import 'dart:async';

import 'package:flutter/foundation.dart';

import 'sync_engine.dart';
import 'sync_metadata_store.dart';

/// 画面表示用にローカル複製をリモートに近づける。
///
/// 教材一覧・問題・学習状態などをローカルに持つ画面の [_load] 先頭で `await` する。
/// Web / 未初期化時は何もしない。並行呼び出しは [SyncEngine.sync] 内で同一同期に合流する。
Future<void> ensureSyncedForLocalRead() async {
  if (kIsWeb) return;
  if (!SyncEngine.isInitialized) return;
  await SyncEngine.instance.syncIfOnline();
}

/// 画面の初期表示をブロックせず、必要なときだけ背景同期を起動する。
///
/// [minInterval] 以内に Pull が終わっていればスキップする。
/// 端末間で学習状況を揃えるため、既定はスキップなし（常に Pull→Push を試みる）。
Future<void> triggerBackgroundSyncWithThrottle({
  Duration minInterval = Duration.zero,
}) async {
  if (kIsWeb) return;
  if (!SyncEngine.isInitialized) return;

  final lastPullAtIso = await SyncMetadataStore.getLastPullAt();
  if (lastPullAtIso != null && lastPullAtIso.isNotEmpty) {
    final lastPullAt = DateTime.tryParse(lastPullAtIso);
    if (lastPullAt != null &&
        DateTime.now().difference(lastPullAt) < minInterval) {
      return;
    }
  }
  unawaited(SyncEngine.instance.syncIfOnline());
}
