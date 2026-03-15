import 'package:shared_preferences/shared_preferences.dart';

/// 同期メタデータの永続化（shared_preferences）。
/// Web では SyncEngine を使わないため、Mobile/Desktop のみ使用。
class SyncMetadataStore {
  SyncMetadataStore._();
  static const _keyLastPullAt = 'sync.last_pull_at';
  static const _keyIsSyncing = 'sync.is_syncing';

  static Future<SharedPreferences> _prefs() async {
    return SharedPreferences.getInstance();
  }

  /// 最終 Pull 完了時刻（ISO8601）。null の場合は初回で全件 Pull する。
  static Future<String?> getLastPullAt() async {
    final prefs = await _prefs();
    return prefs.getString(_keyLastPullAt);
  }

  static Future<void> setLastPullAt(String? iso8601) async {
    final prefs = await _prefs();
    if (iso8601 == null) {
      await prefs.remove(_keyLastPullAt);
    } else {
      await prefs.setString(_keyLastPullAt, iso8601);
    }
  }

  /// 同期中フラグ（クラッシュ後のリカバリ用）
  static Future<bool> getIsSyncing() async {
    final prefs = await _prefs();
    return prefs.getBool(_keyIsSyncing) ?? false;
  }

  static Future<void> setIsSyncing(bool value) async {
    final prefs = await _prefs();
    await prefs.setBool(_keyIsSyncing, value);
  }
}
