import 'package:flutter/material.dart';
import 'hive_service.dart';

/// テーマモード列挙型
enum AppThemeMode {
  light,   // ライトモード固定
  dark,    // ダークモード固定
  system,  // システム設定連動
}

/// テーマ管理サービス
class ThemeService {
  static const String _themeKey = 'themeMode';

  /// 現在のテーマモードを取得
  static AppThemeMode getThemeMode() {
    final settingsBox = HiveService.getSettingsBox();
    final themeModeString = settingsBox.get(_themeKey, defaultValue: 'system');
    
    switch (themeModeString) {
      case 'light':
        return AppThemeMode.light;
      case 'dark':
        return AppThemeMode.dark;
      case 'system':
      default:
        return AppThemeMode.system;
    }
  }

  /// テーマモードを保存
  static Future<void> setThemeMode(AppThemeMode mode) async {
    final settingsBox = HiveService.getSettingsBox();
    await settingsBox.put(_themeKey, mode.name);
  }

  /// AppThemeModeをFlutterのThemeModeに変換
  static ThemeMode toFlutterThemeMode(AppThemeMode appThemeMode) {
    switch (appThemeMode) {
      case AppThemeMode.light:
        return ThemeMode.light;
      case AppThemeMode.dark:
        return ThemeMode.dark;
      case AppThemeMode.system:
        return ThemeMode.system;
    }
  }

  /// テーマモードの表示名を取得
  static String getThemeModeDisplayName(AppThemeMode mode) {
    switch (mode) {
      case AppThemeMode.light:
        return 'ライトモード';
      case AppThemeMode.dark:
        return 'ダークモード';
      case AppThemeMode.system:
        return 'システム設定に従う';
    }
  }

  /// 利用可能なテーマモード一覧
  static List<AppThemeMode> get availableThemeModes => AppThemeMode.values;
}