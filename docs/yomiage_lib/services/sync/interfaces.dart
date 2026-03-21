import 'dart:async';

/// 同期状態を表す列挙型
enum SyncStatus {
  idle, // アイドル状態
  syncing, // 同期中
  synced, // 同期完了
  error // エラー発生
}

/// 同期状態管理のインターフェース
abstract class ISyncStateManager {
  /// 現在の同期状態を取得する
  SyncStatus get status;

  /// 同期状態のストリームを取得する
  Stream<SyncStatus> get statusStream;

  /// 同期状態を更新する
  void updateStatus(SyncStatus status);

  /// 最後の同期時刻を取得する
  DateTime? get lastSyncTime;

  /// 最後の同期時刻を更新する
  void updateLastSyncTime();
}

/// 削除ログサービスのインターフェース
abstract class IDeletionLogService {
  /// 削除済みカードのFirestore IDを取得する
  Future<Set<String>> fetchDeletedCardKeys();

  /// 削除済みデッキ名を取得する
  Future<Set<String>> fetchDeletedDeckNames();

  /// クリア済みデッキ名を取得する
  Future<Set<String>> fetchClearedDeckNames();

  /// カード操作のログを記録する
  Future<void> logCardOperation(String userId, String operationType,
      {String? firestoreId, String? deckName});

  /// デッキ操作のログを記録する
  Future<void> logDeckOperation(String userId, String operationType,
      {String? deckName});

  /// デッキ削除ログをクリーンアップする
  Future<void> cleanupDeckDeletionLog(String userId, String deckName);
}

/// 競合解決サービスのインターフェース
abstract class IConflictResolver {
  /// カードの競合を解決する
  bool resolveCardConflict(dynamic localCard, dynamic cloudCard);

  /// ローカルカードをクラウドデータで更新する
  bool updateLocalCardFromCloud(dynamic localCard, dynamic cloudCard);

  /// カードの内容が異なるかチェックする
  bool isCardContentDifferent(dynamic card1, dynamic card2);
}

/// 重要操作制御サービスのインターフェース
abstract class ICriticalOperationService {
  /// 重要操作が進行中かどうかを取得する
  bool get isInProgress;

  /// 重要操作を開始する
  void startCriticalOperation();

  /// 重要操作を終了する
  void endCriticalOperation();
}

/// デバッグユーティリティのインターフェース
abstract class ISyncDebugUtils {
  /// カードの比較結果をログ出力する
  void logCardComparison(dynamic localCard, dynamic cloudCard, String source);

  /// カードの更新詳細をログ出力する
  void logCardUpdateDetails(dynamic card, String when, {String source});

  /// 二つの数値のうち小さい方を返す
  int min(int a, int b);
}
