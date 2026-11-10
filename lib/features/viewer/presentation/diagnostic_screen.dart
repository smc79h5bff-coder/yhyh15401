// 诊断页：只保留「总开关 / 导出文件 / 清空」三件事。
// 耗时、文件、性能等明细不再显示在页面上，全部写进导出的 txt，
// 这样再长的日志也不会被截断（以前阅读页日志超过 6000 字就被截掉）。
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/debug/compare_timing_log.dart';
import '../../../core/debug/crash_logger.dart';
import '../../../core/debug/diagnostics.dart';
import '../../import/presentation/providers/import_providers.dart';
import '../../reader/reader_load_log.dart';
import 'crash_trace.dart';
import 'providers/diff_viewer_providers.dart';

// ==================== 诊断工具 ====================

class ViewerDiag {
  ViewerDiag._();
  static const int _maxEntries = 2000;
  static final List<({String tag, int ms})> _entries = [];
  static final Stopwatch _sw = Stopwatch()..start();

  static void reset() {
    _entries.clear();
    _sw.reset();
    _sw.start();
  }

  static void mark(String tag) {
    if (!Diagnostics.enabled) return;
    _entries.add((tag: tag, ms: _sw.elapsedMilliseconds));
    // ★ 防止无界增长；超出上限丢弃最旧一条（mark 不在帧循环里，O(n) 可接受）。
    if (_entries.length > _maxEntries) _entries.removeAt(0);
  }

  static List<({String tag, int ms})> get entries =>
      List.unmodifiable(_entries);
}

/// 本次会话的操作历史。
class DiagHistory {
  DiagHistory._();
  static const int _max = 500;
  static final List<({DateTime time, String msg})> _entries = [];

  static void record(String msg) {
    if (!Diagnostics.enabled) return;
    _entries.add((time: DateTime.now(), msg: msg));
    if (_entries.length > _max) _entries.removeAt(0);
  }

  static List<({DateTime time, String msg})> get entries =>
      List.unmodifiable(_entries);

  static void clear() => _entries.clear();
}

String dumpChars(String s, {Set<int> diffAt = const {}}) {
  final sb = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    final mark = diffAt.contains(i) ? '★' : ' ';
    String vis;
    if (c == 0x0D) {
      vis = r'\r';
    } else if (c == 0x0A) {
      vis = r'\n';
    } else if (c == 0x09) {
      vis = r'\t';
    } else if (c == 0x20) {
      vis = '␣';
    } else if (c == 0x3000) {
      vis = '全角空格';
    } else if (c == 0xA0) {
      vis = 'NBSP';
    } else if (c == 0x200B) {
      vis = 'ZWSP';
    } else if (c == 0x200C) {
      vis = 'ZWNJ';
    } else if (c == 0x200D) {
      vis = 'ZWJ';
    } else if (c == 0xFEFF) {
      vis = 'BOM';
    } else if (c == 0x2028) {
      vis = '行分隔符';
    } else if (c == 0x2029) {
      vis = '段分隔符';
    } else if (c < 0x20 || c == 0x7F) {
      vis = '控制字符';
    } else {
      vis = String.fromCharCode(c);
    }
    sb.writeln(
        '$mark[$i] $vis  U+${c.toRadixString(16).toUpperCase().padLeft(4, '0')}');
  }
  return sb.toString();
}

Map<String, int> charStats(String s) {
  var crlf = 0;
  var lf = 0;
  var cr = 0;
  var fwSpace = 0;
  var nbsp = 0;
  var zwsp = 0;
  var bom = 0;
  var tab = 0;
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c == 0x0A) {
      if (i > 0 && s.codeUnitAt(i - 1) == 0x0D) {
        crlf++;
      } else {
        lf++;
      }
    } else if (c == 0x0D) {
      cr++;
    } else if (c == 0x3000) {
      fwSpace++;
    } else if (c == 0xA0) {
      nbsp++;
    } else if (c == 0x200B) {
      zwsp++;
    } else if (c == 0xFEFF) {
      bom++;
    } else if (c == 0x09) {
      tab++;
    }
  }
  return {
    'CRLF(\\r\\n)': crlf,
    'LF(\\n)': lf,
    'CR(\\r)': cr,
    '全角空格 U+3000': fwSpace,
    'NBSP U+00A0': nbsp,
    'ZWSP U+200B': zwsp,
    'BOM U+FEFF': bom,
    'Tab': tab,
  };
}

// ==================== 诊断页 ====================

/// 诊断页：开关 / 导出文件 / 清空。
///
/// 关掉开关后，所有诊断写入（耗时、文件统计、历史、崩溃、闪退痕迹、
/// 帧监控、阅读页日志）都会在写入口直接 return，等于没有这套功能。
class DiagnosticScreen extends ConsumerWidget {
  const DiagnosticScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ValueListenableBuilder<bool>(
      valueListenable: Diagnostics.enabledNotifier,
      builder: (context, on, _) {
        final s = Theme.of(context).colorScheme;
        final divider = Theme.of(context).dividerColor;
        return Scaffold(
          appBar: AppBar(title: const Text('诊断')),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              Container(
                decoration: BoxDecoration(
                  color: s.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: divider, width: 0.5),
                ),
                padding: const EdgeInsets.fromLTRB(16, 12, 12, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '开启诊断',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                on
                                    ? '记录耗时、文件、崩溃和帧数据'
                                    : '关闭后不写入任何内容，零开销',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: s.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Switch(
                          value: on,
                          onChanged: (v) {
                            Diagnostics.setEnabled(v);
                            CrashLogger.instance.setEnabled(v);
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Divider(height: 1, color: divider),
                    const SizedBox(height: 8),
                    Text(
                      on
                          ? (CompareTimingLog.instance.isEmpty
                              ? '还没有对比记录'
                              : '最近一次：${CompareTimingLog.instance.summary}')
                          : '诊断已关闭，没有可导出的内容',
                      style: TextStyle(
                        fontSize: 12,
                        color: s.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              SizedBox(
                height: 44,
                child: FilledButton(
                  onPressed: on ? () => _exportReport(context, ref) : null,
                  child: const Text('导出诊断文件'),
                ),
              ),
              const SizedBox(height: 7),
              Center(
                child: Text(
                  '保存为 txt，内容不截断',
                  style: TextStyle(fontSize: 11, color: s.onSurfaceVariant),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: 44,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: s.error,
                    side: BorderSide(color: divider, width: 0.5),
                  ),
                  onPressed: on ? () => _clearAll(context) : null,
                  child: const Text('清空诊断记录'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 清空所有诊断记录（不改开关）。二次确认，因为清掉就没了。
  Future<void> _clearAll(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('清空诊断记录', style: TextStyle(fontSize: 15)),
        content: const Text(
          '会清空对比耗时、操作历史、崩溃日志、闪退痕迹和阅读页日志，'
          '清空后无法恢复。',
          style: TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    CompareTimingLog.instance.clear();
    ReaderLoadLog.instance.reset();
    ViewerDiag.reset();
    DiagHistory.clear();
    CrashTrace.clear();
    await CrashLogger.instance.clear();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已清空诊断记录')),
    );
  }

  /// 导出成 txt 文件。内容全部给全，不做任何截断。
  Future<void> _exportReport(BuildContext context, WidgetRef ref) async {
    final text = await _buildReport(context, ref);
    if (!context.mounted) return;
    final bytes = Uint8List.fromList(utf8.encode(text));
    final t = DateTime.now();
    String two(int n) => n < 10 ? '0$n' : '$n';
    final stamp = '${t.year}${two(t.month)}${two(t.day)}-'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
    try {
      final out = await FilePicker.saveFile(
        fileName: 'docdiff-diag-$stamp.txt',
        bytes: bytes,
        mimeType: 'text/plain',
        dialogTitle: '导出诊断文件',
        type: FileType.custom,
        allowedExtensions: ['txt'],
      );
      if (!context.mounted) return;
      final kb = (bytes.length / 1024).toStringAsFixed(1);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(out == null ? '已取消导出' : '已保存诊断文件（$kb KB）'),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败：$e')),
      );
    }
  }

  /// 完整诊断报告。页面里已经不显示明细，全靠这份文件，所以一段都不截断。
  Future<String> _buildReport(BuildContext context, WidgetRef ref) async {
    _fillDiagExtras(context);
    final sb = StringBuffer()
      ..writeln('==========================================')
      ..writeln(' DocDiff 诊断报告')
      ..writeln(' 导出时间：${DateTime.now().toIso8601String()}')
      ..writeln('==========================================')
      ..writeln();

    sb.writeln('----- 1. 对比全量耗时 -----');
    sb.writeln(CompareTimingLog.instance.dump());

    sb.writeln('\n----- 2. 性能 -----');
    sb.writeln(ref.read(lastDiffPerfProvider)?.oneLine ?? '（还没有 diff 结果）');

    sb.writeln('\n----- 3. 文件 -----');
    sb.writeln(_fileSection(ref));

    sb.writeln('\n----- 4. 渲染耗时 -----');
    final timeEntries = ViewerDiag.entries;
    if (timeEntries.isEmpty) {
      sb.writeln('（还没有记录）');
    } else {
      var prev = 0;
      for (final e in timeEntries) {
        sb.writeln('+${e.ms - prev}ms  (累计 ${e.ms}ms)  ${e.tag}');
        prev = e.ms;
      }
    }

    sb.writeln('\n----- 5. 操作历史 -----');
    final hist = DiagHistory.entries;
    if (hist.isEmpty) {
      sb.writeln('（还没有记录）');
    } else {
      String two(int n) => n < 10 ? '0$n' : '$n';
      for (final e in hist) {
        final tt = e.time;
        sb.writeln(
            '${two(tt.hour)}:${two(tt.minute)}:${two(tt.second)}  ${e.msg}');
      }
    }

    sb.writeln('\n----- 6. 崩溃日志 -----');
    try {
      final log = await CrashLogger.instance.read();
      sb.writeln(log.isEmpty ? '（空）' : log);
    } catch (e) {
      sb.writeln('读取失败: $e');
    }

    sb.writeln('\n----- 7. 闪退痕迹 -----');
    sb.writeln(await CrashTrace.read());

    sb.writeln('\n----- 8. 阅读页日志（全文，不截断） -----');
    sb.writeln(_readerLogText());

    return sb.toString();
  }

  /// 设备环境参数。阅读页日志**不**拼进来，改为报告第 8 段全文，
  /// 免得长日志把对比耗时那一段挤爆（以前超过 6000 字就被截断）。
  void _fillDiagExtras(BuildContext context) {
    final log = CompareTimingLog.instance;
    if (log.isEmpty) return;
    final mq = MediaQuery.of(context);
    final rl = ReaderLoadLog.instance;
    final buf = StringBuffer()
      ..writeln('  诊断页屏幕逻辑宽高 = '
          '${mq.size.width.toStringAsFixed(1)} x ${mq.size.height.toStringAsFixed(1)}')
      ..writeln('  诊断页设备像素比 = ${mq.devicePixelRatio}')
      ..writeln('  诊断页顶部安全区 = ${mq.padding.top}')
      ..writeln('  诊断页底部安全区 = ${mq.padding.bottom}')
      ..writeln('  诊断页主题亮度 = ${Theme.of(context).brightness}')
      ..writeln('  慢帧(>16.67ms)总数 = ${rl.slowFrameCount}')
      ..writeln('  阅读页日志条数 = ${rl.entries.length}')
      ..writeln('  阅读页日志字符数 = ${rl.sizeInBytes}（全文见本报告第 8 段）');
    log.extraOnce('diag-extras', '设备环境与帧监控（附加）', buf.toString());
  }

  /// 左右两份预处理后文本的行数、特殊字符统计、前 20 行预览。
  String _fileSection(WidgetRef ref) {
    final orig = ref.read(preprocessedOriginalProvider);
    final mod = ref.read(preprocessedModifiedProvider);
    if (orig.isEmpty && mod.isEmpty) return '（还没有导入两份文件）';
    final buf = StringBuffer();
    void one(String name, String text) {
      final lines = text.split('\n');
      buf.writeln('-- $name --');
      buf.writeln('  字符数：${text.length}　行数：${lines.length}');
      final hit = charStats(text).entries.where((e) => e.value > 0).toList();
      if (hit.isEmpty) {
        buf.writeln('  特殊字符：无');
      } else {
        for (final e in hit) {
          buf.writeln('  ${e.key}：${e.value}');
        }
      }
      buf.writeln('  前 20 行预览（方括号是字符数）：');
      for (var i = 0; i < lines.length && i < 20; i++) {
        final t = lines[i];
        final shown = t.length > 40 ? '${t.substring(0, 40)}…' : t;
        buf.writeln('  ${(i + 1).toString().padLeft(3)} [${t.runes.length}] $shown');
      }
      buf.writeln();
    }

    one('左 / A 文件（预处理后）', orig);
    one('右 / B 文件（预处理后）', mod);
    return buf.toString();
  }

  /// 阅读页日志全文。这个类内部有 40000 行 / 4MB 上限，除此之外不再裁剪。
  String _readerLogText() {
    final rl = ReaderLoadLog.instance;
    if (rl.isEmpty) return '（阅读页日志为空）';
    return '条数：${rl.entries.length}　字符数：${rl.sizeInBytes}\n\n${rl.dump()}';
  }
}
