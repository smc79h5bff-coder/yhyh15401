import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants/app_colors.dart';
import '../storage/persistent_notifier.dart';
import '../storage/pref_keys.dart';
import 'app_theme.dart';

/// 可选皮肤。
///
/// `defaultBlue` 是默认皮肤，直接用手搓的 AppColors.lightScheme / darkScheme；
/// 其余皮肤用 [seed] 通过 ColorScheme.fromSeed 生成。
///
/// EnumPrefNotifier 存的是枚举 name，不是 index，所以调整顺序或重命名
/// 不会让旧用户已保存的皮肤错位（找不到的旧名字回落到默认皮肤）。
/// 新增皮肤建议加在末尾，避免设置页的顺序跳动。
///
/// seed 原则：低饱和（30-50%），避免纯 Material 500/800 色阶。
/// 高饱和种子会让 fromSeed 生成刺眼的 primaryContainer，
/// 列表底、按钮底、选中态都会"荧光"，切皮肤时全 App 都在跳。
enum AppSkin {
  defaultBlue('图标蓝', Color(0xFF7FB2F0)),
  pink('品红', Color(0xFFA8509C)),
  orange('赭石', Color(0xFF8B6B4A)),
  yellow('琥珀', Color(0xFFC8BF5E)),
  green('苔绿', Color(0xFF4A6B5A)),
  teal('湖青', Color(0xFF5D98AB)),
  blue('墨蓝', Color(0xFF3A4A6B)),
  indigoBlue('紫蓝', Color(0xFF7878CC));

  final String label;
  final Color seed;
  const AppSkin(this.label, this.seed);
}

class SkinNotifier extends EnumPrefNotifier<AppSkin> {
  SkinNotifier()
      : super(
          key: PrefKeys.skin,
          values: AppSkin.values,
          initial: AppSkin.defaultBlue,
        );
}

final skinProvider =
    NotifierProvider<SkinNotifier, AppSkin>(SkinNotifier.new);

ColorScheme _lightOf(AppSkin skin) => skin == AppSkin.defaultBlue
    ? AppColors.lightScheme
    : ColorScheme.fromSeed(seedColor: skin.seed);

ColorScheme _darkOf(AppSkin skin) => skin == AppSkin.defaultBlue
    ? AppColors.darkScheme
    : ColorScheme.fromSeed(
        seedColor: skin.seed,
        brightness: Brightness.dark,
      );

/// 默认皮肤用新图标的圆角/柔影几何，其他皮肤保持原样。
ThemeData lightThemeOf(AppSkin skin) => AppTheme.light(
      _lightOf(skin),
      signature: skin == AppSkin.defaultBlue,
    );
ThemeData darkThemeOf(AppSkin skin) => AppTheme.dark(
      _darkOf(skin),
      signature: skin == AppSkin.defaultBlue,
    );
