

/// 同期可能なモデルの基盤インターフェース
mixin SyncableModel {
  // 同期用フィールド
  String? get cloudId;
  set cloudId(String? value);
  
  DateTime get lastModified;
  set lastModified(DateTime value);
  
  DateTime? get lastSynced;
  set lastSynced(DateTime? value);
  
  bool get isDeleted;
  set isDeleted(bool value);
  
  String get deviceId;
  set deviceId(String value);
  
  int get version;
  set version(int value);
  
  String get userId;
  set userId(String value);

  // 同期用メソッド
  Map<String, dynamic> toCloudJson();
  void fromCloudJson(Map<String, dynamic> json);
  bool hasConflictWith(SyncableModel other);
  SyncableModel resolveConflictWith(SyncableModel other);
  
  // 同期状態チェック
  bool get needsSync => lastSynced == null || lastModified.isAfter(lastSynced!);
  bool get isLocalOnly => cloudId == null;
  
  // 同期メタデータ更新
  void markAsModified([String? deviceId]) {
    // 競合判定からlastModifiedを外す場合でも、needsSync（未同期判定）のため更新は必須。
    // 端末時計ズレ耐性のため、保存する値はUTCに統一する。
    lastModified = DateTime.now().toUtc();
    version++;
    if (deviceId != null) this.deviceId = deviceId;
  }
  
  void markAsSynced() {
    lastSynced = DateTime.now().toUtc();
  }
}

/// 競合解決の結果
enum ConflictResolution {
  localNewer,    // ローカルが新しい
  remoteNewer,   // リモートが新しい
  localWins,     // 同時刻だがローカル優先
  remoteWins,    // 同時刻だがリモート優先
  needsManual,   // 手動解決が必要
}

/// 同期操作の結果
class SyncResult {
  final bool success;
  final String? error;
  final int syncedCount;
  final int failedCount;
  final List<ConflictResolution> conflicts;

  SyncResult({
    required this.success,
    this.error,
    this.syncedCount = 0,
    this.failedCount = 0,
    this.conflicts = const [],
  });
}

/// 同期状態
enum SyncStatus {
  idle,          // 待機中
  syncing,       // 同期中
  synced,        // 同期完了
  completed,     // 完了
  error,         // エラー
  failed,        // 失敗
  offline,       // オフライン
  conflict,      // 競合あり
}