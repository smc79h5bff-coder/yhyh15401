// diff_list_page.dart
//
// 简洁对比 / 差异清单页（轻量视图）。
//
// 只列有差异的块：一行一条，用「左：」「右：」文字前缀区分来源，
// 不使用整行红/绿底色。默认不做逐字高亮、不折叠。
// 相同行完全不渲染（导出 txt 时会写成一行提示）。
//
// 顶部两个「两头开关」并排一行：上下｜左右、行差异｜字差异。
// 上下结构：长行不折行、不截断，整块共用一个横向滚动区，
// 左行右行一起平移（同步滚动），一个字都不丢。
// 左右结构：两列各自按列宽折行，一字不丢；差异块没有外框 / 卡片，
// 只留一条贯穿的中间竖线 + 块底一条横线。
//
// 数据来源就是 diffResultProvider：worker 给每条 entry 自带行文本，
// 所以这个页面不需要再把两份全文各 split('\n') 一次，也不需要建两万行
// 的数组，只有差异段的行文本才会分配内存。整页只遍历 entries 一遍。
//
// 渲染用 ListView.builder 懒加载；逐字高亮是可选开关，默认关闭。

import 'dart:convert';
import 'dart:typed_data';

import 'package:diff_match_patch/diff_match_patch.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/debug/compare_timing_log.dart';
import '../../../core/debug/diagnostics.dart';
import '../../../core/storage/persistent_notifier.dart';
import '../../../core/storage/pref_keys.dart';
import '../../diff/domain/diff_operation.dart';
import '../../diff/domain/diff_result.dart';
import '../../import/presentation/providers/import_providers.dart';
import 'providers/diff_viewer_providers.dart';

// ==================== 字号设置 ====================

/// 简洁对比页「差异正文」的字号，存在本地（默认 13，范围 11~20）。
/// 复用现成的 DoublePrefNotifier：改值同时刷新内存 + 写磁盘，下次进来还记得。
/// 只影响这一页的正文，不牵连完整对比页 / 阅读页。
final diffListFontSizeProvider =
    NotifierProvider<DoublePrefNotifier, double>(
  () => DoublePrefNotifier(key: PrefKeys.diffListFontSize, initial: 13),
);

// ==================== 数据 ====================

// 类型是相对的：deleted = 这几行只在 A 文件里有（A 独有）；
// inserted = 只在 B 文件里有（B 独有）；modified = 两边都有但内容不同。
enum _DiffListKind { deleted, inserted, modified }

class _DiffListItem {
  const _DiffListItem.change({
    required this.kind,
    required this.leftStart,
    required this.leftEnd,
    required this.rightStart,
    required this.rightEnd,
    required this.leftLines,
    required this.rightLines,
  })  : isGap = false,
        gapLines = 0;

  const _DiffListItem.gap(this.gapLines)
      : isGap = true,
        kind = _DiffListKind.modified,
        leftStart = 0,
        leftEnd = 0,
        rightStart = 0,
        rightEnd = 0,
        leftLines = const [],
        rightLines = const [];

  final bool isGap;
  final int gapLines;
  final _DiffListKind kind;
  final int leftStart;
  final int leftEnd;
  final int rightStart;
  final int rightEnd;
  final List<String> leftLines;
  final List<String> rightLines;
}

/// 遍历 diff.entries 一遍，产出「差异块 + 相同行间隔」的清单。
///
/// 关键：worker 已经在每条 entry 里带上了那一行的文本
/// （equal / delete 属 A，insert 属 B，replace 两边都有），
/// 所以这里不再对两份全文各 split('\n') 一次，也不建两万行的行数组，
/// 只有差异段的行文本才会被分配内存。相同行只累计一个行数。
List<_DiffListItem> _buildListItems(DiffResult diff) {
  const int maxLinesPerBlock = 4000; // 防御：异常超大块切成多块，内容不丢
  final items = <_DiffListItem>[];
  var gap = 0;
  var left = <String>[];
  var right = <String>[];

  void flushGap() {
    if (gap > 0) {
      items.add(_DiffListItem.gap(gap));
      gap = 0;
    }
  }

  void flushBlock() {
    if (left.isEmpty && right.isEmpty) return;
    final kind = left.isNotEmpty && right.isNotEmpty
        ? _DiffListKind.modified
        : left.isNotEmpty
            ? _DiffListKind.deleted
            : _DiffListKind.inserted;
    // 行号不再展示（预处理删过空行，行号对不上原文件），
    // 这几个字段只为兼容数据结构，填块内相对行数即可。
    items.add(_DiffListItem.change(
      kind: kind,
      leftStart: 0,
      leftEnd: left.length,
      rightStart: 0,
      rightEnd: right.length,
      leftLines: left,
      rightLines: right,
    ));
    left = <String>[];
    right = <String>[];
  }

  for (final e in diff.entries) {
    switch (e.operation) {
      case DiffOperation.equal:
        flushBlock();
        // diff 判定为 equal，两边必然是同一行文本，直接算作相同行。
        gap++;
        break;
      case DiffOperation.delete:
        flushGap();
        left.add(e.oldText.isNotEmpty ? e.oldText : e.text);
        break;
      case DiffOperation.insert:
        flushGap();
        right.add(e.newText.isNotEmpty ? e.newText : e.text);
        break;
      case DiffOperation.replace:
        flushGap();
        left.add(e.oldText.isNotEmpty ? e.oldText : e.text);
        right.add(e.newText.isNotEmpty ? e.newText : e.text);
        break;
    }
    // 只切块，不丢行：超大块拆成几个块继续全量展开。
    if (left.length + right.length >= maxLinesPerBlock) flushBlock();
  }
  flushBlock();
  return items;
}

// ==================== 页面 ====================

class DiffListPage extends ConsumerStatefulWidget {
  const DiffListPage({super.key});

  @override
  ConsumerState<DiffListPage> createState() => _DiffListPageState();
}

class _DiffListPageState extends ConsumerState<DiffListPage> {
  List<_DiffListItem>? _items;
  Object? _itemsForDiff; // diff 结果换了就重算，避免显示上一次的旧数据
  bool _exporting = false;
  bool _sideBySide = false; // 左右对照开关
  bool _charHighlight = false; // 高亮具体差异开关（逐字，开销大默认关）
  bool _diagEnded = false; // 首帧计时只收尾一次
  double _bodyFontSize = 13; // 差异正文字号，由 provider 在 build 里更新

  // 逐字高亮的防御上限：超长的行、超多的行对不跑 dmp，退回纯文字。
  static const int _kCharHighlightMaxLineChars = 1000;
  static const int _kCharHighlightMaxPairsPerBlock = 200;

  String _kindLabel(_DiffListKind k) {
    switch (k) {
      case _DiffListKind.deleted:
        return 'A 独有';
      case _DiffListKind.inserted:
        return 'B 独有';
      case _DiffListKind.modified:
        return '修改';
    }
  }

  /// 页面数据：只要差异块，相同行间隔完全不渲染（也不占 ListView 的 item）。
  List<_DiffListItem> _computeItems(DiffResult diff) => _buildListItems(diff)
      .where((it) => !it.isGap)
      .toList(growable: false);

  Future<void> _export() async {
    final diff = ref.read(diffResultProvider).value;
    if (diff == null) return;
    final leftName = ref.read(originalFileNameProvider) ?? '原文件';
    final rightName = ref.read(modifiedFileNameProvider) ?? '修改版';

    setState(() => _exporting = true);
    try {
      final raw = _buildListItems(diff);
      final buf = StringBuffer();
      buf.writeln('A：$leftName');
      buf.writeln('B：$rightName');
      buf.writeln('差异块数：${raw.where((it) => !it.isGap).length}');
      buf.writeln();
      for (final it in raw) {
        if (it.isGap) {
          buf.writeln('—— 中间相同 ${it.gapLines} 行，已省略 ——');
          buf.writeln();
          continue;
        }
        buf.writeln('【${_kindLabel(it.kind)}】');
        for (final l in it.leftLines) {
          buf.writeln('左：$l');
        }
        for (final l in it.rightLines) {
          buf.writeln('右：$l');
        }
        buf.writeln();
      }
      final bytes = Uint8List.fromList(utf8.encode(buf.toString()));
      final out = await FilePicker.saveFile(
        fileName: 'diff-list-${DateTime.now().millisecondsSinceEpoch}.txt',
        bytes: bytes,
        mimeType: 'text/plain',
        dialogTitle: '导出差异清单',
        type: FileType.custom,
        allowedExtensions: ['txt'],
      );
      if (out != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('差异清单已导出')),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// 右上角「Aa」点开的字号面板：滑块 + 实时预览 + 一键回默认。
  /// 拖动时直接改 provider，页面和预览同时变；松手值已经写进本地设置。
  Future<void> _openFontSizeSheet() async {
    var value = _bodyFontSize;
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final cs = Theme.of(ctx).colorScheme;
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const Text('字号',
                            style: TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w600)),
                        const Spacer(),
                        Text(value.toStringAsFixed(0),
                            style: TextStyle(fontSize: 14, color: cs.primary)),
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: () {
                            const reset = 13.0;
                            setSheetState(() => value = reset);
                            ref
                                .read(diffListFontSizeProvider.notifier)
                                .update(reset);
                          },
                          child: const Text('默认'),
                        ),
                      ],
                    ),
                    Slider(
                      min: 11.0,
                      max: 20.0,
                      divisions: 9,
                      value: value.clamp(11.0, 20.0).toDouble(),
                      label: value.toStringAsFixed(0),
                      onChanged: (v) {
                        setSheetState(() => value = v);
                        ref
                            .read(diffListFontSizeProvider.notifier)
                            .update(v);
                      },
                    ),
                    const Row(
                      children: [
                        Text('11', style: TextStyle(fontSize: 11)),
                        Spacer(),
                        Text('20', style: TextStyle(fontSize: 11)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '左：这一行是字号预览，拖动上面滑块看变化',
                      style: TextStyle(fontSize: value, color: cs.onSurface),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final log = CompareTimingLog.instance;
    // 在 build 里读一次存到字段，行渲染方法直接读字段，
    // 避免在 ListView.itemBuilder 回调里调 ref.watch（Riverpod 不允许）。
    _bodyFontSize =
        ref.watch(diffListFontSizeProvider).clamp(11.0, 20.0).toDouble();
    final diffAsync = ref.watch(diffResultProvider);
    final diff = diffAsync.value;

    // 设备 / 页面参数只写一次，避免每次 build 重复刷屏。
    if (!_diagEnded && log.active) {
      final mq = MediaQuery.of(context);
      log.env(
          '屏幕逻辑宽高',
          '${mq.size.width.toStringAsFixed(1)} x ${mq.size.height.toStringAsFixed(1)}');
      log.env('设备像素比', mq.devicePixelRatio);
      log.env(
          '屏幕物理像素',
          '${(mq.size.width * mq.devicePixelRatio).toStringAsFixed(0)} x '
              '${(mq.size.height * mq.devicePixelRatio).toStringAsFixed(0)}');
      log.env('顶部安全区', mq.padding.top);
      log.env('底部安全区', mq.padding.bottom);
      log.env('清单正文字号', _bodyFontSize);
      log.env('上下 / 左右结构', _sideBySide ? '左右对照' : '上下结构');
      log.env('行差异 / 字差异', _charHighlight ? '字差异' : '行差异');
    }

    Widget body;
    if (diffAsync.hasError) {
      log.fail('diffResultProvider 报错：${diffAsync.error}');
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('对比失败：${diffAsync.error}'),
        ),
      );
    } else if (diff == null) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      // 只在 diff 结果真的换了时重算；切开关等 setState 不重复遍历 entries。
      List<_DiffListItem> items;
      if (_items == null || !identical(_itemsForDiff, diff)) {
        items = log.measure<List<_DiffListItem>>(
          '清单页遍历 entries 构建差异块',
          () => _computeItems(diff),
        );
        _items = items;
        _itemsForDiff = diff;
        var diffLines = 0;
        for (final it in items) {
          diffLines += it.leftLines.length + it.rightLines.length;
        }
        log.param('清单/差异块数', items.length);
        log.param('清单/差异行数', diffLines);
        log.param('清单/收到的 entries 总条数', diff.entries.length);
        log.param('清单/被丢掉的相同行条数', diff.entries.length - diffLines);
        log.mark('清单数据构建完成');
      } else {
        items = _items!;
      }
      if (items.isEmpty) {
        body = const Center(child: Text('两个文件没有差异'));
      } else {
        // index 0 是头部（开关一行 + A/B 文件卡），随列表一起滚动。
        body = ListView.builder(
          itemCount: items.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) return _buildHeader(context);
            return _buildRow(context, items[index - 1]);
          },
        );
      }

      // 首帧真正画完之后收尾，这样「总耗时」= 从点按钮到看见内容。
      if (!_diagEnded && log.active) {
        _diagEnded = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          log.mark('差异清单首帧绘制完成');
          log.end('简洁对比 · 从点击到内容可见');
        });
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('差异清单'),
        actions: [
          // 诊断关掉时没有日志可复制，直接把入口藏起来。
          if (Diagnostics.enabled)
            IconButton(
              icon: const Icon(Icons.content_copy),
              tooltip: '复制全量耗时日志',
              onPressed: _copyTiming,
            ),
          IconButton(
            icon: const Icon(Icons.format_size),
            tooltip: '字号',
            onPressed: _openFontSizeSheet,
          ),
          IconButton(
            icon: _exporting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.ios_share),
            tooltip: '导出差异清单为 txt',
            onPressed: _exporting ? null : _export,
          ),
        ],
      ),
      body: body,
    );
  }

  /// 一键复制：把这次对比的全链路耗时 + 全部参数写进剪贴板。
  Future<void> _copyTiming() async {
    final text = CompareTimingLog.instance.dump();
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制耗时日志（${text.length} 字）')),
    );
  }

  // ==================== 头部：开关一行 + A/B 文件卡 ====================

  Widget _buildHeader(BuildContext context) {
    final leftName = ref.watch(originalFileNameProvider) ?? '原文件';
    final rightName = ref.watch(modifiedFileNameProvider) ?? '修改版';

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
      child: Column(
        children: [
          // 两个「两头开关」并排一行，不占第二行。
          // 滑块靠左 = 上下结构 / 行差异，靠右 = 左右对照 / 字差异。
          Row(
            children: [
              Expanded(
                child: _twoEndSwitch(
                  context,
                  leftLabel: '上下',
                  rightLabel: '左右',
                  value: _sideBySide,
                  onChanged: (v) => setState(() => _sideBySide = v),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _twoEndSwitch(
                  context,
                  leftLabel: '行差异',
                  rightLabel: '字差异',
                  value: _charHighlight,
                  onChanged: (v) => setState(() => _charHighlight = v),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // A/B 文件卡跟随「左右对照」开关：关 = 上下两行，开 = 左右两列。
          // 它是列表第 0 项的一部分，上滑会跟列表一起滚走。
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: Theme.of(context)
                  .colorScheme
                  .surfaceContainerHighest
                  .withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(8),
            ),
            child: _sideBySide
                ? _fileCardSideBySide(context, leftName, rightName)
                : _fileCardStacked(context, leftName, rightName),
          ),
        ],
      ),
    );
  }

  /// 一行文件信息：[A] 文件名。父级需给有界宽度。
  Widget _fileLabel(
    BuildContext context,
    String chip,
    String name, {
    int maxLines = 1,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.max,
      children: [
        _kindChip(context, chip),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            name,
            maxLines: maxLines,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ],
    );
  }

  /// 上下结构时：A 一行、B 一行，中间一条细横线。
  Widget _fileCardStacked(BuildContext context, String a, String b) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _fileLabel(context, 'A', a, maxLines: 2),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Container(
            height: 0.5,
            color: Theme.of(context).dividerColor,
          ),
        ),
        _fileLabel(context, 'B', b, maxLines: 2),
      ],
    );
  }

  /// 左右对照时：A 左列、B 右列。卡片本身已经有底框，
  /// 中间不再画竖线（用户说的「左右结构不需要分割线」指的是这里）。
  Widget _fileCardSideBySide(BuildContext context, String a, String b) {
    return Row(
      children: [
        Expanded(child: _fileLabel(context, 'A', a)),
        const SizedBox(width: 10),
        Expanded(child: _fileLabel(context, 'B', b)),
      ],
    );
  }

  /// A / B 小标签：中性灰底，只靠字母区分，不用红绿。
  Widget _kindChip(BuildContext context, String label) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: cs.onSurfaceVariant,
        ),
      ),
    );
  }

  /// 形态二「两头开关」：胶囊里一个小滑块，停在左边 = 左边那个模式，
  /// 停到右边 = 右边那个模式。点两端可以切，左右划一下也能切。
  /// 两个并排正好占一行，不用第二行，也不做「隐藏一半再划出来」。
  Widget _twoEndSwitch(
    BuildContext context, {
    required String leftLabel,
    required String rightLabel,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onHorizontalDragEnd: (details) {
        final double v = details.primaryVelocity ?? 0.0;
        if (v > 80) {
          onChanged(true);
        } else if (v < -80) {
          onChanged(false);
        }
      },
      child: SizedBox(
        height: 32,
        child: Container(
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
            border: Border.all(color: cs.outlineVariant, width: 0.5),
            borderRadius: BorderRadius.circular(16),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Stack(
              children: [
                // 滑块占一半宽，靠左或靠右，切换时滑过去。
                AnimatedAlign(
                  alignment:
                      value ? Alignment.centerRight : Alignment.centerLeft,
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOut,
                  child: FractionallySizedBox(
                    widthFactor: 0.5,
                    heightFactor: 1,
                    child: Container(
                      margin: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: cs.primaryContainer,
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
                // 两端文字盖在滑块上面，当前那一端加粗。
                Positioned.fill(
                  child: Row(
                    children: [
                      Expanded(
                        child: Center(
                          child: Text(
                            leftLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight:
                                  value ? FontWeight.normal : FontWeight.w700,
                              color: value
                                  ? cs.onSurfaceVariant
                                  : cs.onPrimaryContainer,
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: Center(
                          child: Text(
                            rightLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight:
                                  value ? FontWeight.w700 : FontWeight.normal,
                              color: value
                                  ? cs.onPrimaryContainer
                                  : cs.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // 透明命中区：点左半 / 右半直接切到对应那端。
                Positioned.fill(
                  child: Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => onChanged(false),
                          child: const SizedBox.expand(),
                        ),
                      ),
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => onChanged(true),
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRow(BuildContext context, _DiffListItem it) {
    // 相同行的间隔不渲染任何东西。
    if (it.isGap) return const SizedBox.shrink();

    final kindLabel = _kindLabelWidget(context, it.kind);

    if (_sideBySide) {
      return _buildRowSideBySide(context, it, kindLabel);
    }
    return _buildRowStacked(context, it, kindLabel);
  }

  /// 类型标签统一为灰色小字，无背景、无红绿。
  Widget _kindLabelWidget(BuildContext context, _DiffListKind kind) {
    return Text(
      _kindLabel(kind),
      style: TextStyle(
        fontSize: 11,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }

  // ==================== 上下结构 ====================

  /// 上下结构：长行不折行、不截断，整块共用一个横向滚动区。
  /// 左行右行都在同一个滚动区里，所以横向拖动天然同步，
  /// 不需要给每行单独挂 controller，也不会出现「左边滑了右边没滑」。
  /// 块与块之间各滑各的（每个块自己的横向位置）。
  Widget _buildRowStacked(
      BuildContext context, _DiffListItem it, Widget kindLabel) {
    final children = <Widget>[];
    final canPair = _charHighlight &&
        it.kind == _DiffListKind.modified &&
        it.leftLines.length == it.rightLines.length;
    for (var i = 0; i < it.leftLines.length; i++) {
      Widget line = _plainLine(context, it.leftLines[i], singleLine: true);
      if (canPair && i < _kCharHighlightMaxPairsPerBlock) {
        line = _highlightedLine(
          context,
          it.leftLines[i],
          it.rightLines[i],
          isLeft: true,
          singleLine: true,
        );
      }
      children.add(_labeledLine(context, '左：', line, singleLine: true));
    }
    for (var i = 0; i < it.rightLines.length; i++) {
      Widget line = _plainLine(context, it.rightLines[i], singleLine: true);
      if (canPair && i < _kCharHighlightMaxPairsPerBlock) {
        line = _highlightedLine(
          context,
          it.leftLines[i],
          it.rightLines[i],
          isLeft: false,
          singleLine: true,
        );
      }
      children.add(_labeledLine(context, '右：', line, singleLine: true));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
          child: kindLabel,
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.only(right: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          ),
        ),
        const Divider(height: 1, thickness: 0.5),
      ],
    );
  }

  // ==================== 左右对照 ====================

  /// 左右对照：两列各有界宽，长行按列宽折行，不截断、不丢字。
  /// 这里的 _plainLine / _highlightedLine 都用默认 singleLine = false，
  /// 和上下结构的「不折行 + 横向滚动」是两套排版，互不影响。
  Widget _buildRowSideBySide(
      BuildContext context, _DiffListItem it, Widget kindLabel) {
    final maxLen = it.leftLines.length > it.rightLines.length
        ? it.leftLines.length
        : it.rightLines.length;
    final canPair = _charHighlight &&
        it.kind == _DiffListKind.modified &&
        it.leftLines.length == it.rightLines.length;
    final rows = <Widget>[];
    for (var i = 0; i < maxLen; i++) {
      final hasL = i < it.leftLines.length;
      final hasR = i < it.rightLines.length;
      Widget leftCell = const SizedBox.shrink();
      Widget rightCell = const SizedBox.shrink();
      if (hasL && hasR) {
        final forcePlain = !canPair || i >= _kCharHighlightMaxPairsPerBlock;
        leftCell = _labeledLine(
          context,
          '左：',
          _highlightedLine(
            context,
            it.leftLines[i],
            it.rightLines[i],
            isLeft: true,
            forcePlain: forcePlain,
          ),
          compact: true,
        );
        rightCell = _labeledLine(
          context,
          '右：',
          _highlightedLine(
            context,
            it.leftLines[i],
            it.rightLines[i],
            isLeft: false,
            forcePlain: forcePlain,
          ),
          compact: true,
        );
      } else if (hasL) {
        leftCell = _labeledLine(
          context,
          '左：',
          _plainLine(context, it.leftLines[i]),
          compact: true,
        );
      } else {
        rightCell = _labeledLine(
          context,
          '右：',
          _plainLine(context, it.rightLines[i]),
          compact: true,
        );
      }
      // 差异块不要外框、行与行之间也不要横线；
      // 中间竖线由下面整块统一画一条，贯穿整个块。
      // 不做 IntrinsicHeight / stretch，避免之前那种 release 白屏。
      rows.add(Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: leftCell),
          Expanded(child: rightCell),
        ],
      ));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
          child: kindLabel,
        ),
        // 没有外框、没有卡片：块里只有一条贯穿的中间竖线 + 块底一条横线。
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Stack(
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: rows,
              ),
              // 竖线贯穿整个块（不是每行各画一截）。用 Stack 的定位层，
              // 不需要 IntrinsicHeight 去量两列高度，也就不会白屏。
              Positioned.fill(
                child: IgnorePointer(
                  child: Row(
                    children: [
                      const Expanded(child: SizedBox.shrink()),
                      Container(
                        width: 0.5,
                        height: double.infinity,
                        color: Theme.of(context).dividerColor,
                      ),
                      const Expanded(child: SizedBox.shrink()),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        const Divider(height: 1, thickness: 0.5),
      ],
    );
  }

  // ============ 行渲染（文字前缀 + 可选逐字高亮） ============

  /// 普通一行：正文用主题文字色，没有任何底色。
  /// singleLine = true 给上下结构用（不折行、不截断，靠外层横向滚动看全）；
  /// 默认 false 给左右对照用（按列宽折行，一字不丢）。
  Widget _plainLine(BuildContext context, String text,
      {bool singleLine = false}) {
    return Text(
      text.isEmpty ? '（空行）' : text,
      maxLines: singleLine ? 1 : null,
      softWrap: !singleLine,
      style: TextStyle(
        fontSize: _bodyFontSize,
        color: Theme.of(context).colorScheme.onSurface,
      ),
    );
  }

  /// 用「左：」「右：」文字前缀标明这一行来自哪个文件，替代原来的红绿底色。
  /// singleLine 时不能用 Expanded（外层横向滚动给的是无限宽，
  /// Expanded 在无界宽度下会报错 / release 下白屏），改成按内容自然宽度。
  Widget _labeledLine(BuildContext context, String prefix, Widget content,
      {bool compact = false, bool singleLine = false}) {
    return Padding(
      padding: compact
          ? const EdgeInsets.symmetric(horizontal: 6, vertical: 2)
          : const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Row(
        mainAxisSize: singleLine ? MainAxisSize.min : MainAxisSize.max,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            prefix,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          const SizedBox(width: 6),
          singleLine ? content : Expanded(child: content),
        ],
      ),
    );
  }

  /// 逐字高亮：只给改动的那几个字加粗 + 下划线，不用任何颜色块。
  /// 超长行或被要求纯文本时退回普通 Text。
  Widget _highlightedLine(
    BuildContext context,
    String leftText,
    String rightText, {
    required bool isLeft,
    bool forcePlain = false,
    bool singleLine = false,
  }) {
    final text = isLeft ? leftText : rightText;
    if (forcePlain ||
        leftText.length > _kCharHighlightMaxLineChars ||
        rightText.length > _kCharHighlightMaxLineChars) {
      return _plainLine(context, text, singleLine: singleLine);
    }
    final spans = _charSpans(leftText, rightText, isLeft: isLeft);
    return RichText(
      maxLines: singleLine ? 1 : null,
      softWrap: !singleLine,
      text: TextSpan(
        style: TextStyle(
          fontSize: _bodyFontSize,
          color: Theme.of(context).colorScheme.onSurface,
        ),
        children: spans,
      ),
    );
  }

  List<TextSpan> _charSpans(String leftText, String rightText,
      {required bool isLeft}) {
    final dmp = DiffMatchPatch()..diffTimeout = 0.05;
    final sw = Stopwatch()..start();
    final List<Diff> diffs;
    try {
      diffs = dmp.diff(leftText, rightText);
    } catch (_) {
      sw.stop();
      CompareTimingLog.instance
          .addCost('字差异逐字 diff（超时/失败）', sw.elapsedMilliseconds);
      return [TextSpan(text: isLeft ? leftText : rightText)];
    }
    sw.stop();
    CompareTimingLog.instance
        .addCost('字差异逐字 diff', sw.elapsedMilliseconds);
    final spans = <TextSpan>[];
    for (final d in diffs) {
      final show = d.operation == DIFF_EQUAL ||
          (isLeft && d.operation == DIFF_DELETE) ||
          (!isLeft && d.operation == DIFF_INSERT);
      if (!show) continue;
      if (d.operation == DIFF_EQUAL) {
        spans.add(TextSpan(text: d.text));
      } else {
        spans.add(TextSpan(
          text: d.text,
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            decoration: TextDecoration.underline,
          ),
        ));
      }
    }
    return spans;
  }
}
