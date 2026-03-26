import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// `english_example_composition_states` の取得・更新（英作文モード専用）
class EnglishExampleCompositionStateRemote {
  EnglishExampleCompositionStateRemote._();

  static const _table = 'english_example_composition_states';

  static int _asInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  static String _userMessageForPostgrest(PostgrestException e) {
    final code = e.code;
    final msg = e.message.toLowerCase();
    if (code == 'PGRST205' ||
        msg.contains('could not find the table') ||
        msg.contains('schema cache')) {
      return '英作文の記録用テーブルが見つかりません。Supabase に migration 00024（english_example_composition_states）を適用してください。';
    }
    if (code == '23503' || msg.contains('foreign key')) {
      return '例文がサーバーに存在しないため保存できません。データ同期後にもう一度お試しください。';
    }
    if (code == '23505' ||
        msg.contains('duplicate key') ||
        msg.contains('unique constraint')) {
      return '記録の競合が発生しました。もう一度答え合わせしてください。';
    }
    if (code == '42501' ||
        msg.contains('permission denied') ||
        msg.contains('row-level security') ||
        msg.contains('new row violates row-level security')) {
      return '保存が許可されませんでした。ログインし直してください。';
    }
    if (msg.isNotEmpty) {
      return '保存に失敗しました: ${e.message}';
    }
    return '保存に失敗しました。通信状況を確認してください。';
  }

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
      final out = <String, Map<String, dynamic>>{};
      for (final row in rows) {
        final exId = row['example_id']?.toString();
        if (exId == null || exId.isEmpty) continue;
        out[exId] = Map<String, dynamic>.from(row);
      }
      return out;
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('EnglishExampleCompositionStateRemote.fetchStates: $e\n$st');
      }
      return {};
    }
  }

  /// 答え合わせ1回分を記録（正誤のみ。自己申告は使わない）。
  /// [message] は失敗時のみ（SnackBar 等に使う）。
  static Future<({bool ok, String? message})> recordSession({
    required SupabaseClient client,
    required String learnerId,
    required String exampleId,
    required bool answerCorrect,
  }) async {
    try {
      final existing = await client
          .from(_table)
          .select('id, attempts, correct_count')
          .eq('learner_id', learnerId)
          .eq('example_id', exampleId)
          .maybeSingle();

      final attempts = _asInt(existing?['attempts']) + 1;
      final correctCount = _asInt(existing?['correct_count']) + (answerCorrect ? 1 : 0);

      final payload = <String, dynamic>{
        'last_answer_correct': answerCorrect,
        'last_self_remembered': null,
        'attempts': attempts,
        'correct_count': correctCount,
      };

      if (existing != null) {
        final id = existing['id']?.toString();
        if (id != null && id.isNotEmpty) {
          await client.from(_table).update(payload).eq('id', id);
          return (ok: true, message: null);
        }
      }

      final insertPayload = <String, dynamic>{
        'learner_id': learnerId,
        'example_id': exampleId,
        ...payload,
      };

      try {
        await client.from(_table).insert(insertPayload).select('id').single();
        return (ok: true, message: null);
      } on PostgrestException catch (e) {
        final isDup = e.code == '23505' ||
            e.message.toLowerCase().contains('duplicate key') ||
            e.message.toLowerCase().contains('unique constraint');
        if (isDup) {
          final again = await client
              .from(_table)
              .select('id, attempts, correct_count')
              .eq('learner_id', learnerId)
              .eq('example_id', exampleId)
              .maybeSingle();
          if (again != null) {
            final id = again['id']?.toString();
            if (id != null && id.isNotEmpty) {
              final a2 = _asInt(again['attempts']) + 1;
              final c2 = _asInt(again['correct_count']) + (answerCorrect ? 1 : 0);
              await client.from(_table).update({
                'last_answer_correct': answerCorrect,
                'last_self_remembered': null,
                'attempts': a2,
                'correct_count': c2,
              }).eq('id', id);
              return (ok: true, message: null);
            }
          }
        }
        if (kDebugMode) {
          debugPrint('EnglishExampleCompositionStateRemote.recordSession: $e');
        }
        return (ok: false, message: _userMessageForPostgrest(e));
      }
    } on PostgrestException catch (e) {
      if (kDebugMode) {
        debugPrint('EnglishExampleCompositionStateRemote.recordSession: $e');
      }
      return (ok: false, message: _userMessageForPostgrest(e));
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('EnglishExampleCompositionStateRemote.recordSession: $e\n$st');
      }
      return (ok: false, message: '保存に失敗しました。通信状況を確認してください。');
    }
  }

  /// [SyncEngine] 用: ローカル行の絶対値をそのまま反映。
  static Future<String?> pushExactForSync({
    required SupabaseClient client,
    required String learnerId,
    required String exampleId,
    String? knownRemoteRowId,
    required bool? lastAnswerCorrect,
    required bool? lastSelfRemembered,
    required int attempts,
    required int correctCount,
    required int rememberedCount,
    required int forgotCount,
  }) async {
    final updatePayload = <String, dynamic>{
      'last_answer_correct': lastAnswerCorrect,
      'last_self_remembered': lastSelfRemembered,
      'attempts': attempts,
      'correct_count': correctCount,
      'remembered_count': rememberedCount,
      'forgot_count': forgotCount,
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
        debugPrint('EnglishExampleCompositionStateRemote.pushExactForSync failed: $e\n$st');
      }
      return null;
    }
  }
}
