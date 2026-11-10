import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/skin.dart';

/// 文件 / 文件夹图标：复刻用户设计的两枚 SVG。
///
/// 两枚 SVG 原本画在 48×48 画布里，但实际占位不同
/// （文件夹 42×30、文件 28×40），直接缩小后文件夹会明显比文件"胖"。
/// 这里统一收进 24×24 的光学盒：文件夹 20×15、文件 15×19，
/// 两者的视觉面积接近，并且都与系统图标的光学尺寸对齐。
///
/// 只有默认皮肤用这套图标，其他皮肤回退到原来的 Material 图标。
class AppFileIcon extends ConsumerWidget {
  const AppFileIcon({
    super.key,
    required this.isDir,
    this.isZip = false,
    this.size = 24,
    this.tint,
  });

  /// true 画文件夹，false 画文件。
  final bool isDir;

  /// true 画成压缩包：文件夹形状 + 正面一条竖向拉链。
  final bool isZip;

  /// 图标边长（按 24 的光学盒等比缩放）。
  final double size;

  /// 传值时退化成单色绘制，用于 zip 内这类需要弱化的条目。
  final Color? tint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final skin = ref.watch(skinProvider);
    if (skin != AppSkin.defaultBlue) {
      final s = Theme.of(context).colorScheme;
      return Icon(
        isZip
            ? Icons.folder_zip
            : (isDir ? Icons.folder : Icons.insert_drive_file_outlined),
        size: size,
        // 其他皮肤保持原来的 Material 观感：文件夹用主题色，文件/压缩包用弱化色。
        color: tint ??
            (isDir && !isZip ? s.primary : s.onSurfaceVariant),
      );
    }
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _AppFileIconPainter(
          isDir: isDir,
          isZip: isZip,
          tint: tint,
        ),
      ),
    );
  }
}

class _AppFileIconPainter extends CustomPainter {
  const _AppFileIconPainter({
    required this.isDir,
    this.isZip = false,
    this.tint,
  });

  final bool isDir;
  final bool isZip;
  final Color? tint;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);

    final body = (isDir || isZip) ? _folderPath() : _filePath();

    final fill = Paint()..isAntiAlias = true;
    final solid = tint;
    if (solid != null) {
      fill.color = solid;
    } else {
      fill.shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        // 暂时浅色也用原稿（深色主题那套）渐变，先看效果。
        colors: const [
          Color(0xFFDEEDFF),
          Color(0xFF96C6FF),
          Color(0xFFC8E1FF),
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(const Rect.fromLTWH(0, 0, 24, 24));
    }
    canvas.drawPath(body, fill);

    if (isZip) {
      _paintZipper(canvas);
    } else if (!isDir) {
      canvas.drawPath(
        _foldPath(),
        Paint()
          ..isAntiAlias = true
          ..color = Colors.white.withValues(alpha: 0.5),
      );
    }

    canvas.restore();
  }

  /// 压缩包正面的竖向拉链：一排白色短横，中间留缝。
  void _paintZipper(Canvas canvas) {
    final paint = Paint()
      ..isAntiAlias = true
      ..color = Colors.white.withValues(alpha: 0.9);
    const x = 11.1;
    const w = 1.8;
    const dash = 1.25;
    const step = 1.95;
    var y = 7.15;
    while (y + dash <= 18.6) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y, w, dash),
          const Radius.circular(0.6),
        ),
        paint,
      );
      y += step;
    }
  }

  /// 原 SVG：48×48 画布中 x3..45 / y12..42，等比收进 20×15。
  Path _folderPath() {
    const r = Radius.elliptical(1.91, 2.0);
    return Path()
      ..moveTo(3.90, 4.50)
      ..lineTo(9.62, 4.50)
      ..arcToPoint(
        const Offset(10.38, 4.90),
        radius: const Radius.elliptical(0.95, 1.0),
      )
      ..lineTo(11.52, 6.50)
      ..lineTo(20.10, 6.50)
      ..arcToPoint(const Offset(22.00, 8.50), radius: r)
      ..lineTo(22.00, 17.50)
      ..arcToPoint(const Offset(20.10, 19.50), radius: r)
      ..lineTo(3.90, 19.50)
      ..arcToPoint(const Offset(2.00, 17.50), radius: r)
      ..lineTo(2.00, 6.50)
      ..arcToPoint(const Offset(3.90, 4.50), radius: r)
      ..close();
  }

  /// 原 SVG：48×48 画布中 x10..38 / y4..44，等比收进 15×19。
  Path _filePath() {
    const r = Radius.elliptical(2.14, 1.90);
    return Path()
      ..moveTo(6.64, 2.50)
      ..lineTo(13.61, 2.50)
      ..lineTo(19.50, 7.73)
      ..lineTo(19.50, 19.60)
      ..arcToPoint(const Offset(17.36, 21.50), radius: r)
      ..lineTo(6.64, 21.50)
      ..arcToPoint(const Offset(4.50, 19.60), radius: r)
      ..lineTo(4.50, 4.40)
      ..arcToPoint(const Offset(6.64, 2.50), radius: r)
      ..close();
  }

  /// 右上折角。
  Path _foldPath() {
    return Path()
      ..moveTo(13.61, 2.50)
      ..lineTo(19.50, 7.73)
      ..lineTo(15.21, 7.73)
      ..arcToPoint(
        const Offset(13.61, 6.30),
        radius: const Radius.elliptical(1.61, 1.43),
      )
      ..close();
  }

  @override
  bool shouldRepaint(covariant _AppFileIconPainter oldDelegate) =>
      oldDelegate.isDir != isDir ||
      oldDelegate.isZip != isZip ||
      oldDelegate.tint != tint;
}
