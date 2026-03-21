import 'package:flutter/foundation.dart';

import 'sync_engine.dart';

/// 画面表示用にローカル複製をリモートに近づける。
///
/// 教材一覧・問題・学習状態などをローカルに持つ画面の [_load] 先頭で `await` する。
/// Web / 未初期化時は何もしない。並行呼び出しは [SyncEngine.sync] 内で同一同期に合流する。
Future<void> ensureSyncedForLocalRead() async {
  if (kIsWeb) return;
  if (!SyncEngine.isInitialized) return;
  await SyncEngine.instance.syncIfOnline();
}
