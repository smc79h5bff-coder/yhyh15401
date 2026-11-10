import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/debug/crash_logger.dart';
import 'core/debug/diagnostics.dart';
import 'core/storage/shared_preferences_provider.dart';
import 'features/reader/reader_load_log.dart';

Future<void> main() async {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // 崩溃诊断日志（写文件，可从"诊断"页查看）。
    await CrashLogger.instance.init();

    // ============================================================
    // 诊断总开关由用户在「诊断」页控制，存在本地设置里。
    // 关掉后所有诊断写入（耗时、阅读页日志、操作历史、崩溃日志、
    // 闪退痕迹、帧监控）都是空操作，等于没有这套功能。
    // ============================================================

    final prefsSw = Stopwatch()..start();
    final prefs = await SharedPreferences.getInstance();
    Diagnostics.init(prefs);
    CrashLogger.instance.setEnabled(Diagnostics.enabled);

    // 帧回调一直挂着，关闭时内部直接 return；这样中途打开诊断也能立刻有数据。
    ReaderLoadLog.instance.installFrameMonitor();
    // 未捕获异常钩子仍保持手动开启：它会接管 FlutterError.onError，
    // 排查完记得关掉，避免把错误都吞进日志里。
    // ReaderLoadLog.instance.installErrorHooks();

    ReaderLoadLog.instance.info(
      'SharedPreferences 加载 ${prefsSw.elapsedMilliseconds}ms',
    );

    runApp(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
        ],
        child: const DocDiffApp(),
      ),
    );
  }, (error, stack) {
    CrashLogger.instance.log('Zone', error.toString(), stack);
  });
}
