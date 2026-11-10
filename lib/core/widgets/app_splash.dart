import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Flutter 侧启动页。
///
/// Android 12+ 的系统闪屏只支持纯色底 + 圆形遮罩图标，
/// 画不出柔光渐变和柔影。这里在首帧就盖一层自己画的启动页，
/// 让系统那张纯色底一闪而过，停留 0.3 秒后再淡出交给主界面。
class AppSplash extends StatefulWidget {
  const AppSplash({
    super.key,
    required this.child,
    this.enabled = true,
  });

  final Widget child;

  /// 非默认皮肤没有这套品牌配色，直接显示 [child]。
  final bool enabled;

  @override
  State<AppSplash> createState() => _AppSplashState();
}

class _AppSplashState extends State<AppSplash> {
  static const Duration _hold = Duration(milliseconds: 300);
  static const Duration _fade = Duration(milliseconds: 260);

  late bool _show;
  bool _fading = false;

  @override
  void initState() {
    super.initState();
    _show = widget.enabled;
    if (_show) {
      Future<void>.delayed(_hold, () {
        if (!mounted) return;
        setState(() => _fading = true);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    // 始终保留 Stack 结构，只摘掉上层启动页，
    // 避免根节点类型变化导致下面的主界面被整棵重建。
    return Stack(
      children: [
        widget.child,
        if (_show)
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: _fading ? 0 : 1,
                duration: _fade,
                curve: Curves.easeOut,
                onEnd: () {
                  if (_fading && mounted) {
                    setState(() => _show = false);
                  }
                },
                child: const _SplashView(),
              ),
            ),
          ),
      ],
    );
  }
}

class _SplashView extends StatelessWidget {
  const _SplashView();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // 浅色与 Android ≤11 的 launch_background 渐变对齐，
    // 深色与 values-night 的 #121212 / #172231 对齐，切换时不跳色。
    final gradient = isDark
        ? const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF121212), Color(0xFF172231), Color(0xFF121212)],
            stops: [0.0, 0.5, 1.0],
          )
        : const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFF5FAFF), Color(0xFFEAF4FF), Color(0xFFF5FAFF)],
            stops: [0.0, 0.5, 1.0],
          );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: DecoratedBox(
        decoration: BoxDecoration(gradient: gradient),
        child: Center(
          child: Container(
            width: 128,
            height: 128,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(30),
              boxShadow: [
                BoxShadow(
                  color: isDark
                      ? Colors.black.withValues(alpha: 0.55)
                      : const Color(0xFF2E6FC4).withValues(alpha: 0.28),
                  blurRadius: 34,
                  spreadRadius: 2,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(30),
              child: Image.asset(
                'assets/images/app_icon.png',
                fit: BoxFit.cover,
                // 首帧解码可能还没完成，加载好后淡入，避免图标突然跳出。
                frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                  if (wasSynchronouslyLoaded) return child;
                  return AnimatedOpacity(
                    opacity: frame == null ? 0 : 1,
                    duration: const Duration(milliseconds: 120),
                    child: child,
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
