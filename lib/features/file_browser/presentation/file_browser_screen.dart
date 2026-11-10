import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:charset/charset.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show ValueListenable, compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/debug/compare_timing_log.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/theme/skin.dart';
import '../../../core/widgets/app_file_icon.dart';
import '../../../core/widgets/gradient_icon.dart';
import '../../help/presentation/help_screen.dart';
import '../../import/presentation/providers/import_providers.dart';
import '../../share_intake/application/share_intake_service.dart';
import '../../share_intake/presentation/shared_trash_page.dart';
import '../../parser/application/document_parser.dart';
import '../../preprocessing/application/encoding_detector.dart';
import '../../preprocessing/domain/encoding_type.dart';
import '../../reader/reader_load_log.dart';
import '../../reader/reader_repository.dart';
import '../../reader/reader_screen.dart';
import '../../viewer/presentation/diff_list_page.dart';
import '../../viewer/presentation/diff_viewer_screen.dart';
import '../../viewer/presentation/providers/diff_viewer_providers.dart';
import 'browser_settings_screen.dart';
import 'comparison_settings_screen.dart';
import 'config_io_service.dart';
import 'dialogs/directory_picker_dialog.dart';
import 'dir_loader.dart';
import 'file_open_helper.dart';
import 'providers/file_browser_providers.dart';
import 'single_file_editor_screen.dart';

// ==================== 路由观察者 ====================

final RouteObserver<PageRoute<dynamic>> fileBrowserRouteObserver =
    RouteObserver<PageRoute<dynamic>>();

// ==================== 导出文件清单 ====================

String _fmtSizeForListing(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

String _fmtTimeForListing(DateTime t) {
  String two(int n) => n < 10 ? '0$n' : '$n';
  return '${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

Future<Uint8List> _folderListingWorker(String rootPath) async {
  final body = StringBuffer();
  var fileCount = 0;
  var dirCount = 0;
  var emptyDirCount = 0;
  var totalBytes = 0;

  void walk(String dirPath) {
    List<FileSystemEntity> entities;
    try {
      entities = Directory(dirPath).listSync(followLinks: false);
    } catch (_) {
      return;
    }

    final files = <File>[];
    final dirs = <Directory>[];
    for (final e in entities) {
      final name = e.path.split('/').last;
      if (name.isEmpty) continue;
      if (e is File) {
        files.add(e);
      } else if (e is Directory) {
        dirs.add(e);
      }
    }

    files.sort(
        (a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
    dirs.sort(
        (a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));

    if (files.isEmpty && dirs.isEmpty) {
      body.writeln('$dirPath | (空目录) | —');
      emptyDirCount++;
      return;
    }

    for (final f in files) {
      int size = 0;
      DateTime? modified;
      try {
        final st = f.statSync();
        size = st.size;
        modified = st.modified;
      } catch (_) {}
      final sizeStr = _fmtSizeForListing(size);
      final timeStr =
          modified == null ? '—' : _fmtTimeForListing(modified);
      body.writeln('${f.path} | $sizeStr | $timeStr');
      fileCount++;
      totalBytes += size;
    }

    for (final d in dirs) {
      dirCount++;
      walk(d.path);
    }
  }

  walk(rootPath);

  final header = StringBuffer();
  header.writeln(
      '# ============================================================');
  header.writeln('# 文件夹文件清单');
  header.writeln(
      '# ============================================================');
  header.writeln('# 根目录：$rootPath');
  header.writeln('# 导出时间：${_fmtTimeForListing(DateTime.now())}');
  header.writeln('# 总文件数：$fileCount');
  header.writeln('# 总目录数：$dirCount（含空目录 $emptyDirCount）');
  header.writeln('# 总大小：${_fmtSizeForListing(totalBytes)}');
  header.writeln('#');
  header.writeln('# 格式说明：');
  header.writeln('#   每一行：完整路径 | 大小 | 修改时间');
  header.writeln('#   空目录：完整路径 | (空目录) | —');
  header.writeln('#   排序：按目录树顺序');
  header.writeln('#         （当前目录的文件在前，子目录按名称递归）');
  header.writeln(
      '# ============================================================');
  header.writeln();

  final builder = BytesBuilder();
  builder.add(utf8.encode(header.toString()));
  builder.add(utf8.encode(body.toString()));
  return builder.takeBytes();
}

/// 查重暂存篮：跨层级收集待查重的文件夹路径。
/// 去重、保持加入顺序；任何目录层级的文件夹都能加入，确认后一次性传给 DupeBox。
final dupBasketProvider = StateProvider<List<String>>((ref) => const []);

class FileBrowserScreen extends ConsumerStatefulWidget {
  const FileBrowserScreen({super.key, this.initialPath, this.revealPath});

  /// 以子页面方式打开时的起始目录。
  /// 为 null 表示主页面：沿用上次浏览目录，并继续写回该记录。
  final String? initialPath;

  /// 打开后需要定位的文件路径（仅子页面使用）：滚动到该文件并短暂高亮。
  final String? revealPath;

  @override
  ConsumerState<FileBrowserScreen> createState() => _FileBrowserScreenState();
}
enum _ConflictAction { skip, overwrite, rename }

// ==================== 批量重命名：配置 + 规则引擎 ====================

class _RenameConfig {
  /// 重命名方式：rules = 规则组合；fullName = 全名 + 序号（Windows 风格）。
  String renameMode = 'rules';

  // 全名重命名
  String fullNameBase = ''; // 新名字（不含扩展名）
  String fullNameSeqFormat = '({n})'; // {n} 会替换成序号

  /// 预览/序号顺序：browser / selected / name / nameDesc /
  /// mtime / mtimeDesc / size / sizeDesc / custom。
  String orderMode = 'browser';

  // 查找替换
  String findText = '';
  String replaceText = '';
  bool useRegex = false;

  // 前缀 / 后缀（扩展名前）
  String prefix = '';
  String suffix = '';

  // 序号
  bool sequenceEnabled = false;
  int sequenceStart = 1;
  int sequenceStep = 1;
  int sequenceWidth = 2;
  bool sequenceAtPrefix = false; // false=放后面，true=放前面
  String sequenceSeparator = '_';

  // 扩展名 / 大小写（弹窗里拆成两个分组）
  bool changeExt = false;
  String newExt = '';
  String caseMode = 'none'; // none / lower / upper / capitalize

  // 高级：插入 / 删除
  bool insertEnabled = false;
  int insertPos = 1; // 在第 N 个字符前插入（1 起）
  String insertText = '';

  bool deleteEnabled = false;
  int deleteStart = 1; // 删除起点（1 起）
  int deleteLength = 1;

  // 日期
  bool dateEnabled = false;
  String dateFormat = 'yyyyMMdd'; // 日期格式模板
  String datePosition = 'suffix'; // prefix / suffix / insert
  int dateInsertPos = 1; // datePosition == insert 时：插在第 N 个字符前
}

/// 纯函数：原名 + 本批序号 + 配置 → 新名。
/// [isDir] 为 true 时不拆扩展名（文件夹名里的 . 不当扩展名处理）。
String _applyRenameRules(
  String original,
  int index,
  _RenameConfig c, {
  bool isDir = false,
}) {
  final dotIdx = original.lastIndexOf('.');
  final hasExt = !isDir && dotIdx > 0 && dotIdx < original.length - 1;
  String base = hasExt ? original.substring(0, dotIdx) : original;
  String ext = hasExt ? original.substring(dotIdx + 1) : '';

  // 1. 查找替换（普通 / 正则，支持 $1 $2 捕获组引用）
  if (c.findText.isNotEmpty) {
    if (c.useRegex) {
      try {
        final re = RegExp(c.findText);
        base = base.replaceAllMapped(re, (m) {
          return c.replaceText.replaceAllMapped(RegExp(r'\$(\d+)'), (mm) {
            final n = int.tryParse(mm.group(1) ?? '');
            if (n == null) return mm.group(0) ?? '';
            return m.group(n) ?? '';
          });
        });
      } catch (_) {
        // 正则非法：原样保留，预览里也不会崩
      }
    } else {
      base = base.replaceAll(c.findText, c.replaceText);
    }
  }

  // 2. 删除区间（先删再加，保证序号位置不受删除影响）
  if (c.deleteEnabled && base.isNotEmpty) {
    final s = (c.deleteStart - 1).clamp(0, base.length);
    final e = (s + c.deleteLength).clamp(0, base.length);
    if (s < e) base = base.substring(0, s) + base.substring(e);
  }

  // 3. 插入文本
  if (c.insertEnabled && c.insertText.isNotEmpty) {
    final p = (c.insertPos - 1).clamp(0, base.length);
    base = base.substring(0, p) + c.insertText + base.substring(p);
  }

  // 4. 大小写（只改名称部分，扩展名不动）
  base = switch (c.caseMode) {
    'lower' => base.toLowerCase(),
    'upper' => base.toUpperCase(),
    'capitalize' => base.isEmpty
        ? base
        : base[0].toUpperCase() + base.substring(1).toLowerCase(),
    _ => base,
  };

  // 5. 日期：按用户选的格式，插到名称前 / 名称后 / 第 N 位前
  if (c.dateEnabled) {
    final fmt = c.dateFormat.isEmpty ? 'yyyyMMdd' : c.dateFormat;
    final dateStr = _formatDate(DateTime.now(), fmt);
    if (dateStr.isNotEmpty) {
      switch (c.datePosition) {
        case 'prefix':
          base = '$dateStr$base';
          break;
        case 'insert':
          final p = (c.dateInsertPos - 1).clamp(0, base.length);
          base = base.substring(0, p) + dateStr + base.substring(p);
          break;
        default:
          base = '$base$dateStr';
      }
    }
  }

  // 6. 序号
  if (c.sequenceEnabled) {
    final n = c.sequenceStart + index * c.sequenceStep;
    final s = n.toString().padLeft(c.sequenceWidth, '0');
    base = c.sequenceAtPrefix
        ? '$s${c.sequenceSeparator}$base'
        : '$base${c.sequenceSeparator}$s';
  }

  // 7. 前缀后缀
  base = '${c.prefix}$base${c.suffix}';

  // 8. 扩展名（文件夹不改）
  if (c.changeExt && !isDir) ext = c.newExt;

  return ext.isEmpty ? base : '$base.$ext';
}

/// 全名重命名：新名字 + 可选序号，保留原扩展名。
///
/// [index] 是按当前顺序排好的序号下标；[useSequence] 为 false（只选了一个文件）
/// 时只改成新名字，不加序号，和 Windows 文件浏览器的行为一致。
String _applyFullNameRules(
  String original,
  int index,
  _RenameConfig c, {
  bool isDir = false,
  bool useSequence = true,
}) {
  final dotIdx = original.lastIndexOf('.');
  final hasExt = !isDir && dotIdx > 0 && dotIdx < original.length - 1;
  final ext = hasExt ? original.substring(dotIdx + 1) : '';

  final base = c.fullNameBase.trim();
  // 还没输入新名字：保持原名，预览会显示「不变」，执行按钮也会禁用。
  if (base.isEmpty) return original;

  var name = base;
  if (useSequence) {
    final n = c.sequenceStart + index * c.sequenceStep;
    final s = n.toString().padLeft(c.sequenceWidth, '0');
    name += c.fullNameSeqFormat.replaceAll('{n}', s);
  }
  return ext.isEmpty ? name : '$name.$ext';
}

/// 日期格式化：支持 yyyy / yy / MM / M / dd / d / HH / H / mm / ss，
/// 其它字符（包括「年」「月」「日」、「-」「_」等）原样输出。
String _formatDate(DateTime t, String fmt) {
  String two(int n) => n.toString().padLeft(2, '0');
  // 长 token 在前，避免 yyyy 被 yy 抢先匹配。
  const tokens = ['yyyy', 'yy', 'MM', 'dd', 'HH', 'mm', 'ss', 'M', 'd', 'H'];
  final sb = StringBuffer();
  var i = 0;
  while (i < fmt.length) {
    var matched = false;
    for (final tk in tokens) {
      if (!fmt.startsWith(tk, i)) continue;
      sb.write(switch (tk) {
        'yyyy' => '${t.year}',
        'yy' => two(t.year % 100),
        'MM' => two(t.month),
        'M' => '${t.month}',
        'dd' => two(t.day),
        'd' => '${t.day}',
        'HH' => two(t.hour),
        'H' => '${t.hour}',
        'mm' => two(t.minute),
        'ss' => two(t.second),
        _ => tk,
      });
      i += tk.length;
      matched = true;
      break;
    }
    if (!matched) {
      sb.write(fmt[i]);
      i++;
    }
  }
  return sb.toString();
}

// ---------- 配置持久化 ----------

const String _kRenameConfigKey = 'batch_rename_config_v1';

/// 序号顺序的可选值（持久化时也要校验）。
const List<(String, String)> _kRenameOrderOptions = [
  ('browser', '列表顺序'),
  ('selected', '选择顺序'),
  ('name', '名称 ↑'),
  ('nameDesc', '名称 ↓'),
  ('mtime', '时间 ↑'),
  ('mtimeDesc', '时间 ↓'),
  ('size', '大小 ↑'),
  ('sizeDesc', '大小 ↓'),
  ('custom', '手动顺序'),
];

const Set<String> _kRenameOrderModes = {
  'browser',
  'selected',
  'name',
  'nameDesc',
  'mtime',
  'mtimeDesc',
  'size',
  'sizeDesc',
  'custom',
};

extension _RenameConfigJson on _RenameConfig {
  Map<String, dynamic> toJson() => <String, dynamic>{
        'renameMode': renameMode,
        'fullNameBase': fullNameBase,
        'fullNameSeqFormat': fullNameSeqFormat,
        'orderMode': orderMode,
        'findText': findText,
        'replaceText': replaceText,
        'useRegex': useRegex,
        'prefix': prefix,
        'suffix': suffix,
        'sequenceEnabled': sequenceEnabled,
        'sequenceStart': sequenceStart,
        'sequenceStep': sequenceStep,
        'sequenceWidth': sequenceWidth,
        'sequenceAtPrefix': sequenceAtPrefix,
        'sequenceSeparator': sequenceSeparator,
        'changeExt': changeExt,
        'newExt': newExt,
        'caseMode': caseMode,
        'insertEnabled': insertEnabled,
        'insertPos': insertPos,
        'insertText': insertText,
        'deleteEnabled': deleteEnabled,
        'deleteStart': deleteStart,
        'deleteLength': deleteLength,
        'dateEnabled': dateEnabled,
        'dateFormat': dateFormat,
        'datePosition': datePosition,
        'dateInsertPos': dateInsertPos,
      };
}

/// 从 JSON 恢复。任何字段缺失/类型不对都回退到默认值。
_RenameConfig _renameConfigFromJson(Map<String, dynamic> j) {
  final c = _RenameConfig();
  String str(String k, String d) => j[k] is String ? j[k] as String : d;
  bool boo(String k, bool d) => j[k] is bool ? j[k] as bool : d;
  int integer(String k, int d) =>
      j[k] is num ? (j[k] as num).toInt() : d;

  c.renameMode = str('renameMode', 'rules');
  c.fullNameBase = str('fullNameBase', '');
  c.fullNameSeqFormat = str('fullNameSeqFormat', '({n})');
  c.orderMode = str('orderMode', 'browser');

  c.findText = str('findText', '');
  c.replaceText = str('replaceText', '');
  c.useRegex = boo('useRegex', false);
  c.prefix = str('prefix', '');
  c.suffix = str('suffix', '');
  c.sequenceEnabled = boo('sequenceEnabled', false);
  c.sequenceStart = integer('sequenceStart', 1);
  c.sequenceStep = integer('sequenceStep', 1);
  c.sequenceWidth = integer('sequenceWidth', 2);
  c.sequenceAtPrefix = boo('sequenceAtPrefix', false);
  c.sequenceSeparator = str('sequenceSeparator', '_');
  c.changeExt = boo('changeExt', false);
  c.newExt = str('newExt', '');
  c.caseMode = str('caseMode', 'none');
  c.insertEnabled = boo('insertEnabled', false);
  c.insertPos = integer('insertPos', 1);
  c.insertText = str('insertText', '');
  c.deleteEnabled = boo('deleteEnabled', false);
  c.deleteStart = integer('deleteStart', 1);
  c.deleteLength = integer('deleteLength', 1);
  c.dateEnabled = boo('dateEnabled', false);
  c.dateFormat = str('dateFormat', 'yyyyMMdd');
  c.datePosition = str('datePosition', 'suffix');
  c.dateInsertPos = integer('dateInsertPos', 1);

  // 边界保护：负值/0 会让 padLeft / substring 炸
  if (c.sequenceWidth < 1) c.sequenceWidth = 1;
  if (c.sequenceWidth > 12) c.sequenceWidth = 12;
  if (c.insertPos < 1) c.insertPos = 1;
  if (c.deleteStart < 1) c.deleteStart = 1;
  if (c.deleteLength < 1) c.deleteLength = 1;
  if (c.dateInsertPos < 1) c.dateInsertPos = 1;
  if (c.dateFormat.isEmpty) c.dateFormat = 'yyyyMMdd';

  // 枚举值兜底，避免旧配置/手改 JSON 让下拉框拿到不存在的 value。
  if (c.renameMode != 'rules' && c.renameMode != 'fullName') {
    c.renameMode = 'rules';
  }
  if (!_kRenameOrderModes.contains(c.orderMode)) c.orderMode = 'browser';
  if (c.fullNameSeqFormat.isEmpty) c.fullNameSeqFormat = '({n})';
  if (!const {'prefix', 'suffix', 'insert'}.contains(c.datePosition)) {
    c.datePosition = 'suffix';
  }

  return c;
}

/// 读上次配置；没有或损坏就返回默认。永不抛异常。
Future<_RenameConfig> _loadRenameConfig() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kRenameConfigKey);
    if (raw == null || raw.isEmpty) return _RenameConfig();
    final map = jsonDecode(raw);
    if (map is! Map) return _RenameConfig();
    return _renameConfigFromJson(map.cast<String, dynamic>());
  } catch (_) {
    return _RenameConfig();
  }
}

/// 写配置。失败静默忽略——记住规则失败不该阻断改名。
Future<void> _saveRenameConfig(_RenameConfig c) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kRenameConfigKey, jsonEncode(c.toJson()));
  } catch (_) {}
}

// ==================== 高级搜索条件 ====================

enum _SearchOperator { or, and, not }

class _SearchCondition {
  _SearchCondition({required this.operator, String text = ''})
      : controller = TextEditingController(text: text);
  _SearchOperator operator;
  final TextEditingController controller;
  String get text => controller.text;
  void dispose() => controller.dispose();
}
class _SearchHit {
  _SearchHit({
    required this.path,
    required this.name,
    this.isDir = false,
    this.size,
    this.modified,
  });
  final String path;
  final String name;
  final bool isDir;
  final int? size;
  final DateTime? modified;
}

class _AdvancedOverlayContent extends StatefulWidget {
  const _AdvancedOverlayContent({
    required this.panelTop,
    required this.panelLeft,
    required this.panelWidth,
    required this.conditions,
    required this.onChanged,
    required this.onClearAll,
    required this.onClearConditions,
    required this.onSubmit,
    required this.onClose,
    required this.filterSizeMinMb,
    required this.filterSizeMaxMb,
    required this.filterTimeFrom,
    required this.filterTimeTo,
    required this.onSizeChanged,
    required this.onTimeChanged,
  });

  final double panelTop;
  final double panelLeft;
  final double panelWidth;
  final List<_SearchCondition> conditions;
  final VoidCallback onChanged;
  final VoidCallback onClearAll;
  final VoidCallback onClearConditions;
  final VoidCallback onSubmit;
  final VoidCallback onClose;
  final double? filterSizeMinMb;
  final double? filterSizeMaxMb;
  final DateTime? filterTimeFrom;
  final DateTime? filterTimeTo;
  final void Function(double? minMb, double? maxMb) onSizeChanged;
  final void Function(DateTime? from, DateTime? to) onTimeChanged;

  @override
  State<_AdvancedOverlayContent> createState() =>
      _AdvancedOverlayContentState();
}

class _AdvancedOverlayContentState extends State<_AdvancedOverlayContent> {
  int? _openMenuIndex;
  final Map<int, GlobalKey> _btnKeys = {};

  final TextEditingController _sizeMinCtrl = TextEditingController();
  final TextEditingController _sizeMaxCtrl = TextEditingController();
  final TextEditingController _timeFromCtrl = TextEditingController();
  final TextEditingController _timeToCtrl = TextEditingController();
  final FocusNode _timeFromFocus = FocusNode();
  final FocusNode _timeToFocus = FocusNode();
  // 光标最后落在哪个时间框：0 = 从框，1 = 到框
  int _lastFocusedTime = 0;

  @override
  void initState() {
    super.initState();
    _sizeMinCtrl.text = _fmtMb(widget.filterSizeMinMb);
    _sizeMaxCtrl.text = _fmtMb(widget.filterSizeMaxMb);
    _timeFromCtrl.text = _fmtDt(widget.filterTimeFrom);
    _timeToCtrl.text = _fmtDt(widget.filterTimeTo);
    _timeFromFocus.addListener(() {
      if (_timeFromFocus.hasFocus) _lastFocusedTime = 0;
    });
    _timeToFocus.addListener(() {
      if (_timeToFocus.hasFocus) _lastFocusedTime = 1;
    });
  }

  @override
  void didUpdateWidget(covariant _AdvancedOverlayContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 父级点「清空条件」后把输入框同步清空（仅当被清空时）。
    if (widget.filterSizeMinMb == null && _sizeMinCtrl.text.isNotEmpty) {
      _sizeMinCtrl.clear();
    }
    if (widget.filterSizeMaxMb == null && _sizeMaxCtrl.text.isNotEmpty) {
      _sizeMaxCtrl.clear();
    }
    if (widget.filterTimeFrom == null && _timeFromCtrl.text.isNotEmpty) {
      _timeFromCtrl.clear();
    }
    if (widget.filterTimeTo == null && _timeToCtrl.text.isNotEmpty) {
      _timeToCtrl.clear();
    }
  }

  GlobalKey _keyFor(int i) => _btnKeys.putIfAbsent(i, () => GlobalKey());

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: _handleOutsideTap,
            behavior: HitTestBehavior.translucent,
            child: const SizedBox.expand(),
          ),
        ),
        Positioned(
          left: widget.panelLeft,
          top: widget.panelTop,
          width: widget.panelWidth,
          child: _buildPanel(),
        ),
        if (_openMenuIndex != null) _buildMenu(),
      ],
    );
  }

  void _handleOutsideTap() {
    if (_openMenuIndex != null) {
      setState(() => _openMenuIndex = null);
    } else {
      widget.onClose();
    }
  }

  Widget _buildPanel() {
    final hasAny = widget.conditions.any((c) => c.text.trim().isNotEmpty) ||
        widget.filterSizeMinMb != null ||
        widget.filterSizeMaxMb != null ||
        widget.filterTimeFrom != null ||
        widget.filterTimeTo != null;
    final cs = Theme.of(context).colorScheme;
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(12),
      color: cs.surface,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.5,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _addClearRow(hasAny),
            if (widget.conditions.isEmpty)
              const SizedBox(height: 8)
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(top: 8, bottom: 4),
                  itemCount: widget.conditions.length,
                  itemBuilder: (_, i) => _row(i),
                ),
              ),
            _buildSizeTimeSection(),
            _submitButton(hasAny),
          ],
        ),
      ),
    );
  }

  Widget _buildSizeTimeSection() {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(height: 1),
          const SizedBox(height: 6),
          Text('文件大小（MB，可留空）',
              style: TextStyle(fontSize: 13, color: cs.onSurface)),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                  child: _numField(_sizeMinCtrl, '最小', (_) => _notifySize())),
              const SizedBox(width: 8),
              Expanded(
                  child: _numField(_sizeMaxCtrl, '最大', (_) => _notifySize())),
              const SizedBox(width: 8),
              _textClearButton('清空', _clearSize),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text('修改时间（精确到秒，可留空）',
                    style: TextStyle(fontSize: 13, color: cs.onSurface)),
              ),
              _nowButton(),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              SizedBox(
                width: 76,
                child: Text('开始时间',
                    style: TextStyle(fontSize: 13, color: cs.onSurface)),
              ),
              Expanded(
                  child: _dateField(_timeFromCtrl,
                      focusNode: _timeFromFocus)),
              const SizedBox(width: 8),
              _textClearButton('清空', () => _clearTime(from: true)),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              SizedBox(
                width: 76,
                child: Text('结束时间',
                    style: TextStyle(fontSize: 13, color: cs.onSurface)),
              ),
              Expanded(
                  child: _dateField(_timeToCtrl,
                      focusNode: _timeToFocus)),
              const SizedBox(width: 8),
              _textClearButton('清空', () => _clearTime(from: false)),
            ],
          ),
          const SizedBox(height: 2),
        ],
      ),
    );
  }

  Widget _numField(
      TextEditingController ctrl, String hint, ValueChanged<String> onCh) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 34,
      child: TextField(
        controller: ctrl,
        onChanged: onCh,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        style: const TextStyle(fontSize: 14),
        cursorColor: cs.primary,
        decoration: InputDecoration(
          isDense: true,
          hintText: hint,
          hintStyle: TextStyle(color: cs.onSurfaceVariant),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: cs.primary, width: 1.5),
          ),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
      ),
    );
  }

  Widget _dateField(TextEditingController ctrl, {FocusNode? focusNode}) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 34,
      child: TextField(
        controller: ctrl,
        focusNode: focusNode,
        onChanged: (_) => _notifyTime(),
        style: const TextStyle(fontSize: 13),
        cursorColor: cs.primary,
        decoration: InputDecoration(
          isDense: true,
          hintText: 'y-m-d h:m:s',
          hintStyle: TextStyle(color: cs.onSurfaceVariant, fontSize: 11),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: cs.primary, width: 1.5),
          ),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
        ),
      ),
    );
  }

  Widget _nowButton() {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 34,
      child: TextButton(
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: cs.onSurfaceVariant),
          ),
        ),
        onPressed: _fillNow,
        child: Text('填入此刻', style: TextStyle(fontSize: 13, color: cs.primary)),
      ),
    );
  }

  // 点击「填入此刻」：把当前时间（精确到秒）填入光标最后所在的时间框。
  void _fillNow() {
    final txt = _fmtDt(DateTime.now());
    final targetCtrl =
        _lastFocusedTime == 1 ? _timeToCtrl : _timeFromCtrl;
    targetCtrl.text = txt;
    _notifyTime();
    // 把焦点设回目标框，光标归位，方便继续改。
    (_lastFocusedTime == 1 ? _timeToFocus : _timeFromFocus).requestFocus();
  }

  void _notifySize() {
    widget.onSizeChanged(
        _parseMb(_sizeMinCtrl.text), _parseMb(_sizeMaxCtrl.text));
  }

  void _notifyTime() {
    widget.onTimeChanged(
        _parseDt(_timeFromCtrl.text), _parseDt(_timeToCtrl.text));
  }

  // 文字「清空」按钮（无图标）。
  Widget _textClearButton(String label, VoidCallback onTap) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 34,
      child: TextButton(
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: cs.onSurfaceVariant),
          ),
        ),
        onPressed: onTap,
        child: Text(label, style: TextStyle(fontSize: 13, color: cs.error)),
      ),
    );
  }

  void _clearSize() {
    _sizeMinCtrl.clear();
    _sizeMaxCtrl.clear();
    _notifySize();
  }

  void _clearTime({required bool from}) {
    if (from) {
      _timeFromCtrl.clear();
    } else {
      _timeToCtrl.clear();
    }
    _notifyTime();
  }

  // 点击「?」图标：解释整个高级搜索面板的用法。
  void _showAdvancedHelp(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('高级搜索说明'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              Text('【关键词条件】',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              Text('• 或者：文件名包含任意一个关键词即可（命中一个就行）。\n'
                  '• 同时：文件名必须同时包含所有关键词。\n'
                  '• 排除：文件名不能包含该关键词。\n'
                  '可点条件左侧的按钮切换「或者 / 同时 / 排除」，并添加多行组合。'),
              SizedBox(height: 10),
              Text('【文件大小】',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              Text('• 单位为 MB，填 5 即 5MB。\n'
                  '• 最小 / 最大均可单独留空：只填最小 → 搜「≥该值」；只填最大 → 搜「≤该值」；都填 → 区间内。\n'
                  '• 文件夹没有大小，任何大小筛选都会把文件夹排除。'),
              SizedBox(height: 10),
              Text('【修改时间】',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              Text('• 格式 y-m-d h:m:s，精确到秒。\n'
                  '• 开始 / 结束均可单独留空：只填开始 → 搜「该时间之后」；只填结束 → 搜「该时间之前」；都填 → 区间内。均为闭区间（含端点）。\n'
                  '• 时间对文件和文件夹都生效。'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  double? _parseMb(String s) {
    s = s.trim();
    if (s.isEmpty) return null;
    return double.tryParse(s);
  }

  DateTime? _parseDt(String s) {
    s = s.trim();
    if (s.isEmpty) return null;
    return DateTime.tryParse(s);
  }

  String _two(int n) => n.toString().padLeft(2, '0');

  String _fmtMb(double? v) =>
      v == null ? '' : (v == v.roundToDouble() ? v.round().toString() : v.toString());

  String _fmtDt(DateTime? d) {
    if (d == null) return '';
    return '${d.year}-${_two(d.month)}-${_two(d.day)} '
        '${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}';
  }

  Widget _row(int i) {
    final cond = widget.conditions[i];
    return Padding(
      padding: const EdgeInsets.only(left: 3, right: 1, top: 3, bottom: 3),
      child: Row(
        children: [
          _operatorBtn(i, cond),
          const SizedBox(width: 6),
          Expanded(
            child: SizedBox(
              height: 36,
              child: TextField(
                controller: cond.controller,
                onChanged: (_) => widget.onChanged(),
                style: const TextStyle(fontSize: 14),
                cursorColor: Theme.of(context).colorScheme.primary,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '输入文字',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(
                      color: Theme.of(context).colorScheme.primary,
                      width: 1.5,
                    ),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                ),
              ),
            ),
          ),
          SizedBox(
            width: 28,
            height: 36,
            child: IconButton(
              padding: EdgeInsets.zero,
              constraints:
                  const BoxConstraints(minWidth: 28, minHeight: 28),
              icon: Icon(Icons.close,
                  size: 20,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
              tooltip: '删除此条件',
              onPressed: () => _remove(i),
            ),
          ),
        ],
      ),
    );
  }

  Widget _operatorBtn(int i, _SearchCondition cond) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      key: _keyFor(i),
      width: 68,
      height: 36,
      child: Material(
        color: cs.surfaceVariant,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _toggleMenu(i),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _label(cond.operator),
                  style: TextStyle(fontSize: 13, color: cs.onSurface),
                ),
                Icon(Icons.arrow_drop_down,
                    size: 18, color: cs.onSurface),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _toggleMenu(int i) {
    setState(() {
      _openMenuIndex = (_openMenuIndex == i) ? null : i;
    });
  }

  void _selectOperator(int i, _SearchOperator op) {
    setState(() {
      widget.conditions[i].operator = op;
      _openMenuIndex = null;
    });
    widget.onChanged();
  }

  void _add() {
    setState(() {
      widget.conditions
          .add(_SearchCondition(operator: _SearchOperator.or));
      _btnKeys.clear();
    });
    widget.onChanged();
  }

  void _remove(int i) {
    if (i < 0 || i >= widget.conditions.length) return;
    setState(() {
      if (_openMenuIndex == i) _openMenuIndex = null;
      widget.conditions[i].dispose();
      widget.conditions.removeAt(i);
      _btnKeys.clear();
    });
    widget.onChanged();
  }

  Widget _buildMenu() {
    final i = _openMenuIndex!;
    if (i < 0 || i >= widget.conditions.length) {
      return const SizedBox.shrink();
    }
    final key = _keyFor(i);
    final btnBox = key.currentContext?.findRenderObject() as RenderBox?;
    if (btnBox == null) return const SizedBox.shrink();
    final btnPos = btnBox.localToGlobal(Offset.zero);
    final top = btnPos.dy + btnBox.size.height + 2;
    final left = btnPos.dx;

    return Positioned(
      left: left,
      top: top,
      child: Material(
        elevation: 3,
        borderRadius: BorderRadius.circular(8),
        color: Theme.of(context).colorScheme.surface,
        child: SizedBox(
          width: 210,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _menuItem(i, _SearchOperator.or, '或者', '命中一个就行'),
              _menuItem(i, _SearchOperator.and, '同时', '必须都出现'),
              _menuItem(i, _SearchOperator.not, '排除', '不要这个'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _menuItem(
      int i, _SearchOperator op, String label, String hint) {
    final cs = Theme.of(context).colorScheme;
    final selected = widget.conditions[i].operator == op;
    return InkWell(
      onTap: () => _selectOperator(i, op),
      child: Padding(
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            SizedBox(
              width: 20,
              child: selected
                  ? Icon(Icons.check,
                      size: 16, color: cs.primary)
                  : null,
            ),
            Text(label,
                style: TextStyle(
                    fontSize: 14, color: cs.onSurface)),
            const SizedBox(width: 12),
            Text(hint,
                style: TextStyle(
                    fontSize: 12, color: cs.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }

  Widget _addClearRow(bool hasAny) {
    final cs = Theme.of(context).colorScheme;
    // 「清空条件」只清文字条件，按"是否有文字条件"决定可点状态。
    final hasTextConditions =
        widget.conditions.any((c) => c.text.trim().isNotEmpty);
    return Padding(
      padding: const EdgeInsets.fromLTRB(3, 12, 3, 0),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 40,
              child: FilledButton(
                onPressed: _add,
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: const Text(
                  '＋ 添加条件',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SizedBox(
              height: 40,
              child: Material(
                color: cs.surfaceVariant,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: hasTextConditions ? widget.onClearConditions : null,
                  child: Center(
                    child: Text(
                      '🗑 清空条件',
                      style: TextStyle(
                        fontSize: 13,
                        color: hasTextConditions
                            ? cs.onSurface
                            : cs.onSurfaceVariant.withValues(alpha: 0.4),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            icon: Icon(Icons.help_outline,
                size: 22, color: cs.onSurfaceVariant),
            tooltip: '高级搜索说明',
            onPressed: () => _showAdvancedHelp(context),
          ),
        ],
      ),
    );
  }

  Widget _submitButton(bool hasAny) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(3, 12, 3, 10),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 44,
              child: OutlinedButton(
                onPressed: hasAny ? widget.onClearAll : null,
                style: OutlinedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(22),
                  ),
                  side: BorderSide(color: cs.onSurfaceVariant),
                ),
                child: Text(
                  '清空全部',
                  style: TextStyle(
                    fontSize: 15,
                    color: hasAny
                        ? cs.onSurface
                        : cs.onSurfaceVariant.withValues(alpha: 0.4),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: SizedBox(
              height: 44,
              child: FilledButton(
                onPressed: hasAny ? widget.onSubmit : null,
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(22),
                  ),
                ),
                child: const Text(
                  '搜索',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _sizeMinCtrl.dispose();
    _sizeMaxCtrl.dispose();
    _timeFromCtrl.dispose();
    _timeToCtrl.dispose();
    _timeFromFocus.dispose();
    _timeToFocus.dispose();
    super.dispose();
  }

  String _label(_SearchOperator op) {
    switch (op) {
      case _SearchOperator.or:
        return '或者';
      case _SearchOperator.and:
        return '同时';
      case _SearchOperator.not:
        return '排除';
    }
  }
}
// ==================== 统一列表项 ====================

class _DisplayItem {
  const _DisplayItem({
    required this.key,
    required this.displayName,
    required this.depth,
    this.isDir = false,
    this.isZip = false,
    this.isZipInner = false,
    this.size,
    this.modified,
    this.diskEntry,
    this.searchHit,
    this.ownerZipKey,
    this.innerPath,
    this.innerPathForDisplay,
    this.innerArchive,
  });

  final String key;
  final String displayName;
  final int depth;

  final bool isDir;
  final bool isZip;
  final bool isZipInner;

  final int? size;
  final DateTime? modified;

  final EntryInfo? diskEntry;
  final _SearchHit? searchHit;

  final String? ownerZipKey;
  final String? innerPath;
  final String? innerPathForDisplay;
  final Archive? innerArchive;

  bool get isDiskItem => diskEntry != null || searchHit != null;
  bool get canExpand => isZip;
  String? get diskPath => diskEntry?.path ?? searchHit?.path;

  String get fullDisplayPath {
    if (ownerZipKey == null) return displayName;
    final zipName = ownerZipKey!.split('/').last;
    final inner = innerPathForDisplay ?? displayName;
    return '$zipName > $inner';
  }
}

// ==================== 虚拟 key 工具 ====================

const String _zipInnerPrefix = 'zip://';
const String _zipInnerSep = '§';

bool _isZipInnerKey(String key) => key.startsWith(_zipInnerPrefix);

String _makeZipInnerKey(String zipPath, String innerPath) =>
    '$_zipInnerPrefix$zipPath$_zipInnerSep$innerPath';

String _zipPathFromInnerKey(String key) {
  final body = key.substring(_zipInnerPrefix.length);
  final idx = body.indexOf(_zipInnerSep);
  return idx < 0 ? body : body.substring(0, idx);
}

String _innerPathFromInnerKey(String key) {
  final body = key.substring(_zipInnerPrefix.length);
  final idx = body.indexOf(_zipInnerSep);
  return idx < 0 ? '' : body.substring(idx + _zipInnerSep.length);
}

// ==================== 判断 zip / tar 文件名 ====================

bool _isExpandableArchiveName(String name) {
  final lower = name.toLowerCase();
  return lower.endsWith('.zip') ||
      lower.endsWith('.tar') ||
      lower.endsWith('.tar.gz') ||
      lower.endsWith('.tgz');
}

// ==================== 从 archive 里读直接子节点 ====================

class _ZipNode {
  const _ZipNode({
    required this.name,
    required this.fullPath,
    required this.isDir,
    required this.isZip,
    required this.size,
  });

  final String name;
  final String fullPath;
  final bool isDir;
  final bool isZip;
  final int size;
}

List<_ZipNode> _directZipChildren(Archive archive, String at) {
  final prefix = at.isEmpty ? '' : '$at/';
  final dirNames = <String>{};
  final fileMap = <String, ArchiveFile>{};

  for (final f in archive.files) {
    final name = f.name;
    if (name.isEmpty) continue;
    if (name.startsWith('__MACOSX/')) continue;
    if (!name.startsWith(prefix)) continue;
    final rest = name.substring(prefix.length);
    if (rest.isEmpty) continue;

    final slash = rest.indexOf('/');
    if (slash < 0) {
      if (f.isFile) {
        fileMap[rest] = f;
      } else {
        dirNames.add(rest);
      }
    } else {
      dirNames.add(rest.substring(0, slash));
    }
  }

  final out = <_ZipNode>[];
  for (final name in dirNames) {
    out.add(_ZipNode(
      name: name,
      fullPath: '$prefix$name',
      isDir: true,
      isZip: false,
      size: 0,
    ));
  }
  for (final e in fileMap.entries) {
    final name = e.key;
    out.add(_ZipNode(
      name: name,
      fullPath: '$prefix$name',
      isDir: false,
      isZip: _isExpandableArchiveName(name),
      size: e.value.size,
    ));
  }

  out.sort((a, b) {
    if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return out;
}

// ==================== 主状态类（开始） ====================

class _FileBrowserScreenState extends ConsumerState<FileBrowserScreen>
    with RouteAware, SingleTickerProviderStateMixin {
  static const String _rootPath = '/storage/emulated/0';
  static const String _topPath = '/storage';

  static const EdgeInsets _dlgInset = EdgeInsets.all(4);
  static const EdgeInsets _dlgTitlePad =
      EdgeInsets.fromLTRB(12, 8, 12, 0);
  static const EdgeInsets _dlgContentPad = EdgeInsets.fromLTRB(8, 4, 8, 4);
  static const EdgeInsets _dlgActionsPad =
      EdgeInsets.fromLTRB(4, 0, 4, 4);

  static const double _gridCellPadH = 8.0;
  static const double _gridCellPadV = 6.0;
  static const double _gridDividerThickness = 0.5;

  static const Set<String> _textExts = {
    '.txt', '.md', '.markdown', '.log', '.lst', '.diz', '.nfo',
    '.json', '.xml', '.yaml', '.yml', '.toml', '.ini', '.conf', '.cfg',
    '.csv', '.tsv',
    '.sh', '.bash', '.zsh', '.bat', '.cmd', '.ps1',
    '.py', '.js', '.ts', '.java', '.kt', '.dart', '.c', '.cpp', '.cc',
    '.h', '.hpp', '.cs', '.go', '.rs', '.rb', '.php', '.lua', '.smali',
    '.html', '.htm', '.css', '.scss',
    '.diff', '.patch',
  };

  static const Set<String> _binaryExts = {
    '.mp4', '.mkv', '.avi', '.mov', '.flv', '.wmv', '.webm', '.m4v',
    '.3gp', '.mpg', '.mpeg', '.rmvb', '.rm', '.vob',
    '.mp3', '.flac', '.wav', '.aac', '.ogg', '.m4a', '.wma', '.ape',
    '.opus',
    '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp', '.svg', '.ico',
    '.tif', '.tiff', '.heic', '.raw',
    '.zip', '.rar', '.7z', '.tar', '.gz', '.bz2', '.xz', '.iso',
    '.cab', '.lz', '.lzma', '.zst', '.apk', '.apks', '.xapk', '.aab',
    '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx',
    '.odt', '.ods', '.odp', '.epub', '.mobi', '.azw', '.azw3',
    '.exe', '.dll', '.so', '.bin', '.img', '.db', '.sqlite', '.mdb',
  };
static const Set<String> _imageExts = {
  '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp', '.svg', '.ico',
  '.tif', '.tiff', '.heic', '.raw',
};

static const Set<String> _videoExts = {
  '.mp4', '.mkv', '.avi', '.mov', '.flv', '.wmv', '.webm', '.m4v',
  '.3gp', '.mpg', '.mpeg', '.rmvb', '.rm', '.vob',
};

static const Set<String> _audioExts = {
  '.mp3', '.flac', '.wav', '.aac', '.ogg', '.m4a', '.wma', '.ape',
  '.opus',
};

static const Set<String> _archiveExts = {
  '.zip', '.rar', '.7z', '.tar', '.gz', '.bz2', '.xz', '.iso',
  '.cab', '.lz', '.lzma', '.zst', '.apk', '.apks', '.xapk', '.aab',
};
  static String _extOf(String name) {
    final i = name.lastIndexOf('.');
    if (i <= 0 || i == name.length - 1) return '';
    return name.substring(i).toLowerCase();
  }

  // 图标颜色不再由这里决定：默认皮肤用 AppFileIcon 的品牌渐变，
  // 其他皮肤回退 Material 图标；zip 内的次要条目通过 tint 参数弱化。

  Color _gridDividerColorOf(BuildContext context) =>
      Theme.of(context).colorScheme.outlineVariant;

  // ==================== 状态字段 ====================

  late String _currentPath;
  List<EntryInfo>? _entries;
  bool _loading = false;
  bool _showSkeleton = false;
  Timer? _skeletonTimer;
  int _bodyRevision = 0; // 每次切目录 +1，用来强制 AnimatedSwitcher 重建
  String? _error;

  LoadCancelToken? _loadCancelToken;

  final TextEditingController _searchCtrl = TextEditingController();

  /// 搜索输入框的焦点节点。
  /// 用于：展开搜索栏时自动聚焦；监听聚焦变化以刷新边框/标签颜色。
  final FocusNode _searchFocus = FocusNode();

  final ItemScrollController _itemScrollController = ItemScrollController();
  final ItemPositionsListener _positionsListener =
      ItemPositionsListener.create();

  final Map<String, int> _dirScrollPositions = {};

  /// 下次列表体首次挂载时使用的初始滚动下标；在 build 里被消费（置 null），
  /// 因此只在「切换目录 / 重载」后的第一次挂载生效一次，后续 build 传 0 不影响已挂载的列表。
  /// 相比 postFrameCallback 的 jumpTo，它让列表第一次 layout 就落在正确位置，
  /// 不会有「先渲染第 0 行再跳」的一帧闪烁。
  int? _initialScrollIndex;

  /// 每次切换目录 / 重载递增，作为列表体 key 的一部分，强制 [ScrollablePositionedList]
  /// 重新挂载，从而让上面的 [initialScrollIndex] 重新生效。
  int _listGeneration = 0;

  /// 正在恢复滚动位置时置 true，临时抑制 [_recordCurrentScroll]，
  /// 避免路径锚点 jump 的瞬间把已存的滚动位置覆盖成跳转目标之外的值。
  bool _restoringScroll = false;

  /// 子页面打开后要定位的文件：是否已处理、当前高亮的路径及计时器。
  bool _revealHandled = false;
  String? _flashPath;
  Timer? _flashTimer;

  /// 「刚才去过的那一项」。
  ///
  /// 从编辑器 / 阅读器返回，或进入一个文件夹再退回上级时，
  /// 用它把那一项标出来（淡色底 + 左侧一条竖杠），
  /// 让用户一眼看到自己刚才在哪个位置——不用再回想、不用再找。
  ///
  /// 存的是完整路径而不是下标：路径全局唯一，回到哪个目录都不用换算，
  /// 而且列表重排 / 刷新后依然对得上。当前目录里没有这一项时自然就不显示。
  String? _lastVisitedPath;

  /// 「刚才去过」高亮的渐隐动画。出现即开始 ~700ms 由满色淡到透明，
  /// 结束自动把 [_lastVisitedPath] 置空，彻底消失。
  /// 用户要求：高亮不能一直挂着，要自动变浅消失（最长 1 秒）。
  late final AnimationController _visitedFadeCtrl;
  late final Animation<double> _visitedFade; // 1.0（最浓）→ 0.0（透明）

  /// 当前列表（网格模式按行算）的条目总数，供自定义滚动条与翻页按钮使用。
  /// 每次构建列表时刷新；非列表状态（加载中/空目录/出错）置 0。
  int _scrollItemCount = 0;

  bool _selectionMode = false;
  final Set<String> _selectedPaths = <String>{};
  String? _anchorPath;

  List<_SearchHit> _searchResults = <_SearchHit>[];
  bool _searching = false;
  bool _searchActive = false;
  int _searchTaskId = 0;
  DateTime _lastUiRefresh = DateTime.now();

  // ★ 新增：最近一次整行点击的 x 坐标（相对行左边）。
  // 用来判断点的是不是左侧图标区（图标区点=选中，其它=打开）。
  double _lastTapX = double.infinity;
// ==================== 高级搜索条件状态 ====================
bool _advancedOpen = false;
final List<_SearchCondition> _searchConditions = [];
final GlobalKey _searchBarBoxKey = GlobalKey();
final GlobalKey _searchInputKey = GlobalKey();
OverlayEntry? _advancedOverlay;

// 高级搜索 · 大小 / 时间筛选（允许主框留空，仅按大小或时间搜）
double? _filterSizeMinMb;
double? _filterSizeMaxMb;
DateTime? _filterTimeFrom;
DateTime? _filterTimeTo;

// 悬浮菜单（顶栏「更多」和多选底栏「⋯」共用）：
// 不套任何底板，只在锚点旁竖排一列圆角按钮。
// 锚点 key / OverlayEntry 都是本页实例自己的（父子页面会同时挂载），不要挪到文件级。
final GlobalKey _appBarMoreAnchorKey = GlobalKey();
final GlobalKey _bottomMoreAnchorKey = GlobalKey();
OverlayEntry? _floatingMenuEntry;


  // ==================== zip 展开状态 ====================

  final Set<String> _expandedZipKeys = <String>{};
  final Map<String, Archive> _zipArchives = <String, Archive>{};
  final Set<String> _loadingZipKeys = <String>{};
  final Set<String> _encryptedNestedZipKeys = <String>{};
  final Map<String, String> _zipErrors = <String, String>{};

  /// ★ 粘性头部已停用，此字段保留但始终为 null。
String? _stickyZipKey;

// ==================== 过滤状态 ====================

int _filterTaskId = 0;
List<_DisplayItem>? _visibleItems;
List<_DisplayItem>? _cachedDisplayItems;
List<String?>? _cachedOwnerZipPerIndex;

  static const int _maxZipBytes = 50 * 1024 * 1024;

  static const Set<String> _forceSystemPickerExts = {
    '.7z', '.rar', '.dzip', '.iso', '.tz', '.gz',
    '.epub', '.pdf', '.doc', '.docx',
  };

	/// 单次展开中，所有嵌套 zip 解压后的累计大小上限。
/// _maxZipBytes 只限制顶层 zip 磁盘大小，拦不住"小包大解压"
/// 和"嵌套 zip 层层解压"。这里累计统计解压后内容，超限停手。
static const int _maxTotalDecodedBytes = 200 * 1024 * 1024;
static const int _searchMaxDepth = 1000;

/// 本次展开中已累计的解压字节数。
int _expandedDecodedBytes = 0;

  // ==================== 生命周期 ====================

  
  @override
void initState() {
  super.initState();
  // 「刚才去过」高亮的渐隐：每帧重绘让底色 / 竖杠变浅，结束后清掉 path。
  _visitedFadeCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );
  _visitedFade = Tween<double>(begin: 1.0, end: 0.0).animate(
    CurvedAnimation(parent: _visitedFadeCtrl, curve: Curves.easeOut),
  );
  _visitedFadeCtrl.addListener(() {
    if (mounted) setState(() {});
  });
  _visitedFadeCtrl.addStatusListener((status) {
    if (status == AnimationStatus.completed && mounted) {
      setState(() => _lastVisitedPath = null);
    }
  });
  // 清掉上次会话遗留的 zip 内临时文件。
  // 不 await：后台跑，不阻塞启动。子页面不重复清理，避免误删主页面正在用的临时文件。
  if (widget.initialPath == null) _cleanTempDirOnce();
  final saved = widget.initialPath ?? ref.read(lastPathProvider);
  _currentPath = _resolveInitialPath(saved);
  _positionsListener.itemPositions.addListener(_onPositionsChanged);
  _searchFocus.addListener(_onSearchFocusChanged);
  _load();
}

void _onSearchFocusChanged() {
  if (mounted) setState(() {});
}

/// 清空 systemTemp 里所有 zzz_ 前缀的文件。
/// 这个前缀专门标记 App 自己写的临时文件，避免误删别人的东西。
Future<void> _cleanTempDirOnce() async {
  try {
    final dir = Directory.systemTemp;
    if (!await dir.exists()) return;
    var n = 0;
    await for (final e in dir.list(followLinks: false)) {
      if (e is! File) continue;
      final name = e.path.split('/').last;
      if (!name.startsWith('zzz_')) continue;
      try {
        await e.delete();
        n++;
      } catch (_) {}
    }
    if (n > 0) {
      ReaderLoadLog.instance.info('[TempCleanup] 清理 $n 个临时文件');
    }
  } catch (_) {}
}

  String _resolveInitialPath(String? saved) {
    if (saved == null || saved.isEmpty) return _rootPath;
    if (!saved.startsWith(_topPath)) return _rootPath;
    if (!Directory(saved).existsSync()) return _rootPath;
    return saved;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) {
      fileBrowserRouteObserver.subscribe(this, route);
    }
  }

  @override
  void didPushNext() {
    FocusManager.instance.primaryFocus?.unfocus();
  }

  @override
  void dispose() {
    fileBrowserRouteObserver.unsubscribe(this);
    _visitedFadeCtrl.dispose();
    _skeletonTimer?.cancel();
    _flashTimer?.cancel();
    _loadCancelToken?.cancel();
    _positionsListener.itemPositions.removeListener(_onPositionsChanged);
  _searchFocus.removeListener(_onSearchFocusChanged);
  _searchFocus.dispose();
  _searchCtrl.dispose();
  _advancedOverlay?.remove();
  _advancedOverlay = null;
  _floatingMenuEntry?.remove();
  _floatingMenuEntry = null;
  for (final c in _searchConditions) {
    c.dispose();
  }
  _searchConditions.clear();
  super.dispose();
}

  Route<T> _noAnimRoute<T>(Widget page) {
    return PageRouteBuilder<T>(
      pageBuilder: (_, __, ___) => page,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
    );
  }

  // ==================== 悬浮圆角按钮菜单 ====================

  static const TextStyle _chipLabelStyle = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w500,
  );

  /// 悬浮菜单（顶栏「更多」/ 多选底栏「⋯」）选项按钮专用样式：
  /// 默认皮肤：背景统一为 #F4F5F7、主题蓝字、无描边（保持原样不动）。
  /// 自定义皮肤：与底栏第一行「复制路径 / 分享」按钮完全一致
  /// （同色系 surface 底 + outline 描边，字色 onSurface、字号 12/w500），
  /// 不再用统一的 #F4F5F7 灰底。
  /// 悬浮菜单选项的高度：统一锁定为与底栏「复制路径 / 分享」按钮相同的 38，
  /// 这样自定义皮肤（按钮 padding 更小）下也不会显得比底栏按钮矮一截。
  static const double _menuChipHeight = 38.0;

  ButtonStyle _menuChipStyle() {
    final s = Theme.of(context).colorScheme;
    final isDefaultSkin = ref.watch(skinProvider) == AppSkin.defaultBlue;
    // 锁高 38，并去掉默认 64×40 的最小尺寸干扰（否则短标签会被默认最小宽度撑开）。
    const minSize = WidgetStatePropertyAll(Size(0, _menuChipHeight));
    const shrink = MaterialTapTargetSize.shrinkWrap;
    if (isDefaultSkin) {
      return OutlinedButton.styleFrom(
        minimumSize: const Size(0, _menuChipHeight),
        tapTargetSize: shrink,
        // 竖向留白 16→4 缩小高度：内容高度落到 38 以下，由 minimumSize 38 兜底
        // 撑成与底栏第一行按钮同高（底栏固定 38，保持不动）。横向留白仍 16，与底栏一致。
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        foregroundColor: s.primary,
        backgroundColor: const Color(0xFFF4F5F7),
        side: BorderSide.none,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      );
    }
    // 自定义皮肤：复用「复制路径 / 分享」样式，竖向留白 16→4 缩小高度，
    // 再锁高 38 与底栏按钮对齐（底栏固定 38，保持不动）。
    // 注意：ButtonStyle.copyWith 的 tapTargetSize 是普通值 MaterialTapTargetSize?，
    // 不是 WidgetStateProperty，因此直接传 shrink，不能包 WidgetStatePropertyAll。
    return _softChipStyle(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    ).copyWith(
      minimumSize: minSize,
      tapTargetSize: shrink,
    );
  }

  /// 与多选底栏「复制路径 / 分享」完全一致的按钮样式（正方形 16:16 留白）。
  ButtonStyle _softChipStyle({EdgeInsets? padding}) {
    final s = Theme.of(context).colorScheme;
    final isDefaultSkin = ref.watch(skinProvider) == AppSkin.defaultBlue;
    return OutlinedButton.styleFrom(
      padding: padding ??
          const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      foregroundColor: isDefaultSkin ? s.primary : s.onSurface,
      // 悬浮菜单直接压着文件列表，底必须不透明，否则文字和文件名叠在一起。
      // 默认皮肤：底色用 #F4F5F7，与三个点弹出的「反选 / 打开方式」菜单项完全一致；
      // 自定义皮肤：底色等于 surface（同色系），视觉上和原来的透明一致。
      backgroundColor:
          isDefaultSkin ? const Color(0xFFF4F5F7) : s.surface,
      side: isDefaultSkin ? BorderSide.none : BorderSide(color: s.outline),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
    );
  }

  Widget _menuChip({
    required String label,
    required ButtonStyle style,
    Widget? icon,
    VoidCallback? onPressed,
  }) {
    return OutlinedButton(
      style: style,
      onPressed: onPressed == null
          ? null
          : () {
              _closeFloatingMenu();
              onPressed();
            },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            icon,
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: _chipLabelStyle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  void _closeFloatingMenu() {
    final entry = _floatingMenuEntry;
    if (entry == null) return;
    _floatingMenuEntry = null;
    entry.remove();
    // 菜单开关会影响 PopScope 的 canPop（返回键要先关菜单），需要重建一次。
    if (mounted) setState(() {});
  }

  /// 在 [anchorKey] 旁弹出竖排菜单。
  /// [above] 为 true 时向上展开（底栏「⋯」），否则向下展开（顶栏「更多」）。
  void _showFloatingMenu({
    required GlobalKey anchorKey,
    required List<Widget> items,
    required bool above,
  }) {
    _closeFloatingMenu();
    final anchorContext = anchorKey.currentContext;
    if (anchorContext == null) return;
    final overlayState = Overlay.of(context);
    final overlayBox =
        overlayState.context.findRenderObject() as RenderBox?;
    final anchorBox = anchorContext.findRenderObject() as RenderBox?;
    if (overlayBox == null || anchorBox == null || !anchorBox.hasSize) return;

    final anchorTopLeft =
        anchorBox.localToGlobal(Offset.zero, ancestor: overlayBox);
    final anchorSize = anchorBox.size;
    final overlaySize = overlayBox.size;
    const gap = 6.0;
    const margin = 8.0;
    final right = math.max(
      margin,
      overlaySize.width - anchorTopLeft.dx - anchorSize.width,
    );
    final maxHeight = above
        ? anchorTopLeft.dy - gap - margin
        : overlaySize.height -
            anchorTopLeft.dy -
            anchorSize.height -
            gap -
            margin;

    _floatingMenuEntry = OverlayEntry(
      builder: (_) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _closeFloatingMenu,
            ),
          ),
          Positioned(
            right: right,
            top: above ? null : anchorTopLeft.dy + anchorSize.height + gap,
            bottom:
                above ? overlaySize.height - anchorTopLeft.dy + gap : null,
            child: ConstrainedBox(
              constraints:
                  BoxConstraints(maxHeight: math.max(80.0, maxHeight)),
              child: Material(
                // 透明 Material：只为按钮提供墨水和文字样式，不画底板。
                type: MaterialType.transparency,
                child: TweenAnimationBuilder<double>(
                  key: const ValueKey('floatingMenuAnim'),
                  tween: Tween<double>(begin: 0.0, end: 1.0),
                  duration: const Duration(milliseconds: 170),
                  curve: Curves.easeOutCubic,
                  builder: (ctx, v, child) => Opacity(
                    opacity: v,
                    child: Transform.scale(
                      scale: 0.95 + 0.05 * v,
                      alignment:
                          above ? Alignment.bottomRight : Alignment.topRight,
                      child: child,
                    ),
                  ),
                  child: _FloatingMenuScroller(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        for (var i = 0; i < items.length; i++) ...[
                          if (i > 0) const SizedBox(height: 6),
                          items[i],
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    overlayState.insert(_floatingMenuEntry!);
    // 让 PopScope 的 canPop 立刻感知「菜单已打开」，返回键才会先关菜单。
    if (mounted) setState(() {});
  }

  /// 统一入口：顶栏按钮和三个点菜单都调它。
  Future<void> _dispatchTopBarAction(String id) async {
    switch (id) {
      case 'searchToggle':
        _toggleSearchBarCollapsed();
      case 'favorite':
        _toggleFavorite();
      case 'dedup':
        _onTapDedupButton();
      case 'comparisonRules':
        Navigator.of(context).push(_noAnimRoute(
          const ComparisonSettingsScreen(),
        ));
      case 'browserSettings':
        final beforeField = ref.read(sortFieldProvider);
        final beforeAsc = ref.read(sortAscProvider);
        await Navigator.of(context).push(_noAnimRoute(
          const BrowserSettingsScreen(),
        ));
        if (!mounted) return;
        final afterField = ref.read(sortFieldProvider);
        final afterAsc = ref.read(sortAscProvider);
        if (beforeField != afterField || beforeAsc != afterAsc) {
          DirCache.instance.invalidate(_currentPath);
          _load();
        }
      case 'configIo':
        _showConfigIoMenu();
      case 'refresh':
        DirCache.instance.invalidate(_currentPath);
        _load(skipCache: true);
      case 'jumpToPath':
        _showJumpToPathDialog();
      case 'jumpToTop':
        _jumpToTop();
      case 'dirInfo':
        _showDirInfoDialog();
      case 'favoritesList':
        _showFavorites();
      case 'newFolder':
        _newFolder();
      case 'help':
        Navigator.of(context).push(_noAnimRoute(const HelpScreen()));
      case 'sharedTrash':
        Navigator.of(context).push(_noAnimRoute(const SharedTrashPage()));
    }
  }

  // ==================== 滚动 → 粘性头部（已停用） ====================

  void _onPositionsChanged() {
    _recordCurrentScroll();
  }

  // ignore: unused_element
  void _updateStickyZip() {
    final items = _cachedDisplayItems;
    if (items == null || items.isEmpty) {
      if (_stickyZipKey != null) {
        setState(() => _stickyZipKey = null);
      }
      return;
    }

    final positions = _positionsListener.itemPositions.value;
    if (positions.isEmpty) {
      if (_stickyZipKey != null) {
        setState(() => _stickyZipKey = null);
      }
      return;
    }

    int topIdx = 1 << 30;
    for (final p in positions) {
      if (p.itemLeadingEdge <= 0.0 && p.index < topIdx) {
        topIdx = p.index;
      }
    }
    if (topIdx == 1 << 30) {
      if (_stickyZipKey != null) {
        setState(() => _stickyZipKey = null);
      }
      return;
    }

    final sticky = _computeStickyZipForIndex(topIdx, items);
    if (_stickyZipKey != sticky) {
      setState(() => _stickyZipKey = sticky);
    }
  }

  // ignore: unused_element
  String? _computeStickyZipForIndex(int topIdx, List<_DisplayItem> items) {
    if (topIdx < 0 || topIdx >= items.length) return null;
    final item = items[topIdx];
    if (item.isZip && item.ownerZipKey == null) return null;
    final owner = item.ownerZipKey;
    if (owner == null) return null;
    for (var i = 0; i < items.length; i++) {
      final it = items[i];
      if (it.isZip && it.key == owner && it.ownerZipKey == null) {
        if (i < topIdx) return owner;
        return null;
      }
    }
    for (var i = 0; i < items.length; i++) {
      final it = items[i];
      if (it.isZip && it.key == owner) {
        if (i < topIdx) return owner;
        return null;
      }
    }
    return null;
  }

  // ==================== 显示列表构建 ====================

  List<_DisplayItem> _buildDisplayItems() {
    final out = <_DisplayItem>[];

    if (_searchActive) {
      for (final hit in _searchResults) {
        final isZip = !hit.isDir && _isExpandableArchiveName(hit.name);

        final key = hit.path;
       out.add(_DisplayItem(
  key: key,
  displayName: hit.name,
  depth: 0,
  isDir: hit.isDir,    // ★ 加这行
  isZip: isZip,
  size: hit.size,
  modified: hit.modified,
  searchHit: hit,
));
        if (isZip && _expandedZipKeys.contains(key)) {
          _appendZipChildren(
            out: out,
            zipDiskPath: key,
            zipArchive: _zipArchives[key],
            at: '',
            innerPrefix: '',
            parentOwnerKey: null,
            depth: 1,
            error: _zipErrors[key],
            loading: _loadingZipKeys.contains(key),
          );
        }
      }
      return out;
    }

    final entries = _entries ?? const <EntryInfo>[];
    for (final info in entries) {
      final isZip = !info.isDir && _isExpandableArchiveName(info.name);
      final key = info.entity.path;
      out.add(_DisplayItem(
        key: key,
        displayName: info.name,
        depth: 0,
        isDir: info.isDir,
        isZip: isZip,
        size: info.size,
        modified: info.modified,
        diskEntry: info,
      ));
      if (isZip && _expandedZipKeys.contains(key)) {
        _appendZipChildren(
          out: out,
          zipDiskPath: key,
          zipArchive: _zipArchives[key],
          at: '',
          innerPrefix: '',
          parentOwnerKey: null,
          depth: 1,
          error: _zipErrors[key],
          loading: _loadingZipKeys.contains(key),
        );
      }
    }
    return out;
  }

  void _appendZipChildren({
    required List<_DisplayItem> out,
    required String zipDiskPath,
    required Archive? zipArchive,
    required String at,
    required String innerPrefix,
    required String? parentOwnerKey,
    required int depth,
    String? error,
    bool loading = false,
  }) {
    if (depth == 1) {
      if (loading) {
        out.add(_DisplayItem(
          key: '__loading__$zipDiskPath',
          displayName: '正在加载…',
          depth: depth,
          ownerZipKey: zipDiskPath,
          isZipInner: true,
        ));
        return;
      }
      if (error != null) {
        out.add(_DisplayItem(
          key: '__error__$zipDiskPath',
          displayName: '加载失败：$error',
          depth: depth,
          ownerZipKey: zipDiskPath,
          isZipInner: true,
        ));
        return;
      }
    }
    if (zipArchive == null) return;

    final children = _directZipChildren(zipArchive, at);
    for (final c in children) {
      final innerFullForDisplay = innerPrefix.isEmpty
          ? c.fullPath
          : '$innerPrefix>${c.fullPath}';

      final nodeKey = _makeZipInnerKey(zipDiskPath, innerFullForDisplay);
      final ownerKey = parentOwnerKey ?? zipDiskPath;

      out.add(_DisplayItem(
        key: nodeKey,
        displayName: c.name,
        depth: depth,
        isDir: c.isDir,
        isZip: c.isZip,
        isZipInner: true,
        size: c.size,
        ownerZipKey: ownerKey,
        innerPath: c.fullPath,
        innerPathForDisplay: innerFullForDisplay,
        innerArchive: zipArchive,
      ));

      if (c.isDir) {
        _appendZipChildren(
          out: out,
          zipDiskPath: zipDiskPath,
          zipArchive: zipArchive,
          at: c.fullPath,
          innerPrefix: innerPrefix,
          parentOwnerKey: ownerKey,
          depth: depth + 1,
        );
      } else if (c.isZip) {
        final nestedKey =
            _makeZipInnerKey(zipDiskPath, innerFullForDisplay);
        final nestedArchive = _zipArchives[nestedKey];
        if (nestedArchive != null) {
          _appendZipChildren(
            out: out,
            zipDiskPath: zipDiskPath,
            zipArchive: nestedArchive,
            at: '',
            innerPrefix: innerFullForDisplay,
            parentOwnerKey: nestedKey,
            depth: depth + 1,
          );
        }
      }
    }
  }

  // ==================== 加载目录 ====================

  Future<void> _load({
  bool restoreScroll = false,
  bool skipCache = false,
  bool silent = false,
}) async {
    _loadCancelToken?.cancel();
    final token = LoadCancelToken();
    _loadCancelToken = token;

    final log = ReaderLoadLog.instance;
    final t0 = DateTime.now();

    final anchor = restoreScroll ? _snapshotVisiblePaths() : const <String>[];
    var anchorRestored = false;

final sortField = ref.read(sortFieldProvider);
final sortAsc = ref.read(sortAscProvider);
final cacheKey = '$_currentPath|${sortField.name}|$sortAsc';
    if (_expandedZipKeys.isNotEmpty) {
      _clearZipExpansion();
    }

    if (!skipCache) {
      final cached = DirCache.instance.get(cacheKey);
      if (cached != null) {
        log.info('[DirCache] 命中  $cacheKey  (${cached.length} 项)');
        final saved = _dirScrollPositions[_currentPath] ?? 0;
        final grid = _isGridMode;
        final fileIdx = saved > 0 ? saved : 0;
        final jumpIdx = grid ? fileIdx ~/ 2 : fileIdx;
        setState(() {
          _entries = cached;
          _loading = false;
          _showSkeleton = false;
          _error = null;
          // 无锚点时用 initialScrollIndex 让列表首次挂载就落在原位置；
          // 有锚点（重命名/移动）走 _restoreScrollAnchor，不在这里抢位置。
          if (anchor.isEmpty) {
            _initialScrollIndex = jumpIdx;
            _listGeneration++;
          }
        });
        if (anchor.isNotEmpty) _restoreScrollAnchor(anchor);
        _maybeRevealTarget();
        // 兜底：initialScrollIndex 万一没生效（极端边界）时仍能跳回原位；
        // 正常它已是同位置 no-op，不会产生额外闪烁。
        if (anchor.isEmpty) _restoreDirScroll();
        return;
      }
    }



    if (_currentPath == _topPath) {
      List<EntryInfo> entries;
      try {
        entries = _listStorageRoot();
      } catch (_) {
        entries = <EntryInfo>[];
      }
      if (!mounted || token.isCancelled) return;
      final saved = _dirScrollPositions[_currentPath] ?? 0;
      final grid = _isGridMode;
      final fileIdx = saved > 0 ? saved : 0;
      final jumpIdx = grid ? fileIdx ~/ 2 : fileIdx;
      setState(() {
        _entries = entries;
        _loading = false;
        _showSkeleton = false;
        _error = null;
        if (anchor.isEmpty) {
          _initialScrollIndex = jumpIdx;
          _listGeneration++;
        }
      });
      DirCache.instance.put(cacheKey, entries);
      if (anchor.isNotEmpty) _restoreScrollAnchor(anchor);
      _maybeRevealTarget();
      if (anchor.isEmpty) _restoreDirScroll();
      return;
    }

   if (!silent) {
  setState(() {
    _loading = true;
    _error = null;
    _bodyRevision++; // 只在真正显示 loading 时递增，缓存命中/静默刷新保持原地更新
  });
  _skeletonTimer?.cancel();
  _showSkeleton = false;
  _skeletonTimer = Timer(const Duration(milliseconds: 180), () {
    if (mounted && _loading) {
      setState(() => _showSkeleton = true);
    }
  });
} else if (_error != null) {
  setState(() => _error = null);
}

try {
  await loadDirectoryAsync(
        path: _currentPath,
        sortField: sortField,
        sortAsc: sortAsc,
        cancelToken: token,
        onUpdate: (list) {
          if (!mounted || token.isCancelled) return;
          _skeletonTimer?.cancel();
          final saved = _dirScrollPositions[_currentPath] ?? 0;
          final grid = _isGridMode;
          final fileIdx = saved > 0 ? saved : 0;
          final jumpIdx = grid ? fileIdx ~/ 2 : fileIdx;
          setState(() {
            _entries = list;
            _loading = false;
            _showSkeleton = false;
            // 无锚点时用 initialScrollIndex 在首次挂载就定位，避免一帧闪烁。
            if (anchor.isEmpty && !anchorRestored) {
              _initialScrollIndex = jumpIdx;
              _listGeneration++;
            }
          });
          if (anchor.isNotEmpty && !anchorRestored) {
            _restoreScrollAnchor(anchor);
            anchorRestored = true;
          } else if (anchor.isEmpty && !anchorRestored) {
            anchorRestored = true;
          }
          _maybeRevealTarget();
        },
        onComplete: (list) {
          if (!mounted || token.isCancelled) return;
          _skeletonTimer?.cancel();
          setState(() {
            _entries = list;
            _showSkeleton = false;
          });
          DirCache.instance.put(cacheKey, list);
          // 稳定列表已在 onUpdate 通过 initialScrollIndex 定位，这里不再跳，
          // 只刷新数据并保持原位。
          _maybeRevealTarget();
        },
      );
    } catch (e) {
      if (!mounted || token.isCancelled) return;
      _skeletonTimer?.cancel();
      setState(() {
        _error = e.toString();
        _loading = false;
        _showSkeleton = false;
      });
    }
  }

  // ==================== 滚动锚点 ====================

  /// 子页面带 revealPath 时：目录加载完成后滚动到该文件并短暂高亮。
  /// 只滚动 + 闪一下底色，不进入多选，不改变任何选中态。
  void _maybeRevealTarget() {
    if (_revealHandled) return;
    final target = widget.revealPath;
    if (target == null) {
      _revealHandled = true;
      return;
    }
    final entries = _entries;
    if (entries == null) return; // 等加载回调再试

    final parent = target.contains('/')
        ? target.substring(0, target.lastIndexOf('/'))
        : target;
    if (_currentPath != parent) {
      _revealHandled = true;
      return;
    }
    _revealHandled = true;

    final grid = !_searchActive && ref.read(browserGridModeProvider);
    int? index;
    if (grid) {
      final filtered = _filterEntries(entries);
      final i = filtered.indexWhere((e) => e.entity.path == target);
      if (i >= 0) index = i ~/ 2; // 网格两列一行
    } else {
      final i = _buildDisplayItems().indexWhere((it) => it.key == target);
      if (i >= 0) index = i;
    }
    if (index == null) return;
    final jumpIndex = index;

    _flashPath = target;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _jumpToReveal(jumpIndex);
    });
    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(milliseconds: 1600), () {
      if (!mounted) return;
      setState(() => _flashPath = null);
    });
  }

  /// 列表可能还没挂载，最多重试 3 帧再放弃定位。
  void _jumpToReveal(int index, [int attempt = 0]) {
    if (!mounted) return;
    if (_itemScrollController.isAttached) {
      _itemScrollController.jumpTo(index: index);
      return;
    }
    if (attempt >= 3) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _jumpToReveal(index, attempt + 1);
    });
  }

  bool get _isGridMode =>
      !_searchActive && ref.read(browserGridModeProvider);

  List<String> _snapshotVisiblePaths() {
    final positions = _positionsListener.itemPositions.value;
    if (positions.isEmpty) return const <String>[];
    // 列表实际渲染的是 _visibleItems（过滤模式下的子集），
    // 用全量列表按下标取 key 会错位。
    final allItems = _visibleItems ?? _cachedDisplayItems;
    if (allItems == null || allItems.isEmpty) return const <String>[];

    final sorted = positions.toList()
      ..sort((a, b) => a.index.compareTo(b.index));

    final grid = _isGridMode;
    final out = <String>[];
    for (final p in sorted) {
      if (grid) {
        final i1 = p.index * 2;
        final i2 = i1 + 1;
        if (i1 >= 0 && i1 < allItems.length) out.add(allItems[i1].key);
        if (i2 >= 0 && i2 < allItems.length) out.add(allItems[i2].key);
      } else {
        if (p.index < 0 || p.index >= allItems.length) continue;
        out.add(allItems[p.index].key);
      }
    }
    return out;
  }

  void _restoreScrollAnchor(List<String> anchorKeys) {
    if (anchorKeys.isEmpty) return;
    final allItems = _visibleItems ?? _cachedDisplayItems;
    if (allItems == null || allItems.isEmpty) return;

    var targetIdx = -1;
    for (final k in anchorKeys) {
      final idx = allItems.indexWhere((it) => it.key == k);
      if (idx >= 0) {
        targetIdx = idx;
        break;
      }
    }
    if (targetIdx < 0) targetIdx = 0;

    final grid = _isGridMode;
    final jumpIdx = grid ? targetIdx ~/ 2 : targetIdx;

    _restoringScroll = true;
    _jumpToIndexWhenAttached(jumpIdx);
  }

  void _recordCurrentScroll() {
    if (_restoringScroll) return;
    final positions = _positionsListener.itemPositions.value;
    if (positions.isEmpty) return;
    var minIdx = 1 << 30;
    for (final p in positions) {
      if (p.index < minIdx) minIdx = p.index;
    }
    if (minIdx < (1 << 30)) {
      final grid = _isGridMode;
      final fileIdx = grid ? minIdx * 2 : minIdx;
      _dirScrollPositions[_currentPath] = fileIdx;
    }
  }

  /// 跳到指定下标；控制器还没挂上时每帧重试，直到挂上为止。
  /// 重载目录时列表会先卸挂载再重挂，单帧 postFrameCallback 常常早于挂载，
  /// 不加重试就会静默跳过、列表停在顶部。
  void _jumpToIndexWhenAttached(int index, [int attempt = 0]) {
    if (!mounted) return;
    if (_itemScrollController.isAttached) {
      _itemScrollController.jumpTo(index: index);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _restoringScroll = false;
      });
      return;
    }
    if (attempt >= 20) {
      _restoringScroll = false;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _jumpToIndexWhenAttached(index, attempt + 1);
    });
  }

  void _restoreDirScroll() {
    final saved = _dirScrollPositions[_currentPath];
    final fileIdx = (saved != null && saved > 0) ? saved : 0;
    final grid = _isGridMode;
    final jumpIdx = grid ? fileIdx ~/ 2 : fileIdx;
    _restoringScroll = true;
    _jumpToIndexWhenAttached(jumpIdx);
  }

  void _navigateTo(String path) {
    while (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
       if (path == _currentPath) return;
   _recordCurrentScroll();
_clearSelection();
_searchCtrl.clear();
_advancedOverlay?.remove();
_advancedOverlay = null;
_advancedOpen = false;
_clearConditions();
_filterTaskId++;
_searchTaskId++;
_clearZipExpansion();
    // 子页面只在本页导航，不覆盖主页面的「上次浏览目录」。
    if (widget.initialPath == null) {
      ref.read(lastPathProvider.notifier).update(path);
    }
    // 先算好再改 _currentPath——下面要用改动前的目录判断"进去还是出来"。
    final nextVisited = _visitedPathFor(from: _currentPath, to: path);
    setState(() {
      _currentPath = path;
      _searchResults = [];
      _searching = false;
      _searchActive = false;
      _lastVisitedPath = nextVisited;
    });
    _startVisitedFade();
    _load();
  }

  /// 从 [from] 走到 [to] 时，回到 [to] 之后该高亮哪一项。
  ///
  /// 三种走向：
  ///   · 进子目录（to 在 from 下面）→ 记住 to 本身。
  ///     退回 from 时 from 的列表里有 to，正好高亮刚进去过的那个文件夹。
  ///   · 回上级（from 在 to 下面）→ 记住 from 到 to 这条路上的第一级。
  ///     跨好几级直接回（面包屑点顶层）时也能标到正确的那一级，
  ///     而不是标一个当前列表里根本不存在的深层路径。
  ///   · 跳到不相干的目录（收藏、跳转、换存储）→ 清掉，不该继承旧高亮。
  String? _visitedPathFor({required String from, required String to}) {
    if (to.startsWith('$from/')) return to;
    if (from.startsWith('$to/')) {
      final rel = from.substring(to.length + 1);
      final slash = rel.indexOf('/');
      final first = slash < 0 ? rel : rel.substring(0, slash);
      if (first.isEmpty) return null;
      return '$to/$first';
    }
    return null;
  }

  /// 打开文件 / 进入目录后记一笔：回到列表时高亮这一项。
  void _markVisited(String path) {
    if (path.isEmpty) return;
    if (!mounted) return;
    setState(() => _lastVisitedPath = path);
    _startVisitedFade();
  }

  /// 让「刚才去过」高亮从满色渐隐到透明（~700ms），结束自动清除。
  /// 重复触发（连续进出目录）会重头再渐隐一次，不会叠加或卡住。
  void _startVisitedFade() {
    _visitedFadeCtrl
      ..stop()
      ..reset()
      ..forward();
  }

  /// 子页面和主页面共用同一套导航规则：能上跳就上跳，到存储根为止。
  bool get _canGoUp => _currentPath != _topPath;

  /// 返回键是否已经到达本页边界（存储根）：此时返回会关闭本页。
  bool get _atPageBoundary => _currentPath == _topPath;

  void _goUp() {
    if (!_canGoUp) return;
    final parent = Directory(_currentPath).parent.path;
    if (!parent.startsWith(_topPath)) return;
    if (parent == '/storage/emulated') {
      _navigateTo(_topPath);
      return;
    }
    _navigateTo(parent);
  }

  List<EntryInfo> _listStorageRoot() {
    final out = <EntryInfo>[];
    final seen = <String>{};

    void addDir(String path, String name) {
      if (seen.contains(path)) return;
      final dir = Directory(path);
      if (!dir.existsSync()) return;
      seen.add(path);
      out.add(EntryInfo(entity: dir, name: name, isDir: true));
    }

    addDir('/storage/emulated/0', '内部存储');

    try {
      final raw =
          Directory('/storage/emulated').listSync(followLinks: false);
      for (final e in raw) {
        if (e is! Directory) continue;
        final name = e.path.split('/').last;
        if (name == '0' || name == 'self') continue;
        if (!RegExp(r'^\d+$').hasMatch(name)) continue;
        addDir(e.path, '双开($name)');
      }
    } catch (_) {}

    final uuidPattern = RegExp(r'([0-9A-Fa-f]{4}-[0-9A-Fa-f]{4})');
    const sources = <String>[
      '/proc/mounts', '/proc/self/mountinfo', '/proc/self/mounts',
      '/etc/mtab',
    ];
    final uuids = <String>{};
    for (final src in sources) {
      try {
        final content = File(src).readAsStringSync();
        for (final m in uuidPattern.allMatches(content)) {
          uuids.add(m.group(1)!);
        }
        if (uuids.isNotEmpty) break;
      } catch (_) {}
    }
    for (final uuid in uuids) {
      if (Directory('/storage/$uuid').existsSync()) {
        addDir('/storage/$uuid', '外部存储($uuid)');
      } else if (Directory('/mnt/media_rw/$uuid').existsSync()) {
        addDir('/mnt/media_rw/$uuid', '外部存储($uuid)');
      }
    }

    return out;
  }

  // ==================== 选中 ====================
// ==================== 高级搜索条件 · 逻辑 ====================

int get _activeConditionCount =>
    _searchConditions.where((c) => c.text.trim().isNotEmpty).length +
    (_isSizeTimeFilterActive() ? 1 : 0);

/// 有没有非空条件。
bool get _hasActiveConditions => _activeConditionCount > 0;

/// 上一次点"搜索"时的关键词。关键词变了就清空高级条件。
String _lastSearchedQuery = '';




void _clearConditions() {
  for (final c in _searchConditions) {
    c.dispose();
  }
  _searchConditions.clear();
}

/// 清空全部：文字条件 + 大小/时间筛选。
void _clearAllFilters() {
  _clearConditions();
  _filterSizeMinMb = null;
  _filterSizeMaxMb = null;
  _filterTimeFrom = null;
  _filterTimeTo = null;
}

/// 大小 / 时间筛选是否已设置（用于放行空文字搜索）。
bool _isSizeTimeFilterActive() =>
    _filterSizeMinMb != null ||
    _filterSizeMaxMb != null ||
    _filterTimeFrom != null ||
    _filterTimeTo != null;

/// 按大小（MB）/ 修改时间（精确到秒）过滤。
/// 大小筛选下，文件夹（size 为 null）一律不命中；时间对文件与文件夹都生效。
bool _passesSizeTimeFilter(int? size, DateTime? modified) {
  if (_filterSizeMinMb != null &&
      (size == null || size < _filterSizeMinMb! * 1024 * 1024)) {
    return false;
  }
  if (_filterSizeMaxMb != null &&
      (size == null || size > _filterSizeMaxMb! * 1024 * 1024)) {
    return false;
  }
  if (_filterTimeFrom != null &&
      (modified == null || modified.isBefore(_filterTimeFrom!))) {
    return false;
  }
  if (_filterTimeTo != null &&
      (modified == null || modified.isAfter(_filterTimeTo!))) {
    return false;
  }
  return true;
}

/// 核心匹配函数。所有搜索/过滤入口都用它。
bool _matchNameForSearch(String name) {
  final lower = name.toLowerCase();
  final mainText = _searchCtrl.text.trim().toLowerCase();
  final orTexts = <String>[];
  if (mainText.isNotEmpty) orTexts.add(mainText);

  final andTexts = <String>[];
  final notTexts = <String>[];

  for (final c in _searchConditions) {
    final t = c.text.trim().toLowerCase();
    if (t.isEmpty) continue;
    switch (c.operator) {
      case _SearchOperator.or:
        orTexts.add(t);
      case _SearchOperator.and:
        andTexts.add(t);
      case _SearchOperator.not:
        notTexts.add(t);
    }
  }

  if (orTexts.isEmpty && andTexts.isEmpty && notTexts.isEmpty) {
    return true;
  }
  if (orTexts.isNotEmpty && !orTexts.any(lower.contains)) return false;
  for (final t in andTexts) {
    if (!lower.contains(t)) return false;
  }
  for (final t in notTexts) {
    if (lower.contains(t)) return false;
  }
  return true;
}

// ==================== 高级搜索条件 · Overlay ====================

void _toggleAdvanced() {
  FocusManager.instance.primaryFocus?.unfocus();
  if (_advancedOpen) {
    _closeAdvanced();
  } else {
    setState(() => _advancedOpen = true);
    _showAdvancedOverlay();
  }
}

void _closeAdvanced() {
  _advancedOverlay?.remove();
  _advancedOverlay = null;
  if (mounted && _advancedOpen) {
    setState(() => _advancedOpen = false);
  }
}

void _showAdvancedOverlay() {
  _advancedOverlay?.remove();
  _advancedOverlay = null;

  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted) return;
    final box =
        _searchBarBoxKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final pos = box.localToGlobal(Offset.zero);
    final size = box.size;
    final screenWidth = MediaQuery.of(context).size.width;

    _advancedOverlay = OverlayEntry(
      builder: (ctx) => _AdvancedOverlayContent(
        panelTop: pos.dy + size.height + 2,
        panelLeft: 8,
        panelWidth: screenWidth - 16,
        conditions: _searchConditions,
        filterSizeMinMb: _filterSizeMinMb,
        filterSizeMaxMb: _filterSizeMaxMb,
        filterTimeFrom: _filterTimeFrom,
        filterTimeTo: _filterTimeTo,
        onChanged: () {
          if (!mounted) return;
          setState(() {});
          _advancedOverlay?.markNeedsBuild();
        },
        onClearAll: () {
          _clearAllFilters();
          setState(() {});
          _advancedOverlay?.markNeedsBuild();
        },
        onClearConditions: () {
          _clearConditions();
          setState(() {});
          _advancedOverlay?.markNeedsBuild();
        },
        onSizeChanged: (min, max) {
          _filterSizeMinMb = min;
          _filterSizeMaxMb = max;
          _advancedOverlay?.markNeedsBuild();
        },
        onTimeChanged: (from, to) {
          _filterTimeFrom = from;
          _filterTimeTo = to;
          _advancedOverlay?.markNeedsBuild();
        },
        onSubmit: () {
          _closeAdvanced();
          _doSearch();
        },
        onClose: _closeAdvanced,
      ),
    );
    Overlay.of(context).insert(_advancedOverlay!);
  });
}

// ==================== 高级搜索条件 · UI ====================






Widget _buildAdvancedToggle() {
  final cs = Theme.of(context).colorScheme;
  // 只有两态：展开 / 收起。有没有条件靠颜色和 tooltip 表达。
  final icon = _advancedOpen
      ? Icons.keyboard_arrow_up
      : Icons.keyboard_arrow_down;
  final color =
      _hasActiveConditions ? cs.primary : cs.onSurfaceVariant;
  final tip = _hasActiveConditions
      ? '高级搜索（有 $_activeConditionCount 条条件）'
      : '高级搜索';
  return SizedBox(
    width: 40,
    height: 44,
    child: InkResponse(
      onTap: _toggleAdvanced,
      radius: 20,
      child: Tooltip(
        message: tip,
        child: GradientIcon(icon, size: 22, fallbackColor: color),
      ),
    ),
  );
}
  void _clearSelection() {
    // 底栏「⋯」的锚点随多选态一起消失，菜单必须跟着关，不能留在原位。
    _closeFloatingMenu();
    setState(() {
      _selectionMode = false;
      _selectedPaths.clear();
      _anchorPath = null;
    });
  }

  /// 把当前唯一选中的条目压入一个新页面，本页现场（搜索/滚动/多选）保持不变。
  /// 文件夹以自身为起点；文件以所在目录为起点，并定位到该文件。
  Future<void> _openSelectedInNewPage() async {
    if (_selectedPaths.length != 1) return;
    final path = _selectedPaths.first;
    final type = FileSystemEntity.typeSync(path);
    final isDir = type == FileSystemEntityType.directory;
    if (!isDir && type != FileSystemEntityType.file) {
      _toast('无法打开这个条目');
      return;
    }
    final targetDir =
        isDir || !path.contains('/') ? path : path.substring(0, path.lastIndexOf('/'));
    _clearSelection();
    await _pushChildPage(targetDir, revealPath: isDir ? null : path);
  }

  /// 搜索态点面包屑：压子页并把搜索现场留给当前页；普通浏览仍同页跳转。
  void _openBreadcrumb(String path) {
    if (_searchActive) {
      _pushChildPage(path);
    } else {
      _navigateTo(path);
    }
  }

  /// 压入以 [path] 为起点的子页面；返回后校正本页可能已失效的状态。
  Future<void> _pushChildPage(String path, {String? revealPath}) async {
    await Navigator.of(context).push(
      _noAnimRoute(
        FileBrowserScreen(initialPath: path, revealPath: revealPath),
      ),
    );
    if (!mounted) return;
    // 子页面里可能删/移过文件：剔除失效的搜索结果，并让当前目录重新取一次缓存。
    setState(_pruneSearchResults);
    if (!_searchActive) _load();
  }

  void _pruneSearchResults() {
    if (_searchResults.isEmpty) return;
    final still = <_SearchHit>[];
    var removed = 0;
    for (final hit in _searchResults) {
      if (FileSystemEntity.typeSync(hit.path) !=
          FileSystemEntityType.notFound) {
        still.add(hit);
      } else {
        removed++;
        _selectedPaths.remove(hit.path);
      }
    }
    if (removed == 0) return;
    _searchResults = still;
    if (_selectedPaths.isEmpty) {
      _selectionMode = false;
      _anchorPath = null;
    }
  }

  void _toggleSelectionByKey(String key) {
    setState(() {
      _selectionMode = true;
      if (_selectedPaths.contains(key)) {
        _selectedPaths.remove(key);
        if (_selectedPaths.isEmpty) {
          _selectionMode = false;
          _anchorPath = null;
        }
      } else {
        _selectedPaths.add(key);
        _anchorPath = key;
      }
    });
  }

  void _onLongPressItem(_DisplayItem item) {
    if (!_selectionMode) {
      setState(() {
        _selectionMode = true;
        _selectedPaths.add(item.key);
        _anchorPath = item.key;
      });
      return;
    }
    if (_anchorPath != null) {
      // 用屏幕上实际显示的列表，避免过滤模式下把隐藏项一起选上。
      final all =
          _visibleItems ?? _cachedDisplayItems ?? const <_DisplayItem>[];
      final from = all.indexWhere((it) => it.key == _anchorPath);
      final to = all.indexWhere((it) => it.key == item.key);
      if (from >= 0 && to >= 0) {
        final lo = from < to ? from : to;
        final hi = from < to ? to : from;
        setState(() {
          for (var i = lo; i <= hi; i++) {
            _selectedPaths.add(all[i].key);
          }
          _anchorPath = item.key;
        });
        return;
      }
    }
    setState(() {
      _selectedPaths.add(item.key);
      _anchorPath = item.key;
    });
  }

  void _toggleSelectAll() {
    final all =
        _visibleItems ?? _cachedDisplayItems ?? const <_DisplayItem>[];
    final selectable = all
        .where((it) => !it.key.startsWith('__loading__') &&
            !it.key.startsWith('__error__'))
        .map((it) => it.key)
        .toList();
    final allSelected = selectable.isNotEmpty &&
        selectable.every((k) => _selectedPaths.contains(k));
    setState(() {
      if (allSelected) {
        _selectedPaths.clear();
        _selectionMode = false;
        _anchorPath = null;
      } else {
        _selectionMode = true;
        _selectedPaths.addAll(selectable);
      }
    });
  }

  /// 反选：对当前列表里所有可选条目取反。
  /// 对任意选中数（1..n）都成立，用来保证多选底栏「⋯」里永远有可点的项。
  void _invertSelection() {
    final all =
        _visibleItems ?? _cachedDisplayItems ?? const <_DisplayItem>[];
    final selectable = all
        .where((it) => !it.key.startsWith('__loading__') &&
            !it.key.startsWith('__error__'))
        .map((it) => it.key);
    final next = <String>{
      for (final k in selectable)
        if (!_selectedPaths.contains(k)) k,
    };
    if (next.isEmpty && _selectedPaths.isEmpty) return;
    setState(() {
      _selectedPaths
        ..clear()
        ..addAll(next);
      _selectionMode = next.isNotEmpty;
      _anchorPath = next.isEmpty ? null : next.first;
    });
  }

  List<String> get _currentDisplayedPaths {
    if (_searchActive) {
      return _searchResults.map((h) => h.path).toList();
    }
    return (_entries ?? const <EntryInfo>[])
        .map((e) => e.entity.path)
        .toList();
  }

  // ==================== zip 展开 / 收起 ====================

Archive _fixZipNames(Archive archive) {
  var anyChanged = false;
  final newArchive = Archive();
  for (final f in archive.files) {
    final fixed = _fixZipName(f.name);
    if (fixed != f.name) anyChanged = true;
    newArchive.addFile(ArchiveFile(fixed, f.size, f.content));
  }
  return anyChanged ? newArchive : archive;
}

String _fixZipName(String name) {
  if (name.isEmpty) return name;

  var hasHigh = false;
  for (final r in name.runes) {
    if (r > 0xFF) return name;
    if (r >= 0x80) hasHigh = true;
  }
  if (!hasHigh) return name;

  final bytes = Uint8List.fromList(name.codeUnits);

  try {
    final utf8Name = utf8.decode(bytes);
    if (utf8Name != name) return utf8Name;
  } catch (_) {}

  try {
    final gbkName = gbk.decode(bytes);
    if (gbkName != name) return gbkName;
  } catch (_) {}

  return name;
}

  Future<bool> _isEncryptedZip(String path) async {
    try {
      final raf = await File(path).open();
      try {
        final header = await raf.read(8);
        if (header.length < 8) return false;
        if (header[0] != 0x50 ||
            header[1] != 0x4B ||
            header[2] != 0x03 ||
            header[3] != 0x04) {
          return false;
        }
        return (header[6] & 0x01) != 0;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }

Archive _decodeArchiveBytes(String name, Uint8List bytes, {String? password}) {
  final lower = name.toLowerCase();
 if (lower.endsWith('.zip')) {
  final archive = (password == null || password.isEmpty)
      ? ZipDecoder().decodeBytes(bytes)
      : ZipDecoder().decodeBytes(bytes, password: password);
  return _fixZipNames(archive);
}
  if (lower.endsWith('.tar.gz') || lower.endsWith('.tgz')) {
  final gunzipped = GZipDecoder().decodeBytes(bytes);
  return _parseTarWithGbk(Uint8List.fromList(gunzipped));
}
  if (lower.endsWith('.tar')) {
    return _parseTarWithGbk(bytes);
  }
  throw Exception('不支持的压缩格式：$name');
}

Archive _parseTarWithGbk(Uint8List bytes) {
  final archive = Archive();
  var offset = 0;
  Uint8List? pendingLongNameBytes;

  String decodeName(List<int> raw) {
    var end = raw.length;
    while (end > 0 && raw[end - 1] == 0) {
      end--;
    }
    if (end <= 0) return '';
    final slice = raw.sublist(0, end);
    try {
      return utf8.decode(slice);
    } catch (_) {}
    try {
      return gbk.decode(slice);
    } catch (_) {}
    return String.fromCharCodes(slice);
  }

  int readOctal(Uint8List buf, int start, int len) {
    var result = 0;
    for (var i = start; i < start + len; i++) {
      final b = buf[i];
      if (b == 0 || b == 0x20) break;
      if (b < 0x30 || b > 0x37) break;
      result = result * 8 + (b - 0x30);
    }
    return result;
  }

  int alignTo512(int n) => ((n + 511) ~/ 512) * 512;

  while (offset + 512 <= bytes.length) {
    final header = Uint8List.sublistView(bytes, offset, offset + 512);

    var allZero = true;
    for (var i = 0; i < 512; i++) {
      if (header[i] != 0) {
        allZero = false;
        break;
      }
    }
    if (allZero) break;

    var name = decodeName(header.sublist(0, 100));
    final size = readOctal(header, 124, 12);
    final type = header[156];
    final prefix = decodeName(header.sublist(345, 500));
    if (prefix.isNotEmpty) {
      name = '$prefix/$name';
    }

    offset += 512;
    if (offset + size > bytes.length) break;

    if (type == 0x4C) {
      pendingLongNameBytes =
          Uint8List.fromList(bytes.sublist(offset, offset + size));
      offset += alignTo512(size);
      continue;
    }

    if (type == 0x78 || type == 0x67) {
      offset += alignTo512(size);
      continue;
    }

    if (type == 0x00 || type == 0x30 || type == 0x35) {
      if (pendingLongNameBytes != null) {
        name = decodeName(pendingLongNameBytes);
        pendingLongNameBytes = null;
      }

      final isDir = type == 0x35;
      final content = isDir
          ? Uint8List(0)
          : Uint8List.fromList(bytes.sublist(offset, offset + size));

      final cleanName = isDir && name.endsWith('/')
          ? name.substring(0, name.length - 1)
          : name;

      if (cleanName.isNotEmpty) {
        archive.addFile(ArchiveFile(cleanName, content.length, content));
      }
      offset += alignTo512(size);
    } else {
      offset += alignTo512(size);
    }
  }

  return archive;
}

int _le32(Uint8List b, int o) =>
    (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)) &
        0xFFFFFFFF;

/// 扫描 zip 本地文件头，累加解压后总字节数，用于解码前的大小上限判断。
/// 遇到流式写入（数据描述符）导致本地头大小为 0 时返回 null，表示无法预估。
int? _zipUncompressedTotal(Uint8List bytes) {
  var offset = 0;
  var total = 0;
  while (offset + 30 <= bytes.length) {
    if (bytes[offset] != 0x50 ||
        bytes[offset + 1] != 0x4B ||
        bytes[offset + 2] != 0x03 ||
        bytes[offset + 3] != 0x04) {
      break;
    }
    final flags = bytes[offset + 6] | (bytes[offset + 7] << 8);
    final comp = _le32(bytes, offset + 18);
    final uncomp = _le32(bytes, offset + 22);
    final nameLen = bytes[offset + 26] | (bytes[offset + 27] << 8);
    final extraLen = bytes[offset + 28] | (bytes[offset + 29] << 8);
    if (uncomp == 0 && (flags & 0x08) != 0) return null;
    total += uncomp;
    final next = offset + 30 + nameLen + extraLen + comp;
    if (next <= offset) break; // 防御：大小为 0 时避免死循环
    offset = next;
  }
  return total;
}


Future<void> _expandZip(String zipDiskPath) async {
  if (_expandedZipKeys.contains(zipDiskPath)) return;
  if (_loadingZipKeys.contains(zipDiskPath)) return;

  try {
    final length = await File(zipDiskPath).length();
    if (length > _maxZipBytes) {
      if (!mounted) return;
      await openFileWithSystemPicker(zipDiskPath, context);
      if (mounted) {
        _toast('压缩包过大（${_formatSize(length)}），已交给其他 App 打开');
      }
      return;
    }
  } catch (_) {}

  setState(() {
    _loadingZipKeys.add(zipDiskPath);
    _zipErrors.remove(zipDiskPath);
    _expandedZipKeys.add(zipDiskPath);
  });

  try {
  final bytes = await File(zipDiskPath).readAsBytes();
  final lower = zipDiskPath.toLowerCase();

  final Archive archive;
  if (lower.endsWith('.zip') && await _isEncryptedZip(zipDiskPath)) {
    // 加密 ZIP：能预估解压体积时先判断上限，超限交给系统打开；
    // 否则弹密码框解密（输错可重试，取消则退回未展开）。
    final uncomp = _zipUncompressedTotal(bytes);
    if (uncomp != null && uncomp > _maxTotalDecodedBytes) {
      if (!mounted) return;
      await openFileWithSystemPicker(zipDiskPath, context);
      if (mounted) {
        _toast('压缩包解压后过大（${_formatSize(uncomp)}），已交给其他 App 打开');
      }
      return;
    }
    final decrypted = await _tryDecodeEncryptedZip(zipDiskPath, bytes);
    if (decrypted == null) {
      if (!mounted) return;
      setState(() {
        _loadingZipKeys.remove(zipDiskPath);
        _expandedZipKeys.remove(zipDiskPath);
      });
      return;
    }
    archive = decrypted;
  } else {
    // 原有未加密路径
    if (lower.endsWith('.zip')) {
      final uncomp = _zipUncompressedTotal(bytes);
      if (uncomp != null && uncomp > _maxTotalDecodedBytes) {
        if (!mounted) return;
        await openFileWithSystemPicker(zipDiskPath, context);
        if (mounted) {
          _toast('压缩包解压后过大（${_formatSize(uncomp)}），已交给其他 App 打开');
        }
        return;
      }
    }
    archive = _decodeArchiveBytes(zipDiskPath, bytes);
  }

  if (!mounted) return;

  // 重置本次展开的累计解压计数，并把顶层解压后的内容算进去。
  _expandedDecodedBytes = 0;
  final topDecodedSize =
      archive.files.fold<int>(0, (s, f) => s + f.size);
  _expandedDecodedBytes = topDecodedSize;

  _zipArchives[zipDiskPath] = archive;
  _collectNestedZips(zipDiskPath, archive, '', '');


		

    if (!mounted) return;
    setState(() {
      _loadingZipKeys.remove(zipDiskPath);
    });
  } catch (e) {
    if (!mounted) return;

    setState(() {
      _loadingZipKeys.remove(zipDiskPath);
      _expandedZipKeys.remove(zipDiskPath);
    });

    await openFileWithSystemPicker(zipDiskPath, context);
    if (mounted) {
      _toast('此压缩包无法解压（可能已加密），已交给其他 App 打开');
    }
  }
}

  /// 弹密码框。返回 null 表示用户取消。
  Future<String?> _askZipPassword(String zipPath) async {
    if (!mounted) return null;
    final name = zipPath.split('/').last;
    final ctrl = TextEditingController();
    var obscure = true;
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (c) => StatefulBuilder(
        builder: (c, setS) => AlertDialog(
          insetPadding: _dlgInset,
          title: const Text('压缩包已加密'),
          content: SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('「$name」需要密码才能解压。',
                    style: const TextStyle(fontSize: 13)),
                const SizedBox(height: 12),
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  obscureText: obscure,
                  decoration: InputDecoration(
                    labelText: '密码',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    suffixIcon: IconButton(
                      icon: Icon(obscure
                          ? Icons.visibility_off
                          : Icons.visibility),
                      onPressed: () => setS(() => obscure = !obscure),
                    ),
                  ),
                  onSubmitted: (v) => Navigator.pop(c, v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, ctrl.text),
              child: const Text('解压'),
            ),
          ],
        ),
      ),
    );
    ctrl.dispose();
    if (result == null || result.isEmpty) return null;
    return result;
  }

  /// 弹密码 → 解密 → 失败重试，直到成功或用户取消。
  /// 返回 null 表示取消；返回 Archive 表示解密成功。
  Future<Archive?> _tryDecodeEncryptedZip(
    String zipPath,
    Uint8List bytes,
  ) async {
    var pwd = await _askZipPassword(zipPath);
    while (pwd != null) {
      try {
        final archive = _decodeArchiveBytes(zipPath, bytes, password: pwd);
        // 触发一次解密以校验密码（AES 在读取内容时才校验 MAC，
        // 部分版本 decodeBytes 不会立即抛错）。
        for (final f in archive.files) {
          if (f.isFile) {
            final _ = f.content;
            break;
          }
        }
        return archive;
      } catch (e) {
        if (!mounted) return null;
        final action = await showDialog<String>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('解压失败'),
            content: Text('密码可能不正确，或该压缩包使用了暂不支持的加密方式。\n$e'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(c, 'retry'),
                child: const Text('重试'),
              ),
            ],
          ),
        );
        if (action != 'retry' || !mounted) return null;
        pwd = await _askZipPassword(zipPath);
      }
    }
    return null;
  }

  void _collectNestedZips(
  String ownerZipDiskPath,
  Archive archive,
  String at,
  String innerPrefix,
) {
  if (_expandedDecodedBytes >= _maxTotalDecodedBytes) return;
  final children = _directZipChildren(archive, at);
    for (final c in children) {
      if (c.isDir) {
        _collectNestedZips(ownerZipDiskPath, archive, c.fullPath, innerPrefix);
      } else if (c.isZip) {
  // 累计已超上限，不再展开更深的嵌套。
  if (_expandedDecodedBytes >= _maxTotalDecodedBytes) continue;

  final innerFull = innerPrefix.isEmpty
      ? c.fullPath
      : '$innerPrefix>${c.fullPath}';
  final nestedKey = _makeZipInnerKey(ownerZipDiskPath, innerFull);

  try {
    final f = archive.findFile(c.fullPath);
    if (f == null) continue;
    final content = f.content;
    final Uint8List bytes;
    if (content is Uint8List) {
      bytes = content;
    } else if (content is List<int>) {
      bytes = Uint8List.fromList(content);
    } else {
      continue;
    }
    final inner = _decodeArchiveBytes(c.name, bytes);

    // 把这一层的解压内容累计进去。
    final innerDecodedSize =
        inner.files.fold<int>(0, (s, file) => s + file.size);
    _expandedDecodedBytes += innerDecodedSize;
    if (_expandedDecodedBytes > _maxTotalDecodedBytes) {
      // 超限：不再记录这一层，也不再往下钻。
      continue;
    }

    _zipArchives[nestedKey] = inner;
    _expandedZipKeys.add(nestedKey);
    _collectNestedZips(ownerZipDiskPath, inner, '', innerFull);
  } catch (_) {
    // 解不开（大概率是嵌套加密 ZIP）：记一笔，列表里打 🔒。
    _encryptedNestedZipKeys.add(nestedKey);
  }
}
    }
  }

  void _collapseZip(String zipDiskPath) {
    setState(() {
      _expandedZipKeys.remove(zipDiskPath);
      _expandedZipKeys.removeWhere((k) => _isZipInnerKey(k) &&
          _zipPathFromInnerKey(k) == zipDiskPath);
      _zipArchives.remove(zipDiskPath);
      _zipArchives.removeWhere((k, _) => _isZipInnerKey(k) &&
          _zipPathFromInnerKey(k) == zipDiskPath);
      _zipErrors.remove(zipDiskPath);
      if (_stickyZipKey == zipDiskPath) {
        _stickyZipKey = null;
      }
    });
  }

  /// 收起所有已展开的压缩包，并释放其解码缓存（_zipArchives 等），
  /// 避免导航/返回/退出搜索后残留占用内存。
  void _clearZipExpansion() {
    _expandedZipKeys.clear();
    _zipArchives.clear();
    _zipErrors.clear();
    _loadingZipKeys.clear();
    _encryptedNestedZipKeys.clear();
    _stickyZipKey = null;
  }

  Future<void> _toggleZipExpand(_DisplayItem zipItem) async {
    if (zipItem.isZipInner) {
      if (_encryptedNestedZipKeys.contains(zipItem.key)) {
        _toast('嵌套在压缩包里的加密 ZIP 暂不支持，请先解压到本地再打开');
        return;
      }
      setState(() {
        _expandedZipKeys.remove(zipItem.key);
        _expandedZipKeys.removeWhere((k) => k.startsWith(zipItem.key));
      });
      return;
    }
    if (_expandedZipKeys.contains(zipItem.key)) {
      _collapseZip(zipItem.key);
    } else {
      await _expandZip(zipItem.key);
    }
  }

  // ignore: unused_element
  void _onStickyZipTap(String zipDiskPath) {
    _collapseZip(zipDiskPath);
  }

  // ==================== 打开 / 查看 ====================

  Future<void> _handleTapItem(_DisplayItem item) async {
    if (item.key.startsWith('__loading__') ||
        item.key.startsWith('__error__')) {
      return;
    }

    if (item.isZip) {
      await _toggleZipExpand(item);
      return;
    }

    if (item.isZipInner && item.isDir) {
      return;
    }

    if (item.isZipInner) {
      await _openZipInnerFile(item);
      return;
    }

    if (item.isDir) {
      final p = item.diskPath;
      if (p != null) _navigateTo(p);
      return;
    }

    final p = item.diskPath;
    if (p != null) {
      await _openFile(p, item.displayName, item.size);
    }
  }

  Future<void> _openZipInnerFile(_DisplayItem item) async {
    final ext = _extOf(item.displayName);
    final isText = _textExts.contains(ext);

    final bytes = _readZipInnerBytes(item);
    if (bytes == null) {
      _toast('读取失败');
      return;
    }

    if (isText) {
      final tmp = await _writeTempFile(bytes, item.displayName);
      if (tmp == null) {
        _toast('无法创建临时文件');
        return;
      }
      final mode = ref.read(fileOpenModeProvider);
      switch (mode) {
        case FileOpenMode.reader:
          await _openInReader(tmp, item.displayName);
        case FileOpenMode.editor:
        // 行编辑器已下线，旧配置一律走 re_editor 全文编辑器。
        // 枚举值故意保留：老用户 SharedPreferences 里存的是 "lineEditor"，
        // 删掉会让 decode 回落到 defaultValue，反而不好控制。
        case FileOpenMode.lineEditor:
          await _openInEditor(tmp, item.displayName);
        case FileOpenMode.ask:
          final picked = await _askOpenMode(item.displayName);
          if (picked == null) return;
          switch (picked) {
            case FileOpenMode.reader:
              await _openInReader(tmp, item.displayName);
            case FileOpenMode.editor:
            case FileOpenMode.lineEditor:
              await _openInEditor(tmp, item.displayName);
            case FileOpenMode.ask:
              break;
          }
      }
    } else {
      final tmp = await _writeTempFile(bytes, item.displayName);
      if (tmp == null) {
        _toast('无法创建临时文件');
        return;
      }
      if (!mounted) return;
      await showOpenOrShareSheet(context, tmp, item.displayName);
    }
  }

  Uint8List? _readZipInnerBytes(_DisplayItem item) {
    final archive = item.innerArchive;
    final path = item.innerPath;
    if (archive == null || path == null) return null;
    try {
      final f = archive.findFile(path);
      if (f == null) return null;
      final content = f.content;
      if (content is Uint8List) return content;
      if (content is List<int>) return Uint8List.fromList(content);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 把 zip 内文件写到临时目录。
///
/// 用固定文件名（不带时间戳）：同名文件自动覆盖，不积累。
/// 上次会话遗留的文件，App 启动时由 _cleanTempDirOnce 清掉。
Future<String?> _writeTempFile(Uint8List bytes, String fileName) async {
  try {
    final dir = Directory.systemTemp;
    final safe = fileName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final path = '${dir.path}/zzz_$safe';
    await File(path).writeAsBytes(bytes, flush: true);
    return path;
  } catch (_) {
    return null;
  }
}

  // ==================== 打开磁盘文件 ====================

Future<void> _openFile(
  String path,
  String name,
  int? size, {
  bool allowExpand = true,
}) async {
  final isText = _textExts.contains(_extOf(name));

  if (!isText) {
    final lowerName = name.toLowerCase();

    if (_isExpandableArchiveName(name)) {
if (!allowExpand) {
  if (!mounted) return;
  await openFileWithSystemPicker(path, context);
  return;
}
      await _expandZip(path);
      return;
    }

    if (_forceSystemPickerExts.any((ext) => lowerName.endsWith(ext))) {
      if (!mounted) return;
      await openFileWithSystemPicker(path, context);
      return;
    }

    await showOpenOrShareSheet(context, path, name);
    return;
  }

  final configured = ref.read(fileOpenModeProvider);
  FileOpenMode resolved;
  if (configured == FileOpenMode.ask) {
    final picked = await _askOpenMode(name);
    if (picked == null) return;
    resolved = picked;
  } else {
    resolved = configured;
  }

  switch (resolved) {
    case FileOpenMode.reader:
      await _openInReader(path, name);
    case FileOpenMode.editor:
    case FileOpenMode.lineEditor:
      await _openInEditor(path, name);
    case FileOpenMode.ask:
      break;
  }
}

  Future<void> _openInReader(String path, String name) async {
    final textPaths = _collectTextFilePaths();
    var index = textPaths.indexOf(path);
    if (index < 0) {
      textPaths.insert(0, path);
      index = 0;
    }

    final openedPath = path;
    final result = await Navigator.of(context).push<String>(
      PageRouteBuilder<String>(
        pageBuilder: (_, __, ___) => ReaderScreen(
          filePaths: textPaths,
          initialIndex: index,
        ),
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      ),
    );

    if (!mounted) return;

    final deleted = ref.read(readerDeletedPathsProvider);
    if (deleted.isNotEmpty) {
      ref.read(readerDeletedPathsProvider.notifier).state = const [];
      final deletedSet = deleted.toSet();
      final current = _entries ?? const <EntryInfo>[];
      final stillThere = <EntryInfo>[];
      for (final info in current) {
        if (!deletedSet.contains(info.entity.path)) {
          stillThere.add(info);
        }
      }
      if (stillThere.length != current.length) {
        setState(() => _entries = stillThere);
        DirCache.instance.applyToAll(
          _currentPath,
          (list) => list.where((e) => !deletedSet.contains(e.path)).toList(),
        );
      }
    }

    if (result != null && result != openedPath) {
      _scrollToPath(result);
    }
    // 阅读器里可能翻到别的文件：标最后读的那个，不是最初打开的那个。
    _markVisited(result ?? openedPath);
  }

  /// 只刷新单个文件的 stat（size / modified），不重新 list、不重新排序。
  ///
  /// 编辑器返回时用：文件内容改了但目录结构没变，没必要全量重载
  /// （全量重载会闪空 + 分批 stat 重排导致位置抖动）。
  Future<void> _refreshSingleEntry(String path) async {
    final entries = _entries;
    if (entries == null || entries.isEmpty) return;
    final idx = entries.indexWhere((e) => e.path == path);
    if (idx < 0) return;

    FileStat st;
    try {
      st = await FileStat.stat(path);
    } catch (_) {
      return;
    }
    if (!mounted) return;
    if (st.type == FileSystemEntityType.notFound) return;

    final old = entries[idx];
    if (old.size == st.size && old.modified == st.modified) return;

    // EntryInfo 是可变类，但这里重建一份新实例并替换列表元素，
    // 保证 build() 用最新值重建显示、且与缓存引用脱钩更稳妥。
    final updated = EntryInfo(
      entity: old.entity,
      name: old.name,
      isDir: old.isDir,
      size: st.size,
      modified: st.modified,
    );
    setState(() {
      final copy = List<EntryInfo>.from(entries);
      copy[idx] = updated;
      _entries = copy;
    });

    // 同步缓存（所有排序方式），下次再进这个目录能看到新值。
    DirCache.instance.applyToAll(_currentPath, (list) {
      final i = list.indexWhere((e) => e.path == path);
      if (i < 0) return list;
      final c = List<EntryInfo>.from(list);
      c[i] = updated;
      return c;
    });
  }

  /// path 是不是当前目录的直接子文件（zip 内临时文件不算）。
  bool _isInCurrentDir(String path) {
    if (path.isEmpty || _currentPath.isEmpty) return false;
    if (!path.startsWith('$_currentPath/')) return false;
    final rest = path.substring(_currentPath.length + 1);
    return !rest.contains('/');
  }

  Future<void> _openInEditor(String path, String name) async {
    await Navigator.of(context).push(_noAnimRoute(SingleFileEditorScreen(
      filePath: path,
      fileName: name,
    )));
    if (!mounted) return;
    // 原来这里 invalidate + _load() 会导致：
    //   1. _loading=true → 列表变空闪一下
    //   2. 完整 list + 分批 stat + 重排 → 位置要几十~几百毫秒才稳定
    // 编辑器只改了文件内容，目录结构没变，只刷新那一个文件的 stat 即可。
    if (_isInCurrentDir(path)) {
      await _refreshSingleEntry(path);
      if (!mounted) return;
      _markVisited(path);
    }
    // zip 内文件（tmp 路径不在当前目录下）：不刷新、不 invalidate、不重载，
    // 交给 _openZipInnerFile 用 item.key 高亮，避免列表闪空。
  }

  // 行编辑器（LineEditorScreen）暂时下线，入口统一走上面的 _openInEditor。
  // 页面文件本身还留着（lib/features/file_browser/presentation/line_editor_screen.dart），
  // 要恢复就把上面几处 switch 的 lineEditor 分支接回去，并把它 import 回来。

  Future<FileOpenMode?> _askOpenMode(String fileName) async {
    final remember = ValueNotifier<bool>(false);
    final picked = await showModalBottomSheet<FileOpenMode>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (c) => SafeArea(
        child: StatefulBuilder(
          builder: (c, setS) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: Row(
                  children: [
                    const Icon(Icons.open_in_new, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '用哪种方式打开「$fileName」？',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.menu_book),
                title: const Text('阅读器'),
                subtitle: const Text('分页翻页，看小说用'),
                onTap: () => Navigator.pop(c, FileOpenMode.reader),
              ),
              ListTile(
                leading: const Icon(Icons.edit_note),
                title: const Text('编辑器'),
                subtitle: const Text('全文编辑，大文件也流畅'),
                onTap: () => Navigator.pop(c, FileOpenMode.editor),
              ),
              const Divider(height: 1),
              CheckboxListTile(
                value: remember.value,
                onChanged: (v) => setS(() => remember.value = v ?? false),
                title: const Text('记住我的选择'),
                subtitle: const Text(
                  '下次不再询问，直接按选中的方式打开。\n'
                  '想改回询问：右上角设置 → 打开方式 → 每次询问',
                  style: TextStyle(fontSize: 11),
                ),
                controlAffinity: ListTileControlAffinity.leading,
              ),
              const SizedBox(height: 6),
            ],
          ),
        ),
      ),
    );

    if (picked != null && remember.value) {
      ref.read(fileOpenModeProvider.notifier).update(picked);
    }
    return picked;
  }
void _jumpToTop() {
  if (!_itemScrollController.isAttached) return;
  _itemScrollController.jumpTo(index: 0);
}
  void _scrollToPath(String path) {
    final allItems = _visibleItems ?? _cachedDisplayItems ?? const <_DisplayItem>[];
    final index = allItems.indexWhere((it) => it.key == path);
    if (index < 0) return;

    final grid = _isGridMode;
    final jumpIdx = grid ? index ~/ 2 : index;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_itemScrollController.isAttached) return;
      _itemScrollController.jumpTo(index: jumpIdx);
    });
  }

  List<String> _collectTextFilePaths() {
    if (_searchActive) {
      return [
        for (final hit in _searchResults)
          if (_textExts.contains(_extOf(hit.name))) hit.path,
      ];
    }
    final entries = _entries ?? const <EntryInfo>[];
    return [
      for (final info in entries)
        if (!info.isDir && _textExts.contains(_extOf(info.name)))
          info.entity.path,
    ];
  }

  Widget _leading({
    required bool selectionMode,
    required bool selected,
    required bool isDir,
    required String name,
    required VoidCallback onToggle,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: AppFileIcon(isDir: isDir),
    );
  }

  // ==================== 搜索 ====================

  void _onSearchChanged(String v) {
  final mode = ref.read(searchBoxModeProvider);
  if (mode == SearchBoxMode.filter) {
    _onFilterTextChanged(v);
  } else {
    setState(() {});
  }
}
// ==================== 过滤 ====================

void _onFilterTextChanged(String q) {
  _filterTaskId++;
  setState(() {
    // 过滤条件变了，屏幕上看得见的项也跟着变了。
    // 把已经不在可见列表里的选中项清掉，避免"看不见却选着"
    // 导致数量对不上、删/移动/复制时误伤隐藏文件。
    if (ref.read(searchBoxModeProvider) == SearchBoxMode.filter) {
      final visible = _computeVisibleItems(_buildDisplayItems());
      final visibleKeys = visible.map((it) => it.key).toSet();
      _selectedPaths.removeWhere((k) => !visibleKeys.contains(k));
      if (_selectedPaths.isEmpty) {
        _selectionMode = false;
        _anchorPath = null;
      }
    }
  });
}

List<_DisplayItem> _computeVisibleItems(List<_DisplayItem> all) {
  if (_searchActive) return all;
  if (ref.read(searchBoxModeProvider) != SearchBoxMode.filter) return all;

  final q = _searchCtrl.text.trim().toLowerCase();
  if (q.isEmpty) return all;

  final matchedTop = <String>{};
  for (final it in all) {
    if (it.depth != 0) continue;
    if (it.displayName.toLowerCase().contains(q)) {
      matchedTop.add(it.key);
    }
  }

  return [
    for (final it in all)
      if (it.depth == 0 && matchedTop.contains(it.key))
        it
      else if (it.ownerZipKey != null &&
          matchedTop.contains(it.ownerZipKey))
        it,
  ];
}

List<EntryInfo> _filterEntries(List<EntryInfo> entries) {
  if (ref.read(searchBoxModeProvider) != SearchBoxMode.filter) {
    return entries;
  }
  final q = _searchCtrl.text.trim().toLowerCase();
  final sizeTimeActive = _isSizeTimeFilterActive();
  return entries.where((e) {
    if (q.isNotEmpty && !e.name.toLowerCase().contains(q)) return false;
    if (sizeTimeActive && !_passesSizeTimeFilter(e.size, e.modified)) {
      return false;
    }
    return true;
  }).toList();
}

void _clearFilter() {
  _searchTaskId++;
  _filterTaskId++;
  _searchCtrl.clear();
  _selectionMode = false;
  _selectedPaths.clear();
  _anchorPath = null;
  setState(() {});
}
  void _doSearch() {
  final q = _searchCtrl.text.trim();
  if (q.isEmpty && !_hasActiveConditions) return;

  // 关键词变了 → 清空高级搜索条件，关闭面板。
  // 用户从"搜张三+排除斗罗"改到"搜我吃西红柿"时，条件不应跟着走。
  if (_lastSearchedQuery != q) {
    if (_searchConditions.isNotEmpty) {
      _clearConditions();
      _advancedOverlay?.remove();
      _advancedOverlay = null;
      _advancedOpen = false;
    }
    _lastSearchedQuery = q;
  }

  if (q.isNotEmpty) {
    ref.read(browserSearchHistoryProvider.notifier).add(q);
  }
  setState(() {
    _searchActive = true;
    _bodyRevision++; // 搜索/普通列表共用 _itemScrollController，整体重建避免交叉淡入期双挂载
  });
  _startSearch();
}
/// 只清空输入框，退出搜索交给 AppBar 的返回箭头。
void _clearSearchInput() {
  _searchTaskId++;
  _searchCtrl.clear();
  _selectionMode = false;
  _selectedPaths.clear();
  _anchorPath = null;
  _clearZipExpansion();
  setState(() {
    _searchResults = [];
    _searching = false;
    // 注意：_searchActive 保持 true，留在搜索模式
  });
}
  void _clearSearch() {
    _searchTaskId++;
    _searchCtrl.clear();
    _selectionMode = false;
    _selectedPaths.clear();
    _anchorPath = null;
    _clearZipExpansion();
    setState(() {
      _searchResults = [];
      _searching = false;
      _searchActive = false;
      _bodyRevision++; // 退出搜索时整体重建，避免新旧列表交叉淡入双挂载 controller
    });
  }

  void _cancelSearch() {
    _searchTaskId++;
    setState(() => _searching = false);
  }

  Future<void> _showSearchHistory() async {
    await showDialog<void>(
      context: context,
      builder: (c) => Consumer(
        builder: (c, ref, _) {
          final history = ref.watch(browserSearchHistoryProvider);
          return AlertDialog(
            insetPadding: _dlgInset,
            titlePadding: _dlgTitlePad,
            contentPadding: _dlgContentPad,
            actionsPadding: _dlgActionsPad,
            title: const Text('搜索历史'),
            content: SizedBox(
              width: double.maxFinite,
              height: MediaQuery.of(c).size.height * 0.7,
              child: history.isEmpty
                  ? const Center(child: Text('还没有搜索记录'))
                  : ListView.builder(
                      itemCount: history.length,
                      itemBuilder: (ctx, i) {
                        final q = history[i];
                        return ListTile(
                          dense: true,
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 8),
                          leading: const Icon(Icons.history, size: 20),
                          title: Text(
                            q,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            tooltip: '删除',
                            onPressed: () {
                              ref
                                  .read(browserSearchHistoryProvider.notifier)
                                  .remove(q);
                            },
                          ),
                          onTap: () {
                            _searchCtrl.text = q;
                            setState(() {});
                            Navigator.pop(c);
                          },
                        );
                      },
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('关闭'),
              ),
            ],
          );
        },
      ),
    );
  }

  List<String> _dedupFolders(List<String> folders) {
    final sorted = List<String>.from(folders)..sort();
    final out = <String>[];
    for (final f in sorted) {
      final covered = out.any((p) => f == p || f.startsWith('$p/'));
      if (!covered) out.add(f);
    }
    return out;
  }

Future<void> _startSearch() async {
  final taskId = ++_searchTaskId;
  final q = _searchCtrl.text.trim();
  if (q.isEmpty && !_hasActiveConditions) {
    setState(() {
      _searchResults = [];
      _searching = false;
    });
    return;
  }

  setState(() {
    _searching = true;
    _searchResults = [];
  });
  _lastUiRefresh = DateTime.now();

  final scope = ref.read(searchScopeProvider);
  final customFolders = ref.read(customSearchFoldersProvider);

  final roots = <String>[];
  if (scope == SearchScope.currentRecursive) {
    roots.add(_currentPath);
  } else {
    if (customFolders.isEmpty) {
      _toast('请先点击左侧搜索设置 → 管理搜索范围');
      if (mounted) setState(() => _searching = false);
      return;
    }
    roots.addAll(_dedupFolders(customFolders));
  }

  final results = <_SearchHit>[];

  for (final root in roots) {
    if (taskId != _searchTaskId) return;
    await _scanDir(root, results, taskId);
  }

  if (taskId != _searchTaskId) return;
  if (!mounted) return;

  final sortField = ref.read(searchSortFieldProvider);
  final sortAsc = ref.read(searchSortAscProvider);

  results.sort((a, b) {
    int cmp;
    switch (sortField) {
      case SortField.name:
        cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      case SortField.modified:
        final at = a.modified?.millisecondsSinceEpoch ?? 0;
        final bt = b.modified?.millisecondsSinceEpoch ?? 0;
        cmp = at.compareTo(bt);
      case SortField.size:
        final as = a.size ?? 0;
        final bs = b.size ?? 0;
        cmp = as.compareTo(bs);
    }
    return sortAsc ? cmp : -cmp;
  });

  setState(() {
    _searching = false;
    _searchResults = List.from(results);
  });
}

  Future<void> _scanDir(
  String dirPath,
  List<_SearchHit> results,
  int taskId, {
  int depth = 0,
}) async {
  if (depth > _searchMaxDepth) return;
  if (results.length >= 2000) return;
  try {
    await for (final e in Directory(dirPath).list(followLinks: false)) {
      if (taskId != _searchTaskId) return;
      if (results.length >= 2000) return;

      if (e is Directory) {
        final name = e.path.split('/').last;
        if (name.startsWith('.')) continue;
        final lower = e.path.toLowerCase();
        if (lower.contains('/android/data') ||
            lower.contains('/android/obb')) {
          continue;
        }

          if (_matchNameForSearch(name)) {
          DateTime? modified;
          try {
            final st = await e.stat();
            modified = st.modified;
          } catch (_) {}

          if (_passesSizeTimeFilter(null, modified)) {
            results.add(_SearchHit(
              path: e.path,
              name: name,
              isDir: true,
              size: null,
              modified: modified,
            ));
          }

          final now = DateTime.now();
          if (mounted &&
              now.difference(_lastUiRefresh).inMilliseconds > 100) {
            _lastUiRefresh = now;
            setState(() => _searchResults = List.from(results));
          }
        }

        await _scanDir(e.path, results, taskId, depth: depth + 1);
      } else if (e is File) {
        final name = e.path.split('/').last;
          if (_matchNameForSearch(name)) {
          int? size;
          DateTime? modified;
          try {
            final st = await e.stat();
            size = st.size;
            modified = st.modified;
          } catch (_) {}

          if (_passesSizeTimeFilter(size, modified)) {
            results.add(_SearchHit(
              path: e.path,
              name: name,
              isDir: false,
              size: size,
              modified: modified,
            ));
          }

          final now = DateTime.now();
          if (mounted &&
              now.difference(_lastUiRefresh).inMilliseconds > 100) {
            _lastUiRefresh = now;
            setState(() => _searchResults = List.from(results));
          }
        }
      }
    }
  } catch (_) {}
}

  Future<void> _showSearchFolderPicker() async {
    final current = ref.read(customSearchFoldersProvider);
    final result = await showDialog<List<String>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _SearchFolderPickerDialog(
        rootPath: _topPath,
        initialPath: _currentPath,
        initialSelected: current,
      ),
    );
    if (result != null && mounted) {
      ref.read(customSearchFoldersProvider.notifier).setAll(result);
      if (_searchActive && _searchCtrl.text.isNotEmpty) {
    _startSearch();
      }
    }
  }

  // ==================== 对比 / MD5 / 属性 / 复制路径 ====================

  List<_DisplayItem> _resolveSelectedItems() {
    final items = _cachedDisplayItems ?? const <_DisplayItem>[];
    final out = <_DisplayItem>[];
    for (final key in _selectedPaths) {
      final it = items.firstWhere(
        (x) => x.key == key,
        orElse: () => _DisplayItem(
          key: key,
          displayName: key.split('/').last,
          depth: 0,
        ),
      );
      out.add(it);
    }
    return out;
  }

  /// 首次安装后，选中两个文件对比时弹一次引导。
  ///
  /// 第一行红字提醒「对比页不改原文件」，并解释替换 / 编辑 / 快捷操作按钮的用途。
  /// 点「知道了」或「不再显示」都视为已看过，写标记后不再弹。
  Future<void> _maybeShowCompareOnboard() async {
    if (ref.read(compareOnboardProvider)) return;
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        title: const Text('对比前先看一眼'),
        content: const SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '⚠ 对比页不会改动你的原文件！',
                style: TextStyle(
                  color: Colors.red,
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                  height: 1.5,
                ),
              ),
              SizedBox(height: 12),
              Text(
                '替换、编辑、快捷操作按钮，都只是为了让对比更省事。'
                '原文件一个字不动，退出对比页就恢复原样。',
                style: TextStyle(fontSize: 13.5, height: 1.65),
              ),
              SizedBox(height: 8),
              Text(
                '如果想真正修改文件，请用「编辑器」打开文件再改。',
                style: TextStyle(fontSize: 13.5, height: 1.65),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('不再显示'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    ref.read(compareOnboardProvider.notifier).update(true);
  }

  /// 简洁对比（差异清单）入口：与完整对比并列，不经过对比页。
  Future<void> _startQuickCompare() => _startCompare(quick: true);

  /// quick = true 时打开「简洁对比」页（不建块、不排版、只列差异行）；
  /// quick = false 时打开原来的完整对比页。读盘 / 解析 / 写入 provider 完全共用。
  Future<void> _startCompare({bool quick = false}) async {
    if (_selectedPaths.length != 2) return;

    // 简洁对比页没有替换/编辑/快捷操作按钮，引导弹窗只针对完整对比页。
    if (!quick) {
      await _maybeShowCompareOnboard();
      if (!mounted) return;
    }

    final items = _resolveSelectedItems();
    if (items.length != 2) return;

    for (final it in items) {
      if (it.isDir) {
        _toast('对比只支持文件，请勿选中文件夹');
        return;
      }
      if (it.isZip && !it.isZipInner) {
        _toast('对比不支持直接对比压缩包本身，请展开后选里面的文件');
        return;
      }
    }

    // 从这里开始记录一次完整对比：从「点按钮」一直到页面首帧出内容。
    // 引导弹窗不计时（那是用户在看提示，不是程序在算）。
    final log = CompareTimingLog.instance;
    log.start(quick ? '简洁对比' : '完整对比');
    log.param('入口/左文件名', items[0].displayName);
    log.param('入口/右文件名', items[1].displayName);
    log.param('入口/左为压缩包内条目', items[0].isZipInner);
    log.param('入口/右为压缩包内条目', items[1].isZipInner);
    log.param('入口/左为磁盘文件', items[0].isDiskItem);
    log.param('入口/右为磁盘文件', items[1].isDiskItem);
    log.mark('入口参数记录完成，开始推入页面路由');

    String? leftText;
    String? rightText;
    String? leftName;
    String? rightName;
    String? leftPath;
    String? rightPath;

    // 只保留对比页里的那一个加载动画：
    // 先把对比页推出来（表情动画立刻显示），再在它背后读盘 + 解析，
    // 期间把阶段写进 compareLoadStageProvider，让用户知道现在到哪一步。
    // 原来的「灰底 + 空心转圈」对话框已删除，避免出现两个加载页。
    resetCompareLoadState(ref);
    ref.read(compareLoadStageProvider.notifier).state = '正在读取文件…';

    final viewerRoute = Navigator.of(context).push(
      PageRouteBuilder<void>(
        pageBuilder: (_, __, ___) =>
            quick ? const DiffListPage() : const DiffViewerScreen(),
        // 零转场：进入/退出对比页均无动画
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      ),
    );
    log.mark('对比页路由已推入（加载页开始显示）');

    try {
      // 两个文件同时读盘：File.readAsBytes 走 IO 线程池，可以真正重叠；
      // 解码与规范化仍在同一 isolate 内串行执行。
      // 先让对比页把加载页画出来，再开始干重活。
      ref.read(compareLoadStageProvider.notifier).state = '正在读取两个文件…';
      await WidgetsBinding.instance.endOfFrame;
      log.mark('加载页已画出，开始并行读盘');

      final results = await Future.wait([
        _readAndParseForCompare(items[0], '左侧', showStage: false),
        _readAndParseForCompare(items[1], '右侧', showStage: false),
      ]);
      leftText = results[0].text;
      leftName = results[0].fileName;
      leftPath = items[0].isDiskItem ? items[0].diskPath : null;
      rightText = results[1].text;
      rightName = results[1].fileName;
      rightPath = items[1].isDiskItem ? items[1].diskPath : null;
      log.mark('两个文件读盘 + 解析全部完成');
      log.param('文件/左解析后字符数', leftText?.length ?? 0);
      log.param('文件/右解析后字符数', rightText?.length ?? 0);

      if (!mounted) return;

      // 预处理规则是在对比页里同步跑的，先把这条文案画出来再交棒，
      // 这样规则跑到一半时屏幕上写的是"正在应用预处理规则"，不是停住的表情。
      ref.read(compareLoadStageProvider.notifier).state = '正在应用预处理规则…';
      await WidgetsBinding.instance.endOfFrame;
      log.mark('规则阶段文案已画出，开始写入 provider');

      ref.read(originalRawTextProvider.notifier).state = leftText;
      ref.read(modifiedRawTextProvider.notifier).state = rightText;
      ref.read(originalFileNameProvider.notifier).state = leftName;
      ref.read(modifiedFileNameProvider.notifier).state = rightName;
      ref.read(originalEncodingProvider.notifier).state = 'UTF-8';
      ref.read(modifiedEncodingProvider.notifier).state = 'UTF-8';
      ref.read(originalFilePathProvider.notifier).state = leftPath;
      ref.read(modifiedFilePathProvider.notifier).state = rightPath;
      ref.read(originalSharedTempPathProvider.notifier).state = null;
      ref.read(modifiedSharedTempPathProvider.notifier).state = null;
      ref.read(importRevisionProvider.notifier).state++;
      ref.read(fromDupeBoxProvider.notifier).state = false;
      ref.read(editedOriginalProvider.notifier).state = null;
      ref.read(editedModifiedProvider.notifier).state = null;

      // 交棒：之后由 diffResultProvider 自己的加载文案接管。
      ref.read(compareLoadStageProvider.notifier).state = null;
      log.mark('provider 写入完成，交给 diffResultProvider 算差异');

      await viewerRoute;
      if (!mounted) return;
      setState(() => _pruneSearchResults());
    } catch (e) {
      if (!mounted) return;
      ref.read(compareLoadStageProvider.notifier).state = null;
      // UnsupportedError 是解析器主动抛的「暂不支持 xx 格式」，
      // 直接用它自己的文案，别带上 "Unsupported operation:" 这种前缀。
      final msg = e is UnsupportedError ? '${e.message}' : '$e';
      log.fail('读取文件失败：$msg');
      ref.read(compareLoadErrorProvider.notifier).state = '读取文件失败：$msg';
      // 简洁对比页没有加载错误界面：出错时直接退回并提示，避免一直转圈。
      if (quick && mounted) {
        Navigator.of(context).pop();
        _toast('读取文件失败：$msg');
      }
    }
  }

  /// 对比入口用：读盘 + 解析一项，并把当前阶段写进对比页的加载文案。
  ///
  /// 每换一次文案都等一下帧，保证「正在读取 xx.txt…」真的被画出来，
  /// 而不是刚设上去就被后面的大段同步解析卡住。
  Future<({String text, String fileName})> _readAndParseForCompare(
    _DisplayItem item,
    String side, {
    // 两侧并行读盘时由外层统一显示一条文案，避免两边互相覆盖，
    // 也省掉各自多等一帧。
    bool showStage = true,
  }) async {
    if (!mounted) throw Exception('页面已关闭');
    final name = item.displayName;

    if (showStage) {
      ref.read(compareLoadStageProvider.notifier).state =
          '正在读取$side文件 $name…';
      await WidgetsBinding.instance.endOfFrame;
    }

    final log = CompareTimingLog.instance;
    final swRead = Stopwatch()..start();
    final bytes = await _readBytesOfItem(item);
    swRead.stop();
    if (bytes == null) throw Exception('读取$side文件失败');
    log.param('文件/$side 名称', name);
    log.param('文件/$side 压缩包内条目', item.isZipInner);
    log.param('文件/$side 原始字节数', bytes.length);
    log.param('文件/$side 读盘Ms', swRead.elapsedMilliseconds);

    if (showStage) {
      ref.read(compareLoadStageProvider.notifier).state = '正在解析 $name…';
      await WidgetsBinding.instance.endOfFrame;
    }

    final swParse = Stopwatch()..start();
    final parsed = await DocumentParser.parse(fileName: name, bytes: bytes);
    swParse.stop();
    log.param('文件/$side 解析Ms', swParse.elapsedMilliseconds);
    log.param('文件/$side 解析后字符数', parsed.plainText.length);
    log.param('文件/$side 解析器返回文件名', parsed.fileName);
    log.mark('读盘 + 解析完成 / $side');
    return (text: parsed.plainText, fileName: parsed.fileName);
  }

  Future<Uint8List?> _readBytesOfItem(_DisplayItem item) async {
    if (item.isZipInner) {
      return _readZipInnerBytes(item);
    }
    final p = item.diskPath;
    if (p == null) return null;
    try {
      return await File(p).readAsBytes();
    } catch (_) {
      return null;
    }
  }

  static String _md5Worker(Uint8List bytes) {
    return md5.convert(bytes).toString();
  }

  /// 计算单个选中项的 MD5：磁盘文件走分块流式（不整文件入内存），
  /// zip 内部文件内容已在内存中，直接对字节求哈希。
  Future<String> _md5OfItem(_DisplayItem it) async {
    if (it.isZipInner) {
      final b = await _readZipInnerBytes(it);
      if (b == null) throw Exception('读取文件失败');
      return compute(_FileBrowserScreenState._md5Worker, b);
    }
    final p = it.diskPath;
    if (p == null) throw Exception('读取文件失败');
    return compute(_md5FileOfPath, p);
  }

  Future<void> _md5Compare() async {
    if (_selectedPaths.length != 2) return;
    final items = _resolveSelectedItems();
    if (items.length != 2) return;

    for (final it in items) {
      if (it.isDir) {
        _toast('MD5 对比只支持文件，请勿选中文件夹');
        return;
      }
    }

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final h1 = await _md5OfItem(items[0]);
      final h2 = await _md5OfItem(items[1]);

      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();

      final same = h1 == h2;
      final name1 = items[0].displayName;
      final name2 = items[1].displayName;

      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          insetPadding: _dlgInset,
          titlePadding: _dlgTitlePad,
          contentPadding: _dlgContentPad,
          actionsPadding: _dlgActionsPad,
          title: const Text('MD5 对比'),
          content: SizedBox(
            width: double.maxFinite,
            height: MediaQuery.of(context).size.height * 0.7,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name1,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  SelectableText(h1,
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 12)),
                  const SizedBox(height: 14),
                  Text(name2,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  SelectableText(h2,
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 12)),
                  const SizedBox(height: 16),
                  Text(
                    same ? '相同' : '不同',
                    style: TextStyle(
                      color: same
                          ? Theme.of(c).colorScheme.primary
                          : Theme.of(c).colorScheme.error,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      _toast('计算 MD5 失败：$e');
    }
  }

  // ==================== 顶栏查重：先选范围，再查 ====================

  /// 顶栏查重按钮的入口。
  ///
  /// 原来一点就直接扫当前目录，用户没有反悔的余地。
  /// 现在先问一句「查哪个范围」：此目录 / 自定义目录。
  Future<void> _onTapDedupButton() async {
    final remembered = ref.read(dupScopeFoldersProvider);

    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Row(
                children: [
                  Image.asset(
                    'assets/images/dupebox_icon.png',
                    width: 20,
                    height: 20,
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      '查重哪个范围？',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: const Text('查重此目录'),
              subtitle: Text(
                _currentPath,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11),
              ),
              onTap: () => Navigator.pop(c, 'current'),
            ),
            ListTile(
              leading: const Icon(Icons.checklist),
              title: const Text('自定义目录'),
              subtitle: Text(
                remembered.isEmpty
                    ? '自己勾选一个或多个文件夹'
                    : '已记住 ${remembered.length} 个目录',
                style: const TextStyle(fontSize: 11),
              ),
              onTap: () => Navigator.pop(c, 'custom'),
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );

    if (choice == 'current') {
      await _findDuplicatesCurrentFolder();
    } else if (choice == 'custom') {
      await _runCustomDupScan();
    }
  }

  /// 自定义目录查重的完整流程：
  ///   记住过 → 先问「沿用 / 重选」；
  ///   没记住 → 直接打开选择器；
  ///   选完   → 问「要不要记住」；
  ///   最后   → 发起扫描。
  Future<void> _runCustomDupScan() async {
    final remembered = ref.read(dupScopeFoldersProvider);

    if (remembered.isNotEmpty) {
      final act = await _askReuseRememberedScope(remembered);
      if (act == null || !mounted) return;
      if (act == 'reuse') {
        await _launchDupScan(_dedupFolders(remembered));
        return;
      }
    }

    final picked = await _pickDupFolders(remembered);
    if (picked == null || !mounted) return;
    if (picked.isEmpty) {
      _toast('没有勾选任何文件夹');
      return;
    }

    // 选完范围、要真的去查了，才问记不记住。
    final remember = await _askRememberScope(picked);
    if (!mounted) return;
    ref
        .read(dupScopeFoldersProvider.notifier)
        .setAll(remember == true ? picked : const <String>[]);
    if (remember == true) {
      _toast('已记住 ${picked.length} 个目录，下次点查重直接沿用');
    }
    await _launchDupScan(_dedupFolders(picked));
  }

  /// 打开文件夹勾选器。首次使用会叠一层引导（高亮勾选区 / 进入区）。
  Future<List<String>?> _pickDupFolders(List<String> initial) async {
    final needGuide = !ref.read(dupScopeGuideSeenProvider);
    final result = await showDialog<List<String>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _SearchFolderPickerDialog(
        rootPath: _topPath,
        initialPath: _currentPath,
        initialSelected: initial,
        titleText: '勾选要查重的文件夹',
        showGuide: needGuide,
      ),
    );
    if (needGuide) {
      ref.read(dupScopeGuideSeenProvider.notifier).update(true);
    }
    return result;
  }

  /// 已有记住的范围时，问是沿用还是重新选。
  Future<String?> _askReuseRememberedScope(List<String> folders) {
    return showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('查重范围'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('上次记住了这些目录：'),
              const SizedBox(height: 8),
              ...folders.take(4).map(
                    (p) => Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(
                        '· ${p.split('/').last}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
              if (folders.length > 4)
                Text(
                  '· 等共 ${folders.length} 个',
                  style: const TextStyle(fontSize: 12),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, 'reselect'),
            child: const Text('重新选'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, 'reuse'),
            child: const Text('用这些'),
          ),
        ],
      ),
    );
  }

  /// 选完范围、发起查重之前，问要不要记住。
  ///
  /// 两个选项都把后果写清楚，避免用户随手一点后不知道会发生什么。
  Future<bool?> _askRememberScope(List<String> folders) {
    return showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('记住这次的扫描范围吗？'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '已勾选 ${folders.length} 个文件夹。',
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              const Text(
                '记住：\n'
                '下次点查重直接用这些目录，不用再选一遍。\n'
                '想换范围时，在同一个菜单里选「重新选」即可。',
                style: TextStyle(fontSize: 12, height: 1.5),
              ),
              const SizedBox(height: 10),
              const Text(
                '不记住：\n'
                '只查这一次。下次点查重会重新打开选择器让你再选。',
                style: TextStyle(fontSize: 12, height: 1.5),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('不记住'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('记住'),
          ),
        ],
      ),
    );
  }

  /// 选中单个文件夹时，跳转到 DupeBox 对该文件夹进行重复扫描。
  /// 通过原生通道拉起 DupeBox（com.dupebox.dupe_box）并传入真实文件夹路径。
  Future<void> _findDuplicates() async {
    final sel = _resolveSelectedItems();
    // 支持多选文件夹：仅取其中所有文件夹，至少 1 个才发起扫描。
    final folders = sel.where((it) => it.isDir).map((it) => it.key).toList();
    if (folders.isEmpty) return;
    await _launchDupScan(folders);
  }

  /// 向 DupeBox 发起对给定文件夹列表的重复扫描（统一深链通道）。
  /// 返回是否成功发起（未装 DupeBox 等情况返回 false 并 toast）。
  Future<bool> _launchDupScan(List<String> folders) async {
    if (folders.isEmpty) return false;
    try {
      await const MethodChannel('docdiff/dupebox_launcher')
          .invokeMethod('scanFolder', {'folderPaths': folders});
      return true;
    } on PlatformException catch (e) {
      final msg = e.code == 'NO_DUPEBOX'
          ? '未安装 DupeBox，请先安装后重试'
          : (e.message ?? '无法启动 DupeBox');
      if (!mounted) return false;
      _toast(msg);
      return false;
    }
  }

  /// 对「当前所在文件夹」直接发起查重：单文件夹深链跳转到 DupeBox。
  /// 满足“点进文件夹就能查”的预期，无需先回到上级再多选。
  Future<void> _findDuplicatesCurrentFolder() async {
    // _currentPath 即当前目录的真实路径，作为深链 roots 使用。
    final folder = _currentPath;
    if (folder.isEmpty) return;
    try {
      await const MethodChannel('docdiff/dupebox_launcher')
          .invokeMethod('scanFolder', {
        'folderPaths': <String>[folder],
      });
    } on PlatformException catch (e) {
      final msg = e.code == 'NO_DUPEBOX'
          ? '未安装 DupeBox，请先安装后重试'
          : (e.message ?? '无法启动 DupeBox');
      if (!mounted) return;
      _toast(msg);
    }
  }

  // ==================== 查重暂存篮 ====================

  /// 把当前选中的文件夹（多选也支持）加入查重暂存篮，去重。
  void _addSelectionToBasket() {
    final sel = _resolveSelectedItems();
    final folders = sel.where((it) => it.isDir).map((it) => it.key).toList();
    if (folders.isEmpty) return;
    final cur = ref.read(dupBasketProvider);
    final next = <String>[...cur];
    for (final f in folders) {
      if (!next.contains(f)) next.add(f);
    }
    ref.read(dupBasketProvider.notifier).state = next;
    _toast('已加入去重盒子扫描范围（${next.length}）');
  }

  /// 从暂存篮移除某个路径（管理弹窗内单条删除用）。
  void _removeFromBasket(String path) {
    final cur = ref.read(dupBasketProvider);
    ref.read(dupBasketProvider.notifier).state =
        cur.where((p) => p != path).toList();
  }

  /// 清空暂存篮。
  void _clearBasket() {
    ref.read(dupBasketProvider.notifier).state = const [];
  }

  /// 用暂存篮里的所有文件夹发起查重。
  ///
  /// 注意：深链是 fire-and-forget——只要 DupeBox 已安装就返回成功，无法得知
  /// 对方是否真的开扫（例如「全盘访问」权限不足时 DupeBox 会直接拒绝，
  /// 而这里收不到任何失败通知）。因此不再发送后自动清空，避免用户辛苦
  /// 跨层级收集的目录被静默丢弃；改为弹一条带「清空」操作的提示，
  /// 由用户自己决定何时清空。
  Future<void> _launchDupScanFromBasket() async {
    final basket = ref.read(dupBasketProvider);
    final ok = await _launchDupScan(basket);
    if (!ok || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: const Text('已发送到 DupeBox（扫描范围已保留，方便重试）'),
        action: SnackBarAction(
          label: '清空',
          onPressed: _clearBasket,
        ),
      ),
    );
  }

  /// 打开“去重盒子扫描范围”管理弹窗：查看/增删路径，确认后一次性传给 DupeBox。
  Future<void> _openDupBasketSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSheet) {
            final basket = ref.watch(dupBasketProvider);
            final s = Theme.of(context).colorScheme;
            return SafeArea(
              child: Container(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.8,
                ),
                decoration: BoxDecoration(
                  color: s.brightness == Brightness.light
                      ? Colors.white
                      : s.surface,
                  border: Border(
                    top: BorderSide(color: s.outlineVariant),
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '去重盒子扫描范围（${basket.length}）',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          if (basket.isNotEmpty)
                            TextButton(
                              onPressed: () {
                                _clearBasket();
                                setSheet(() {});
                              },
                              child: const Text('清空'),
                            ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    if (basket.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          '暂无文件夹。在任意层级选中文件夹后，\n点底部「加入扫描范围」（在「去查重」旁边）即可添加。',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 13),
                        ),
                      )
                    else
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight:
                              MediaQuery.of(context).size.height * 0.5,
                        ),
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: basket.length,
                          separatorBuilder: (_, __) =>
                              const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final p = basket[i];
                            return ListTile(
                              leading: const Icon(Icons.folder_outlined),
                              title: Text(p.split('/').last),
                              subtitle: Text(
                                p,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                              trailing: IconButton(
                                icon: const Icon(Icons.close),
                                tooltip: '移除',
                                onPressed: () {
                                  _removeFromBasket(p);
                                  setSheet(() {});
                                },
                              ),
                            );
                          },
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                      child: Text(
                        '提示：DupeBox 需「全盘访问」权限才能按路径扫描这些目录。'
                        '若跳转后提示权限不足，请先到 DupeBox 设置里开启，'
                        '扫描范围已保留可直接重试。',
                        style: TextStyle(
                          fontSize: 12,
                          color: s.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          icon: Image.asset(
                            'assets/images/dupebox_icon.png',
                            width: 18,
                            height: 18,
                          ),
                          label: const Text('去 DupeBox 查重'),
                          onPressed: basket.isEmpty
                              ? null
                              : () => _launchDupScanFromBasket(),
                        ),
                      ),
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

  /// 底部“去重盒子扫描范围”条：非空时显示，点开管理、一键去查重。
  Widget _buildDupBasketBar() {
    final basket = ref.watch(dupBasketProvider);
    final s = Theme.of(context).colorScheme;
    return Container(
      // 顶边不再画线：整块的边界由 _buildBottomOverlay 的羽化带统一处理，
      // 这里再画一条就会在渐变下面冒出一道硬边。
      color: s.brightness == Brightness.light ? Colors.white : s.surface,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: _openDupBasketSheet,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                child: Row(
                  children: [
                    Image.asset(
                      'assets/images/dupebox_icon.png',
                      width: 18,
                      height: 18,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '去重盒子扫描范围（${basket.length}）',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(Icons.expand_less, size: 18),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          OutlinedButton(
            onPressed: _openDupBasketSheet,
            child: const Text('管理'),
          ),
          const SizedBox(width: 4),
          FilledButton(
            onPressed: () => _launchDupScanFromBasket(),
            child: const Text('去查重'),
          ),
        ],
      ),
    );
  }

  Future<void> _exportFolderListing() async {
    if (_selectedPaths.length != 1) {
      _toast('导出清单一次只能选一个文件夹');
      return;
    }
    final items = _resolveSelectedItems();
    if (items.isEmpty || !items[0].isDir) {
      _toast('导出清单只能用于文件夹');
      return;
    }
    final path = items[0].diskPath;
    if (path == null) {
      _toast('此文件夹不在磁盘上');
      return;
    }

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    Uint8List bytes;
    try {
      bytes = await compute(_folderListingWorker, path);
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      _toast('扫描失败：$e');
      return;
    }

    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();

    final name = path.split('/').last;
    final ts = DateTime.now().millisecondsSinceEpoch;
    final out = await FilePicker.saveFile(
      fileName: '$name-list-$ts.txt',
      bytes: bytes,
      mimeType: 'text/plain',
      dialogTitle: '保存文件夹清单',
      type: FileType.custom,
      allowedExtensions: ['txt'],
    );
    if (out != null && mounted) {
      _toast('清单已导出');
    }
  }

  Future<void> _showProperties() async {
    if (_selectedPaths.isEmpty) return;
    final items = _resolveSelectedItems();
    if (items.isEmpty) return;

    // 多选：只做统计，不进下面那个带 MD5 的单文件弹窗。
    if (items.length > 1) {
      await _showMultiProperties(items);
      return;
    }
    final it = items[0];

    if (it.isZipInner) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          insetPadding: _dlgInset,
          titlePadding: _dlgTitlePad,
          contentPadding: _dlgContentPad,
          actionsPadding: _dlgActionsPad,
          title: const Text('属性'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _propRow(context, '名称', it.displayName),
                _propRow(context, '来源', it.fullDisplayPath),
                _propRow(context, '类型', it.isDir ? '文件夹' : '文件'),
                _propRow(
                  context,
                  '大小',
                  it.size == null ? '—' : _formatSize(it.size),
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
        ),
      );
      return;
    }

    final path = it.diskPath;
    if (path == null) return;
    final name = it.displayName;

    int? size;
    DateTime? modified;
    DateTime? accessed;
    bool isDir = false;
    try {
      final st = await FileStat.stat(path);
      modified = st.modified;
      accessed = st.accessed;
      size = st.size;
      isDir = st.type == FileSystemEntityType.directory;
    } catch (_) {}

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _PropertiesDialog(
        name: name,
        path: path,
        isDir: isDir,
        size: size,
        modified: modified,
        accessed: accessed,
      ),
    );
  }

  /// 多选属性：只统计，不算 MD5（⋯ 菜单里已有「MD5对比」）。
  /// 大小/时间优先用列表里已有的元数据；缺了才补一次 FileStat.stat，
  /// 所以两个普通文件通常是零额外读盘，点开即出。
  Future<void> _showMultiProperties(List<_DisplayItem> items) async {
    final details = <_PropDetail>[];
    int fileCount = 0;
    int dirCount = 0;
    int? totalBytes = 0;
    bool hasUnknownSize = false;
    DateTime? newest;
    String? newestName;
    DateTime? oldest;
    String? oldestName;

    for (final it in items) {
      int? size = it.size;
      DateTime? modified = it.modified;
      // 磁盘项缺元数据时补一次 stat；压缩包内的条目只能用它自带的 size。
      final p = it.diskPath;
      if ((size == null || modified == null) && p != null) {
        try {
          final st = await FileStat.stat(p);
          size ??= st.size;
          modified ??= st.modified;
        } catch (_) {}
      }

      if (it.isDir) {
        // 跟单文件属性一致：文件夹大小显示 —，也不计入总大小。
        dirCount++;
      } else if (size == null) {
        hasUnknownSize = true;
      } else {
        totalBytes = (totalBytes ?? 0) + size;
      }

      if (modified != null) {
        if (newest == null || modified.isAfter(newest)) {
          newest = modified;
          newestName = it.displayName;
        }
        if (oldest == null || modified.isBefore(oldest)) {
          oldest = modified;
          oldestName = it.displayName;
        }
      }

      details.add(_PropDetail(
        name: it.displayName,
        path: p,
        isDir: it.isDir,
        size: size,
        modified: modified,
      ));
    }

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (c) {
        final s = Theme.of(c).colorScheme;

        Widget kv(String label, String value) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: Theme.of(c).textTheme.labelSmall),
                  const SizedBox(height: 2),
                  SelectableText(value, style: const TextStyle(fontSize: 13)),
                ],
              ),
            );

        final sizeNote = dirCount > 0
            ? '（不含文件夹）'
            : (hasUnknownSize ? ' + 部分未统计' : '');
        final sizeText = '${_formatSize(totalBytes)}$sizeNote';

        return AlertDialog(
          insetPadding: const EdgeInsets.all(16),
          title: const Text('属性'),
          content: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(c).size.height * 0.7,
            ),
            child: SizedBox(
              width: 380,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '已选 ${items.length} 项',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      "$fileCount 个文件${dirCount > 0 ? ' · $dirCount 个文件夹' : ''}",
                      style: TextStyle(fontSize: 13, color: s.onSurfaceVariant),
                    ),
                    const SizedBox(height: 12),
                    const Divider(height: 1),
                    const SizedBox(height: 12),
                    kv('总大小', sizeText),
                    if (dirCount == 0 && !hasUnknownSize && items.length > 1)
                      kv('平均大小', _formatSize(totalBytes! ~/ items.length)),
                    if (newest != null)
                      kv('最新修改', '$newestName（${_formatTimeFull(newest!)}）'),
                    if (oldest != null && oldest != newest)
                      kv('最旧修改', '$oldestName（${_formatTimeFull(oldest!)}）'),
                    const SizedBox(height: 4),
                    const Divider(height: 1),
                    const SizedBox(height: 10),
                    Text(
                      '明细',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: s.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 6),
                    ...List.generate(details.length, (i) {
                      final d = details[i];
                      final sizeLabel = d.isDir
                          ? '—'
                          : (d.size == null ? '大小未知' : _formatSize(d.size));
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('${i + 1}. ',
                                    style: const TextStyle(fontSize: 13)),
                                Expanded(
                                  child: Text(
                                    d.name,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              [
                                sizeLabel,
                                if (d.modified != null)
                                  '修改 ${_formatTime(d.modified)}',
                              ].join(' · '),
                              style: TextStyle(
                                fontSize: 12,
                                color: s.onSurfaceVariant,
                              ),
                            ),
                            if (d.path != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: SelectableText(
                                  d.path!,
                                  maxLines: 2,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: s.onSurfaceVariant,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      );
                    }),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }

  Widget _propRow(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 2),
          SelectableText(value),
        ],
      ),
    );
  }

  Future<void> _openWithApp() async {
    if (_selectedPaths.length != 1) return;
    final items = _resolveSelectedItems();
    if (items.isEmpty) return;
    final it = items[0];
    if (it.isDir) {
      _toast('文件夹不能"打开方式"');
      return;
    }
    if (it.isZipInner) {
      final bytes = _readZipInnerBytes(it);
      if (bytes == null) {
        _toast('读取失败');
        return;
      }
      final tmp = await _writeTempFile(bytes, it.displayName);
      if (tmp == null) {
        _toast('无法创建临时文件');
        return;
      }
      if (!mounted) return;
      await openFileWithSystemPicker(tmp, context);
      return;
    }
    final p = it.diskPath;
    if (p == null) return;
    await openFileWithSystemPicker(p, context);
  }

  Future<void> _shareSelected() async {
    if (_selectedPaths.isEmpty) return;
    final items = _resolveSelectedItems();

    final diskPaths = <String>[];
    final tempPaths = <String>[];
    for (final it in items) {
      if (it.isZipInner) {
        final bytes = _readZipInnerBytes(it);
        if (bytes == null) continue;
        final tmp = await _writeTempFile(bytes, it.displayName);
        if (tmp != null) tempPaths.add(tmp);
      } else {
        final p = it.diskPath;
        if (p != null) diskPaths.add(p);
      }
    }

    final all = <String>[...diskPaths, ...tempPaths];
    if (all.isEmpty) {
      _toast('没有可分享的文件');
      return;
    }
    if (!mounted) return;
    await shareMany(all, context);
  }

  Future<void> _copyPath() async {
    if (_selectedPaths.length != 1) return;
    final items = _resolveSelectedItems();
    if (items.isEmpty) return;
    final it = items[0];
    final path = it.isZipInner ? it.fullDisplayPath : (it.diskPath ?? '');
    if (path.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: path));
    if (mounted) _toast('路径已复制');
  }

  static String _formatTimeFull(DateTime t) {
    String two(int n) => n < 10 ? '0$n' : '$n';
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  // ==================== 视图弹窗 ====================

  String _sortLabel(SortField f) {
    switch (f) {
      case SortField.name:
        return '名称';
      case SortField.modified:
        return '修改时间';
      case SortField.size:
        return '大小';
    }
  }

// ==================== 当前目录信息 ====================

Future<void> _showDirInfoDialog() async {
  if (_loading) {
    _toast('目录还在加载中，请稍候');
    return;
  }

  final entries = _entries ?? const <EntryInfo>[];

  var dirCount = 0;
  var fileCount = 0;
  var totalBytes = 0;
  var hasUnknownSize = false;

  var textCount = 0;
  var imageCount = 0;
  var videoCount = 0;
  var audioCount = 0;
  var archiveCount = 0;
  var otherCount = 0;

  int? maxSize;
  String? maxSizeName;
  DateTime? newestTime;
  String? newestName;
  DateTime? oldestTime;
  String? oldestName;

  for (final info in entries) {
    if (info.isDir) {
      dirCount++;
      continue;
    }
    fileCount++;

    final sz = info.size;
    if (sz != null) {
      totalBytes += sz;
      if (maxSize == null || sz > maxSize) {
        maxSize = sz;
        maxSizeName = info.name;
      }
    } else {
      hasUnknownSize = true;
    }

    final t = info.modified;
    if (t != null) {
      if (newestTime == null || t.isAfter(newestTime)) {
        newestTime = t;
        newestName = info.name;
      }
      if (oldestTime == null || t.isBefore(oldestTime)) {
        oldestTime = t;
        oldestName = info.name;
      }
    }

    final ext = _extOf(info.name);
    if (_textExts.contains(ext)) {
      textCount++;
    } else if (_imageExts.contains(ext)) {
      imageCount++;
    } else if (_videoExts.contains(ext)) {
      videoCount++;
    } else if (_audioExts.contains(ext)) {
      audioCount++;
    } else if (_archiveExts.contains(ext)) {
      archiveCount++;
    } else {
      otherCount++;
    }
  }

  if (!mounted) return;

  final sortField = ref.read(sortFieldProvider);
  final sortAsc = ref.read(sortAscProvider);
  final gridMode = ref.read(browserGridModeProvider);

  String sizeText;
  if (hasUnknownSize) {
    sizeText = '${_formatSize(totalBytes)} + 部分未统计';
  } else {
    sizeText = _formatSize(totalBytes);
  }

  await showDialog<void>(
    context: context,
    builder: (c) {
      final s = Theme.of(c).colorScheme;

      Widget kv(String label, String value, {bool selectable = false}) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: Theme.of(c).textTheme.labelSmall),
              const SizedBox(height: 2),
              selectable
                  ? SelectableText(value, style: const TextStyle(fontSize: 13))
                  : Text(value, style: const TextStyle(fontSize: 13)),
            ],
          ),
        );
      }

      return AlertDialog(
        insetPadding: const EdgeInsets.all(16),
        title: const Text('当前目录信息'),
        content: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(c).size.height * 0.7,
          ),
          child: SizedBox(
            width: 380,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  kv('路径', _currentPath, selectable: true),
                  const SizedBox(height: 4),

                  Text(
                    '共 ${entries.length} 项',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$dirCount 个文件夹 · $fileCount 个文件',
                    style: TextStyle(
                      fontSize: 13,
                      color: s.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Divider(height: 1),
                  const SizedBox(height: 12),

                  kv('总大小（不含子目录）', sizeText),

                  if (maxSizeName != null)
                    kv('最大文件',
                        '$maxSizeName（${_formatSize(maxSize!)}）'),

                  if (newestTime != null)
                    kv('最新文件',
                        '$newestName（${_formatTime(newestTime!)}）'),

                  if (oldestTime != null)
                    kv('最旧文件',
                        '$oldestName（${_formatTime(oldestTime!)}）'),

                  kv('当前排序',
                      '${_sortLabel(sortField)} · ${sortAsc ? "升序" : "降序"}'),

                  kv('显示模式', gridMode ? '网格' : '列表'),

                  const SizedBox(height: 4),
                  const Divider(height: 1),
                  const SizedBox(height: 8),

                  Text(
                    '类型分布',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: s.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '文本 $textCount · 图片 $imageCount · 视频 $videoCount · '
                    '音频 $audioCount · 压缩包 $archiveCount · 其他 $otherCount',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('关闭'),
          ),
        ],
      );
    },
  );
}

  // ==================== 收藏 / 配置 ====================

  void _toggleSearchBarCollapsed() {
    final notifier = ref.read(searchBarCollapsedProvider.notifier);
    final currentlyCollapsed = ref.read(searchBarCollapsedProvider);

    if (currentlyCollapsed) {
      // 展开 + 自动聚焦
      notifier.update(false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchFocus.requestFocus();
      });
    } else {
      // 折叠：只收起 UI，不清空搜索内容（对标 Solid Explorer）。
      // 想清空请用输入框右边的 × 按钮。
      FocusManager.instance.primaryFocus?.unfocus();
      notifier.update(true);
    }
  }

  /// 搜索栏区域当前是否可见。
  /// - 选择模式：始终可见（显示提示条）
  /// - 始终显示：可见
  /// - 可折叠 + 已折叠：隐藏
  bool get _searchBarAreaVisible {
    if (_selectionMode) return true;
    if (ref.watch(searchBarVisibilityProvider) ==
        SearchBarVisibility.alwaysVisible) {
      return true;
    }
    return !ref.watch(searchBarCollapsedProvider);
  }

  void _toggleFavorite() {
    final favs = ref.read(favoritesProvider);
    final wasFav = favs.contains(_currentPath);
    ref.read(favoritesProvider.notifier).toggle(_currentPath);
    _toast(wasFav ? '已取消收藏' : '已收藏当前目录');
  }

  /// 导入 / 导出合并成一个入口，点开后再选方向。
  Future<void> _showConfigIoMenu() async {
    final action = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        insetPadding: _dlgInset,
        title: const Text('配置导入导出'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.upload_file, size: 18),
                label: const Text('导出配置'),
                onPressed: () => Navigator.pop(c, 'export'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.download_for_offline_outlined, size: 18),
                label: const Text('导入配置'),
                onPressed: () => Navigator.pop(c, 'import'),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'export') {
      await _exportConfig();
    } else {
      await _importConfig();
    }
  }

  Future<void> _exportConfig() async {
    try {
      final ok = await ConfigIoService.instance.export();
      if (!mounted) return;
      if (ok) _toast('配置已导出');
    } catch (e) {
      if (mounted) _toast('导出失败：$e');
    }
  }

  Future<void> _importConfig() async {
    final result = await ConfigIoService.instance.import();
    if (!mounted) return;
    if (!result.ok && result.message == null) return;
    if (!result.ok) {
      _toast(result.message ?? '导入失败');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('导入成功'),
        content: const Text(
          '配置已导入。请手动退出 App 再重新打开，配置才会生效。',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _showFavorites() async {
    final picked = await showDialog<String>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setInnerState) {
          final favorites = ref.watch(favoritesProvider);
          final isFav = favorites.contains(_currentPath);
          final cs = Theme.of(context).colorScheme;

          return AlertDialog(
            insetPadding: const EdgeInsets.all(16),
            title: const Text('已收藏目录'),
            content: SizedBox(
              width: 360,
              height: MediaQuery.of(context).size.height * 0.55,
              child: Column(
                children: [
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        isFav ? Icons.star : Icons.star_border,
                        color: isFav ? Colors.amber : cs.onSurfaceVariant,
                      ),
                      title: Text(
                        isFav ? '取消收藏当前目录' : '收藏当前目录',
                        style: TextStyle(color: cs.onSurface),
                      ),
                      subtitle: Text(
                        _currentPath,
                        style: const TextStyle(fontSize: 11),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () {
                        ref
                            .read(favoritesProvider.notifier)
                            .toggle(_currentPath);
                        setInnerState(() {});
                      },
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: favorites.isEmpty
                          ? Center(
                              child: Text(
                                '还没有收藏任何目录',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            )
                          : ListView.builder(
                              itemCount: favorites.length,
                              itemBuilder: (ctx, i) {
                                final p = favorites[i];
                                return ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  leading: const AppFileIcon(isDir: true),
                                  title: Text(
                                    p,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: cs.onSurface,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  onTap: () => Navigator.pop(c, p),
                                  trailing: IconButton(
                                    icon: Icon(
                                      Icons.delete_outline,
                                      size: 20,
                                      color: cs.onSurfaceVariant,
                                    ),
                                    tooltip: '移除收藏',
                                    onPressed: () async {
                                      final ok = await showDialog<bool>(
                                        context: ctx,
                                        builder: (dc) => AlertDialog(
                                          title: const Text('移除收藏？'),
                                          content: Text(p),
                                          actions: [
                                            TextButton(
                                              onPressed: () =>
                                                  Navigator.pop(dc, false),
                                              child: const Text('取消'),
                                            ),
                                            FilledButton(
                                              onPressed: () =>
                                                  Navigator.pop(dc, true),
                                              child: const Text('移除'),
                                            ),
                                          ],
                                        ),
                                      );
                                      if (ok != true) return;
                                      ref
                                          .read(favoritesProvider.notifier)
                                          .remove(p);
                                      setInnerState(() {});
                                    },
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('关闭'),
              ),
            ],
          );
        },
      ),
    );
    if (picked != null && mounted) {
  if (Directory(picked).existsSync()) {
    _navigateTo(picked);
  } else {
    // 权限被收回时 existsSync 也会返回 false。
    // 不自动删收藏，让用户自己决定。
    final action = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        insetPadding: _dlgInset,
        title: const Text('目录打不开'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('无法访问：', style: TextStyle(fontSize: 12)),
            const SizedBox(height: 4),
            SelectableText(
              picked,
              style: const TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              '可能原因：\n'
              '· 目录已被删除或重命名\n'
              '· 存储卡已拔出\n'
              '· 文件访问权限被收回',
              style: TextStyle(fontSize: 12, height: 1.5),
            ),
            const SizedBox(height: 12),
            const Text(
              '这条收藏要保留吗？',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('保留'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(c).colorScheme.error,
              foregroundColor: Theme.of(c).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(c, 'remove'),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (action == 'remove' && mounted) {
      ref.read(favoritesProvider.notifier).remove(picked);
      _toast('已移除');
    }
  }
}
  }

  // ==================== 文件操作 ====================

  // 记录上一次 toast 的消息和时间，用于"短时间内相同消息不重复弹"。
  String? _lastToastMsg;
  DateTime? _lastToastTime;

  void _toast(String msg) {
    if (!mounted) return;

    // 去重：1.5 秒内同一条消息不再重弹。
    final now = DateTime.now();
    if (_lastToastMsg == msg &&
        _lastToastTime != null &&
        now.difference(_lastToastTime!) < const Duration(milliseconds: 1500)) {
      return;
    }
    _lastToastMsg = msg;
    _lastToastTime = now;

    final ms = msg.length <= 10 ? 1500 : 2000;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          msg,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onInverseSurface,
            fontWeight: FontWeight.bold,
          ),
        ),
        duration: Duration(milliseconds: ms),
        // 悬浮样式：浮在底部操作栏上方，不会被遮挡。
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.only(
          left: 16,
          right: 16,
          bottom: 72,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  Future<bool> _confirm(String title, String message) async {
    if (!mounted) return false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        insetPadding: const EdgeInsets.symmetric(
          horizontal: 32,
          vertical: 24,
        ),
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  List<String> _selectedDiskPaths() {
    final out = <String>[];
    for (final p in _selectedPaths) {
      if (_isZipInnerKey(p)) continue;
      out.add(p);
    }
    return out;
  }

  Future<void> _rename() async {
    // 多选：转批量重命名
    if (_selectedPaths.length > 1) {
      await _batchRename();
      return;
    }

    if (_selectedPaths.length != 1) {
      _toast('重命名一次只能操作一个');
      return;
    }
    final key = _selectedPaths.first;
    if (_isZipInnerKey(key)) {
      _toast('压缩包内的文件不支持重命名');
      return;
    }
    final oldPath = key;
    final oldName = oldPath.split('/').last;

    final newName = await showDialog<String>(
      context: context,
      builder: (_) => _TextInputDialog(
        title: '重命名',
        initialValue: oldName,
      ),
    );
    if (newName == null) return;

    final trimmed = newName.trim();
    if (trimmed.isEmpty || trimmed == oldName) return;
    if (trimmed.contains('/') || trimmed.contains('\\')) {
      _toast('名称不能包含斜杠');
      return;
    }
    if (trimmed == '.' || trimmed == '..') {
      _toast('名称无效');
      return;
    }

    final parent = File(oldPath).parent.path;
    final newPath = '$parent/$trimmed';

    if (FileSystemEntity.typeSync(newPath) !=
        FileSystemEntityType.notFound) {
      _toast('目标已存在：$trimmed');
      return;
    }

    try {
      if (Directory(oldPath).existsSync()) {
        await Directory(oldPath).rename(newPath);
      } else {
        await File(oldPath).rename(newPath);
      }
  DirCache.instance.invalidate(_currentPath);
_clearSelection();
_load(restoreScroll: true, silent: true);
_toast('已重命名为 $trimmed');
    } catch (e) {
      _toast('重命名失败：$e');
    }
  }

  // ==================== 批量重命名：执行 ====================

  Future<void> _batchRename() async {
    var paths = _selectedDiskPaths();
    if (paths.isEmpty) {
      _toast('压缩包内的文件不支持重命名');
      return;
    }

    // 同时选中了文件夹和它内部子项时，去掉子项（父级改名后子路径失效）
    paths = [
      for (final p in paths)
        if (!paths.any((q) => q != p && p.startsWith('$q/'))) p
    ];

    // 把当前列表的显示顺序带进弹窗，供「列表顺序」排序使用。
    final visible = _visibleItems ?? _cachedDisplayItems ?? const <_DisplayItem>[];
    final selectedSet = paths.toSet();
    final orderHint = <String>[
      for (final it in visible)
        if (selectedSet.contains(it.key)) it.key,
    ];
    for (final p in paths) {
      if (!orderHint.contains(p)) orderHint.add(p);
    }

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => _BatchRenameDialog(
        paths: paths,
        orderHint: orderHint,
      ),
    );
    if (result == null || result.isEmpty || !mounted) return;

    // 两阶段改名，避免链式覆盖（a→b、b→c）
    var ok = 0;
    var fail = 0;
    final tempMap = <String, String>{};

    // 阶段 1：全部改成临时名
    for (final oldPath in result.keys) {
      final tmp =
          '$oldPath.renaming_${DateTime.now().microsecondsSinceEpoch}';
      try {
        if (Directory(oldPath).existsSync()) {
          await Directory(oldPath).rename(tmp);
        } else {
          await File(oldPath).rename(tmp);
        }
        tempMap[oldPath] = tmp;
      } catch (_) {
        fail++;
      }
    }

    // 阶段 2：临时名 → 目标名
    for (final entry in result.entries) {
      final tmp = tempMap[entry.key];
      if (tmp == null) continue;
      try {
        if (Directory(tmp).existsSync()) {
          await Directory(tmp).rename(entry.value);
        } else {
          await File(tmp).rename(entry.value);
        }
        ok++;
      } catch (_) {
        // 阶段 2 失败：把临时名改回去，别留下奇怪后缀
        try {
          if (Directory(tmp).existsSync()) {
            await Directory(tmp).rename(entry.key);
          } else {
            await File(tmp).rename(entry.key);
          }
        } catch (_) {}
        fail++;
      }
    }

    DirCache.instance.invalidate(_currentPath);
    _clearSelection();
    _load(restoreScroll: true, silent: true);
    _toast('已重命名 $ok 项${fail > 0 ? "，$fail 项失败" : ""}');
  }

  Future<void> _move() async {
  final paths = _selectedDiskPaths();
  if (paths.isEmpty) {
    _toast('压缩包内的文件不支持移动');
    return;
  }
  final target = await _pickDirectory('移动到哪？', paths);
  if (target == null) return;

  // 冲突预检
  final conflictNames = <String>[];
  for (final src in paths) {
    final name = src.split('/').last;
    final dst = '$target/$name';
    if (src == dst) continue;
    if (FileSystemEntity.typeSync(dst) != FileSystemEntityType.notFound) {
      conflictNames.add(name);
    }
  }

  _ConflictAction? action;
  if (conflictNames.isNotEmpty) {
    action = await _askConflict(conflictNames);
    if (action == null) return; // 用户取消
  }

 var ok = 0, fail = 0, skipped = 0;
final movedSources = <String>{};
for (final src in paths) {
    final name = src.split('/').last;
    var dst = '$target/$name';
    if (src == dst) continue;

    if (FileSystemEntity.typeSync(dst) != FileSystemEntityType.notFound) {
      if (action == _ConflictAction.skip) {
        skipped++;
        continue;
      } else if (action == _ConflictAction.rename) {
        dst = _findNonConflictPath(dst);
      } else if (action == _ConflictAction.overwrite) {
        try {
          if (Directory(dst).existsSync()) {
            await Directory(dst).delete(recursive: true);
          } else {
            await File(dst).delete();
          }
        } catch (_) {}
      }
    }

    try {


		
       if (Directory(src).existsSync()) {
      await Directory(src).rename(dst);
    } else {
      await File(src).rename(dst);
    }
    ok++;
    movedSources.add(src);
  } catch (_) {
    fail++;
  }
}

 if (ok > 0) {
  ref.read(recentMoveTargetsProvider.notifier).add(target);
  DirCache.instance.invalidate(target);
}
_clearSelection();

if (movedSources.isNotEmpty && target != _currentPath) {
  // 目标不是当前目录：就地剔除源
  setState(() {
    _entries = (_entries ?? const <EntryInfo>[])
        .where((e) => !movedSources.contains(e.path))
        .toList();
  });
  DirCache.instance.applyToAll(
    _currentPath,
    (list) => list
        .where((e) => !movedSources.contains(e.path))
        .toList(),
  );
} else if (target == _currentPath) {
  // 目标就是当前目录（少见）：退化为静默重载
  _load(restoreScroll: true, silent: true);
}

final parts = <String>['已移动 $ok 项'];
	  
  if (skipped > 0) parts.add('跳过 $skipped 项');
  if (fail > 0) parts.add('$fail 项失败');
  _toast(parts.join('，'));
}

 Future<void> _copy() async {
  final paths = _selectedDiskPaths();
  if (paths.isEmpty) {
    _toast('压缩包内的文件不支持复制');
    return;
  }
  final target = await _pickDirectory('复制到哪？', paths);
  if (target == null) return;

  final conflictNames = <String>[];
  for (final src in paths) {
    final name = src.split('/').last;
    final dst = '$target/$name';
    if (src == dst) continue;
    if (FileSystemEntity.typeSync(dst) != FileSystemEntityType.notFound) {
      conflictNames.add(name);
    }
  }

  _ConflictAction? action;
  if (conflictNames.isNotEmpty) {
    action = await _askConflict(conflictNames);
    if (action == null) return;
  }

  var ok = 0, fail = 0, skipped = 0;
  for (final src in paths) {
    final name = src.split('/').last;
    var dst = '$target/$name';
    if (src == dst) continue;

    if (FileSystemEntity.typeSync(dst) != FileSystemEntityType.notFound) {
      if (action == _ConflictAction.skip) {
        skipped++;
        continue;
      } else if (action == _ConflictAction.rename) {
        dst = _findNonConflictPath(dst);
      } else if (action == _ConflictAction.overwrite) {
        try {
          if (Directory(dst).existsSync()) {
            await Directory(dst).delete(recursive: true);
          } else {
            await File(dst).delete();
          }
        } catch (_) {}
      }
    }

    try {
      if (Directory(src).existsSync()) {
        await _copyDir(Directory(src), Directory(dst));
      } else {
        await File(src).copy(dst);
      }
      ok++;
    } catch (_) {
      fail++;
    }
  }

if (ok > 0) {
  ref.read(recentMoveTargetsProvider.notifier).add(target);
  DirCache.instance.invalidate(target);
  if (target == _currentPath) {
    DirCache.instance.invalidate(_currentPath);
  }
}
_clearSelection();
_load(restoreScroll: true, silent: true);

final parts = <String>['已复制 $ok 项'];
  if (skipped > 0) parts.add('跳过 $skipped 项');
  if (fail > 0) parts.add('$fail 项失败');
  _toast(parts.join('，'));
}

  Future<void> _copyDir(Directory src, Directory dst) async {
    await dst.create(recursive: true);
    await for (final e in src.list(followLinks: false)) {
      final name = e.path.split('/').last;
      final target = '${dst.path}/$name';
      if (e is Directory) {
        await _copyDir(e, Directory(target));
      } else if (e is File) {
        await e.copy(target);
      }
    }
  }
Future<_ConflictAction?> _askConflict(List<String> conflictNames) async {
  return showDialog<_ConflictAction>(
    context: context,
    barrierDismissible: false,
    builder: (c) => AlertDialog(
      insetPadding: _dlgInset,
      title: const Text('目标目录有同名项'),
      content: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.of(c).size.height * 0.5,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('以下 ${conflictNames.length} 个名称已在目标目录中存在：'),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: conflictNames.length,
                itemBuilder: (ctx, i) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    '· ${conflictNames[i]}',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(c, _ConflictAction.skip),
          child: const Text('跳过'),
        ),
        TextButton(
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(c).colorScheme.error,
          ),
          onPressed: () => Navigator.pop(c, _ConflictAction.overwrite),
          child: const Text('覆盖'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(c, _ConflictAction.rename),
          child: const Text('重命名'),
        ),
      ],
    ),
  );
}

/// 给 dst 找一个不冲突的路径：加 " (1)" " (2)" 之类的后缀。
String _findNonConflictPath(String originalDst) {
  final dotIdx = originalDst.lastIndexOf('.');
  final slashIdx = originalDst.lastIndexOf('/');
  final hasExt = dotIdx > slashIdx && dotIdx < originalDst.length - 1;
  final base = hasExt ? originalDst.substring(0, dotIdx) : originalDst;
  final ext = hasExt ? originalDst.substring(dotIdx) : '';
  for (var i = 1; i < 10000; i++) {
    final candidate = '$base ($i)$ext';
    if (FileSystemEntity.typeSync(candidate) ==
        FileSystemEntityType.notFound) {
      return candidate;
    }
  }
  return '$base (${DateTime.now().millisecondsSinceEpoch})$ext';
}

  Future<void> _delete() async {
    final paths = _selectedDiskPaths();
    if (paths.isEmpty) {
      _toast('压缩包内的文件不支持删除');
      return;
    }
    final n = paths.length;
final ok = await showDialog<bool>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _DeleteConfirmDialog(paths: paths),
);
if (ok != true) return;

    final deletedPaths = <String>{};
    var fail = 0;
    var trashed = 0; // 移入回收站的项数
    var direct = 0; // 直接物理删除的项数（文件夹 / 回收站写入失败回退）
    for (final p in paths) {
      try {
        if (Directory(p).existsSync()) {
          await Directory(p).delete(recursive: true);
          direct++;
        } else {
          // 文件删除：先移入共享回收站（fromDupeBox=false → 在 docdiff 回收站入口可见）；
          // 回收站不可用时退化为永久删除，绝不阻断用户删除。
          var moved = false;
          try {
            await ShareIntakeCoordinator.moveToSharedTrash(p, fromDupeBox: false);
            moved = true;
          } catch (_) {
            try {
              await File(p).delete();
            } on FileSystemException catch (_) {
              // 原文件已不存在（极少数：moveToSharedTrash 已删原文件）视为成功。
            }
          }
          if (moved) {
            trashed++;
          } else {
            direct++;
          }
        }
        deletedPaths.add(p);
      } catch (_) {
        fail++;
      }
    }

    final deleted = deletedPaths.length;
    _clearSelection();

    if (_searchActive) {
      final anchor = _snapshotVisiblePaths();
      setState(() {
        _searchResults = _searchResults.where((h) {
          if (deletedPaths.contains(h.path)) return false;
          for (final dp in deletedPaths) {
            if (h.path.startsWith('$dp/')) return false;
          }
          return true;
        }).toList();
      });
      if (anchor.isNotEmpty) _restoreScrollAnchor(anchor);
  
	
	} else {
  // 就地移除，不重载
  setState(() {
    _entries = (_entries ?? const <EntryInfo>[])
        .where((e) => !deletedPaths.contains(e.path))
        .toList();
  });
  DirCache.instance.applyToAll(
    _currentPath,
    (list) => list
        .where((e) => !deletedPaths.contains(e.path))
        .toList(),
  );
}

    final destNote = trashed > 0 && direct > 0
        ? '（$trashed 项已移入回收站，$direct 项直接删除无法恢复）'
        : trashed > 0
            ? '（已移入回收站，可在「⋯ → 回收站」恢复）'
            : direct > 0
                ? '（直接删除，无法恢复）'
                : '';
    _toast('已删除 $deleted 项$destNote${fail > 0 ? "，$fail 项失败" : ""}');
  }

  Future<void> _newFolder() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _TextInputDialog(
        title: '新建文件夹',
        initialValue: '新建文件夹',
      ),
    );
    if (name == null) return;

    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      _toast('名称不能为空');
      return;
    }
    if (trimmed.contains('/') || trimmed.contains('\\')) {
      _toast('名称不能包含斜杠');
      return;
    }
    if (trimmed == '.' || trimmed == '..') {
      _toast('名称无效');
      return;
    }

    final path = '$_currentPath/$trimmed';
    if (FileSystemEntity.typeSync(path) !=
        FileSystemEntityType.notFound) {
      _toast('同名文件或文件夹已存在');
      return;
    }
    try {
     await Directory(path).create();
DirCache.instance.invalidate(_currentPath);
_load(silent: true);
_toast('已新建 $trimmed');
    } catch (e) {
      _toast('新建失败：$e');
    }
  }

  Future<void> _showJumpToPathDialog() async {
    final ctrl = TextEditingController();
    final cs = Theme.of(context).colorScheme;
    final path = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        insetPadding: const EdgeInsets.symmetric(
          horizontal: 32,
          vertical: 24,
        ),
        title: const Text('跳转到目录'),
        content: SizedBox(
          width: 340,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '输入或粘贴完整路径',
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: ctrl,
                autofocus: true,
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '/storage/emulated/0/xxx',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: cs.primary, width: 1.5),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                ),
                onSubmitted: (v) => Navigator.pop(c, v),
              ),
              const SizedBox(height: 8),
              Text(
                '若粘贴的是文件路径，会跳到该文件所在目录',
                style: TextStyle(
                  fontSize: 11,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, ctrl.text.trim()),
            child: const Text('跳转'),
          ),
        ],
      ),
    );
    ctrl.dispose();

    if (!mounted || path == null || path.isEmpty) return;

  var target = path.trim();
  if (target.isEmpty) return;

  // 常见路径前缀统一换成 /storage/emulated/0
  target = _normalizePath(target);

  if (FileSystemEntity.typeSync(target) == FileSystemEntityType.file) {
    target = File(target).parent.path;
  }

  if (!Directory(target).existsSync()) {
    _toast('目录不存在：$target');
    return;
  }
  if (!target.startsWith('/storage/')) {
    _toast('只能跳到 /storage 以内的路径');
    return;
  }
  _navigateTo(target);
}

/// 归一化用户粘贴的路径。
/// · /sdcard/...         → /storage/emulated/0/...
/// · /storage/self/primary/... → /storage/emulated/0/...
/// · /storage/emulated/legacy/... → /storage/emulated/0/...
/// · /mnt/sdcard/...     → /storage/emulated/0/...
String _normalizePath(String path) {
  const prefixes = <String, String>{
    '/sdcard/': '/storage/emulated/0/',
    '/sdcard': '/storage/emulated/0',
    '/mnt/sdcard/': '/storage/emulated/0/',
    '/mnt/sdcard': '/storage/emulated/0',
    '/storage/self/primary/': '/storage/emulated/0/',
    '/storage/self/primary': '/storage/emulated/0',
    '/storage/emulated/legacy/': '/storage/emulated/0/',
    '/storage/emulated/legacy': '/storage/emulated/0',
  };
  for (final e in prefixes.entries) {
    if (path.startsWith(e.key)) {
      return e.value + path.substring(e.key.length);
    }
  }
  return path;
}




	  
  

  Future<String?> _pickDirectory(String title, List<String> pickedPaths) async {
  return showDialog<String>(
    context: context,
    builder: (_) => DirectoryPickerDialog(
      title: title,
      rootPath: _topPath,
      initialPath: _currentPath,
      pickedPaths: pickedPaths,
    ),
  );
}

  // ==================== 面包屑 ====================

  List<({String label, String path})>? _crumbsCache;
  String? _crumbsCacheForPath;

  List<({String label, String path})> get _crumbs {
    if (_crumbsCacheForPath == _currentPath && _crumbsCache != null) {
      return _crumbsCache!;
    }
    final out = _computeCrumbs();
    _crumbsCacheForPath = _currentPath;
    _crumbsCache = out;
    return out;
  }

  List<({String label, String path})> _computeCrumbs() {
    if (_currentPath == _topPath) {
      return [(label: '存储', path: _topPath)];
    }

    if (_currentPath == _rootPath ||
        _currentPath.startsWith('$_rootPath/')) {
      final out = <({String label, String path})>[
        (label: '内部存储', path: _rootPath),
      ];
      final relative = _currentPath.substring(_rootPath.length);
      final segments =
          relative.split('/').where((s) => s.isNotEmpty).toList();
      var acc = _rootPath;
      for (final seg in segments) {
        acc = '$acc/$seg';
        out.add((label: seg, path: acc));
      }
      return out;
    }

    final out = <({String label, String path})>[
      (label: '存储', path: _topPath),
    ];
    if (!_currentPath.startsWith('$_topPath/')) return out;
    final relative = _currentPath.substring(_topPath.length);
    final segments =
        relative.split('/').where((s) => s.isNotEmpty).toList();

    var acc = _topPath;
    for (final seg in segments) {
      acc = '$acc/$seg';
      if (seg == 'emulated') continue;
      out.add((label: _crumbLabelFor(acc, seg), path: acc));
    }
    return out;
  }

  String _crumbLabelFor(String fullPath, String segment) {
    if (segment == 'emulated') return 'emulated';
    if (segment == 'self') return 'self';
    if (fullPath == _rootPath) return '内部存储';
    if (fullPath.startsWith('$_topPath/emulated/')) {
      return '双开($segment)';
    }
    if (RegExp(r'^[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}$').hasMatch(segment)) {
      return '外部存储($segment)';
    }
    return segment;
  }

  Widget _buildBreadcrumbs() {
    final crumbs = _crumbs;
    final s = Theme.of(context).colorScheme;
    final widgets = <Widget>[];
    for (var i = 0; i < crumbs.length; i++) {
      final c = crumbs[i];
      final isLast = i == crumbs.length - 1;
      if (i > 0) {
        widgets.add(Icon(
          Icons.chevron_right,
          size: 16,
          color: _selectionMode ? s.outlineVariant : s.outline,
        ));
      }
      widgets.add(
        GestureDetector(
          onTap: (_selectionMode || isLast)
              ? null
              : () => _openBreadcrumb(c.path),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Text(
              c.label,
              style: TextStyle(
                fontSize: 12,
                color: _selectionMode
                    ? s.onSurfaceVariant.withValues(alpha: 0.4)
                    : (isLast ? s.onSurface : s.onSurfaceVariant),
                fontWeight: FontWeight.normal,
              ),
            ),
          ),
        ),
      );
    }
    return Container(
      width: double.infinity,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Row(children: widgets),
      ),
    );
  }

  static String _formatSize(int? bytes) {
    if (bytes == null) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  static String _formatTime(DateTime? t) {
    if (t == null) return '';
    String two(int n) => n < 10 ? '0$n' : '$n';
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}';
  }

  static String _formatGridTime(DateTime t) {
    String two(int n) => n < 10 ? '0$n' : '$n';
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}';
  }

  String get _title {
    if (_currentPath == _topPath) return '存储';
    if (_currentPath == _rootPath) return '内部存储';
    return _currentPath.split('/').last;
  }

  String _relPath(String fullPath) {
    if (fullPath == _rootPath) return '~/';
    if (fullPath.startsWith('$_rootPath/')) {
      return '~${fullPath.substring(_rootPath.length)}';
    }
    return fullPath;
  }
  
  // ==================== build ====================
    // ==================== build ====================
    @override
    Widget build(BuildContext context) {
      _cachedDisplayItems = _buildDisplayItems();
      _visibleItems = _computeVisibleItems(_cachedDisplayItems!);
      return PopScope(
        canPop: _atPageBoundary &&
            !_selectionMode &&
            !_searchActive &&
            _expandedZipKeys.isEmpty &&
            _floatingMenuEntry == null &&
            _advancedOverlay == null,
                onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          // 高级面板是浮在最上层的临时层，返回键先把它关掉，不动页面状态。
          if (_advancedOverlay != null) {
            _closeAdvanced();
            return;
          }
          // 悬浮菜单是浮在最上层的临时层，返回键先把它关掉，不动页面状态。
          if (_floatingMenuEntry != null) {
            _closeFloatingMenu();
            return;
          }
          if (_selectionMode) {
            setState(_clearSelection);
          } else if (_searchActive) {
            _clearSearch();
          } else if (_expandedZipKeys.isNotEmpty) {
            setState(() {
              _clearZipExpansion();
            });
          } else if (_canGoUp) {
            _goUp();
          }
          // 主页面在存储选择页（_topPath）、子页面在自己的起始目录时 canPop 为 true：
          // 主页面直接退出 App，子页面则 pop 回上一页，都不走这里。
        },

      child: Scaffold(
        appBar:
            _selectionMode ? _buildSelectionAppBar() : _buildNormalAppBar(),
       body: SafeArea(
  top: false,
  child: Stack(
    children: [
      Column(
        children: [
          _buildBreadcrumbs(),
          ClipRect(
            child: AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              child: _searchBarAreaVisible
                  ? _buildTopBarWithSelectionOverlay()
                  : const SizedBox(width: double.infinity, height: 0),
            ),
          ),
          // 顶栏（标题 + 面包屑 + 搜索栏）与文件列表之间的一条极淡分割线。
          Container(
            height: 1,
            color: Theme.of(context)
                .colorScheme
                .outlineVariant
                .withValues(alpha: 0.5),
          ),
          Expanded(child: _buildBodyWithOverlays()),
        ],
      ),
      // 选中底栏改为覆盖层：ScrollablePositionedList 是底部锚定的，
      // 用 bottomNavigationBar 改变列表高度会让整个列表上下跳动。
      // 查重暂存篮条（非空时）与选中底栏共用同一底部覆盖层，竖向叠放：
      // 篮子条在上、选中底栏在下，互不遮挡。
      Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: _buildBottomOverlay(),
      ),
    ],
  ),
),
        floatingActionButton: null,
      ),
    );
  }

  /// 底部覆盖层：查重暂存篮条（非空时）+ 选中底栏，竖向叠放。
  ///
  /// 外缘做了一层羽化（见 [_buildFeatheredTop]）——
  /// 原来这里是一条 1px 的 outlineVariant 横线，把列表和底栏硬生生切开，
  /// 现在改成向上渐隐到透明，像图片边缘羽化那样过渡过去。
  /// 底栏是浮在列表上的，这样过渡才不显得突兀。
  Widget _buildBottomOverlay() {
    final basketOn = ref.watch(dupBasketProvider).isNotEmpty;
    if (!basketOn && !_selectionMode) return const SizedBox.shrink();

    final s = Theme.of(context).colorScheme;
    final bg = s.brightness == Brightness.light ? Colors.white : s.surface;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: 0,
          right: 0,
          top: -_bottomFeatherHeight,
          height: _bottomFeatherHeight,
          child: _buildFeatheredTop(bg),
        ),
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (basketOn) _buildDupBasketBar(),
            if (_selectionMode) _buildBottomBar(),
          ],
        ),
      ],
    );
  }

  /// 羽化条高度：够看清渐变，又不至于吃掉列表太多内容。
  static const double _bottomFeatherHeight = 20;

  /// 从透明渐变到 [bg] 的一条羽化带，垫在覆盖层上方。
  ///
  /// 中间多加两个停靠点是为了让曲线更接近高斯羽化：
  /// 线性渐变两头会显得生硬，前段慢、后段快才像"晕开"。
  Widget _buildFeatheredTop(Color bg) {
    return IgnorePointer(
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[
              bg.withValues(alpha: 0),
              bg.withValues(alpha: 0.35),
              bg.withValues(alpha: 0.72),
              bg.withValues(alpha: 0.93),
              bg,
            ],
            stops: const <double>[0, 0.3, 0.62, 0.85, 1],
          ),
        ),
      ),
    );
  }

  PreferredSizeWidget _buildNormalAppBar() {
    final favorites = ref.watch(favoritesProvider);
    final isFav = favorites.contains(_currentPath);
    final isChildPage = widget.initialPath != null;
    final s = Theme.of(context).colorScheme;
    final isDefaultSkin = ref.watch(skinProvider) == AppSkin.defaultBlue;
    // 新页面统一用中性灰顶栏，和原页面区分；不跟随各套皮肤的彩色表面色。
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 自定义皮肤：主页面顶栏用皮肤 tint 的 surface，与「浏览器设置」页顶栏同色；
    // 默认皮肤保持纯白不染 tint。子页面（灰色）/ 深色维持原逻辑。
    final appBarColor = isChildPage
        ? (isDark ? Colors.grey.shade900 : Colors.grey.shade200)
        : (isDark
            ? s.surface
            : (isDefaultSkin ? Colors.white : s.surface));
    // ===== 顶栏按钮 + 三个点菜单：按用户配置渲染 =====
    final layoutRaw = ref.watch(browserTopBarLayoutProvider);
    final layout = parseTopBarLayout(layoutRaw);

    // 顶栏按钮（按配置顺序）
    final topBarActions = <Widget>[];
    for (final a in layout.order) {
      if (!layout.onTopBar.contains(a)) continue;
      final w = _buildTopBarActionButton(a, isFav: isFav);
      if (w != null) topBarActions.add(w);
    }

    // 三个点菜单项（按配置顺序）
    final moreChipStyle = _menuChipStyle();
    final menuItems = <Widget>[];
    for (final a in layout.order) {
      if (layout.onTopBar.contains(a)) continue;
      if (!_isActionAvailable(a)) continue;
      final label = a == BrowserTopBarAction.favoritesList
          ? '已收藏目录 (${favorites.length})'
          : a.label;
      menuItems.add(_menuChip(
        label: label,
        icon: a == BrowserTopBarAction.dedup
            ? Image.asset(
                'assets/images/dupebox_icon.png',
                width: 14,
                height: 14,
              )
            : Icon(_iconForAction(a), size: 14),
        style: moreChipStyle,
        onPressed: () => _dispatchTopBarAction(a.id),
      ));
    }

    return AppBar(
      automaticallyImplyLeading: false, // 左侧按钮完全自绘，避免存储根冒出自动返回键
      backgroundColor: appBarColor,
      surfaceTintColor: Colors.transparent, // Material3 下防止主题色 tint 覆盖
      elevation: 0, // 不要阴影，保持和面包屑同一平面
      title: GestureDetector(
        onLongPress: _showJumpToPathDialog,
        child: Text(
          (_searchActive &&
                  ref.watch(searchScopeProvider) == SearchScope.custom)
              ? '自定义的搜索范围'
              : _title,
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w400,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
      ),
      leading: _searchActive
          ? IconButton(
              icon: const GradientIcon(Icons.arrow_back),
              onPressed: _clearSearch,
            )
          : (isChildPage
              // 子页面：上一级一直可用，直到存储根（与主页面同规则）。
              ? (_canGoUp ? _smallBackButton(onPressed: _goUp) : null)
              : (_currentPath == _topPath
                  ? _smallBackButton(
                      onPressed: () => _navigateTo(_rootPath),
                    )
                  : (_canGoUp
                      ? _smallBackButton(onPressed: _goUp)
                      : null))),
      actions: [
        // 子页面「关闭」按钮：固定，不参与自定义
        if (widget.initialPath != null)
          IconButton(
            icon: const GradientIcon(Icons.close),
            tooltip: '关闭此页面',
            onPressed: () => Navigator.of(context).pop(),
          ),
        // 用户配置的顶栏按钮
        ...topBarActions,
        // 「更多」：固定永远在最后
        KeyedSubtree(
          key: _appBarMoreAnchorKey,
          child: IconButton(
            icon: const GradientIcon(Icons.more_vert),
            tooltip: '更多',
            onPressed: () {
              if (menuItems.isEmpty) {
                _toast('菜单已空。可在「浏览器设置 → 顶栏按钮」里添加。');
                return;
              }
              _showFloatingMenu(
                anchorKey: _appBarMoreAnchorKey,
                above: false,
                items: menuItems,
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _smallBackButton({required VoidCallback onPressed}) {
    return Center(
      child: SizedBox(
        width: 36,
        height: 36,
        child: IconButton(
          icon: const GradientIcon(Icons.arrow_back, size: 20),
          onPressed: onPressed,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(
            minWidth: 36,
            minHeight: 36,
            maxWidth: 36,
            maxHeight: 36,
          ),
          tooltip: null,
        ),
      ),
    );
  }

  /// 按当前配置渲染单个顶栏按钮。
  /// 返回 null 表示当前状态下这个按钮不适用（如「搜索栏开关」在始终显示模式下）。
  Widget? _buildTopBarActionButton(
    BrowserTopBarAction a, {
    required bool isFav,
  }) {
    switch (a) {
      case BrowserTopBarAction.searchToggle:
        if (ref.watch(searchBarVisibilityProvider) !=
            SearchBarVisibility.collapsible) {
          return null;
        }
        return IconButton(
          iconSize: 22,
          icon: GradientIcon(
            ref.watch(searchBarCollapsedProvider)
                ? Icons.search
                : Icons.search_off,
          ),
          tooltip: ref.watch(searchBarCollapsedProvider)
              ? '展开搜索栏'
              : '收起搜索栏',
          onPressed: _toggleSearchBarCollapsed,
        );

      case BrowserTopBarAction.favorite:
        return IconButton(
          icon: isFav
              ? const Icon(Icons.star, color: Colors.amber)
              : const GradientIcon(Icons.star_border),
          tooltip: isFav ? '取消收藏此目录' : '收藏此目录',
          onPressed: _toggleFavorite,
        );

      case BrowserTopBarAction.dedup:
        return IconButton(
          icon: Image.asset(
            'assets/images/dupebox_icon.png',
            width: 22,
            height: 22,
          ),
          tooltip: '查重',
          onPressed: _onTapDedupButton,
        );

      case BrowserTopBarAction.comparisonRules:
        return IconButton(
          icon: const GradientIcon(Icons.tune),
          tooltip: '对比规则设置',
          onPressed: () => _dispatchTopBarAction('comparisonRules'),
        );

      default:
        return IconButton(
          icon: GradientIcon(browserTopBarActionIcon(a)),
          tooltip: a.label,
          onPressed: () => _dispatchTopBarAction(a.id),
        );
    }
  }

  /// 当前状态下该动作是否可用（用于菜单过滤）。
  bool _isActionAvailable(BrowserTopBarAction a) {
    if (a == BrowserTopBarAction.searchToggle) {
      return ref.watch(searchBarVisibilityProvider) ==
          SearchBarVisibility.collapsible;
    }
    return true;
  }

  IconData _iconForAction(BrowserTopBarAction a) => browserTopBarActionIcon(a);

  PreferredSizeWidget _buildSelectionAppBar() {
    final all =
        _visibleItems ?? _cachedDisplayItems ?? const <_DisplayItem>[];
    final selectable = all
        .where((it) => !it.key.startsWith('__loading__') &&
            !it.key.startsWith('__error__'))
        .map((it) => it.key)
        .toList();
    final allSelected = selectable.isNotEmpty &&
        selectable.every((k) => _selectedPaths.contains(k));
    return AppBar(
      backgroundColor: Theme.of(context).colorScheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: () => setState(_clearSelection),
      ),
      title: Text('已选 ${_selectedPaths.length} 个'),
      actions: [
        IconButton(
          icon: Icon(allSelected ? Icons.deselect : Icons.select_all),
          tooltip: allSelected ? '全不选' : '全选',
          onPressed: _toggleSelectAll,
        ),
      ],
    );
  }

  // ==================== 搜索栏 UI ====================


/// 顶部区域：搜索栏（+状态栏/展开条）。
/// 选择模式下不替换，而是把提示条覆盖在上面。
/// 用 Stack + Visibility(maintainSize) 保证两种模式高度一致，
/// 否则 Expanded 的列表会跟着上下跳。
/// ExcludeFocus 在选择模式下把搜索框的焦点断掉，
/// 防止透明状态下仍弹输入法。
Widget _buildTopBarWithSelectionOverlay() {
  final normal = ExcludeFocus(
    excluding: _selectionMode,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSearchBar(),
        if (_searchActive) _buildSearchStatusBar(),
        if (!_searchActive && _expandedZipKeys.isNotEmpty)
          _buildExpandedZipBar(),
      ],
    ),
  );

  return Stack(
    children: [
      // 高度基准。选择模式下隐藏但仍占位。
      Visibility(
        visible: !_selectionMode,
        maintainSize: true,
        maintainAnimation: true,
        maintainState: true,
        child: normal,
      ),
      if (_selectionMode)
        Positioned.fill(child: _buildSelectionHintBar()),
    ],
  );
}

/// 选中模式下替代搜索栏显示的提示条。
/// 高度与搜索栏（8 + 44 + 4 ≈ 56）对齐，切换时不跳动。
Widget _buildSelectionHintBar() {
  final n = _selectedPaths.length;
  final items = _resolveSelectedItems();

  bool isComparable(_DisplayItem it) =>
      !it.isDir && !(it.isZip && !it.isZipInner);

  final allComparable =
      items.isNotEmpty && items.every(isComparable);

  String line1;
  String line2;

  if (allComparable && n == 2) {
    // 两个文件都在，左右已经可以自证，直接给出角色
    line1 = '左：${items[0].displayName}';
    line2 = '右：${items[1].displayName} · 可对比 / MD5 对比';
  } else {
    line1 = '长按另一个文件可进行区间选择，点击可继续加选';
    if (allComparable && n == 1) {
      line2 = '此项会放在对比页左边';
    } else {
      line2 = '如果想对比文件，请选择两个文件';
    }
  }

  final cs = Theme.of(context).colorScheme;
  return Container(
    width: double.infinity,
    // 高度不再写死：由 Positioned.fill 从 Stack 拉满，
    // 等于搜索栏（+状态栏/展开条）的实际高度，切换选择模式时列表不动。
    margin: const EdgeInsets.fromLTRB(8, 4, 8, 4),
    padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
    decoration: BoxDecoration(
      color: cs.surface,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: cs.outlineVariant),
    ),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          line1,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 11.5,
            height: 1.25,
            color: cs.onSurface,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          line2,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 11.5,
            height: 1.25,
            color: cs.onSurfaceVariant,
          ),
        ),
      ],
    ),
  );
}

  Widget _buildSearchBar() {
  final cs = Theme.of(context).colorScheme;
  final scope = ref.watch(searchScopeProvider);
  final mode = ref.watch(searchBoxModeProvider);
  final isFilter = mode == SearchBoxMode.filter;
  final isCustom = scope == SearchScope.custom;
  final customFolders = ref.watch(customSearchFoldersProvider);
  final hasText = _searchCtrl.text.isNotEmpty;
  final focused = _searchFocus.hasFocus;
  // 默认皮肤才启用品牌渐变；其他皮肤保持原来的实色描边与单色图标。
  final useBrandGradient = ref.watch(skinProvider) == AppSkin.defaultBlue;

  // ===== 左侧标签 =====
  final String label;
  final String? badge;
  if (isFilter) {
    label = '过滤';
    badge = null;
  } else if (isCustom) {
    label = '自定义';
    badge = customFolders.isEmpty ? null : '${customFolders.length}';
  } else {
    label = '当前目录';
    badge = null;
  }

  // ===== 输入框占位文案 =====
  final String hintText;
  if (isFilter) {
    hintText = '过滤当前目录';
  } else if (isCustom) {
    if (customFolders.isEmpty) {
      hintText = '点左侧标签设置搜索范围';
    } else if (customFolders.length == 1) {
      hintText = '在 1 个自定义目录中搜索';
    } else {
      hintText = '在 ${customFolders.length} 个自定义目录中搜索';
    }
  } else {
    hintText = '在当前目录中搜索';
  }

  // ===== 右侧按钮：形状区分模式 =====
  final IconData actionIcon =
      isFilter ? Icons.filter_alt_outlined : Icons.search;
  final Color actionColor = (isFilter || !hasText)
      ? cs.onSurfaceVariant
      : cs.onSurface;

  // ===== 输入框形状：搜索=胶囊，过滤=圆角矩形 =====
  final double radius = isFilter ? 8.0 : 22.0;
  final Color borderColor = focused ? cs.onSurface : cs.outline;
  final double borderWidth = focused ? 1.5 : 1.0;
  // 渐变描边：浅色直接用品牌蓝，深色压深一档，避免在暗底上发亮。
  final List<Color> borderGradient = cs.brightness == Brightness.dark
      ? const [Color(0xFF2A476E), Color(0xFF5C8FC9), Color(0xFF1E3554)]
      : GradientIcon.colors;
  final double borderAlpha = focused ? 1.0 : 0.6;

  // ===== 标签颜色：聚焦或有字时加深 =====
  final bool labelActive = focused || hasText;
  final Color labelColor =
      labelActive ? cs.onSurface : cs.onSurfaceVariant;

  return TapRegion(
    onTapOutside: (_) {
      FocusManager.instance.primaryFocus?.unfocus();
    },
    child: Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: Row(
        children: [
          // ===== 左侧活字标签 =====
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _showSearchSettings,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 6,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: labelActive
                            ? FontWeight.w600
                            : FontWeight.w500,
                        color: labelColor,
                      ),
                    ),
                    if (badge != null) ...[
                      const SizedBox(width: 3),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: cs.surfaceVariant,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          badge,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(width: 3),
                    GradientIcon(
                      Icons.settings_outlined,
                      size: 14,
                      fallbackColor: labelColor,
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),

          // ===== 输入框 =====
          Expanded(
            child: AnimatedContainer(
              key: _searchBarBoxKey,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              height: 44,
              padding: useBrandGradient
                  ? const EdgeInsets.all(1.5)
                  : null,
              decoration: useBrandGradient
                  ? BoxDecoration(
                      borderRadius: BorderRadius.circular(radius),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: borderGradient
                            .map((c) => c.withValues(alpha: borderAlpha))
                            .toList(),
                        stops: const [0.0, 0.5, 1.0],
                      ),
                    )
                  : BoxDecoration(
                      borderRadius: BorderRadius.circular(radius),
                      border: Border.all(
                        color: borderColor,
                        width: borderWidth,
                      ),
                    ),
              child: Container(
                decoration: BoxDecoration(
                  color: cs.surface,
                  borderRadius: BorderRadius.circular(
                    useBrandGradient ? radius - 1.5 : radius,
                  ),
                ),
                child: Row(
                children: [
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      key: _searchInputKey,
                      controller: _searchCtrl,
                      focusNode: _searchFocus,
                      cursorColor: cs.primary,
                      style: TextStyle(fontSize: 14, color: cs.onSurface),
                      decoration: InputDecoration(
                        hintText: hintText,
                        hintStyle: TextStyle(
                          fontSize: 14,
                          color: cs.onSurfaceVariant,
                        ),
                        isDense: true,
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.zero,
                      ),
                      onChanged: _onSearchChanged,
                      onSubmitted: isFilter
                          ? (_) => FocusManager.instance
                              .primaryFocus
                              ?.unfocus()
                          : (_) => _doSearch(),
                    ),
                  ),
                  // 条件徽章：只显示数字，点它打开高级面板
                  if (_hasActiveConditions)
                    Padding(
                      padding: const EdgeInsets.only(right: 2),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: _toggleAdvanced,
                          borderRadius: BorderRadius.circular(4),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: cs.primaryContainer,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '条件·$_activeConditionCount',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: cs.onPrimaryContainer,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  // 高级搜索（搜索模式下常驻，不再要求输入框有内容）
                  if (!isFilter) _buildAdvancedToggle(),
                  // 清空 / 历史
                  SizedBox(
                    width: 40,
                    height: 44,
                    child: InkResponse(
                      onTap: hasText
                          ? (isFilter ? _clearFilter : _clearSearchInput)
                          : _showSearchHistory,
                      radius: 20,
                      child: Tooltip(
                        message: hasText ? '清空输入' : '搜索历史',
                        child: GradientIcon(
                          hasText ? Icons.close : Icons.history,
                          size: 20,
                          fallbackColor: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              ),
            ),
          ),
          const SizedBox(width: 4),

          // ===== 右侧执行 / 标识按钮 =====
          SizedBox(
            width: 44,
            height: 44,
            child: InkResponse(
              radius: 22,
              onTap: () {
                if (isFilter) {
                  // 过滤模式：点击 = 收键盘（过滤是实时的，无"执行"语义）
                  FocusManager.instance.primaryFocus?.unfocus();
                } else if (hasText || _hasActiveConditions) {
                  _doSearch();
                } else {
                  // 搜索模式无内容：聚焦输入框
                  _searchFocus.requestFocus();
                }
              },
              child: GradientIcon(
                actionIcon,
                size: 22,
                fallbackColor: actionColor,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
Future<void> _showSearchSettings() async {
  FocusManager.instance.primaryFocus?.unfocus();

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (c) => Consumer(
      builder: (c, ref, _) {
        final cs = Theme.of(c).colorScheme;
        final scope = ref.watch(searchScopeProvider);
        final customFolders = ref.watch(customSearchFoldersProvider);
        final searchSortField = ref.watch(searchSortFieldProvider);
        final searchSortAsc = ref.watch(searchSortAscProvider);
        final boxMode = ref.watch(searchBoxModeProvider);
        final isFilter = boxMode == SearchBoxMode.filter;

        final String scopeLabel;
        if (isFilter) {
          scopeLabel = '过滤当前目录';
        } else if (scope == SearchScope.custom) {
          scopeLabel = '在 ${customFolders.length} 个自定义目录中搜索';
        } else {
          scopeLabel = '在当前目录及子目录中搜索';
        }

        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // drag handle
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: cs.onSurfaceVariant.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // 标题
                Text(
                  '搜索设置',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  scopeLabel,
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 20),

                // ===== 搜索框行为 =====
                _settingsSectionHeader(cs, '搜索框行为'),
                const SizedBox(height: 8),
                _settingsChoiceGroup<SearchBoxMode>(
                  context: context,
                  cs: cs,
                  value: boxMode,
                  onChanged: (v) => ref
                      .read(searchBoxModeProvider.notifier)
                      .update(v),
                  options: const [
                    (
                      value: SearchBoxMode.search,
                      label: '搜索',
                      hint: '回车或点搜索按钮才执行，扫子目录',
                    ),
                    (
                      value: SearchBoxMode.filter,
                      label: '过滤',
                      hint: '边打字边筛，只当前目录',
                    ),
                  ],
                ),
                const SizedBox(height: 20),

                // ===== 搜索模式：范围 + 排序 =====
                if (!isFilter) ...[
                  _settingsSectionHeader(cs, '搜索范围'),
                  const SizedBox(height: 8),
                  _settingsChoiceGroup<SearchScope>(
                    context: context,
                    cs: cs,
                    value: scope,
                    onChanged: (v) {
                      ref.read(searchScopeProvider.notifier).update(v);
                      if (_searchActive && _searchCtrl.text.isNotEmpty) {
                        _startSearch();
                      }
                    },
                    options: const [
                      (
                        value: SearchScope.currentRecursive,
                        label: '当前目录及子目录',
                        hint: null,
                      ),
                      (
                        value: SearchScope.custom,
                        label: '自定义的搜索范围',
                        hint: null,
                      ),
                    ],
                  ),
                  if (scope == SearchScope.custom) ...[
                    const SizedBox(height: 6),
                    Padding(
                      padding: const EdgeInsets.only(left: 30),
                      child: TextButton.icon(
                        style: TextButton.styleFrom(
                          foregroundColor: cs.primary,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          visualDensity: VisualDensity.compact,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: const Icon(Icons.folder_special, size: 16),
                        label: Text(
                          customFolders.isEmpty
                              ? '选择搜索目录'
                              : '管理搜索目录（${customFolders.length}）',
                          style: const TextStyle(fontSize: 13),
                        ),
                        onPressed: () => _showSearchFolderPicker(),
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),

                  _settingsSectionHeader(cs, '结果排序'),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _settingsSortChip(
                        cs: cs,
                        label: '名称',
                        selected: searchSortField == SortField.name,
                        onTap: () {
                          ref
                              .read(searchSortFieldProvider.notifier)
                              .update(SortField.name);
                          _resortSearchResults();
                        },
                      ),
                      _settingsSortChip(
                        cs: cs,
                        label: '修改时间',
                        selected: searchSortField == SortField.modified,
                        onTap: () {
                          ref
                              .read(searchSortFieldProvider.notifier)
                              .update(SortField.modified);
                          _resortSearchResults();
                        },
                      ),
                      _settingsSortChip(
                        cs: cs,
                        label: '大小',
                        selected: searchSortField == SortField.size,
                        onTap: () {
                          ref
                              .read(searchSortFieldProvider.notifier)
                              .update(SortField.size);
                          _resortSearchResults();
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _settingsSortChip(
                        cs: cs,
                        label: '升序',
                        selected: searchSortAsc,
                        onTap: () {
                          ref
                              .read(searchSortAscProvider.notifier)
                              .update(true);
                          _resortSearchResults();
                        },
                      ),
                      _settingsSortChip(
                        cs: cs,
                        label: '降序',
                        selected: !searchSortAsc,
                        onTap: () {
                          ref
                              .read(searchSortAscProvider.notifier)
                              .update(false);
                          _resortSearchResults();
                        },
                      ),
                    ],
                  ),
                ] else ...[
                  // ===== 过滤模式：说明条 =====
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '过滤只在当前目录内生效。\n'
                      '想跨目录查找，请切回"搜索"模式。',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.6,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 24),

                // ===== 完成按钮 =====
                SizedBox(
                  width: double.infinity,
                  height: 44,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(c),
                    child: const Text(
                      '完成',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

// ==================== 搜索设置弹窗 · 小部件 ====================

/// 设置弹窗里的小节标题。13px，主题色，字重 600。
Widget _settingsSectionHeader(ColorScheme cs, String text) {
  return Text(
    text,
    style: TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w600,
      color: AppColors.textAccentOf(cs),
      letterSpacing: 0.3,
    ),
  );
}

/// 一组单选项，卡片式。第一个和最后一个圆角，中间直角。
/// 每一项：圆点 + 标题 + 可选副标题。
Widget _settingsChoiceGroup<T>({
  required BuildContext context,
  required ColorScheme cs,
  required T value,
  required ValueChanged<T> onChanged,
  required List<({T value, String label, String? hint})> options,
}) {
  return Container(
    decoration: BoxDecoration(
      color: cs.surfaceContainerLow,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < options.length; i++) ...[
          if (i > 0)
            Divider(
              height: 1,
              indent: 44,
              endIndent: 16,
              color: cs.outlineVariant.withValues(alpha: 0.5),
            ),
          InkWell(
            onTap: () => onChanged(options[i].value),
            borderRadius: i == 0
                ? const BorderRadius.vertical(top: Radius.circular(10))
                : i == options.length - 1
                    ? const BorderRadius.vertical(bottom: Radius.circular(10))
                    : BorderRadius.zero,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 12,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Icon(
                      value == options[i].value
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                      size: 20,
                      color: value == options[i].value
                          ? cs.primary
                          : cs.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          options[i].label,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: value == options[i].value
                                ? FontWeight.w600
                                : FontWeight.normal,
                            color: value == options[i].value
                                ? AppColors.textAccentOf(cs)
                                : cs.onSurface,
                          ),
                        ),
                        if (options[i].hint != null) ...[
                          const SizedBox(height: 3),
                          Text(
                            options[i].hint!,
                            style: TextStyle(
                              fontSize: 11,
                              height: 1.4,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    ),
  );
}

/// 排序胶囊。选中：主题色底 + 主题色边框；未选中：浅灰底。
Widget _settingsSortChip({
  required ColorScheme cs,
  required String label,
  required bool selected,
  required VoidCallback onTap,
}) {
  return GestureDetector(
    onTap: onTap,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: selected ? cs.secondaryContainer : cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 13,
          fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          color: selected ? cs.onSecondaryContainer : cs.onSurface,
        ),
      ),
    ),
  );
}

void _resortSearchResults() {
  if (_searchResults.isEmpty) return;
  final sortField = ref.read(searchSortFieldProvider);
final sortAsc = ref.read(searchSortAscProvider);
_searchResults.sort((a, b) {
 
    int cmp;
    switch (sortField) {
      case SortField.name:
        cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      case SortField.modified:
        final at = a.modified?.millisecondsSinceEpoch ?? 0;
        final bt = b.modified?.millisecondsSinceEpoch ?? 0;
        cmp = at.compareTo(bt);
      case SortField.size:
        final as = a.size ?? 0;
        final bs = b.size ?? 0;
        cmp = as.compareTo(bs);
    }
    return sortAsc ? cmp : -cmp;
  });
  setState(() {});
}
/// 有压缩包展开时，在搜索栏下方固定显示一条提示条。
Widget _buildExpandedZipBar() {
  final topLevelCount =
      _expandedZipKeys.where((k) => !_isZipInnerKey(k)).length;
  if (topLevelCount == 0) return const SizedBox.shrink();

  final cs = Theme.of(context).colorScheme;
  return Container(
    width: double.infinity,
    color: cs.secondaryContainer,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
    child: Row(
      children: [
    const AppFileIcon(isDir: true, isZip: true, size: 16),
              const SizedBox(width: 8),
        Expanded(
          child: Text(
            '已展开 $topLevelCount 个压缩包',
            style: TextStyle(
              fontSize: 12,
              color: cs.onSecondaryContainer,
            ),
          ),
        ),
        TextButton(
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            foregroundColor: cs.onSecondaryContainer,
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
          onPressed: () {
            setState(() {
              _expandedZipKeys.clear();
              _zipArchives.clear();
              _zipErrors.clear();
              _loadingZipKeys.clear();
              _encryptedNestedZipKeys.clear();
              _stickyZipKey = null;
            });
          },
          child: const Text('全部收起'),
        ),
      ],
    ),
  );
}


  Widget _buildSearchStatusBar() {
    final textTheme = Theme.of(context).textTheme;
    if (_searching) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        child: Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '扫描中... 已找到 ${_searchResults.length} 个',
                style: textTheme.labelSmall,
              ),
            ),
            TextButton(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
              onPressed: _cancelSearch,
              child: const Text('取消'),
            ),
          ],
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _searchResults.length >= 500
                  ? '已达上限，只显示前 2000 个'
                  : '共找到 ${_searchResults.length} 个',
              style: textTheme.labelSmall,
            ),
          ),
        ],
      ),
    );
  }

  // ==================== 底部栏 ====================

  bool get _selectionAllDisk {
    if (_selectedPaths.isEmpty) return false;
    for (final k in _selectedPaths) {
      if (_isZipInnerKey(k)) return false;
    }
    return true;
  }

  bool get _selectionHasZipInner {
    for (final k in _selectedPaths) {
      if (_isZipInnerKey(k)) return true;
    }
    return false;
  }

  Widget _buildBottomBar() {
    final n = _selectedPaths.length;
    // 与提示条同一套判定：文件夹 / 压缩包本体不能对比，按钮置灰。
    final selItems = _resolveSelectedItems();
    bool isComparable(_DisplayItem it) =>
        !it.isDir && !(it.isZip && !it.isZipInner);
    final allComparable =
        selItems.isNotEmpty && selItems.every(isComparable);
    final canCompare = n == 2 && allComparable;
    final canMd5 = n == 2 && allComparable;
    // 属性不再只认单选：多选也要能看数量 / 总大小等统计（见 _showMultiProperties）。
    final canProps = n >= 1;
    final canOpenWith = n == 1;
    final canShare = n >= 1;
    final allDisk = _selectionAllDisk;

    final canCopyPath = n == 1;
    final canRename = n >= 1 && allDisk;
    final canMove = n >= 1 && allDisk;
    final canCopy = n >= 1 && allDisk;
    final canDelete = n >= 1 && allDisk;
    final canOpenNewPage = n == 1 && selItems.length == 1 && allDisk;
    final openNewPageLabel =
        selItems.length == 1 && !selItems.first.isDir ? '所在目录打开' : '新页面打开';

    final s = Theme.of(context).colorScheme;
    final isDefaultSkin = ref.watch(skinProvider) == AppSkin.defaultBlue;
    // 菜单项（顶栏「更多」/ 底栏「⋯」）仍用 16:16 留白。
    final chipStyle = _menuChipStyle();
    // 底栏第一行四个描边按钮（简洁对比 / 复制路径 / 分享 / ⋯）共用这一套：
    // 横向内边距归零 —— 按钮本来就是 Expanded 撑满、文字居中，宽度富余时自然留白；
    // 固定留白反而让窄屏上 4 个字的「复制路径」被挤成省略号，也跟其他按钮不齐。
    // 竖向 4 保留：当年从 16 改到 4 才修复被 SizedBox(38) 裁成"半截字"的问题。
    final rowChipStyle = _softChipStyle(
      padding: const EdgeInsets.symmetric(vertical: 4),
    );

    const labelStyle = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w500,
    );

    final moreMenuItems = <Widget>[
      _menuChip(
        label: '打开方式',
        style: chipStyle,
        onPressed: canOpenWith ? _openWithApp : null,
      ),
      _menuChip(
        label: openNewPageLabel,
        style: chipStyle,
        onPressed: canOpenNewPage ? _openSelectedInNewPage : null,
      ),
      _menuChip(
        label: 'MD5对比',
        style: chipStyle,
        onPressed: canMd5 ? _md5Compare : null,
      ),
      // 任意选中数都成立，保证「⋯」永远不会是一个全灰的空菜单。
      _menuChip(
        label: '反选',
        style: chipStyle,
        onPressed: _invertSelection,
      ),
    ];

    return SafeArea(
      child: Container(
        // 不再画顶部那条 outlineVariant 分割线：
        // 边界交给 _buildBottomOverlay 的羽化带去做，这里保持纯色块。
        color: s.brightness == Brightness.light ? Colors.white : s.surface,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 第一行：对比 + 简洁对比 + 复制路径 + 分享 + 「⋯」。
            // 按 flex 20 : 20 : 16 : 16 : 10 分配（合计 82 份），
            // 按钮随屏幕变宽变窄、始终铺满第一行，不再横向滚动。
            SizedBox(
              height: 38,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    flex: 20,
                    child: FilledButton.icon(
                      icon: const Icon(Icons.compare_arrows, size: 16),
                      label: const Text(
                        '对比',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      // 默认皮肤：原淡底蓝字 → 反色为实色蓝底 + 浅字，与「反选 / 打开方式」
                      // 菜单项区分开、强调主操作；自定义皮肤保持原样（已是实色蓝底）。
                      //
                      // 字色写死白色：默认皮肤的 onPrimary 是深蓝（#0B2A55），
                      // 压在浅蓝底（#6FA9F0）上发闷、像没点亮的按钮；
                      // 自定义皮肤的底色也偏深，onPrimary 同样读不清。
                      // 主操作按钮要的是「一眼看到能点」，统一白字。
                      style: FilledButton.styleFrom(
                        backgroundColor: isDefaultSkin ? s.primary : null,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: canCompare ? _startCompare : null,
                    ),
                  ),
                  const SizedBox(width: 3),
                  Expanded(
                    flex: 20,
                    child: OutlinedButton(
                      style: rowChipStyle,
                      onPressed: canCompare ? _startQuickCompare : null,
                      child: const Text(
                        '简洁对比',
                        style: labelStyle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  const SizedBox(width: 3),
                  Expanded(
                    flex: 16,
                    child: OutlinedButton(
                      style: rowChipStyle,
                      onPressed: canCopyPath ? _copyPath : null,
                      child: const Text(
                        '复制路径',
                        style: labelStyle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  const SizedBox(width: 3),
                  Expanded(
                    flex: 16,
                    child: OutlinedButton(
                      style: rowChipStyle,
                      onPressed: canShare ? _shareSelected : null,
                      child: const Text(
                        '分享',
                        style: labelStyle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  const SizedBox(width: 3),
                  Expanded(
                    flex: 10,
                    child: Tooltip(
                      message: '更多',
                      child: OutlinedButton(
                        key: _bottomMoreAnchorKey,
                        style: rowChipStyle,
                        onPressed: () => _showFloatingMenu(
                          anchorKey: _bottomMoreAnchorKey,
                          above: true,
                          items: moreMenuItems,
                        ),
                        child: const Icon(Icons.more_horiz, size: 18),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: _wideAction(
                    icon: Icons.info_outline,
                    label: '属性',
                    onPressed: canProps ? _showProperties : null,
                  ),
                ),
                Expanded(
                  child: _wideAction(
                    icon: Icons.drive_file_rename_outline,
                    label: '重命名',
                    onPressed: canRename ? _rename : null,
                  ),
                ),
                Expanded(
                  child: _wideAction(
                    icon: Icons.drive_file_move_outline,
                    label: '移动',
                    onPressed: canMove ? _move : null,
                  ),
                ),
                Expanded(
                  child: _wideAction(
                    icon: Icons.copy_all_outlined,
                    label: '复制',
                    onPressed: canCopy ? _copy : null,
                  ),
                ),
                Expanded(
                  child: _wideAction(
                    icon: Icons.delete_outline,
                    label: '删除',
                    color: canDelete ? s.error : null,
                    onPressed: canDelete ? _delete : null,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _wideAction({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
    Color? color,
  }) {
    final disabled = onPressed == null;
    // 与第一行的 OutlinedButton 保持同一套配色：默认皮肤用主题蓝，其他皮肤用正文色。
    final isDefaultSkin = ref.watch(skinProvider) == AppSkin.defaultBlue;
    final s = Theme.of(context).colorScheme;
    final c = disabled
        ? Theme.of(context).disabledColor
        : (color ?? (isDefaultSkin ? s.primary : s.onSurface));
    return InkWell(
      onTap: onPressed,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: c),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: c,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ==================== 主体 ====================

  Widget _buildBody() {
    return AnimatedSwitcher(
      key: ValueKey('switcher_$_bodyRevision'),
      duration: const Duration(milliseconds: 180),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: child,
      ),
      child: _buildBodyState(),
    );
  }

  // ==================== 列表之上的覆盖层（滚动条 / 悬浮翻页按钮） ====================
  //
  // 不改文件浏览器本身的滚动实现，只在外面盖一层：
  //   · 可拖动滚动条（默认关）
  //   · 上下悬浮翻页按钮（默认关）

  Widget _buildBodyWithOverlays() {
    final scrollbarOn = ref.watch(browserScrollbarEnabledProvider);
    final floatingOn = ref.watch(browserFloatingPageEnabledProvider);
    final body = _buildBody();
    if (!scrollbarOn && !floatingOn) return body;
    return Stack(
      fit: StackFit.expand,
      children: [
        body,
        if (scrollbarOn) _buildBrowserScrollbar(),
        if (floatingOn) _buildFloatingPageOverlay(),
      ],
    );
  }

  Widget _buildBrowserScrollbar() {
    final track = ref.watch(browserScrollbarTrackColorProvider);
    final thumb = ref.watch(browserScrollbarThumbColorProvider);
    final opacity = (ref.watch(browserScrollbarOpacityProvider) / 100)
        .clamp(0.0, 1.0)
        .toDouble();
    final width = ref
        .watch(browserScrollbarWidthProvider)
        .clamp(2.0, 28.0)
        .toDouble();

    return Positioned(
      top: 2,
      bottom: 2,
      right: 0,
      width: math.max(width + 12, 24),
      child: _BrowserScrollbar(
        positions: _positionsListener.itemPositions,
        itemCount: () => _scrollItemCount,
        thumbWidth: width,
        trackColor: track.withValues(alpha: opacity * 0.35),
        thumbColor: thumb.withValues(alpha: opacity),
        onJump: _jumpToIndex,
      ),
    );
  }

  Widget _buildFloatingPageOverlay() {
    final color = ref.watch(browserFloatingPageColorProvider);
    final opacity = (ref.watch(browserFloatingPageOpacityProvider) / 100)
        .clamp(0.0, 1.0)
        .toDouble();
    final size = ref
        .watch(browserFloatingPageSizeProvider)
        .clamp(28.0, 88.0)
        .toDouble();
    final upX = ref.watch(browserFloatingPageUpXProvider);
    final upY = ref.watch(browserFloatingPageUpYProvider);
    final downX = ref.watch(browserFloatingPageDownXProvider);
    final downY = ref.watch(browserFloatingPageDownYProvider);

    return Positioned.fill(
      child: LayoutBuilder(
        builder: (ctx, c) {
          Widget btn({
            required double x,
            required double y,
            required bool up,
          }) {
            final left =
                (c.maxWidth - size) * (x.clamp(0.0, 100.0).toDouble() / 100);
            final top =
                (c.maxHeight - size) * (y.clamp(0.0, 100.0).toDouble() / 100);
            return Positioned(
              left: left,
              top: top,
              width: size,
              height: size,
              child: _BrowserFloatingPageButton(
                size: size,
                color: color.withValues(alpha: opacity),
                up: up,
                onTap: up ? _pageUp : _pageDown,
              ),
            );
          }

          return Stack(
            children: [
              btn(x: upX, y: upY, up: true),
              btn(x: downX, y: downY, up: false),
            ],
          );
        },
      ),
    );
  }

  /// 跳到指定条目（顶部对齐）。
  void _jumpToIndex(int index) {
    if (!_itemScrollController.isAttached) return;
    final count = _scrollItemCount;
    if (count <= 0) return;
    try {
      _itemScrollController.jumpTo(
        index: index.clamp(0, count - 1).toInt(),
        alignment: 0,
      );
    } catch (_) {}
  }

  /// 当前可见区间的首/末条目索引与可见条目数。
  _VisibleRange _visibleRange() {
    var first = -1;
    var last = -1;
    var visible = 0;
    for (final p in _positionsListener.itemPositions.value) {
      if (p.itemTrailingEdge > 0 && p.itemLeadingEdge < 1) {
        visible++;
        if (first < 0 || p.index < first) first = p.index;
        if (p.index > last) last = p.index;
      }
    }
    return _VisibleRange(first: first, last: last, visible: visible);
  }

  /// 向下翻一页：上一页最后一个文件仍显示在最上面。
  void _pageDown() {
    final r = _visibleRange();
    if (r.last < 0) return;
    _jumpToIndex(r.last);
  }

  /// 向上翻一页。
  void _pageUp() {
    final r = _visibleRange();
    if (r.first <= 0) return;
    final step = r.visible > 1 ? r.visible - 1 : 1;
    _jumpToIndex(r.first - step);
  }

  Widget _keyed(String k, Widget child) =>
      KeyedSubtree(key: ValueKey(k), child: child);

  Widget _buildBodyState() {
    // 先清零，下面各列表构建时再写入真实条目数。
    _scrollItemCount = 0;

    if (_searchActive) {
      return _keyed('search', _buildSearchResultsList());
    }

    if (_showSkeleton) {
      return const _LoadingSkeleton(key: ValueKey('skeleton'));
    }

    if (_loading) {
      // 180ms 延迟窗口内：什么都不显示，避免闪烁
      return const SizedBox.shrink(key: ValueKey('blank'));
    }

    if (_error != null) {
      return _keyed(
        'error',
        Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 48),
                const SizedBox(height: 12),
                Text('无法访问目录：\n$_error', textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton(onPressed: _load, child: const Text('重试')),
              ],
            ),
          ),
        ),
      );
    }

  final entries = _entries ?? const <EntryInfo>[];
    if (entries.isEmpty) {
      final cs = Theme.of(context).colorScheme;
      return _keyed(
        'empty',
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.folder_open_outlined,
                size: 64,
                color: cs.onSurfaceVariant.withValues(alpha: 0.5),
              ),
              const SizedBox(height: 12),
              Text(
                '这里还没有文件',
                style: TextStyle(
                  fontSize: 14,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }

  final mode = ref.read(searchBoxModeProvider);
  if (mode == SearchBoxMode.filter &&
      _searchCtrl.text.trim().isNotEmpty) {
    final items = _visibleItems ?? const <_DisplayItem>[];
    if (items.isEmpty) {
      return _keyed('nomatch', const Center(child: Text('无匹配')));
    }
  }

  return _keyed(
    'content',
    ref.watch(browserGridModeProvider)
        ? _buildGridBody(_filterEntries(entries))
        : _buildListBody(),
  );
}
  // ==================== 列表模式（无粘性头部） ====================

Widget _buildListBody() {
  final fontName = ref.watch(browserFontListNameProvider);
  final fontMeta = ref.watch(browserFontListMetaProvider);
  final colorScheme = Theme.of(context).colorScheme;
  final scrollbarOn = ref.watch(browserScrollbarEnabledProvider);

  final items = _visibleItems ?? const <_DisplayItem>[];
  // 选中模式下底栏是 Stack 覆盖层，不占布局；
  // 在列表末尾补一段滚动留白，让最后一个文件能滚出底栏遮挡。
  // 留白在滚动内容末尾，不改变可视区高度，进入/退出选中模式内容不跳。
  final extra = _selectionMode ? 1 : 0;
  _scrollItemCount = items.length + extra;
  final initial = _initialScrollIndex;
  _initialScrollIndex = null; // 消费一次：仅本次挂载用，下次 build 传 0。
  final list = ScrollablePositionedList.builder(
    key: ValueKey('list_${_currentPath}_$_listGeneration'),
    initialScrollIndex: initial ?? 0,
    itemScrollController: _itemScrollController,
    itemPositionsListener: _positionsListener,
    itemCount: items.length + extra,
    itemBuilder: (ctx, i) {
      if (i >= items.length) {
        return SizedBox(
          height: MediaQuery.of(context).padding.bottom + 110,
        );
      }
      final item = items[i];
      return RepaintBoundary(
        key: ValueKey('rb_${item.key}'),
        child: _buildDisplayItemTile(item, fontName, fontMeta, colorScheme),
      );
    },
  );
  // 自定义可拖动滚动条开启时，默认 Scrollbar 就关掉，避免两条并存。
  return scrollbarOn ? list : Scrollbar(child: list);
}

  /// 行的底色。优先级：选中 > 定位闪烁 > 刚访问过 > 默认（透明）。
  ///
  /// 「刚访问过」用主题主色的淡底，不用黄色——黄色在这一屏里已经被
  /// 「查重扫描范围」等提示占用了，而且和收藏的琥珀色容易混。
  /// 淡蓝底 + 左侧一条竖杠，扫一眼就知道刚才在哪，又不抢选中态。
  Color? _rowBgFor(String key, bool selected, ColorScheme cs) {
    if (selected) return cs.primary.withValues(alpha: 0.14);
    if (_flashPath == key) return cs.primary.withValues(alpha: 0.10);
    if (_lastVisitedPath == key) {
      // 渐隐：_visitedFade 1→0，底色随之由 0.10 变到 0。
      // 0.10 比选中态的 0.14 浅一档，不抢选中。
      return cs.primary.withValues(alpha: 0.10 * _visitedFade.value);
    }
    return null;
  }

  /// 「刚访问过」的左侧竖杠。选中态已经够醒目，不再叠一层。
  bool _showVisitedMark(String key, bool selected) =>
      !selected && _lastVisitedPath == key;

  /// 竖杠本体：贴着行左边，只留左侧两个圆角，和行的圆角对齐。
  /// 随 [_visitedFade] 一起变浅，和底色同步消失。
  Widget _visitedMarkBar(ColorScheme cs) {
    final a = 0.85 * _visitedFade.value;
    return Positioned(
      left: 0,
      top: 0,
      bottom: 0,
      child: Container(
        width: 3,
        decoration: BoxDecoration(
          color: cs.primary.withValues(alpha: a),
          borderRadius: const BorderRadius.horizontal(
            left: Radius.circular(10),
          ),
        ),
      ),
    );
  }

  /// 渲染一个 display item。磁盘项、zip 头、zip 内项各有不同样式。
  ///
  /// ★ 改动点：整行用 Listener 记录点击的 x 坐标。
  ///   左侧图标区（宽度 48 + depth*18）点 = 选中/取消；
  ///   其它区点 = 打开（或选择模式下切换选中）。
  Widget _buildDisplayItemTile(
    _DisplayItem item,
    double fontName,
    double fontMeta,
    ColorScheme colorScheme,
  ) {
    // loading / error 提示行
    if (item.key.startsWith('__loading__')) {
      return Padding(
        padding: EdgeInsets.only(
          left: 8.0 + item.depth * 18.0,
          right: 12,
          top: 8,
          bottom: 8,
        ),
        child: Row(
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Text(
              item.displayName,
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }
    if (item.key.startsWith('__error__')) {
      return Padding(
        padding: EdgeInsets.only(
          left: 8.0 + item.depth * 18.0,
          right: 12,
          top: 8,
          bottom: 8,
        ),
        child: Row(
          children: [
            Icon(Icons.warning_amber,
                size: 16, color: colorScheme.error),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                item.displayName,
                style: TextStyle(fontSize: 12, color: colorScheme.error),
              ),
            ),
          ],
        ),
      );
    }

    final selected = _selectedPaths.contains(item.key);
    final compact = ref.watch(browserListCompactProvider);

    // 左侧图标区宽度（含缩进）。点这块 = 选中/取消。
    final iconZoneRight = (compact ? 36.0 : 48.0) + item.depth * 18.0;

    // zip 头（顶层或嵌套）：和普通文件一样的 ListTile，
    // 右侧箭头表示展开/折叠状态。
if (item.isZip) {
  final isExpanded = _expandedZipKeys.contains(item.key);
  final isTopLevel = item.ownerZipKey == null;
  final metaLine = _buildItemMetaLine(item);

return Listener(
  onPointerDown: (e) => _lastTapX = e.localPosition.dx,
  child: Container(
    margin: EdgeInsets.symmetric(horizontal: 6, vertical: compact ? 1 : 2),
    decoration: BoxDecoration(
      color: _rowBgFor(item.key, selected, colorScheme),
      borderRadius: BorderRadius.circular(10),
    ),
  child: Stack(
    children: [
  ListTile(
      dense: true,
  visualDensity: const VisualDensity(horizontal: 0, vertical: 0),
      contentPadding: EdgeInsets.only(
  left: item.depth * 18.0,
  right: 8,
  top: compact ? 1 : 4,
  bottom: compact ? 1 : 4,
),
leading: SizedBox(
  width: compact ? 36 : 48,
  child: Padding(
    padding: EdgeInsets.only(left: compact ? 4 : 8),
    child: Center(
      child: AppFileIcon(
        isDir: true,
        isZip: true,
        size: compact ? 20 : 24,
        tint: isTopLevel
            ? null
            : colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
      ),
    ),
  ),
),
      title: Text(
        item.displayName,
        maxLines: compact ? 1 : 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: fontName,
          fontWeight: FontWeight.w400,
          height: compact ? 1.15 : 1.3,
        ),
      ),
      subtitle: metaLine.isEmpty
          ? null
          : Text(
              metaLine,
              style: TextStyle(
                fontSize: fontMeta,
                color: colorScheme.onSurfaceVariant,
                height: 1.3,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      // 图标不再是「空心/实心」两态，用箭头保留展开状态。
      trailing: _encryptedNestedZipKeys.contains(item.key)
          ? Icon(Icons.lock_outline,
              size: 18, color: colorScheme.error)
          : Icon(
              isExpanded
                  ? Icons.keyboard_arrow_up
                  : Icons.keyboard_arrow_down,
              size: 18,
              color: colorScheme.onSurfaceVariant,
            ),
      onTap: () {
        // ★ 左侧图标区点 = 选中/取消
        if (_lastTapX < iconZoneRight) {
          _toggleSelectionByKey(item.key);
          return;
        }
        if (_selectionMode) {
          _toggleSelectionByKey(item.key);
          return;
        }
        _handleTapItem(item);
      },
      onLongPress: () => _onLongPressItem(item),
    ),
      if (_showVisitedMark(item.key, selected)) _visitedMarkBar(colorScheme),
    ],
  ),
  ),
);
}

    // zip 内目录
    if (item.isZipInner && item.isDir) {
      return Padding(
        padding: EdgeInsets.only(
          left: 8.0 + item.depth * 18.0,
          right: 12,
          top: compact ? 4 : 7,
          bottom: compact ? 4 : 7,
        ),
        child: Row(
          children: [
            const SizedBox(width: 22),
            const AppFileIcon(isDir: true, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                item.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: fontName - 1,
                  color: colorScheme.onSurface,
                ),
              ),
            ),
          ],
        ),
      );
    }

    // 通用文件行（磁盘文件 或 zip 内文件）
    final isZipInner = item.isZipInner;
    final metaLine = _buildItemMetaLine(item);

return Listener(
  onPointerDown: (e) => _lastTapX = e.localPosition.dx,
  child: Container(
    margin: EdgeInsets.symmetric(horizontal: 6, vertical: compact ? 1 : 2),
    decoration: BoxDecoration(
      color: _rowBgFor(item.key, selected, colorScheme),
      borderRadius: BorderRadius.circular(10),
    ),
  child: Stack(
    children: [
  ListTile(
  dense: true,
  visualDensity: const VisualDensity(horizontal: 0, vertical: 0),

  contentPadding: EdgeInsets.only(
        left: item.depth * 18.0,
        right: 8,
        top: compact ? 1 : 4,
        bottom: compact ? 1 : 4,
      ),
      leading: SizedBox(
        width: compact ? 36 : 48,
        child: Padding(
          padding: EdgeInsets.only(left: compact ? 4 : 8),
          child: Center(
            child: AppFileIcon(
              isDir: item.isDir,
              size: compact ? 20 : 24,
              tint: isZipInner
                  ? colorScheme.onSurfaceVariant.withValues(alpha: 0.6)
                  : null,
            ),
          ),
        ),
      ),
        title: Text(
          item.displayName,
          maxLines: compact ? 1 : 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: fontName,
            fontWeight: FontWeight.w400,
            height: compact ? 1.15 : 1.3,
            color: isZipInner
                ? colorScheme.onSurface.withOpacity(0.85)
                : null,
          ),
        ),
        subtitle: metaLine.isEmpty
            ? null
            : Text(
                metaLine,
                style: TextStyle(
                  fontSize: fontMeta,
                  color: colorScheme.onSurfaceVariant,
                  height: 1.3,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
        onTap: () {
          // ★ 左侧图标区点 = 选中/取消
          if (_lastTapX < iconZoneRight) {
            _toggleSelectionByKey(item.key);
            return;
          }
          if (_selectionMode) {
            _toggleSelectionByKey(item.key);
            return;
          }
          _handleTapItem(item);
        },
        onLongPress: () => _onLongPressItem(item),
      ),
      if (_showVisitedMark(item.key, selected)) _visitedMarkBar(colorScheme),
    ],
  ),
    ),
  );
  }

  String _buildItemMetaLine(_DisplayItem item) {
    final parts = <String>[];
    if (item.size != null && !item.isDir) {
      final s = _formatSize(item.size);
      if (s.isNotEmpty) parts.add(s);
    }
    if (item.modified != null) {
      parts.add(_formatTime(item.modified));
    }
    return parts.join(' · ');
  }

  // ==================== 网格模式（不支持 zip 展开） ====================

  Widget _buildGridBody(List<EntryInfo> entries) {
    final showSize = ref.watch(browserGridShowSizeProvider);
    final showTime = ref.watch(browserGridShowTimeProvider);
    final fontName = ref.watch(browserFontGridNameProvider);
    final fontMeta = ref.watch(browserFontGridMetaProvider);
    final scrollbarOn = ref.watch(browserScrollbarEnabledProvider);

    final rowCount = (entries.length + 1) ~/ 2;
    // 选中模式下底栏是覆盖层，网格末尾同样补一段滚动留白。
    final extraRow = _selectionMode ? 1 : 0;
    _scrollItemCount = rowCount + extraRow;

    final initial = _initialScrollIndex;
    _initialScrollIndex = null; // 消费一次：仅本次挂载用，下次 build 传 0。
    final list = ScrollablePositionedList.builder(
      key: ValueKey('grid_${_currentPath}_$_listGeneration'),
      initialScrollIndex: initial ?? 0,
      itemScrollController: _itemScrollController,
      itemPositionsListener: _positionsListener,
      itemCount: rowCount + extraRow,
      itemBuilder: (ctx, rowIdx) {
        if (rowIdx >= rowCount) {
          return SizedBox(
            height: MediaQuery.of(context).padding.bottom + 110,
          );
        }
        final leftIdx = rowIdx * 2;
        final rightIdx = leftIdx + 1;

        final leftInfo = entries[leftIdx];
        final rightInfo =
            rightIdx < entries.length ? entries[rightIdx] : null;

        final leftWidget = _buildGridCell(
          info: leftInfo,
          showSize: showSize,
          showTime: showTime,
          fontName: fontName,
          fontMeta: fontMeta,
        );

        final rightWidget = rightInfo == null
            ? const SizedBox.shrink()
            : _buildGridCell(
                info: rightInfo,
                showSize: showSize,
                showTime: showTime,
                fontName: fontName,
                fontMeta: fontMeta,
              );

        return RepaintBoundary(
          key: ValueKey('rb_grid_$rowIdx'),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: leftWidget),
                Container(
                  width: _gridDividerThickness,
                  color: _gridDividerColorOf(context),
                ),
                Expanded(child: rightWidget),
              ],
            ),
          ),
        );
      },
    );
    return scrollbarOn ? list : Scrollbar(child: list);
  }

  Widget _buildGridCell({
    required EntryInfo info,
    required bool showSize,
    required bool showTime,
    required double fontName,
    required double fontMeta,
  }) {
    final e = info.entity;
    final selected = _selectedPaths.contains(e.path);
    final colorScheme = Theme.of(context).colorScheme;

    final metaParts = <String>[];
    if (showSize && !info.isDir && info.size != null) {
      metaParts.add(_formatSize(info.size));
    }
    if (showTime && info.modified != null) {
      metaParts.add(_formatGridTime(info.modified!));
    }
    final metaLine = metaParts.join(' · ');

    final displayItem = _displayItemForEntry(info);

    return GestureDetector(
      onTap: () {
        if (_selectionMode) {
          _toggleSelectionByKey(e.path);
          return;
        }
        if (info.isDir) {
          _navigateTo(e.path);
        } else {
          _openFile(e.path, info.name, info.size, allowExpand: false);
        }
      },
      onLongPress: () => _onLongPressItem(displayItem),
      child: Container(
        decoration: BoxDecoration(
          // 背景只保留选中态，和列表模式一致；
          // 文本/二进制靠图标颜色区分，灰底属于隐式规则。
          color: _rowBgFor(e.path, selected, colorScheme),
        ),
        foregroundDecoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: _gridDividerColorOf(context),
              width: _gridDividerThickness,
            ),
          ),
        ),
        padding: EdgeInsets.symmetric(
          horizontal: _gridCellPadH,
          vertical: _gridCellPadV,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _toggleSelectionByKey(e.path),
                  onLongPress: () => _onLongPressItem(displayItem),
                  child: Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: Center(
                        child: AppFileIcon(
                          isDir: info.isDir,
                          size: 16,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(child: _buildGridName(info, fontName)),
              ],
            ),
            if (metaLine.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                metaLine,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: fontMeta,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 网格长按需要的 item 解析逻辑，图标/整格手势共用一份。
  _DisplayItem _displayItemForEntry(EntryInfo info) {
    final all = _cachedDisplayItems ?? const <_DisplayItem>[];
    return all.firstWhere(
      (x) => x.key == info.entity.path,
      orElse: () => _DisplayItem(
        key: info.entity.path,
        displayName: info.name,
        depth: 0,
      ),
    );
  }

  Widget _buildGridName(EntryInfo info, double fontSize) {
    if (info.isDir) {
      return Text(
        '/${info.name}/',
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w400,
          height: 1.3,
        ),
      );
    }
    // 粗细与列表模式对齐：文件夹和文件都用常规字重。
    return Text(
      info.name,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: fontSize,
        fontWeight: FontWeight.w400,
        height: 1.3,
      ),
    );
  }

  // ==================== 搜索结果列表（无粘性头部） ====================

  Widget _buildSearchResultsList() {
    if (_searchResults.isEmpty) {
  return Center(
    child: Text(
      _searchCtrl.text.trim().isEmpty
          ? '请输入关键词后搜索'
          : (_searching ? '正在扫描...' : '未找到匹配'),
    ),
  );
}
    final colorScheme = Theme.of(context).colorScheme;
    final fontName = ref.watch(browserFontListNameProvider);
    final fontMeta = ref.watch(browserFontListMetaProvider);
    final scrollbarOn = ref.watch(browserScrollbarEnabledProvider);

    final items = _cachedDisplayItems ?? const <_DisplayItem>[];
    // 选中模式下底栏是覆盖层，搜索结果列表末尾同样补滚动留白。
    final extra = _selectionMode ? 1 : 0;
    _scrollItemCount = items.length + extra;
    // 搜索结果始终从头开始；消费掉可能残留的 _initialScrollIndex，
    // 避免退出搜索后泄漏到主列表导致莫名跳位。
    _initialScrollIndex = null;

    final list = ScrollablePositionedList.builder(
      itemScrollController: _itemScrollController,
      itemPositionsListener: _positionsListener,
      itemCount: items.length + extra,
      itemBuilder: (ctx, i) {
        if (i >= items.length) {
          return SizedBox(
            height: MediaQuery.of(context).padding.bottom + 110,
          );
        }
        final item = items[i];
        return RepaintBoundary(
          key: ValueKey('rb_search_${item.key}'),
          child: _buildSearchResultTile(item, fontName, fontMeta, colorScheme),
        );
      },
    );
    return scrollbarOn ? list : Scrollbar(child: list);
  }

  /// 搜索结果模式的列表项渲染（跟普通列表不同：显示路径副标题）。
  ///
  /// ★ 改动点：整行用 Listener 记录点击的 x 坐标。
  ///   左侧图标区（宽度 48 + depth*18）点 = 选中/取消；
  ///   其它区点 = 打开（或选择模式下切换选中）。
  Widget _buildSearchResultTile(
    _DisplayItem item,
    double fontName,
    double fontMeta,
    ColorScheme colorScheme,
  ) {
    if (item.key.startsWith('__loading__') ||
        item.key.startsWith('__error__')) {
      return _buildDisplayItemTile(item, fontName, fontMeta, colorScheme);
    }

    if (item.isZipInner && item.isDir) {
      return _buildDisplayItemTile(item, fontName, fontMeta, colorScheme);
    }

    final selected = _selectedPaths.contains(item.key);
    final isZipInner = item.isZipInner;
    final metaLine = _buildItemMetaLine(item);
    final pathLine = isZipInner
        ? item.fullDisplayPath
        : (item.diskPath ?? '');

    final compact = ref.watch(browserListCompactProvider);

    // 左侧图标区宽度（含缩进）。点这块 = 选中/取消。
    final iconZoneRight = (compact ? 36.0 : 48.0) + item.depth * 18.0;

    return Listener(
      onPointerDown: (e) => _lastTapX = e.localPosition.dx,
      child: Container(
        margin: EdgeInsets.symmetric(horizontal: 6, vertical: compact ? 1 : 2),
        decoration: BoxDecoration(
          color: selected
              ? colorScheme.primary.withValues(alpha: 0.14)
              : null,
          borderRadius: BorderRadius.circular(10),
        ),
        child: ListTile(
          dense: true,
          isThreeLine: true,
          visualDensity: const VisualDensity(horizontal: 0, vertical: 0),
          contentPadding: EdgeInsets.only(
            left: item.depth * 18.0,
            right: 8,
            top: compact ? 1 : 4,
            bottom: compact ? 1 : 4,
          ),
          leading: SizedBox(
            width: compact ? 36 : 48,
            child: Padding(
              padding: EdgeInsets.only(left: compact ? 4 : 8, top: compact ? 2 : 4),
              child: Align(
                alignment: Alignment.topCenter,
                child: item.isZip
                    ? AppFileIcon(
                        isDir: true,
                        isZip: true,
                        size: compact ? 20 : 24,
                        tint: isZipInner
                            ? colorScheme.onSurfaceVariant
                                .withValues(alpha: 0.6)
                            : null,
                      )
                    : AppFileIcon(
                        isDir: item.isDir,
                        size: compact ? 20 : 24,
                        tint: isZipInner
                            ? colorScheme.onSurfaceVariant
                                .withValues(alpha: 0.6)
                            : null,
                      ),
              ),
            ),
          ),
          title: Text(
            item.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: fontName,
              fontWeight: FontWeight.w400,
              height: 1.3,
              color: isZipInner
                  ? colorScheme.onSurface.withOpacity(0.85)
                  : null,
            ),
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (metaLine.isNotEmpty)
                Text(
                  metaLine,
                  style: TextStyle(
                    fontSize: fontMeta,
                    color: colorScheme.onSurfaceVariant,
                    height: 1.3,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              Text(
                pathLine,
                style: TextStyle(
                  fontSize: fontMeta,
                  color: colorScheme.onSurfaceVariant,
                  height: 1.3,
                ),
                softWrap: true,
              ),
            ],
          ),
          onTap: () {
            // ★ 左侧图标区点 = 选中/取消
            if (_lastTapX < iconZoneRight) {
              _toggleSelectionByKey(item.key);
              return;
            }
            if (_selectionMode) {
              _toggleSelectionByKey(item.key);
              return;
            }
            _handleTapItem(item);
          },
          onLongPress: () => _onLongPressItem(item),
        ),
      ),
    );
  }
}

// ==================== 辅助 Widget ====================

/// 悬浮菜单的滚动容器：内容超出可用高度时可滚动，
/// 滚动过程中出现滚动条，避免「看不出还有更多项」。
class _FloatingMenuScroller extends StatefulWidget {
  const _FloatingMenuScroller({required this.child});

  final Widget child;

  @override
  State<_FloatingMenuScroller> createState() => _FloatingMenuScrollerState();
}

class _FloatingMenuScrollerState extends State<_FloatingMenuScroller> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      controller: _controller,
      child: SingleChildScrollView(
        controller: _controller,
        child: widget.child,
      ),
    );
  }
}

const EdgeInsets _dlgInsetG = EdgeInsets.all(4);
const EdgeInsets _dlgTitlePadG = EdgeInsets.fromLTRB(12, 8, 12, 0);
const EdgeInsets _dlgContentPadG = EdgeInsets.fromLTRB(8, 4, 8, 4);
const EdgeInsets _dlgActionsPadG = EdgeInsets.fromLTRB(4, 0, 4, 4);

class _TextInputDialog extends StatefulWidget {
  const _TextInputDialog({
    required this.title,
    required this.initialValue,
  });

  final String title;
  final String initialValue;

  @override
  State<_TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<_TextInputDialog> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(
        horizontal: 32,
        vertical: 24,
      ),
      title: Text(widget.title),
      content: SizedBox(
        width: 320,
        child: TextField(
          controller: _ctrl,
          autofocus: true,
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(
            isDense: true,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: cs.primary, width: 1.5),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 12,
            ),
          ),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _ctrl.text),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

// ==================== 批量重命名：弹窗 ====================

typedef _RenameItem = ({
  String oldPath,
  String oldName,
  String parent,
  bool isDir
});

class _BatchRenameDialog extends StatefulWidget {
  const _BatchRenameDialog({
    required this.paths,
    this.orderHint = const [],
  });

  final List<String> paths;

  /// 这些文件在文件浏览器当前列表里的显示顺序（用于「列表顺序」）。
  /// 不在里面的文件会排在后面，保持原有选择顺序。
  final List<String> orderHint;

  @override
  State<_BatchRenameDialog> createState() => _BatchRenameDialogState();
}

class _BatchRenameDialogState extends State<_BatchRenameDialog> {
  late _RenameConfig _cfg;
  late final List<_RenameItem> _items;

  // 文本 controller 全部提到 State，避免每次 build 新建导致光标跳动
  late final TextEditingController _findCtrl;
  late final TextEditingController _replaceCtrl;
  late final TextEditingController _prefixCtrl;
  late final TextEditingController _suffixCtrl;
  late final TextEditingController _extCtrl;
  late final TextEditingController _insertTextCtrl;
  late final TextEditingController _fullNameCtrl;
  late final TextEditingController _fullNameFormatCtrl;

  // 整数 / 分隔符 controller 也提到 State（方案原只提了文本，漏了这 7 个）
  late final TextEditingController _seqStartCtrl;
  late final TextEditingController _seqStepCtrl;
  late final TextEditingController _seqWidthCtrl;
  late final TextEditingController _insertPosCtrl;
  late final TextEditingController _deleteStartCtrl;
  late final TextEditingController _deleteLenCtrl;
  late final TextEditingController _seqSepCtrl;
  late final TextEditingController _dateFmtCtrl;
  late final TextEditingController _datePosCtrl;

  /// 用户是否在「读 prefs 期间」动过任何控件。动过就不覆盖，避免把刚输入的内容冲掉。
  bool _touched = false;

  /// 手动微调后的顺序（仅 orderMode == custom 时生效）。
  List<String> _manualOrder = const [];

  /// 浏览器列表顺序的排名（initState 里按 orderHint 建一次）。
  late final Map<String, int> _browserRank;

  /// 修改时间 / 大小缓存，避免排序时反复 stat。
  final Map<String, ({DateTime? modified, int size})> _statCache = {};

  @override
  void initState() {
    super.initState();
    _cfg = _RenameConfig(); // 先给默认值，UI 立刻能画

    _items = widget.paths.map((p) {
      final idx = p.lastIndexOf('/');
      final isDir = Directory(p).existsSync();
      return (
        oldPath: p,
        oldName: p.substring(idx + 1),
        parent: p.substring(0, idx),
        isDir: isDir,
      );
    }).toList();

    _findCtrl = TextEditingController();
    _replaceCtrl = TextEditingController();
    _prefixCtrl = TextEditingController();
    _suffixCtrl = TextEditingController();
    _extCtrl = TextEditingController();
    _insertTextCtrl = TextEditingController();
    _fullNameCtrl = TextEditingController();
    _fullNameFormatCtrl = TextEditingController(
      text: _cfg.fullNameSeqFormat,
    );

    // 浏览器显示顺序的排名：命中的用它在列表里的位置，没命中的接在后面。
    _browserRank = {};
    for (var i = 0; i < widget.orderHint.length; i++) {
      _browserRank[widget.orderHint[i]] = i;
    }
    var tail = widget.orderHint.length;
    for (final it in _items) {
      _browserRank.putIfAbsent(it.oldPath, () => tail++);
    }

    _seqStartCtrl = TextEditingController(text: '${_cfg.sequenceStart}');
    _seqStepCtrl = TextEditingController(text: '${_cfg.sequenceStep}');
    _seqWidthCtrl = TextEditingController(text: '${_cfg.sequenceWidth}');
    _insertPosCtrl = TextEditingController(text: '${_cfg.insertPos}');
    _deleteStartCtrl = TextEditingController(text: '${_cfg.deleteStart}');
    _deleteLenCtrl = TextEditingController(text: '${_cfg.deleteLength}');
    _seqSepCtrl = TextEditingController(text: _cfg.sequenceSeparator);
    _dateFmtCtrl = TextEditingController(text: _cfg.dateFormat);
    _datePosCtrl = TextEditingController(text: '${_cfg.dateInsertPos}');

    _loadSavedConfig(); // 异步读上次配置
  }

  @override
  void dispose() {
    _findCtrl.dispose();
    _replaceCtrl.dispose();
    _prefixCtrl.dispose();
    _suffixCtrl.dispose();
    _extCtrl.dispose();
    _insertTextCtrl.dispose();
    _fullNameCtrl.dispose();
    _fullNameFormatCtrl.dispose();
    _seqStartCtrl.dispose();
    _seqStepCtrl.dispose();
    _seqWidthCtrl.dispose();
    _insertPosCtrl.dispose();
    _deleteStartCtrl.dispose();
    _deleteLenCtrl.dispose();
    _seqSepCtrl.dispose();
    _dateFmtCtrl.dispose();
    _datePosCtrl.dispose();
    super.dispose();
  }

  /// 异步读上次配置，读到后刷 UI。读之前用户已经输入的内容不会丢——
  /// 只要用户在「读 prefs 期间」动过任何控件（文本框/整数框/开关/下拉），就不覆盖。
  Future<void> _loadSavedConfig() async {
    final saved = await _loadRenameConfig();
    if (!mounted) return;

    // _touched 由所有 onChanged 经 _edit() 置位，覆盖文本/整数/开关/下拉所有类型。
    if (_touched) return;

    // 手动顺序是「本次选择」的临时结果，下一次打开没有意义，回到列表顺序。
    if (saved.orderMode == 'custom') saved.orderMode = 'browser';

    setState(() {
      _cfg = saved;
      _syncControllersFromConfig();
    });
  }

  /// 所有用户编辑的统一入口：标记「已改动」并刷新。
  /// _loadSavedConfig 据此判断要不要覆盖用户输入。
  void _edit(void Function() fn) {
    _touched = true;
    setState(fn);
  }

  /// 把配置刷回所有 controller（文本 + 整数 + 分隔符）。
  /// 整数 / 分隔符 controller 已提到 State，这里一并同步，load / 重置时调用。
  void _syncControllersFromConfig() {
    _findCtrl.text = _cfg.findText;
    _replaceCtrl.text = _cfg.replaceText;
    _prefixCtrl.text = _cfg.prefix;
    _suffixCtrl.text = _cfg.suffix;
    _extCtrl.text = _cfg.newExt;
    _insertTextCtrl.text = _cfg.insertText;
    _fullNameCtrl.text = _cfg.fullNameBase;
    _fullNameFormatCtrl.text = _cfg.fullNameSeqFormat;
    _seqStartCtrl.text = '${_cfg.sequenceStart}';
    _seqStepCtrl.text = '${_cfg.sequenceStep}';
    _seqWidthCtrl.text = '${_cfg.sequenceWidth}';
    _insertPosCtrl.text = '${_cfg.insertPos}';
    _deleteStartCtrl.text = '${_cfg.deleteStart}';
    _deleteLenCtrl.text = '${_cfg.deleteLength}';
    _seqSepCtrl.text = _cfg.sequenceSeparator;
    _dateFmtCtrl.text = _cfg.dateFormat;
    _datePosCtrl.text = '${_cfg.dateInsertPos}';
  }

  /// 修改时间 / 大小缓存。stat 失败时返回 null/0，不让排序崩。
  ({DateTime? modified, int size}) _statFor(String path) {
    final cached = _statCache[path];
    if (cached != null) return cached;
    try {
      final st = FileStat.statSync(path);
      final v = (modified: st.modified, size: st.size);
      _statCache[path] = v;
      return v;
    } catch (_) {
      final v = (modified: null as DateTime?, size: 0);
      _statCache[path] = v;
      return v;
    }
  }

  List<_RenameItem> get _orderedItems {
    final list = [..._items];

    int byName(_RenameItem a, _RenameItem b) =>
        a.oldName.toLowerCase().compareTo(b.oldName.toLowerCase());

    switch (_cfg.orderMode) {
      case 'browser':
        list.sort((a, b) {
          final ra = _browserRank[a.oldPath] ?? (1 << 30);
          final rb = _browserRank[b.oldPath] ?? (1 << 30);
          return ra.compareTo(rb);
        });
        break;
      case 'name':
        list.sort(byName);
        break;
      case 'nameDesc':
        list.sort((a, b) => byName(b, a));
        break;
      case 'mtime':
      case 'mtimeDesc':
        list.sort((a, b) {
          final am = _statFor(a.oldPath).modified;
          final bm = _statFor(b.oldPath).modified;
          // 没有修改时间的始终排最后（倒序也不把它翻到最前）。
          if (am == null && bm == null) return byName(a, b);
          if (am == null) return 1;
          if (bm == null) return -1;
          final c = am.compareTo(bm);
          final v = _cfg.orderMode == 'mtimeDesc' ? -c : c;
          return v != 0 ? v : byName(a, b);
        });
        break;
      case 'size':
      case 'sizeDesc':
        list.sort((a, b) {
          final sizeA = _statFor(a.oldPath).size;
          final sizeB = _statFor(b.oldPath).size;
          final c = sizeA.compareTo(sizeB);
          final v = _cfg.orderMode == 'sizeDesc' ? -c : c;
          return v != 0 ? v : byName(a, b);
        });
        break;
      case 'custom':
        final rank = <String, int>{};
        for (var i = 0; i < _manualOrder.length; i++) {
          rank[_manualOrder[i]] = i;
        }
        // 手动顺序里没有的（例如刚重置过）：接在末尾，保持原有顺序。
        final fallback = <String, int>{};
        for (var i = 0; i < list.length; i++) {
          fallback[list[i].oldPath] = _manualOrder.length + i;
        }
        list.sort((a, b) {
          final ra = rank[a.oldPath] ?? fallback[a.oldPath] ?? (1 << 30);
          final rb = rank[b.oldPath] ?? fallback[b.oldPath] ?? (1 << 30);
          return ra.compareTo(rb);
        });
        break;
      default:
        break;
    }
    return list;
  }

  /// 预览里点上/下箭头：交换相邻两项，并自动切到「手动顺序」。
  void _moveOrderedItem(String oldPath, int delta) {
    final ordered = _orderedItems.map((e) => e.oldPath).toList();
    final from = ordered.indexOf(oldPath);
    final to = from + delta;
    if (from < 0 || to < 0 || to >= ordered.length) return;
    setState(() {
      _touched = true;
      final moved = ordered.removeAt(from);
      ordered.insert(to, moved);
      _manualOrder = ordered;
      _cfg.orderMode = 'custom';
    });
  }

  /// 下拉切换排序方式。切到「手动顺序」时，先以当前预览顺序为基准。
  void _setOrderMode(String? mode) {
    if (mode == null) return;
    setState(() {
      _touched = true;
      if (mode == 'custom') {
        _manualOrder = _orderedItems.map((e) => e.oldPath).toList();
      }
      _cfg.orderMode = mode;
    });
  }

  /// 预览：每条 (旧路径, 旧名, 新名, 冲突原因?)。每次 build 重算。
  List<
      ({
        String oldPath,
        String oldName,
        String newName,
        String? conflict,
      })> get _preview {
    final used = <String>{};
    final out = <({
      String oldPath,
      String oldName,
      String newName,
      String? conflict,
    })>[];

    final ordered = _orderedItems;
    for (var i = 0; i < ordered.length; i++) {
      final it = ordered[i];
      final newName = _cfg.renameMode == 'fullName'
          ? _applyFullNameRules(
              it.oldName,
              i,
              _cfg,
              isDir: it.isDir,
              useSequence: ordered.length > 1,
            )
          : _applyRenameRules(it.oldName, i, _cfg, isDir: it.isDir);
      String? conflict;

      if (newName == it.oldName) {
        conflict = null; // 未变，灰显
      } else if (newName.isEmpty ||
          newName.contains('/') ||
          newName == '.' ||
          newName == '..') {
        conflict = '名称非法';
      } else {
        final newFull = '${it.parent}/$newName';
        final exists = FileSystemEntity.typeSync(newFull) !=
            FileSystemEntityType.notFound;
        // 目标确实存在，但它正是本批里另一个正在移动的源文件——
        // 两阶段改名能正确处理，不算冲突（否则链式 a→b、b→c 会被误拦）。
        final isMovingTarget = _items.any((q) => q.oldPath == newFull);
        if (exists && newFull != it.oldPath && !isMovingTarget) {
          conflict = '目标已存在';
        }
        if (used.contains(newFull.toLowerCase())) conflict = '与本批重名';
        used.add(newFull.toLowerCase());
      }

      out.add((
        oldPath: it.oldPath,
        oldName: it.oldName,
        newName: newName,
        conflict: conflict,
      ));
    }
    return out;
  }

  bool get _canSubmit {
    // 整名重命名必须先输入新名字。
    if (_cfg.renameMode == 'fullName' && _cfg.fullNameBase.trim().isEmpty) {
      return false;
    }
    final p = _preview;
    return p.any((e) => e.newName != e.oldName) &&
        p.every((e) => e.conflict == null);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final preview = _preview;
    final conflictCount = preview.where((e) => e.conflict != null).length;

    return AlertDialog(
      insetPadding: const EdgeInsets.all(8),
      titlePadding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      contentPadding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
      actionsPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      title: Row(
        children: [
          Expanded(
            child: Text('批量重命名（${_items.length} 项）'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            onPressed: _resetConfig,
            child: const Text('重置', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.of(context).size.height * 0.72,
        child: Column(
          children: [
            // 规则区：可滚动，占 70%
            Expanded(
              flex: 65,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 全名重命名和下面的规则放在同一页，不跳转、不切换页面。
                    // 开启全名重命名时，下面的规则会变灰并且不参与本次改名。
                    _sectionFullName(),
                    if (_cfg.renameMode == 'fullName') _fullNameNotice(),
                    Opacity(
                      opacity: _cfg.renameMode == 'fullName' ? 0.4 : 1,
                      child: IgnorePointer(
                        ignoring: _cfg.renameMode == 'fullName',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _sectionFindReplace(),
                            _sectionPrefixSuffix(),
                            _sectionSequence(),
                            _sectionExt(),
                            _sectionCase(),
                            _sectionAdvanced(),
                            _sectionDate(),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),

            // 预览区：固定，约占 30%（比原来缩小约 1/5，给规则区腾空间）
            Expanded(
              flex: 27,
              child: _sectionPreview(preview, conflictCount, cs),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _canSubmit ? _submit : null,
          child: const Text('执行'),
        ),
      ],
    );
  }

  void _submit() {
    final result = <String, String>{};
    for (final e in _preview) {
      if (e.newName == e.oldName || e.conflict != null) continue;
      final parent =
          _items.firstWhere((it) => it.oldPath == e.oldPath).parent;
      result[e.oldPath] = '$parent/${e.newName}';
    }
    // 记住这套规则，下次打开自动带上（取消不保存）。
    _saveRenameConfig(_cfg);
    Navigator.pop(context, result);
  }

  /// 一键回到默认规则（不影响已保存的配置，除非用户再点执行）。
  void _resetConfig() {
    setState(() {
      _cfg = _RenameConfig();
      _manualOrder = const [];
      _syncControllersFromConfig();
    });
  }

  // ---------- 规则区：全名重命名 + 各折叠分组 ----------

  /// 开了全名重命名时，提醒下面的规则不参与本次改名（规则仍完整显示，只是变灰）。
  Widget _fullNameNotice() {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 14, color: cs.onSurfaceVariant),
          const SizedBox(width: 6),
          const Expanded(
            child: Text(
              '整名替换已启用：下面的规则本次不生效',
              style: TextStyle(fontSize: 11),
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              minimumSize: const Size(0, 28),
            ),
            onPressed: () => _edit(() => _cfg.renameMode = 'rules'),
            child: const Text('关闭', style: TextStyle(fontSize: 11)),
          ),
        ],
      ),
    );
  }

  /// Windows 文件浏览器式：全部改成「新名字 + 序号」，保留原扩展名。
  Widget _sectionFullName() {
    final hintColor = Theme.of(context).colorScheme.onSurfaceVariant;
    final enabled = _cfg.renameMode == 'fullName';
    return _ExpandableSection(
      title: '新名字 + 序号',
      initiallyExpanded: true,
      helpTitle: '新名字 + 序号（整名替换）',
      helpText: '• 整名替换成「新名字 + 序号」（类似 Windows 里选中一批文件后重命名），'
          '保留原扩展名。\n'
          '• 勾选「启用整名替换」后才生效；启用时下面的规则不参与本次改名。\n'
          '• 序号格式用 {n} 表示序号：({n}) → (1) (2)；-{n} → -1 -2；也能自己写。\n'
          '• 起始 / 步长 / 位数控制序号：位数 1 → (1)，位数 2 → (01)。\n'
          '• 只选一个文件时只改成新名字，不加序号。\n'
          '• 哪个文件是 1：按预览区上方的「序号顺序」，也能用 ↑↓ 微调。',
      children: [
        CheckboxListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('启用整名替换', style: TextStyle(fontSize: 13)),
          subtitle: const Text(
            '整名替换成「新名字 + 序号」，启用后下面的规则不参与',
            style: TextStyle(fontSize: 11),
          ),
          value: enabled,
          onChanged: (v) => _edit(
              () => _cfg.renameMode = (v ?? false) ? 'fullName' : 'rules'),
        ),
        if (enabled)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _fullNameCtrl,
                decoration: const InputDecoration(
                  labelText: '新名字（不含扩展名）',
                  hintText: '例如：旅行照片',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) =>
                    _edit(() => _cfg.fullNameBase = v),
              ),
              const SizedBox(height: 8),
              Text(
                '序号格式（{n} 会替换成序号）',
                style: TextStyle(fontSize: 12, color: hintColor),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final fmt in const [
                    '({n})',
                    '-{n}',
                    '_{n}',
                    '（{n}）',
                    '{n}',
                  ])
                    ChoiceChip(
                      label: Text(
                        fmt.replaceAll('{n}', '1'),
                        style: const TextStyle(fontSize: 12),
                      ),
                      selected: _cfg.fullNameSeqFormat == fmt,
                      onSelected: (_) => _edit(() {
                        _cfg.fullNameSeqFormat = fmt;
                        _fullNameFormatCtrl.text = fmt;
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _fullNameFormatCtrl,
                decoration: const InputDecoration(
                  labelText: '自定义序号格式',
                  hintText: '({n})',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) =>
                    _edit(() => _cfg.fullNameSeqFormat = v),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _intField('起始', _seqStartCtrl,
                        (v) => _edit(() => _cfg.sequenceStart = v)),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: _intField('步长', _seqStepCtrl,
                        (v) => _edit(() => _cfg.sequenceStep = v)),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: _intField('位数', _seqWidthCtrl,
                        (v) => _edit(() => _cfg.sequenceWidth = v)),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '文件保留原扩展名；只选一个文件时不加序号。'
                '位数=1 时序号形如 (1)，位数=2 则是 (01)。'
                '序号顺序在预览区上方选择，也可用 ↑↓ 微调。',
                style: TextStyle(fontSize: 11, color: hintColor),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _sectionFindReplace() {
    return _ExpandableSection(
      title: '查找替换（不改扩展名）',
      initiallyExpanded: true,
      helpTitle: '查找替换（不改扩展名）',
      helpText: '• 只改文件名，扩展名（.txt、.jpg 等）保持原样。\n'
          '• 「查找」填要被替换掉的文字，「替换为」填新文字，命中的部分会全部替换。\n'
          '• 「替换为」留空并执行，就等于删掉查找到的内容。\n'
          '• 勾选「使用正则」后，「查找」按正则表达式匹配，'
          '「替换为」里可用 \$1 \$2 引用第 1、2 个捕获组。\n'
          '• 例：查找 (\\d+) 替换为 第\$1张，IMG2026.jpg → 第2026张.jpg。',
      children: [
        Padding(
          // 顶部留 8：让浮动标签（聚焦时上浮到边框上方）有完整显示空间，
          // 否则会被分组/滚动区域的边缘裁掉一半。
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _findCtrl,
                      decoration: const InputDecoration(
                        labelText: '查找',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (v) => _edit(() => _cfg.findText = v),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: TextField(
                      controller: _replaceCtrl,
                      decoration: const InputDecoration(
                        labelText: '替换为',
                        hintText: '正则可用 \$1',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (v) =>
                          _edit(() => _cfg.replaceText = v),
                    ),
                  ),
                ],
              ),
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('使用正则（替换值可用 \$1 \$2）',
                    style: TextStyle(fontSize: 12)),
                value: _cfg.useRegex,
                onChanged: (v) =>
                    _edit(() => _cfg.useRegex = v ?? false),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _sectionPrefixSuffix() {
    return _ExpandableSection(
      title: '前缀 / 后缀（扩展名前）',
      helpTitle: '前缀 / 后缀',
      helpText: '• 前缀加在文件名最前面，后缀加在扩展名之前。\n'
          '• 例：前缀「已归档_」+ 后缀「_终稿」，报告.docx → 已归档_报告_终稿.docx。\n'
          '• 文件夹没有扩展名，前缀 / 后缀直接加在名字两端。\n'
          '• 两处都留空就等于不使用。',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _prefixCtrl,
                  decoration: const InputDecoration(
                    labelText: '前缀',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => _edit(() => _cfg.prefix = v),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: TextField(
                  controller: _suffixCtrl,
                  decoration: const InputDecoration(
                    labelText: '后缀',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => _edit(() => _cfg.suffix = v),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _sectionSequence() {
    return _ExpandableSection(
      // key 跟着启用状态走：配置异步加载完成后能自动展开 / 收起；
      // 展开 = 启用序号，收起 = 关闭，和 ExpansionTile 的交互保持一致。
      key: ValueKey('rename-seq-${_cfg.sequenceEnabled}'),
      title: '添加序号',
      initiallyExpanded: _cfg.sequenceEnabled,
      onExpansionChanged: (v) =>
          _edit(() => _cfg.sequenceEnabled = v),
      helpTitle: '添加序号',
      helpText: '• 展开这组就启用序号，收起就关闭。\n'
          '• 起始 / 步长 / 位数：起始 1、步长 1、位数 1 → 1、2、3…；'
          '位数 2 → 01、02、03…。\n'
          '• 位置可选「名称前面」或「名称后面」，分隔符默认 _，可改成 - 或空格。\n'
          '• 序号按预览区上方的「序号顺序」排列：预览第 1 行就是 1 号。',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: _intField('起始', _seqStartCtrl,
                        (v) => _edit(() => _cfg.sequenceStart = v)),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: _intField('步长', _seqStepCtrl,
                        (v) => _edit(() => _cfg.sequenceStep = v)),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: _intField('位数', _seqWidthCtrl,
                        (v) => _edit(() => _cfg.sequenceWidth = v)),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<bool>(
                      decoration: const InputDecoration(
                        labelText: '位置',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      value: _cfg.sequenceAtPrefix,
                      items: const [
                        DropdownMenuItem(
                            value: false, child: Text('名称后面')),
                        DropdownMenuItem(
                            value: true, child: Text('名称前面')),
                      ],
                      onChanged: (v) => _edit(
                          () => _cfg.sequenceAtPrefix = v ?? false),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: TextField(
                      decoration: const InputDecoration(
                        labelText: '分隔符',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      controller: _seqSepCtrl,
                      onChanged: (v) =>
                          _edit(() => _cfg.sequenceSeparator = v),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _sectionExt() {
    final anyDir = _items.any((e) => e.isDir);
    return _ExpandableSection(
      title: '扩展名',
      helpTitle: '扩展名',
      helpText: '• 勾选后，所有文件统一改成这里填的扩展名（只填后缀，不用写点）。\n'
          '• 原名没有扩展名的文件也会加上这个扩展名。\n'
          '• 文件夹不改扩展名。\n'
          '• 例：填 mp4，报告.docx → 报告.mp4。',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(
                    anyDir ? '改扩展名（文件夹不生效）' : '改扩展名',
                    style: const TextStyle(fontSize: 12),
                  ),
                  value: _cfg.changeExt,
                  onChanged: (v) =>
                      _edit(() => _cfg.changeExt = v ?? false),
                ),
              ),
              if (_cfg.changeExt)
                Expanded(
                  child: TextField(
                    controller: _extCtrl,
                    decoration: const InputDecoration(
                      labelText: '新扩展名',
                      hintText: 'txt',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) => _edit(
                        () => _cfg.newExt = v.trim().replaceAll('.', '')),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _sectionCase() {
    return _ExpandableSection(
      title: '大小写',
      helpTitle: '大小写',
      helpText: '• 只统一文件名里的英文大小写，扩展名不受影响。\n'
          '• 全小写：REPORT.TXT → report.TXT\n'
          '• 全大写：report.txt → REPORT.txt\n'
          '• 首字母大写：首字母变大写，其余字母变小写。\n'
          '• 例：REPORT-2026.TXT → Report-2026.TXT\n'
          '• 中文名不受影响。',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final m in const [
                ('none', '不变'),
                ('lower', '全小写'),
                ('upper', '全大写'),
                ('capitalize', '首字母大写'),
              ])
                ChoiceChip(
                  label: Text(m.$2, style: const TextStyle(fontSize: 12)),
                  selected: _cfg.caseMode == m.$1,
                  onSelected: (_) => _edit(() => _cfg.caseMode = m.$1),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _sectionAdvanced() {
    return _ExpandableSection(
      title: '高级（插入 / 删除）',
      helpTitle: '高级（插入 / 删除）',
      helpText: '• 「在指定位置插入文本」：填第几位前 + 要插入的内容。\n'
          '• 「删除一段字符」：填从第几位开始删、删掉几位。\n'
          '• 位置都按文件名算，不含扩展名；第 1 位 = 文件名第一个字。\n'
          '• 例：文件名 报告-终稿，从第 1 位删 2 位 → -终稿。\n'
          '• 插入 / 删除在大小写、日期、序号之前执行。',
      children: [
        // 插入
        CheckboxListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('在指定位置插入文本', style: TextStyle(fontSize: 13)),
          value: _cfg.insertEnabled,
          onChanged: (v) =>
              _edit(() => _cfg.insertEnabled = v ?? false),
        ),
        if (_cfg.insertEnabled)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
            child: Row(
              children: [
                Expanded(
                  flex: 2,
                  child: _intField('第几位前', _insertPosCtrl,
                      (v) => _edit(() => _cfg.insertPos = v)),
                ),
                const SizedBox(width: 6),
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _insertTextCtrl,
                    decoration: const InputDecoration(
                      labelText: '插入内容',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) =>
                        _edit(() => _cfg.insertText = v),
                  ),
                ),
              ],
            ),
          ),

        // 删除
        CheckboxListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('删除一段字符', style: TextStyle(fontSize: 13)),
          value: _cfg.deleteEnabled,
          onChanged: (v) =>
              _edit(() => _cfg.deleteEnabled = v ?? false),
        ),
        if (_cfg.deleteEnabled)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
            child: Row(
              children: [
                Expanded(
                  child: _intField('从第几位', _deleteStartCtrl,
                      (v) => _edit(() => _cfg.deleteStart = v)),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: _intField('删几位', _deleteLenCtrl,
                      (v) => _edit(() => _cfg.deleteLength = v)),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// 添加日期：用户自己选「加到哪」和「日期格式」。
  Widget _sectionDate() {
    return _ExpandableSection(
      title: '添加日期',
      helpTitle: '添加日期',
      helpText: '• 勾选后，把「当前的日期 / 时间」插进文件名，扩展名不受影响。\n'
          '• 添加到：名称前面、名称后面，或第 N 个字符之前。\n'
          '• 格式里可用：yyyy 年、yy 两位年、MM 月、dd 日、HH 时、mm 分、ss 秒；'
          '其它字符原样保留。\n'
          '• 例：yyyyMMdd → 20261101；yyyy-MM-dd → 2026-11-01；'
          '_yyyyMMdd_HHmmss → _20261101_153000。',
      children: [
        CheckboxListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('添加日期到文件名', style: TextStyle(fontSize: 13)),
          value: _cfg.dateEnabled,
          onChanged: (v) =>
              _edit(() => _cfg.dateEnabled = v ?? false),
        ),
        if (_cfg.dateEnabled) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final f in const [
                  'yyyyMMdd',
                  'yyyy-MM-dd',
                  'yyyy年MM月dd日',
                  '_yyyyMMdd',
                  'yyyyMMdd_HHmmss',
                ])
                  ChoiceChip(
                    label: Text(f, style: const TextStyle(fontSize: 12)),
                    selected: _cfg.dateFormat == f,
                    onSelected: (_) => _edit(() {
                      _cfg.dateFormat = f;
                      _dateFmtCtrl.text = f;
                    }),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Column(
              children: [
                TextField(
                  controller: _dateFmtCtrl,
                  decoration: const InputDecoration(
                    labelText: '日期格式',
                    hintText: 'yyyyMMdd',
                    isDense: true,
                    border: OutlineInputBorder(),
                    helperText: 'yyyy 年 / MM 月 / dd 日 / HH 时 / mm 分 / ss 秒，'
                        '其它字符原样保留',
                    helperMaxLines: 2,
                  ),
                  onChanged: (v) =>
                      _edit(() => _cfg.dateFormat = v),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: DropdownButtonFormField<String>(
                        decoration: const InputDecoration(
                          labelText: '添加到',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                        value: _cfg.datePosition,
                        items: const [
                          DropdownMenuItem(
                              value: 'prefix', child: Text('名称前面')),
                          DropdownMenuItem(
                              value: 'suffix', child: Text('名称后面')),
                          DropdownMenuItem(
                              value: 'insert', child: Text('第 N 位前')),
                        ],
                        onChanged: (v) => _edit(
                            () => _cfg.datePosition = v ?? 'suffix'),
                      ),
                    ),
                    if (_cfg.datePosition == 'insert') ...[
                      const SizedBox(width: 6),
                      Expanded(
                        flex: 2,
                        child: _intField('第几位前', _datePosCtrl,
                            (v) => _edit(() => _cfg.dateInsertPos = v)),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  // ---------- 预览区 ----------

  Widget _sectionPreview(
    List<
        ({
          String oldPath,
          String oldName,
          String newName,
          String? conflict,
        })> preview,
    int conflictCount,
    ColorScheme cs,
  ) {
    final changed = preview.where((e) => e.newName != e.oldName).length;
    // 只有「全名+序号」或「添加序号」开启时，先后顺序才影响结果，
    // 这时才显示序号和 ↑↓ 微调，避免误导。
    final showOrder = _cfg.renameMode == 'fullName' || _cfg.sequenceEnabled;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
          child: Row(
            children: [
              const Text('预览',
                  style:
                      TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              const Spacer(),
              if (conflictCount > 0)
                Text('$conflictCount 处冲突',
                    style: TextStyle(fontSize: 12, color: cs.error))
              else if (changed > 0)
                Text('$changed 项将改名',
                    style: TextStyle(
                        fontSize: 12, color: cs.onSurfaceVariant)),
            ],
          ),
        ),
        // 序号顺序：默认按文件浏览器里的显示顺序。
        // 只有顺序会影响结果时才显示（全名+序号 / 规则里开了序号）。
        if (showOrder)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: Row(
              children: [
                Text('序号顺序',
                    style: TextStyle(
                        fontSize: 11, color: cs.onSurfaceVariant)),
                const SizedBox(width: 6),
                Expanded(
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _cfg.orderMode,
                      isDense: true,
                      isExpanded: true,
                      borderRadius: BorderRadius.circular(8),
                      style: TextStyle(fontSize: 12, color: cs.onSurface),
                      items: [
                        for (final o in _kRenameOrderOptions)
                          DropdownMenuItem<String>(
                            value: o.$1,
                            child: Text(o.$2,
                                style: const TextStyle(fontSize: 12)),
                          ),
                      ],
                      onChanged: _setOrderMode,
                    ),
                  ),
                ),
                Tooltip(
                  message:
                      '先在这里选排序方式，再点预览里的 ↑↓ 微调（会自动切到手动顺序）',
                  child: Icon(Icons.info_outline,
                      size: 14, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
        Expanded(
          child: changed == 0
              ? Center(
                  child: Text(
                    _cfg.renameMode == 'fullName' &&
                            _cfg.fullNameBase.trim().isEmpty
                        ? '请输入新名字'
                        : '当前规则不会改变任何文件名',
                    style: TextStyle(
                        fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                  itemCount: preview.length,
                  itemBuilder: (_, i) {
                    final e = preview[i];
                    final unchanged = e.newName == e.oldName;
                    final hasConflict = e.conflict != null;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          if (showOrder) ...[
                            SizedBox(
                              width: 18,
                              child: Text(
                                '${i + 1}',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                          ],
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  e.oldName,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: cs.onSurfaceVariant,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  unchanged ? '（不变）' : e.newName,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                    color: hasConflict
                                        ? cs.error
                                        : (unchanged
                                            ? cs.onSurfaceVariant
                                            : cs.onSurface),
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                if (hasConflict)
                                  Text(
                                    e.conflict!,
                                    style: TextStyle(
                                        fontSize: 11, color: cs.error),
                                  ),
                              ],
                            ),
                          ),
                          if (showOrder && preview.length > 1) ...[
                            _previewMoveButton(
                              e.oldPath,
                              -1,
                              enabled: i > 0,
                            ),
                            _previewMoveButton(
                              e.oldPath,
                              1,
                              enabled: i < preview.length - 1,
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _previewMoveButton(
    String oldPath,
    int delta, {
    required bool enabled,
  }) {
    return SizedBox(
      width: 26,
      height: 26,
      child: IconButton(
        padding: EdgeInsets.zero,
        constraints:
            const BoxConstraints.tightFor(width: 26, height: 26),
        visualDensity: VisualDensity.compact,
        iconSize: 16,
        tooltip: delta < 0 ? '上移' : '下移',
        icon: Icon(
          delta < 0 ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
        ),
        onPressed: enabled ? () => _moveOrderedItem(oldPath, delta) : null,
      ),
    );
  }

  // ---------- 小工具 ----------

  Widget _intField(String label, TextEditingController ctrl, ValueChanged<int> onChanged) {
    return TextField(
      controller: ctrl,
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      keyboardType: TextInputType.number,
      onChanged: (v) {
        final n = int.tryParse(v);
        if (n != null) onChanged(n);
      },
    );
  }
}

// ==================== 批量重命名：可折叠分组（带帮助入口） ====================

/// 批量重命名弹窗里的分组：标题行右侧是「？ + 展开箭头」。
/// 点 ？ 弹出该分组的用法说明，箭头随展开状态旋转。
class _ExpandableSection extends StatefulWidget {
  const _ExpandableSection({
    super.key,
    required this.title,
    required this.children,
    required this.helpTitle,
    required this.helpText,
    this.initiallyExpanded = false,
    this.onExpansionChanged,
  });

  final String title;
  final List<Widget> children;
  final String helpTitle;
  final String helpText;
  final bool initiallyExpanded;
  final ValueChanged<bool>? onExpansionChanged;

  @override
  State<_ExpandableSection> createState() => _ExpandableSectionState();
}

class _ExpandableSectionState extends State<_ExpandableSection> {
  late bool _expanded = widget.initiallyExpanded;

  void _showHelp() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(widget.helpTitle,
            style: const TextStyle(fontSize: 16)),
        content: SingleChildScrollView(
          child: Text(widget.helpText,
              style: const TextStyle(fontSize: 13, height: 1.6)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 12),
      initiallyExpanded: widget.initiallyExpanded,
      onExpansionChanged: (v) {
        setState(() => _expanded = v);
        widget.onExpansionChanged?.call(v);
      },
      title: Text(widget.title, style: const TextStyle(fontSize: 13)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 28,
            height: 28,
            child: IconButton(
              padding: EdgeInsets.zero,
              constraints:
                  const BoxConstraints.tightFor(width: 28, height: 28),
              visualDensity: VisualDensity.compact,
              iconSize: 16,
              tooltip: '使用说明',
              icon: Icon(Icons.help_outline, color: cs.onSurfaceVariant),
              onPressed: _showHelp,
            ),
          ),
          const SizedBox(width: 2),
          AnimatedRotation(
            turns: _expanded ? 0.5 : 0,
            duration: const Duration(milliseconds: 150),
            child: Icon(Icons.expand_more, color: cs.onSurfaceVariant),
          ),
        ],
      ),
      children: widget.children,
    );
  }
}

class _SearchFolderPickerDialog extends StatefulWidget {
  const _SearchFolderPickerDialog({
    required this.rootPath,
    required this.initialPath,
    required this.initialSelected,
    this.titleText,
    this.showGuide = false,
  });

  final String rootPath;
  final String initialPath;
  final List<String> initialSelected;

  /// 顶部标题。不传就用勾选文件夹的默认文案。
  /// 查重范围选择器会传自己的，说明这次勾选是给谁用的。
  final String? titleText;

  /// 是否叠一层首次引导：高亮「勾选区」和「进入区」，其余变暗。
  final bool showGuide;

  @override
  State<_SearchFolderPickerDialog> createState() =>
      _SearchFolderPickerDialogState();
}

class _SearchFolderPickerDialogState extends State<_SearchFolderPickerDialog> {
  static const String _internalRoot = '/storage/emulated/0';

  // 7.4：区间高亮色改读主题 token（原为 static const 硬编码）
  Color get _rangeBlue => Theme.of(context).colorScheme.primary;
  Color get _rangeHighlight =>
      Theme.of(context).colorScheme.primary.withValues(alpha: 0.2);

  late String _path;
  late List<String> _selected;
  late final TextEditingController _jumpCtrl;
  List<Directory> _dirs = const [];
  bool _loading = true;

  bool _rangeMode = false;
  String? _rangeAnchorPath;

  // 首次引导要挖洞高亮的两个位置：第一行的勾选方框 / 进入箭头。
  final GlobalKey _guideCheckKey = GlobalKey();
  final GlobalKey _guideEnterKey = GlobalKey();
  final GlobalKey _guideRangeKey = GlobalKey();
  final GlobalKey _guideAllKey = GlobalKey();
  OverlayEntry? _guideEntry;

  bool get _isDupScope => (widget.titleText ?? '').contains('查重');

  /// 引导只弹一次：进子目录会重新 _load，不该每次都再弹一遍。
  bool _guideDone = false;

  @override
  void initState() {
    super.initState();
    _path = widget.initialPath;
    _selected = List<String>.from(widget.initialSelected);
    _jumpCtrl = TextEditingController();
    _load();
  }

  @override
  void dispose() {
    _guideEntry?.remove();
    _guideEntry = null;
    _jumpCtrl.dispose();
    super.dispose();
  }

  /// 组件的屏幕矩形。没挂上 / 已卸载时返回 null。
  Rect? _rectOf(GlobalKey key) {
    final obj = key.currentContext?.findRenderObject();
    if (obj is! RenderBox || !obj.attached) return null;
    return obj.localToGlobal(Offset.zero) & obj.size;
  }

  /// 打开操作引导（多页分页版）。
  ///
  /// 把需要讲清楚的几处功能各做成一页：勾选方框、进入箭头、区间选择、
  /// 全选，最后再讲「确定 / 记住范围」。右上角有「第 X / N · 还剩 M 页」
  /// 的计数，告诉用户后面还有几页。
  ///
  /// 入口有两处：① 首次进入时自动弹一次（看 [_guideDone]）；② 弹窗
  /// 右上角的常驻「?」按钮，随时可再打开复习。
  void _openGuide() {
    if (!mounted || _guideEntry != null) return;

    // 对话框此刻已构建完成，各目标位置在引导期间不会变（引导内不导航），
    // 所以直接量一次屏幕矩形、作为固定值传进去即可。量不到（如空目录没有
    // 第一行）的就以「无高亮」页呈现，只讲概念。
    final steps = <_GuideStep>[
      _GuideStep(
        rect: _rectOf(_guideCheckKey),
        title: '① 点方框 = 选中',
        body: _isDupScope
            ? '勾上就是要查重这个文件夹，可以多选。'
            : '勾上就是把它加进范围，可以多选。',
      ),
      _GuideStep(
        rect: _rectOf(_guideEnterKey),
        title: '② 点箭头 = 进入',
        body: '只是进去看它里面的子文件夹，不会勾选它。'
            '点错就跑到别的目录了，要回来点左上角「↑」。',
      ),
      _GuideStep(
        rect: _rectOf(_guideRangeKey),
        title: '③ 区间：一次选一串',
        body: '先点底部「区间」，再点两行内容当起点和终点，'
            '中间夹着的所有文件夹会一起被选中，省得一个一个点。',
      ),
      _GuideStep(
        rect: _rectOf(_guideAllKey),
        title: '④ 全选：本页全勾上',
        body: '一键勾选当前目录列出的全部文件夹；'
            '进入别的目录后要再点一次才生效。',
      ),
      _GuideStep(
        rect: null,
        title: '选完点「确定」',
        body: '会再问你要不要记住范围：\n'
            '记住——下次查重直接用这些目录，不用再选；'
            '不记住——只查这一次，下次重新选。',
      ),
    ];

    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (c) => _PickerGuideLayer(
        steps: steps,
        onClose: () {
          entry.remove();
          if (_guideEntry == entry) _guideEntry = null;
        },
      ),
    );
    _guideEntry = entry;
    Overlay.of(context, rootOverlay: true).insert(entry);
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final dirs = await listSubdirectoriesSafe(_path);
      if (!mounted) return;
      setState(() {
        _dirs = dirs;
        _loading = false;
      });
      // 引导要等列表真的画出来才能测到位置，所以放在加载完的下一帧。
      // 只自动弹这一次；之后用户可随时点弹窗右上角的「?」再看。
      if (widget.showGuide && !_guideDone) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_guideDone) {
            _guideDone = true;
            _openGuide();
          }
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _dirs = const [];
        _loading = false;
      });
    }
  }

  bool get _canGoUp => _path != widget.rootPath;

  void _goUp() {
    if (!_canGoUp) return;
    final parent = Directory(_path).parent.path;
    if (!parent.startsWith(widget.rootPath)) return;
    setState(() {
      _path = parent;
      _rangeAnchorPath = null;
    });
    _load();
  }

  String get _relPath {
    if (_path == widget.rootPath) return '~/';
    if (_path == _internalRoot || _path.startsWith('$_internalRoot/')) {
      final sub = _path.substring(_internalRoot.length);
      return sub.isEmpty ? '~' : '~$sub';
    }
    return _path;
  }

  void _jumpToPath(String path) {
  if (path.isEmpty) return;
  var target = _normalizePath(path.trim());
  if (FileSystemEntity.typeSync(target) == FileSystemEntityType.file) {
    target = File(target).parent.path;
  }
  if (!Directory(target).existsSync()) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('目录不存在')),
    );
    return;
  }
  if (!target.startsWith(widget.rootPath)) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('只能跳到内部存储以内')),
    );
    return;
  }
  setState(() {
    _path = target;
    _rangeAnchorPath = null;
  });
  _load();
}

String _normalizePath(String path) {
  const prefixes = <String, String>{
    '/sdcard/': '/storage/emulated/0/',
    '/sdcard': '/storage/emulated/0',
    '/mnt/sdcard/': '/storage/emulated/0/',
    '/mnt/sdcard': '/storage/emulated/0',
    '/storage/self/primary/': '/storage/emulated/0/',
    '/storage/self/primary': '/storage/emulated/0',
    '/storage/emulated/legacy/': '/storage/emulated/0/',
    '/storage/emulated/legacy': '/storage/emulated/0',
  };
  for (final e in prefixes.entries) {
    if (path.startsWith(e.key)) {
      return e.value + path.substring(e.key.length);
    }
  }
  return path;
}

  void _toggle(String path) {
    setState(() {
      if (_selected.contains(path)) {
        _selected.remove(path);
      } else {
        _selected.add(path);
      }
    });
  }

  bool get _allVisibleSelected {
    if (_dirs.isEmpty) return false;
    for (final d in _dirs) {
      if (!_selected.contains(d.path)) return false;
    }
    return true;
  }

  void _toggleSelectAll() {
    setState(() {
      if (_allVisibleSelected) {
        for (final d in _dirs) {
          _selected.remove(d.path);
        }
      } else {
        for (final d in _dirs) {
          if (!_selected.contains(d.path)) _selected.add(d.path);
        }
      }
    });
  }

  void _toggleRangeMode() {
    setState(() {
      _rangeMode = !_rangeMode;
      _rangeAnchorPath = null;
    });
  }

  void _handleRangeTap(String path) {
    final anchor = _rangeAnchorPath;
    if (anchor == null) {
      setState(() => _rangeAnchorPath = path);
      return;
    }

    final visible = _dirs.map((d) => d.path).toList();
    final from = visible.indexOf(anchor);
    final to = visible.indexOf(path);
    if (from < 0 || to < 0) {
      setState(() => _rangeAnchorPath = path);
      return;
    }
    final lo = from < to ? from : to;
    final hi = from < to ? to : from;

    setState(() {
      for (var i = lo; i <= hi; i++) {
        _selected.add(visible[i]);
      }
      _rangeMode = false;
      _rangeAnchorPath = null;
    });
  }

  Future<void> _showSelected() async {
    await showDialog<void>(
      context: context,
      builder: (outerContext) => StatefulBuilder(
        builder: (innerContext, setInnerState) => AlertDialog(
          insetPadding: _dlgInsetG,
          titlePadding: _dlgTitlePadG,
          contentPadding: _dlgContentPadG,
          actionsPadding: _dlgActionsPadG,
          title: const Text('已勾选文件夹'),
          content: SizedBox(
            width: double.maxFinite,
            height: MediaQuery.of(innerContext).size.height * 0.85,
            child: _selected.isEmpty
                ? const Text('还没有勾选任何文件夹')
                : ListView.builder(
                    itemCount: _selected.length,
                    itemBuilder: (ctx, i) {
                      final p = _selected[i];
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(p.split('/').last),
                        subtitle: Text(
                          p,
                          style: const TextStyle(fontSize: 11),
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          tooltip: '移除',
                          onPressed: () {
                            setInnerState(() => _selected.removeAt(i));
                            setState(() {});
                          },
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(innerContext),
              child: const Text('关闭'),
            ),
          ],
        ),
      ),
    );
  }

  String get _titleText {
    if (_rangeMode) {
      return _rangeAnchorPath == null ? '点一行内容为起点' : '再点一行内容为终点';
    }
    return widget.titleText ?? '点击左侧方框勾选对应文件夹';
  }

  double get _titleSize => _rangeMode ? 14.0 : 16.0;

  Color? get _titleColor => _rangeMode ? _rangeBlue : null;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      insetPadding: _dlgInsetG,
      titlePadding: _dlgTitlePadG,
      contentPadding: EdgeInsets.zero,
      actionsPadding: _dlgActionsPadG,
      title: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Text(
              _titleText,
              style: TextStyle(
                fontSize: _titleSize,
                fontWeight: FontWeight.bold,
                color: _titleColor,
              ),
            ),
          ),
          // 常驻操作引导入口：弹窗右上角，随时可点开复习。
          IconButton(
            icon: const Icon(Icons.help_outline, size: 20),
            tooltip: '操作引导',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: _openGuide,
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.of(context).size.height * 0.85,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _jumpCtrl,
                      cursorColor: Theme.of(context).colorScheme.primary,
                      style: const TextStyle(fontSize: 13),
                      decoration: InputDecoration(
                        hintText: '粘贴路径跳转',
                        isDense: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                            color: Theme.of(context).colorScheme.primary,
                            width: 2,
                          ),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                      ),
                      onSubmitted: (v) => _jumpToPath(v.trim()),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    icon: const Icon(Icons.arrow_forward),
                    color: Theme.of(context).colorScheme.primary,
                    tooltip: '跳转',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _jumpToPath(_jumpCtrl.text.trim()),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 0),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_upward),
                    onPressed: _canGoUp ? _goUp : null,
                    tooltip: '上一级',
                    visualDensity: VisualDensity.compact,
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Text(
                        _relPath,
                        style: Theme.of(context).textTheme.labelSmall,
                        maxLines: 1,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _dirs.isEmpty
                      ? const Center(child: Text('（无子目录）'))
                      : ListView.builder(
                          itemCount: _dirs.length,
                          itemBuilder: (ctx, i) {
                            final d = _dirs[i];
                            final name = d.path.split('/').last;
                            final selected = _selected.contains(d.path);
                            final isAnchor = d.path == _rangeAnchorPath;

                            return Container(
                              color: isAnchor ? _rangeHighlight : null,
                              child: ListTile(
                                dense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 4),
                                leading: SizedBox(
                                  width: 68,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      // 第一行挂引导用的 key：这里是「勾选」。
                                      InkWell(
                                        key: i == 0 ? _guideCheckKey : null,
                                        onTap: () => _toggle(d.path),
                                        child: Padding(
                                          padding: const EdgeInsets.all(4),
                                          child: Icon(
                                            selected
                                                ? Icons.check_box
                                                : Icons
                                                    .check_box_outline_blank,
                                            color: _rangeMode
                                                ? Theme.of(context)
                                                    .colorScheme
                                                    .onSurfaceVariant
                                                    .withValues(alpha: 0.3)
                                                : (selected
                                                    ? Theme.of(context)
                                                        .colorScheme
                                                        .primary
                                                    : null),
                                          ),
                                        ),
                                      ),
                                      InkWell(
                                        onTap: () => _toggle(d.path),
                                        child: Padding(
                                          padding: const EdgeInsets.all(4),
                                          child: const AppFileIcon(isDir: true),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                title: Text(name),
                                // 第一行挂引导用的 key：这里是「进入」。
                                trailing: InkWell(
                                  key: i == 0 ? _guideEnterKey : null,
                                  onTap: () {
                                    setState(() {
                                      _path = d.path;
                                      _rangeMode = false;
                                      _rangeAnchorPath = null;
                                    });
                                    _load();
                                  },
                                  child: const Padding(
                                    padding: EdgeInsets.all(8),
                                    child: Icon(Icons.chevron_right),
                                  ),
                                ),
                                onTap: () {
                                  if (_rangeMode) {
                                    _handleRangeTap(d.path);
                                    return;
                                  }
                                  setState(() {
                                    _path = d.path;
                                    _rangeAnchorPath = null;
                                  });
                                  _load();
                                },
                              ),
                            );
                          },
                        ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
              child: Row(
                children: [
                  FilterChip(
                    key: _guideAllKey,
                    label: const Text('全选'),
                    selected: _allVisibleSelected,
                    onSelected: (_) => _toggleSelectAll(),
                    backgroundColor:
                        Theme.of(context).colorScheme.surface,
                    selectedColor: Theme.of(context).colorScheme.surface,
                    surfaceTintColor: Colors.transparent,
                    shadowColor: Colors.transparent,
                    elevation: 0,
                    checkmarkColor: Theme.of(context).colorScheme.primary,
                    labelStyle: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurface,
                      fontWeight: FontWeight.normal,
                    ),
                    side: BorderSide(
                      color: _allVisibleSelected
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.outlineVariant,
                    ),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize:
                        MaterialTapTargetSize.shrinkWrap,
                  ),
                  const SizedBox(width: 24),
                  FilterChip(
                    key: _guideRangeKey,
                    label: const Text('区间'),
                    selected: _rangeMode,
                    onSelected: (_) => _toggleRangeMode(),
                    backgroundColor:
                        Theme.of(context).colorScheme.surface,
                    selectedColor:
                        Theme.of(context).colorScheme.primaryContainer,
                    surfaceTintColor: Colors.transparent,
                    shadowColor: Colors.transparent,
                    elevation: 0,
                    checkmarkColor: _rangeBlue,
                    labelStyle: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurface,
                      fontWeight: FontWeight.normal,
                    ),
                    side: BorderSide(
                      color: _rangeMode
                          ? _rangeBlue
                          : Theme.of(context).colorScheme.outlineVariant,
                    ),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize:
                        MaterialTapTargetSize.shrinkWrap,
                  ),
                  const Spacer(),
                  Text(
                    '已勾选 ${_selected.length} 个',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  const SizedBox(width: 4),
                  TextButton(
                    onPressed: _selected.isEmpty ? null : _showSelected,
                    child: const Text('查看'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _selected),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

// ==================== 文件夹勾选器的操作引导 ====================

/// 弹窗右上角常驻的「?」按钮，以及首次进入时自动弹一次的分步引导。
///
/// 参考主流 App 的做法：一屏放不下就一页只讲一个功能，整屏压暗、只在
/// 当前要讲的元素处挖亮洞；右上角有「第 X / N · 还剩 M 页」计数，告诉
/// 用户后面还有几页。翻完即止，关掉后随时可点「?」再看一遍。

/// 引导的一页：要突出的元素屏幕矩形（为 null 时整屏轻压暗、只讲概念）+ 文案。
class _GuideStep {
  const _GuideStep({this.rect, required this.title, required this.body});
  final Rect? rect;
  final String title;
  final String body;
}

class _PickerGuideLayer extends StatefulWidget {
  const _PickerGuideLayer({
    super.key,
    required this.steps,
    required this.onClose,
  });

  final List<_GuideStep> steps;
  final VoidCallback onClose;

  @override
  State<_PickerGuideLayer> createState() => _PickerGuideLayerState();
}

class _PickerGuideLayerState extends State<_PickerGuideLayer> {
  int _page = 0;
  int get _total => widget.steps.length;

  void _next() {
    if (_page < _total - 1) {
      setState(() => _page++);
    } else {
      widget.onClose();
    }
  }

  void _prev() {
    if (_page > 0) setState(() => _page--);
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final size = MediaQuery.of(context).size;
    final step = widget.steps[_page];
    final remaining = _total - _page - 1;
    final hasHole = step.rect != null;

    // 卡片放哪一侧：目标在屏幕下半（如底部「区间 / 全选」）就放到上面，
    // 否则放下面。高亮洞和卡片永不叠在一起——这正是之前那个 bug 的根因。
    final putTop = hasHole && step.rect!.center.dy > size.height * 0.55;

    return SizedBox(
      width: size.width,
      height: size.height,
      child: Stack(
        children: [
          // 压暗层：有洞时只挖当前这一页的洞；无洞时整屏轻压暗。
          Positioned.fill(
            child: CustomPaint(
              painter: _GuideHolePainter(
                holes: hasHole ? [step.rect!] : const [],
                dimColor: Colors.black.withValues(
                  alpha: hasHole ? 0.62 : 0.5,
                ),
                ringColor: Colors.white,
              ),
            ),
          ),

          // 右上角：计数 + 关闭。常驻提示「还有几页」。
          Positioned(
            top: 14,
            right: 14,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.62),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '第 ${_page + 1} / $_total',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        remaining > 0 ? '还剩 $remaining 页' : '最后一步',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Material(
                  color: Colors.black.withValues(alpha: 0.62),
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: widget.onClose,
                    child: const Padding(
                      padding: EdgeInsets.all(8),
                      child: Icon(Icons.close, color: Colors.white, size: 18),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // 说明卡片：根据目标位置自动贴在上或下，避免挡住高亮。
          Positioned(
            left: 16,
            right: 16,
            top: putTop ? 64 : null,
            bottom: putTop ? null : 24,
            child: _guideCard(s, step),
          ),
        ],
      ),
    );
  }

  Widget _guideCard(ColorScheme s, _GuideStep step) {
    return Material(
      color: s.surface,
      borderRadius: BorderRadius.circular(12),
      elevation: 8,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              step.title,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: s.onSurface,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              step.body,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.5,
                color: s.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                if (_page > 0)
                  TextButton(
                    onPressed: _prev,
                    child: const Text('上一步'),
                  )
                else
                  const SizedBox.shrink(),
                const Spacer(),
                FilledButton(
                  onPressed: _next,
                  child: Text(_page < _total - 1 ? '下一步' : '完成'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 压暗整屏 + 挖洞。
///
/// 用 difference 填充路径：外圈是整个屏幕，内圈是每个要突出的元素
/// 对应的圆角矩形，相减后洞自然就空出来了。holes 为空时整屏被压暗
/// （用于没有具体可高亮目标的「纯讲解」页）。
class _GuideHolePainter extends CustomPainter {
  const _GuideHolePainter({
    required this.holes,
    required this.dimColor,
    required this.ringColor,
  });

  final List<Rect> holes;
  final Color dimColor;
  final Color ringColor;

  @override
  void paint(Canvas canvas, Size size) {
    final full = Path()..addRect(Offset.zero & size);
    final cut = Path();
    for (final r in holes) {
      // 洞比原件大一圈，留出呼吸空间，也让高亮更明显。
      final pad = r.inflate(6);
      cut.addRRect(RRect.fromRectAndRadius(pad, const Radius.circular(10)));
    }
    final dimmed = Path.combine(PathOperation.difference, full, cut);

    canvas.drawPath(dimmed, Paint()..color = dimColor);

    // 洞边描一圈亮线，提示"看这里"。
    final ring = Paint()
      ..color = ringColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (final r in holes) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(r.inflate(6), const Radius.circular(10)),
        ring,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GuideHolePainter oldDelegate) =>
      oldDelegate.holes != holes ||
      oldDelegate.dimColor != dimColor ||
      oldDelegate.ringColor != ringColor;
}

// ==================== 属性弹窗（含手动计算 MD5） ====================

/// 多选属性弹窗里的一行明细（名称 / 大小 / 修改时间 / 路径）。
class _PropDetail {
  const _PropDetail({
    required this.name,
    required this.path,
    required this.isDir,
    required this.size,
    required this.modified,
  });

  final String name;
  final String? path;
  final bool isDir;
  final int? size;
  final DateTime? modified;
}

class _PropertiesDialog extends StatefulWidget {
  const _PropertiesDialog({
    required this.name,
    required this.path,
    required this.isDir,
    required this.size,
    required this.modified,
    required this.accessed,
  });

  final String name;
  final String path;
  final bool isDir;
  final int? size;
  final DateTime? modified;
  final DateTime? accessed;

  @override
  State<_PropertiesDialog> createState() => _PropertiesDialogState();
}

class _PropertiesDialogState extends State<_PropertiesDialog> {
  String? _md5;
  bool _md5Loading = false;
  String? _md5Error;

  Future<void> _computeMd5() async {
    if (widget.isDir) return;
    setState(() {
      _md5Loading = true;
      _md5Error = null;
    });
    try {
      final hash = await compute(_md5FileOfPath, widget.path);
      if (!mounted) return;
      setState(() {
        _md5 = hash;
        _md5Loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _md5Error = e.toString();
        _md5Loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: Theme.of(context).textTheme.labelSmall),
              const SizedBox(height: 2),
              SelectableText(value),
            ],
          ),
        );

    return AlertDialog(
      insetPadding: const EdgeInsets.all(16),
      title: const Text('属性'),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                row('名称', widget.name),
                row('路径', widget.path),
                row('类型', widget.isDir ? '文件夹' : '文件'),
                row(
                  '大小',
                  widget.isDir
                      ? '—'
                      : (widget.size == null
                          ? '—'
                          : _FileBrowserScreenState._formatSize(widget.size)),
                ),
                if (widget.modified != null)
                  row(
                    '修改时间',
                    _FileBrowserScreenState._formatTimeFull(widget.modified!),
                  ),
                if (widget.accessed != null)
                  row(
                    '访问时间',
                    _FileBrowserScreenState._formatTimeFull(widget.accessed!),
                  ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'MD5',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                      const SizedBox(height: 4),
                      _buildMd5Area(),
                    ],
                  ),
                ),
              ],
            ),
          ),
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

  Widget _buildMd5Area() {
    if (widget.isDir) {
      return Text(
        '文件夹不支持计算 MD5',
        style: TextStyle(
          fontSize: 13,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      );
    }

    if (_md5Loading) {
      return const Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 8),
          Text('计算中…', style: TextStyle(fontSize: 13)),
        ],
      );
    }

    if (_md5 != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  _md5!,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                tooltip: '重新计算',
                visualDensity: VisualDensity.compact,
                onPressed: _computeMd5,
              ),
            ],
          ),
          if (_md5Error != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '计算失败：$_md5Error',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            ),
        ],
      );
    }

    return OutlinedButton.icon(
      onPressed: _computeMd5,
      icon: const Icon(Icons.fingerprint, size: 16),
      label: const Text('点击计算 MD5'),
    );
  }
}

// ==================== 删除确认弹窗（异步统计） ====================

typedef _PathStat = ({int files, int bytes, bool truncated, bool done});

class _DeleteConfirmDialog extends StatefulWidget {
  const _DeleteConfirmDialog({required this.paths});
  final List<String> paths;

  @override
  State<_DeleteConfirmDialog> createState() => _DeleteConfirmDialogState();
}

class _DeleteConfirmDialogState extends State<_DeleteConfirmDialog> {
  static const int _limit = 10000;

  final Map<String, _PathStat> _stats = {};
  final Map<String, bool> _isDir = {};
  bool _allDone = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
  for (final p in widget.paths) {
    try {
      if (!Directory(p).existsSync()) {
        _isDir[p] = false;
        final st = File(p).statSync();
        _stats[p] = (files: 1, bytes: st.size, truncated: false, done: true);
      }
    } catch (_) {
      _stats[p] = (files: 0, bytes: 0, truncated: true, done: true);
    }
  }
  if (mounted) setState(() {});

  for (final p in widget.paths) {
    if (!mounted) return;
    if (_stats.containsKey(p)) continue;
    try {
      if (Directory(p).existsSync()) {
        _isDir[p] = true;
        if (mounted) setState(() {});
        final r = await _scanDir(p);
        if (!mounted) return;
        _stats[p] = r;
      }
    } catch (_) {
      _stats[p] = (files: 0, bytes: 0, truncated: true, done: true);
    }
    if (mounted) setState(() {});
  }
  if (mounted) setState(() => _allDone = true);
}

  Future<_PathStat> _scanDir(String rootPath) async {
    var fileCount = 0;
    var dirCount = 0;
    var bytes = 0;
    final stack = <String>[rootPath];
    var lastYield = DateTime.now();
    while (stack.isNotEmpty) {
      if (fileCount + dirCount > _limit) {
        return (files: fileCount, bytes: bytes, truncated: true, done: true);
      }
      final p = stack.removeLast();
      List<FileSystemEntity> entries;
      try {
        entries = Directory(p).listSync(followLinks: false);
      } catch (_) {
        continue;
      }
      for (final e in entries) {
        if (e is File) {
          fileCount++;
          try {
            bytes += e.statSync().size;
          } catch (_) {}
        } else if (e is Directory) {
          dirCount++;
          stack.add(e.path);
        }
      }
      final now = DateTime.now();
      if (now.difference(lastYield).inMilliseconds > 30) {
        lastYield = now;
        if (mounted) setState(() {});
        await Future<void>.delayed(Duration.zero);
      }
    }
    return (files: fileCount, bytes: bytes, truncated: false, done: true);
  }

  String _fmt(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.paths.length;

    final totalFiles = _stats.values.fold<int>(0, (s, e) => s + e.files);
    final totalBytes = _stats.values.fold<int>(0, (s, e) => s + e.bytes);
    final anyTruncated = _stats.values.any((e) => e.truncated);

    final lines = <Widget>[];
    for (final p in widget.paths) {
      final name = p.split('/').last;
      final stat = _stats[p];
      final isDir = _isDir[p] ?? false;

      String text;
      if (stat == null) {
        text = '· ${isDir ? "$name/" : name} —— 正在统计…';
      } else if (stat.truncated) {
        text = '· $name/ —— 文件超过 $_limit 个，未完全统计';
      } else if (isDir) {
        text = '· $name/ —— ${stat.files} 个文件，${_fmt(stat.bytes)}';
      } else {
        text = '· $name —— ${_fmt(stat.bytes)}';
      }

      lines.add(Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(
          text,
          style: const TextStyle(fontSize: 13, height: 1.5),
        ),
      ));
    }

    String totalStr;
    if (!_allDone) {
      totalStr = '正在统计…';
    } else if (anyTruncated) {
      totalStr = '总计约 ${_fmt(totalBytes)}（部分未统计）';
    } else {
      totalStr = '共 $totalFiles 个文件，${_fmt(totalBytes)}';
    }

    // 按选中项类型说明删除去向：文件→回收站，文件夹→直接删除。
    final statCount = _isDir.length; // 已统计出类型的项数
    final dirCount = _isDir.values.where((d) => d).length;
    final fileCount = statCount - dirCount;
    final unknownCount = n - statCount;

    final String fateText;
    if (unknownCount > 0) {
      fateText = '文件将先移入回收站（可在「⋯ → 回收站」恢复）；'
          '文件夹将被直接删除，无法恢复。';
    } else if (fileCount > 0 && dirCount == 0) {
      fateText = '选中的 $fileCount 个文件将先移入回收站，'
          '可在「⋯ → 回收站」中恢复，不会直接物理删除。';
    } else if (fileCount == 0 && dirCount > 0) {
      fateText = '选中的 $dirCount 个文件夹（含其全部内容）将被直接删除，无法恢复。';
    } else {
      fateText = '$fileCount 个文件将先移入回收站（可恢复）；'
          '$dirCount 个文件夹将被直接删除，无法恢复。';
    }

    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      titlePadding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      contentPadding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      actionsPadding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
      title: Text('删除 $n 项？'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              ...lines,
              const SizedBox(height: 8),
              const Divider(height: 1),
              const SizedBox(height: 8),
              Text(
                totalStr,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                fateText,
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

// ==================== 加载骨架屏（Shimmer 流光） ====================

class _SlidingGradientTransform extends GradientTransform {
  const _SlidingGradientTransform(this.slidePercent);
  final double slidePercent;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    return Matrix4.translationValues(
      bounds.width * (slidePercent * 2 - 1),
      0,
      0,
    );
  }
}

class _LoadingSkeleton extends StatefulWidget {
  const _LoadingSkeleton({super.key, this.rows = 16});
  final int rows;

  @override
  State<_LoadingSkeleton> createState() => _LoadingSkeletonState();
}

class _LoadingSkeletonState extends State<_LoadingSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (ctx, _) {
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) {
            final cs = Theme.of(context).colorScheme;
            return LinearGradient(
              colors: [
                cs.surfaceVariant,
                cs.surfaceVariant.withValues(alpha: 0.4),
                cs.surfaceVariant,
              ],
              stops: const [0.35, 0.5, 0.65],
              transform: _SlidingGradientTransform(_ctrl.value),
            ).createShader(bounds);
          },
          child: _buildStatic(),
        );
      },
    );
  }

  Widget _buildStatic() {
    return ListView.builder(
      physics: const NeverScrollableScrollPhysics(),
      itemCount: widget.rows,
      itemBuilder: (ctx, i) {
        // 每行宽度略有变化，看起来不像机器排的
        final nameW = 120.0 + (i * 37) % 80;
        final metaW = 70.0 + (i * 23) % 60;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceVariant,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: nameW,
                      height: 11,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceVariant,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      width: metaW,
                      height: 8,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceVariant,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ==================== 可拖动滚动条（外包在列表之上） ====================

/// ScrollablePositionedList 不暴露 ScrollController，
/// 所以用 ItemPositionsListener 的可见项信息推算滚动位置，
/// 拖动时换算成目标条目索引再 jumpTo。
class _BrowserScrollbar extends StatefulWidget {
  const _BrowserScrollbar({
    required this.positions,
    required this.itemCount,
    required this.thumbWidth,
    required this.trackColor,
    required this.thumbColor,
    required this.onJump,
  });

  final ValueListenable<Iterable<ItemPosition>> positions;
  final int Function() itemCount;
  final double thumbWidth;
  final Color trackColor;
  final Color thumbColor;
  final void Function(int index) onJump;

  @override
  State<_BrowserScrollbar> createState() => _BrowserScrollbarState();
}

class _BrowserScrollbarState extends State<_BrowserScrollbar> {
  static const double _minThumb = 36;

  /// 拖动中的拇指顶部位置；null 表示跟随列表实际位置。
  double? _dragTop;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, c) {
        final h = c.maxHeight;
        return ValueListenableBuilder<Iterable<ItemPosition>>(
          valueListenable: widget.positions,
          builder: (ctx, positions, _) {
            final m = _metrics(h, positions);
            final top =
                (_dragTop ?? m.top).clamp(0.0, m.maxTop).toDouble();

            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) {
                // 点轨道直接跳到对应位置（拖动时不会误触发）。
                final t = (d.localPosition.dy - m.thumbH / 2)
                    .clamp(0.0, m.maxTop)
                    .toDouble();
                _apply(m, t);
              },
              onVerticalDragStart: (d) {
                final inThumb = d.localPosition.dy >= top &&
                    d.localPosition.dy <= top + m.thumbH;
                if (inThumb) {
                  setState(() => _dragTop = top);
                } else {
                  final t = (d.localPosition.dy - m.thumbH / 2)
                      .clamp(0.0, m.maxTop)
                      .toDouble();
                  setState(() => _dragTop = t);
                  _apply(m, t);
                }
              },
              onVerticalDragUpdate: (d) {
                final t = ((_dragTop ?? top) + d.delta.dy)
                    .clamp(0.0, m.maxTop)
                    .toDouble();
                setState(() => _dragTop = t);
                _apply(m, t);
              },
              onVerticalDragEnd: (_) => setState(() => _dragTop = null),
              onVerticalDragCancel: () => setState(() => _dragTop = null),
              child: CustomPaint(
                size: Size(c.maxWidth, h),
                painter: _BrowserScrollbarPainter(
                  top: top,
                  thumbHeight: m.thumbH,
                  thumbWidth: widget.thumbWidth,
                  trackColor: widget.trackColor,
                  thumbColor: widget.thumbColor,
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _apply(_ScrollMetrics m, double top) {
    if (m.maxTop <= 0) return;
    final f = top / m.maxTop;
    widget.onJump((f * m.maxScroll).round());
  }

  _ScrollMetrics _metrics(
    double h,
    Iterable<ItemPosition> positions,
  ) {
    final count = widget.itemCount();
    var visible = 0;
    var first = 0;
    var leading = 0.0;
    var found = false;

    for (final p in positions) {
      if (p.itemTrailingEdge > 0 && p.itemLeadingEdge < 1) {
        visible++;
        if (!found || p.index < first) {
          found = true;
          first = p.index;
          leading = p.itemLeadingEdge;
        }
      }
    }

    if (!found || count <= 0) {
      return _ScrollMetrics(thumbH: h, top: 0, maxTop: 0, maxScroll: 1);
    }

    final thumbH = math.min(h, math.max(_minThumb, h * visible / count));
    final maxTop = math.max(0.0, h - thumbH);
    final maxScroll = math.max(1, count - visible);
    final raw = first + leading.clamp(-1.0, 0.0).toDouble();
    final top =
        (raw / maxScroll).clamp(0.0, 1.0).toDouble() * maxTop;
    return _ScrollMetrics(
      thumbH: thumbH,
      top: top,
      maxTop: maxTop,
      maxScroll: maxScroll,
    );
  }
}

class _ScrollMetrics {
  const _ScrollMetrics({
    required this.thumbH,
    required this.top,
    required this.maxTop,
    required this.maxScroll,
  });

  final double thumbH;
  final double top;
  final double maxTop;
  final int maxScroll;
}

class _BrowserScrollbarPainter extends CustomPainter {
  const _BrowserScrollbarPainter({
    required this.top,
    required this.thumbHeight,
    required this.thumbWidth,
    required this.trackColor,
    required this.thumbColor,
  });

  final double top;
  final double thumbHeight;
  final double thumbWidth;
  final Color trackColor;
  final Color thumbColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.height <= 0 || size.width <= 0) return;
    final w = thumbWidth.clamp(2.0, size.width).toDouble();
    final left = size.width - w;

    // 轨道
    final trackRect = Rect.fromLTWH(left, 0, w, size.height);
    canvas.drawRRect(
      RRect.fromRectAndRadius(trackRect, Radius.circular(w / 2)),
      Paint()..color = trackColor,
    );

    // 拖动块
    final thumbRect = Rect.fromLTWH(left, top, w, thumbHeight);
    canvas.drawRRect(
      RRect.fromRectAndRadius(thumbRect, Radius.circular(w / 2)),
      Paint()..color = thumbColor,
    );
  }

  @override
  bool shouldRepaint(covariant _BrowserScrollbarPainter old) =>
      old.top != top ||
      old.thumbHeight != thumbHeight ||
      old.thumbWidth != thumbWidth ||
      old.trackColor != trackColor ||
      old.thumbColor != thumbColor;
}

// ==================== 悬浮翻页按钮 ====================

class _BrowserFloatingPageButton extends StatelessWidget {
  const _BrowserFloatingPageButton({
    required this.size,
    required this.color,
    required this.up,
    required this.onTap,
  });

  final double size;
  final Color color;
  final bool up;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg =
        color.computeLuminance() > 0.5 ? Colors.black87 : Colors.white;
    return Material(
      color: color,
      shape: const CircleBorder(),
      elevation: 2,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Icon(
          up ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
          size: size * 0.62,
          color: fg,
        ),
      ),
    );
  }
}

class _VisibleRange {
  const _VisibleRange({
    required this.first,
    required this.last,
    required this.visible,
  });

  final int first;
  final int last;
  final int visible;
}

/// 以流式方式读取文件计算 MD5，避免把整个大文件读进内存。
/// 使用 crypto 包自带的 Hash.bind，按文件原生分块流式转换（无需 AccumulatorSink，
/// 该符号并不属于 crypto 的公开 API，用它会导致编译失败）。
Future<String> _md5FileOfPath(String path) async {
  final digest = await md5.bind(File(path).openRead()).single;
  return digest.toString();
}
