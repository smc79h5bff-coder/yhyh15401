import 'dart:async';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:shared_preferences/shared_preferences.dart';

import '../storage/pref_keys.dart';

/// 诊断总开关。
///
/// 一个开关管全部诊断写入：对比耗时日志、阅读页日志、文件统计、
/// 操作历史、崩溃日志、闪退痕迹、帧监控。
///
/// 关闭时，每个写入方法第一行就 return —— 不拼字符串、不建 Stopwatch、
/// 不写文件、不占内存，开销和"没有这套诊断代码"时一样。
///
/// 开关状态存本地，下次启动沿用。默认**开**：这个 App 的用户主要是
/// 自己排查问题，默认开着才拿得到数据；嫌吵可以随时关。
class Diagnostics {
  Diagnostics._();

  /// 监听它可以让界面跟着开关实时变化（诊断页、清单页的复制图标）。
  static final ValueNotifier<bool> enabledNotifier = ValueNotifier<bool>(true);

  static bool get enabled => enabledNotifier.value;

  static SharedPreferences? _prefs;

  /// main() 里 runApp 之前调一次。
  static void init(SharedPreferences prefs) {
    _prefs = prefs;
    enabledNotifier.value =
        prefs.getBool(PrefKeys.diagnosticsEnabled) ?? true;
  }

  /// 切换开关：内存立刻生效，磁盘异步保存。
  static void setEnabled(bool value) {
    if (enabledNotifier.value == value) return;
    enabledNotifier.value = value;
    final p = _prefs;
    if (p != null) {
      unawaited(p.setBool(PrefKeys.diagnosticsEnabled, value));
    }
  }
}
