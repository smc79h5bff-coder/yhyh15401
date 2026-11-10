import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/skin.dart';

/// 默认皮肤下的"品牌渐变"图标。
///
/// 用 [ShaderMask] 把任意 Material 图标重涂成渐变，不必逐个复刻路径；
/// 渐变取值与 AppFileIcon 完全一致，保证文件图标和界面图标是同一套语言。
///
/// 其他皮肤原样退回普通 [Icon]，保持各自的 Material 观感。
class GradientIcon extends ConsumerWidget {
  const GradientIcon(this.icon, {super.key, this.size, this.fallbackColor});

  final IconData icon;

  /// 图标边长；为空则沿用 IconTheme。
  final double? size;

  /// 非默认皮肤下的颜色；为空则沿用 IconTheme。
  final Color? fallbackColor;

  static const List<Color> colors = <Color>[
    Color(0xFFDEEDFF),
    Color(0xFF96C6FF),
    Color(0xFFC8E1FF),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(skinProvider) != AppSkin.defaultBlue) {
      return Icon(icon, size: size, color: fallbackColor);
    }
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (bounds) => const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: colors,
        stops: <double>[0.0, 0.5, 1.0],
      ).createShader(bounds),
      child: Icon(icon, size: size),
    );
  }
}
