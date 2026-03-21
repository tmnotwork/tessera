import '../database/local_database.dart';
import 'sync_engine.dart';
import 'sync_notifier.dart';

/// ローカルに保存したあと [SyncEngine.syncIfOnline] を待ち、
/// 当該知識行の `dirty` で Supabase 反映の有無を文章化する。
Future<String> knowledgeSaveRemoteStatusAfterLocalPersist({
  required LocalDatabase localDb,
  required String knowledgeId,
}) async {
  if (!SyncEngine.isInitialized) {
    return 'ローカルに保存済み。Supabase同期が無効のため、リモートにはまだ載っていません';
  }
  await SyncEngine.instance.syncIfOnline();
  if (SyncNotifier.instance.state == SyncState.error) {
    final err = SyncNotifier.instance.lastError;
    return 'ローカルに保存済み。Supabaseへの反映に失敗しました: $err';
  }
  Map<String, dynamic>? row;
  if (knowledgeId.startsWith('local_')) {
    final lid = int.tryParse(knowledgeId.substring(6));
    if (lid != null) {
      row = await localDb.getByLocalId(LocalTable.knowledge, lid);
    }
  } else {
    row = await localDb.getBySupabaseId(LocalTable.knowledge, knowledgeId);
  }
  if (row == null) {
    return 'ローカルに保存済み。反映状況の確認に失敗しました';
  }
  final dirty = row['dirty'];
  if (dirty == 1) {
    return 'ローカルに保存済み。Supabaseにはまだ載っていません（同期待ち・科目の未同期など）';
  }
  return 'Supabaseに反映しました';
}
