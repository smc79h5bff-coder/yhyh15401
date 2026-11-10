import 'package:flutter/material.dart';

/// PRD §5: visualization highlights.
/// Light and dark variants per category.
class AppColors {
  const AppColors._();

  // Diff highlights — light mode
  static const Color addedLight = Color(0xFF2ECC71);
  static const Color deletedLight = Color(0xFFE74C3C);
  static const Color modifiedLight = Color(0xFFF1C40F);

  // Diff highlights — dark mode (PRD §5)
  static const Color addedDark = Color(0xFF3DDC84);
  static const Color deletedDark = Color(0xFFFF6B6B);
  static const Color modifiedDark = Color(0xFFFFD60A);

  static Color addedOf(BuildContext c) =>
      Theme.of(c).brightness == Brightness.dark ? addedDark : addedLight;
  static Color deletedOf(BuildContext c) =>
      Theme.of(c).brightness == Brightness.dark ? deletedDark : deletedLight;
  static Color modifiedOf(BuildContext c) =>
      Theme.of(c).brightness == Brightness.dark ? modifiedDark : modifiedLight;

  /// 默认皮肤的 primary 是浅蓝 #7FB2F0，白底上做文字只有 2.2:1，
  /// 用作 13-14px 标签/选中态文字会发虚。
  /// 这类"主题蓝文字"统一走它：默认皮肤给深一档的品牌蓝，
  /// 其余皮肤仍是各自的 primary，外观不受影响。
  static Color textAccentOf(ColorScheme cs) =>
      cs.brightness == Brightness.light && cs.primary == lightScheme.primary
          ? const Color(0xFF2E6FC4)
          : cs.primary;

  // ---------------------------------------------------------------
  // 浅色主题：主色是图标蓝，其余全部纯灰（R=G=B）
  // ---------------------------------------------------------------
  static const ColorScheme lightScheme = ColorScheme(
    brightness: Brightness.light,

    // —— 主色：取自图标的浅蓝，比渐变里最深的 #96C6FF 再深一档 ——
    // 底色变浅后白字不可读，压在上面的文字/图标统一用深蓝。
    primary: Color(0xFF6FA9F0),
    onPrimary: Color(0xFF0B2A55),
    primaryContainer: Color(0xFFDCEBFF),
    onPrimaryContainer: Color(0xFF12335C),

    // —— 次要色：同色系更灰一点 ——
    secondary: Color(0xFF6B7A90),
    onSecondary: Color(0xFFFFFFFF),
    secondaryContainer: Color(0xFFE6EBF2),
    onSecondaryContainer: Color(0xFF23272E),

    tertiary: Color(0xFF616161),
    onTertiary: Color(0xFFFFFFFF),
    tertiaryContainer: Color(0xFFE0E0E0),
    onTertiaryContainer: Color(0xFF1C1C1C),

    error: Color(0xFFB3261E),
    onError: Color(0xFFFFFFFF),
    errorContainer: Color(0xFFF9DEDC),
    onErrorContainer: Color(0xFF410E0B),

    // —— 背景：纯白底 ——
    surface: Color(0xFFFFFFFF),
    onSurface: Color(0xFF1C1C1C),
    surfaceDim: Color(0xFFE0E0E0),
    surfaceBright: Color(0xFFFFFFFF),
    surfaceContainerLowest: Color(0xFFFFFFFF),
    surfaceContainerLow: Color(0xFFF7F7F8),
    surfaceContainer: Color(0xFFEEEEEE),
    surfaceContainerHigh: Color(0xFFE8E8E8),
    surfaceContainerHighest: Color(0xFFE0E0E0),
    onSurfaceVariant: Color(0xFF616161),

    outline: Color(0xFF9E9E9E),
    outlineVariant: Color(0xFFE0E0E0),

    // 透明，防止组件把背景染偏色
    surfaceTint: Color(0x00000000),

    inverseSurface: Color(0xFF303030),
    onInverseSurface: Color(0xFFF5F5F5),
    inversePrimary: Color(0xFF2E6FC4),

    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
  );

  // ---------------------------------------------------------------
  // 夜间主题：主色是浅蓝，其余纯灰
  // ---------------------------------------------------------------
  static const ColorScheme darkScheme = ColorScheme(
    brightness: Brightness.dark,

    // —— 主色 ——
    primary: Color(0xFF96C6FF),
    onPrimary: Color(0xFF0B2A55),
    primaryContainer: Color(0xFF1B3A5F),
    onPrimaryContainer: Color(0xFFDDE9FF),

    secondary: Color(0xFFA9B8CE),
    onSecondary: Color(0xFF1B2430),
    secondaryContainer: Color(0xFF2A3444),
    onSecondaryContainer: Color(0xFFDEE5EE),

    tertiary: Color(0xFFBDBDBD),
    onTertiary: Color(0xFF1C1C1C),
    tertiaryContainer: Color(0xFF424242),
    onTertiaryContainer: Color(0xFFE0E0E0),

    error: Color(0xFFFFB4AB),
    onError: Color(0xFF690005),
    errorContainer: Color(0xFF93000A),
    onErrorContainer: Color(0xFFFFDAD6),

    // —— 背景：纯灰 ——
    surface: Color(0xFF121212),
    onSurface: Color(0xFFE0E0E0),
    surfaceDim: Color(0xFF121212),
    surfaceBright: Color(0xFF424242),
    surfaceContainerLowest: Color(0xFF0A0A0A),
    surfaceContainerLow: Color(0xFF1A1C1F),
    surfaceContainer: Color(0xFF1E1E1E),
    surfaceContainerHigh: Color(0xFF262626),
    surfaceContainerHighest: Color(0xFF303030),
    onSurfaceVariant: Color(0xFFBDBDBD),

    outline: Color(0xFF757575),
    outlineVariant: Color(0xFF424242),

    surfaceTint: Color(0x00000000),

    inverseSurface: Color(0xFFE0E0E0),
    onInverseSurface: Color(0xFF1C1C1C),
    inversePrimary: Color(0xFF2E6FC4),

    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
  );
}
