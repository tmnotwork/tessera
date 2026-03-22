import 'package:supabase_flutter/supabase_flutter.dart';

import '../database/local_database.dart';
import '../repositories/knowledge_repository.dart';
import '../supabase/knowledge_supabase_delete_verify.dart';
import '../sync/sync_engine.dart';
import '../sync/sync_notifier.dart';

/// ローカル行から Supabase の knowledge id を解決（ソフト削除直後も getByLocalId で参照可）
Future<String?> resolveRemoteKnowledgeIdForDeleteReport(
  LocalDatabase db,
  String knowledgeId,
) async {
  if (!knowledgeId.startsWith('local_')) {
    return knowledgeId;
  }
  final lid = int.tryParse(knowledgeId.substring(6));
  if (lid == null || lid <= 0) return null;
  final row = await db.getByLocalId(LocalTable.knowledge, lid);
  final sid = row?['supabase_id'] as String?;
  if (sid != null && sid.isNotEmpty) return sid;
  return null;
}

/// `local_knowledge` には `subject_id` 列が無いため、[Knowledge.subjectId] は常に null になりがち。
/// `subject_local_id` → `local_subjects.supabase_id` で科目 UUID を解決する。
Future<String?> resolveSubjectSupabaseIdForKnowledge(
  LocalDatabase db,
  String knowledgeId,
) async {
  Map<String, dynamic>? kRow;
  if (knowledgeId.startsWith('local_')) {
    final lid = int.tryParse(knowledgeId.substring(6));
    if (lid == null || lid <= 0) return null;
    kRow = await db.getByLocalId(LocalTable.knowledge, lid);
  } else {
    kRow = await db.getBySupabaseId(LocalTable.knowledge, knowledgeId);
  }
  if (kRow == null) return null;
  final sLocal = kRow['subject_local_id'] as int?;
  if (sLocal == null) return null;
  final sRow = await db.getByLocalId(LocalTable.subjects, sLocal);
  final sid = sRow?['supabase_id'] as String?;
  if (sid != null && sid.isNotEmpty) return sid;
  return null;
}

/// 行が無ければ OK。存在するなら deleted=1 であること（一覧に出ない条件）。
Future<void> assertLocalKnowledgeTombstoneOrGone(
  LocalDatabase db,
  String knowledgeId,
) async {
  if (knowledgeId.startsWith('local_')) {
    final lid = int.tryParse(knowledgeId.substring(6));
    if (lid == null || lid <= 0) return;
    final row = await db.getByLocalId(LocalTable.knowledge, lid);
    if (row == null) return;
    if (row['deleted'] != 1 && row['deleted'] != true) {
      throw StateError(
        'ローカルがまだ deleted=0 です（同期Pullで復活した可能性）。一覧に残ります',
      );
    }
    return;
  }
  final row = await db.getBySupabaseId(LocalTable.knowledge, knowledgeId);
  if (row == null) return;
  if (row['deleted'] != 1 && row['deleted'] != true) {
    throw StateError(
      'ローカルがまだ deleted=0 です（id=$knowledgeId）。一覧に残ります',
    );
  }
}

/// 画面で取れる subjectId と DB から解決した UUID をマージ（local_ 科目は一覧検証に使わない）
Future<String?> _effectiveSubjectSupabaseId({
  required LocalDatabase? localDatabase,
  required String knowledgeId,
  String? subjectSupabaseIdFromUi,
}) async {
  var s = subjectSupabaseIdFromUi;
  if (s != null && s.isNotEmpty && !s.startsWith('local_')) {
    return s;
  }
  if (localDatabase != null) {
    final resolved = await resolveSubjectSupabaseIdForKnowledge(localDatabase, knowledgeId);
    if (resolved != null && resolved.isNotEmpty) return resolved;
  }
  return null;
}

/// 知識カード削除を実行し、スナックバー用の詳細メッセージを返す。
///
/// 一覧と同条件の検証には **Supabase の subject UUID** が必要。
/// ローカルでは [resolveSubjectSupabaseIdForKnowledge] で補う。
Future<String> runKnowledgeDeleteWithSupabaseReport({
  required String knowledgeId,
  required LocalDatabase? localDatabase,
  String? subjectSupabaseId,
}) async {
  final client = Supabase.instance.client;

  if (localDatabase == null) {
    final report = await hardDeleteKnowledgeOnSupabaseWithSelect(client, knowledgeId);
    if (!report.ok) throw StateError(report.message);
    final parts = <String>[report.message];
    final subj = await _effectiveSubjectSupabaseId(
      localDatabase: null,
      knowledgeId: knowledgeId,
      subjectSupabaseIdFromUi: subjectSupabaseId,
    );
    if (subj != null) {
      final lr = await verifyKnowledgeNotInActiveSubjectList(
        client,
        subjectSupabaseId: subj,
        knowledgeRemoteId: knowledgeId,
      );
      if (!lr.ok) throw StateError('${report.message} / ${lr.message}');
      parts.add(lr.message);
    }
    return parts.join(' ');
  }

  final repo = createKnowledgeRepository(localDatabase);
  await repo.delete(knowledgeId);

  final remoteIdCaptured = await resolveRemoteKnowledgeIdForDeleteReport(localDatabase, knowledgeId);
  await assertLocalKnowledgeTombstoneOrGone(localDatabase, knowledgeId);

  final effectiveSubject = await _effectiveSubjectSupabaseId(
    localDatabase: localDatabase,
    knowledgeId: knowledgeId,
    subjectSupabaseIdFromUi: subjectSupabaseId,
  );

  final parts = <String>['ローカルDBで削除（ソフト）済み'];

  if (SyncEngine.isInitialized) {
    await SyncEngine.instance.syncIfOnline();
    if (SyncNotifier.instance.state == SyncState.error) {
      parts.add('同期: エラー ${SyncNotifier.instance.lastError}');
    } else {
      parts.add('同期: 実行済み');
    }
  } else {
    parts.add('同期エンジンなし');
  }

  await assertLocalKnowledgeTombstoneOrGone(localDatabase, knowledgeId);

  if (remoteIdCaptured == null || remoteIdCaptured.isEmpty) {
    parts.add('Supabase id 未割当（プッシュ後にリモートへ載ります）');
    return parts.join('。');
  }

  KnowledgeSupabaseDeleteReport remoteReport;
  if (effectiveSubject != null && effectiveSubject.isNotEmpty) {
    remoteReport = await verifyKnowledgeNotInActiveSubjectList(
      client,
      subjectSupabaseId: effectiveSubject,
      knowledgeRemoteId: remoteIdCaptured,
    );
    if (!remoteReport.ok) {
      final up = await softDeleteKnowledgeOnSupabaseWithSelect(client, remoteIdCaptured);
      if (!up.ok) {
        throw StateError('${parts.join('。')}。${up.message}');
      }
      parts.add(up.message);
      remoteReport = await verifyKnowledgeNotInActiveSubjectList(
        client,
        subjectSupabaseId: effectiveSubject,
        knowledgeRemoteId: remoteIdCaptured,
      );
    }
  } else {
    remoteReport = await softDeleteKnowledgeOnSupabaseWithSelect(client, remoteIdCaptured);
    parts.add('科目UUID未解決のため一覧相当SELECTは省略');
  }

  parts.add(remoteReport.message);
  if (!remoteReport.ok) {
    throw StateError(parts.join('。'));
  }

  await assertLocalKnowledgeTombstoneOrGone(localDatabase, knowledgeId);

  return parts.join('。');
}
