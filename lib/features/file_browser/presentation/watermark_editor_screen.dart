import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:re_editor/re_editor.dart';

import '../../preprocessing/application/encoding_detector.dart';
import '../../preprocessing/application/watermark_service.dart';

/// 水印词表的编辑器。
///
/// 以前这里是「每行一个 TextField + ScrollablePositionedList 虚拟化」的行编辑器，
/// 那个骨架是从下线的行编辑器页面搬过来的，在虚拟列表里拿不到有限的高度约束，
/// 每行都被撑成一屏高：进来只看得见一行内容、下面整片空白，删掉这行才露出下一行。
///
/// 现在换成和 single_file_editor_screen 同一个编辑器（re_editor 的 CodeEditor）：
/// 整份词表就是一个多行文本，一个换行一条词，光标直接在正文里改，
/// 不再有「一行一个输入框」的东西，也不画行号栏。
///
/// 界面：顶栏（导入 / 更多 / 保存）+ 提示条 + 正文。没有底栏按钮，
/// 所有增删改都直接在正文里做——回车换行就是新增一条、整行删掉就是删一条、
/// 整份词表可以用长按菜单粘贴进来。长按菜单（剪切 / 复制 / 粘贴 / 全选）
/// 提供选区级的文本操作。
class WatermarkEditorScreen extends ConsumerStatefulWidget {
  const WatermarkEditorScreen({super.key});

  @override
  ConsumerState<WatermarkEditorScreen> createState() =>
      _WatermarkEditorScreenState();
}

class _WatermarkEditorScreenState extends ConsumerState<WatermarkEditorScreen> {
  /// 正文控制器：整份词表就是一个多行文本。
  late final CodeLineEditingController _controller;

  final CodeScrollController _scrollCtrl = CodeScrollController();

  /// 手机长按选中菜单（剪切 / 复制 / 粘贴 / 全选）。不给的话长按没有任何菜单，
  /// 粘贴一整份词表都做不了，和原来每行 TextField 的原生菜单对不上。
  late final SelectionToolbarController _toolbarController;

  /// 上一次见到的正文快照：只用来识别「正文真的变了」。
  /// 光标移动也会触发 controller 通知，但不会换 codeLines 实例。
  CodeLines? _lastLines;

  /// 程序化改正文时置位，避免被误标成「用户改动」。
  bool _suppressChange = false;

  bool _dirty = false;
  bool _loading = true;

  /// 非空行条数，给顶栏标题用。正文变了才重算。
  int _realCount = 0;

  @override
  void initState() {
    super.initState();
    _controller = CodeLineEditingController.fromText('');
    _lastLines = _controller.codeLines;
    _toolbarController = MobileSelectionToolbarController(
      builder: _buildSelectionToolbar,
    );
    _controller.addListener(_onControllerChanged);
    _loadFromPrefs();
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _loadFromPrefs() {
    final words = parseWatermarkWords(ref.read(watermarkWordsProvider));
    _suppressChange = true;
    // 空表时 setText('') 也会留一行空行，编辑器不会出现 0 行。
    _controller.text = words.join('\n');
    _controller.selection = const CodeLineSelection.collapsed(index: 0, offset: 0);
    _suppressChange = false;
    _lastLines = _controller.codeLines;
    _realCount = words.length;
    _loading = false;
    _dirty = false;
  }

  // ==================== 正文变更 ====================

  void _onControllerChanged() {
    if (!mounted) return;
    final lines = _controller.codeLines;
    // 同一个 CodeLines 实例 → 只是光标/选区变化，正文没动。
    final structural = !identical(lines, _lastLines);
    if (structural) {
      _lastLines = lines;
      // 直接数，不先拼成 List：打字时每一下都会走到这里，
      // 几千条词表再复制一份 List 没必要。
      _realCount = _countRealIn(lines);
    }
    // 程序化改动由调用方自己 setState，这里别抢。
    if (_suppressChange) return;

    final nextDirty = _dirty || structural;
    // 没有底栏要跟着光标走，只有「脏了」才需要重建整页，
    // 否则每敲一个字都重建一遍顶栏和编辑器。
    if (nextDirty != _dirty) {
      setState(() {
        _dirty = nextDirty;
      });
    }
  }

  /// 取出正文的每一行文本（保留空行，位置和行号一一对应）。
  List<String> _snapshotLines() {
    final out = <String>[];
    for (final segment in _controller.codeLines.segments) {
      for (final line in segment.codeLines) {
        out.add(line.text);
      }
    }
    return out;
  }

  int _countReal(List<String> lines) {
    var n = 0;
    for (final l in lines) {
      if (l.trim().isNotEmpty) n++;
    }
    return n;
  }

  int _countRealIn(CodeLines codeLines) {
    var n = 0;
    for (final segment in codeLines.segments) {
      for (final line in segment.codeLines) {
        if (line.text.trim().isNotEmpty) n++;
      }
    }
    return n;
  }

  /// 整份正文换掉，光标落到 [cursor] 行。
  ///
  /// 结构变了（删行 / 插行 / 去重 / 导入 / 保存后归一化）统一走这里：
  /// 行内容、光标一次性对齐，不会出现错位。
  void _applyLines(List<String> lines, int cursor, {bool markDirty = true}) {
    final safe = lines.isEmpty ? const <String>[''] : lines;
    final at = cursor.clamp(0, safe.length - 1).toInt();

    _suppressChange = true;
    _controller.codeLines =
        CodeLines.of(safe.map((t) => CodeLine(t)).toList());
    _controller.selection =
        CodeLineSelection.collapsed(index: at, offset: 0);
    _suppressChange = false;

    _lastLines = _controller.codeLines;
    setState(() {
      _dirty = markDirty;
      _realCount = _countReal(safe);
    });
  }

  // ==================== 全表操作 ====================

  void _dedupe() {
    final lines = _snapshotLines();
    final before = _countReal(lines);
    final seen = <String>{};
    final out = <String>[];
    for (final l in lines) {
      final w = normalizeWatermark(l);
      if (w.isEmpty) continue;
      if (!seen.add(w)) continue;
      out.add(w);
    }
    _applyLines(out, 0);
    _toast('已去掉 ${before - out.length} 条重复/空行，剩 ${out.length} 条');
  }

  Future<void> _clearAll() async {
    if (_snapshotLines().every((l) => l.trim().isEmpty)) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('清空词表'),
        content: const Text('这会删掉全部词条，且没法撤销。确定吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(c).colorScheme.error,
              foregroundColor: Theme.of(c).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    _applyLines(const <String>[''], 0);
  }

  /// 从 txt 导入。
  ///
  /// 用户攒的水印表通常是从各处复制来的，重复一大堆
  /// （实测一份 3159 行的表里重复了 1422 行），
  /// 所以导入时就地做掉：分拆 → 归一化 → 去空 → 去重 → 追加。
  Future<void> _importFromTxt() async {
    final picked = await FilePicker.pickFiles(
      dialogTitle: '选择水印词表 txt',
      type: FileType.custom,
      allowedExtensions: ['txt'],
    );
    if (picked.isEmpty) return;
    final path = picked.single.path;
    if (path == null) {
      _toast('无法读取文件');
      return;
    }

    setState(() => _loading = true);
    try {
      final bytes = await File(path).readAsBytes();
      final enc = EncodingDetector.detect(bytes);
      final decoded = await EncodingDetector.decodeChunkedAsync(bytes, enc);
      final imported = parseImportedWatermarks(decoded.text);
      if (imported.isEmpty) {
        if (!mounted) return;
        setState(() => _loading = false);
        _toast('这个文件里没有可用词条');
        return;
      }

      final existing = <String>{
        for (final l in _snapshotLines())
          if (normalizeWatermark(l).isNotEmpty) normalizeWatermark(l),
      };
      var added = 0;
      final next = _snapshotLines();
      // 导入进来的是空表时，先把开头那条占位空行去掉。
      if (next.length == 1 && next.first.isEmpty) next.clear();
      for (final w in imported) {
        if (existing.add(w)) {
          next.add(w);
          added++;
        }
      }

      if (!mounted) return;
      _applyLines(next, 0);
      setState(() => _loading = false);
      _toast('导入完成：新增 $added 条（去重后），共 ${next.length} 条');
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _toast('导入失败：$e');
    }
  }

  // ==================== 保存 ====================

  Future<bool> _save() async {
    // 存之前统一做一次归一化 + 去重：
    // 词表里躺着看不见的控制字符，编辑器里根本没法编辑，
    // 而且匹配前两边都要归一化，不如入库时就弄干净。
    final seen = <String>{};
    final out = <String>[];
    for (final l in _snapshotLines()) {
      final w = normalizeWatermark(l);
      if (w.isEmpty) continue;
      if (!seen.add(w)) continue;
      out.add(w);
    }
    ref.read(watermarkWordsProvider.notifier).setAll(encodeWatermarkWords(out));
    invalidateWatermarkCache();
    _applyLines(out, 0, markDirty: false);
    return true;
  }

  Future<void> _handleBack() async {
    if (!_dirty) {
      Navigator.of(context).pop();
      return;
    }
    final r = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('词表已修改'),
        content: const Text('要保存之后再返回吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, 'discard'),
            child: const Text('放弃'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, 'save'),
            child: const Text('保存并返回'),
          ),
        ],
      ),
    );
    if (r == 'save') {
      await _save();
      if (mounted) Navigator.of(context).pop();
    } else if (r == 'discard') {
      if (mounted) Navigator.of(context).pop();
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  // ==================== 长按选中菜单 ====================

  Widget _buildSelectionToolbar({
    required BuildContext context,
    required TextSelectionToolbarAnchors anchors,
    required CodeLineEditingController controller,
    required VoidCallback onDismiss,
    required VoidCallback onRefresh,
  }) {
    final hasSelection = !controller.selection.isCollapsed;
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: anchors,
      buttonItems: <ContextMenuButtonItem>[
        if (hasSelection)
          ContextMenuButtonItem(
            label: '剪切',
            onPressed: () {
              controller.cut();
              onDismiss();
            },
          ),
        if (hasSelection)
          ContextMenuButtonItem(
            label: '复制',
            onPressed: () async {
              await controller.copy();
              onDismiss();
            },
          ),
        ContextMenuButtonItem(
          label: '粘贴',
          onPressed: () {
            controller.paste();
            onDismiss();
          },
        ),
        ContextMenuButtonItem(
          label: '全选',
          onPressed: () {
            controller.selectAll();
            onRefresh();
          },
        ),
      ],
    );
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _handleBack();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text('删除水印 · $_realCount 条'),
          actions: [
            IconButton(
              icon: const Icon(Icons.file_upload_outlined),
              tooltip: '从 txt 导入',
              onPressed: _importFromTxt,
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              onSelected: (v) {
                if (v == 'dedupe') {
                  _dedupe();
                } else if (v == 'clear') {
                  _clearAll();
                } else if (v == 'help') {
                  _showHelp();
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'dedupe',
                  child: Row(
                    children: [
                      Icon(Icons.filter_alt_outlined),
                      SizedBox(width: 10),
                      Text('去掉重复和空行'),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'clear',
                  child: Row(
                    children: [
                      Icon(Icons.delete_sweep_outlined),
                      SizedBox(width: 10),
                      Text('清空词表'),
                    ],
                  ),
                ),
                PopupMenuDivider(),
                PopupMenuItem(
                  value: 'help',
                  child: Row(
                    children: [
                      Icon(Icons.help_outline),
                      SizedBox(width: 10),
                      Text('这个词表怎么工作的'),
                    ],
                  ),
                ),
              ],
            ),
            TextButton(
              onPressed: _dirty ? () => _save() : null,
              child: const Text('保存'),
            ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  _buildHintBar(s),
                  Expanded(child: _buildEditor(s)),
                ],
              ),
      ),
    );
  }

  Widget _buildHintBar(ColorScheme s) {
    return InkWell(
      onTap: _showHelp,
      child: Container(
        width: double.infinity,
        color: s.surfaceContainerHighest.withValues(alpha: 0.5),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.info_outline, size: 16, color: s.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '每行一条 · 字面匹配 · 点「导入」可一次灌入整份词表',
                style: TextStyle(fontSize: 12, color: s.onSurfaceVariant),
              ),
            ),
            Icon(Icons.chevron_right, size: 16, color: s.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  /// 正文编辑器：和全文编辑器同一套（re_editor 的 CodeEditor）。
  ///
  /// 整份词表当普通文本编辑——回车换行就是新增一条，删掉一整行就是删一条，
  /// 不用再一行一个 TextField 去虚拟化，也不画左侧行号栏。
  /// 行高和正文由同一个 TextPainter 算，不会出现「一屏只看得见一行」。
  Widget _buildEditor(ColorScheme s) {
    return CodeEditor(
      controller: _controller,
      scrollController: _scrollCtrl,
      toolbarController: _toolbarController,
      // 纯文本不需要 {} [] 折叠分析，关掉省开销。
      chunkAnalyzer: const NonCodeChunkAnalyzer(),
      // 水印词一行一条，长词横向滚动比折行更好分辨「这是第几条」。
      wordWrap: false,
      // 进来不主动弹键盘（几千条词表，先把内容看清楚）。
      autofocus: false,
      hint: '（空表）每行一条水印',
      maxLengthSingleLineRendering: 2048,
      padding: EdgeInsets.zero,
      // 不画外框：和全文编辑器一致，正文不从边上再缩进一圈。
      scrollbarBuilder: (context, child, details) {
        if (details.direction != AxisDirection.down) return child;
        return Scrollbar(
          controller: details.controller,
          thumbVisibility: false,
          child: child,
        );
      },
      style: CodeEditorStyle(
        fontSize: 14,
        fontFamily: 'monospace',
        fontHeight: 1.4,
        textColor: s.onSurface,
        cursorColor: s.primary,
        selectionColor: s.primary.withValues(alpha: 0.25),
      ),
    );
  }

  void _showHelp() {
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除水印'),
        content: const SingleChildScrollView(
          child: Text(
            '这个词表是给你攒各种水印、广告、网站名用的。\n\n'
            '怎么用：\n'
            '· 每行一条，纯字面匹配，不支持正则\n'
            '· 正文里出现这个词，就把这一小段抠掉\n'
            '· 抠完之后整行什么都不剩，这行也一起消失\n\n'
            '看不见的字符不用管：\n'
            '水印作者常在词中间插控制字符（比如把「微博」写成「微+某个不可见字符+博」）'
            '来绕过过滤。匹配前两边都会自动抹掉这些干扰，插什么都一样命中。\n\n'
            '顺序建议放在最前面：\n'
            '这样删完留下的空行，能交给后面的「去行首尾空白」「删掉空行」收拾干净。',
            style: TextStyle(fontSize: 13, height: 1.6),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
              child: const Text('知道了'),
          ),
        ],
      ),
    );
  }
}
