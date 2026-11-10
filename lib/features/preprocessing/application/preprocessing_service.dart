import 'package:charset/charset.dart';

import '../domain/preprocessing_rule.dart';
import 'js_runtime.dart';
import 'presets.dart';

/// 正则缓存：同一个 pattern 只编译一次，之后复用。
const int _regexCacheCap = 512;
final Map<String, RegExp> _regexCache = {};

RegExp _cachedRegex(String pattern) {
  final hit = _regexCache[pattern];
  if (hit != null) return hit;
  if (_regexCache.length >= _regexCacheCap) {
    _regexCache.clear();
  }
  final re = RegExp(pattern, multiLine: true);
  _regexCache[pattern] = re;
  return re;
}

/// 还原 \n \r \t \\ \0 成真字符。
String unescapeEscapes(String s) {
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

/// 展开替换串里的 $0 $1 $2 … 为捕获组内容。
String expandDollarRefs(String tpl, Match m) {
  if (!tpl.contains(r'$')) return tpl;
  final re = RegExp(r'\$(\d+)');
  final out = StringBuffer();
  var last = 0;
  for (final match in re.allMatches(tpl)) {
    out.write(tpl.substring(last, match.start));
    final idx = int.parse(match.group(1)!);
    if (idx == 0) {
      out.write(m.group(0) ?? '');
    } else {
      out.write(m.group(idx) ?? '');
    }
    last = match.end;
  }
  out.write(tpl.substring(last));
  return out.toString();
}

/// 展开替换串里的 \1 \2 … 为捕获组内容。
String expandBackslashRefs(String tpl, Match m) {
  if (!tpl.contains(r'\')) return tpl;
  final re = RegExp(r'\\(\d+)');
  final out = StringBuffer();
  var last = 0;
  for (final match in re.allMatches(tpl)) {
    out.write(tpl.substring(last, match.start));
    final idx = int.parse(match.group(1)!);
    out.write(m.group(idx) ?? '');
    last = match.end;
  }
  out.write(tpl.substring(last));
  return out.toString();
}

/// 对一段文本执行一条规则。
///
/// 三种 kind：
///   replace → 走 7 开关的查找替换（含内置脚本）
///   preset  → 走 presets.dart 里的预置功能
///   js      → 走 js_runtime.dart 里的 JS 引擎
String applyOneRule(String text, PreprocessingRule rule) {
  switch (rule.kind) {
    case RuleKind.preset:
      return _applyPreset(text, rule);
    case RuleKind.js:
      return _applyJs(text, rule);
    case RuleKind.replace:
      break;
    case RuleKind.table:
      // 规则表类型不走 applyOneRule，由调用方逐表执行；这里兜底原样返回。
      return text;
  }
  return _applyReplace(text, rule);
}

// ==================== preset ====================

String _applyPreset(String text, PreprocessingRule rule) {
  final id = rule.presetId;
  if (id == null || id.isEmpty) return text;
  final preset = Presets.byId(id);
  if (preset == null) return text;
  try {
    return preset.apply(text, rule.params);
  } catch (_) {
    return text;
  }
}

// ==================== js ====================

String _applyJs(String text, PreprocessingRule rule) {
  final script = rule.jsScript;
  if (script == null || script.trim().isEmpty) return text;
  try {
    return JsRuntime.instance.run(script, text);
  } catch (_) {
    return text;
  }
}

// ==================== replace ====================

String _applyReplace(String text, PreprocessingRule rule) {
  // 内置脚本优先。
  final script = rule.script;
  if (script != null && script.isNotEmpty) {
    switch (script) {
      case 'lowercase':
        return text.toLowerCase();
      case 'dropEmptyLines':
        return text.split('\n').where((l) => l.trim().isNotEmpty).join('\n');
      case 'unifyAnsi':
        return unifyToAnsi(text);
      case 'fullToHalf':
        return fullToHalf(text);
      case 'enPunctToCn':
        return enPunctToCn(text);
    }
    return text;
  }

  if (rule.findPattern.isEmpty) return text;

  // 1. 查找串预处理。
  var find = rule.findPattern;
  if (rule.findEscape) find = unescapeEscapes(find);
  if (find.isEmpty) return text;

  // 2. 用正则还是字面。
  final useRegex = rule.findRegex && !rule.findLiteral;

  if (useRegex) {
    RegExp re;
    try {
      re = _cachedRegex(find);
    } catch (_) {
      return text;
    }
    final needExpand =
        !rule.replaceLiteral && (rule.replaceDollar || rule.replaceBackslash);
    final needEscape = rule.replaceEscape;
    if (needExpand || needEscape) {
      return text.replaceAllMapped(re, (m) => _buildReplacement(rule, m));
    }
    return text.replaceAll(re, rule.replaceWith);
  } else {
    // 字面匹配。
    if (!text.contains(find)) return text;
    final replacement = _buildLiteralReplacement(rule, find);
    return text.replaceAll(find, replacement);
  }
}

String _buildReplacement(PreprocessingRule rule, Match m) {
  var tpl = rule.replaceWith;
  if (rule.replaceEscape) tpl = unescapeEscapes(tpl);
  if (rule.replaceLiteral) return tpl;
  if (rule.replaceDollar) tpl = expandDollarRefs(tpl, m);
  if (rule.replaceBackslash) tpl = expandBackslashRefs(tpl, m);
  return tpl;
}

String _buildLiteralReplacement(PreprocessingRule rule, String find) {
  var replacement = rule.replaceWith;
  if (rule.replaceEscape) replacement = unescapeEscapes(replacement);
  if (rule.replaceLiteral) return replacement;
  // 字面匹配无捕获组：$0 = 整个 find，$1+ = 空；\1+ = 空。
  if (rule.replaceDollar) {
    replacement = replacement.replaceAll(r'$0', find);
    replacement = replacement.replaceAll(RegExp(r'\$\d+'), '');
  }
  if (rule.replaceBackslash) {
    replacement = replacement.replaceAll(RegExp(r'\\\d+'), '');
  }
  return replacement;
}

/// 转 GBK 后能无损还原的字符保留，其余删掉。
String unifyToAnsi(String text) {
  try {
    final bytes = gbk.encode(text);
    if (gbk.decode(bytes) == text) return text;
  } catch (_) {}
  final sb = StringBuffer();
  for (final rune in text.runes) {
    final ch = String.fromCharCode(rune);
    try {
      final bytes = gbk.encode(ch);
      if (gbk.decode(bytes) != ch) continue;
      sb.write(ch);
    } catch (_) {}
  }
  return sb.toString();
}

bool _isFullWidthAlnum(int c) =>
    (c >= 0xFF10 && c <= 0xFF19) || // ０-９
    (c >= 0xFF21 && c <= 0xFF3A) || // Ａ-Ｚ
    (c >= 0xFF41 && c <= 0xFF5A); // ａ-ｚ

/// 全角数字/英文字母 → 半角。标点、空格不动。
String fullToHalf(String text) {
  // 原实现用 runes.map + fromCharCodes，不管有没有全角字符都会把整篇
  // 重建一遍（两趟遍历 + 一个大字符串）。这里改成单趟扫描：
  //   · 没有全角字符（绝大多数中文文本）→ 零分配，直接返回原 String；
  //   · 有 → 只在命中处切一小段，重建一次。
  // 全角数字/字母都在 BMP，非 BMP 字符（emoji 等）原样保留，
  // 与 runes 映射逐字等价。
  final sb = StringBuffer();
  var last = 0;
  for (var i = 0; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    if (_isFullWidthAlnum(c)) {
      sb.write(text.substring(last, i));
      sb.writeCharCode(c - 0xFEE0);
      last = i + 1;
    }
  }
  if (last == 0) return text;
  sb.write(text.substring(last));
  return sb.toString();
}

/// 英文标点 → 中文标点。
/// 除 '-' 外，全篇任意位置替换；
/// '-' 只在"跳过行首空白（半角空格/Tab/全角空格）后连续出现"时转。
/// 除 '-' 外的标点替换表，用码点做 key 以便单遍扫描。
/// '-' 不在这里，由下面的行首规则单独处理。
const Map<int, String> _enToCnPunctCodes = {
  0x2C: '，', // ,
  0x2E: '。', // .
  0x21: '！', // !
  0x3F: '？', // ?
  0xFF0A: '*', // ＊
  0x3B: '；', // ;
  0x3A: '：', // :
  0x28: '（', // (
  0x29: '）', // )
  0x7E: '～', // ~
};

String enPunctToCn(String text) {
  var out = text;

  // 1. 单遍扫描替代原来 10 次全文 replaceAll。
  //    替换后的字符都是全角标点，不在待替换集合里，不会触发二次替换，
  //    因此与原来的串行 replaceAll 逐字等价。无命中时不分配新字符串。
  final sb = StringBuffer();
  var last = 0;
  for (var i = 0; i < out.length; i++) {
    final rep = _enToCnPunctCodes[out.codeUnitAt(i)];
    if (rep != null) {
      sb.write(out.substring(last, i));
      sb.write(rep);
      last = i + 1;
    }
  }
  if (last > 0) {
    sb.write(out.substring(last));
    out = sb.toString();
  }

  // 2. '-'：跳过行首空白后，连续的 '-' 才转成 '—'。
  //    全文没有 '-' 时 split/join 的结果就是 out 本身，直接跳过，
  //    省掉一次把全文拆成几万行又拼回来的开销。
  if (out.contains('-')) {
    final lines = out.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      var k = 0;
      while (k < line.length &&
          (line[k] == ' ' || line[k] == '\t' || line[k] == '\u3000')) {
        k++;
      }
      final dashStart = k;
      while (k < line.length && line[k] == '-') {
        k++;
      }
      if (k == dashStart) continue;
      lines[i] = line.substring(0, dashStart) +
          '—' * (k - dashStart) +
          line.substring(k);
    }
    out = lines.join('\n');
  }

  // 3. 连续点号折叠成 ……（放最后：此时英文 . 已经变成 。）
  out = out.replaceAll(RegExp(r'[.。…⋯]{2,}'), '……');

  return out;
}

