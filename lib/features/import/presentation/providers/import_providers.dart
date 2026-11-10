import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/debug/compare_timing_log.dart';
import '../../../../core/storage/pref_keys.dart';
import '../../../../core/storage/persistent_notifier.dart';
import '../../../preprocessing/application/aho_corasick.dart';
import '../../../preprocessing/application/builtin_rules.dart';
import '../../../preprocessing/application/preprocessing_service.dart';
import '../../../preprocessing/application/watermark_service.dart';
import '../../../preprocessing/domain/preprocessing_rule.dart';
import '../../domain/import_source.dart';

// ==================== 特殊块标记 ====================

/// 统一规则顺序列表里，关键词块 / 正则块 / 水印块用这几个特殊 id 占位。
class RuleBlockIds {
  const RuleBlockIds._();
  static const String keyword = '__block_keyword__';
  static const String regex = '__block_regex__';
  static const String watermark = '__block_watermark__';
}

// ==================== 正则缓存 ====================

const int _regexCacheCap = 512;
final Map<String, RegExp> _regexCache = {};

RegExp _cachedRegex(String pattern, {bool multiLine = false}) {
  final key = '$multiLine|$pattern';
  final hit = _regexCache[key];
  if (hit != null) return hit;
  if (_regexCache.length >= _regexCacheCap) {
    _regexCache.clear();
  }
  final re = RegExp(pattern, multiLine: multiLine);
  _regexCache[key] = re;
  return re;
}

final RegExp _regexMeta = RegExp(r'[\^$.*+?()\[\]{}|\\]');

bool _isPlainText(String s) => !_regexMeta.hasMatch(s);

/// 规则文本按行切分。兼容 `\r\n` / `\r` / `\n` 三种换行。
///
/// **不做 trim**：行首行尾的空格/Tab/全角空格等一律保留，作为用户
/// 输入的一部分。唯一被跳过的是"完全空白、长度为 0"的行。
final RegExp _ruleLineSplitter = RegExp(r'\r\n|\r|\n');

// ==================== 写死水印词库（已废弃） ====================
//
// 早期版本曾在这里放一份写死的 builtinWatermarks 常量、并预建一棵
// _watermarkAc 在 [applyKeywordRules] 里顺手替换。现在改成了用户可在
// 「删除水印」编辑器里自由编辑的词表（[watermarkWordsProvider]），配合
// 独立开关与顺序块，那份写死词库已无意义，删掉避免两套机制并存让人困惑。

// ==================== 关键词规则解析缓存 + AC 缓存 ====================

class _ParsedKeywordRules {
  const _ParsedKeywordRules(this.ac);
  final AhoCorasick? ac;
}

const int _keywordRulesCacheCap = 16;
final Map<String, _ParsedKeywordRules> _keywordRulesCache = {};

_ParsedKeywordRules _parseKeywordRules(String rulesText) {
  final hit = _keywordRulesCache[rulesText];
  if (hit != null) return hit;

  final patterns = <String>[];
  final replacements = <String>[];
  final priorities = <int>[];

  var lineNo = 0;
  for (final line in rulesText.split(_ruleLineSplitter)) {
    final currentLine = lineNo;
    lineNo++;
    // 只跳过真正的空行（连续换行产生的空行）。
    // 一行里哪怕只有一个空格，也当作有效查找词。
    if (line.isEmpty) continue;
    final idx = line.indexOf('->=>');
    if (idx >= 0) {
      final find = line.substring(0, idx);
      if (find.isEmpty) continue;
      final replace = line.substring(idx + 4);
      patterns.add(find);
      replacements.add(_unescapeReplacement(replace));
      priorities.add(currentLine);
    } else {
      patterns.add(line);
      replacements.add('');
      priorities.add(currentLine);
    }
  }

  final ac = patterns.isEmpty
      ? null
      : AhoCorasick(
          patterns: patterns,
          replacements: replacements,
          priorities: priorities,
        );

  final parsed = _ParsedKeywordRules(ac);
  if (_keywordRulesCache.length >= _keywordRulesCacheCap) {
    _keywordRulesCache.clear();
  }
  _keywordRulesCache[rulesText] = parsed;
  return parsed;
}

// ==================== 正则规则解析缓存 ====================

class _ParsedRegexRule {
  const _ParsedRegexRule(this.find, this.replace, this.isPlain);
  final String find;
  final String replace;
  final bool isPlain;
}

const int _regexRulesCacheCap = 16;
final Map<String, List<_ParsedRegexRule>> _regexRulesCache = {};

List<_ParsedRegexRule> _parseRegexRules(String rulesText) {
  final hit = _regexRulesCache[rulesText];
  if (hit != null) return hit;

  final out = <_ParsedRegexRule>[];
  for (final line in rulesText.split(_ruleLineSplitter)) {
    // 同关键词表：只跳过空行，不 trim，空格一律保留。
    if (line.isEmpty) continue;
    final idx = line.indexOf('->=>');
    final find = idx >= 0 ? line.substring(0, idx) : line;
    final replace = idx >= 0 ? line.substring(idx + 4) : '';
    if (find.isEmpty) continue;
    out.add(_ParsedRegexRule(
      find,
      _unescapeReplacement(replace),
      _isPlainText(find),
    ));
  }

  if (_regexRulesCache.length >= _regexRulesCacheCap) {
    _regexRulesCache.clear();
  }
  _regexRulesCache[rulesText] = out;
  return out;
}

// ==================== 文本 provider ====================

/// 原始文本（导入后从没被改过）。**不持久化**。
final originalRawTextProvider = StateProvider<String?>((ref) => null);
final modifiedRawTextProvider = StateProvider<String?>((ref) => null);

/// 用户在对比页编辑后的临时文本。
/// null = 没有编辑过，走原文 + 规则。
/// 非 null = 从这份内容开始跑规则（规则对它仍然生效）。
final editedOriginalProvider = StateProvider<String?>((ref) => null);
final editedModifiedProvider = StateProvider<String?>((ref) => null);

final originalFileNameProvider = StateProvider<String?>((ref) => null);
final modifiedFileNameProvider = StateProvider<String?>((ref) => null);

final originalFilePathProvider = StateProvider<String?>((ref) => null);
final modifiedFilePathProvider = StateProvider<String?>((ref) => null);

/// 当前对比是否由 DupeBox 导入而来。
/// 用于：① 删除时给共享回收站记录打 `fromDupeBox` 标记；
///       ② 删除确认文案区分「可在 DupeBox 回收站恢复」还是「可在 docdiff 回收站恢复」。
/// 默认值 false；来自 DupeBox 的分享会在 share_intake_listener 中置 true，
/// 其余入口（导入 / 文件浏览器）显式置 false，避免遗留上一轮状态。
final fromDupeBoxProvider = StateProvider<bool>((ref) => false);

/// 从其他 App 分享进来的临时文件路径。
/// 只用于文件信息弹窗展示大小/时间，**不参与删除**（删除只看上面两个 provider）。
final originalSharedTempPathProvider = StateProvider<String?>((ref) => null);
final modifiedSharedTempPathProvider = StateProvider<String?>((ref) => null);

final originalEncodingProvider = StateProvider<String>((ref) => 'UTF-8');
final modifiedEncodingProvider = StateProvider<String>((ref) => 'UTF-8');

final showProcessedTextProvider = StateProvider<bool>((ref) => false);

final importRevisionProvider = StateProvider<int>((ref) => 0);

final selectedSourceProvider = StateProvider<ImportSource?>((ref) => null);

// ==================== 自定义预处理规则（持久化） ====================

final userRulesProvider =
    NotifierProvider<UserRulesNotifier, List<PreprocessingRule>>(
  UserRulesNotifier.new,
);

class UserRulesNotifier extends PersistentNotifier<List<PreprocessingRule>> {
  @override
  String get key => PrefKeys.userRules;

  @override
  List<PreprocessingRule> get defaultValue => const [];

  @override
  List<PreprocessingRule> decode(String raw) {
    final list = jsonDecode(raw) as List<dynamic>;
    return [
      for (final e in list)
        PreprocessingRule.fromJson(e as Map<String, dynamic>),
    ];
  }

  @override
  String encode(List<PreprocessingRule> value) =>
      jsonEncode([for (final r in value) r.toJson()]);

  void add(PreprocessingRule rule) {
    update([...state, rule]);
    ref.read(ruleOrderProvider.notifier).append(rule.id);
  }

  void updateRule(PreprocessingRule rule) => update([
        for (final r in state)
          if (r.id == rule.id) rule else r,
      ]);

  void remove(String id) {
    update(state.where((r) => r.id != id).toList());
    ref.read(ruleOrderProvider.notifier).removeId(id);
  }

  void toggle(String id) => update([
        for (final r in state)
          if (r.id == id) r.copyWith(enabled: !r.enabled) else r,
      ]);

  void importFromJson(List<Map<String, dynamic>> json) =>
      update(json.map(PreprocessingRule.fromJson).toList());
}

// ==================== 内置规则启用状态（持久化） ====================

final builtinRuleEnablesProvider =
    NotifierProvider<BuiltinRuleEnablesNotifier, Map<String, bool>>(
  BuiltinRuleEnablesNotifier.new,
);

class BuiltinRuleEnablesNotifier
    extends PersistentNotifier<Map<String, bool>> {
  @override
  String get key => PrefKeys.builtinRuleEnables;

  @override
  Map<String, bool> get defaultValue => <String, bool>{
        for (final r in BuiltinRules.all()) r.id: r.enabled,
      };

  @override
  Map<String, bool> decode(String raw) {
    final saved = jsonDecode(raw) as Map<String, dynamic>;
    final out = <String, bool>{
      for (final r in BuiltinRules.all()) r.id: r.enabled,
    };
    for (final e in saved.entries) {
      if (out.containsKey(e.key)) {
        out[e.key] = e.value == true;
      }
    }
    return out;
  }

  @override
  String encode(Map<String, bool> value) => jsonEncode(value);

  void setOne(String id, bool enabled) {
    update({...state, id: enabled});
  }
}

/// 被隐藏的内置规则 id 集合。
/// 被隐藏的规则不出现在比较设置列表里，但仍然保留配置。
final builtinRuleHiddenProvider =
    NotifierProvider<BuiltinRuleHiddenNotifier, Set<String>>(
  BuiltinRuleHiddenNotifier.new,
);

class BuiltinRuleHiddenNotifier
    extends PersistentNotifier<Set<String>> {
  @override
  String get key => PrefKeys.builtinRuleHidden;

  @override
  Set<String> get defaultValue => const {};

  @override
  Set<String> decode(String raw) {
    final list = jsonDecode(raw) as List<dynamic>;
    return list.map((e) => e as String).toSet();
  }

  @override
  String encode(Set<String> value) => jsonEncode(value.toList());

  void hide(String id) => update({...state, id});

  void restore(String id) {
    final next = Set<String>.from(state);
    next.remove(id);
    update(next);
  }

  void restoreAll() => update(const {});
}

/// 内置规则名称覆盖表：ruleId → 用户改的名字。
/// 空表 = 全都用内置默认名。
final builtinRuleNameOverridesProvider = NotifierProvider<
    BuiltinRuleNameOverridesNotifier, Map<String, String>>(
  BuiltinRuleNameOverridesNotifier.new,
);

class BuiltinRuleNameOverridesNotifier
    extends PersistentNotifier<Map<String, String>> {
  @override
  String get key => PrefKeys.builtinRuleNameOverrides;

  @override
  Map<String, String> get defaultValue => const {};

  @override
  Map<String, String> decode(String raw) {
    final saved = jsonDecode(raw) as Map<String, dynamic>;
    return saved.map((k, v) => MapEntry(k, v as String));
  }

  @override
  String encode(Map<String, String> value) => jsonEncode(value);

  /// 设置。空串 = 删掉覆盖（回到默认名）。
  void setOne(String id, String name) {
    final next = Map<String, String>.from(state);
    if (name.trim().isEmpty) {
      next.remove(id);
    } else {
      next[id] = name;
    }
    update(next);
  }

  void remove(String id) {
    if (!state.containsKey(id)) return;
    final next = Map<String, String>.from(state);
    next.remove(id);
    update(next);
  }
}
final builtinRulesWithStateProvider = Provider<List<PreprocessingRule>>((ref) {
  final overrides = ref.watch(builtinRuleEnablesProvider);
  final hidden = ref.watch(builtinRuleHiddenProvider);
  return <PreprocessingRule>[
    for (final r in BuiltinRules.all())
      if (!hidden.contains(r.id))
        r.copyWith(enabled: overrides[r.id] ?? r.enabled),
  ];
});

final ruleByIdProvider = Provider<Map<String, PreprocessingRule>>((ref) {
  final builtins = ref.watch(builtinRulesWithStateProvider);
  final user = ref.watch(userRulesProvider);
  final overrides = ref.watch(builtinRuleNameOverridesProvider);
  final map = <String, PreprocessingRule>{};
  for (final r in builtins) {
    final newName = overrides[r.id];
    map[r.id] = (newName != null && newName.isNotEmpty)
        ? r.copyWith(name: newName)
        : r;
  }
  for (final r in user) map[r.id] = r;
  return map;
});

// ==================== 统一规则顺序（持久化） ====================

final ruleOrderProvider =
    NotifierProvider<RuleOrderNotifier, List<String>>(
  RuleOrderNotifier.new,
);

class RuleOrderNotifier extends PersistentNotifier<List<String>> {
  @override
  String get key => PrefKeys.ruleOrder;

  /// 「删除水印」默认排在 norm_eol 之后、其余规则之前。
  ///
  /// 两个原因：
  ///   1. 默认开着的「删掉空白符号」会把「微 博」压成「微博」，
  ///      等它先跑完，词表里带空格的形态就再也匹配不上了。
  ///      （现在匹配前两边都会归一化，不至于完全失效，但越靠前越稳。）
  ///   2. 更关键：水印删完常常留下空行。排在前面的话，后面的
  ///      「去行首尾空白 → 删掉空行」能顺手把残渣清掉；
  ///      排最后的话，删完留一堆空行没人管，对比页会冒出一片空行差异。
  ///
  /// 老用户升级时 order 已经存在，不会走到这里 —— 见
  /// [_ensureWatermarkInOrder] 里的补插逻辑。
  @override
  List<String> get defaultValue => <String>[
        'norm_eol',
        RuleBlockIds.watermark,
        for (final r in BuiltinRules.all())
          if (r.id != 'norm_eol') r.id,
        RuleBlockIds.keyword,
        RuleBlockIds.regex,
      ];

  @override
  List<String> decode(String raw) {
    if (raw.isEmpty) return defaultValue;
    final list = raw.split('\u0000').where((s) => s.isNotEmpty).toList();
    return _ensureWatermarkInOrder(list);
  }

  /// 老配置里没有水印块：补插到 norm_eol 后面（没有就插到最前面），
  /// 保证升级后这条规则出现在列表里，且位置是推荐的那个。
  static List<String> _ensureWatermarkInOrder(List<String> list) {
    if (list.contains(RuleBlockIds.watermark)) return list;
    final out = List<String>.from(list);
    final at = out.indexOf('norm_eol');
    out.insert(at < 0 ? 0 : at + 1, RuleBlockIds.watermark);
    return out;
  }

  @override
  String encode(List<String> value) => value.join('\u0000');

  void setAll(List<String> value) => update(List<String>.from(value));

  void append(String id) {
    if (state.contains(id)) return;
    update([...state, id]);
  }

  void removeId(String id) {
    if (!state.contains(id)) return;
    update(state.where((s) => s != id).toList());
  }
}

// ==================== 关键词 / 正则替换规则（持久化） ====================

final keywordRulesTextProvider =
    NotifierProvider<KeywordRulesTextNotifier, String>(
  KeywordRulesTextNotifier.new,
);

class KeywordRulesTextNotifier extends StringPrefNotifier {
  KeywordRulesTextNotifier() : super(key: PrefKeys.keywordRulesText);
}

final regexRulesTextProvider =
    NotifierProvider<RegexRulesTextNotifier, String>(
  RegexRulesTextNotifier.new,
);

class RegexRulesTextNotifier extends StringPrefNotifier {
  RegexRulesTextNotifier() : super(key: PrefKeys.regexRulesText);
}

// ==================== 规则表详细说明（持久化，用户可编辑） ====================

final keywordRulesHelpProvider =
    NotifierProvider<KeywordRulesHelpNotifier, String>(
  KeywordRulesHelpNotifier.new,
);

class KeywordRulesHelpNotifier extends StringPrefNotifier {
  KeywordRulesHelpNotifier() : super(key: PrefKeys.keywordRulesHelp);
}

final regexRulesHelpProvider =
    NotifierProvider<RegexRulesHelpNotifier, String>(
  RegexRulesHelpNotifier.new,
);

class RegexRulesHelpNotifier extends StringPrefNotifier {
  RegexRulesHelpNotifier() : super(key: PrefKeys.regexRulesHelp);
}

// ==================== 文本转义 ====================

String _unescapeReplacement(String s) {
  if (!s.contains(r'\')) return s;
  final sb = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c == r'\' && i + 1 < s.length) {
      final n = s[i + 1];
      switch (n) {
        case 'n':
          sb.write('\n');
          i++;
          continue;
        case 'r':
          sb.write('\r');
          i++;
          continue;
        case 't':
          sb.write('\t');
          i++;
          continue;
        case '0':
          sb.write('\u0000');
          i++;
          continue;
        case r'\':
          sb.write(r'\');
          i++;
          continue;
      }
    }
    sb.write(c);
  }
  return sb.toString();
}

// ==================== 应用 ====================

/// 规则表（普通文字）：所有规则合成一棵 AC 树，一次扫描。
/// 同一位置多命中 → 行号最小的赢。
String applyKeywordRules(String text, String rulesText) {
  if (text.isEmpty) return text;

  var out = text;

  if (rulesText.isEmpty) return out;
  final parsed = _parseKeywordRules(rulesText);
  if (parsed.ac != null) {
    out = parsed.ac!.replaceAll(out);
  }
  return out;
}

/// 规则表（支持正则）：逐条 replaceAll，严格按行顺序。
String applyRegexRules(String text, String rulesText) {
  if (text.isEmpty || rulesText.isEmpty) return text;

  final rules = _parseRegexRules(rulesText);
  var out = text;
  for (final r in rules) {
    if (r.isPlain) {
      if (!out.contains(r.find)) continue;
      out = out.replaceAll(r.find, r.replace);
    } else {
      try {
        out = out.replaceAll(_cachedRegex(r.find), r.replace);
      } catch (_) {}
    }
  }
  return out;
}

// ==================== 预处理管线 ====================

bool _inScope(PreprocessingRule rule, {required bool isOriginal}) {
  switch (rule.scope) {
    case RuleScope.both:
      return true;
    case RuleScope.originalOnly:
      return isOriginal;
    case RuleScope.modifiedOnly:
      return !isOriginal;
  }
}

/// 按用户排序，依次执行所有规则（纯数据版，不依赖 Ref）。
///
/// 所有输入都是普通数据（字符串 / List / Map / 枚举），因此这个函数可以
/// 直接在后台 isolate 里跑——除了一个例外：JS 规则（[RuleKind.js]）依赖
/// flutter_js 的平台环境，调用方必须保证 [order]/[byId] 里没有启用的
/// JS 规则，否则在后台会执行失败（失败时规则按「原样返回」兜底，不崩）。
///
/// [timing] 非空时，每条规则的耗时与字符变化会追加进去（key/value），
/// 供主线程写进对比耗时日志；传 null 则不创建任何 Stopwatch，零额外开销。
String runRulesPipelinePure({
  required String raw,
  required bool isOriginal,
  required List<String> order,
  required Map<String, PreprocessingRule> byId,
  required String keywordText,
  required String regexText,
  required bool watermarkOn,
  required String watermarkWords,
  List<(String, Object)>? timing,
}) {
  final side = isOriginal ? '左' : '右';
  final timed = timing != null;
  final swAll = timed ? (Stopwatch()..start()) : null;
  var out = raw;
  var idx = 0;
  for (final id in order) {
    idx++;
    final before = out.length;
    final sw = timed ? (Stopwatch()..start()) : null;
    var note = '';
    if (id == RuleBlockIds.keyword) {
      out = applyKeywordRules(out, keywordText);
      note = '关键词块';
    } else if (id == RuleBlockIds.regex) {
      out = applyRegexRules(out, regexText);
      note = '正则块';
    } else if (id == RuleBlockIds.watermark) {
      // 默认关：词表空着开着没意义，还会白跑一次全文扫描。
      if (watermarkOn && watermarkWords.isNotEmpty) {
        out = applyWatermarkRules(out, watermarkWords);
        note = '水印块(执行)';
      } else {
        note = '水印块(跳过)';
      }
    } else {
      final rule = byId[id];
      if (rule == null) {
        note = '未找到规则(跳过)';
      } else if (!rule.enabled) {
        note = '${rule.name}(已关闭,跳过)';
      } else if (!_inScope(rule, isOriginal: isOriginal)) {
        note = '${rule.name}(作用域不匹配,跳过)';
      } else {
        out = applyOneRule(out, rule);
        note = '${rule.name}(${rule.kind.name})';
      }
    }
    sw?.stop();
    timing?.add((
      '规则/$side#$idx $id $note',
      '${sw?.elapsedMilliseconds ?? 0}ms  字符 $before → ${out.length}',
    ));
  }
  swAll?.stop();
  timing?.add(('规则/$side 合计Ms', swAll?.elapsedMilliseconds ?? 0));
  timing?.add(('规则/$side 输出字符数', out.length));
  return out;
}

/// 按用户排序，依次执行所有规则。
String _runPipeline(
  Ref ref, {
  required String raw,
  required bool isOriginal,
}) {
  final order = ref.watch(ruleOrderProvider);
  final byId = ref.watch(ruleByIdProvider);
  final keywordText = ref.watch(keywordRulesTextProvider);
  final regexText = ref.watch(regexRulesTextProvider);
  final watermarkOn = ref.watch(watermarkEnabledProvider);
  final watermarkWords = ref.watch(watermarkWordsProvider);

  final log = CompareTimingLog.instance;
  final side = isOriginal ? '左' : '右';
  log.section('预处理规则 / $side');
  log.param('规则/输入字符数', raw.length);
  log.param('规则/规则顺序条数', order.length);
  log.param('规则/顺序', order.join(' → '));
  log.param('规则/关键词配置字符数', keywordText.length);
  log.param('规则/正则配置字符数', regexText.length);
  log.param('规则/水印开关', watermarkOn);
  log.param('规则/水印词数', watermarkWords.length);

  // 没有正在记录的对比时，不创建任何 Stopwatch，保持零额外开销。
  final timing = log.active ? <(String, Object)>[] : null;
  final out = runRulesPipelinePure(
    raw: raw,
    isOriginal: isOriginal,
    order: order,
    byId: byId,
    keywordText: keywordText,
    regexText: regexText,
    watermarkOn: watermarkOn,
    watermarkWords: watermarkWords,
    timing: timing,
  );
  if (timing != null) {
    for (final (k, v) in timing) {
      log.param(k, v);
    }
  }
  log.mark('规则管线执行完成 / $side');
  return out;
}

/// 左边当前显示的文本。
///
/// 起点规则：
///   · 有编辑（edited != null）→ 从编辑内容开始跑规则
///   · 没有编辑            → 从原文开始跑规则
/// 这样规则永远生效，不会因为"编辑过"而被冻结；
/// 用户在设置里改开关，两边都会跟着变。
final preprocessedOriginalProvider = Provider<String>((ref) {
  final edited = ref.watch(editedOriginalProvider);
  final raw = ref.watch(originalRawTextProvider);
  if (raw == null && edited == null) return '';
  return _runPipeline(ref, raw: edited ?? raw!, isOriginal: true);
});

/// 右边当前显示的文本。逻辑同上。
final preprocessedModifiedProvider = Provider<String>((ref) {
  final edited = ref.watch(editedModifiedProvider);
  final raw = ref.watch(modifiedRawTextProvider);
  if (raw == null && edited == null) return '';
  return _runPipeline(ref, raw: edited ?? raw!, isOriginal: false);
});
