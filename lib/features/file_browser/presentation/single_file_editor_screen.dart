import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:charset/charset.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart' show PointerDownEvent, PointerUpEvent;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show FrameCallback, SchedulerBinding;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:re_editor/re_editor.dart';

import '../../../core/constants/app_colors.dart';
import '../../preprocessing/application/encoding_bridge.dart';
import '../../preprocessing/application/encoding_detector.dart';
import '../../preprocessing/application/preprocessing_service.dart';
import '../../import/presentation/providers/import_providers.dart'
    show
        applyKeywordRules,
        applyRegexRules,
        regexRulesTextProvider,
        keywordRulesTextProvider;
import '../../preprocessing/application/watermark_service.dart'
    show applyWatermarkRules, watermarkWordsProvider;
import '../../preprocessing/domain/encoding_type.dart';
import '../../preprocessing/domain/preprocessing_rule.dart';
import '../../viewer/presentation/viewer_widgets.dart' show pickColorDialog;
import 'providers/line_editor_rules_provider.dart';
import 'translation_table.dart';
import 'comparison_settings_screen.dart'
    show RuleEditorDialog, ruleSubtitle;

/// 文件大小阈值。
const int _warnSizeBytes = 5 * 1024 * 1024;
const int _rejectSizeBytes = 20 * 1024 * 1024;

/// 其余匹配的高亮底色（黄）。
const Color _matchYellow = Color(0xFFFFF59D);

/// 当前命中 / 手动选区的底色（粉）。
const Color _matchPink = Color(0xFFFFB3C1);

/// 多选行：已勾选行的颜色（蓝）。行号底色、行号文字、左侧竖条都用它。
const Color _kSelectBlue = Color(0xFF1E88E5);

/// 多选行：区间选择的起点色。刻意做成「偏黄的绿」，
/// 和已勾选的蓝区分开，也比行编辑器那种正绿柔和一点。
const Color _kRangeStart = Color(0xFF9E9D24);

/// 点行号时允许的手指抖动。超过就当成滚动/拖动，不勾选。
const double _kGutterTapSlop = 24.0;

/// 按下到抬手的最大时长，超过当成长按（不做任何事）。
const Duration _kGutterTapTimeout = Duration(milliseconds: 1500);

/// 「跳到开头 / 跳到结尾」最多补多少帧。普通文件 2~4 帧就收敛了，
/// 给大文件留足余量；到顶后靠「连续几帧没得动」提前退出，不会跑满。
const int _kParkMaxFrames = 40;

/// 连续多少帧视口已经无处可动，就认为真的到顶了。
const int _kParkSettleFrames = 3;

/// 「跳到指定行 / 查找定位」最多补多少帧。正常 2~4 帧就把目标行精确
/// 放到中间；行高分布极不均匀的超大文件留 12 帧余量（≈200ms）。
const int _kLineJumpMaxFrames = 12;

/// 目标行上下各留这么多像素就算「已经看得见了」，不再滚动。
const double _kLineJumpMargin = 8.0;

// 默认皮肤（defaultBlue）专属灰：按钮栏背景。和行编辑器保持一致，
// 其它皮肤沿用各自 scheme。
const Color _defaultToolbarBgLight = Color(0xFFE2E2E2);
const Color _defaultToolbarBgDark = Color(0xFF44474D);

/// 仅默认皮肤返回 true（与行编辑器同一套判断）。
bool _isDefaultSkin(ColorScheme s) =>
    s.primary == AppColors.lightScheme.primary ||
    s.primary == AppColors.darkScheme.primary;

enum _SaveEncoding {
  utf8('UTF-8'),
  gbk('GBK');

  const _SaveEncoding(this.label);
  final String label;
}

class SingleFileEditorScreen extends ConsumerStatefulWidget {
  const SingleFileEditorScreen({
    super.key,
    required this.filePath,
    required this.fileName,
  });

  final String filePath;
  final String fileName;

  @override
  ConsumerState<SingleFileEditorScreen> createState() =>
      _SingleFileEditorScreenState();
}

class _SingleFileEditorScreenState
    extends ConsumerState<SingleFileEditorScreen> {
  /// re_editor 的正文控制器（替代原来的自定义 TextEditingController）。
  late final CodeLineEditingController _controller;

  /// 查找/替换控制器：查找、替换、高亮全部由它和编辑器内部完成。
  late final CodeFindController _findController;

  /// 手机长按选中菜单（剪切/复制/粘贴/全选）。
  late final SelectionToolbarController _toolbarController;

  bool _loading = true;
  bool _saving = false;
  bool _dirty = false;
  bool _showFind = false;
  bool _processing = false;
  String _processingText = '';

  String _detectedEncoding = '';
  _SaveEncoding _saveEncoding = _SaveEncoding.utf8;

  /// 加载时缓存的原始字节：手动切换编码时按新编码重解一遍，
  /// 不重新读文件（屏幕上的改动会丢，所以切换前会先确认）。
  Uint8List? _rawBytes;

  bool _useRegex = false;
  bool _caseSensitive = false;

  /// 查找词防抖（300ms，和行编辑器一致）。
  /// re_editor 每收到一次输入就把整篇文档扫一遍，20MB 的文件打字稍快
  /// 就会一直重扫、计数反复跳「搜索中」，耗电也高。停手再提交。
  Timer? _findDebounce;

  /// 自己持有的查找输入框控制器。
  /// 直接用库的 findInputController 没法防抖——它自带监听，一改文本立刻开扫。
  /// 这里先收按键，防抖结束再同步过去。
  final TextEditingController _findInput = TextEditingController();

  /// 防抖刚提交、结果还没回来时，记下用户按的是哪个按钮，结果一到就执行，
  /// 免得「点了没反应」。
  String? _pendingFindAction;

  /// 全部替换进行中。库里的替换是同步的，这里只用来挡连点、置灰按钮。
  bool _replacing = false;

  /// 上一次渲染用的查找状态。
  ///
  /// 库的 `_updateResult` 挂在编辑器 controller 上，**选区一变也会跑**；
  /// 即使 equals 命中、结果没变，它仍会 `copyWith` 出一个新 value 并通知，
  /// 于是就一路 setState 整页重建（AppBar + 工具条 + 状态栏）。
  /// 拖选区手柄时每帧一次。这里比对 searching / result 引用，没变就不重建。
  bool _lastFindSearching = false;
  Object? _lastFindResult;

  bool _noWrap = false;
  double _fontSize = 14.0;

  /// 行号栏最小宽度（和行编辑器同一套设置，24~120）。
  /// 行数很多时实际宽度取「这个值」和「容纳行号所需宽度」的较大者。
  double _lineNumberWidth = 44.0;

  /// 上一次见到的正文快照：只用来识别「正文真的变了」，
  /// 光标移动也会触发 controller 通知，但不会换 codeLines 实例。
  CodeLines? _lastLines;

  /// 行数缓存：`_controller.lineCount` 会遍历所有 segment 做 fold，
  /// 行号栏宽度和行号渲染每帧/每次滚动都读它。正文变化才重算，
  /// 光标移动、滚动、查找高亮都不该再付一次 O(段数) 的 fold。
  int _cachedLineCount = 0;

  /// 程序化改正文时置位，避免被误标成「用户改动」。
  bool _suppressChange = false;

  int _charCount = 0;
  Timer? _charCountTimer;

  // ---- 多选行 ----
  /// 选择模式：点行号勾选整行，正文暂时只读。
  bool _selectMode = false;

  /// 已勾选的行（0-based 行下标）。支持不连续多行。
  final Set<int> _selectedLines = <int>{};

  /// 区间拾取中（点了底部操作条的「区间选择」）。
  bool _pickingRange = false;

  /// 区间起点（0-based）。非 null = 正在等第二次点击。
  int? _rangeStart;

  /// re_editor 的滚动控制器。自己持有一份，点行号时能把惯性滑动停住。
  final CodeScrollController _scrollCtrl = CodeScrollController();

  /// 行号栏回调里存下来的可见行信息（点行号时按 y 换算行下标）。
  /// 只在 indicatorBuilder 里赋值，不 setState。
  ValueNotifier<CodeIndicatorValue?>? _linesNotifier;

  int? _gutterPointer;
  Offset? _gutterDownPos;
  DateTime? _gutterDownAt;
  int? _gutterDownIndex;

  @override
  void initState() {
    super.initState();
    _controller = CodeLineEditingController();
    _lastLines = _controller.codeLines;
    _cachedLineCount = _controller.lineCount;
    _findController = CodeFindController(_controller);
    _toolbarController = MobileSelectionToolbarController(
      builder: _buildSelectionToolbar,
    );
    _controller.addListener(_onControllerChanged);
    _findController.addListener(_onFindChanged);
    _load();
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _findController.removeListener(_onFindChanged);
    _charCountTimer?.cancel();
    _findDebounce?.cancel();
    _findInput.dispose();
    _findController.dispose();
    _controller.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  // ==================== 正文变更 ====================

  void _onControllerChanged() {
    final lines = _controller.codeLines;
    // 同一个 CodeLines 实例 → 只是光标/选区变化，不算改动。
    if (identical(lines, _lastLines)) return;
    _lastLines = lines;
    _cachedLineCount = _controller.lineCount;
    if (_suppressChange) return;
    _scheduleCharCount();
    if (!_dirty) setState(() => _dirty = true);
  }

  void _onFindChanged() {
    if (!mounted) return;
    final value = _findController.value;
    final searching = value?.searching ?? false;
    final result = value?.result;
    // 选区变化也会一路通知到这里：结果没变就别整页重建。
    if (searching != _lastFindSearching || !identical(result, _lastFindResult)) {
      _lastFindSearching = searching;
      _lastFindResult = result;
      setState(() {});
    }
    // 防抖期间按下的「上一个/下一个/替换当前」，等这一轮结果回来再执行。
    final pending = _pendingFindAction;
    if (pending == null) return;
    if (value == null || value.searching || value.result == null) return;
    _pendingFindAction = null;
    if (value.result!.matches.isEmpty) {
      _toast('未找到');
      return;
    }
    if (pending == 'prev') {
      _findController.previousMatch();
    } else if (pending == 'replace') {
      _findController.replaceMatch();
    } else {
      _findController.nextMatch();
    }
    _syncToCurrentMatch();
  }

  void _scheduleCharCount() {
    _charCountTimer?.cancel();
    _charCountTimer = Timer(const Duration(milliseconds: 600), () {
      if (!mounted) return;
      setState(() => _charCount = _computeCharCount());
    });
  }

  /// 不拼接整篇字符串（20MB 拼一次太贵），直接累加每行长度。
  ///
  /// 直接遍历 segments，不走 `toList()`：后者会为 30 万行分配一个临时
  /// List（约 2.4MB 指针 + 扩容拷贝），每 600ms 抖动一次。
  int _computeCharCount() {
    final codeLines = _controller.codeLines;
    final total = codeLines.length;
    if (total == 0) return 0;
    var count = 0;
    for (final segment in codeLines.segments) {
      for (final line in segment.codeLines) {
        count += line.length;
      }
    }
    count += total - 1; // 行间换行符
    return count < 0 ? 0 : count;
  }

  // ==================== 加载 ====================

  Future<void> _load() async {
    try {
      final file = File(widget.filePath);
      final len = await file.length();

      if (len > _rejectSizeBytes) {
        if (!mounted) return;
        setState(() => _loading = false);
        _toast('文件超过 ${_rejectSizeBytes ~/ 1024 ~/ 1024} MB，请用预览功能');
        return;
      }

      bool noWrap = false;
      if (len > _warnSizeBytes) {
        if (!mounted) return;
        final mb = (len / 1024 / 1024).toStringAsFixed(1);
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('文件较大'),
            content: Text(
              '此文件约 $mb MB，将以「不换行」模式打开以避免卡顿。\n'
              '打开后可在顶栏切换回换行模式。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('打开'),
              ),
            ],
          ),
        );
        if (ok != true) {
          if (!mounted) return;
          setState(() => _loading = false);
          return;
        }
        noWrap = true;
      }

      final bytes = await file.readAsBytes();
      _rawBytes = bytes;
      final enc = EncodingDetector.detect(bytes);
      final decoded = await EncodingDetector.decodeChunkedAsync(bytes, enc);

      // 大文本在主线程拆行会明显卡顿，切到 isolate 里做。
      final lines = await decoded.text.codeLinesAsync;
      if (!mounted) return;

      _suppressChange = true;
      _controller.codeLines = lines;
      _suppressChange = false;

      setState(() {
        _lastLines = _controller.codeLines;
        _dirty = false;
        _charCount = decoded.text.length;
        _detectedEncoding = decoded.encoding.label;
        _saveEncoding = _guessSaveEncoding(decoded.encoding);
        _noWrap = noWrap;
        _loading = false;
        // 换了正文，旧的勾选/区间状态全部作废
        _selectMode = false;
        _selectedLines.clear();
        _pickingRange = false;
        _rangeStart = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _toast('读取失败：$e');
    }
  }

  _SaveEncoding _guessSaveEncoding(EncodingType enc) {
    switch (enc) {
      case EncodingType.gbk:
      case EncodingType.gb18030:
        return _SaveEncoding.gbk;
      default:
        return _SaveEncoding.utf8;
    }
  }

  // ==================== 保存 ====================

  Uint8List _encodeText(String text, _SaveEncoding enc) {
    switch (enc) {
      case _SaveEncoding.utf8:
        return Uint8List.fromList(utf8.encode(text));
      case _SaveEncoding.gbk:
        return Uint8List.fromList(gbk.encode(text));
    }
  }

  /// 分批编码，每批之间让出事件循环。
  ///
  /// `_controller.text` 会先把整篇拼成一个 9MB 字符串，再整体 `gbk.encode`
  /// （纯 Dart 表驱动，实测 1~3 秒），全程占着主线程——界面看起来是冻死的。
  /// 这里按行累加，满 512K 字符编码一批：逐字符编码可以按批拼接，
  /// 行边界也不会切在代理对中间。
  ///
  /// 返回 null 表示页面在分批过程中被销毁，调用方应直接放弃。
  Future<Uint8List?> _encodeChunked() async {
    const batchChars = 1 << 19;
    final lineBreak = _controller.options.lineBreak;
    final lb = lineBreak.value;
    // 先快照行结构：分批会让出事件循环，期间用户还能打字。
    final lines = _controller.codeLines.toList();
    final builder = BytesBuilder(copy: false);
    final buf = StringBuffer();
    var bufLen = 0;
    var first = true;

    for (final line in lines) {
      if (!first) {
        buf.write(lb);
        bufLen += lb.length;
      }
      first = false;
      final s = line.asString(0, lineBreak);
      buf.write(s);
      bufLen += s.length;

      if (bufLen >= batchChars) {
        builder.add(_encodeText(buf.toString(), _saveEncoding));
        buf.clear();
        bufLen = 0;
        if (!mounted) return null;
        await Future<void>.delayed(Duration.zero);
      }
    }

    if (bufLen > 0 || builder.isEmpty) {
      builder.add(_encodeText(buf.toString(), _saveEncoding));
    }
    return builder.takeBytes();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final bytes = await _encodeChunked();
      if (bytes == null) {
        if (mounted) setState(() => _saving = false);
        return;
      }
      final file = File(widget.filePath);
      if (await file.exists()) {
        // 只保留一个 .bak，每次覆盖。
        await File('${widget.filePath}.bak')
            .writeAsBytes(await file.readAsBytes(), flush: true);
      }
      await file.writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      setState(() {
        _dirty = false;
        _saving = false;
      });
      _toast('已保存（原文件已生成 .bak 备份）');
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('保存失败：$e');
    }
  }

  Future<void> _saveAs() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final bytes = await _encodeChunked();
      if (bytes == null) {
        if (mounted) setState(() => _saving = false);
        return;
      }
      final out = await FilePicker.saveFile(
        fileName: widget.fileName,
        bytes: bytes,
        mimeType: 'text/plain',
        dialogTitle: '另存为',
        type: FileType.custom,
        allowedExtensions: ['txt'],
      );
      if (!mounted) return;
      setState(() => _saving = false);
      if (out != null) _toast('已另存为 $out');
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('另存失败：$e');
    }
  }

  Future<bool> _confirmLeave() async {
    if (!_dirty) return true;
    final r = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('有未保存的修改'),
        content: const Text('返回将丢失改动，确定吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, 'cancel'),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, 'discard'),
            child: const Text('放弃并返回'),
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
      return !_dirty;
    }
    return r == 'discard';
  }

  // ==================== 跳转 ====================

  /// 真实行数（不含折叠分块），用作跳转时的索引上界。
  int get _lineTotal => _controller.codeLines.length;

  /// 状态栏里的编码文案：检测到的和保存用的相同时只显示一次，
  /// 避免出现 "UTF-8 → UTF-8" 这种重复（和行编辑器一致）。
  String get _encodingLabel {
    if (_detectedEncoding.isEmpty || _detectedEncoding == _saveEncoding.label) {
      return _saveEncoding.label;
    }
    return '$_detectedEncoding → ${_saveEncoding.label}';
  }

  void _jumpToTop() {
    if (_lineTotal <= 0) return;
    _controller.selection =
        const CodeLineSelection.collapsed(index: 0, offset: 0);
    _parkViewport(atEnd: false);
  }

  void _jumpToBottom() {
    final last = _lineTotal - 1;
    if (last < 0) return;
    _controller.selection = CodeLineSelection.collapsed(
      index: last,
      offset: _lineLength(last),
    );
    _parkViewport(atEnd: true);
  }

  int _lineLength(int index) {
    final lines = _controller.codeLines;
    if (index < 0 || index >= lines.length) return 0;
    return lines[index].length;
  }

  /// 移动光标并把它滚到可见区中间。
  void _moveCursorTo(int lineIndex, int offset) {
    final lines = _controller.codeLines;
    final total = lines.length;
    if (total <= 0) return;
    final index = lineIndex.clamp(0, total - 1).toInt();
    final maxOffset = lines[index].length;
    final off = offset.clamp(0, maxOffset).toInt();
    _controller.selection = CodeLineSelection.collapsed(
      index: index,
      offset: off,
    );
    _scrollToLine(index);
  }

  // ==================== 跳到开头 / 结尾 ====================

  /// 每次「跳转到开头/结尾」递增，用来让上一次还在跑的收敛循环自行退出。
  int _parkToken = 0;

  /// 把视口顶到文档最上 / 最下的真实位置。
  ///
  /// 为什么不用 `makePositionCenterIfInvisible`：re_editor 只对「已经布局
  /// 过的那几屏」知道每行的真实高度，范围外一律按单行高度估算
  /// （`_code_field.dart` 里 `totalHeight` 的算法）。开了自动换行后一行
  /// 常常占两行高，估算就偏小，行号离得越远偏得越多——表现正是
  /// 「有时候准，有时候差几十行」。库里的补救只在目标行没被布局出来时
  /// 补下一帧、最多 10 次，而且补帧靠 `addPostFrameCallback`（它自己
  /// 不排帧），视口不动时循环就断了，于是停在半路。
  ///
  /// 而「最上 / 最下」这两个位置本身不需要任何估算：
  /// 最上就是 offset 0，最下就是当前的 maxScrollExtent。顶到最下之后，
  /// 那一片区域被真正布局出来，总高度随之变准，maxScrollExtent 只增
  /// 不减，再顶一次就更靠后。每帧只做一次 jumpTo（O(1)）加库本来就要
  /// 做的「一屏」布局，几帧内收敛；看到连续几帧无处可动就停。
  void _parkViewport({required bool atEnd}) {
    final token = ++_parkToken;
    var frame = 0;
    var still = 0;
    double? lastExtent; // 上一帧看到的总可滚距离，用来判断"布局还在变大"

    void step(Duration _) {
      if (!mounted || token != _parkToken) return;
      frame++;

      final vertical = _scrollCtrl.verticalScroller;
      if (!vertical.hasClients || !vertical.position.hasContentDimensions) {
        // 编辑器还没挂上（比如刚进页面就点）：下一帧再试。
        if (frame < _kParkMaxFrames) _nextFrame(step);
        return;
      }

      final pos = vertical.position;
      final target = atEnd ? pos.maxScrollExtent : pos.minScrollExtent;
      // 注意这里读的是"上一帧布局完之后"的位置：布局可能把 pixels 顶回来，
      // 所以要拿跳之前的值判断有没有站稳。
      final before = pos.pixels;
      final moved = (before - target).abs() > 0.5;
      if (moved) vertical.jumpTo(target);

      // 不换行模式下还要横向贴边：跳到结尾时让最后一行的末尾露出来。
      final h = _scrollCtrl.horizontalScroller;
      if (h.hasClients && h.position.hasContentDimensions) {
        final hTarget = atEnd
            ? h.position.maxScrollExtent
            : h.position.minScrollExtent;
        if ((h.position.pixels - hTarget).abs() > 0.5) {
          h.jumpTo(hTarget);
        }
      }

      // 「还能往前走」或者「这一帧布局又把总高度算大了一点」都算没收敛。
      // 顶端：pixels 回到 0 才算真的到顶（换行内容会让它每次退一点点，
      // 几帧内退到 0）；末端：停下且总高度这一帧不再变才算真的到底。
      final extentStable = lastExtent != null && (target - lastExtent!).abs() <= 2.0;
      lastExtent = target;
      final settled = atEnd ? (!moved && extentStable) : before.abs() <= 0.5;
      still = settled ? still + 1 : 0;
      if (still < _kParkSettleFrames && frame < _kParkMaxFrames) {
        _nextFrame(step);
      }
    }

    _nextFrame(step);
  }

  /// 排下一帧。`addPostFrameCallback` 本身不排帧，必须显式补一次，
  /// 否则视口没变化时循环就卡死了（这正是原来看起来"跳一半"的原因之一）。
  void _nextFrame(FrameCallback cb) {
    SchedulerBinding.instance.addPostFrameCallback(cb);
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  /// 用户自己动手了（点正文、拖滚动条），立刻放弃补帧，不要抢他的滚动。
  void _cancelPark() => _parkToken++;

  /// 精确、瞬时地把某一行定位到视口中间。
  ///
  /// 不用 `makePositionCenterIfInvisible` 的原因和 [_parkViewport] 一样：
  /// 它对「还没布局出来的行」只能按单行高度估算（`_code_field.dart` 里
  /// `first.top - preferredLineHeight * (距离)`），开了自动换行后一行常占
  /// 好几行高，估算偏小，于是停在差几十行的位置；它自己补帧用的
  /// `addPostFrameCallback` 又不排帧，中途很容易断。
  ///
  /// 这里换一条不会猜错的路：`paragraphs` 是布局算出来的**真实**坐标
  /// （视口相对，`top = offset.dy`）。目标行一旦出现在里面，就用
  /// `当前 pixels + p.top` 直接算出它的绝对位置，误差 0 像素；
  /// 还没出现，就按视口里这几行的实际平均行高外推一个位置先跳过去，
  /// 下一帧再判。全程只用 `jumpTo`，没有 `animateTo`，所以是瞬移。
  void _scrollToLine(int lineIndex) {
    final token = ++_parkToken;
    var frame = 0;
    var still = 0;
    double? lastGap;

    void step(Duration _) {
      if (!mounted || token != _parkToken) return;
      frame++;

      final vertical = _scrollCtrl.verticalScroller;
      if (!vertical.hasClients || !vertical.position.hasContentDimensions) {
        if (frame < _kLineJumpMaxFrames) _nextFrame(step);
        return;
      }
      final pos = vertical.position;
      final paragraphs = _linesNotifier?.value?.paragraphs;
      if (paragraphs == null || paragraphs.isEmpty) {
        if (frame < _kLineJumpMaxFrames) _nextFrame(step);
        return;
      }

      final viewportHeight = pos.viewportDimension;
      final at = _paragraphAt(paragraphs, lineIndex);

      // 目标行已经完整在视野里：不再挪动。查找「下一处」时相邻命中
      // 往往就在同一屏，每次都居中会让画面一直抖。
      if (at != null &&
          at.top >= _kLineJumpMargin &&
          at.bottom <= viewportHeight - _kLineJumpMargin) {
        return;
      }

      double target;
      if (at != null) {
        // 目标行已经布局出来 —— 这是真实坐标，一次到位。
        target = pos.pixels + at.top + at.height / 2 - viewportHeight / 2;
      } else if (lineIndex < paragraphs.first.index) {
        // 在上方：从当前首行的真实位置往上推。
        target = pos.pixels +
            paragraphs.first.top -
            (paragraphs.first.index - lineIndex) *
                _averageLineHeight(paragraphs) -
            viewportHeight / 2;
      } else {
        // 在下方：从当前末行的真实位置往下推。
        target = pos.pixels +
            paragraphs.last.bottom +
            (lineIndex - paragraphs.last.index) *
                _averageLineHeight(paragraphs) -
            viewportHeight / 2;
      }

      final clamped = target
          .clamp(pos.minScrollExtent, pos.maxScrollExtent)
          .toDouble();
      final gap = (pos.pixels - clamped).abs();
      if (gap > 0.5) pos.jumpTo(clamped);

      // 目标行已经在视口里、且这一帧不用再动，就算落稳。
      final settled = at != null && gap <= 0.5;
      // 跳了却没拉近距离（比如被 min/max 夹住）就别死撑。
      still = (lastGap != null && gap >= lastGap! - 0.5) ? still + 1 : 0;
      lastGap = gap;
      if (!settled &&
          still < _kParkSettleFrames &&
          frame < _kLineJumpMaxFrames) {
        _nextFrame(step);
      }
    }

    _nextFrame(step);
  }

  /// 在已布局的段落里找某一行（折叠时可能不存在）。
  CodeLineRenderParagraph? _paragraphAt(
    List<CodeLineRenderParagraph> paragraphs,
    int lineIndex,
  ) {
    for (final p in paragraphs) {
      if (p.index == lineIndex) return p;
    }
    return null;
  }

  /// 视口里这几行的平均行高，含自动换行折出来的额外高度。
  double _averageLineHeight(List<CodeLineRenderParagraph> paragraphs) {
    final span = paragraphs.last.index - paragraphs.first.index;
    if (span <= 0) return paragraphs.first.height;
    final unit = (paragraphs.last.bottom - paragraphs.first.top) / span;
    return unit > 0 ? unit : paragraphs.first.height;
  }

  /// 整篇替换正文后把光标收回开头。
  ///
  /// `codeLines` setter 不会动选区，旧的光标位置在新正文里可能越界
  /// （比如简繁转换后某行变短了），接着随便点一下就会 RangeError。
  void _collapseSelectionToStart() {
    if (_controller.codeLines.isEmpty) return;
    _controller.selection =
        const CodeLineSelection.collapsed(index: 0, offset: 0);
  }

  Future<void> _jumpToLine() async {
    final total = _lineTotal;
    final ctrl = TextEditingController();
    final line = await showDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('跳到指定行'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(
            hintText: '输入行号（从 1 开始，共 $total 行）',
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (v) {
            final n = int.tryParse(v.trim());
            if (n != null && n >= 1) Navigator.pop(c, n);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final n = int.tryParse(ctrl.text.trim());
              if (n != null && n >= 1) Navigator.pop(c, n);
            },
            child: const Text('跳转'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (line == null || !mounted) return;
    final total2 = _lineTotal;
    if (total2 <= 0) return;

    final target = (line - 1).clamp(0, total2 - 1).toInt();
    _moveCursorTo(target, 0);
    _toast('已跳到第 ${target + 1} 行');
  }

  // ==================== 查找替换 ====================

  void _toggleFind() {
    if (_showFind) {
      _closeFind();
    } else {
      _openFind();
    }
  }

  void _openFind() {
    setState(() => _showFind = true);
    // 等查找栏真正挂上去之后，再把焦点交给它自己维护的输入框。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _findController.findMode();
      // 库会拿当前选区自动填词，把它同步到我们自己的输入框里。
      final filled = _findController.findInputController.text;
      if (_findInput.text != filled) {
        _findInput.value = TextEditingValue(
          text: filled,
          selection: TextSelection.collapsed(offset: filled.length),
        );
      }
      _applyFindOptions();
    });
  }

  void _closeFind() {
    _findDebounce?.cancel();
    _pendingFindAction = null;
    _findInput.clear();
    _findController.close(); // value = null → 清空所有高亮
    setState(() => _showFind = false);
  }

  /// 把防抖里的查找词立刻提交给 re_editor。
  /// 返回 true 表示「刚提交、新一轮结果还没回来」。
  bool _flushFindInput() {
    final pending = _findDebounce?.isActive ?? false;
    _findDebounce?.cancel();
    if (!pending) return false;
    _pushFindInput();
    return true;
  }

  /// 防抖到点：把输入框里的词同步给库的查找控制器，触发一轮扫描。
  void _pushFindInput() {
    if (_findController.value == null) return; // 没在查找模式，别自己开
    final text = _findInput.text;
    if (_findController.findInputController.text == text) return;
    _findController.findInputController.text = text;
  }

  void _onFindInputChanged(String _) {
    _findDebounce?.cancel();
    _findDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      _pushFindInput();
    });
  }

  /// 把「正则 / 区分大小写」两个开关同步给 re_editor 的查找控制器。
  /// 注意它的 option 只在查找模式打开（value != null）时才有效。
  void _applyFindOptions() {
    final value = _findController.value;
    if (value == null) return;
    if (value.option.regex != _useRegex) {
      _findController.toggleRegex();
    }
    final next = _findController.value;
    if (next != null && next.option.caseSensitive != _caseSensitive) {
      _findController.toggleCaseSensitive();
    }
  }

  /// 把光标移到当前命中处并滚动到可见。
  /// 编辑器内部只在「自身未聚焦」时才自动跳，
  /// 点过正文后它就不动了，所以这里自己兜一次。
  void _syncToCurrentMatch() {
    final selection = _findController.currentMatchSelection;
    if (selection == null) return;
    _controller.selection = selection;
    // 和「跳到指定行」走同一条精确定位，不用库里那个按单行高度估算的
    // makePositionCenterIfInvisible（跨几十屏时会停偏）。
    _scrollToLine(selection.start.index);
  }

  /// 底部状态栏里的查找信息，文案和行编辑器对齐。
  /// 编辑器关掉了折叠分析（NonCodeChunkAnalyzer），代码行号就是显示行号，
  /// 所以直接 startIndex + 1，不去走 O(n) 的 index2lineIndex。
  String get _findStatusText {
    final value = _findController.value;
    if (value == null || value.option.pattern.isEmpty) return '';
    if (value.searching) return ' · 搜索中';
    final result = value.result;
    if (result == null) return '';
    if (result.matches.isEmpty) return ' · 无命中';
    final i = result.index < 0 ? 0 : result.index;
    return ' · 命中 ${i + 1}/${result.matches.length}'
        ' @ 第 ${result.matches[i].startIndex + 1} 行';
  }

  void _findNext() => _stepFind('next');

  void _findPrev() => _stepFind('prev');

  void _replaceCurrent() => _stepFind('replace');

  /// 「上一个 / 下一个 / 替换当前」共用的入口。
  ///
  /// 防抖提交后结果还没回来时，把动作记到 [_pendingFindAction]，
  /// 等这一轮扫完由 [_onFindChanged] 补执行 —— 用户不会觉得点了没反应。
  void _stepFind(String action) {
    _flushFindInput();
    final value = _findController.value;
    if (value == null || value.option.pattern.isEmpty) {
      _toast('请先输入要查找的内容');
      return;
    }
    final result = value.result;
    if (value.searching || result == null) {
      _pendingFindAction = action;
      return;
    }
    if (result.matches.isEmpty) {
      _toast('未找到');
      return;
    }
    if (action == 'prev') {
      _findController.previousMatch();
    } else if (action == 'replace') {
      _findController.replaceMatch();
    } else {
      _findController.nextMatch();
    }
    _syncToCurrentMatch();
  }

  Future<void> _replaceAll() async {
    if (_replacing) return; // 防连点
    _flushFindInput();
    final value = _findController.value;
    if (value == null || value.option.pattern.isEmpty) {
      _toast('请先输入要查找的内容');
      return;
    }
    if (value.option.regex && value.option.regExp == null) {
      _toast('正则无效');
      return;
    }
    final result = value.result;
    if (value.searching || result == null) {
      _toast('正在查找，稍等一下');
      return;
    }
    if (result.matches.isEmpty) {
      _toast('未找到');
      return;
    }
    // 替换数量必须在替换前取：换完之后 result 会被标脏并重扫。
    final count = result.matches.length;
    // 替换是一次全文重写。虽然已经丢到后台 isolate，但从按下到结果回来
    // 中间还有几十到几百毫秒；这段时间正文设成只读，免得用户敲的字被
    // 「基于旧文本」的结果覆盖。
    setState(() => _replacing = true);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    bool ok = false;
    try {
      ok = await _findController.replaceAllMatches();
    } finally {
      if (mounted) setState(() => _replacing = false);
    }
    if (!mounted) return;
    _toast(ok ? '已替换 $count 处' : '未替换（正文有改动，或替换内容与原文相同）');
  }

  // ==================== 按钮栏 ====================

  Widget _buildToolbar() {
    final rules = ref.watch(lineEditorRulesOrderedProvider);
    final colors = ref.watch(lineEditorButtonColorsProvider);
    final s = Theme.of(context).colorScheme;
    final toolbarBg = _isDefaultSkin(s)
        ? (s.brightness == Brightness.dark
            ? _defaultToolbarBgDark
            : _defaultToolbarBgLight)
        : s.surfaceVariant.withOpacity(0.25);

    return Container(
      height: 46,
      color: toolbarBg,
      child: Row(
        children: [
          Expanded(
            child: rules.isEmpty
                ? Center(
                    child: Text(
                      '点 + 添加按钮（长按编辑）。这一栏和对比页按钮栏互不影响。',
                      style: TextStyle(
                        fontSize: 11,
                        color: s.onSurfaceVariant,
                      ),
                    ),
                  )
                : ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    itemCount: rules.length,
                    itemBuilder: (ctx, i) {
                      final r = rules[i];
                      final c = colors[r.id];
                      final bg = c?.bg ?? s.surface;
                      final fg = c?.fg ?? s.onSurface;
                      final border = c?.border ?? s.outline;
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 3,
                          vertical: 7,
                        ),
                        child: GestureDetector(
                          onTap: () => _applyToolbarRule(r),
                          onLongPress: () => _editToolbarRule(r),
                          child: Container(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 1),
                            decoration: BoxDecoration(
                              color: bg,
                              borderRadius: BorderRadius.zero,
                              border: Border.all(color: border),
                            ),
                            alignment: Alignment.center,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (r.kind == RuleKind.table)
                                  Container(
                                    margin: const EdgeInsets.only(right: 4),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 1,
                                    ),
                                    decoration: BoxDecoration(
                                      color: s.primary,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      '表',
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: s.onPrimary,
                                      ),
                                    ),
                                  ),
                                Text(
                                  r.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: fg,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          SizedBox(
            width: 28,
            child: IconButton(
              icon: const Icon(Icons.add, size: 18),
              padding: EdgeInsets.zero,
              tooltip: '新建按钮',
              visualDensity: VisualDensity.compact,
              onPressed: _addToolbarRule,
            ),
          ),
          SizedBox(
            width: 28,
            child: IconButton(
              icon: const Icon(Icons.sort, size: 18),
              padding: EdgeInsets.zero,
              tooltip: '排序 / 颜色',
              visualDensity: VisualDensity.compact,
              onPressed: _showToolbarOrderDialog,
            ),
          ),
          // 折叠：和行编辑器同一套交互——点一下收起整栏，
          // 收起后只能从右上角「⋯」→「展开工具栏」再打开。
          TextButton(
            onPressed: () =>
                ref.read(lineEditorToolbarVisibleProvider.notifier).update(false),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              '折叠',
              style: TextStyle(fontSize: 11, color: s.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  // ==================== 整篇转换的分片工具 ====================

  /// 按行分批跑一个纯文本转换，每批之间让出事件循环。
  ///
  /// 只在「每个字符的处理结果与相邻行无关」时可用。9MB 全文一次转换要
  /// 几秒，全程占着主线程，遮罩出来了但界面是僵的（接近 ANR）。
  ///
  /// 批与批之间补一个换行符，拼接结果和整篇转换等价。
  /// 返回 null 表示页面在分批过程中被销毁，调用方应直接放弃。
  Future<String?> _transformChunked(String Function(String chunk) transform) async {
    const batchChars = 1 << 19;
    final lineBreak = _controller.options.lineBreak;
    final lb = lineBreak.value;
    final lines = _controller.codeLines.toList();
    final out = StringBuffer();
    final buf = StringBuffer();
    var bufLen = 0;
    var firstLine = true;
    var firstBatch = true;

    for (final line in lines) {
      if (!firstLine) {
        buf.write(lb);
        bufLen += lb.length;
      }
      firstLine = false;
      final s = line.asString(0, lineBreak);
      buf.write(s);
      bufLen += s.length;

      if (bufLen >= batchChars) {
        // 不在这里补换行：下一批的第一件事就是 buf.write(lb)，
        // 再补一次会变成两个换行（批边界凭空多一行空行）。
        out.write(transform(buf.toString()));
        firstBatch = false;
        buf.clear();
        bufLen = 0;
        if (!mounted) return null;
        await Future<void>.delayed(Duration.zero);
      }
    }

    if (bufLen > 0 || firstBatch) {
      out.write(transform(buf.toString()));
    }
    return out.toString();
  }

  /// 这条规则能不能按行分片执行。
  ///
  /// - preset / js：可能整篇解析（`dropEmptyLines` 内部就 `split('\n')`，
  ///   脚本拿到的应该是整篇），一律整篇。
  /// - replace：pattern 里出现换行或 `^ $ \A \z` 锚点时整篇——分片之后
  ///   锚点会落到每一批的开头/结尾，语义就变了。判断偏保守没关系，
  ///   误判只会退回整篇（慢一点，但结果对）。
  bool _canChunkRule(PreprocessingRule rule) {
    if (rule.kind != RuleKind.replace) return false;
    final script = rule.script;
    if (script != null && script.isNotEmpty) return false;
    final p = rule.findPattern;
    if (p.isEmpty) return true;
    if (p.contains('\n') || p.contains('\r')) return false;
    // findEscape 打开时 `\n` 是字面量反斜杠 + n，序列化后会变成真换行，
    // 等于跨行匹配，分片就错了。
    if (rule.findEscape && (p.contains(r'\n') || p.contains(r'\r'))) {
      return false;
    }
    final useRegex = rule.findRegex && !rule.findLiteral;
    if (!useRegex) return true;
    return !p.contains('^') &&
        !p.contains(r'$') &&
        !p.contains(r'\A') &&
        !p.contains(r'\z');
  }

  Future<void> _applyToolbarRule(PreprocessingRule rule) async {
    setState(() {
      _processing = true;
      _processingText = '正在执行「${rule.name}」…';
    });
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;

    try {
      // 能分片就分片（界面不冻），不能就整篇跑（结果优先）。
      final String? next;
      if (rule.kind == RuleKind.table) {
        // 规则表整篇跑：水印表会删空行，分片在边界上会误删，故不分片。
        next = _applyTableRule(_controller.text, rule);
      } else {
        next = _canChunkRule(rule)
            ? await _transformChunked((chunk) => applyOneRule(chunk, rule))
            : applyOneRule(_controller.text, rule);
      }
      if (next == null || !mounted) return;
      // 空安全提升不会带进闭包：setState 回调里用的是声明类型 String?，
      // 先在这里把非空的 next 固化成新局部变量，闭包里才拿得到 String。
      final nextText = next;
      final lines = await nextText.codeLinesAsync;
      if (!mounted) return;
      _suppressChange = true;
      _controller.codeLines = lines;
      _suppressChange = false;
      _collapseSelectionToStart();
      setState(() {
        _lastLines = _controller.codeLines;
        _dirty = true; // 规则改了正文，算未保存
        _charCount = nextText.length;
      });
      _toast('已应用「${rule.name}」');
    } catch (e) {
      _toast('执行失败：$e');
    } finally {
      if (mounted) {
        setState(() {
          _processing = false;
          _processingText = '';
        });
      }
    }
  }

  /// 按规则表顺序执行：内置表取实时内容，自定义表用内嵌 content（按普通文字语义）。
  String _applyTableRule(String text, PreprocessingRule rule) {
    final regexText = ref.read(regexRulesTextProvider);
    final keywordText = ref.read(keywordRulesTextProvider);
    final watermarkText = ref.read(watermarkWordsProvider);
    var out = text;
    for (final t in rule.tables) {
      if (t == 'regex') {
        out = applyRegexRules(out, regexText);
      } else if (t == 'keyword') {
        out = applyKeywordRules(out, keywordText);
      } else if (t == 'watermark') {
        out = applyWatermarkRules(out, watermarkText);
      } else if (t.startsWith('custom_')) {
        final ct = rule.customTables[t];
        if (ct != null) out = applyKeywordRules(out, ct.content);
      }
    }
    return out;
  }

  Future<void> _addToolbarRule() async {
    final rule = await showDialog<PreprocessingRule>(
      context: context,
      builder: (_) => RuleEditorDialog(
        showCopyToPreprocess: false,
        showTableKind: true,
      ),
    );
    if (rule == null || !mounted) return;
    ref.read(lineEditorRulesProvider.notifier).add(rule);
    _toast('已添加按钮「${rule.name}」');
  }

  Future<void> _editToolbarRule(PreprocessingRule rule) async {
    final updated = await showDialog<PreprocessingRule>(
      context: context,
      builder: (_) => RuleEditorDialog(
        initial: rule,
        showCopyToPreprocess: true,
        showTableKind: true,
        onCopyToPreprocess: (copied) {
          _toast('「${copied.name}」已复制到对比规则设置里');
        },
      ),
    );
    if (updated == null || !mounted) return;
    ref.read(lineEditorRulesProvider.notifier).updateRule(updated);
  }

  Future<void> _showToolbarOrderDialog() async {
    final rules = ref.read(lineEditorRulesOrderedProvider);
    if (rules.isEmpty) {
      _toast('还没有按钮');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (c) => _ToolbarOrderDialog(rules: rules),
    );
  }

  // ==================== 编码（重新解码 / 保存编码） ====================

  /// 手动切换编码 + 指定保存编码。菜单项文案和行编辑器一致（「编码：xxx」）。
  ///
  /// 自动探测（detect + ICU 复核）对少数文件仍然会判错——GBK / Big5 /
  /// Shift-JIS 的字节范围高度重叠，一旦判错整篇就是乱码，而且没法修。
  /// 这里把候选列出来让用户自己指定，按指定编码重新解一遍原始字节。
  ///
  /// 用的是加载时缓存的 [_rawBytes]，不是重新读文件：
  /// 用户在编辑器里可能已经改过内容但没保存，重新读会把改动冲掉。
  Future<void> _showEncodingDialog() async {
    final bytes = _rawBytes;
    if (bytes == null) {
      _toast('文件还没读完，稍等一下');
      return;
    }

    const candidates = <EncodingType>[
      EncodingType.utf8,
      EncodingType.gbk,
      EncodingType.gb18030,
      EncodingType.big5,
      EncodingType.utf16le,
      EncodingType.utf16be,
      EncodingType.shiftJis,
    ];

    // 返回 EncodingType = 重新解码；返回 _SaveEncoding = 只改保存编码。
    final picked = await showDialog<Object>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('编码'),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 6),
            child: Text(
              '当前内容乱码时，选一个编码重新解一遍。\n'
              '重新解码会丢弃屏幕上的改动，从文件重新载入。',
              style: TextStyle(fontSize: 12),
            ),
          ),
          for (final e in candidates)
            SimpleDialogOption(
              onPressed: () => Navigator.pop<Object>(c, e),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Icon(
                      e.label == _detectedEncoding
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      size: 18,
                      color: e.label == _detectedEncoding
                          ? Theme.of(c).colorScheme.primary
                          : null,
                    ),
                    const SizedBox(width: 12),
                    Text(e.label),
                  ],
                ),
              ),
            ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 6),
            child: Text(
              '保存时使用的编码',
              style: TextStyle(fontSize: 12),
            ),
          ),
          for (final e in _SaveEncoding.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop<Object>(c, e),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Icon(
                      e == _saveEncoding
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      size: 18,
                      color: e == _saveEncoding
                          ? Theme.of(c).colorScheme.primary
                          : null,
                    ),
                    const SizedBox(width: 12),
                    Text('保存编码：${e.label}'),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;

    // 选了「保存编码」：只改设置，不动正文。
    if (picked is _SaveEncoding) {
      final saveAs = picked;
      setState(() => _saveEncoding = saveAs);
      _toast('保存编码已设为 ${saveAs.label}');
      return;
    }

    final enc = picked is EncodingType ? picked : null;
    if (enc == null) return;

    if (_dirty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('有未保存的修改'),
          content: const Text('切换编码会按新编码重新读一遍文件，'
              '屏幕上的改动会丢失。要继续吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('继续切换'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }

    setState(() {
      _processing = true;
      _processingText = '正在按 ${enc.label} 重新解码…';
    });
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;

    try {
      final text = await _decodeWithEncoding(bytes, enc);
      if (!mounted) return;
      final lines = await text.codeLinesAsync;
      if (!mounted) return;

      _suppressChange = true;
      _controller.codeLines = lines;
      _suppressChange = false;
      _collapseSelectionToStart();

      setState(() {
        _lastLines = _controller.codeLines;
        _detectedEncoding = enc.label;
        _saveEncoding = _guessSaveEncoding(enc);
        _dirty = false;
        _charCount = text.length;
        // 换了正文，旧的勾选/区间状态全部作废
        _selectMode = false;
        _selectedLines.clear();
        _pickingRange = false;
        _rangeStart = null;
        _processing = false;
        _processingText = '';
      });
      _toast('已按 ${enc.label} 重新载入');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _processing = false;
        _processingText = '';
      });
      _toast('解码失败：$e');
    }
  }

  /// 按指定编码解码，**不做可读性复核**。
  ///
  /// 探测器会复核并可能把用户手动选的编码又换回去（它以为自己更懂），
  /// 手动切换必须绕开这一步。Android 上优先走系统 ICU（全码表、
  /// 不会静默错位），失败或平台不支持时回落 Dart 侧解码。
  Future<String> _decodeWithEncoding(
    Uint8List bytes,
    EncodingType enc,
  ) async {
    const androidNames = <EncodingType, String>{
      EncodingType.gbk: 'GBK',
      EncodingType.gb2312: 'GBK',
      EncodingType.gb18030: 'GB18030',
      EncodingType.big5: 'Big5',
      EncodingType.shiftJis: 'Shift-JIS',
    };
    final name = androidNames[enc];
    if (name != null && EncodingBridge.isSupported) {
      final r = await EncodingBridge.decode(bytes, name);
      if (r != null) return r;
    }
    return EncodingDetector.decodeChunked(bytes, enc);
  }

  // ==================== 简繁转换 ====================

  /// 整篇简繁转换（和行编辑器同一个词库、同一套交互）。
  Future<void> _convertTranslation() async {
    if (_processing) return;
    setState(() {
      _processing = true;
      _processingText = '正在简繁转换…';
    });
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;

    try {
      await TranslationTable.instance.init();
      if (!mounted) return;
      if (TranslationTable.instance.isEmpty) {
        _toast('词库为空');
        return;
      }

      // 分片转换：词表里不可能有含换行的 key，所以按行切开、每批独立转换
      // 和整篇转换完全等价，只是期间界面不会冻住。
      final next = await _transformChunked(TranslationTable.instance.convert);
      if (next == null || !mounted) return;
      // 同上：提升带不进闭包，先固化成非空局部变量。
      final nextText = next;
      final lines = await nextText.codeLinesAsync;
      if (!mounted) return;

      _suppressChange = true;
      _controller.codeLines = lines;
      _suppressChange = false;
      _collapseSelectionToStart();

      setState(() {
        _lastLines = _controller.codeLines;
        _dirty = true; // 正文被改写，算未保存
        _charCount = nextText.length;
        _selectMode = false;
        _selectedLines.clear();
        _pickingRange = false;
        _rangeStart = null;
      });
      _toast('已转换');
    } catch (e) {
      _toast('转换失败：$e');
    } finally {
      if (mounted) {
        setState(() {
          _processing = false;
          _processingText = '';
        });
      }
    }
  }

  Future<void> _openTranslationTable() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const TranslationTableScreen(),
      ),
    );
  }

  // ==================== 字号 ====================

  /// 「字号 +1」「字号 -1」两项合并成这一个：菜单里显示当前值，
  /// 点开后既能用滑块拖动，也能点 − / ＋ 一格一格调。和行编辑器一致。
  Future<void> _showFontSizeDialog() async {
    var tmp = _fontSize;
    await showDialog<double>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setSt) => AlertDialog(
          title: const Text('字号'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline),
                    tooltip: '减小',
                    onPressed: tmp <= 8
                        ? null
                        : () =>
                            setSt(() => tmp = (tmp - 1).clamp(8, 36).toDouble()),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '${tmp.round()}',
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(width: 12),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline),
                    tooltip: '增大',
                    onPressed: tmp >= 36
                        ? null
                        : () =>
                            setSt(() => tmp = (tmp + 1).clamp(8, 36).toDouble()),
                  ),
                ],
              ),
              Slider(
                min: 8,
                max: 36,
                value: tmp.clamp(8, 36).toDouble(),
                onChanged: (v) => setSt(() => tmp = v),
              ),
              Text(
                'Aa 示例文字',
                style: TextStyle(fontSize: tmp, fontFamily: 'monospace'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, tmp),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    ).then((v) {
      if (v != null && mounted) {
        setState(() => _fontSize = v.clamp(8, 36).toDouble());
      }
    });
  }

  // ==================== 行号宽度 ====================

  /// 行号栏最小宽度。行数多时实际宽度还会按行号位数自动加宽，
  /// 所以这里拖小不会把行号挤掉。
  Future<void> _showLineNumberWidthDialog() async {
    var tmp = _lineNumberWidth;
    final r = await showDialog<double>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setSt) => AlertDialog(
          title: const Text('行号宽度'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${tmp.round()} px'),
              Slider(
                min: 24,
                max: 120,
                value: tmp.clamp(24, 120).toDouble(),
                onChanged: (v) => setSt(() => tmp = v),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, tmp),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    if (r != null && mounted) {
      setState(() => _lineNumberWidth = r);
    }
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

  // ==================== 查找栏 ====================

  Widget _buildFindBar() {
    final s = Theme.of(context).colorScheme;
    final value = _findController.value;
    final result = value?.result;
    final searching = value?.searching ?? false;
    final count = result?.matches.length ?? 0;
    final current = result == null || count == 0 ? 0 : result.index + 1;
    final counterText =
        searching ? '搜索中' : (result == null ? '0/0' : '$current/$count');

    return Material(
      color: s.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: '关闭查找',
                  visualDensity: VisualDensity.compact,
                  onPressed: _closeFind,
                ),
                Expanded(
                  child: TextField(
                    // 用自己持有的控制器收按键（300ms 防抖后才同步给库），
                    // 焦点节点仍用库的：findMode() 是靠它弹键盘的。
                    controller: _findInput,
                    focusNode: _findController.findInputFocusNode,
                    cursorColor: s.primary,
                    decoration: const InputDecoration(
                      hintText: '查找',
                      isDense: true,
                      border: InputBorder.none,
                    ),
                    onChanged: _onFindInputChanged,
                    onSubmitted: (_) => _findNext(),
                  ),
                ),
                Text(
                  counterText,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                IconButton(
                  icon: const Icon(Icons.arrow_upward),
                  tooltip: '上一个',
                  // 和下面「替换当前 / 全部替换」同一个主色（蓝）
                  color: s.primary,
                  visualDensity: VisualDensity.compact,
                  onPressed: _findPrev,
                ),
                IconButton(
                  icon: const Icon(Icons.arrow_downward),
                  tooltip: '下一个',
                  color: s.primary,
                  visualDensity: VisualDensity.compact,
                  onPressed: _findNext,
                ),
              ],
            ),
            Row(
              children: [
                const SizedBox(width: 48),
                Expanded(
                  child: TextField(
                    controller: _findController.replaceInputController,
                    focusNode: _findController.replaceInputFocusNode,
                    cursorColor: s.primary,
                    decoration: const InputDecoration(
                      hintText: '替换为（留空 = 删掉）',
                      isDense: true,
                      border: InputBorder.none,
                    ),
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: s.primary,
                  ),
                  onPressed: _replaceCurrent,
                  child: const Text('替换当前'),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: s.primary,
                  ),
                  // 替换期间（同步占着主线程）不能点第二次
                  onPressed: _replacing ? null : _replaceAll,
                  child: Text(_replacing ? '替换中…' : '全部替换'),
                ),
              ],
            ),
            Row(
              children: [
                const SizedBox(width: 8),
                _toggle(
                  label: '正则',
                  value: _useRegex,
                  onTap: () {
                    setState(() => _useRegex = !_useRegex);
                    _applyFindOptions();
                  },
                ),
                _toggle(
                  label: '区分大小写',
                  value: _caseSensitive,
                  onTap: () {
                    setState(() => _caseSensitive = !_caseSensitive);
                    _applyFindOptions();
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 「正则 / 区分大小写」这一组：小开关 + 文字，和行编辑器完全同一套尺寸。
  /// 点开关或点文字都能切换。
  /// 开关尺寸按 12px 文字的行高对齐（高 14 / 宽 24 / 圆点 10），不吃版面。
  Widget _toggle({
    required String label,
    required bool value,
    required VoidCallback onTap,
  }) {
    final s = Theme.of(context).colorScheme;
    const trackW = 24.0;
    const trackH = 14.0;
    const thumbD = 10.0;

    // 打开：轨道用按钮同款主色，圆点是「很浅的蓝」；关闭：整组灰。
    final trackColor = value
        ? s.primary
        : s.onSurfaceVariant.withValues(alpha: 0.35);
    final thumbColor = value
        ? Color.lerp(Colors.white, s.primary, 0.30)!
        : Colors.white;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOut,
              width: trackW,
              height: trackH,
              padding: const EdgeInsets.symmetric(horizontal: 2),
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              decoration: BoxDecoration(
                color: trackColor,
                borderRadius: BorderRadius.circular(trackH / 2),
              ),
              child: Container(
                width: thumbD,
                height: thumbD,
                decoration: BoxDecoration(
                  color: thumbColor,
                  shape: BoxShape.circle,
                ),
              ),
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: value ? FontWeight.bold : FontWeight.normal,
                color: value ? s.primary : s.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ==================== 多选行 ====================

  void _toggleSelectMode() {
    if (_selectMode) {
      _exitSelectMode();
      return;
    }
    // 进选择模式先收键盘，否则焦点还留在正文里，键盘一直杵着。
    FocusScope.of(context).unfocus();
    final sel = _controller.selection;
    setState(() {
      _selectMode = true;
      _selectedLines.clear();
      _pickingRange = false;
      _rangeStart = null;
    });
    // 清掉原生选区，避免和"按行勾选"两套高亮混在一起。
    _controller.selection = CodeLineSelection.collapsed(
      index: sel.extentIndex,
      offset: sel.extentOffset,
    );
  }

  void _exitSelectMode() {
    if (!_selectMode) return;
    setState(() {
      _selectMode = false;
      _selectedLines.clear();
      _pickingRange = false;
      _rangeStart = null;
    });
  }

  /// 点行号 → 勾选/取消整行（区间拾取时则是定起点/终点）。
  /// 行号栏每行自己带一个手势，不用在编辑器上盖透明层——
  /// 盖层会把正文的滚动一起挡住（Stack 命中测试到第一层就停了）。
  void _onLineTap(int index) {
    // 区间拾取：第一次点定起点（偏黄绿），第二次点把 [lo, hi] 全勾上。
    if (_pickingRange) {
      final start = _rangeStart;
      if (start == null) {
        setState(() => _rangeStart = index);
        return;
      }
      final lo = start < index ? start : index;
      final hi = start < index ? index : start;
      setState(() {
        for (var n = lo; n <= hi; n++) {
          _selectedLines.add(n);
        }
        _rangeStart = null;
        _pickingRange = false;
      });
      _toast(
        lo == hi
            ? '已勾选第 ${lo + 1} 行'
            : '已勾选第 ${lo + 1}~${hi + 1} 行，共 ${hi - lo + 1} 行',
        const Duration(milliseconds: 1000),
      );
      return;
    }

    setState(() {
      if (!_selectedLines.remove(index)) _selectedLines.add(index);
    });
  }

  /// 按行号升序拼接勾选行的内容（和行编辑器一致）。
  String _selectedLinesText() {
    final lines = _controller.codeLines;
    final nums = _selectedLines.toList()..sort();
    final buf = StringBuffer();
    var first = true;
    for (final n in nums) {
      if (n < 0 || n >= lines.length) continue;
      if (!first) buf.write('\n');
      buf.write(lines[n].text);
      first = false;
    }
    return buf.toString();
  }

  Future<void> _copySelectedLines() async {
    if (_selectedLines.isEmpty) return;
    final count = _selectedLines.length;
    await Clipboard.setData(ClipboardData(text: _selectedLinesText()));
    if (!mounted) return;
    _exitSelectMode();
    _toast('已复制 $count 行', const Duration(milliseconds: 1000));
  }

  Future<void> _cutSelectedLines() async {
    if (_selectedLines.isEmpty) return;
    final count = _selectedLines.length;
    await Clipboard.setData(ClipboardData(text: _selectedLinesText()));
    if (!mounted) return;
    _deleteSelectedLines();
    if (!mounted) return;
    setState(() {
      _selectMode = false;
      _pickingRange = false;
      _rangeStart = null;
    });
    _toast('已剪切 $count 行', const Duration(milliseconds: 1000));
  }

  /// 删除勾选行。不连续删除，行号整体前移。
  ///
  /// 用 [CodeLines.of] 重新装一遍保留行：复用已有的 CodeLine 对象，
  /// 不用把整篇拼成一个 20MB 字符串再切开。代价是撤销历史会丢，
  /// 这里明确不做撤销（按需求）。
  void _deleteSelectedLines() {
    if (_selectedLines.isEmpty) return;

    final lines = _controller.codeLines;
    final removed = Set<int>.of(_selectedLines);
    var firstRemoved = lines.length;
    final kept = <CodeLine>[];
    for (var i = 0; i < lines.length; i++) {
      if (removed.contains(i)) {
        if (i < firstRemoved) firstRemoved = i;
      } else {
        kept.add(lines[i]);
      }
    }

    _controller.codeLines = CodeLines.of(kept);

    // 光标可能指向已经删掉的行，挪到被删区域的开头，避免越界。
    final total = _controller.codeLines.length;
    final target = total <= 0 ? 0 : firstRemoved.clamp(0, total - 1).toInt();
    _controller.selection =
        CodeLineSelection.collapsed(index: target, offset: 0);

    setState(_selectedLines.clear);
  }

  Widget _buildMultiSelectBar() {
    final has = _selectedLines.isNotEmpty;

    Widget btn(String label, VoidCallback? onTap) {
      return Expanded(
        child: TextButton(
          onPressed: onTap,
          style: TextButton.styleFrom(
            padding: EdgeInsets.zero,
            minimumSize: const Size(0, 34),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
            shape: const RoundedRectangleBorder(),
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              label,
              maxLines: 1,
              softWrap: false,
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ),
      );
    }

    return Container(
      color: _kSelectBlue.withValues(alpha: 0.10),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          btn(
            _pickingRange ? '取消区间' : '区间选择',
            () => setState(() {
              _pickingRange = !_pickingRange;
              // 重新拾取时清掉残留的起点
              if (_pickingRange) _rangeStart = null;
            }),
          ),
          btn('复制', has ? _copySelectedLines : null),
          btn('剪切', has ? _cutSelectedLines : null),
          btn(
            '删除',
            has
                ? () {
                    final c = _selectedLines.length;
                    _deleteSelectedLines();
                    setState(() {
                      _selectMode = false;
                      _pickingRange = false;
                      _rangeStart = null;
                    });
                    _toast('已删除 $c 行', const Duration(milliseconds: 1000));
                  }
                : null,
          ),
          btn(
            '清空选中行',
            (has || _rangeStart != null)
                ? () => setState(() {
                      _selectedLines.clear();
                      // 区间拾取到一半也一起收掉，否则起点还亮着，
                      // 下一次点行号会莫名其妙连成一段。
                      _rangeStart = null;
                      _pickingRange = false;
                    })
                : null,
          ),
        ],
      ),
    );
  }

  // ==================== 编辑器本体 ====================

  Widget _buildEditorArea() {
    final s = Theme.of(context).colorScheme;

    final gutterStyle = TextStyle(
      fontSize: _fontSize,
      fontFamily: 'monospace',
      height: 1.4,
      color: s.onSurface.withOpacity(0.55),
    );
    // 行号栏宽度在这里算，行号栏本身和上面那层"点行号"命中层共用同一个值。
    // 两边分别算的话，字号/位数一变就可能差几像素，点到的就不是看到的那一行。
    final gutterWidth = _gutterWidthFor(gutterStyle, _cachedLineCount);

    final editor = CodeEditor(
      controller: _controller,
      findController: _findController,
      toolbarController: _toolbarController,
      scrollController: _scrollCtrl,
      // 纯文本不需要 {} [] 折叠分析，关掉省开销
      chunkAnalyzer: const NonCodeChunkAnalyzer(),
      // 关闭自动换行 = 允许横向滚动
      wordWrap: !_noWrap,
      // 打开文件时不主动弹键盘
      autofocus: false,
      // 多选行模式下正文只读：避免点行号选行时顺手把光标插进正文、
      // 或者误触键盘。行号栏的点击由上面那层命中层处理。
      // 全部替换进行中同样只读：替换结果基于「按下那一刻」的文本，
      // 这期间敲进去的字会被覆盖掉。
      readOnly: _selectMode || _replacing,
      hint: '（空文件）',
      // 贴边：正文不从边上再缩进一圈。行号栏自己带 6px 右间距，
      // 和正文之间不会粘在一起，所以这里可以给 0。
      padding: EdgeInsets.zero,
      // 不画外框：行编辑器也没有。加了 border 之后正文和行号会被一个大方框
      // 整个圈起来，看起来像个输入框，和行编辑器不一致。
      // 滚动条平时不显示（re_editor 默认是 thumbVisibility: true，一直挂着
      // 一条灰条），滚动时才浮出来；横向不画，和行编辑器的观感一致。
      scrollbarBuilder: (context, child, details) {
        if (details.direction != AxisDirection.down) return child;
        return Scrollbar(
          controller: details.controller,
          thumbVisibility: false,
          child: child,
        );
      },
      // 长行兜底：单行超过这个字符数就不再为它精确折行/测量宽度，
      // 只渲染前 N 个字符。否则一行几十万字符会让 TextPainter 去算一个
      // 超宽的段落、横向滚动条也被撑到几百万像素，整帧卡死。
      // 对纯文本/小说这种场景，超长行（如一条超长日志）几乎不存在，
      // 截断渲染无感知；正常行不受影响。
      maxLengthSingleLineRendering: 2048,
      // 选中行的整行背景。行号栏已经有底色了，但正文这一侧原来只有左边的
      // 数字变色，右边的正文看起来毫无反应；这里把整行铺一条淡底色。
      // 与行号栏用同一组颜色，两边的"选中"看起来是同一件事。
      //
      // 传副本而不是 _selectedLines 本身：这个字段是原地增删的，直接传引用
      // 会让「新列表」和「旧列表」是同一个对象，判等永远相等，画不出来。
      highlightLineGroups: [
        if (_selectedLines.isNotEmpty)
          CodeLineHighlight(
            lines: Set<int>.of(_selectedLines),
            color: _kSelectBlue.withValues(alpha: 0.12),
          ),
        if (_rangeStart != null)
          CodeLineHighlight(
            lines: {_rangeStart!},
            color: _kRangeStart.withValues(alpha: 0.18),
          ),
      ],
      style: CodeEditorStyle(
        fontSize: _fontSize,
        fontFamily: 'monospace',
        fontHeight: 1.4,
        textColor: s.onSurface,
        cursorColor: s.primary,
        // 其余匹配：黄底
        highlightColor: _matchYellow,
        // 当前命中（编辑器会把命中变成选区）：粉底
        selectionColor: _matchPink,
      ),
      indicatorBuilder: (ctx, editingController, chunkController, notifier) {
        // 给外面那层命中层留个引用（只存引用，不 setState，
        // 滚动时不会连累整页重建）。
        _linesNotifier = notifier;
        return _SelectableLineNumber(
          controller: editingController,
          notifier: notifier,
          selected: _selectedLines,
          rangeStart: _rangeStart,
          width: gutterWidth,
          textStyle: gutterStyle,
          // 行号栏宽度和行号位数都由这里算好的缓存值统一供给：
          // 行号渲染每次滚动都重建，不能再现场调 controller.lineCount
          // 去遍历所有 segment。
          lineCount: _cachedLineCount,
        );
      },
    );

    // 外面这层 Listener 只做一件事：用户一碰屏幕就放弃还在补帧的跳转，
    // 免得刚点的「跳到结尾」跟他自己的拖动抢滚动位置。
    // deferToChild 意味着它不改变命中范围，下面的滚动/长按完全没影响。
    return Listener(
      onPointerDown: (_) => _cancelPark(),
      child: Stack(
        fit: StackFit.expand,
        children: [
          editor,
          // 选择模式：在行号栏上面盖一条命中层。
          //
          // 为什么不在行号栏内部接点击：行号栏在 re_editor 的 Scrollable
          // 内容区里，而 Flutter 的 Scrollable 在惯性滑动（ballistic）
          // 期间会对整个内容区套 IgnorePointer —— 那段时间点行号完全
          // 收不到事件，表现就是"点了没反应，滑一下才好"。这一层在滚动区
          // 外面，不受影响。
          //
          // 用 translucent：事件照样往下传，正文的滚动/长按完全不受影响。
          if (_selectMode)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: gutterWidth,
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: _onGutterDown,
                onPointerUp: _onGutterUp,
                onPointerCancel: (_) => _resetGutterPointer(),
                child: const SizedBox.expand(),
              ),
            ),
        ],
      ),
    );
  }

  /// 行号栏宽度：按最大行号的位数实测，再和菜单里设的「行号宽度」取较大值。
  double _gutterWidthFor(TextStyle style, int lineCount) {
    final digits = lineCount.toString().length;
    final minDigits = digits < 3 ? 3 : digits;
    final measure = TextPainter(
      text: TextSpan(text: '0' * minDigits, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    return math.max(measure.width + 14, _lineNumberWidth);
  }

  // ==================== 点行号 ====================

  /// 惯性滑动还在跑就停住。
  /// 不停的话：点了行号，内容还在飞，刚变蓝的那行立刻滑出屏幕。
  void _stopScrollIfAny() {
    final c = _scrollCtrl.verticalScroller;
    if (!c.hasClients) return;
    final pos = c.position;
    if (!pos.isScrollingNotifier.value) return;
    c.jumpTo(pos.pixels);
  }

  void _resetGutterPointer() {
    _gutterPointer = null;
    _gutterDownPos = null;
    _gutterDownAt = null;
    _gutterDownIndex = null;
  }

  /// 命中层里的 y → 行下标。
  /// 段落坐标的原点就是编辑器内容区左上角（paddingTop 已经算在 top 里），
  /// 所以这里不需要再减任何偏移，直接比。
  int? _lineIndexAt(double dy) {
    final paragraphs = _linesNotifier?.value?.paragraphs;
    if (paragraphs == null || paragraphs.isEmpty) return null;
    for (final p in paragraphs) {
      if (dy >= p.top && dy < p.bottom) return p.index;
    }
    return null;
  }

  void _onGutterDown(PointerDownEvent e) {
    if (!_selectMode) return;
    // 多指只认第一根。
    if (_gutterPointer != null && _gutterPointer != e.pointer) return;
    _stopScrollIfAny();
    _gutterPointer = e.pointer;
    _gutterDownPos = e.position;
    _gutterDownAt = DateTime.now();
    _gutterDownIndex = _lineIndexAt(e.localPosition.dy);
  }

  void _onGutterUp(PointerUpEvent e) {
    // 不是我们记住的那根手指（多指时的第二根），直接忽略，
    // 别把第一根手指的状态清掉。
    if (_gutterPointer != e.pointer) return;
    final down = _gutterDownPos;
    final at = _gutterDownAt;
    final index = _gutterDownIndex;
    _resetGutterPointer();
    if (down == null || at == null || index == null) return;
    // 按下期间退出了选择模式（比如另一根手指点了"退出"），不再勾选。
    if (!_selectMode) return;
    // 位移/时长超限 = 滚动或长按，不算点击。
    if ((e.position - down).distance > _kGutterTapSlop) return;
    if (DateTime.now().difference(at) > _kGutterTapTimeout) return;
    _onLineTap(index);
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final ok = await _confirmLeave();
        if (ok && mounted) Navigator.pop(context);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            widget.fileName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.vertical_align_top),
              tooltip: '跳到开头',
              visualDensity: VisualDensity.compact,
              onPressed: _jumpToTop,
            ),
            IconButton(
              icon: const Icon(Icons.vertical_align_bottom),
              tooltip: '跳到结尾',
              visualDensity: VisualDensity.compact,
              onPressed: _jumpToBottom,
            ),
            IconButton(
              icon: const Icon(Icons.find_in_page),
              tooltip: '查找 / 替换',
              visualDensity: VisualDensity.compact,
              onPressed: _toggleFind,
            ),
            TextButton(
              onPressed: _toggleSelectMode,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
              child: Text(_selectMode ? '退出多选' : '多选行'),
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              onSelected: (v) {
                switch (v) {
                  case 'jumpToLine':
                    _jumpToLine();
                    break;
                  case 'convertTranslation':
                    _convertTranslation();
                    break;
                  case 'translationTable':
                    _openTranslationTable();
                    break;
                  case 'saveAs':
                    _saveAs();
                    break;
                  case 'encoding':
                    _showEncodingDialog();
                    break;
                  case 'toggleToolbar':
                    ref
                        .read(lineEditorToolbarVisibleProvider.notifier)
                        .update(!ref.read(lineEditorToolbarVisibleProvider));
                    break;
                  case 'fontSize':
                    _showFontSizeDialog();
                    break;
                  case 'lineNumberWidth':
                    _showLineNumberWidthDialog();
                    break;
                  case 'wrap':
                    setState(() => _noWrap = !_noWrap);
                    break;
                }
              },
              itemBuilder: (_) {
                final toolbarVisible =
                    ref.read(lineEditorToolbarVisibleProvider);
                return [
                  const PopupMenuItem(
                    value: 'jumpToLine',
                    child: Row(
                      children: [
                        Icon(Icons.format_list_numbered),
                        SizedBox(width: 10),
                        Text('跳到指定行'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'convertTranslation',
                    child: Row(
                      children: [
                        Icon(Icons.translate),
                        SizedBox(width: 10),
                        Text('简繁转换'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'translationTable',
                    child: Row(
                      children: [
                        Icon(Icons.table_chart),
                        SizedBox(width: 10),
                        Text('管理简繁转换表'),
                      ],
                    ),
                  ),
                  const PopupMenuDivider(),
                  const PopupMenuItem(
                    value: 'saveAs',
                    child: Row(
                      children: [
                        Icon(Icons.save_as),
                        SizedBox(width: 10),
                        Text('另存为'),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'encoding',
                    child: Row(
                      children: [
                        const Icon(Icons.code),
                        const SizedBox(width: 10),
                        Text('编码：$_detectedEncoding'),
                      ],
                    ),
                  ),
                  const PopupMenuDivider(),
                  PopupMenuItem(
                    value: 'fontSize',
                    child: Row(
                      children: [
                        const Icon(Icons.format_size),
                        const SizedBox(width: 10),
                        Text('字号（${_fontSize.round()}）'),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'toggleToolbar',
                    child: Row(
                      children: [
                        Icon(
                          toolbarVisible
                              ? Icons.dashboard_customize
                              : Icons.dashboard_customize_outlined,
                        ),
                        const SizedBox(width: 10),
                        Text(toolbarVisible ? '隐藏工具栏' : '展开工具栏'),
                      ],
                    ),
                  ),
                  const PopupMenuDivider(),
                  const PopupMenuItem(
                    value: 'lineNumberWidth',
                    child: Row(
                      children: [
                        Icon(Icons.straighten),
                        SizedBox(width: 10),
                        Text('行号宽度'),
                      ],
                    ),
                  ),
                  // 全文编辑器额外有「自动换行」（行编辑器是逐行列表，没有这个概念）
                  PopupMenuItem(
                    value: 'wrap',
                    child: Row(
                      children: [
                        Icon(_noWrap ? Icons.wrap_text : Icons.notes),
                        const SizedBox(width: 10),
                        Text(_noWrap ? '自动换行：关' : '自动换行：开'),
                      ],
                    ),
                  ),
                ];
              },
            ),
            TextButton.icon(
              onPressed: _saving || _loading ? null : _save,
              icon: Icon(
                _saving ? Icons.hourglass_top : Icons.save,
                color: (_saving || _loading)
                    ? null
                    : Theme.of(context).colorScheme.primary,
              ),
              label: Text(
                '保存',
                style: TextStyle(
                  color: (_saving || _loading)
                      ? null
                      : Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    if (ref.watch(lineEditorToolbarVisibleProvider))
                      _buildToolbar(),
                    if (_processing)
                      Container(
                        width: double.infinity,
                        color: Theme.of(context)
                            .colorScheme
                            .tertiaryContainer,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        child: Text(
                          _processingText,
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context)
                                .colorScheme
                                .onTertiaryContainer,
                          ),
                        ),
                      ),
                    if (_showFind) _buildFindBar(),
                    // 内容区贴边：行编辑器外面没有任何留白，这里也去掉。
                    Expanded(child: _buildEditorArea()),
                    if (_selectMode) _buildMultiSelectBar(),
                    Container(
                      width: double.infinity,
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceVariant
                          .withOpacity(0.4),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      child: Text(
                        '$_charCount 字符 · $_lineTotal 行 · $_encodingLabel'
                        '${_noWrap ? " · 不换行" : ""}'
                        '$_findStatusText'
                        '${_selectMode ? " · 已选 ${_selectedLines.length} 行" : ""}'
                        '${_dirty ? " · 未保存" : ""}',
                        style: Theme.of(context).textTheme.labelSmall,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  /// 底部提示条。时长默认和行编辑器一样是 4 秒；
  /// 多选那几条操作（勾选区间 / 复制 / 剪切 / 删除）传 1 秒 —— 结果当场
  /// 就看得见，没必要挂四秒挡住正文。
  void _toast(String msg, [Duration? duration]) {
    if (!mounted) return;
    // 先收掉上一条再弹，新提示不会排在旧提示后面等它走完。
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: duration ?? const Duration(seconds: 4),
        ),
      );
  }
}

// ==================== 按钮排序 / 颜色对话框 ====================

class _ToolbarOrderDialog extends ConsumerStatefulWidget {
  const _ToolbarOrderDialog({required this.rules});

  final List<PreprocessingRule> rules;

  @override
  ConsumerState<_ToolbarOrderDialog> createState() =>
      _ToolbarOrderDialogState();
}

class _ToolbarOrderDialogState extends ConsumerState<_ToolbarOrderDialog> {
  late List<PreprocessingRule> _rules;

  @override
  void initState() {
    super.initState();
    _rules = List<PreprocessingRule>.from(widget.rules);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      insetPadding: const EdgeInsets.all(8),
      titlePadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      contentPadding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      actionsPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      title: const Text('按钮排序 / 颜色'),
      content: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.of(context).size.height * 0.7,
        child: ReorderableListView.builder(
          itemCount: _rules.length,
          onReorder: (oldIndex, newIndex) {
            setState(() {
              if (newIndex > oldIndex) newIndex--;
              final item = _rules.removeAt(oldIndex);
              _rules.insert(newIndex, item);
            });
          },
          itemBuilder: (ctx, i) {
            final r = _rules[i];
            return ListTile(
              key: ValueKey<String>('order:${r.id}'),
              leading: const Icon(Icons.drag_handle),
              title: Text(r.name),
              subtitle: Text(
                ruleSubtitle(r),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '设置颜色',
                    icon: const Icon(Icons.palette),
                    onPressed: () => _openColorPanel(r),
                  ),
                  IconButton(
                    tooltip: '删除',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () {
                      setState(() => _rules.removeAt(i));
                    },
                  ),
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('保存'),
        ),
      ],
    );
  }

  void _openColorPanel(PreprocessingRule r) {
    showDialog<void>(
      context: context,
      builder: (_) => _ButtonColorDialog(
        ruleId: r.id,
        ruleName: r.name,
      ),
    );
  }

  void _save() {
    ref
        .read(lineEditorOrderProvider.notifier)
        .setAll(_rules.map((r) => r.id).toList());
    ref.read(lineEditorRulesProvider.notifier).setAll(_rules);

    // 被删掉的按钮，颜色表里的记录一起清掉，避免设置越堆越多。
    final newIds = _rules.map((r) => r.id).toSet();
    final oldIds = widget.rules.map((r) => r.id).toSet();
    for (final id in oldIds.difference(newIds)) {
      ref.read(lineEditorButtonColorsProvider.notifier).remove(id);
    }

    final messenger = ScaffoldMessenger.of(context);
    Navigator.pop(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('已保存')));
  }
}

// ==================== 按钮颜色对话框 ====================

class _ButtonColorDialog extends ConsumerStatefulWidget {
  const _ButtonColorDialog({
    required this.ruleId,
    required this.ruleName,
  });

  final String ruleId;
  final String ruleName;

  @override
  ConsumerState<_ButtonColorDialog> createState() =>
      _ButtonColorDialogState();
}

class _ButtonColorDialogState extends ConsumerState<_ButtonColorDialog> {
  @override
  Widget build(BuildContext context) {
    final all = ref.watch(lineEditorButtonColorsProvider);
    final c = all[widget.ruleId] ?? const LineEditorButtonColor();

    return AlertDialog(
      insetPadding: const EdgeInsets.all(8),
      titlePadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      actionsPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      title: Text(
        '${widget.ruleName} · 按钮颜色',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _colorRow(
              context: context,
              label: '背景色',
              isSet: c.bg != null,
              color: c.bg ?? Theme.of(context).colorScheme.surface,
              onPick: (v) => _setBg(v),
            ),
            _colorRow(
              context: context,
              label: '文字色',
              isSet: c.fg != null,
              color: c.fg ?? Theme.of(context).colorScheme.onSurface,
              onPick: (v) => _setFg(v),
            ),
            _colorRow(
              context: context,
              label: '边框色',
              isSet: c.border != null,
              color: c.border ?? Theme.of(context).colorScheme.outline,
              onPick: (v) => _setBorder(v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  void _setBg(Color? color) {
    final all = ref.read(lineEditorButtonColorsProvider);
    final cur = all[widget.ruleId] ?? const LineEditorButtonColor();
    ref.read(lineEditorButtonColorsProvider.notifier).setOne(
          widget.ruleId,
          LineEditorButtonColor(bg: color, fg: cur.fg, border: cur.border),
        );
  }

  void _setFg(Color? color) {
    final all = ref.read(lineEditorButtonColorsProvider);
    final cur = all[widget.ruleId] ?? const LineEditorButtonColor();
    ref.read(lineEditorButtonColorsProvider.notifier).setOne(
          widget.ruleId,
          LineEditorButtonColor(bg: cur.bg, fg: color, border: cur.border),
        );
  }

  void _setBorder(Color? color) {
    final all = ref.read(lineEditorButtonColorsProvider);
    final cur = all[widget.ruleId] ?? const LineEditorButtonColor();
    ref.read(lineEditorButtonColorsProvider.notifier).setOne(
          widget.ruleId,
          LineEditorButtonColor(bg: cur.bg, fg: cur.fg, border: color),
        );
  }

  Widget _colorRow({
    required BuildContext context,
    required String label,
    required bool isSet,
    required Color color,
    required void Function(Color?) onPick,
  }) {
    final s = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(label),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            isSet ? _hexOf(color) : '默认',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: isSet ? s.onSurface : s.outline,
            ),
          ),
          const SizedBox(width: 4),
          if (isSet)
            SizedBox(
              width: 24,
              height: 24,
              child: IconButton(
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                tooltip: '清空（回到默认）',
                icon: const Icon(Icons.close, size: 14),
                onPressed: () => onPick(null),
              ),
            ),
          const SizedBox(width: 4),
          InkWell(
            onTap: () async {
              final picked = await pickColorDialog(context, color);
              if (picked != null) onPick(picked);
            },
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: color,
                border: Border.all(color: s.outline),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _hexOf(Color c) {
    final v = c.toARGB32() & 0xFFFFFF;
    return '#${v.toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }
}

// ==================== 可高亮的行号栏 ====================

/// re_editor 的 indicatorBuilder 自定义实现。
///
/// 官方 `DefaultCodeLineNumber` 只负责画，接不到点击，也没有"某一行被
/// 勾选"的概念。这里重写一份，做两件事：
/// 1) 勾选行：行号底色淡蓝 + 行号蓝色加粗 + 左侧竖条
/// 2) 区间起点：偏黄的绿，同样带底色和左侧竖条
///
/// 点击不在这里处理：行号栏在 re_editor 的 Scrollable 内容区内部，
/// 惯性滑动期间收不到指针事件，所以"点行号"交给 `_buildEditorArea`
/// 里那条盖在行号栏上的命中层。
class _SelectableLineNumber extends StatelessWidget {
  const _SelectableLineNumber({
    required this.controller,
    required this.notifier,
    required this.selected,
    required this.rangeStart,
    required this.width,
    required this.textStyle,
    required this.lineCount,
  });

  final CodeLineEditingController controller;
  final CodeIndicatorValueNotifier notifier;
  final Set<int> selected;
  final int? rangeStart;

  /// 总行数。由页面统一算好并缓存传进来，避免每次滚动重建都去
  /// `controller.lineCount` 遍历所有 segment。
  final int lineCount;

  /// 行号栏宽度。由页面统一算好传进来，和"点行号"命中层共用同一个值，
  /// 否则两边各算一次，字号或行数一变就可能差几像素，点到的不是看到的那行。
  final double width;
  final TextStyle textStyle;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CodeIndicatorValue?>(
      valueListenable: notifier,
      builder: (context, value, _) {
        final paragraphs =
            value?.paragraphs ?? const <CodeLineRenderParagraph>[];
        return _build(context, paragraphs);
      },
    );
  }

  Widget _build(BuildContext context, List<CodeLineRenderParagraph> paragraphs) {
    final digits = lineCount.toString().length;
    final minDigits = digits < 3 ? 3 : digits;

    // 行号字号自适应（和行编辑器同一套算法）：以"最大行号的位数 +
    // 行号宽度"反推能放下的最大字号，宽度够时维持原字号。
    final available = width - 10;
    final fit = available <= 0 ? 6.0 : available / (0.62 * minDigits);
    final maxSize = textStyle.fontSize ?? 14.0;
    final fitCapped = fit > maxSize ? maxSize : (fit < 6.0 ? 6.0 : fit);
    // 行号字号通常比正文小，但行高必须和正文一致：Text 的行高 = fontSize ×
    // height，字号一小行高就小，顶对齐之后字形自然和正文错位。这里把 height
    // 反算成「正文行高 ÷ 行号字号」，让行号文本占满和正文一样高的行。
    final bodyLineHeight =
        (textStyle.fontSize ?? 14.0) * (textStyle.height ?? 1.4);
    // 先把 DefaultTextStyle 合进来，量基线和真正画出来的 Text 用同一份样式。
    // Text 的样式是「继承默认样式再覆盖」，只拿 textStyle 去量，量到的可能
    // 不是渲染时真正生效的那份（字距、字重、字体回退都可能被默认样式影响）。
    final numberStyle = DefaultTextStyle.of(context).style.merge(textStyle).copyWith(
      fontSize: fitCapped.toDouble(),
      height: bodyLineHeight / fitCapped,
    );
    // 行号文本自己的基线位置（相对它自己那行盒子顶部）。
    //
    // 所有行号样式一致，所以只量一次；放进循环里就是每行建一个 TextPainter，
    // 滚动时白烧一屏的时间。
    final numberBaseline = _numberBaseline(numberStyle, width);

    return SizedBox(
      width: width,
      child: LayoutBuilder(
        builder: (context, box) {
          final height = box.maxHeight.isFinite ? box.maxHeight : 0.0;
          if (paragraphs.isEmpty) return SizedBox(height: height);

          // 本页关掉了折叠分析（NonCodeChunkAnalyzer），代码行号就是显示
          // 行号，直接 index + 1。原来调 controller.index2lineIndex() 是
          // O(n)：在三十万行的文件末尾重建这一屏，光算第一个行号就要空转
          // 三十万次。
          final children = <Widget>[];

          for (final p in paragraphs) {
            final isSelected = selected.contains(p.index);
            final isStart = rangeStart == p.index;

            Color? bg;
            Color? bar;
            var color = textStyle.color ?? const Color(0xFF9E9E9E);
            var weight = FontWeight.normal;

            if (isSelected) {
              bg = _kSelectBlue.withValues(alpha: 0.12);
              bar = _kSelectBlue;
              color = _kSelectBlue;
              weight = FontWeight.bold;
            } else if (isStart) {
              bg = _kRangeStart.withValues(alpha: 0.18);
              bar = _kRangeStart;
              color = _kRangeStart;
              weight = FontWeight.bold;
            }

            // 行号基线对齐正文首行基线。
            //
            // 正文的真实基线由 re_editor 量出来（IParagraph.firstLineBaseline，
            // 来自 TextPainter.computeLineMetrics）。中文行走系统 CJK 回退字体，
            // ascent 比例比 monospace 大，段落取各 run 的最大 ascent，所以基线
            // 比「用行高比例估出来的位置」更低几个像素——原来用「估算行高 +
            // 垂直居中」去凑，必然偏高一点。这里直接按两条基线重合来反推 top，
            // 跟字体、字号、中英文混排都无关。
            final double numberTop =
                p.top + p.paragraph.firstLineBaseline - numberBaseline;

            children.add(
              Positioned(
                left: 0,
                top: p.top,
                width: width,
                height: p.height,
                // 这一行只管画。点击由页面里那层盖在行号栏上的命中层处理：
                // 行号栏在滚动区内部，惯性滑动时收不到指针事件，
                // 挂在行上的手势在这种时候会整个失效。
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: bg,
                    border: bar == null
                        ? null
                        : Border(
                            left: BorderSide(color: bar, width: 3),
                          ),
                  ),
                  // 用 Stack + Positioned 而不是 Padding 顶偏移：基线差可能是
                  // 负的（行号基线本来就比正文高时），而 Padding 不允许负值。
                  // Clip.none：基线对齐后数字可能探出这一行盒子一两像素，
                  // 默认的 hardEdge 会把探出的部分切掉。
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned(
                        top: numberTop - p.top,
                        right: 6,
                        child: Text(
                          '${p.index + 1}',
                          maxLines: 1,
                          softWrap: false,
                          // re_editor 排正文时从不乘系统字体缩放（它自己量段落
                          // 时没用 textScaler），行号也跟着不缩放；否则系统字号
                          // 一调大，行号先变大，基线和正文就对不上了。
                          textScaler: TextScaler.noScaling,
                          style: numberStyle.copyWith(
                            color: color,
                            fontWeight: weight,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }

          return SizedBox(
            width: width,
            height: height,
            child: Stack(
              children: children,
            ),
          );
        },
      ),
    );
  }

  /// 量出「行号文本」这种样式下，单行文本的基线相对它自己盒子顶部的距离。
  ///
  /// 必须是和行号 Text 完全一致的样式（同样的 fontSize / height），并且
  /// 同样不乘系统字体缩放，否则量出来的基线和实际画出来的基线不在一处。
  ///
  /// 结果按 (样式, 可用宽度) 记忆：`_build` 每次滚动通知都会跑，滚动时若每次
  /// 都新建一个 TextPainter 去量同一个数字，白白多出几十次 layout。
  static TextStyle? _baselineCacheStyle;
  static double _baselineCacheWidth = -1;
  static double _baselineCacheValue = 0;

  static double _numberBaseline(TextStyle style, double maxWidth) {
    if (_baselineCacheStyle == style && _baselineCacheWidth == maxWidth) {
      return _baselineCacheValue;
    }
    final TextPainter painter = TextPainter(
      text: TextSpan(text: '0', style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      textScaler: TextScaler.noScaling,
    )..layout(maxWidth: maxWidth);
    // 拿不到精确基线时退回 0.8 倍行高：Flutter 默认 leadingDistribution 下
    // ascent 大约占行高的 80%，误差一两像素，比完全不对齐好。
    final double baseline =
        painter.computeDistanceToActualBaseline(TextBaseline.alphabetic) ??
            painter.height * 0.8;
    painter.dispose();
    _baselineCacheStyle = style;
    _baselineCacheWidth = maxWidth;
    _baselineCacheValue = baseline;
    return baseline;
  }
}
