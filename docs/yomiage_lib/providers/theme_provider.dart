import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/theme_service.dart';

/// テーマモード状態管理用のNotifier
class ThemeNotifier extends StateNotifier<AppThemeMode> {
  ThemeNotifier() : super(ThemeService.getThemeMode());

  /// テーマモードを変更
  Future<void> setThemeMode(AppThemeMode mode) async {
    await ThemeService.setThemeMode(mode);
    state = mode;
  }

  /// 設定からテーマモードを再読み込み
  void refreshFromSettings() {
    state = ThemeService.getThemeMode();
  }
}

/// テーマモード状態管理用のProvider
final themeProvider = StateNotifierProvider<ThemeNotifier, AppThemeMode>((ref) {
  return ThemeNotifier();
});

/// 現在のテーマモードを監視するProvider（読み取り専用）
final currentThemeModeProvider = Provider<AppThemeMode>((ref) {
  return ref.watch(themeProvider);
});