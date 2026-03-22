import 'package:supabase_flutter/supabase_flutter.dart';

import '../database/local_database.dart';

/// Supabase 側の削除・ソフト削除の結果説明
class KnowledgeSupabaseDeleteReport {
  const KnowledgeSupabaseDeleteReport({required this.ok, required this.message});

  final bool ok;
  final String message;
}

bool _hasDeletedAt(dynamic v) {
  if (v == null) return false;
  return v.toString().trim().isNotEmpty;
}

/// 一覧取得と同様に `subject_id` で絞ったうえで、当該 id が「有効行」として返るか。
Future<KnowledgeSupabaseDeleteReport> verifyKnowledgeNotInActiveSubjectList(
  SupabaseClient client, {
  required String subjectSupabaseId,
  required String knowledgeRemoteId,
}) async {
  try {
    final rows = await client
        .from('knowledge')
        .select('id,deleted_at')
        .eq('subject_id', subjectSupabaseId)
        .eq('id', knowledgeRemoteId);
    final list = rows as List;
    if (list.isEmpty) {
      return const KnowledgeSupabaseDeleteReport(
        ok: true,
        message: '科目内SELECT: 行なし（一覧に出ない条件）',
      );
    }
    final m = list.first as Map<String, dynamic>;
    if (_hasDeletedAt(m['deleted_at'])) {
      return const KnowledgeSupabaseDeleteReport(
        ok: true,
        message: '科目内SELECT: deleted_at あり（一覧フィルタで除外される）',
      );
    }
    return KnowledgeSupabaseDeleteReport(
      ok: false,
      message:
          '科目内SELECT: まだ有効行として返る（subject_id=$subjectSupabaseId / 一覧と同じバグ）',
    );
  } catch (e) {
    return KnowledgeSupabaseDeleteReport(ok: false, message: '科目内SELECT エラー: $e');
  }
}

/// ソフト削除を実行し、SELECT で更新件数を確認する
Future<KnowledgeSupabaseDeleteReport> softDeleteKnowledgeOnSupabaseWithSelect(
  SupabaseClient client,
  String remoteId,
) async {
  try {
    final ts = LocalDatabase.nowUtc();
    final updated = await client
        .from('knowledge')
        .update({'deleted_at': ts})
        .eq('id', remoteId)
        .select('id');
    final n = (updated as List).length;
    if (n >= 1) {
      return KnowledgeSupabaseDeleteReport(
        ok: true,
        message: 'Supabase: deleted_at を書き込み（$n件）— 成功',
      );
    }
    return const KnowledgeSupabaseDeleteReport(
      ok: false,
      message: 'Supabase: deleted_at 更新が0件（RLS・行なし・id不一致）',
    );
  } catch (e) {
    return KnowledgeSupabaseDeleteReport(ok: false, message: 'Supabase 更新エラー: $e');
  }
}

/// 物理削除を実行し、SELECT で削除件数を確認する
Future<KnowledgeSupabaseDeleteReport> hardDeleteKnowledgeOnSupabaseWithSelect(
  SupabaseClient client,
  String remoteId,
) async {
  try {
    final deleted = await client.from('knowledge').delete().eq('id', remoteId).select('id');
    final n = (deleted as List).length;
    if (n >= 1) {
      return KnowledgeSupabaseDeleteReport(
        ok: true,
        message: 'Supabase: 物理削除（$n件）— 成功',
      );
    }
    final still = await client.from('knowledge').select('id').eq('id', remoteId).maybeSingle();
    if (still == null) {
      return const KnowledgeSupabaseDeleteReport(
        ok: true,
        message: 'Supabase: 行なし — 既に削除済みとみなせます',
      );
    }
    return const KnowledgeSupabaseDeleteReport(
      ok: false,
      message: 'Supabase: DELETE が 0 件（RLS・anon 権限・id を確認）',
    );
  } catch (e) {
    return KnowledgeSupabaseDeleteReport(ok: false, message: 'Supabase 削除エラー: $e');
  }
}
