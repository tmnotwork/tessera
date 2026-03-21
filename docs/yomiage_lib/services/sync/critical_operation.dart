/// 重要操作の制御を担当するサービス
///
/// 責任: 重要操作の制御
/// 独立性: 外部依存なし、単純なフラグ管理
/// 影響範囲: 既存コードでの参照箇所が少ない
class CriticalOperationService {
  /// 重要操作が進行中かどうかのフラグ
  static bool _isCriticalOperationInProgress = false;

  /// 重要操作が進行中かどうかを取得する
  ///
  /// 戻り値: 重要操作が進行中かどうか
  static bool get isInProgress => _isCriticalOperationInProgress;

  /// 重要操作を開始する
  ///
  /// このメソッドを呼び出すと、他の同期処理が一時的に停止されます。
  /// 操作完了後は必ず endCriticalOperation() を呼び出してください。
  static void startCriticalOperation() {
    _isCriticalOperationInProgress = true;
  }

  /// 重要操作を終了する
  ///
  /// 重要操作が完了したことを通知し、他の同期処理を再開します。
  static void endCriticalOperation() {
    _isCriticalOperationInProgress = false;
  }

  /// 重要操作の状態をリセットする（緊急時用）
  ///
  /// 注意: 通常は使用しないでください。デバッグや緊急時の復旧用です。
  static void resetCriticalOperationState() {
    _isCriticalOperationInProgress = false;
  }

  /// 重要操作の状態を確認する（デバッグ用）
  ///
  /// 戻り値: 現在の状態を表す文字列
  static String getStatusDescription() {
    return _isCriticalOperationInProgress ? '重要操作進行中' : '通常状態';
  }
}
