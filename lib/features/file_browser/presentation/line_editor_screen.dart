import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:charset/charset.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

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
import '../../viewer/presentation/viewer_widgets.dart'
    show pickColorDialog;
import 'comparison_settings_screen.dart' show RuleEditorDialog, ruleSubtitle;
import 'dialogs/line_range_selector_dialog.dart';
import 'providers/line_editor_rules_provider.dart';
import 'translation_table.dart';

const int _lineEditorWarnSizeBytes = 5 * 1024 * 1024;
const int _lineEditorRejectSizeBytes = 100 * 1024 * 1024;

// 默认皮肤（defaultBlue）专属灰：行编辑器自定义按钮栏背景、行号颜色。
// 仅当当前皮肤为默认皮肤时生效，其它皮肤沿用各自 scheme，不受影响。
const Color _defaultToolbarBgLight = Color(0xFFE2E2E2);
const Color _defaultToolbarBgDark = Color(0xFF44474D);
const Color _defaultLineNumberLight = Color(0xFF4D4D4D);
const Color _defaultLineNumberDark = Color(0xFFB0B0B0);

/// 仅默认皮肤返回 true（与 AppColors.textAccentOf 的判断方式一致）。
bool _isDefaultSkin(ColorScheme s) =>
    s.primary == AppColors.lightScheme.primary ||
    s.primary == AppColors.darkScheme.primary;

enum _LineSaveEncoding {
  utf8('UTF-8'),
  gbk('GBK');

  const _LineSaveEncoding(this.label);
  final String label;
}

/// 行编辑器：每行一个独立小 TextField。
///
/// 用 `ScrollablePositionedList.builder` 而非 `ListView.builder`——
/// 因为前者支持按 index 跳转（跳末尾 O(1)，大文件不卡），
/// 后者跳末尾需要估算总高，大文件会反复构建 → 卡死甚至闪退。
class LineEditorScreen extends ConsumerStatefulWidget {
  const LineEditorScreen({
    super.key,
    required this.filePath,
    required this.fileName,
  });

  final String filePath;
  final String fileName;

  @override
  ConsumerState<LineEditorScreen> createState() => _LineEditorScreenState();
}

class _LineEditorScreenState extends ConsumerState<LineEditorScreen> {
  static const int _controllerCacheCap = 600;

  /// 事实来源：每行文本。controller 是这张表的镜像。
  List<String> _lines = const <String>[];

  /// 按行号缓存的 controller。
  final Map<int, _LineController> _controllers = {};

  /// 当前已构建行的 FocusNode 登记表（由 _LineRow 自己 attach/detach，
  /// 只装"活着的行"，不做缓存池——避免销毁还被 TextField 引用的节点）。
  final Map<int, FocusNode> _focusNodes = {};

  bool _loading = true;
  bool _dirty = false;
  bool _saving = false;
  bool _processing = false;
  String _processingText = '';

  String _detectedEncoding = '';
  _LineSaveEncoding _saveEncoding = _LineSaveEncoding.utf8;

  /// 原始字节。手动切换编码时要拿它重新解码，不重新读文件
  /// （磁盘上的文件可能已经被改过，重新读会丢内容）。
  Uint8List? _rawBytes;

  double _fontSize = 18.0;

  // ---- 行号显示 ----
  bool _showLineNumbers = true;
  double _lineNumberWidth = 44.0;

  // ---- 选区起止（1-based 行号） ----
  int? _selectionStart;
  int? _selectionEnd;

  // ---- 多选行模式 ----
  // 和区间选择（点两个行号弹窗）并存但互斥：
  // - 普通模式：只有行号能点（点了就进区间选择流程）
  // - 多选模式：**整行**都是热区，点正文/行尾空白/行号都是勾选/取消
  // 支持单选和不连续多行；退出时清空。行号 1-based。
  bool _multiSelectMode = false;
  final Set<int> _multiSelected = <int>{};

  // ---- 拆行排队（粘贴多行 / 回车带进的换行） ----
  /// 行号 → 待插入的后续段落（存原始字符串，split 推迟到 flush 再做，
  /// 避免在输入事件回调里干重活）。
  final Map<int, List<String>> _pendingTails = <int, List<String>>{};
  bool _splitFlushScheduled = false;

  /// 分片重算命中的代号：新任务开始/同步重算时自增，旧任务自动作废。
  int _hitGen = 0;

  /// 多选模式下的区间拾取：点了操作条「区间选择」后，
  /// 接下来两下行号点击 = 勾选整个区间（不弹窗）。
  bool _pickingRangeInMulti = false;

  // ---- 滚动（ScrollablePositionedList） ----
  final ItemScrollController _itemScrollCtrl = ItemScrollController();
  final ItemPositionsListener _positionsListener =
      ItemPositionsListener.create();

  /// 列表可视区高度（LayoutBuilder 里记下来，跳转定位用）。
  /// 在 build 里直接赋值，不触发 setState。
  double _viewportHeight = 0;

  /// 加载进度文案（只有大文件切分时才有值）。
  String _loadProgress = '';

  // ---- 查找 / 替换 ----
  bool _showFind = false;
  final TextEditingController _findCtrl = TextEditingController();
  final TextEditingController _replaceCtrl = TextEditingController();
  bool _useRegex = false;
  bool _caseSensitive = false;
  List<int> _findHits = const <int>[];
  int _findPos = -1;

  /// 当前查找词对应的 Pattern。null = 没有查找词或查找框为空。
  /// 所有可见行的 _LineController 都引用同一个对象，方便统一刷新。
  Pattern? _currentPattern;

  /// _currentPattern 对应的 key（查找词 + 正则 + 大小写）。
  /// 用来判断是否需要把新 pattern 刷到 controller 上。
  String _patternKey = '';

  /// 查找输入防抖。
  Timer? _findTimer;

  /// 当前命中在本行里的「续搜位置」（相对本行起点，-1 = 从行首算起）。
  ///
  /// 行编辑器按行定位，一行里可能有好几处匹配。为了让「替换当前」
  /// 和全文编辑器一样「只替换一处」，这里记住上一次替换结束的位置：
  /// 下一次从它后面找下一处，找不到才回到本行第一处。
  int _findOccOffset = -1;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _findTimer?.cancel();
    _findCtrl.dispose();
    _replaceCtrl.dispose();
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  // ==================== 加载 / 保存 ====================

  Future<void> _load() async {
    try {
      final file = File(widget.filePath);
      final len = await file.length();

      if (len > _lineEditorRejectSizeBytes) {
        if (!mounted) return;
        setState(() => _loading = false);
        _toast(
            '文件超过 ${_lineEditorRejectSizeBytes ~/ 1024 ~/ 1024} MB，请用预览功能');
        return;
      }

      if (len > _lineEditorWarnSizeBytes && mounted) {
        final mb = (len / 1024 / 1024).toStringAsFixed(1);
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('文件较大'),
            content: Text(
              '此文件约 $mb MB。\n'
              '行编辑器只渲染可见行，超大文件仍可能卡顿。\n'
              '继续打开？',
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
          if (mounted) setState(() => _loading = false);
          return;
        }
      }

      final bytes = await file.readAsBytes();
      final enc = EncodingDetector.detect(bytes);
      final decoded = await EncodingDetector.decodeChunkedAsync(bytes, enc);
      if (!mounted) return;

      // 20MB 文本一次 split('\n') 会当场分配几十万个 String，
      // 单帧几十到上百毫秒（还会连带一次大 GC）——这正是
      // 「打开大文件卡一下」的来源。改成切片：每片切完主动让出
      // 事件循环，UI 任何一帧的占用都压在十几毫秒以内。
      final lines = await _splitIntoLines(decoded.text);
      if (lines == null || !mounted) return;

      setState(() {
        _rawBytes = bytes;
        _lines = lines;
        _detectedEncoding = decoded.encoding.label;
        _saveEncoding = _guessSaveEncoding(decoded.encoding);
        _loadProgress = '';
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _toast('读取失败：$e');
    }
  }

  /// 把整篇文本切成行（等价于 `text.split('\n')`），但切片执行。
  ///
  /// 每片 2M 字符：切完 `await` 一次让出事件循环，单帧最多十几毫秒，
  /// 400 万字符的文本也只会经历几次很短的让出，不会出现一次长冻结。
  /// 返回 null = 期间页面已销毁。
  Future<List<String>?> _splitIntoLines(String text) async {
    const sliceChars = 1 << 21; // 2M 字符
    final total = text.length;
    final out = <String>[];
    var start = 0;

    while (start < total) {
      var end = start + sliceChars;
      if (end >= total) {
        end = total;
      } else {
        // 对齐到换行之后，保证不切碎某一行
        final nl = text.indexOf('\n', end);
        end = nl < 0 ? total : nl + 1;
      }

      final segs = text.substring(start, end).split('\n');
      if (start == 0) {
        out.addAll(segs);
      } else {
        // 上一片的最后一段并没有结束，接上本片第一段
        out[out.length - 1] = out[out.length - 1] + segs[0];
        if (segs.length > 1) out.addAll(segs.getRange(1, segs.length));
      }

      start = end;
      if (!mounted) return null;

      if (total > sliceChars) {
        final pct = (start * 100 ~/ total).clamp(0, 100);
        setState(() => _loadProgress = '正在解析文本 $pct%');
        await Future<void>.delayed(Duration.zero);
      }
    }

    if (out.isEmpty) out.add('');
    return out;
  }

  _LineSaveEncoding _guessSaveEncoding(EncodingType enc) {
    switch (enc) {
      case EncodingType.gbk:
      case EncodingType.gb18030:
        return _LineSaveEncoding.gbk;
      default:
        return _LineSaveEncoding.utf8;
    }
  }

  Uint8List _encodeText(String text) {
    switch (_saveEncoding) {
      case _LineSaveEncoding.utf8:
        return Uint8List.fromList(utf8.encode(text));
      case _LineSaveEncoding.gbk:
        return Uint8List.fromList(gbk.encode(text));
    }
  }

  String _joinLines() => _lines.join('\n');

  /// 逐行拼接 + 编码，分批让出事件循环。结果等价于
  /// `_encodeText(_joinLines())`。
  ///
  /// 为什么不用一行 `utf8.encode(_joinLines())`：20MB 文本 join 出
  /// 一个 20MB 字符串再整块编码，UI 线程要一次吃掉 200ms 左右
  /// （保存时那一下明显卡顿）。这里按 512K 字符一批处理，每批
  /// 几毫秒，批与批之间主动让出，保存过程界面始终能响应。
  /// 按「整行」分批，不会把代理对（emoji）劈成两半。
  ///
  /// 返回 null = 期间页面已销毁。
  Future<Uint8List?> _encodeLinesChunked() async {
    const batchChars = 1 << 19; // 512K 字符一批
    // 先把行快照下来：分批过程中会让出事件循环，期间用户还可能打字，
    // 快照保证写出去的是「按下保存那一刻」的完整内容。
    final lines = List<String>.of(_lines);
    final builder = BytesBuilder(copy: false);
    final buf = StringBuffer();
    var bufLen = 0;
    var first = true;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (!first) {
        buf.write('\n');
        bufLen += 1;
      }
      first = false;
      buf.write(line);
      bufLen += line.length;

      if (bufLen >= batchChars) {
        builder.add(_encodeText(buf.toString()));
        buf.clear();
        bufLen = 0;
        if (!mounted) return null;
        await Future<void>.delayed(Duration.zero);
      }
    }

    // 收尾（空文件也要 encode 一次，保证写出的是空内容而不是 null）
    if (bufLen > 0 || builder.isEmpty) {
      builder.add(_encodeText(buf.toString()));
    }
    return builder.takeBytes();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final bytes = await _encodeLinesChunked();
      if (bytes == null) {
        if (mounted) setState(() => _saving = false);
        return;
      }
      final file = File(widget.filePath);
      if (await file.exists()) {
        // 只保留一个 .bak，每次覆盖。
        // 原来每次保存都新建一个时间戳 .bak，改 100 次就堆 100 个。
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
      final bytes = await _encodeLinesChunked();
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
      contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
      actionsPadding: const EdgeInsets.only(bottom: 8),
      content: const Text('返回将丢失改动，确定吗？'),
      actions: [
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
  TextButton(
    style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
    onPressed: () => Navigator.pop(c, 'save'),
    child: const Text('保存并返回'),
  ),
  const SizedBox(height: 20),
  TextButton(
    style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
    onPressed: () => Navigator.pop(c, 'cancel'),
    child: const Text('取消'),
  ),
  const SizedBox(height: 20),
  TextButton(
    style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
    onPressed: () => Navigator.pop(c, 'discard'),
    child: const Text('放弃并返回'),
  ),
],
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

  // ==================== Controller 缓存 ====================

  _LineController _controllerFor(int i) {
    var c = _controllers[i];
    if (c == null) {
      c = _LineController(text: _lines[i]);
      final cc = c;
      c.addListener(() => _onLineChanged(i, cc));
      _controllers[i] = c;
      _maybeEvict();
    } else if (c.text != _lines[i]) {
      c.text = _lines[i];
    }
    return c;
  }

  void _maybeEvict() {
    if (_controllers.length <= _controllerCacheCap) return;
    final take = _controllers.length ~/ 2;
    // 按插入顺序踢最老的一半，但**跳过还挂着焦点的**。
    // 最老的那批正好是文件开头的行：滚到顶 → 滚到底 → 再回顶部时，
    // 顶部行的 controller 正落在淘汰集合里，那一帧它的输入框会拿到
    // 已 dispose 的实例（debug 报 used after dispose，release 下表现为
    // 该行输入突然没反应）。
    final idle = _controllers.keys
        .where((k) => !_focusNodes.containsKey(k))
        .toList(growable: false);
    final keys = idle.isEmpty
        // 极端情况（几乎全都有焦点）：退回原策略，保证缓存不会无限涨。
        ? _controllers.keys.take(take).toList(growable: false)
        : idle.take(take).toList(growable: false);
    for (final k in keys) {
      _controllers.remove(k)?.dispose();
    }
  }

  void _attachFocusNode(int i, FocusNode node) {
    _focusNodes[i] = node;
  }

  void _detachFocusNode(int i, FocusNode node) {
    if (identical(_focusNodes[i], node)) _focusNodes.remove(i);
  }

  /// 丢弃 [from] 及之后的 controller 缓存。
  ///
  /// 只处理 controller：focusNode 由行自己管生命周期，且是「按位置」登记的
  /// （位置 P 上的行永远是第 P+1 行），行号位移后依然有效，不能清掉，
  /// 否则正在编辑的行会丢焦点、键盘直接收起。
  void _dropCachesFrom(int from) {
    for (final k in _controllers.keys.toList()) {
      if (k >= from) _controllers.remove(k)?.dispose();
    }
  }

  void _onLineChanged(int i, _LineController cc) {
    if (i < 0 || i >= _lines.length) return;
    final text = cc.text;
    if (_lines[i] == text) return;

    // 正常输入：只同步这一行的文本。
    //
    // 粘贴/回车带进来的换行已经被 _LineBreakSplitter 在「提交给
    // controller 之前」截走了，所以这里理论上见不到 \n。万一见到
    // （个别输入法绕过 formatter 直接 set value），走兜底：真正的
    // 文本先落进 _lines，下一次 itemBuilder 里 _controllerFor 会把
    // controller 文本纠回首段——纠正在 layout 之前，所以那一帧也只
    // 布局一行，不会出现"整块文本被排一遍"的卡顿。
    if (text.contains('\n')) {
      final idx = text.indexOf('\n');
      _lines[i] = text.substring(0, idx);
      _queueSplit(i, text.substring(idx + 1));
      if (!_dirty) setState(() => _dirty = true);
      return;
    }

    // 只在「由干净变脏」这一刻重建一次（标题的未保存标记 + PopScope）。
    // 平时每敲一个字符都 setState 会整屏 rebuild：工具栏、状态栏、
    // 以及整个 ScrollablePositionedList 的 itemBuilder 闭包全换新，
    // 可见行跟着重排——40 万行的文件里这是最没必要的开销，而
    // TextField 的文本本来就由 controller 自己驱动，不需要重建。
    _lines[i] = text;
    if (!_dirty) setState(() => _dirty = true);
  }

  /// formatter 截获换行后的回调：当前行只留首段，其余段落排队插入。
  ///
  /// 这里不做任何拆分/列表操作——只记一笔，重活全部推到帧末尾。
  void _onLineBreakInRow(int i, String head, String rest) {
    if (i < 0 || i >= _lines.length) return;
    _lines[i] = head;
    _queueSplit(i, rest);
  }
  void _queueSplit(int i, String rest) {
    _pendingTails.putIfAbsent(i, () => <String>[]).add(rest);
    if (_splitFlushScheduled) return;
    _splitFlushScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _splitFlushScheduled = false;
      if (!mounted) return;
      _flushPendingSplits();
    });
  }

  /// 把排队的新行一次性插进 [_lines]。
  ///
  /// 性能要点（这是大段粘贴不卡的关键）：
  /// 1. 插入用 `insertAll` 原地做，O(n + 新增) 的指针搬移，不重建整表；
  /// 2. 只作废「被拆分行之后」的 controller（当前行位置没变，光标和
  ///    焦点都保住），且缓存有上限（600），循环成本恒定；
  /// 3. 查找命中改用分片异步重算，不会在这一帧扫全表；
  /// 4. 渲染是 ScrollablePositionedList 懒加载，只重建可见行。
  void _flushPendingSplits() {
    if (_pendingTails.isEmpty) return;
    final entries = _pendingTails.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    _pendingTails.clear();

    var offset = 0;
    // 每项 [原始行号(0-based), 插入行数]，用于重映射选区
    final remaps = <List<int>>[];
    int? focusTarget;
    var focusAtEnd = false;

    for (final e in entries) {
      final orig0 = e.key;
      final i = orig0 + offset;
      if (i < 0 || i >= _lines.length) continue;

      final tails = <String>[];
      for (final raw in e.value) {
        tails.addAll(raw.split('\n'));
      }
      if (tails.isEmpty) continue;

      // 当前行（i）位置不变，只作废它后面的 controller / focusNode
      _dropCachesFrom(i + 1);

      _lines.insertAll(i + 1, tails);
      offset += tails.length;
      remaps.add(<int>[orig0, tails.length]);

      // 光标落到新行：多行粘贴 → 最后一段行尾；回车 → 新行行首
      focusTarget = i + tails.length;
      focusAtEnd = e.value.any((raw) => raw.contains('\n'));
    }
    if (remaps.isEmpty) return;

    setState(() {
      _dirty = true;

      // 选区/多选按「原始行号」重映射：拆分点之后的整体后移，
      // 被拆的那一行本身位置不变。
      int mapLine(int n) {
        var r = n;
        for (final m in remaps) {
          if (n > m[0] + 1) r += m[1];
        }
        return r;
      }

      final s = _selectionStart;
      final e2 = _selectionEnd;
      if (s != null) _selectionStart = mapLine(s);
      if (e2 != null) _selectionEnd = mapLine(e2);
      if (_multiSelected.isNotEmpty) {
        final remapped = <int>{for (final n in _multiSelected) mapLine(n)};
        _multiSelected
          ..clear()
          ..addAll(remapped);
      }
    });

    // 焦点交给新行（回车后继续打字应该落在新行，而不是写回上一行）
    final target = focusTarget;
    if (target != null) _focusLineSoon(target, atEnd: focusAtEnd);

    // 查找框开着才重算，且分片执行，不阻塞当前帧
    if (_findCtrl.text.isNotEmpty) {
      unawaited(_recomputeHitsChunked());
    }
  }

  /// 滚动到目标行（仅当不可见时）并请求焦点。分两帧做：
  /// 先让列表把该行构建出来（行自己会登记 FocusNode），再设光标 + 聚焦。
  void _focusLineSoon(int i, {required bool atEnd}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (i < 0 || i >= _lines.length) return;

      final visible =
          _positionsListener.itemPositions.value.any((p) => p.index == i);
      if (!visible && _itemScrollCtrl.isAttached) {
        _itemScrollCtrl.jumpTo(index: i);
      }
      _applyFocus(i, atEnd: atEnd, retries: 2);
    });
  }

  void _applyFocus(int i, {required bool atEnd, required int retries}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (i < 0 || i >= _lines.length) return;

      final node = _focusNodes[i];
      if (node == null) {
        // 行还没构建出来（刚 jumpTo），再等一帧
        if (retries > 0) {
          _applyFocus(i, atEnd: atEnd, retries: retries - 1);
        }
        return;
      }

      final ctrl = _controllers[i];
      if (ctrl != null) {
        ctrl.selection = TextSelection.collapsed(
          offset: atEnd ? ctrl.text.length : 0,
        );
      }
      node.requestFocus();
    });
  }

  /// 查找命中重算（分片版）：每片最多占约 8ms，逐片让出事件循环。
  /// 几十万行的文件也不会卡一帧；旧的未完成任务靠 [_hitGen] 自动作废。
  /// [anchorLine] 为 0-based 行号：重算后从该行往后找最近的一个命中作为当前项，
  /// 传 null 表示回到第一个。[jump] 为 true 时把当前项滚到可见区。
  ///
  /// 之所以要锚点：命中列表会因编辑/拆行/删行而变化，直接把 `_findPos` 归零
  /// 会让「已经在第 7 个结果」的定位凭空跳回第 1 个。
  Future<void> _recomputeHitsChunked({
    int? anchorLine,
    bool jump = false,
  }) async {
    final gen = ++_hitGen;
    final q = _findCtrl.text;
    if (q.isEmpty) {
      _findHits = const <int>[];
      _findPos = -1;
      return;
    }
    final p = _buildPattern();
    final hits = <int>[];
    final sw = Stopwatch()..start();
    for (var i = 0; i < _lines.length; i++) {
      if (p.allMatches(_lines[i]).isNotEmpty) hits.add(i);
      if (sw.elapsedMilliseconds >= 8) {
        await Future<void>.delayed(Duration.zero);
        if (!mounted || gen != _hitGen) return;
        sw.reset();
      }
    }
    if (!mounted || gen != _hitGen) return;
    // 定位当前项：有锚点就取锚点之后的第一个命中（都没有则回落到第一个）
    var pos = 0;
    if (anchorLine != null && hits.isNotEmpty) {
      var found = -1;
      for (var k = 0; k < hits.length; k++) {
        if (hits[k] >= anchorLine) {
          found = k;
          break;
        }
      }
      pos = found >= 0 ? found : 0;
    }
    // 当前命中行变了 → 「替换当前」的续搜位置归零。
    // 没变就保留：刚替换完一处，剩下的那一处才是新的「当前」。
    final oldLine =
        (_findPos >= 0 && _findPos < _findHits.length) ? _findHits[_findPos] : -1;
    final newLine = hits.isEmpty ? -1 : hits[pos];
    if (newLine != oldLine) _findOccOffset = -1;
    setState(() {
      _findHits = hits;
      _findPos = hits.isEmpty ? -1 : pos;
    });
    if (jump && hits.isNotEmpty) {
      _jumpToIndex(hits[pos]);
    }
  }

  /// 每次 itemBuilder 构建可见行时调用。
  /// 把主编辑器的最新查找状态刷到 controller 上。
  /// 只在状态真变了才 notifyListeners，避免无谓重绘。
  ///
  /// 用 _patternKey 而不是直接比 Pattern 对象：每次 _recomputeHits
  /// 都会新建 Pattern，对象引用必然不同，比不了。
  void _syncControllerHighlight(int i, _LineController c) {
    final key = _patternKey;
    final newHit = _findPos >= 0 &&
        _findPos < _findHits.length &&
        _findHits[_findPos] == i;
    // 当前命中行里，只有「当前这一处」用深粉，其余匹配仍是黄底。
    // 这样「替换当前」换的是哪一处，一眼就能看出来。
    final range = newHit ? _currentOccurrence(i) : null;
    if (c.patternKey != key ||
        c.isCurrentHitLine != newHit ||
        c.currentMatchRange != range) {
      c.patternKey = key;
      c.findPattern = _currentPattern;
      c.isCurrentHitLine = newHit;
      c.currentMatchRange = range;
      c.notifyListeners();
    }
  }

  // ==================== 行号点击选行 ====================

  void _onTapLineNumber(int lineNum) {
    // 普通模式点行号：自动进入多选行模式，并把这一行勾上
    if (!_multiSelectMode) {
      // 进入多选后整行变热区、正文不能再编辑，先把键盘收掉，
      // 否则焦点还停在某行 TextField 上，键盘会一直杵着。
      FocusScope.of(context).unfocus();
      setState(() {
        _multiSelectMode = true;
        _pickingRangeInMulti = false;
        _selectionStart = null;
        _selectionEnd = null;
        _multiSelected.clear();
        _multiSelected.add(lineNum);
      });
      return;
    }

    // 多选模式
    if (_pickingRangeInMulti) {
      // 区间拾取：第一次点定起点（绿色高亮反馈），
      // 第二次点定终点，把 [lo, hi] 全部勾进多选，不弹窗。
      if (_selectionStart == null) {
        setState(() => _selectionStart = lineNum);
        return;
      }
      final s = _selectionStart!;
      final lo = s < lineNum ? s : lineNum;
      final hi = s < lineNum ? lineNum : s;
      setState(() {
        for (var n = lo; n <= hi; n++) {
          _multiSelected.add(n);
        }
        _selectionStart = null;
        _selectionEnd = null;
        _pickingRangeInMulti = false;
      });
      _toast('已勾选第 $lo~$hi 行，共 ${hi - lo + 1} 行', const Duration(milliseconds: 1000));
      return;
    }
    // 普通勾选：点整行 = 勾选/取消勾选
    setState(() {
      if (!_multiSelected.remove(lineNum)) {
        _multiSelected.add(lineNum);
      }
    });
  }

  Future<void> _showRangeDialog() async {
    final s = _selectionStart;
    final e = _selectionEnd;
    if (s == null || e == null) return;

    final r = await showDialog<LineRangeResult>(
      context: context,
      builder: (_) => LineRangeSelectorDialog(
        lines: _lines,
        initialStart: s,
        initialEnd: e,
      ),
    );
    if (!mounted) return;

    if (r == null) {
      setState(() {
        _selectionStart = null;
        _selectionEnd = null;
      });
      return;
    }

    final startIdx = r.start - 1;
    final endIdx = r.end;
    final selectedLines = _lines.sublist(startIdx, endIdx);
    final text = selectedLines.join('\n');
    final count = r.end - r.start + 1;

    if (r.action == 'copy') {
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) return;
      _toast('已复制 $count 行');
      setState(() {
        _selectionStart = null;
        _selectionEnd = null;
      });
    } else if (r.action == 'cut') {
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) return;
      _deleteLineRange(startIdx, endIdx);
      _toast('已剪切 $count 行');
    } else if (r.action == 'delete') {
      _deleteLineRange(startIdx, endIdx);
      _toast('已删除 $count 行');
    }
  }

  /// 删除 [_lines] 的 [startIdx, endIdx) 范围（0-based，右开）。
  void _deleteLineRange(int startIdx, int endIdx) {
    _dropCachesFrom(startIdx);

    setState(() {
      _lines = [
        ..._lines.sublist(0, startIdx),
        ..._lines.sublist(endIdx),
      ];
      _dirty = true;
      _selectionStart = null;
      _selectionEnd = null;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_itemScrollCtrl.isAttached) return;
      if (_lines.isEmpty) return;
      final target = startIdx.clamp(0, _lines.length - 1);
      _itemScrollCtrl.jumpTo(index: target);
    });
  }

  // ==================== 多选行 ====================

  void _toggleMultiSelectMode() {
    // 进入多选后整行变成热区、正文不能再编辑，先把键盘收掉，
    // 否则焦点还留在某行的 TextField 上，键盘会一直杵在那儿。
    if (!_multiSelectMode) FocusScope.of(context).unfocus();
    setState(() {
      _multiSelectMode = !_multiSelectMode;
      _multiSelected.clear();
      _pickingRangeInMulti = false;
      _selectionStart = null;
      _selectionEnd = null;
    });
  }

  /// 主动退出多选行模式（清空选中与区间拾取状态）。
  /// 复制 / 剪切 / 删除 操作完成后自动调用，回到普通编辑。
  void _exitMultiSelectMode() {
    if (!_multiSelectMode) return;
    setState(() {
      _multiSelectMode = false;
      _multiSelected.clear();
      _pickingRangeInMulti = false;
      _selectionStart = null;
      _selectionEnd = null;
    });
  }

  /// 按行号升序拼接所有勾选行的内容。
  String _multiSelectedText() {
    final nums = _multiSelected.toList()..sort();
    return [for (final n in nums) if (n >= 1 && n <= _lines.length) _lines[n - 1]]
        .join('\n');
  }

  Future<void> _copyMultiSelected() async {
    if (_multiSelected.isEmpty) return;
    final count = _multiSelected.length;
    await Clipboard.setData(ClipboardData(text: _multiSelectedText()));
    if (!mounted) return;
    _toast('已复制 $count 行', const Duration(milliseconds: 1000));
    _exitMultiSelectMode();
  }

  Future<void> _cutMultiSelected() async {
    if (_multiSelected.isEmpty) return;
    final count = _multiSelected.length;
    await Clipboard.setData(ClipboardData(text: _multiSelectedText()));
    if (!mounted) return;
    _deleteMultiSelected();
    _exitMultiSelectMode();
    _toast('已剪切 $count 行', const Duration(milliseconds: 1000));
  }

  /// 删除所有勾选行。不连续删除，行号整体前移。
  /// 仅做删除与清空选中，提示与退出由调用方负责（复制/剪切/删除各自处理）。
  void _deleteMultiSelected() {
    if (_multiSelected.isEmpty) return;
    final removed = _multiSelected.map((n) => n - 1).toSet(); // 0-based

    final kept = <String>[];
    for (var i = 0; i < _lines.length; i++) {
      if (!removed.contains(i)) kept.add(_lines[i]);
    }

    // 行号整体位移，controller / focusNode 缓存全部作废
    // （listener 闭包捕获了旧 index，复用会写错行）。
    // 可见行下次 itemBuilder 会自动重建。
    _dropCachesFrom(0);

    setState(() {
      _lines = List<String>.of(kept);
      _dirty = true;
      _multiSelected.clear();
    });

    // 查找命中分片重算，不在这一帧扫全表
    if (_findCtrl.text.isNotEmpty) {
      unawaited(_recomputeHitsChunked());
    }
  }

  Widget _buildMultiSelectBar() {
    final has = _multiSelected.isNotEmpty;
    // 原来：上方一行「已选 xx 行」提示 + 下方按钮行。
    // 现在去掉提示行，但保持整条操作栏高度不变；
    // 按钮行上下内边距相等、整体垂直居中（文字上移）。
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
              // 操作栏文字永远纯黑，不随主题（亮/暗）变化。
              style: const TextStyle(fontSize: 13, color: Colors.black),
            ),
          ),
        ),
      );
    }

    return Container(
      color: Colors.blue.withValues(alpha: 0.10),
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          btn(
            _pickingRangeInMulti ? '取消区间' : '区间选择',
            () => setState(() {
              _pickingRangeInMulti = !_pickingRangeInMulti;
              if (_pickingRangeInMulti) {
                // 重新拾取，清掉残留的起点
                _selectionStart = null;
                _selectionEnd = null;
              }
            }),
          ),
          btn('复制', has ? _copyMultiSelected : null),
          btn('剪切', has ? _cutMultiSelected : null),
          btn(
            '删除',
            has
                ? () {
                    final c = _multiSelected.length;
                    _deleteMultiSelected();
                    _exitMultiSelectMode();
                    _toast('已删除 $c 行', const Duration(milliseconds: 1000));
                  }
                : null,
          ),
        ],
      ),
    );
  }

  // ==================== 查找 / 替换 ====================

  Pattern _buildPattern() {
    final q = _findCtrl.text;
    if (q.isEmpty) return RegExp(r'(?!)');
    try {
      return _useRegex
          ? RegExp(q, caseSensitive: _caseSensitive, multiLine: true)
          : RegExp(RegExp.escape(q), caseSensitive: _caseSensitive);
    } catch (_) {
      return RegExp(r'(?!)');
    }
  }

  /// 输入变化：加防抖。停手 300ms 后再算命中。
  /// 原来每输一个字就遍历所有行，30 万行会明显卡。
  void _onFindInputChanged(String _) {
    _findTimer?.cancel();
    _findTimer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      _beginFind();
    });
  }

  /// 开始一次查找：高亮 pattern 立刻上屏，命中统计走分片异步。
  ///
  /// 关键点：**同步部分只有 O(1)**（编译一个正则 + 更新 key），
  /// 真正扫全表的活全部在 [_recomputeHitsChunked] 里按 8ms 切片。
  /// 40 万行时「搜一下」也不会吞掉一整帧。
  ///
  /// [keepPosition]：查询条件（词/正则/大小写）没变时是否保持当前定位。
  /// 点第三行的「搜索」按钮就是在**同条件**下重搜，必须保持——否则用户
  /// 点了 7 次「下一个」之后随手再点一下搜索，就被打回第一个结果。
  /// 条件真的变了（改了词、切了正则/大小写）才回到第一个。
  void _beginFind({bool keepPosition = true}) {
    final q = _findCtrl.text;
    final newKey = q.isEmpty
        ? ''
        : '$q|${_useRegex ? 1 : 0}|${_caseSensitive ? 1 : 0}';
    // 同条件且当前定位有效 → 以当前命中行为锚点，重算后仍停在这附近
    final anchor = keepPosition &&
            newKey.isNotEmpty &&
            newKey == _patternKey &&
            _findPos >= 0 &&
            _findPos < _findHits.length
        ? _findHits[_findPos]
        : null;

    _hitGen++; // 先作废还在跑的分片任务
    // 查询条件变了 → 当前处归零，从本行第一处重新算
    if (newKey != _patternKey) _findOccOffset = -1;
    if (q.isEmpty) {
      _currentPattern = null;
      _patternKey = '';
      _findOccOffset = -1;
      setState(() {
        _findHits = const <int>[];
        _findPos = -1;
      });
      return;
    }
    final p = _buildPattern();
    setState(() {
      _currentPattern = p;
      _patternKey = newKey;
    });
    // 有锚点：停在原处（不滚动，视觉零变化）；没锚点：回第一个并跳过去
    unawaited(_recomputeHitsChunked(
      anchorLine: anchor,
      jump: anchor == null,
    ));
  }

  /// 查找词为空时统一给一句提示。
  /// 上下箭头、替换当前、全部替换、搜索按钮都先过这里——否则点了没反应，
  /// 用户会以为按钮坏了。
  bool _ensureFindQuery() {
    if (_findCtrl.text.isNotEmpty) return true;
    _toast('请先输入要查找的内容');
    return false;
  }

  void _findNext() {
    if (!_ensureFindQuery()) return;
    if (_findHits.isEmpty) {
      _beginFind();
      return;
    }
    setState(() {
      _findPos = (_findPos + 1) % _findHits.length;
      _findOccOffset = -1; // 换了行，从该行第一处算起
    });
    _scrollToLine(_findHits[_findPos]);
  }

  void _findPrev() {
    if (!_ensureFindQuery()) return;
    if (_findHits.isEmpty) {
      _beginFind();
      return;
    }
    setState(() {
      _findPos = (_findPos - 1 + _findHits.length) % _findHits.length;
      _findOccOffset = -1;
    });
    _scrollToLine(_findHits[_findPos]);
  }

  /// 当前命中在本行里的字符区间（相对本行起点）。
  /// 一行里有多处匹配时，只有这一段算「当前」，替换也只换这一段。
  _MatchRange? _currentOccurrence(int lineNo) {
    final p = _currentPattern;
    if (p == null || lineNo < 0 || lineNo >= _lines.length) return null;
    Match? first;
    Match? after;
    for (final m in p.allMatches(_lines[lineNo])) {
      if (m.start == m.end) continue; // 空匹配（^ / $）跳过
      first ??= m;
      if (m.start >= _findOccOffset) {
        after = m;
        break;
      }
    }
    final pick = after ?? first;
    if (pick == null) return null;
    return _MatchRange(pick.start, pick.end);
  }

  /// 替换当前命中，**只换一处**（和全文编辑器一致）。
  /// 本行还有剩余匹配时留在本行，下次接着换下一处。
  void _replaceCurrent() {
    if (!_ensureFindQuery()) return;
    if (_findHits.isEmpty || _findPos < 0) {
      _toast('没有匹配');
      return;
    }
    final lineNo = _findHits[_findPos];
    final line = _lines[lineNo];
    final p = _buildPattern();
    final matches =
        p.allMatches(line).where((m) => m.start != m.end).toList();
    if (matches.isEmpty) return;
    Match pick = matches.first;
    for (final m in matches) {
      if (m.start >= _findOccOffset) {
        pick = m;
        break;
      }
    }
    final replaceText = _replaceCtrl.text;
    final newLine = line.replaceRange(pick.start, pick.end, replaceText);
    // 记下替换结束位置，下一次从这里往后找
    _findOccOffset = pick.start + replaceText.length;
    _lines[lineNo] = newLine;
    final c = _controllers[lineNo];
    if (c != null) c.text = newLine;
    setState(() => _dirty = true);
    // 本行可能还有别的命中，重算走分片，不冻界面
    _beginFind();
  }

  /// 全部替换。分批 + 每批让出事件循环，UI 不冻。
  /// 顶部蓝色横幅显示进度。
  Future<void> _replaceAll() async {
    if (!_ensureFindQuery()) return;
    if (_processing) return; // 防连点

    setState(() {
      _processing = true;
      _processingText = '正在全部替换…';
    });
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;

    final p = _buildPattern();
    var count = 0;
    final total = _lines.length;

    try {
      const batchSize = 5000;
      for (var i = 0; i < total; i++) {
        final line = _lines[i];
        final newLine = line.replaceAllMapped(p, (_) => _replaceCtrl.text);
        if (newLine != line) {
          _lines[i] = newLine;
          final c = _controllers[i];
          if (c != null) c.text = newLine;
          count++;
        }
        if (i > 0 && i % batchSize == 0) {
          if (!mounted) return;
          final pct = (i * 100 ~/ total);
          setState(() => _processingText = '正在全部替换… $pct%');
          await Future<void>.delayed(Duration.zero);
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _processing = false;
          _processingText = '';
        });
      }
    }

    if (!mounted) return;
    if (count == 0) {
      _toast('没有匹配');
      return;
    }
    setState(() => _dirty = true);
    _beginFind();
    _toast('已替换 $count 行');
  }

  // ==================== 滚动 / 跳转 ====================

  /// 跳到第 [index] 行（0-based）。所有跳转的唯一入口。
  ///
  /// 为什么这里无论文件多大都是「瞬间」：`ScrollablePositionedList`
  /// 的 `jumpTo` 不是滚像素，而是直接把新行设成布局锚点重建 ——
  /// 它不计算偏移、不遍历、也不测量中间任何一行。跳到第 1 行和跳到
  /// 第 40 万行的成本完全一样（都只布局屏幕里那十几行）。
  /// 所以这里绝对不能改成 `scrollTo`/`animateTo`，那才会走过渡动画。
  void _jumpToIndex(int index, {int retries = 1}) {
    if (_lines.isEmpty) return;
    final target = index.clamp(0, _lines.length - 1);
    if (!_itemScrollCtrl.isAttached) {
      // 列表还没挂上（例如刚进页面就点跳转）：下一帧补一次，
      // 不能像原来那样静默 return——用户会觉得按钮坏了。
      if (retries > 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _jumpToIndex(target, retries: retries - 1);
        });
      }
      return;
    }
    _itemScrollCtrl.jumpTo(index: target);
  }

  void _scrollToLine(int lineIdx) => _jumpToIndex(lineIdx);

  /// 聚焦兜底：把第 [index] 行滚到可见位置（避免被键盘挡住）。
  ///
  /// resizeToAvoidBottomInset=false 后，键盘不再自动顶起列表，
  /// 点击底部附近的行时 EditableText 自带的 ensureVisible 不一定生效，
  /// 这里手动兜底：只有当该行「不完全在可视区内」时才 jumpTo 滚一下，
  /// 完全可见的行不动，避免每次点击都跳一下的突兀感。
  void _ensureLineVisible(int index) {
    if (!mounted) return;
    // 先看当前屏幕位置：这一行是否已经被完整布局出来。
    var fullyVisible = false;
    for (final p in _positionsListener.itemPositions.value) {
      if (p.index == index) {
        // leading/trailing 是 0~1 的相对位置；完全可见 = 头尾都在屏内
        fullyVisible = p.itemLeadingEdge >= 0.0 && p.itemTrailingEdge <= 1.0;
        break;
      }
    }
    if (fullyVisible) return;

    // 位置信息可能还没更新（刚获得焦点那一刻 itemPositions 未必有这行），
    // 下一帧再确认一次，避免误跳。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final p in _positionsListener.itemPositions.value) {
        if (p.index == index &&
            p.itemLeadingEdge >= 0.0 &&
            p.itemTrailingEdge <= 1.0) {
          return; // 一帧后已经可见，不需要动
        }
      }
      _jumpToIndex(index);
    });
  }

  void _jumpToTop() => _jumpToIndex(0);

  void _jumpToBottom() {
    if (_lines.isEmpty) return;
    final last = _lines.length - 1;
    // 先无条件跳到末尾：保证「一定看得到最后一行」，且是 O(1)
    _jumpToIndex(last);
    // 但 jumpTo 会把目标行顶到屏幕最上方，末尾下面全是空白。
    // 下一帧用真实布局位置把内容往下推一次，让最后一行贴底。
    _settleAtBottom(last, 2);
  }

  /// 跳到末尾后的贴底校正：最多补 1 次 `jumpTo`（仍是 O(1)），
  /// 全程不循环、不测中间行，只读当前屏幕上的布局位置。
  void _settleAtBottom(int last, int tries) {
    if (tries <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // jumpTo 的 setState 要到下一帧才布局完，再等一帧位置才是新的
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _doSettleAtBottom(last, tries);
      });
    });
  }

  void _doSettleAtBottom(int last, int tries) {
    if (last != _lines.length - 1) return; // 期间行数变了，放弃校正
    final vh = _viewportHeight;
    if (vh <= 0) return;

    ItemPosition? pos;
    for (final p in _positionsListener.itemPositions.value) {
      if (p.index == last) {
        pos = p;
        break;
      }
    }
    // 最后一行还没露出来：多半是位置信息还没跟上，下一帧再试一次
    if (pos == null) {
      if (tries > 1) _settleAtBottom(last, tries - 1);
      return;
    }

    final blank = 1.0 - pos.itemTrailingEdge;
    if (blank <= 0.02) return; // 已经贴底

    final rowH = (pos.itemTrailingEdge - pos.itemLeadingEdge) * vh;
    if (rowH <= 1) return;

    // 取下整，宁可少推一点也不要推过头（推过头会让最后一行跑出屏幕）
    final k = (blank * vh / rowH).floor();
    if (k < 1) return;

    final anchor = last - k;
    if (anchor <= 0) {
      _jumpToIndex(0);
      return;
    }
    _jumpToIndex(anchor);
    _settleAtBottom(last, tries - 1);
  }

  Future<void> _jumpToLine() async {
    final ctrl = TextEditingController();
    final line = await showDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('跳到指定行'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '输入行号（从 1 开始）',
            border: OutlineInputBorder(),
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
    if (line == null) return;
    if (line < 1 || line > _lines.length) {
      _toast('行号超出范围');
      return;
    }
    _scrollToLine(line - 1);
  }

  // ==================== 行号宽度对话框 ====================

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
                value: tmp.clamp(24, 120),
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

  // ==================== 字号（加 / 减 合并为一个） ====================

  /// 「字号 +1」「字号 -1」两项合并成这一个：菜单里显示当前值，
  /// 点开后既能用滑块拖动，也能点 − / ＋ 一格一格调。
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
                        : () => setSt(() => tmp = (tmp - 1).clamp(8, 36).toDouble()),
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
                        : () => setSt(() => tmp = (tmp + 1).clamp(8, 36).toDouble()),
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

  // ==================== 手动切换编码 ====================

  /// 手动切换编码。
  ///
  /// 自动探测（detect + ICU 复核）对少数文件仍然会判错——GBK / Big5 /
  /// Shift-JIS 的字节范围高度重叠，一旦判错整篇就是乱码，而且没法修。
  /// 这里把候选列出来让用户自己指定，按指定编码重新解一遍原始字节。
  ///
  /// 用的是探测阶段缓存的 [_rawBytes]，不是重新读文件：
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

    final picked = await showDialog<EncodingType>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('切换编码'),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              '当前内容乱码时，选一个编码重新解一遍。\n'
              '切换会丢弃屏幕上的改动，从文件重新载入。',
              style: TextStyle(fontSize: 12),
            ),
          ),
          for (final e in candidates)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, e),
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
        ],
      ),
    );
    if (picked == null || !mounted) return;

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
      if (ok != true) return;
    }

    setState(() {
      _processing = true;
      _processingText = '正在按 ${picked.label} 重新解码…';
    });
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;

    try {
      final text = await _decodeWithEncoding(bytes, picked);
      if (!mounted) return;
      for (final c in _controllers.values) {
        c.dispose();
      }
      _controllers.clear();
      setState(() {
        _lines = text.split('\n');
        _detectedEncoding = picked.label;
        _saveEncoding = _guessSaveEncoding(picked);
        _dirty = false;
        _selectionStart = null;
        _selectionEnd = null;
        _processing = false;
        _processingText = '';
      });
      _toast('已按 ${picked.label} 重新载入');
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
  /// [EncodingDetector.decodeChunkedAsync] 会复核并可能把用户手动选的编码
  /// 又换回去（它以为自己更懂），手动切换必须绕开这一步。
  /// Android 上仍然优先走系统 ICU（全码表、不会静默错位），
  /// 失败或平台不支持时回落 Dart 侧解码。
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

  // ==================== 顶部按钮栏 ====================

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
          // 折叠：和对比页按钮栏同一套交互——点一下收起整栏，
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

  Future<void> _applyToolbarRule(PreprocessingRule rule) async {
    setState(() {
      _processing = true;
      _processingText = '正在执行「${rule.name}」…';
    });
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;

    try {
      final joined = _joinLines();
      final next = rule.kind == RuleKind.table
          ? _applyTableRule(joined, rule)
          : applyOneRule(joined, rule);
      final nextLines = next.split('\n');

      for (final c in _controllers.values) {
        c.dispose();
      }
      _controllers.clear();

      setState(() {
        _lines = nextLines;
        _dirty = true;
        _selectionStart = null;
        _selectionEnd = null;
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
      builder: (c) => _LineEditorOrderDialog(rules: rules),
    );
  }

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
if (TranslationTable.instance.isEmpty) {
  _toast('词库为空');
  return;
}

final joined = _joinLines();
final next = TranslationTable.instance.convert(joined);
        
        
        
        final nextLines = next.split('\n');

      for (final c in _controllers.values) {
        c.dispose();
      }
      _controllers.clear();

      setState(() {
        _lines = nextLines;
        _dirty = true;
        _selectionStart = null;
        _selectionEnd = null;
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
        // 关键：关闭「键盘弹起时自动收缩 body」。
        // 默认 resizeToAvoidBottomInset=true 会让键盘弹起那一刻整棵 body
        // （工具栏 + 列表 + 状态栏）一起 relayout，几十行 TextField 一起
        // 重新测量/重绘——这就是「点一下弹键盘卡一下」的主要来源。
        // 关掉后 body 高度恒定，改由下方 Padding 按 viewInsets 手动留白，
        // 让正在编辑的行仍可滚动到可见位置。
        resizeToAvoidBottomInset: false,
        appBar: AppBar(
          actions: [
            IconButton(
              icon: const Icon(Icons.vertical_align_top),
              tooltip: '跳到开头',
              onPressed: _jumpToTop,
            ),
            IconButton(
              icon: const Icon(Icons.vertical_align_bottom),
              tooltip: '跳到结尾',
              onPressed: _jumpToBottom,
            ),
            IconButton(
              icon: const Icon(Icons.find_in_page),
              tooltip: '查找 / 替换',
              onPressed: () => setState(() => _showFind = !_showFind),
            ),
            TextButton(
              onPressed: _toggleMultiSelectMode,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
              child: Text(_multiSelectMode ? '退出多选' : '多选行'),
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
                }
              },
              itemBuilder: (_) {
              final toolbarVisible = ref.read(lineEditorToolbarVisibleProvider);
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
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      if (_loadProgress.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Text(
                          _loadProgress,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ],
                  ),
                )
              : Column(
                  children: [
                    if (ref.watch(lineEditorToolbarVisibleProvider))
                      _buildToolbar(),
                    if (_processing) _buildProcessingBanner(),
                    if (_showFind) _buildFindBar(),
                    Expanded(
                      // 独立 widget 隔离键盘留白：viewInsets 的依赖挂在
                      // _KeyboardAwarePadding 上，键盘弹起时只有它重建，
                      // 不会触发整页（工具栏/状态栏）rebuild。
                      child: _KeyboardAwarePadding(
                        child: LayoutBuilder(
                          builder: (ctx, cons) {
                            _viewportHeight = cons.maxHeight;
                            return _buildLineList();
                          },
                        ),
                      ),
                    ),
                    if (_multiSelectMode) _buildMultiSelectBar(),
                    _buildStatusBar(),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _buildProcessingBanner() {
    return Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.tertiaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Text(
        _processingText,
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onTertiaryContainer,
        ),
      ),
    );
  }

  Widget _buildLineList() {
    final s = Theme.of(context).colorScheme;
    final total = _lines.length;
    final gutterColor = _isDefaultSkin(s)
        ? (s.brightness == Brightness.dark
            ? _defaultLineNumberDark
            : _defaultLineNumberLight)
        : s.outline;
    final selStart = _selectionStart;
    final selEnd = _selectionEnd;

    // 行号字号自适应：以"最大行号的位数 + 当前行号宽度"反推能放下的
    // 最大字号（数字字符宽约 0.62em），上限 = 正文字号 - 3，下限 6。
    // 宽度够时维持原字号，宽度窄或行数位数多时自动缩小，不溢出。
    final digits = '${_lines.length}'.length.clamp(1, 10);
    final available = (_lineNumberWidth - 10).clamp(0.0, double.infinity);
    final fit = available / (0.62 * digits);
    final fitCapped = fit < 6.0 ? 6.0 : fit;
    final lineNumberFontSize =
        (_fontSize - 3).clamp(6.0, fitCapped).toDouble();

    final curHitLine =
        (_findPos >= 0 && _findPos < _findHits.length) ? _findHits[_findPos] : -1;

    return ScrollablePositionedList.builder(
      itemScrollController: _itemScrollCtrl,
      itemPositionsListener: _positionsListener,
      itemCount: total,
      itemBuilder: (ctx, i) {
        final ctrl = _controllerFor(i);
        _syncControllerHighlight(i, ctrl);

        final lineNum = i + 1;
        final isStart = selStart == lineNum;
        final isEnd = selEnd == lineNum;
        final inRange = selStart != null &&
            selEnd != null &&
            lineNum > selStart &&
            lineNum < selEnd;

        return _LineRow(
          index: i,
          controller: ctrl,
          fontSize: _fontSize,
          gutterColor: gutterColor,
          showLineNumber: _showLineNumbers,
          lineNumberWidth: _lineNumberWidth,
          lineNumberFontSize: lineNumberFontSize,
          isSelectionStart: isStart,
          isSelectionEnd: isEnd,
          inSelection: inRange,
          isMultiSelected:
              _multiSelectMode && _multiSelected.contains(lineNum),
          isCurrentHitLine: i == curHitLine,
          onTapLineNumber: _showLineNumbers
              ? () => _onTapLineNumber(lineNum)
              : null,
          // 多选模式下整行都是热区：点正文、点行尾空白、点行号，效果一样
          onTapRow:
              _multiSelectMode ? () => _onTapLineNumber(lineNum) : null,
          onLineBreak: _onLineBreakInRow,
          onAttachFocus: _attachFocusNode,
          onDetachFocus: _detachFocusNode,
          onFocus: _ensureLineVisible,
        );
      },
    );
  }

  Widget _buildStatusBar() {
    final s = Theme.of(context).colorScheme;
    final total = _lines.length;

    String selectionInfo = '';
    if (_multiSelectMode) {
      if (_pickingRangeInMulti) {
        selectionInfo = _selectionStart == null
            ? ' · 区间选择：点两行自动勾选'
            : ' · 起点：第 $_selectionStart 行，再点一行定终点';
      } else {
        selectionInfo = _multiSelected.isEmpty
            ? ' · 多选模式：点整行勾选'
            : ' · 多选已选：${_multiSelected.length} 行';
      }
    } else if (_selectionStart != null && _selectionEnd == null) {
      selectionInfo = ' · 起点：第 $_selectionStart 行（再点一行确定范围）';
    } else if (_selectionStart != null && _selectionEnd != null) {
      selectionInfo = ' · 已选：第 $_selectionStart~$_selectionEnd 行';
    }

    String hitInfo = '';
    if (_findCtrl.text.isNotEmpty && _findHits.isNotEmpty) {
      hitInfo =
          ' · 命中 ${_findPos + 1}/${_findHits.length} @ 第 ${_findHits[_findPos] + 1} 行';
    } else if (_findCtrl.text.isNotEmpty && _findHits.isEmpty) {
      hitInfo = ' · 无命中';
    }

    // 检测编码与保存编码相同（绝大多数情况）时只显示一次，
    // 避免状态栏出现 "UTF-8 → UTF-8" 这种看似重复的文案；
    // 两者真正不一致（如手动切编码后）才用 → 标出。
    final encPart = _detectedEncoding.isEmpty || _detectedEncoding == _saveEncoding.label
        ? _saveEncoding.label
        : '$_detectedEncoding → ${_saveEncoding.label}';

    return Container(
      width: double.infinity,
      color: s.surfaceVariant.withOpacity(0.4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Text(
        '$total 行 · $encPart'
        '$selectionInfo'
        '$hitInfo'
        '${_dirty ? " · 未保存" : ""}',
        style: Theme.of(context).textTheme.labelSmall,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _buildFindBar() {
    final s = Theme.of(context).colorScheme;
    final total = _findHits.length;
    final cur = total == 0 ? 0 : (_findPos + 1);

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
                  onPressed: () => setState(() {
                    _showFind = false;
                    _findTimer?.cancel();
                    _findCtrl.clear();
                    _findHits = const <int>[];
                    _findPos = -1;
                    _currentPattern = null;
                    _patternKey = '';
                    for (final c in _controllers.values) {
                      if (c.patternKey.isNotEmpty ||
                          c.isCurrentHitLine) {
                        c.patternKey = '';
                        c.findPattern = null;
                        c.isCurrentHitLine = false;
                        c.currentMatchRange = null;
                        c.notifyListeners();
                      }
                    }
                  }),
                ),
                Expanded(
                  child: TextField(
                    controller: _findCtrl,
                    autofocus: true,
                    cursorColor: Theme.of(context).colorScheme.primary,
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
                  '$cur/$total',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                IconButton(
                  icon: const Icon(Icons.arrow_upward),
                  tooltip: '上一个',
                  // 和下面「搜索」等 TextButton 同一个主色（蓝）
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
                    controller: _replaceCtrl,
                    cursorColor: Theme.of(context).colorScheme.primary,
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
                    foregroundColor: Theme.of(context).colorScheme.primary,
                  ),
                  onPressed: _replaceCurrent,
                  child: const Text('替换当前'),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: Theme.of(context).colorScheme.primary,
                  ),
                  onPressed: _processing ? null : _replaceAll,
                  child: const Text('全部替换'),
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
                    _beginFind();
                  },
                ),
                _toggle(
                  label: '区分大小写',
                  value: _caseSensitive,
                  onTap: () {
                    setState(() => _caseSensitive = !_caseSensitive);
                    _beginFind();
                  },
                ),
                const Spacer(),
                TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: Theme.of(context).colorScheme.primary,
                  ),
                  onPressed: () {
                    // 空输入时给提示，不能点了没反应
                    if (!_ensureFindQuery()) return;
                    _beginFind();
                  },
                  child: const Text('搜索'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 「正则 / 区分大小写」这一组：小开关 + 文字。
  /// 两个都是在同一个 InkWell 里，点开关或点文字都能切换。
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
              alignment:
                  value ? Alignment.centerRight : Alignment.centerLeft,
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

// ==================== 行 Widget ====================

/// 把「键盘弹起时的底部留白」隔离成一个独立 widget。
///
/// 直接在上层 build 里调 MediaQuery.viewInsetsOf 会把整个页面注册成
/// viewInsets 的依赖，键盘弹起 → 整页（工具栏/状态栏）一起 rebuild。
/// 单独拎成 StatelessWidget 后，viewInsets 的依赖只挂在这一个节点上，
/// 键盘弹起时只有它（以及它的 child 列表区）重建，工具栏/状态栏不动，
/// 是「点一下弹键盘卡」的关键优化之一。
class _KeyboardAwarePadding extends StatelessWidget {
  const _KeyboardAwarePadding({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: child,
    );
  }
}

class _LineRow extends StatefulWidget {
  const _LineRow({
    required this.index,
    required this.controller,
    required this.fontSize,
    required this.gutterColor,
    required this.showLineNumber,
    required this.lineNumberWidth,
    required this.lineNumberFontSize,
    required this.isSelectionStart,
    required this.isSelectionEnd,
    required this.inSelection,
    required this.isMultiSelected,
    required this.isCurrentHitLine,
    required this.onTapLineNumber,
    required this.onTapRow,
    required this.onLineBreak,
    required this.onAttachFocus,
    required this.onDetachFocus,
    required this.onFocus,
  });

  final int index;
  final _LineController controller;
  final double fontSize;
  final Color gutterColor;
  final bool showLineNumber;
  final double lineNumberWidth;
  final double lineNumberFontSize;
  final bool isSelectionStart;
  final bool isSelectionEnd;
  final bool inSelection;
  final bool isMultiSelected;
  final bool isCurrentHitLine;
  final VoidCallback? onTapLineNumber;

  /// 多选模式下「点整行」的回调。null = 普通模式，只有行号能点。
  ///
  /// 非 null 时整行都变成勾选热区，并且文本输入被临时屏蔽——
  /// 多选模式下点哪里都是选行，不会误把光标插进正文。
  final VoidCallback? onTapRow;

  /// 提交前拦截到换行时回调：(行下标, 首段, 剩余部分)。
  final void Function(int index, String head, String rest) onLineBreak;

  /// FocusNode 由行自己创建/销毁并登记给列表页——拆行后要把焦点
  /// 交给新行。生命周期跟 TextField 严格绑定，避免"缓存池销毁了
  /// 节点但 TextField 还在引用"的崩溃。
  final void Function(int index, FocusNode node) onAttachFocus;
  final void Function(int index, FocusNode node) onDetachFocus;

  /// 本行获得焦点时回调（index = 行下标），用于把被键盘挡住的当前行
  /// 滚动到可见位置。resizeToAvoidBottomInset=false 后这是必要的兜底。
  final void Function(int index) onFocus;

  @override
  State<_LineRow> createState() => _LineRowState();
}

class _LineRowState extends State<_LineRow> {
  late final FocusNode _focusNode;

  /// 复用的换行拦截器，避免每次 build 都 new 一个（减少弹键盘/重建帧的分配）。
  /// 依赖的 index 在 didUpdateWidget 里同步更新。
  late final _LineBreakSplitter _lineBreakSplitter;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(debugLabel: 'line-${widget.index}');
    _lineBreakSplitter =
        _LineBreakSplitter(widget.index, widget.onLineBreak);
    // 获得焦点（键盘弹起）时，把本行滚到可见位置，避免被键盘挡住。
    // 只有从「无焦点 → 有焦点」这一下才触发，输入过程中不会反复滚。
    _focusNode.addListener(_handleFocusChange);
    widget.onAttachFocus(widget.index, _focusNode);
  }

  void _handleFocusChange() {
    if (_focusNode.hasFocus) {
      widget.onFocus(widget.index);
    }
  }

  @override
  void didUpdateWidget(covariant _LineRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) {
      oldWidget.onDetachFocus(oldWidget.index, _focusNode);
      widget.onAttachFocus(widget.index, _focusNode);
      _lineBreakSplitter.index = widget.index;
    }
    if (oldWidget.onLineBreak != widget.onLineBreak) {
      _lineBreakSplitter.onLineBreak = widget.onLineBreak;
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChange);
    widget.onDetachFocus(widget.index, _focusNode);
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final index = widget.index;
    final isMultiSelected = widget.isMultiSelected;
    final isSelectionStart = widget.isSelectionStart;
    final isSelectionEnd = widget.isSelectionEnd;

    Color? rowBg;
    Color barColor = Colors.transparent;
    if (isMultiSelected) {
      // 多选勾选行用蓝色，区别于区间选中的绿（起点）/橙（终点）
      rowBg = Colors.blue.withValues(alpha: 0.12);
      barColor = Colors.blue;
    } else if (isSelectionStart) {
      rowBg = Colors.green.withValues(alpha: 0.10);
      barColor = Colors.green;
    } else if (isSelectionEnd) {
      rowBg = Colors.blue.withValues(alpha: 0.10);
      barColor = Colors.orange;
    } else if (widget.inSelection) {
      rowBg = Colors.green.withValues(alpha: 0.08);
    }

    final textAreaBg = widget.isCurrentHitLine
        ? const Color(0x0FFF4081) // 粉 @ 6%
        : null;

    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(width: 4, color: barColor),
        if (widget.showLineNumber)
          GestureDetector(
            onTap: widget.onTapLineNumber,
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: widget.lineNumberWidth,
              child: Padding(
                padding:
                    const EdgeInsets.only(top: 8, right: 6, left: 4),
                child: Text(
                  '${index + 1}',
                  textAlign: TextAlign.end,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: widget.lineNumberFontSize,
                    height: 1.4,
                    color: isMultiSelected
                        ? Colors.blue
                        : (isSelectionStart || isSelectionEnd)
                            ? (isSelectionStart
                                ? Colors.green
                                : Colors.orange)
                            : widget.gutterColor,
                    fontWeight: (isMultiSelected ||
                            isSelectionStart ||
                            isSelectionEnd)
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),
              ),
            ),
          ),
        Expanded(
          child: Container(
            color: textAreaBg,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: TextField(
                controller: widget.controller,
                focusNode: _focusNode,
                maxLines: null,
                minLines: 1,
                keyboardType: TextInputType.multiline,
                // 关闭拼写建议/自动更正：减少弹键盘时的 IME 协商开销。
                // 中文拼音输入不受影响，仅英文单词联想会消失。
                enableSuggestions: false,
                autocorrect: false,
                inputFormatters: [_lineBreakSplitter],
                style: TextStyle(
                  fontSize: widget.fontSize,
                  height: 1.4,
                  fontFamily: 'monospace',
                ),
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                ),
              ),
            ),
          ),
        ),
      ],
    );

    final content = rowBg == null ? row : ColoredBox(color: rowBg, child: row);

    // 每行单独一个 RepaintBoundary：键盘弹起/焦点切换时，
    // 只有被点击的那一行会重绘，不会连累整列可见行一起重绘。
    // 这是「点一下弹键盘有点卡」的主要来源之一。
    final isolated = RepaintBoundary(child: content);

    // 多选模式：整行都是勾选热区。
    // 外面套 IgnorePointer，让 TextField 和行号上原有的手势全部失效，
    // 点击（无论落在行号、正文还是行尾空白）都由下面这个 GestureDetector
    // 接住 → 一行只会切换一次，不会和 TextField 抢手势。
    // 拖动不受影响：水平/垂直滑动仍然由外层列表处理。
    final onTapRow = widget.onTapRow;
    if (onTapRow == null) return isolated;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTapRow,
      child: IgnorePointer(child: isolated),
    );
  }
}

// ==================== 换行拦截器（大段粘贴不卡的关键） ====================

/// 在文本「提交给 controller 之前」把换行截走。
///
/// 为什么必须在这一层做：`maxLines: null` 的 TextField 收到多行文本时，
/// 会先把整块内容布局一遍（几千行 = 几十上百毫秒），无论我们在
/// listener / post-frame 里多快把它拆走，那一帧的排版已经发生了。
/// formatter 是唯一能在 commit 之前改值的地方，这里只留首段、其余
/// 交给 [onLineBreak] 排队，TextField 从头到尾只布局一行。
///
/// 成本：一次 indexOf + 两次 substring（O(粘贴长度) 的字符串拷贝），
/// 不做 split——切片推迟到帧末尾的 flush 里做，输入回调里只留最轻的活。
class _LineBreakSplitter extends TextInputFormatter {
  _LineBreakSplitter(this.index, this.onLineBreak);

  int index;
  void Function(int index, String head, String rest) onLineBreak;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = newValue.text;
    final idx = text.indexOf('\n');
    if (idx < 0) return newValue;

    final head = text.substring(0, idx);
    final rest = text.substring(idx + 1);

    // 光标落在首段内（粘贴时通常是首段末尾）
    final cursor = newValue.selection.baseOffset;
    final offset = cursor < 0 ? head.length : cursor.clamp(0, head.length);

    onLineBreak(index, head, rest);

    return TextEditingValue(
      text: head,
      selection: TextSelection.collapsed(offset: offset),
    );
  }
}

// ==================== 带查找高亮的 controller ====================

/// 「当前命中」的字符区间（相对本行起点，左闭右开）。
/// 只用两个 int，省得依赖 dart:ui 的 TextRange，也方便做相等比较。
class _MatchRange {
  const _MatchRange(this.start, this.end);

  final int start;
  final int end;

  @override
  bool operator ==(Object other) =>
      other is _MatchRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);
}

class _LineController extends TextEditingController {
  _LineController({super.text});

  /// 高亮用的 Pattern。null = 没有高亮。
  ///
  /// 和主编辑器的搜索逻辑一致：可能是正则、可能忽略大小写。
  /// 用 Pattern 而不是字符串，是为了让"忽略大小写"和"正则"两种
  /// 模式下，行内高亮都能正确匹配。
  Pattern? findPattern;

  /// findPattern 对应的 key。用来判断"是否需要把新 pattern 刷过来"。
  /// 直接比 Pattern 对象不行——每次 _recomputeHits 都会 new 一个新对象。
  String patternKey = '';

  /// 本行是否包含"当前命中"。
  /// 影响行背景（淡粉）以及命中词的默认颜色。
  bool isCurrentHitLine = false;

  /// 当前命中处的字符区间（相对本行）。null = 本行不是当前命中行。
  /// 一行里有多个匹配时，只有这一段用深粉，其余用黄 —— 「替换当前」
  /// 换的就是这一段，得让用户看得见是哪一处。
  _MatchRange? currentMatchRange;

  static const Color _matchYellow = Color(0xFFFFF59D);
  static const Color _matchPink = Color(0xFFFF4081);

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    if (withComposing && value.composing.isValid) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }

    final text = this.text;
    final p = findPattern;
    if (p == null || text.isEmpty) {
      return TextSpan(style: style, text: text.isEmpty ? ' ' : text);
    }

    final bg = isCurrentHitLine ? _matchPink : _matchYellow;
    final cur = currentMatchRange;
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in p.allMatches(text)) {
      if (m.start == m.end) continue; // 空匹配（如 ^ 或 $）跳过
      if (m.start < last) continue;   // 前一个匹配已经盖过这段了
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start)));
      }
      // 有「当前这一处」时只它用深粉，同行其余匹配保持黄；
      // 没有（本行不是当前行）就整行按 isCurrentHitLine 上色。
      final isCur = cur != null && m.start == cur.start && m.end == cur.end;
      spans.add(TextSpan(
        text: text.substring(m.start, m.end),
        style: TextStyle(
          backgroundColor: cur == null ? bg : (isCur ? _matchPink : _matchYellow),
          fontWeight: FontWeight.bold,
        ),
      ));
      last = m.end;
    }
    if (last < text.length) {
      spans.add(TextSpan(text: text.substring(last)));
    }
    return TextSpan(style: style, children: spans.isEmpty ? null : spans);
  }
}

// ==================== 按钮排序 + 颜色对话框 ====================

class _LineEditorOrderDialog extends ConsumerStatefulWidget {
  const _LineEditorOrderDialog({required this.rules});

  final List<PreprocessingRule> rules;

  @override
  ConsumerState<_LineEditorOrderDialog> createState() =>
      _LineEditorOrderDialogState();
}

class _LineEditorOrderDialogState
    extends ConsumerState<_LineEditorOrderDialog> {
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
      builder: (_) => _LineEditorColorDialog(
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

class _LineEditorColorDialog extends ConsumerStatefulWidget {
  const _LineEditorColorDialog({
    required this.ruleId,
    required this.ruleName,
  });

  final String ruleId;
  final String ruleName;

  @override
  ConsumerState<_LineEditorColorDialog> createState() =>
      _LineEditorColorDialogState();
}

class _LineEditorColorDialogState
    extends ConsumerState<_LineEditorColorDialog> {
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
