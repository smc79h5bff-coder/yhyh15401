import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';

import '../constants/app_colors.dart';

/// Light / Dark theme for DocDiff.
/// 主体色板由调用方通过 [scheme] 参数传入
/// （默认皮肤用 AppColors.lightScheme / darkScheme，
///  其他皮肤用 ColorScheme.fromSeed 生成）。
/// 默认皮肤通过 `signature` 额外启用 12/16/10 的圆角和弹窗柔影，
/// 其他皮肤保持原来的 6/18 扁平几何。
/// 弹窗 / 菜单 / 底部弹窗 / AppBar / 卡片一律强制白色（深色用 darkCard），
/// 不再从 scheme.surface 取，避免 M3 叠加 tint 后泛蓝。
class AppTheme {
  const AppTheme._();

  /// 非默认皮肤沿用的旧几何。
  static const double radius = 6;

  /// 非默认皮肤沿用的旧按钮圆角。
  static const double buttonRadius = 18;

  static ThemeData light(ColorScheme scheme, {bool signature = false}) =>
      _build(Brightness.light, scheme, signature: signature);

  static ThemeData dark(ColorScheme scheme, {bool signature = false}) =>
      _build(Brightness.dark, scheme, signature: signature);

  static ThemeData _build(
    Brightness brightness,
    ColorScheme scheme, {
    required bool signature,
  }) {
    final base = ThemeData(brightness: brightness, useMaterial3: true);
    final isDark = brightness == Brightness.dark;

    // 默认皮肤：更圆、带柔影，呼应新图标；
    // 其他皮肤：保持原来的 6/18 直角风格。
    final containerShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(signature ? 12.0 : radius),
    );
    final dialogShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(signature ? 16.0 : radius),
    );
    final buttonShapeTheme = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(signature ? 10.0 : buttonRadius),
    );
    final sheetShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(signature ? 20.0 : radius),
      ),
    );

    // ★ 页面底色（scaffold / canvas / appBar 兜底）：
    //   浅色模式一律纯白底（默认皮肤与所有自定义皮肤都白），
    //   不再用 fromSeed 生成的浅色调 surface 当页面底色；深色模式保持深色。
    //   卡片底色仍走 scheme.surfaceContainerLowest，跟随皮肤。
    final pageBg = isDark ? scheme.surface : Colors.white;

    // ★ 弹窗类统一底色：仍强制默认皮肤的中性灰，
    //   防止 fromSeed 皮肤把弹窗也染出主题色。
    final popupBg = isDark
        ? AppColors.darkScheme.surfaceContainer
        : AppColors.lightScheme.surface;

    // 默认皮肤的按钮统一成"淡底 + 主题蓝字、无描边"，
    // 背景取对比规则设置里批处理项的那层淡底。
    final buttonBg = scheme.secondaryContainer.withValues(alpha: 0.35);
    final buttonFg = scheme.primary;

    return base.copyWith(
      colorScheme: scheme,

      // 兼容遗留组件读 primaryColor / canvasColor。
      primaryColor: scheme.primary,
      canvasColor: pageBg,

      scaffoldBackgroundColor: pageBg,
      cardColor: scheme.surfaceContainerLowest,

      dividerColor: scheme.outlineVariant,
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),

      // ★ AppBar：白底、黑字（深色：深底、浅字），去掉 tint。
      appBarTheme: AppBarTheme(
        backgroundColor: pageBg,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
        iconTheme: IconThemeData(color: scheme.onSurface),
      ),

      // —— 动画 ——
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.fuchsia: FadeForwardsPageTransitionsBuilder(),
        },
      ),

      // ★ 所有弹窗类背景统一白（深色 darkCard）。
      dialogTheme: DialogThemeData(
        backgroundColor: popupBg,
        surfaceTintColor: Colors.transparent,
        shape: dialogShape,
        elevation: signature ? 8 : null,
        shadowColor:
            signature ? (isDark ? Colors.black54 : Colors.black26) : null,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
        contentTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 14,
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: popupBg,
        modalBackgroundColor: popupBg,
        surfaceTintColor: Colors.transparent,
        shape: sheetShape,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: popupBg,
        surfaceTintColor: Colors.transparent,
        shape: containerShape,
        elevation: signature ? 8 : null,
        textStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 14,
        ),
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: popupBg,
        surfaceTintColor: Colors.transparent,
      ),
      // 卡片也跟随 scheme。
      cardTheme: CardThemeData(
        shape: containerShape,
        elevation: signature ? 0 : null,
        color: scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
      ),
      snackBarTheme: SnackBarThemeData(shape: containerShape),
      chipTheme: ChipThemeData(shape: containerShape),

      // —— 按钮 ——
      // 默认皮肤：实心蓝底/黑描边一律换成淡底 + 主题蓝字；
      // 其他皮肤保持原样。
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: buttonShapeTheme,
          minimumSize: signature ? const Size(0, 44) : null,
          backgroundColor: signature ? buttonBg : null,
          foregroundColor: signature ? buttonFg : null,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          shape: buttonShapeTheme,
          minimumSize: signature ? const Size(0, 44) : null,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: buttonShapeTheme,
          minimumSize: signature ? const Size(0, 44) : null,
          backgroundColor: signature ? buttonBg : null,
          foregroundColor: signature ? buttonFg : null,
          side: signature ? BorderSide.none : null,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(shape: buttonShapeTheme).copyWith(
          // 默认皮肤：文字按钮统一用正文色（浅色近黑、深色自动反色），
          // 与「淡底 + 主题蓝字」的确认按钮拉开层级；禁用态保留 38% 透明度。
          foregroundColor: signature
              ? WidgetStateProperty.resolveWith(
                  (states) => states.contains(WidgetState.disabled)
                      ? scheme.onSurface.withValues(alpha: 0.38)
                      : scheme.onSurface,
                )
              : null,
        ),
      ),

      // —— 开关 ——
      // M3 默认拿 primary 当轨道、onPrimary 当滑块，
      // 默认皮肤的 onPrimary 是深海军蓝，落在浅蓝轨道上像颗黑圆点。
      // 这里改成「打开：深蓝轨道 + 白滑块；关闭：浅灰轨道 + 深灰滑块」，
      // 其他皮肤不设置、保持原样。
      switchTheme: signature
          ? SwitchThemeData(
              thumbColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.selected)
                    ? Colors.white
                    : scheme.onSurfaceVariant,
              ),
              trackColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.selected)
                    ? scheme.inversePrimary
                    : scheme.outlineVariant,
              ),
              trackOutlineColor:
                  const WidgetStatePropertyAll(Colors.transparent),
            )
          : null,

      // —— 文本 ——
      textTheme: base.textTheme.apply(
        bodyColor: scheme.onSurface,
        displayColor: scheme.onSurface,
      ),

      // —— 光标 / 选中 ——
      // 默认皮肤的 primary 是浅蓝，光标/选择柄要用深一档才看得见。
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: AppColors.textAccentOf(scheme),
        selectionColor: scheme.primary.withValues(alpha: 0.30),
        selectionHandleColor: AppColors.textAccentOf(scheme),
      ),
    );
  }
}
