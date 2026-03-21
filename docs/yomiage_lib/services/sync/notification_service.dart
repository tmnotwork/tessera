import 'dart:async';
import '../hive_service.dart';

/// 同期状態を表す列挙型
enum SyncStatus {
  idle, // アイドル状態
  syncing, // 同期中
  synced, // 同期完了
  error // エラー発生
}

/// 同期状態の通知と管理を担当するサービス
class SyncNotificationService {
  // 同期状態のリスナー
  static final StreamController<SyncStatus> _syncStatusController =
      StreamController<SyncStatus>.broadcast();
  
  // 同期状態
  static SyncStatus _status = SyncStatus.idle;
  
  // 最後に同期した時刻
  static DateTime? _lastSyncTime;

  /// 同期状態のストリームを取得
  static Stream<SyncStatus> get syncStatusStream => _syncStatusController.stream;

  /// 現在の同期状態を取得
  static SyncStatus get status => _status;

  /// 最後の同期時刻を取得
  static DateTime? getLastSyncTime() {
    if (_lastSyncTime == null) {
      // 保存されている値があれば読み込む
      final settingsBox = HiveService.getSettingsBox();
      final lastSyncTimeMillis = settingsBox.get('lastSyncTime');
      if (lastSyncTimeMillis != null) {
        _lastSyncTime = DateTime.fromMillisecondsSinceEpoch(lastSyncTimeMillis);
      }
    }
    return _lastSyncTime;
  }

  /// 最後の同期時刻を設定
  static void setLastSyncTime(DateTime time) {
    _lastSyncTime = time;
    // 設定に保存
    final settingsBox = HiveService.getSettingsBox();
    settingsBox.put('lastSyncTime', _lastSyncTime!.millisecondsSinceEpoch);
  }

  /// 同期状態を更新
  static void updateStatus(SyncStatus newStatus) {
    _status = newStatus;
    _syncStatusController.add(newStatus);
  }

  /// 同期完了状態に更新（時刻も更新）
  static void updateToSynced() {
    _lastSyncTime = DateTime.now();
    // 設定に保存
    final settingsBox = HiveService.getSettingsBox();
    settingsBox.put('lastSyncTime', _lastSyncTime!.millisecondsSinceEpoch);
    updateStatus(SyncStatus.synced);
  }

  /// 同期中状態に更新
  static void updateToSyncing() {
    updateStatus(SyncStatus.syncing);
  }

  /// エラー状態に更新
  static void updateToError() {
    updateStatus(SyncStatus.error);
  }

  /// アイドル状態に更新
  static void updateToIdle() {
    updateStatus(SyncStatus.idle);
  }

  /// リソースをクリーンアップ
  static void dispose() {
    _syncStatusController.close();
  }

  /// 状態をリセット
  static void reset() {
    _status = SyncStatus.idle;
    _lastSyncTime = null;
  }

  /// 現在の状態の説明を取得
  static String getStatusDescription() {
    switch (_status) {
      case SyncStatus.idle:
        return '同期待機中';
      case SyncStatus.syncing:
        return '同期中...';
      case SyncStatus.synced:
        return '同期完了';
      case SyncStatus.error:
        return '同期エラー';
    }
  }

  /// 最後の同期時刻の文字列表現を取得
  static String getLastSyncTimeString() {
    if (_lastSyncTime == null) {
      return '未同期';
    }
    return '${_lastSyncTime!.year}/${_lastSyncTime!.month.toString().padLeft(2, '0')}/${_lastSyncTime!.day.toString().padLeft(2, '0')} ${_lastSyncTime!.hour.toString().padLeft(2, '0')}:${_lastSyncTime!.minute.toString().padLeft(2, '0')}';
  }
} 