import 'dart:async';
import '../hive_service.dart';
import 'notification_service.dart';

/// 同期状態の包括的な管理を担当するサービス
class SyncStateManager {
  // シングルトンインスタンス
  static final SyncStateManager _instance = SyncStateManager._internal();
  static SyncStateManager get instance => _instance;
  SyncStateManager._internal();

  // 同期中かどうかのフラグ
  bool _isSyncing = false;

  // 自動同期が有効かどうかのフラグ
  bool _isAutoSyncEnabled = false;

  // 最後の同期エラー
  String? _lastSyncError;

  // 同期統計情報
  final Map<String, int> _syncStats = {};

  /// 同期中かどうかを取得
  bool get isSyncing => _isSyncing;

  /// 自動同期が有効かどうかを取得
  bool get isAutoSyncEnabled => _isAutoSyncEnabled;

  /// 最後の同期エラーを取得
  String? get lastSyncError => _lastSyncError;

  /// 同期統計情報を取得
  Map<String, int> get syncStats => Map.unmodifiable(_syncStats);

  /// 同期状態のストリームを取得
  Stream<SyncStatus> get syncStatusStream =>
      SyncNotificationService.syncStatusStream;

  /// 現在の同期状態を取得
  SyncStatus get status => SyncNotificationService.status;

  /// 最後の同期時刻を取得
  DateTime? getLastSyncTime() => SyncNotificationService.getLastSyncTime();

  /// 同期開始
  void startSync() {
    if (_isSyncing) {
      return;
    }

    _isSyncing = true;
    _lastSyncError = null;
    SyncNotificationService.updateStatus(SyncStatus.syncing);
  }

  /// 同期完了
  void completeSync({bool hasChanges = false}) {
    if (!_isSyncing) {
      return;
    }

    _isSyncing = false;
    SyncNotificationService.updateToSynced();

    if (hasChanges) {
    } else {}
  }

  /// 同期エラー
  void setSyncError(String error) {
    _isSyncing = false;
    _lastSyncError = error;
    SyncNotificationService.updateToError();
  }

  /// 同期状態をリセット
  void resetSyncState() {
    _isSyncing = false;
    _lastSyncError = null;
    SyncNotificationService.updateToIdle();
  }

  /// 自動同期を有効化
  void enableAutoSync() {
    _isAutoSyncEnabled = true;
    _saveAutoSyncSetting();
  }

  /// 自動同期を無効化
  void disableAutoSync() {
    _isAutoSyncEnabled = false;
    _saveAutoSyncSetting();
  }

  /// 同期統計を更新
  void updateSyncStats(String key, int value) {
    _syncStats[key] = (_syncStats[key] ?? 0) + value;
  }

  /// 同期統計をリセット
  void resetSyncStats() {
    _syncStats.clear();
  }

  /// 同期統計を取得
  Map<String, int> getSyncStats() {
    return Map.unmodifiable(_syncStats);
  }

  /// 同期状態の詳細情報を取得
  Map<String, dynamic> getSyncStateInfo() {
    return {
      'isSyncing': _isSyncing,
      'isAutoSyncEnabled': _isAutoSyncEnabled,
      'status': status.toString(),
      'lastSyncTime': getLastSyncTime()?.toIso8601String(),
      'lastSyncError': _lastSyncError,
      'syncStats': Map.unmodifiable(_syncStats),
    };
  }

  /// 同期状態の検証
  bool validateSyncState() {
    // 同期中なのに状態がsyncingでない場合
    if (_isSyncing && status != SyncStatus.syncing) {
      return false;
    }

    // 同期中でないのに状態がsyncingの場合
    if (!_isSyncing && status == SyncStatus.syncing) {
      return false;
    }

    return true;
  }

  /// 同期状態を修復
  void repairSyncState() {
    if (!validateSyncState()) {
      if (_isSyncing) {
        SyncNotificationService.updateStatus(SyncStatus.syncing);
      } else {
        SyncNotificationService.updateToIdle();
      }
    }
  }

  /// 設定の保存
  void _saveAutoSyncSetting() {
    final settingsBox = HiveService.getSettingsBox();
    settingsBox.put('autoSyncEnabled', _isAutoSyncEnabled);
  }

  /// 設定の読み込み
  void _loadAutoSyncSetting() {
    final settingsBox = HiveService.getSettingsBox();
    _isAutoSyncEnabled =
        settingsBox.get('autoSyncEnabled', defaultValue: false);
  }

  /// 初期化
  void initialize() {
    _loadAutoSyncSetting();
    repairSyncState();
  }

  /// 破棄
  void dispose() {
    _syncStats.clear();
  }

  /// デバッグ情報を出力
  void debugPrint() {}
}
