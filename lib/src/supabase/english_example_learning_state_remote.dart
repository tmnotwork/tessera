import 'package:flutter/foundation.dart';
import 'package:postgrest/postgrest.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// `english_example_learning_states` を RLS 下で確実に upsert する。
///
/// `QuestionLearningStateRemote` と同じ方針:
/// PostgREST の複合キー upsert が環境によって不安定なため、
/// SELECT → UPDATE / INSERT に分ける。
class EnglishExampleLearningStateRemote {
  EnglishExampleLearningStateRemote._();

  static const _table = 'english_example_learning_states';

  /// 学習状態を取得する。未学習の場合は null。
  static Future<Map<String, dynamic>?> fetchState({
    required SupabaseClient client,
    required String learnerId,
    required String exampleId,
  }) async {
    try {
      final row = await client
          .from(_table)
          .select()
          .eq('learner_id', learnerId)
          .eq('example_id', exampleId)
          .maybeSingle();
      return row;
    } catch (e, st) {
      if (kDebugMode) debugPrint('EnglishExampleLearningStateRemote.fetchState: $e\n$st');
      return null;
    }
  }

  /// 複数例文の学習状態をまとめて取得する（キー: example_id）。
  static Future<Map<String, Map<String, dynamic>>> fetchStates({
    required SupabaseClient client,
    required String learnerId,
    required List<String> exampleIds,
  }) async {
    if (exampleIds.isEmpty) return {};
    try {
      final rows = await client
          .from(_table)
          .select()
          .eq('learner_id', learnerId)
          .inFilter('example_id', exampleIds);
      return {
        for (final row in rows) row['example_id'] as String: Map<String, dynamic>.from(row),
      };
    } catch (e, st) {
      if (kDebugMode) debugPrint('EnglishExampleLearningStateRemote.fetchStates: $e\n$st');
      return {};
    }
  }

  /// 学習状態を保存（INSERT or UPDATE）。成功時はリモート行の UUID、失敗時は null。
  static Future<String?> upsertState({
    required SupabaseClient client,
    required String learnerId,
    required String exampleId,
    String? knownRemoteRowId,
    required Map<String, dynamic> stateFields,
    required int quality,
  }) async {
    final updatePayload = Map<String, dynamic>.from(stateFields)
      ..remove('learner_id')
      ..remove('example_id')
      ..['last_quality'] = quality
      ..['reviewed_count'] = (stateFields['reviewed_count'] as int? ?? 0) + 1;

    try {
      // 既知の行 ID がある場合は直接 UPDATE
      if (knownRemoteRowId != null && knownRemoteRowId.isNotEmpty) {
        await client.from(_table).update(updatePayload).eq('id', knownRemoteRowId);
        return knownRemoteRowId;
      }

      // 既存行を SELECT
      final existing = await client
          .from(_table)
          .select('id, reviewed_count')
          .eq('learner_id', learnerId)
          .eq('example_id', exampleId)
          .maybeSingle();

      if (existing != null) {
        final id = existing['id']?.toString();
        if (id != null && id.isNotEmpty) {
          // reviewed_count を DB の値ベースで加算
          updatePayload['reviewed_count'] =
              (existing['reviewed_count'] as int? ?? 0) + 1;
          await client.from(_table).update(updatePayload).eq('id', id);
          return id;
        }
      }

      // INSERT
      final insertPayload = <String, dynamic>{
        'learner_id': learnerId,
        'example_id': exampleId,
        ...stateFields,
        'last_quality': quality,
        'reviewed_count': 1,
      }..remove('id');

      try {
        final inserted = await client
            .from(_table)
            .insert(insertPayload)
            .select('id')
            .single();
        return inserted['id']?.toString();
      } on PostgrestException catch (e) {
        // 競合: 別リクエストが先に INSERT した
        final isDup = e.code == '23505' ||
            e.message.toLowerCase().contains('duplicate key') ||
            e.message.toLowerCase().contains('unique constraint');
        if (isDup) {
          final again = await client
              .from(_table)
              .select('id, reviewed_count')
              .eq('learner_id', learnerId)
              .eq('example_id', exampleId)
              .maybeSingle();
          final id = again?['id']?.toString();
          if (id != null && id.isNotEmpty) {
            updatePayload['reviewed_count'] =
                (again?['reviewed_count'] as int? ?? 0) + 1;
            await client.from(_table).update(updatePayload).eq('id', id);
            return id;
          }
        }
        rethrow;
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('EnglishExampleLearningStateRemote.upsertState failed: $e\n$st');
      }
      return null;
    }
  }

  /// [SyncEngine] 用: ローカルで確定した SM-2 値をそのまま反映（`reviewed_count` の加算なし）。
  static Future<String?> pushExactForSync({
    required SupabaseClient client,
    required String learnerId,
    required String exampleId,
    String? knownRemoteRowId,
    required int repetitions,
    required double eFactor,
    required int intervalDays,
    required String nextReviewAtIso,
    required int? lastQuality,
    required int reviewedCount,
  }) async {
    final updatePayload = <String, dynamic>{
      'repetitions': repetitions,
      'e_factor': eFactor,
      'interval_days': intervalDays,
      'next_review_at': nextReviewAtIso,
      'last_quality': lastQuality,
      'reviewed_count': reviewedCount,
    };
    try {
      if (knownRemoteRowId != null && knownRemoteRowId.isNotEmpty) {
        await client.from(_table).update(updatePayload).eq('id', knownRemoteRowId);
        return knownRemoteRowId;
      }

      final existing = await client
          .from(_table)
          .select('id')
          .eq('learner_id', learnerId)
          .eq('example_id', exampleId)
          .maybeSingle();
      if (existing != null) {
        final id = existing['id']?.toString();
        if (id != null && id.isNotEmpty) {
          await client.from(_table).update(updatePayload).eq('id', id);
          return id;
        }
      }

      final insertPayload = <String, dynamic>{
        'learner_id': learnerId,
        'example_id': exampleId,
        ...updatePayload,
      };

      try {
        final inserted = await client.from(_table).insert(insertPayload).select('id').single();
        return inserted['id']?.toString();
      } on PostgrestException catch (e) {
        final isDup = e.code == '23505' ||
            e.message.toLowerCase().contains('duplicate key') ||
            e.message.toLowerCase().contains('unique constraint');
        if (isDup) {
          final again = await client
              .from(_table)
              .select('id')
              .eq('learner_id', learnerId)
              .eq('example_id', exampleId)
              .maybeSingle();
          final id = again?['id']?.toString();
          if (id != null && id.isNotEmpty) {
            await client.from(_table).update(updatePayload).eq('id', id);
            return id;
          }
        }
        rethrow;
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('EnglishExampleLearningStateRemote.pushExactForSync failed: $e\n$st');
      }
      return null;
    }
  }
}
