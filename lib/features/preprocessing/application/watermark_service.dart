import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/pref_keys.dart';
import '../../../core/storage/persistent_notifier.dart';
import 'aho_corasick.dart';
import 'watermark_defaults.dart';

// ==================== 持久化 ====================

/// 「删除水印」这条规则是否开启。默认关：
/// 词表是用户自己攒的，空表开着没意义，还会让首次使用的性能莫名其妙变差。
final watermarkEnabledProvider =
    NotifierProvider<WatermarkEnabledNotifier, bool>(
  WatermarkEnabledNotifier.new,
);

class WatermarkEnabledNotifier extends BoolPrefNotifier {
  WatermarkEnabledNotifier()
      : super(key: PrefKeys.watermarkEnabled, initial: false);
}

/// 水印词表。每行一条，纯字面匹配（不解析正则、不支持替换，命中就删）。
///
/// 初始值是 App 内置的 [kDefaultWatermarkWords]（来自用户提供的词表，
/// 已去重），首次安装就有；用户打开编辑器增删改之后会被自己的内容覆盖。
final watermarkWordsProvider =
    NotifierProvider<WatermarkWordsNotifier, String>(
  WatermarkWordsNotifier.new,
);

class WatermarkWordsNotifier extends StringPrefNotifier {
  WatermarkWordsNotifier()
      : super(key: PrefKeys.watermarkWords, initial: kDefaultWatermarkWords);

  void setAll(String text) => update(text);
}

/// 首次进入对比页时「要不要自动去掉水印」是否已经问过。
///
/// 只问一次：问过就写 true，之后进对比页不再弹。
final watermarkOnboardProvider =
    NotifierProvider<WatermarkOnboardNotifier, bool>(
  WatermarkOnboardNotifier.new,
);

class WatermarkOnboardNotifier extends BoolPrefNotifier {
  WatermarkOnboardNotifier()
      : super(key: PrefKeys.watermarkOnboardAsked, initial: false);
}

/// 把词表文本拆成条目：去空行、去重、保持原有顺序。
List<String> parseWatermarkWords(String text) {
  if (text.isEmpty) return const <String>[];
  final out = <String>[];
  final seen = <String>{};
  for (final raw in text.split('\n')) {
    final w = normalizeWatermark(raw);
    if (w.isEmpty) continue;
    if (!seen.add(w)) continue;
    out.add(w);
  }
  return out;
}

// ==================== 归一化 ====================

/// 匹配前把「不该影响比对」的字符抹掉。
///
/// 水印作者最常用的反过滤手段，就是在关键词中间插随机控制字符
/// （比如把「微博」写成「微\x08博」），或者插空格。只做字面匹配的话
/// 这些变体全都漏掉。这里把两边（词表和正文）都归一化，插什么都一样命中。
///
/// 保留 \n 和 \r：行边界是判断「这行是不是被删空了」的依据，不能抹。
bool _isStrippable(int code) {
  if (code == 0x0A || code == 0x0D) return false;
  if (code < 0x20) return true; // C0 控制字符
  if (code == 0x7F) return true; // DEL
  if (code == 0x20 || code == 0x09 || code == 0x3000) return true;
  if (code == 0xA0 || code == 0xAD) return true;
  if (code >= 0x200B && code <= 0x200F) return true; // 零宽
  if (code >= 0x202A && code <= 0x202E) return true; // 方向控制
  if (code == 0x202F) return true;
  if (code >= 0x2060 && code <= 0x2064) return true;
  if (code >= 0x2066 && code <= 0x2069) return true;
  if (code == 0xFEFF) return true; // BOM
  return false;
}

/// 归一化一条词（或一行）：抹掉上面那些字符。幂等，重复调用无副作用。
String normalizeWatermark(String s) {
  if (s.isEmpty) return s;
  final codes = <int>[];
  for (final code in s.codeUnits) {
    if (_isStrippable(code)) continue;
    codes.add(code);
  }
  return String.fromCharCodes(codes);
}

/// 归一化一行，用于判断它是不是「已经被删空了」。
bool isLineBlankAfterStrip(String line) => normalizeWatermark(line).isEmpty;

// ==================== AC 缓存 ====================

class _WatermarkMatcher {
  const _WatermarkMatcher(this.ac, this.wordCount);
  final AhoCorasick? ac;
  final int wordCount;
}

/// 缓存键就是词表原文。
///
/// 别拿条数当键：词表改了但条数刚好一样时会命中旧树，
/// 用户改完词发现没生效，这种 bug 极难查。
/// Dart 的 String 会缓存 hashCode，重复查表几乎不花钱。
const int _watermarkCacheCap = 8;
final Map<String, _WatermarkMatcher> _watermarkCache = {};

_WatermarkMatcher _matcherFor(String wordsText) {
  final hit = _watermarkCache[wordsText];
  if (hit != null) return hit;

  if (_watermarkCache.length >= _watermarkCacheCap) {
    _watermarkCache.clear();
  }

  final words = parseWatermarkWords(wordsText);
  final ac = words.isEmpty
      ? null
      : AhoCorasick(
          patterns: words,
          replacements: List<String>.filled(words.length, ''),
          priorities: List<int>.generate(words.length, (i) => i),
        );
  final m = _WatermarkMatcher(ac, words.length);
  _watermarkCache[wordsText] = m;
  return m;
}

/// 词表变了要清缓存，否则改完词表还是拿旧树匹配。
void invalidateWatermarkCache() => _watermarkCache.clear();

// ==================== 应用 ====================

/// 按词表删水印。
///
/// 三件事：
///   1. 正文归一化（抹干扰字符），同时记下「归一化后的第 i 个字符」对应
///      正文的哪个位置 —— 匹配到的是归一化串上的区间，要还原回正文才能删准。
///   2. AC 一次扫完所有词，合并重叠区间，从后往前删（避免删前面的让后面的
///      下标失效）。
///   3. 删完之后，原本只剩空白的行整行去掉 —— 一行本来就是「△」这种水印，
///      抠掉之后留个空行在对比页碍事。
String applyWatermarkRules(String text, String wordsText) {
  if (text.isEmpty) return text;

  final matcher = _matcherFor(wordsText);
  final ac = matcher.ac;
  if (ac == null) return text;

  // 1. 归一化 + 位置映射
  final codes = <int>[];
  final map = <int>[];
  for (var i = 0; i < text.length; i++) {
    final code = text.codeUnitAt(i);
    if (_isStrippable(code)) continue;
    codes.add(code);
    map.add(i);
  }
  if (map.isEmpty) return text;
  final norm = String.fromCharCodes(codes);

  // 2. 收集命中区间（findAllMatches 按结束位置输出，这里要按起点重排）
  final hits = <List<int>>[];
  ac.findAllMatches(norm, (start, end, _) {
    if (start < 0 || end > map.length || start >= end) return;
    hits.add(<int>[start, end]);
  });
  if (hits.isEmpty) return text;

  hits.sort((a, b) => a[0].compareTo(b[0]));
  final merged = <List<int>>[];
  for (final h in hits) {
    if (merged.isEmpty || h[0] > merged.last[1]) {
      merged.add(h);
    } else if (h[1] > merged.last[1]) {
      merged.last[1] = h[1];
    }
  }

  // 3. 从后往前删，映射回正文下标
  var out = text;
  for (var k = merged.length - 1; k >= 0; k--) {
    final start = map[merged[k][0]];
    final end = map[merged[k][1] - 1] + 1;
    if (start >= end || end > out.length) continue;
    out = out.substring(0, start) + out.substring(end);
  }

  // 4. 被删空的行整行去掉
  final lines = out.split('\n');
  final kept = <String>[];
  var dropped = false;
  for (final l in lines) {
    if (isLineBlankAfterStrip(l)) {
      dropped = true;
      continue;
    }
    kept.add(l);
  }
  return dropped ? kept.join('\n') : out;
}

/// 词表条目数（给设置页显示用）。
int countWatermarkWords(String text) => parseWatermarkWords(text).length;

/// 从导入的 txt 里整理出词表条目。
///
/// 用户给的文件往往有大量重复（实测 3159 行里重复了 1422 行），
/// 这里一次做掉：分拆 → 归一化 → 去空行 → 去重。
List<String> parseImportedWatermarks(String raw) {
  return parseWatermarkWords(raw);
}

/// 把词表编码成存储用的文本（每行一条）。
String encodeWatermarkWords(List<String> words) => words.join('\n');
