import 'dart:io' show Platform;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kReleaseMode;

import 'diagnostics.dart';

/// 一次「选中两个文件 → 看到对比结果」的全链路耗时日志。
///
/// 全局单例，跨文件浏览器 / 规则管线 / diff worker 调用方 / 两个对比页共享。
/// 只驻留内存，不落盘；用户在诊断页或简洁对比页点「一键复制」时导出。
///
/// 设计要点：
///   · worker 是另一个 isolate，静态变量不共享，所以后台内部的分段耗时
///     由 _DiffPayload 带回来，再在 UI isolate 里用 [param] 写进这里。
///   · 日志默认随每次 [start] 清空，只保留最近一次对比，避免无限增长。
///   · 所有写入都是拼字符串，不开 Stopwatch 之外的额外对象，开销极小。
class CompareTimingLog {
  CompareTimingLog._();

  static final CompareTimingLog instance = CompareTimingLog._();

  static const int _maxLines = 8000;

  final List<String> _lines = <String>[];
  final Set<String> _extraKeys = <String>{};
  final Map<String, int> _costMs = <String, int>{};
  final Map<String, int> _costCount = <String, int>{};
  final Stopwatch _sw = Stopwatch();
  int _lastMark = 0;
  bool _active = false;
  String _mode = '';
  DateTime? _startedAt;
  int? _totalMs;

  bool get isEmpty => _lines.isEmpty;
  bool get active => _active;
  String get mode => _mode;
  int? get totalMs => _totalMs;
  int get lineCount => _lines.length;

  String get summary => _lines.isEmpty
      ? '还没有对比记录'
      : '$_mode · ${_totalMs ?? '进行中'}ms · $_lines.length 条';

  /// 开始记录一次新的对比。[mode] 传「简洁对比」或「完整对比」。
  void start(String mode) {
    // 诊断关闭：顺手把残留内容清掉，避免 dump 出上一次的旧数据。
    if (!Diagnostics.enabled) {
      if (_lines.isNotEmpty) clear();
      return;
    }
    _lines.clear();
    _extraKeys.clear();
    _costMs.clear();
    _costCount.clear();
    _mode = mode;
    _startedAt = DateTime.now();
    _totalMs = null;
    _sw.reset();
    _sw.start();
    _lastMark = 0;
    _active = true;

    _add('====== DocDiff 对比全量耗时 ======');
    _add('开始时间：${_startedAt!.toIso8601String()}');
    _add('对比模式：$mode');
    _add('构建模式：${kReleaseMode ? 'release' : 'debug / profile'}');
    _add('运行平台：$defaultTargetPlatform');
    try {
      _add('系统：${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
      _add('CPU 核数：${Platform.numberOfProcessors}');
      _add('系统地区：${Platform.localeName}');
    } catch (_) {
      _add('系统信息：不可用');
    }
    section('设备与环境参数');
  }

  /// 环境类参数（屏幕、字号、开关状态等），统一加前缀方便阅读。
  void env(String key, Object? value) {
    param('环境/$key', value);
  }

  /// 任意一条详细参数。
  /// 对比结束后仍允许补写（比如在诊断页补设备信息），只是不再加时间点。
  void param(String key, Object? value) {
    if (!Diagnostics.enabled || _lines.isEmpty) return;
    _add('  · $key = $value');
  }

  /// 分段标题，不参与计时。
  void section(String title) {
    if (!Diagnostics.enabled || _lines.isEmpty) return;
    _add('');
    _add('------ $title ------');
  }

  /// 打一个时间节点，自动算出与上一段的间隔。
  void mark(String label) {
    if (!Diagnostics.enabled || !_active) return;
    final now = _sw.elapsedMilliseconds;
    _add('[+${now - _lastMark}ms] $label  (累计 ${now}ms)');
    _lastMark = now;
  }

  /// 包一段同步代码单独测耗时，并把结果写进日志。
  /// 返回值原样透传，方便直接套在已有表达式外面。
  T measure<T>(String label, T Function() body) {
    if (!Diagnostics.enabled || !_active) return body();
    final sw = Stopwatch()..start();
    try {
      return body();
    } finally {
      sw.stop();
      _add('[${sw.elapsedMilliseconds}ms] $label');
      _lastMark = _sw.elapsedMilliseconds;
    }
  }

  /// 补一段不带计时的原始文本（例如帧统计、崩溃日志摘要）。
  void extra(String title, String text) {
    if (!Diagnostics.enabled || _lines.isEmpty || text.isEmpty) return;
    section(title);
    _add(text);
  }

  /// 同一份附加信息只写一次，避免用户连点几次「复制」把日志刷长。
  /// [start] 会清空这个去重集合。
  void extraOnce(String key, String title, String text) {
    if (!Diagnostics.enabled ||
        _lines.isEmpty ||
        text.isEmpty ||
        _extraKeys.contains(key)) {
      return;
    }
    _extraKeys.add(key);
    extra(title, text);
  }

  /// 结束一次记录。
  void end(String label) {
    if (!Diagnostics.enabled) {
      _active = false;
      return;
    }
    if (!_active) return;
    _totalMs = _sw.elapsedMilliseconds;
    _add('====== $label 结束，总计 ${_totalMs}ms ======');
    _sw.stop();
    _active = false;
  }

  /// 异常中断时也留一条，避免日志停在半截。
  void fail(String reason) {
    if (!Diagnostics.enabled) {
      _active = false;
      return;
    }
    if (!_active) return;
    _totalMs = _sw.elapsedMilliseconds;
    _add('====== 中断（${_totalMs}ms）：$reason ======');
    _sw.stop();
    _active = false;
  }

  /// 滚动期间会反复发生的小段开销（比如开「字差异」时的逐字 diff），
  /// 只累计次数与总毫秒，不逐条写日志，避免把导出内容刷爆。
  void addCost(String key, int ms) {
    if (!Diagnostics.enabled || _lines.isEmpty) return;
    _costMs[key] = (_costMs[key] ?? 0) + ms;
    _costCount[key] = (_costCount[key] ?? 0) + 1;
  }

  String get costSummary {
    if (_costMs.isEmpty) return '  （本次未开启字差异，或没有逐字计算）';
    final buf = StringBuffer();
    for (final k in _costMs.keys) {
      buf.writeln('  · $k = 累计 ${_costMs[k]}ms / ${_costCount[k]} 次');
    }
    return buf.toString();
  }

  void clear() {
    _lines.clear();
    _extraKeys.clear();
    _costMs.clear();
    _costCount.clear();
    _sw.reset();
    _lastMark = 0;
    _active = false;
    _mode = '';
    _totalMs = null;
    _startedAt = null;
  }

  /// 导出成可复制的纯文本。
  String dump() {
    if (_lines.isEmpty) {
      return '还没有对比记录。请先在文件浏览器选中两个文件，点「对比」或「简洁对比」跑一次。';
    }
    final sb = StringBuffer()
      ..writeln(_lines.join('\n'))
      ..writeln()
      ..writeln('====== 滚动 / 渲染期间累计开销 ======')
      ..writeln(costSummary)
      ..writeln()
      ..writeln('====== 摘要 ======')
      ..writeln('模式：$_mode')
      ..writeln('总耗时：${_totalMs ?? "进行中"} ms')
      ..writeln('日志条数：${_lines.length}');
    return sb.toString();
  }

  void _add(String line) {
    if (!Diagnostics.enabled) return;
    _lines.add(line);
    if (_lines.length > _maxLines) {
      _lines.removeRange(0, _lines.length - _maxLines);
    }
  }
}
