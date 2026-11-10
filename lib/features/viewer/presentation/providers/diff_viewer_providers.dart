import 'dart:convert';

import 'package:diff_match_patch/diff_match_patch.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/debug/compare_timing_log.dart';
import '../../../../core/storage/pref_keys.dart';
import '../../../../core/storage/persistent_notifier.dart';
import '../../../diff/domain/diff_entry.dart';
import '../../../diff/domain/diff_operation.dart';
import '../../../diff/domain/diff_result.dart';
import '../../../import/presentation/providers/import_providers.dart';

// ★ 新增 grouped 值
enum ViewMode { merged, sideBySide, diffOnly, diffOnlyPlain, grouped }

final viewModeProvider = StateProvider<ViewMode>((ref) => ViewMode.merged);
/// 进入对比页时的默认视图。用户可在菜单里改。
final defaultViewModeProvider =
    NotifierProvider<DefaultViewModeNotifier, ViewMode>(
  DefaultViewModeNotifier.new,
);

class DefaultViewModeNotifier extends EnumPrefNotifier<ViewMode> {
  DefaultViewModeNotifier()
      : super(
          key: PrefKeys.defaultViewMode,
          values: ViewMode.values,
          initial: ViewMode.grouped,
        );
}

/// 视图 tab 显示顺序（持久化）。
final viewModeOrderProvider =
    NotifierProvider<ViewModeOrderNotifier, List<ViewMode>>(
  ViewModeOrderNotifier.new,
);

class ViewModeOrderNotifier extends PersistentNotifier<List<ViewMode>> {
  @override
  String get key => 'jianming.viewer.viewModeOrder';

  static const List<ViewMode> _defaultOrder = [
    ViewMode.diffOnly,
    ViewMode.diffOnlyPlain,
    ViewMode.grouped,
    ViewMode.merged,
    ViewMode.sideBySide,
  ];

  @override
  List<ViewMode> get defaultValue => _defaultOrder;

  @override
  List<ViewMode> decode(String raw) {
    if (raw.isEmpty) return _defaultOrder;
    final result = <ViewMode>[];
    for (final name in raw.split('\u0000')) {
      if (name.isEmpty) continue;
      for (final m in ViewMode.values) {
        if (m.name == name && !result.contains(m)) {
          result.add(m);
          break;
        }
      }
    }
    for (final m in _defaultOrder) {
      if (!result.contains(m)) result.add(m);
    }
    return result;
  }

  @override
  String encode(List<ViewMode> value) =>
      value.map((m) => m.name).join('\u0000');

  void setAll(List<ViewMode> order) => update(List<ViewMode>.from(order));
}

// ==================== 顶栏按钮排序（持久化） ====================

/// 对比页顶栏里可排序的按钮。
///
/// 「返回」和「更多」固定在两端，不在这个枚举里。
/// deleteLeft / deleteRight / moveLeft / moveRight 是候选按钮：默认不在顶栏，
/// 用户可在显示设置里加进来。
enum TopBarButton {
  pageUp,
  pageDown,
  prevDiff,
  nextDiff,
  find,
  deleteLeft,
  deleteRight,
  moveLeft,
  moveRight,
}

/// 顶栏按钮的一项：固定顺序里的每颗按钮 + 是否在顶栏显示。
class TopBarEntry {
  const TopBarEntry(this.button, this.visible);
  final TopBarButton button;
  final bool visible;

  TopBarEntry copyWith({TopBarButton? button, bool? visible}) {
    return TopBarEntry(button ?? this.button, visible ?? this.visible);
  }
}

/// 顶栏按钮顺序与可见性。
///
/// 持久化格式：`buttonName:1\u0000buttonName:0...`
/// 旧格式（只有名字）解析时默认 visible=true，向前兼容。
final topBarOrderProvider =
    NotifierProvider<TopBarOrderNotifier, List<TopBarEntry>>(
  TopBarOrderNotifier.new,
);

class TopBarOrderNotifier extends PersistentNotifier<List<TopBarEntry>> {
  @override
  String get key => PrefKeys.topBarOrder;

  /// 全部按钮的默认顺序（前 5 个显示，删除/移动按钮默认隐藏）。
  static const List<TopBarEntry> _default = [
    TopBarEntry(TopBarButton.pageUp, true),
    TopBarEntry(TopBarButton.pageDown, true),
    TopBarEntry(TopBarButton.prevDiff, true),
    TopBarEntry(TopBarButton.nextDiff, true),
    TopBarEntry(TopBarButton.find, true),
    TopBarEntry(TopBarButton.deleteLeft, false),
    TopBarEntry(TopBarButton.deleteRight, false),
    TopBarEntry(TopBarButton.moveLeft, false),
    TopBarEntry(TopBarButton.moveRight, false),
  ];

  @override
  List<TopBarEntry> get defaultValue => _default;

  @override
  List<TopBarEntry> decode(String raw) {
    if (raw.isEmpty) return _default;
    final result = <TopBarEntry>[];
    final seenButtons = <TopBarButton>{};
    for (final token in raw.split('\u0000')) {
      if (token.isEmpty) continue;
      TopBarButton? button;
      var visible = true;
      final colon = token.indexOf(':');
      if (colon > 0) {
        // 新格式：name:visible
        final name = token.substring(0, colon);
        for (final b in TopBarButton.values) {
          if (b.name == name) {
            button = b;
            visible = token.substring(colon + 1) == '1';
            break;
          }
        }
      } else {
        // 旧格式：只有 name，默认 visible=true
        for (final b in TopBarButton.values) {
          if (b.name == token) {
            button = b;
            break;
          }
        }
      }
      if (button != null && !seenButtons.contains(button)) {
        seenButtons.add(button);
        result.add(TopBarEntry(button, visible));
      }
    }
    // 补齐所有没出现过的按钮（保持默认顺序）
    for (final entry in _default) {
      if (!seenButtons.contains(entry.button)) result.add(entry);
    }
    return result;
  }

  @override
  String encode(List<TopBarEntry> value) =>
      value.map((e) => '${e.button.name}:${e.visible ? '1' : '0'}').join('\u0000');

  void setAll(List<TopBarEntry> entries) =>
      update(List<TopBarEntry>.from(entries));

  void reorder(int oldIndex, int newIndex) {
    final list = List<TopBarEntry>.from(state);
    if (newIndex > oldIndex) newIndex--;
    final item = list.removeAt(oldIndex);
    list.insert(newIndex, item);
    update(list);
  }

  void setVisible(TopBarButton button, bool visible) {
    final list = state
        .map((e) => e.button == button ? e.copyWith(visible: visible) : e)
        .toList();
    update(list);
  }

  /// 顶栏上实际显示的按钮（visible=true 的，按当前顺序）。
  List<TopBarButton> get visibleButtons =>
      state.where((e) => e.visible).map((e) => e.button).toList();
}

final showPerfOverlayProvider = StateProvider<bool>((ref) => false);

final noWrapProvider = StateProvider<bool>((ref) => false);

// ==================== 显示设置（持久化） ====================

final showLineNumbersProvider =
    NotifierProvider<ShowLineNumbersNotifier, bool>(
  ShowLineNumbersNotifier.new,
);

class ShowLineNumbersNotifier extends BoolPrefNotifier {
  ShowLineNumbersNotifier()
      : super(key: PrefKeys.showLineNumbers, initial: true); // ★ 修正
}

final bodyFontSizeProvider =
    NotifierProvider<BodyFontSizeNotifier, double>(BodyFontSizeNotifier.new);

class BodyFontSizeNotifier extends DoublePrefNotifier {
  BodyFontSizeNotifier()
      : super(key: PrefKeys.bodyFontSize, initial: 14.0); // ★ 修正
}


final groupedContextLinesProvider =
    NotifierProvider<GroupedContextLinesNotifier, double>(
  GroupedContextLinesNotifier.new,
);

class GroupedContextLinesNotifier extends DoublePrefNotifier {
  GroupedContextLinesNotifier()
      : super(key: PrefKeys.groupedContextLines, initial: 0.0);
}


final gutterFontSizeProvider =
    NotifierProvider<GutterFontSizeNotifier, double>(
  GutterFontSizeNotifier.new,
);

class GutterFontSizeNotifier extends DoublePrefNotifier {
  GutterFontSizeNotifier()
      : super(key: PrefKeys.gutterFontSize, initial: 11.0); // ★ 修正
}


final contextFontSizeProvider =
    NotifierProvider<ContextFontSizeNotifier, double>(
  ContextFontSizeNotifier.new,
);

class ContextFontSizeNotifier extends DoublePrefNotifier {
  ContextFontSizeNotifier()
      : super(key: PrefKeys.contextFontSize, initial: 10.0); // ★ 修正
}



final syncScrollProvider =
    NotifierProvider<SyncScrollNotifier, bool>(SyncScrollNotifier.new);

class SyncScrollNotifier extends BoolPrefNotifier {
  SyncScrollNotifier() : super(key: PrefKeys.syncScroll, initial: true);
}

class DiffPerfStats {
  const DiffPerfStats({
    required this.prepMs,
    required this.isolateRoundTripMs,
    required this.expandMs,
    required this.ansiMs,
    required this.splitMs,
    required this.encodeMs,
    required this.diffMs,
    required this.isolateExpandMs,
    required this.lineCount,
    required this.origLen,
    required this.modLen,
    required this.origLines,
    required this.modLines,
    required this.uniqueLines,
    required this.usedMyers,
    required this.workerDetails,
  });

  final int prepMs;
  final int isolateRoundTripMs;
  final int expandMs;
  final int ansiMs;
  final int splitMs;
  final int encodeMs;
  final int diffMs;
  final int isolateExpandMs;
  final int lineCount;
  final int origLen;
  final int modLen;
  final int origLines;
  final int modLines;
  final int uniqueLines;
  final bool usedMyers;
  final String workerDetails;

  String get oneLine =>
      'prep=$prepMs isolate=$isolateRoundTripMs expand=$expandMs '
      '| ansi=$ansiMs split=$splitMs encode=$encodeMs '
      'diffMain=$diffMs expandInIso=$isolateExpandMs '
      '| lineCount=$lineCount origLen=$origLen modLen=$modLen '
      '| origLines=$origLines modLines=$modLines '
      'uniqueLines=$uniqueLines myers=$usedMyers\n'
      '--- worker 内部 ---\n$workerDetails';
}

final lastDiffPerfProvider = StateProvider<DiffPerfStats?>((ref) => null);

// ==================== Diff 计算 ====================

typedef _DiffRequest = ({
  String original,
  String modified,
});

typedef _DiffPayload = ({
  List<(int, String)> entries,
  int ansiMs,
  int splitMs,
  int encodeMs,
  int diffMs,
  int expandMs,
  int origLines,
  int modLines,
  int uniqueLines,
  bool usedMyers,
  Map<String, Object> details,
});

int _dmpOpToIndex(int op) {
  if (op == DIFF_EQUAL) return DiffOperation.equal.index;
  if (op == DIFF_INSERT) return DiffOperation.insert.index;
  return DiffOperation.delete.index;
}

List<String> _splitLines(String text) {
  final out = <String>[];
  var start = 0;
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) == 0x0A) {
      out.add(text.substring(start, i));
      start = i + 1;
    }
  }
  if (start < text.length) {
    out.add(text.substring(start));
  }
  return out;
}

const int _puaLimit = 6000;

_DiffPayload _computeInWorker(_DiffRequest req) {
  final sw = Stopwatch()..start();

  final original = req.original;
  final modified = req.modified;

  if (original.isEmpty && modified.isEmpty) {
    return (
      entries: const <(int, String)>[],
      ansiMs: 0,
      splitMs: 0,
      encodeMs: 0,
      diffMs: 0,
      expandMs: 0,
      origLines: 0,
      modLines: 0,
      uniqueLines: 0,
      usedMyers: false,
      details: const <String, Object>{'说明': '两份文本都为空，未计算'},
    );
  }

  final swSplitA = Stopwatch()..start();
  final linesA = _splitLines(original);
  final splitAMs = swSplitA.elapsedMilliseconds;
  final swSplitB = Stopwatch()..start();
  final linesB = _splitLines(modified);
  final splitBMs = swSplitB.elapsedMilliseconds;
  final tSplit = sw.elapsedMilliseconds;

  final minLen =
      linesA.length < linesB.length ? linesA.length : linesB.length;

  var commonPrefix = 0;
  while (commonPrefix < minLen &&
      linesA[commonPrefix] == linesB[commonPrefix]) {
    commonPrefix++;
  }

  var commonSuffix = 0;
  final maxSuffix = minLen - commonPrefix;
  while (commonSuffix < maxSuffix &&
      linesA[linesA.length - 1 - commonSuffix] ==
          linesB[linesB.length - 1 - commonSuffix]) {
    commonSuffix++;
  }

  final midAStart = commonPrefix;
  final midAEnd = linesA.length - commonSuffix;
  final midBStart = commonPrefix;
  final midBEnd = linesB.length - commonSuffix;

  final mid = _diffMidLines(
    linesA,
    midAStart,
    midAEnd,
    linesB,
    midBStart,
    midBEnd,
  );
  // tEncode 对齐旧语义：「纯编码」完成时刻（不含 PUA 转码与算法主计算），
  // 这样 encodeMs / diffMs 两个统计口径与重构前完全一致。
  final tEncode =
      sw.elapsedMilliseconds - mid.puaEncodeMs - mid.algoCoreMs;
  final uniqueCount = mid.uniqueLines;
  final usedMyers = mid.usedMyers;
  final encAMs = mid.encAMs;
  final encBMs = mid.encBMs;
  final puaEncodeMs = mid.puaEncodeMs;
  final algoCoreMs = mid.algoCoreMs;

  final out = <(int, String)>[];
  for (var i = 0; i < commonPrefix; i++) {
    out.add((DiffOperation.equal.index, linesA[i]));
  }
  for (final (op, id) in mid.ops) {
    out.add((op, mid.idToLine[id]));
  }
  for (var i = linesA.length - commonSuffix; i < linesA.length; i++) {
    out.add((DiffOperation.equal.index, linesA[i]));
  }
  final tDiff = sw.elapsedMilliseconds;

  // 回传后这些 equal 行在清单页会被全部丢掉，这里把条数记下来，
  // 方便判断「白算了多少行」是不是等待时间的瓶颈。
  var equalCount = 0;
  var insertCount = 0;
  var deleteCount = 0;
  final tCount0 = sw.elapsedMilliseconds;
  for (final e in out) {
    final op = e.$1;
    if (op == DiffOperation.equal.index) {
      equalCount++;
    } else if (op == DiffOperation.insert.index) {
      insertCount++;
    } else {
      deleteCount++;
    }
  }
  final countOpsMs = sw.elapsedMilliseconds - tCount0;
  final tExpand = tDiff;

  final details = <String, Object>{
    '算法': usedMyers
        ? 'patience（唯一行多）'
        : 'PUA编码 + diff_match_patch（唯一行少）',
    'PUA分支阈值_唯一行数': _puaLimit,
    '左总行数': linesA.length,
    '右总行数': linesB.length,
    '开头相同行数_公共前缀': commonPrefix,
    '结尾相同行数_公共后缀': commonSuffix,
    '左参与diff行数_中间段': midAEnd - midAStart,
    '右参与diff行数_中间段': midBEnd - midBStart,
    '唯一行数': uniqueCount,
    '左拆行Ms': splitAMs,
    '右拆行Ms': splitBMs,
    '拆行合计Ms': tSplit,
    '左编码Ms': encAMs,
    '右编码Ms': encBMs,
    '编码合计Ms': tEncode - tSplit,
    'PUA编码Ms': puaEncodeMs,
    '算法主计算Ms': algoCoreMs,
    '构造输出合计Ms': tDiff - tEncode,
    '统计操作条数Ms': countOpsMs,
    '输出总条数': out.length,
    '相同行条数_equal': equalCount,
    '新增行条数_insert': insertCount,
    '删除行条数_delete': deleteCount,
    '后台内部耗时合计Ms': tDiff,
  };

  return (
    entries: out,
    ansiMs: 0,
    splitMs: tSplit,
    encodeMs: tEncode - tSplit,
    diffMs: tDiff - tEncode,
    expandMs: tExpand - tDiff,
    origLines: linesA.length,
    modLines: linesB.length,
    uniqueLines: uniqueCount,
    usedMyers: usedMyers,
    details: details,
  );
}

// ==================== 中段编码 + diff（两条路径共用） ====================

/// 去掉公共前后缀后，中间段的编码 + diff 结果。
typedef _MidDiff = ({
  /// 中段操作序列：(操作, 行 id)。行文本用 id 到 [idToLine] 里取。
  List<(int, int)> ops,

  /// id → 行文本。id 从 0 连续编号，所以用 List 而不是 Map，
  /// 省掉每行一次的哈希查找。
  List<String> idToLine,
  int uniqueLines,
  bool usedMyers,
  int encAMs,
  int encBMs,
  int puaEncodeMs,
  int algoCoreMs,
});

/// 把左右中段各行编成整数 id，然后按唯一行数选算法：
///   · 唯一行少 → PUA 编码 + diff_match_patch；
///   · 唯一行多 → 耐心 diff。
///
/// 完整对比和简洁对比都要做这一步，提出来共用。
_MidDiff _diffMidLines(
  List<String> linesA,
  int aStart,
  int aEnd,
  List<String> linesB,
  int bStart,
  int bEnd,
) {
  final sw = Stopwatch()..start();

  final lineToId = <String, int>{};
  final idToLine = <String>[]; // id 即下标

  List<int> encodeIds(List<String> lines, int start, int end) {
    final ids = <int>[];
    for (var i = start; i < end; i++) {
      final line = lines[i];
      var id = lineToId[line];
      if (id == null) {
        id = idToLine.length;
        lineToId[line] = id;
        idToLine.add(line);
      }
      ids.add(id);
    }
    return ids;
  }

  final tEncA0 = sw.elapsedMilliseconds;
  final idsA = encodeIds(linesA, aStart, aEnd);
  final encAMs = sw.elapsedMilliseconds - tEncA0;
  final tEncB0 = sw.elapsedMilliseconds;
  final idsB = encodeIds(linesB, bStart, bEnd);
  final encBMs = sw.elapsedMilliseconds - tEncB0;

  final uniqueCount = idToLine.length;
  final ops = <(int, int)>[];
  var usedMyers = false;
  var puaEncodeMs = 0;
  var algoCoreMs = 0;

  if (uniqueCount <= _puaLimit) {
    // 小唯一行数：用 diff_match_patch 的位运算加速（PUA 编码）。
    // id 从 0 连续编号，所以 PUA 码点直接就是 0xE000 + id，
    // 不再需要 idToCode / codeToLine 两张映射表（旧实现要建两个
    // 各几千项的 Map，还在每行做一次哈希查找）。
    final tPua0 = sw.elapsedMilliseconds;
    final sbA = StringBuffer();
    for (final id in idsA) {
      sbA.writeCharCode(0xE000 + id);
    }
    final sbB = StringBuffer();
    for (final id in idsB) {
      sbB.writeCharCode(0xE000 + id);
    }
    puaEncodeMs = sw.elapsedMilliseconds - tPua0;
    final dmp = DiffMatchPatch();
    final tDmp0 = sw.elapsedMilliseconds;
    final diffs = dmp.diff(sbA.toString(), sbB.toString());
    algoCoreMs = sw.elapsedMilliseconds - tDmp0;
    for (final d in diffs) {
      final opIndex = _dmpOpToIndex(d.operation);
      for (final rune in d.text.runes) {
        ops.add((opIndex, rune - 0xE000));
      }
    }
  } else {
    // 唯一行多（如小说全文）：用耐心 diff。
    // 它先找"两边都唯一"的行当锚点，把问题切成小块，速度快、
    // 内存低，且不像原始 Myers 那样差异一大就退化成"全部标红"。
    usedMyers = true;
    final tPat0 = sw.elapsedMilliseconds;
    final mid = _patienceDiff(idsA, idsB);
    algoCoreMs = sw.elapsedMilliseconds - tPat0;
    ops.addAll(mid);
  }

  return (
    ops: ops,
    idToLine: idToLine,
    uniqueLines: uniqueCount,
    usedMyers: usedMyers,
    encAMs: encAMs,
    encBMs: encBMs,
    puaEncodeMs: puaEncodeMs,
    algoCoreMs: algoCoreMs,
  );
}

// ==================== 耐心 diff ====================

/// 耐心 diff：先找"两边都只出现一次"的公共行当锚点，用锚点把问题
/// 切成小块。对小说这类几乎每行唯一的文本，比 Myers 快 100 倍。
List<(int, int)> _patienceDiff(List<int> a, List<int> b) {
  final out = <(int, int)>[];
  _patienceRec(a, 0, a.length, b, 0, b.length, out);
  return out;
}

void _patienceRec(
  List<int> a, int aLo, int aHi,
  List<int> b, int bLo, int bHi,
  List<(int, int)> out,
) {
  // 剥公共前缀
  while (aLo < aHi && bLo < bHi && a[aLo] == b[bLo]) {
    out.add((DiffOperation.equal.index, a[aLo]));
    aLo++;
    bLo++;
  }
  // 剥公共后缀
  var aEnd = aHi;
  var bEnd = bHi;
  while (aEnd > aLo && bEnd > bLo && a[aEnd - 1] == b[bEnd - 1]) {
    aEnd--;
    bEnd--;
  }

  if (aLo == aEnd) {
    for (var j = bLo; j < bEnd; j++) {
      out.add((DiffOperation.insert.index, b[j]));
    }
  } else if (bLo == bEnd) {
    for (var i = aLo; i < aEnd; i++) {
      out.add((DiffOperation.delete.index, a[i]));
    }
  } else if ((aEnd - aLo) + (bEnd - bLo) < 200) {
    // 区块足够小，直接 Myers，别折腾锚点
    _myersRec(a, aLo, aEnd, b, bLo, bEnd, out);
  } else {
    final anchors = _findUniqueAnchors(a, aLo, aEnd, b, bLo, bEnd);
    if (anchors.isEmpty) {
      // 这一块没有唯一行（重复段落），退回 Myers
      _myersRec(a, aLo, aEnd, b, bLo, bEnd, out);
    } else {
      var curA = aLo;
      var curB = bLo;
      for (final (ai, bi) in anchors) {
        _patienceRec(a, curA, ai, b, curB, bi, out);
        out.add((DiffOperation.equal.index, a[ai]));
        curA = ai + 1;
        curB = bi + 1;
      }
      _patienceRec(a, curA, aEnd, b, curB, bEnd, out);
    }
  }

  // 回填后缀
  for (var i = aEnd; i < aHi; i++) {
    out.add((DiffOperation.equal.index, a[i]));
  }
}

/// 找"两边都只出现一次"的公共行，用最长递增子序列挑出配对。
List<(int, int)> _findUniqueAnchors(
  List<int> a, int aLo, int aHi,
  List<int> b, int bLo, int bHi,
) {
  final aCount = <int, int>{};
  final aPos = <int, int>{};
  for (var i = aLo; i < aHi; i++) {
    final id = a[i];
    aCount[id] = (aCount[id] ?? 0) + 1;
    aPos[id] = i;
  }
  final bCount = <int, int>{};
  final bPos = <int, int>{};
  for (var i = bLo; i < bHi; i++) {
    final id = b[i];
    bCount[id] = (bCount[id] ?? 0) + 1;
    bPos[id] = i;
  }
  final candidates = <(int, int)>[];
  for (final id in aCount.keys) {
    if (aCount[id] == 1 && bCount[id] == 1) {
      candidates.add((aPos[id]!, bPos[id]!));
    }
  }
  if (candidates.isEmpty) return const [];
  candidates.sort((x, y) => x.$1.compareTo(y.$1));
  return _longestIncreasingSubsequence(candidates);
}

List<(int, int)> _longestIncreasingSubsequence(List<(int, int)> pairs) {
  final n = pairs.length;
  if (n == 0) return const [];
  final tails = <int>[];
  final prev = List<int>.filled(n, -1);
  for (var i = 0; i < n; i++) {
    final v = pairs[i].$2;
    var lo = 0, hi = tails.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (pairs[tails[mid]].$2 < v) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (lo > 0) prev[i] = tails[lo - 1];
    if (lo == tails.length) {
      tails.add(i);
    } else {
      tails[lo] = i;
    }
  }
  final res = <(int, int)>[];
  var k = tails.isEmpty ? -1 : tails.last;
  while (k >= 0) {
    res.add(pairs[k]);
    k = prev[k];
  }
  return res.reversed.toList();
}

// ==================== 线性空间 Myers（耐心 diff 的兜底） ====================

void _myersRec(
  List<int> a, int aStart, int aEnd,
  List<int> b, int bStart, int bEnd,
  List<(int, int)> out,
) {
  while (aStart < aEnd && bStart < bEnd && a[aStart] == b[bStart]) {
    out.add((DiffOperation.equal.index, a[aStart]));
    aStart++;
    bStart++;
  }
  var aSuf = aEnd;
  var bSuf = bEnd;
  while (aSuf > aStart && bSuf > bStart && a[aSuf - 1] == b[bSuf - 1]) {
    aSuf--;
    bSuf--;
  }

  if (aStart == aSuf) {
    for (var j = bStart; j < bSuf; j++) {
      out.add((DiffOperation.insert.index, b[j]));
    }
  } else if (bStart == bSuf) {
    for (var i = aStart; i < aSuf; i++) {
      out.add((DiffOperation.delete.index, a[i]));
    }
  } else {
    final mid = _myersFindMiddleSnake(a, aStart, aSuf, b, bStart, bSuf);
    _myersRec(a, aStart, mid.$1, b, bStart, mid.$2, out);
    _myersRec(a, mid.$1, aSuf, b, mid.$2, bSuf, out);
  }

  for (var i = aSuf; i < aEnd; i++) {
    out.add((DiffOperation.equal.index, a[i]));
  }
}

(int, int) _myersFindMiddleSnake(
  List<int> a, int aStart, int aEnd,
  List<int> b, int bStart, int bEnd,
) {
  final n = aEnd - aStart;
  final m = bEnd - bStart;
  final delta = n - m;
  final deltaIsOdd = delta.abs() % 2 == 1;
  final maxD = (n + m + 1) ~/ 2;
  final offset = maxD;
  final size = 2 * maxD + 1;
  final vf = List<int>.filled(size, 0);
  final vb = List<int>.filled(size, 0);

  for (var d = 0; d <= maxD; d++) {
    for (var k = -d; k <= d; k += 2) {
      int x;
      if (k == -d ||
          (k != d && vf[offset + k - 1] < vf[offset + k + 1])) {
        x = vf[offset + k + 1];
      } else {
        x = vf[offset + k - 1] + 1;
      }
      var y = x - k;
      while (x < n && y < m && a[aStart + x] == b[bStart + y]) {
        x++;
        y++;
      }
      vf[offset + k] = x;
      if (deltaIsOdd) {
        final bK = delta - k;
        if (bK >= -d + 1 && bK <= d - 1) {
          if (vf[offset + k] + vb[offset + bK] >= n) {
            return (aStart + x, bStart + y);
          }
        }
      }
    }
    for (var k = -d; k <= d; k += 2) {
      int x;
      if (k == -d ||
          (k != d && vb[offset + k - 1] < vb[offset + k + 1])) {
        x = vb[offset + k + 1];
      } else {
        x = vb[offset + k - 1] + 1;
      }
      var y = x - k;
      while (x < n && y < m && a[aEnd - 1 - x] == b[bEnd - 1 - y]) {
        x++;
        y++;
      }
      vb[offset + k] = x;
      if (!deltaIsOdd) {
        final fK = delta - k;
        if (fK >= -d && fK <= d) {
          if (vb[offset + k] + vf[offset + fK] >= n) {
            final fx = vf[offset + fK];
            final fy = fx - fK;
            return (aStart + fx, bStart + fy);
          }
        }
      }
    }
  }
  return ((aStart + aEnd) ~/ 2, (bStart + bEnd) ~/ 2);
}

// ==================== 组装 DiffEntry ====================

DiffEntry _mkEntry(DiffOperation op, String line) {
  switch (op) {
    case DiffOperation.equal:
      return DiffEntry(operation: op, text: line);
    case DiffOperation.insert:
      return DiffEntry(operation: op, text: line, newText: line);
    case DiffOperation.delete:
      return DiffEntry(operation: op, text: line, oldText: line);
    case DiffOperation.replace:
      return DiffEntry(operation: op, text: line);
  }
}

/// 对比页「读盘 / 解析」阶段的文案。
///
/// 从文件浏览器点「对比」后，会把所有重活都留在对比页里做，全程只显示
/// 对比页自己的表情动画（不再先弹一个灰底空心转圈对话框）。这个 provider
/// 就是那段时间里唯一的信息来源：
///   · 非 null → 对比页只显示表情加载页，文案就是这里的字符串；
///   · null    → 读盘解析已结束，交给 [diffResultProvider] 自己算差异。
final compareLoadStageProvider = StateProvider<String?>((ref) => null);

/// 读盘 / 解析失败时的提示。
///
/// 以前失败是直接把对话框 pop 掉再 toast，现在没有对话框可 pop，
/// 就把错误交给对比页显示成错误页，让用户自己决定要不要返回。
final compareLoadErrorProvider = StateProvider<String?>((ref) => null);

/// 进入对比页前先清一遍加载状态。
///
/// 导入页、分享接管这些入口不经过文件浏览器的读盘流程，如果上一次对比
/// 被中途打断留下了阶段文案，不清掉会卡在一个永远不结束的加载页上。
void resetCompareLoadState(WidgetRef ref) {
  ref.read(compareLoadStageProvider.notifier).state = null;
  ref.read(compareLoadErrorProvider.notifier).state = null;
}

final diffResultProvider = FutureProvider.autoDispose<DiffResult?>((ref) async {
  final sw = Stopwatch()..start();
  final log = CompareTimingLog.instance;

  final original = ref.watch(preprocessedOriginalProvider);
  final modified = ref.watch(preprocessedModifiedProvider);
  if (original.isEmpty || modified.isEmpty) {
    log.param('diff/跳过原因', '预处理后有一侧为空');
    return null;
  }

  ref.watch(importRevisionProvider);

  final tPrep = sw.elapsedMilliseconds;
  log.section('后台 diff 计算（UI isolate 视角）');
  log.param('diff/左预处理后字符数', original.length);
  log.param('diff/右预处理后字符数', modified.length);
  log.mark('两份预处理文本就绪（这一步含规则管线执行）');

  final payload = await compute(
    _computeInWorker,
    (
      original: original,
      modified: modified,
    ),
  );
  final tIsolate = sw.elapsedMilliseconds;
  log.mark('后台 isolate 返回（含参数序列化与结果回传）');
  log.param('diff/isolate 往返总Ms', tIsolate - tPrep);
  log.param('diff/后台内部净耗时Ms', payload.diffMs + payload.splitMs + payload.encodeMs);
  log.param(
      'diff/序列化与线程调度估算Ms',
      (tIsolate - tPrep) -
          payload.splitMs -
          payload.encodeMs -
          payload.diffMs -
          payload.expandMs);
  log.section('后台 worker 内部分段');
  for (final e in payload.details.entries) {
    log.param('worker/${e.key}', e.value);
  }

  final entries = log.measure<List<DiffEntry>>(
    '主线程逐条构造 DiffEntry（共 ${payload.entries.length} 条）',
    () => <DiffEntry>[
      for (final (opIndex, line) in payload.entries)
        _mkEntry(DiffOperation.values[opIndex], line),
    ],
  );
  final tExpand = sw.elapsedMilliseconds;
  log.mark('主线程构造对象完成');

  final detailText =
      payload.details.entries.map((e) => '  ${e.key} = ${e.value}').join('\n');
  log.param('diff/最终 entries 条数', entries.length);
  log.param('diff/主线程构造对象Ms', tExpand - tIsolate);

  ref.read(lastDiffPerfProvider.notifier).state = DiffPerfStats(
    prepMs: tPrep,
    isolateRoundTripMs: tIsolate - tPrep,
    expandMs: tExpand - tIsolate,
    ansiMs: payload.ansiMs,
    splitMs: payload.splitMs,
    encodeMs: payload.encodeMs,
    diffMs: payload.diffMs,
    isolateExpandMs: payload.expandMs,
    lineCount: payload.entries.length,
    origLen: original.length,
    modLen: modified.length,
    origLines: payload.origLines,
    modLines: payload.modLines,
    uniqueLines: payload.uniqueLines,
    usedMyers: payload.usedMyers,
    workerDetails: detailText,
  );

  return DiffResult(entries: entries, engineType: DiffEngineType.line);
});

// ==================== 差异颜色（持久化） ====================

class ColorPrefNotifier extends PersistentNotifier<Color> {
  ColorPrefNotifier({required this.key, required Color initial})
      : _initial = initial;

  @override
  final String key;
  final Color _initial;

  @override
  Color get defaultValue => _initial;

  @override
  Color decode(String raw) {
    final c = hexToColor(raw);
    if (c == null) throw const FormatException('Invalid color string');
    return c;
  }

  @override
  String encode(Color value) => colorToHex(value);
}

final deleteRowBgProvider =
    NotifierProvider<DeleteRowBgNotifier, Color>(DeleteRowBgNotifier.new);

class DeleteRowBgNotifier extends ColorPrefNotifier {
  DeleteRowBgNotifier()
      : super(
          key: PrefKeys.colorDeleteRowBg,
          initial: const Color(0xFFFFC0BF),
        );
}

final deleteRowFgProvider =
    NotifierProvider<DeleteRowFgNotifier, Color>(DeleteRowFgNotifier.new);

class DeleteRowFgNotifier extends ColorPrefNotifier {
  DeleteRowFgNotifier()
      : super(
          key: PrefKeys.colorDeleteRowFg,
          initial: const Color(0xFF000000),
        );
}

final insertRowBgProvider =
    NotifierProvider<InsertRowBgNotifier, Color>(InsertRowBgNotifier.new);

class InsertRowBgNotifier extends ColorPrefNotifier {
  InsertRowBgNotifier()
      : super(
          key: PrefKeys.colorInsertRowBg,
          initial: const Color(0xFFC2FFBF),
        );
}

final insertRowFgProvider =
    NotifierProvider<InsertRowFgNotifier, Color>(InsertRowFgNotifier.new);

class InsertRowFgNotifier extends ColorPrefNotifier {
  InsertRowFgNotifier()
      : super(
          key: PrefKeys.colorInsertRowFg,
          initial: const Color(0xFF000000),
        );
}

final replaceLeftBgProvider =
    NotifierProvider<ReplaceLeftBgNotifier, Color>(
  ReplaceLeftBgNotifier.new,
);

class ReplaceLeftBgNotifier extends ColorPrefNotifier {
  ReplaceLeftBgNotifier()
      : super(
          key: PrefKeys.colorReplaceLeftBg,
          initial: const Color(0xFFFFEEEF),
        );
}

final replaceLeftFgProvider =
    NotifierProvider<ReplaceLeftFgNotifier, Color>(
  ReplaceLeftFgNotifier.new,
);

class ReplaceLeftFgNotifier extends ColorPrefNotifier {
  ReplaceLeftFgNotifier()
      : super(
          key: PrefKeys.colorReplaceLeftFg,
          initial: const Color(0xFF000000),
        );
}

final replaceRightBgProvider =
    NotifierProvider<ReplaceRightBgNotifier, Color>(
  ReplaceRightBgNotifier.new,
);

class ReplaceRightBgNotifier extends ColorPrefNotifier {
  ReplaceRightBgNotifier()
      : super(
          key: PrefKeys.colorReplaceRightBg,
          initial: const Color(0xFFE7FFEE),
        );
}

final replaceRightFgProvider =
    NotifierProvider<ReplaceRightFgNotifier, Color>(
  ReplaceRightFgNotifier.new,
);

class ReplaceRightFgNotifier extends ColorPrefNotifier {
  ReplaceRightFgNotifier()
      : super(
          key: PrefKeys.colorReplaceRightFg,
          initial: const Color(0xFF000000),
        );
}

final charDeleteBgProvider =
    NotifierProvider<CharDeleteBgNotifier, Color>(CharDeleteBgNotifier.new);

class CharDeleteBgNotifier extends ColorPrefNotifier {
  CharDeleteBgNotifier()
      : super(
          key: PrefKeys.colorCharDeleteBg,
          initial: const Color(0xFFB71C1C),
        );
}

final charDeleteFgProvider =
    NotifierProvider<CharDeleteFgNotifier, Color>(CharDeleteFgNotifier.new);

class CharDeleteFgNotifier extends ColorPrefNotifier {
  CharDeleteFgNotifier()
      : super(
          key: PrefKeys.colorCharDeleteFg,
          initial: const Color(0xFFFFFFFF),
        );
}

final charInsertBgProvider =
    NotifierProvider<CharInsertBgNotifier, Color>(CharInsertBgNotifier.new);

class CharInsertBgNotifier extends ColorPrefNotifier {
  CharInsertBgNotifier()
      : super(
          key: PrefKeys.colorCharInsertBg,
          initial: const Color(0xFF007709),
        );
}

final charInsertFgProvider =
    NotifierProvider<CharInsertFgNotifier, Color>(CharInsertFgNotifier.new);

class CharInsertFgNotifier extends ColorPrefNotifier {
  CharInsertFgNotifier()
      : super(
          key: PrefKeys.colorCharInsertFg,
          initial: const Color(0xFFFFFFFF),
        );
}

typedef DiffColors = ({
  Color deleteRowBg,
  Color deleteRowFg,
  Color insertRowBg,
  Color insertRowFg,
  Color replaceLeftBg,
  Color replaceLeftFg,
  Color replaceRightBg,
  Color replaceRightFg,
  Color charDeleteBg,
  Color charDeleteFg,
  Color charInsertBg,
  Color charInsertFg,
});

DiffColors watchDiffColors(WidgetRef ref) => (
      deleteRowBg: ref.watch(deleteRowBgProvider),
      deleteRowFg: ref.watch(deleteRowFgProvider),
      insertRowBg: ref.watch(insertRowBgProvider),
      insertRowFg: ref.watch(insertRowFgProvider),
      replaceLeftBg: ref.watch(replaceLeftBgProvider),
      replaceLeftFg: ref.watch(replaceLeftFgProvider),
      replaceRightBg: ref.watch(replaceRightBgProvider),
      replaceRightFg: ref.watch(replaceRightFgProvider),
      charDeleteBg: ref.watch(charDeleteBgProvider),
      charDeleteFg: ref.watch(charDeleteFgProvider),
      charInsertBg: ref.watch(charInsertBgProvider),
      charInsertFg: ref.watch(charInsertFgProvider),
    );

String colorToHex(Color c) {
  final v = c.toARGB32() & 0xFFFFFF;
  return '#${v.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

Color? hexToColor(String s) {
  if (s.length != 7 || !s.startsWith('#')) return null;
  final v = int.tryParse(s.substring(1), radix: 16);
  if (v == null) return null;
  return Color(0xFF000000 | v);
}

// ==================== 查找历史（持久化） ====================

/// 上限 50 条，去重（最新在前）。
final findHistoryProvider =
    NotifierProvider<FindHistoryNotifier, List<String>>(
  FindHistoryNotifier.new,
);

class FindHistoryNotifier extends StringListPrefNotifier {
  FindHistoryNotifier() : super(key: PrefKeys.findHistory);

  static const int _max = 50;

  /// 记住一条。空串跳过；重复的挪到最前。
  void add(String q) {
    if (q.trim().isEmpty) return;
    final next = <String>[q, ...state.where((s) => s != q)];
    if (next.length > _max) next.removeRange(_max, next.length);
    update(next);
  }

  void remove(String q) {
    update(state.where((s) => s != q).toList());
  }
}


/// 悬浮下翻页按钮：是否显示。
final floatingPageDownEnabledProvider =
    NotifierProvider<FloatingPageDownEnabledNotifier, bool>(
  FloatingPageDownEnabledNotifier.new,
);

class FloatingPageDownEnabledNotifier extends BoolPrefNotifier {
  FloatingPageDownEnabledNotifier()
      : super(key: 'jianming.viewer.floatingPageDown', initial: false);
}


final floatingPageDownXProvider =
    NotifierProvider<FloatingPageDownXNotifier, double>(
  FloatingPageDownXNotifier.new,
);

class FloatingPageDownXNotifier extends DoublePrefNotifier {
  FloatingPageDownXNotifier()
      : super(key: 'jianming.viewer.floatingPageDown.x', initial: 75.0);
}

final floatingPageDownYProvider =
    NotifierProvider<FloatingPageDownYNotifier, double>(
  FloatingPageDownYNotifier.new,
);

class FloatingPageDownYNotifier extends DoublePrefNotifier {
  FloatingPageDownYNotifier()
      : super(key: 'jianming.viewer.floatingPageDown.y', initial: 58.0);
}

final floatingPageDownSizeProvider =
    NotifierProvider<FloatingPageDownSizeNotifier, double>(
  FloatingPageDownSizeNotifier.new,
);

class FloatingPageDownSizeNotifier extends DoublePrefNotifier {
  FloatingPageDownSizeNotifier()
      : super(key: 'jianming.viewer.floatingPageDown.size', initial: 110.0);
}

final floatingPageDownOpacityProvider =
    NotifierProvider<FloatingPageDownOpacityNotifier, double>(
  FloatingPageDownOpacityNotifier.new,
);

class FloatingPageDownOpacityNotifier extends DoublePrefNotifier {
  FloatingPageDownOpacityNotifier()
      : super(key: 'jianming.viewer.floatingPageDown.opacity', initial: 60.0);
}

final floatingPageDownBorderWidthProvider =
    NotifierProvider<FloatingPageDownBorderWidthNotifier, double>(
  FloatingPageDownBorderWidthNotifier.new,
);

class FloatingPageDownBorderWidthNotifier extends DoublePrefNotifier {
  FloatingPageDownBorderWidthNotifier()
      : super(
          key: 'jianming.viewer.floatingPageDown.borderWidth',
          initial: 2.0,
        );
}

final floatingPageDownColorProvider =
    NotifierProvider<FloatingPageDownColorNotifier, Color>(
  FloatingPageDownColorNotifier.new,
);

class FloatingPageDownColorNotifier extends ColorPrefNotifier {
  FloatingPageDownColorNotifier()
      : super(
          key: 'jianming.viewer.floatingPageDown.color',
          initial: const Color(0xFFD4D4DC),
        );
}

final groupedRestoreOffsetProvider = StateProvider<double?>((ref) => null);



// ==================== 悬浮上翻页按钮 ====================

/// 悬浮上翻页按钮：是否显示。
final floatingPageUpEnabledProvider =
    NotifierProvider<FloatingPageUpEnabledNotifier, bool>(
  FloatingPageUpEnabledNotifier.new,
);

class FloatingPageUpEnabledNotifier extends BoolPrefNotifier {
  FloatingPageUpEnabledNotifier()
      : super(key: 'jianming.viewer.floatingPageUp', initial: false);
}

final floatingPageUpXProvider =
    NotifierProvider<FloatingPageUpXNotifier, double>(
  FloatingPageUpXNotifier.new,
);

class FloatingPageUpXNotifier extends DoublePrefNotifier {
  FloatingPageUpXNotifier()
      : super(key: 'jianming.viewer.floatingPageUp.x', initial: 75.0);
}

final floatingPageUpYProvider =
    NotifierProvider<FloatingPageUpYNotifier, double>(
  FloatingPageUpYNotifier.new,
);

class FloatingPageUpYNotifier extends DoublePrefNotifier {
  // 默认放在下翻页按钮上方，免得两个按钮一开始就叠在一起。
  FloatingPageUpYNotifier()
      : super(key: 'jianming.viewer.floatingPageUp.y', initial: 42.0);
}

final floatingPageUpSizeProvider =
    NotifierProvider<FloatingPageUpSizeNotifier, double>(
  FloatingPageUpSizeNotifier.new,
);

class FloatingPageUpSizeNotifier extends DoublePrefNotifier {
  FloatingPageUpSizeNotifier()
      : super(key: 'jianming.viewer.floatingPageUp.size', initial: 110.0);
}

final floatingPageUpOpacityProvider =
    NotifierProvider<FloatingPageUpOpacityNotifier, double>(
  FloatingPageUpOpacityNotifier.new,
);

class FloatingPageUpOpacityNotifier extends DoublePrefNotifier {
  FloatingPageUpOpacityNotifier()
      : super(key: 'jianming.viewer.floatingPageUp.opacity', initial: 60.0);
}

final floatingPageUpBorderWidthProvider =
    NotifierProvider<FloatingPageUpBorderWidthNotifier, double>(
  FloatingPageUpBorderWidthNotifier.new,
);

class FloatingPageUpBorderWidthNotifier extends DoublePrefNotifier {
  FloatingPageUpBorderWidthNotifier()
      : super(
          key: 'jianming.viewer.floatingPageUp.borderWidth',
          initial: 2.0,
        );
}

final floatingPageUpColorProvider =
    NotifierProvider<FloatingPageUpColorNotifier, Color>(
  FloatingPageUpColorNotifier.new,
);

class FloatingPageUpColorNotifier extends ColorPrefNotifier {
  FloatingPageUpColorNotifier()
      : super(
          key: 'jianming.viewer.floatingPageUp.color',
          initial: const Color(0xFFD4D4DC),
        );
}

// ==================== 工具栏显示开关（持久化） ====================

final toolbarVisibleProvider =
    NotifierProvider<ToolbarVisibleNotifier, bool>(
  ToolbarVisibleNotifier.new,
);

class ToolbarVisibleNotifier extends BoolPrefNotifier {
  ToolbarVisibleNotifier()
      : super(key: 'jianming.viewer.toolbarVisible', initial: true);
}
