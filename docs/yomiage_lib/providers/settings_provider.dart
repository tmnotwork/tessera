import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

// 設定関連のサービスクラス（仮実装）
// 必要に応じて SharedPreferences 以外の永続化方法に変更
class SettingsService {
  final SharedPreferences _prefs;

  SettingsService(this._prefs);

  // CSV 最終インポート日時を取得 (エポックミリ秒)
  int? getLastCsvImportTimeMillis() {
    return _prefs.getInt('lastCsvImportTime');
  }

  // CSV 最終インポート日時を保存 (エポックミリ秒)
  Future<void> setLastCsvImportTimeMillis(int millis) async {
    await _prefs.setInt('lastCsvImportTime', millis);
  }

  // 必要に応じて他の設定項目を追加
}

// SettingsService を提供する Provider
// アプリ起動時に SharedPreferences を非同期で初期化し、それを SettingsService に渡す
final settingsServiceProvider = FutureProvider<SettingsService>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  return SettingsService(prefs);
});
