import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../database/local_database.dart';
import '../services/sm2_calculator.dart';
import '../supabase/english_example_composition_state_remote.dart';
import '../supabase/english_example_learning_state_remote.dart';

/// 英語例文 SM-2 / 英作文状態のローカル保存と、リモートとのマージ表示。
class EnglishExampleStateSync {
  EnglishExampleStateSync._();

  static Future<Map<String, Map<String, dynamic>>> _queryLearningByExampleIds(
    LocalDatabase db,
    String learnerId,
    List<String> exampleIds,
  ) async {
    if (exampleIds.isEmpty) return {};
    final placeholders = List.filled(exampleIds.length, '?').join(',');
    final rows = await db.db.query(
      LocalTable.englishExampleLearningStates,
      where: 'learner_id = ? AND example_supabase_id IN ($placeholders)',
      whereArgs: [learnerId, ...exampleIds],
    );
    return {
      for (final r in rows) r['example_supabase_id'] as String: Map<String, dynamic>.from(r),
    };
  }

  static Map<String, dynamic> learningRowToUiMap(Map<String, dynamic> r) {
    final sid = r['supabase_id']?.toString();
    return {
      'id': (sid != null && sid.isNotEmpty) ? sid : null,
      'learner_id': r['learner_id'],
      'example_id': r['example_supabase_id'],
      'repetitions': r['repetitions'],
      'e_factor': r['e_factor'],
      'interval_days': r['interval_days'],
      'next_review_at': r['next_review_at'],
      'last_quality': r['last_quality'],
      'reviewed_count': r['reviewed_count'],
    };
  }

  /// dirty ローカル行を優先し、それ以外はリモート（他端末の更新）を優先。
  static Future<Map<String, Map<String, dynamic>>> fetchLearningStatesHybrid({
    required SupabaseClient client,
    required String learnerId,
    required List<String> exampleIds,
    LocalDatabase? localDb,
  }) async {
    if (exampleIds.isEmpty) return {};
    Map<String, Map<String, dynamic>> remote = {};
    try {
      remote = await EnglishExampleLearningStateRemote.fetchStates(
        client: client,
        learnerId: learnerId,
        exampleIds: exampleIds,
      );
    } catch (e, st) {
      if (kDebugMode) debugPrint('EnglishExampleStateSync.fetchLearningStatesHybrid remote: $e\n$st');
    }
    if (localDb == null || kIsWeb) return remote;

    final localMap = await _queryLearningByExampleIds(localDb, learnerId, exampleIds);
    final out = <String, Map<String, dynamic>>{};
    for (final id in exampleIds) {
      final loc = localMap[id];
      final rem = remote[id];
      if (loc != null && (loc['dirty'] == 1 || loc['dirty'] == true)) {
        out[id] = learningRowToUiMap(loc);
      } else if (rem != null) {
        out[id] = rem;
      } else if (loc != null) {
        out[id] = learningRowToUiMap(loc);
      }
    }
    return out;
  }

  static Future<void> upsertLearningAfterRating(
    LocalDatabase db, {
    required String learnerId,
    required String exampleId,
    String? knownRemoteRowId,
    required Sm2Result sm2,
    required int quality,
    required int reviewedCount,
  }) async {
    final fields = <String, dynamic>{
      'repetitions': sm2.repetitions,
      'e_factor': sm2.eFactor,
      'interval_days': sm2.intervalDays,
      'next_review_at': sm2.nextReviewAt.toUtc().toIso8601String(),
      'last_quality': quality,
      'reviewed_count': reviewedCount,
    };

    final existing = await db.db.query(
      LocalTable.englishExampleLearningStates,
      where: 'learner_id = ? AND example_supabase_id = ?',
      whereArgs: [learnerId, exampleId],
      limit: 1,
    );

    if (existing.isEmpty) {
      await db.insertWithSync(LocalTable.englishExampleLearningStates, {
        'learner_id': learnerId,
        'example_supabase_id': exampleId,
        if (knownRemoteRowId != null && knownRemoteRowId.isNotEmpty) 'supabase_id': knownRemoteRowId,
        ...fields,
      });
    } else {
      final lid = existing.first['local_id'] as int;
      final patch = Map<String, dynamic>.from(fields);
      if (knownRemoteRowId != null && knownRemoteRowId.isNotEmpty) {
        patch['supabase_id'] = knownRemoteRowId;
      }
      await db.updateWithSync(
        LocalTable.englishExampleLearningStates,
        patch,
        where: 'local_id = ?',
        whereArgs: [lid],
      );
    }
  }

  static Future<Map<String, Map<String, dynamic>>> _queryCompositionByExampleIds(
    LocalDatabase db,
    String learnerId,
    List<String> exampleIds,
  ) async {
    if (exampleIds.isEmpty) return {};
    final placeholders = List.filled(exampleIds.length, '?').join(',');
    final rows = await db.db.query(
      LocalTable.englishExampleCompositionStates,
      where: 'learner_id = ? AND example_supabase_id IN ($placeholders)',
      whereArgs: [learnerId, ...exampleIds],
    );
    return {
      for (final r in rows) r['example_supabase_id'] as String: Map<String, dynamic>.from(r),
    };
  }

  static bool? _boolFromSqlInt(dynamic v) {
    if (v == null) return null;
    if (v is bool) return v;
    if (v is int) return v != 0;
    return int.tryParse(v.toString()) == 1;
  }

  static Map<String, dynamic> compositionRowToUiMap(Map<String, dynamic> r) {
    final sid = r['supabase_id']?.toString();
    return {
      'id': (sid != null && sid.isNotEmpty) ? sid : null,
      'learner_id': r['learner_id'],
      'example_id': r['example_supabase_id'],
      'last_answer_correct': _boolFromSqlInt(r['last_answer_correct']),
      'last_self_remembered': _boolFromSqlInt(r['last_self_remembered']),
      'attempts': r['attempts'],
      'correct_count': r['correct_count'],
      'remembered_count': r['remembered_count'],
      'forgot_count': r['forgot_count'],
    };
  }

  static Future<Map<String, Map<String, dynamic>>> fetchCompositionStatesHybrid({
    required SupabaseClient client,
    required String learnerId,
    required List<String> exampleIds,
    LocalDatabase? localDb,
  }) async {
    if (exampleIds.isEmpty) return {};
    Map<String, Map<String, dynamic>> remote = {};
    try {
      remote = await EnglishExampleCompositionStateRemote.fetchStates(
        client: client,
        learnerId: learnerId,
        exampleIds: exampleIds,
      );
    } catch (e, st) {
      if (kDebugMode) debugPrint('EnglishExampleStateSync.fetchCompositionStatesHybrid remote: $e\n$st');
    }
    if (localDb == null || kIsWeb) return remote;

    final localMap = await _queryCompositionByExampleIds(localDb, learnerId, exampleIds);
    final out = <String, Map<String, dynamic>>{};
    for (final id in exampleIds) {
      final loc = localMap[id];
      final rem = remote[id];
      if (loc != null && (loc['dirty'] == 1 || loc['dirty'] == true)) {
        out[id] = compositionRowToUiMap(loc);
      } else if (rem != null) {
        out[id] = rem;
      } else if (loc != null) {
        out[id] = compositionRowToUiMap(loc);
      }
    }
    return out;
  }

  /// [EnglishExampleCompositionStateRemote.recordSession] と同じ集計をローカルに記録する。
  static Future<void> recordCompositionAnswerLocal(
    LocalDatabase db, {
    required String learnerId,
    required String exampleId,
    required bool answerCorrect,
  }) async {
    final existing = await db.db.query(
      LocalTable.englishExampleCompositionStates,
      where: 'learner_id = ? AND example_supabase_id = ?',
      whereArgs: [learnerId, exampleId],
      limit: 1,
    );
    final prev = existing.isEmpty ? null : existing.first;
    final attempts = (prev?['attempts'] as int? ?? 0) + 1;
    final correctCount = (prev?['correct_count'] as int? ?? 0) + (answerCorrect ? 1 : 0);

    if (prev == null) {
      await db.insertWithSync(LocalTable.englishExampleCompositionStates, {
        'learner_id': learnerId,
        'example_supabase_id': exampleId,
        'last_answer_correct': answerCorrect ? 1 : 0,
        'last_self_remembered': null,
        'attempts': attempts,
        'correct_count': correctCount,
        'remembered_count': 0,
        'forgot_count': 0,
      });
    } else {
      await db.updateWithSync(
        LocalTable.englishExampleCompositionStates,
        {
          'last_answer_correct': answerCorrect ? 1 : 0,
          'last_self_remembered': null,
          'attempts': attempts,
          'correct_count': correctCount,
        },
        where: 'local_id = ?',
        whereArgs: [prev['local_id']],
      );
    }
  }
}
