import 'package:flutter/foundation.dart';
import 'package:postgrest/postgrest.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// `question_learning_states` を RLS 下で確実に反映する。
/// PostgREST の複合キー upsert が環境によって不安定なため、SELECT → UPDATE / INSERT に分ける。
class QuestionLearningStateRemote {
  QuestionLearningStateRemote._();

  /// 学習状態を保存。成功時はリモート行の UUID、失敗時は null。
  static Future<String?> upsertState({
    required SupabaseClient client,
    required String learnerId,
    required String questionId,
    String? knownRemoteRowId,
    required Map<String, dynamic> stateFields,
  }) async {
    // UPDATE では learner_id / question_id を変えない
    final updatePayload = Map<String, dynamic>.from(stateFields)
      ..remove('learner_id')
      ..remove('question_id');

    try {
      if (knownRemoteRowId != null && knownRemoteRowId.isNotEmpty) {
        await client
            .from('question_learning_states')
            .update(updatePayload)
            .eq('id', knownRemoteRowId);
        return knownRemoteRowId;
      }

      final existing = await client
          .from('question_learning_states')
          .select('id')
          .eq('learner_id', learnerId)
          .eq('question_id', questionId)
          .maybeSingle();

      if (existing != null) {
        final id = existing['id']?.toString();
        if (id != null && id.isNotEmpty) {
          await client.from('question_learning_states').update(updatePayload).eq('id', id);
          return id;
        }
      }

      final insertPayload = <String, dynamic>{
        'learner_id': learnerId,
        'question_id': questionId,
        ...stateFields,
      };

      try {
        final inserted = await client
            .from('question_learning_states')
            .insert(insertPayload)
            .select('id')
            .single();
        return inserted['id']?.toString();
      } on PostgrestException catch (e) {
        // 競合: 別リクエストが先に INSERT した
        final dup = e.code == '23505' ||
            e.message.toLowerCase().contains('duplicate key') ||
            e.message.toLowerCase().contains('unique constraint');
        if (dup) {
          final again = await client
              .from('question_learning_states')
              .select('id')
              .eq('learner_id', learnerId)
              .eq('question_id', questionId)
              .maybeSingle();
          final id = again?['id']?.toString();
          if (id != null && id.isNotEmpty) {
            await client.from('question_learning_states').update(updatePayload).eq('id', id);
            return id;
          }
        }
        rethrow;
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('QuestionLearningStateRemote.upsertState failed: $e\n$st');
      }
      return null;
    }
  }
}
