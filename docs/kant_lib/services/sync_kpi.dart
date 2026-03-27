class SyncKpi {
  SyncKpi._();
  static int queryReads = 0; // クエリ由来のドキュメント取得数（get/query）
  static int docGets = 0; // 個別ドキュメントGET回数（doc.get）
  static int preWriteChecks = 0; // 書込み前の事前確認（状態ロールバック防止）
  // Firestore への書き込み回数（概算）
  // - docRef.set/update/delete を「1 write」として加算
  // - batch.commit は「含まれる write 数（set/update/delete の件数）」を加算
  static int writes = 0;
  // batch.commit の回数（補助指標）
  static int batchCommits = 0;
  static int watchStarts = 0; // ストリーム購読開始回数
  static int watchInitialReads = 0; // snapshots の初回スナップショット概算read
  static int watchChangeReads = 0; // snapshots の変更イベント概算read（docChanges）
  static int onDemandFetches = 0; // 必要時同期の実行回数
  static int versionFeedEvents = 0; // バージョン差分検知イベント数

  /// 現在のKPIをリセット（検証用）
  static void reset() {
    queryReads = 0;
    docGets = 0;
    preWriteChecks = 0;
    writes = 0;
    batchCommits = 0;
    watchStarts = 0;
    watchInitialReads = 0;
    watchChangeReads = 0;
    onDemandFetches = 0;
    versionFeedEvents = 0;
  }

  static Map<String, int> snapshot() {
    return {
      'queryReads': queryReads,
      'docGets': docGets,
      'preWriteChecks': preWriteChecks,
      'writes': writes,
      'batchCommits': batchCommits,
      'watchStarts': watchStarts,
      'watchInitialReads': watchInitialReads,
      'watchChangeReads': watchChangeReads,
      'onDemandFetches': onDemandFetches,
      'versionFeedEvents': versionFeedEvents,
    };
  }

  static Map<String, int> delta(
    Map<String, int> before,
    Map<String, int> after,
  ) {
    int d(String k) => (after[k] ?? 0) - (before[k] ?? 0);
    return {
      'queryReads': d('queryReads'),
      'docGets': d('docGets'),
      'preWriteChecks': d('preWriteChecks'),
      'watchStarts': d('watchStarts'),
      'watchInitialReads': d('watchInitialReads'),
      'watchChangeReads': d('watchChangeReads'),
      'onDemandFetches': d('onDemandFetches'),
      'versionFeedEvents': d('versionFeedEvents'),
    };
  }

  static void logSummary() {
    // デバッグ用途の軽量サマリ（ログ出力は削減）
  }

  static void recordOnDemandFetch(String category) {
    onDemandFetches += 1;
  }

  static void recordVersionFeed(int count) {
    versionFeedEvents += count;
  }
}