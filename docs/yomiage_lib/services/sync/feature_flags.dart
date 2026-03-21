import '../hive_service.dart';

/// Firebase同期の段階導入用フラグ群（Hive settingsBox に保存）
///
/// - デフォルトは「既存挙動を変えない」を優先して false/true を設定する
/// - Firestore側の移行（バックフィル/Rules/Index）が完了したら順次ONにする想定
class FirebaseSyncFeatureFlags {
  FirebaseSyncFeatureFlags._();

  static const String _logicalDeleteKey = 'firebaseSync.useLogicalDelete';

  // 既存の削除ログ（card_operations/deck_operations）を
  // 「全件get」ではなく「増分カーソル」で読む（readスパイク緩和）
  static const String _incrementalDeletionLogKey =
      'firebaseSync.deletionLog.incremental';

  // ローカル変更時に「必ず」pending operationsへ積む（オフライン保証の完成形）
  static const String _alwaysEnqueueOnLocalWriteKey =
      'firebaseSync.pendingOps.alwaysEnqueueOnLocalWrite';

  static bool useLogicalDelete() {
    final box = HiveService.getSettingsBox();
    return box.get(_logicalDeleteKey, defaultValue: false) == true;
  }

  static void setUseLogicalDelete(bool enabled) {
    final box = HiveService.getSettingsBox();
    box.put(_logicalDeleteKey, enabled);
  }

  static bool useIncrementalDeletionLog() {
    final box = HiveService.getSettingsBox();
    return box.get(_incrementalDeletionLogKey, defaultValue: true) == true;
  }

  static void setUseIncrementalDeletionLog(bool enabled) {
    final box = HiveService.getSettingsBox();
    box.put(_incrementalDeletionLogKey, enabled);
  }

  static bool alwaysEnqueueOnLocalWrite() {
    final box = HiveService.getSettingsBox();
    return box.get(_alwaysEnqueueOnLocalWriteKey, defaultValue: false) == true;
  }

  static void setAlwaysEnqueueOnLocalWrite(bool enabled) {
    final box = HiveService.getSettingsBox();
    box.put(_alwaysEnqueueOnLocalWriteKey, enabled);
  }
}

