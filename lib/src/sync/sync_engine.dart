import 'package:flutter/foundation.dart';
import 'package:postgrest/postgrest.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../database/local_database.dart';
import '../supabase/question_learning_state_remote.dart';
import 'sync_metadata_store.dart';
import 'sync_notifier.dart';

/// 双方向同期エンジン（Pull → Push、LWW 競合解消）。
/// Web では使用しない（sqflite 非対応のため）。
class SyncEngine {
  SyncEngine._({required LocalDatabase localDb}) : _localDb = localDb;

  final LocalDatabase _localDb;

  static SyncEngine? _instance;

  static SyncEngine get instance {
    final i = _instance;
    if (i == null) throw StateError('SyncEngine not initialized. Call init() first.');
    return i;
  }

  static bool get isInitialized => _instance != null;

  static void init(LocalDatabase localDb) {
    _instance = SyncEngine._(localDb: localDb);
  }

  bool _syncing = false;
  bool get isSyncing => _syncing;

  /// 進行中の [sync]（画面からの同時 await 用に共有）
  Future<void>? _inFlightSync;

  /// オンラインなら同期を実行。オフラインなら何もしない。
  ///
  /// 注意: [sync] 内部で例外は握りつぶして [SyncNotifier.setError] するため、
  /// 成否は `SyncNotifier.instance.state` / `lastError` で確認すること。
  Future<void> syncIfOnline() async {
    if (kIsWeb) return;
    try {
      await sync();
      if (kDebugMode && SyncNotifier.instance.state == SyncState.error) {
        debugPrint(
          'SyncEngine.syncIfOnline: 同期処理は終了しましたがエラーです: ${SyncNotifier.instance.lastError}',
        );
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('SyncEngine.syncIfOnline: 予期しない例外 $e\n$st');
      }
    }
  }

  /// 学習者の四択解答をローカルに記録し、同期キューへ積む。
  Future<bool> recordQuestionLearningProgress({
    required String learnerId,
    required String questionSupabaseId,
    required int selectedIndex,
    required String selectedChoiceText,
    required bool isCorrect,
  }) async {
    if (kIsWeb) return false;

    final q = await _localDb.getBySupabaseId(LocalTable.questions, questionSupabaseId);
    final questionLocalId = q?['local_id'] as int?;
    if (questionLocalId == null) return false;

    final now = DateTime.now().toUtc();
    final nowIso = now.toIso8601String();

    await _localDb.insertWithSync(LocalTable.questionAnswerLogs, {
      'learner_id': learnerId,
      'question_local_id': questionLocalId,
      'selected_choice_text': selectedChoiceText,
      'selected_index': selectedIndex,
      'is_correct': isCorrect ? 1 : 0,
      'answered_at': nowIso,
    });

    final existing = await _localDb.db.query(
      LocalTable.questionLearningStates,
      where: 'learner_id = ? AND question_local_id = ?',
      whereArgs: [learnerId, questionLocalId],
      limit: 1,
    );

    final prev = existing.isNotEmpty ? existing.first : null;
    final prevStability = (prev?['stability'] as num?)?.toDouble() ?? 1.0;
    final prevStreak = (prev?['success_streak'] as num?)?.toInt() ?? 0;
    final prevLapse = (prev?['lapse_count'] as num?)?.toInt() ?? 0;
    final prevReviewed = (prev?['reviewed_count'] as num?)?.toInt() ?? 0;

    late final int successStreak;
    late final int lapseCount;
    late final double stability;
    late final DateTime nextReviewAt;
    late final double retrievability;

    if (isCorrect) {
      // 初回正解は「既に知っている」とみなし、忘却曲線の対象外にする
      final isFirstCorrect = prevReviewed == 0;
      successStreak = prevStreak + 1;
      lapseCount = prevLapse;
      if (isFirstCorrect) {
        stability = 3650.0;
        nextReviewAt = now.add(const Duration(days: 3650));
        retrievability = 1.0;
      } else {
        stability = (prevStability * 1.25 + 0.5).clamp(1.0, 120.0).toDouble();
        final intervalDays = (stability * (1.0 + successStreak * 0.35)).clamp(1.0, 60.0);
        nextReviewAt = now.add(Duration(minutes: (intervalDays * 24 * 60).round()));
        retrievability = 0.9;
      }
    } else {
      successStreak = 0;
      lapseCount = prevLapse + 1;
      stability = (prevStability * 0.65).clamp(0.5, 60.0).toDouble();
      final reviewHours = lapseCount <= 1 ? 6 : 12;
      nextReviewAt = now.add(Duration(hours: reviewHours));
      retrievability = 0.35;
    }

    final payload = <String, dynamic>{
      'stability': stability,
      'difficulty': isCorrect ? 0.45 : 0.7,
      'retrievability': retrievability,
      'success_streak': successStreak,
      'lapse_count': lapseCount,
      'reviewed_count': prevReviewed + 1,
      'last_is_correct': isCorrect ? 1 : 0,
      'last_selected_choice_text': selectedChoiceText,
      'last_selected_index': selectedIndex,
      'last_review_at': nowIso,
      'next_review_at': nextReviewAt.toUtc().toIso8601String(),
    };
    if (prev == null) {
      await _localDb.insertWithSync(LocalTable.questionLearningStates, {
        'learner_id': learnerId,
        'question_local_id': questionLocalId,
        'question_supabase_id': questionSupabaseId,
        ...payload,
      });
    } else {
      await _localDb.updateWithSync(
        LocalTable.questionLearningStates,
        {
          'question_supabase_id': questionSupabaseId,
          ...payload,
        },
        where: 'local_id = ?',
        whereArgs: [prev['local_id']],
      );
    }

    // 全同期（Pull→Push）はここでは走らせない。画面側で Supabase へ直接反映し、
    // ensureSyncedForLocalRead などでまとめて Pull/Push する（Pull が直後に古い行で上書きする競合を避ける）。
    return true;
  }

  /// 直近のローカル `question_learning_states` を Supabase upsert 用の Map にする。
  /// リモート側の二重カウントを避け、タイル表示とローカルを一致させる。
  Future<Map<String, dynamic>?> buildQuestionLearningStateSupabaseUpsert({
    required String learnerId,
    required String questionSupabaseId,
  }) async {
    if (kIsWeb) return null;
    final q = await _localDb.getBySupabaseId(LocalTable.questions, questionSupabaseId);
    final questionLocalId = q?['local_id'] as int?;
    if (questionLocalId == null) return null;
    final rows = await _localDb.db.query(
      LocalTable.questionLearningStates,
      where: 'learner_id = ? AND question_local_id = ?',
      whereArgs: [learnerId, questionLocalId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    return {
      'learner_id': learnerId,
      'question_id': questionSupabaseId,
      'stability': r['stability'],
      'difficulty': r['difficulty'],
      'retrievability': r['retrievability'],
      'success_streak': r['success_streak'],
      'lapse_count': r['lapse_count'],
      'reviewed_count': r['reviewed_count'],
      'last_is_correct': (r['last_is_correct'] == 1),
      'last_selected_choice_text': r['last_selected_choice_text'],
      'last_selected_index': r['last_selected_index'],
      'last_review_at': r['last_review_at'],
      'next_review_at': r['next_review_at'],
      'updated_at': LocalDatabase.nowUtc(),
    };
  }

  /// 同期実行: 1) Pull 2) Push。完了時に SyncNotifier に通知。
  /// 並行呼び出しは同一処理の終了を待ち合わせる。
  Future<void> sync() {
    if (kIsWeb) return Future.value();
    _inFlightSync ??= _runSync().whenComplete(() {
      _inFlightSync = null;
    });
    return _inFlightSync!;
  }

  Future<void> _runSync() async {
    final client = Supabase.instance.client;
    _syncing = true;
    SyncNotifier.setSyncing();

    try {
      final lastPullAt = await SyncMetadataStore.getLastPullAt();
      await SyncMetadataStore.setIsSyncing(true);

      final pullStartAt = DateTime.now().toUtc().toIso8601String();

      // Pull（deleted_at 未追加のリモートでは 42703 で落ちるため1回だけ legacy でリトライ）
      try {
        if (lastPullAt == null || lastPullAt.isEmpty) {
          await _pullAll(client, pullStartAt);
        } else {
          await _pullIncremental(client, lastPullAt);
        }
      } on PostgrestException catch (e) {
        // deleted_at / updated_at 未追加のリモート（00014 未適用など）
        final isMissingColumn = e.code == '42703' ||
            (e.message.contains('does not exist') &&
                (e.message.contains('deleted_at') ||
                    e.message.contains('updated_at') ||
                    e.message.contains('dev_completed')));
        if (isMissingColumn && !_useLegacyCols) {
          _useLegacyCols = true;
          if (lastPullAt == null || lastPullAt.isEmpty) {
            await _pullAll(client, pullStartAt);
          } else {
            await _pullIncremental(client, lastPullAt);
          }
        } else {
          rethrow;
        }
      }

      await SyncMetadataStore.setLastPullAt(pullStartAt);
      await SyncMetadataStore.setIsSyncing(false);

      // Push
      await _push(client);

      SyncNotifier.setDone();
    } catch (e, st) {
      if (kDebugMode) {
        // ignore: avoid_print
        print('SyncEngine.sync error: $e\n$st');
      }
      await SyncMetadataStore.setIsSyncing(false);
      SyncNotifier.setError(e);
    } finally {
      _syncing = false;
    }
  }

  static const _pageSize = 1000;

  /// テーブルがリモートに無い場合（PGRST205）はスキップして続行
  Future<void> _pullTableFullSafe(SupabaseClient client, String remoteTable, String localTable, List<String> cols) async {
    try {
      await _pullTableFull(client, remoteTable, localTable, cols);
    } on PostgrestException catch (e) {
      if (e.code == 'PGRST205') {
        if (kDebugMode) debugPrint('SyncEngine: skip $remoteTable (table not in remote)');
        return;
      }
      rethrow;
    }
  }

  Future<void> _pullAll(SupabaseClient client, String pullStartAt) async {
    await _pullTableFull(client, 'subjects', LocalTable.subjects, _effectiveSubjectCols);
    await _pullTableFull(client, 'knowledge', LocalTable.knowledge, _effectiveKnowledgeCols);
    await _pullTableFullSafe(client, 'memorization_cards', LocalTable.memorizationCards, _effectiveMemorizationCardCols);
    await _pullTableFull(client, 'questions', LocalTable.questions, _effectiveQuestionCols);
    await _pullTableFullSafe(client, 'question_choices', LocalTable.questionChoices, _effectiveQuestionChoiceCols);
    await _pullTableFullSafe(client, 'knowledge_tags', LocalTable.knowledgeTags, _knowledgeTagCols);
    await _pullTableFullSafe(client, 'memorization_tags', LocalTable.memorizationTags, _memorizationTagCols);
    await _pullTableFullSafe(client, 'question_answer_logs', LocalTable.questionAnswerLogs, _questionAnswerLogCols);
    await _pullTableFullSafe(client, 'question_learning_states', LocalTable.questionLearningStates, _questionLearningStateCols);
    await _pullJunctionFullSafe(client);
  }

  /// テーブルがリモートに無い場合（PGRST205）はスキップして続行
  Future<void> _pullTableIncrementalSafe(SupabaseClient client, String remoteTable, String localTable, List<String> cols, String lastPullAt) async {
    try {
      await _pullTableIncremental(client, remoteTable, localTable, cols, lastPullAt);
    } on PostgrestException catch (e) {
      if (e.code == 'PGRST205') {
        if (kDebugMode) debugPrint('SyncEngine: skip $remoteTable (table not in remote)');
        return;
      }
      rethrow;
    }
  }

  Future<void> _pullIncremental(SupabaseClient client, String lastPullAt) async {
    await _pullTableIncremental(client, 'subjects', LocalTable.subjects, _effectiveSubjectCols, lastPullAt);
    await _pullTableIncremental(client, 'knowledge', LocalTable.knowledge, _effectiveKnowledgeCols, lastPullAt);
    await _pullTableIncrementalSafe(client, 'memorization_cards', LocalTable.memorizationCards, _effectiveMemorizationCardCols, lastPullAt);
    await _pullTableIncremental(client, 'questions', LocalTable.questions, _effectiveQuestionCols, lastPullAt);
    await _pullTableIncrementalSafe(client, 'question_choices', LocalTable.questionChoices, _effectiveQuestionChoiceCols, lastPullAt);
    await _pullTableIncrementalSafe(client, 'knowledge_tags', LocalTable.knowledgeTags, _knowledgeTagCols, lastPullAt);
    await _pullTableIncrementalSafe(client, 'memorization_tags', LocalTable.memorizationTags, _memorizationTagCols, lastPullAt);
    await _pullTableIncrementalSafe(client, 'question_answer_logs', LocalTable.questionAnswerLogs, _questionAnswerLogCols, lastPullAt);
    await _pullTableIncrementalSafe(client, 'question_learning_states', LocalTable.questionLearningStates, _questionLearningStateCols, lastPullAt);
    await _pullJunctionIncremental(client, lastPullAt);
  }

  static const _subjectCols = ['id', 'name', 'display_order', 'created_at', 'updated_at', 'deleted_at'];
  static const _knowledgeCols = [
    'id',
    'subject_id',
    'subject',
    'unit',
    'content',
    'description',
    'display_order',
    'construction',
    'author_comment',
    'dev_completed',
    'created_at',
    'updated_at',
    'deleted_at',
  ];
  static const _memorizationCardCols = ['id', 'subject_id', 'knowledge_id', 'unit', 'front_content', 'back_content', 'display_order', 'created_at', 'updated_at', 'deleted_at'];
  static const _questionCols = [
    'id',
    'knowledge_id',
    'question_type',
    'question_text',
    'correct_answer',
    'explanation',
    'reference',
    'choices',
    'dev_completed',
    'created_at',
    'updated_at',
    'deleted_at',
  ];
  /// 00014 適用後は updated_at あり。未適用時は legacy 列セットで Pull し、カーソルは created_at。
  static const _questionChoiceCols = [
    'id',
    'question_id',
    'position',
    'choice_text',
    'is_correct',
    'created_at',
    'updated_at',
    'deleted_at',
  ];
  static const _questionAnswerLogCols = ['id', 'learner_id', 'question_id', 'selected_choice_text', 'selected_index', 'is_correct', 'answered_at', 'created_at', 'updated_at'];
  static const _questionLearningStateCols = ['id', 'learner_id', 'question_id', 'stability', 'difficulty', 'retrievability', 'success_streak', 'lapse_count', 'reviewed_count', 'last_is_correct', 'last_selected_choice_text', 'last_selected_index', 'last_review_at', 'next_review_at', 'created_at', 'updated_at'];
  /// deleted_at 未追加のリモート用（マイグレーション 00014_add_deleted_at_for_sync 未適用時）
  static const _subjectColsLegacy = ['id', 'name', 'display_order', 'created_at', 'updated_at'];
  /// deleted_at 無しリモート用。dev_completed 等を含めないと Pull マージで常に false/0 に上書きされる。
  static const _knowledgeColsLegacy = [
    'id',
    'subject_id',
    'subject',
    'unit',
    'content',
    'description',
    'display_order',
    'construction',
    'author_comment',
    'dev_completed',
    'created_at',
    'updated_at',
  ];
  static const _memorizationCardColsLegacy = ['id', 'subject_id', 'knowledge_id', 'unit', 'front_content', 'back_content', 'display_order', 'created_at', 'updated_at'];
  static const _questionColsLegacy = [
    'id',
    'knowledge_id',
    'question_type',
    'question_text',
    'correct_answer',
    'explanation',
    'reference',
    'choices',
    'dev_completed',
    'created_at',
    'updated_at',
  ];
  static const _questionChoiceColsLegacy = ['id', 'question_id', 'position', 'choice_text', 'is_correct', 'created_at'];
  static const _knowledgeTagCols = ['id', 'name', 'created_at'];
  static const _memorizationTagCols = ['id', 'name', 'created_at'];

  bool _useLegacyCols = false;

  List<String> get _effectiveSubjectCols => _useLegacyCols ? _subjectColsLegacy : _subjectCols;
  List<String> get _effectiveKnowledgeCols => _useLegacyCols ? _knowledgeColsLegacy : _knowledgeCols;
  List<String> get _effectiveMemorizationCardCols => _useLegacyCols ? _memorizationCardColsLegacy : _memorizationCardCols;
  List<String> get _effectiveQuestionCols => _useLegacyCols ? _questionColsLegacy : _questionCols;
  List<String> get _effectiveQuestionChoiceCols => _useLegacyCols ? _questionChoiceColsLegacy : _questionChoiceCols;

  /// Pull の並び・増分フィルタに使う時刻列（リモートに `updated_at` が無いテーブルは `created_at`）。
  String _pullTimeColumn(List<String> cols) {
    if (cols.contains('updated_at')) return 'updated_at';
    return 'created_at';
  }

  Future<void> _pullTableFull(SupabaseClient client, String remoteTable, String localTable, List<String> cols) async {
    final timeCol = _pullTimeColumn(cols);
    int offset = 0;
    while (true) {
      // order を固定することでページング中にレコードが落ちるのを防止
      final rows = await client
          .from(remoteTable)
          .select(cols.join(','))
          .order(timeCol, ascending: true)
          .order('id', ascending: true)
          .range(offset, offset + _pageSize - 1);
      if (rows.isEmpty) break;
      for (final row in rows as List) {
        await _mergeRow(client, localTable, row as Map<String, dynamic>, remoteTable, fullPull: true);
      }
      offset += _pageSize;
      if ((rows as List).length < _pageSize) break;
    }
  }

  Future<void> _pullTableIncremental(SupabaseClient client, String remoteTable, String localTable, List<String> cols, String lastPullAt) async {
    final timeCol = _pullTimeColumn(cols);
    int offset = 0;
    while (true) {
      final rows = await client
          .from(remoteTable)
          .select(cols.join(','))
          .gte(timeCol, lastPullAt)
          .order(timeCol, ascending: true)
          .order('id', ascending: true)
          .range(offset, offset + _pageSize - 1);
      if (rows.isEmpty) break;
      for (final row in rows as List) {
        await _mergeRow(client, localTable, row as Map<String, dynamic>, remoteTable, fullPull: false);
      }
      offset += _pageSize;
      if ((rows as List).length < _pageSize) break;
    }
  }

  /// 増分 Pull などで `local_questions` にまだ無いとき、リモートから1件取り込む（学習状態・選択肢の FK 用）。
  Future<Map<String, dynamic>?> _ensureQuestionInLocalDb(SupabaseClient client, String questionSupabaseId) async {
    if (questionSupabaseId.isEmpty) return null;
    final existing = await _localDb.getBySupabaseId(LocalTable.questions, questionSupabaseId);
    if (existing != null) return existing;
    try {
      final raw = await client
          .from('questions')
          .select(_effectiveQuestionCols.join(','))
          .eq('id', questionSupabaseId)
          .maybeSingle();
      if (raw == null) {
        if (kDebugMode) {
          debugPrint('SyncEngine: question $questionSupabaseId not found on remote (skip dependent row)');
        }
        return null;
      }
      final row = Map<String, dynamic>.from(raw);
      await _mergeRow(client, LocalTable.questions, row, 'questions', fullPull: true);
      return await _localDb.getBySupabaseId(LocalTable.questions, questionSupabaseId);
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('SyncEngine: _ensureQuestionInLocalDb($questionSupabaseId) failed: $e\n$st');
      }
      return null;
    }
  }

  /// 端末で先に解答済み（supabase_id 未確定）の行と、Pull のリモート行が同一 (learner, question) でぶつかるのを防ぐ。
  Future<Map<String, dynamic>?> _localQuestionLearningStateByLearnerAndQuestion(
    Map<String, dynamic> remote,
  ) async {
    final learnerId = _str(remote['learner_id']);
    final questionSupabaseId = _str(remote['question_id']);
    if (learnerId.isEmpty || questionSupabaseId.isEmpty) return null;
    final q = await _localDb.getBySupabaseId(LocalTable.questions, questionSupabaseId);
    final qLocalId = q?['local_id'] as int?;
    if (qLocalId == null) return null;
    final rows = await _localDb.db.query(
      LocalTable.questionLearningStates,
      where: 'learner_id = ? AND question_local_id = ?',
      whereArgs: [learnerId, qLocalId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> _mergeRow(SupabaseClient client, String localTable, Map<String, dynamic> remote, String remoteTable, {required bool fullPull}) async {
    final supabaseId = _str(remote['id']);
    if (supabaseId.isEmpty) return;
    final deletedAt = remote['deleted_at'];
    final isDeleted = deletedAt != null && deletedAt.toString().isNotEmpty;

    var existing = await _localDb.getBySupabaseId(localTable, supabaseId);
    if (existing == null && localTable == LocalTable.questionLearningStates && remoteTable == 'question_learning_states') {
      existing = await _localQuestionLearningStateByLearnerAndQuestion(remote);
    }
    if (existing == null) {
      await _insertRemoteRow(client, localTable, remote, remoteTable, isDeleted);
      return;
    }
    if (existing['dirty'] == 1) {
      final localUpdated = _parseUtc(existing['updated_at']?.toString());
      final remoteUpdated = _parseUtc(remote['updated_at']?.toString());
      if (remoteUpdated != null && localUpdated != null) {
        if (remoteUpdated.isAfter(localUpdated)) {
          await _updateLocalFromRemote(localTable, remote, remoteTable, existing['local_id'] as int, isDeleted);
        } else if (remoteUpdated.isAtSameMomentAs(localUpdated)) {
          // Tiebreaker: supabase_id の辞書順（全デバイスで同一結果になる）
          final remoteId = _str(remote['id']);
          final localSupabaseId = existing['supabase_id']?.toString() ?? '';
          if (remoteId.compareTo(localSupabaseId) > 0) {
            await _updateLocalFromRemote(localTable, remote, remoteTable, existing['local_id'] as int, isDeleted);
          }
        }
      }
      return;
    }
    await _updateLocalFromRemote(localTable, remote, remoteTable, existing['local_id'] as int, isDeleted);
  }

  Future<void> _insertRemoteRow(SupabaseClient client, String localTable, Map<String, dynamic> remote, String remoteTable, bool isDeleted) async {
    final now = LocalDatabase.nowUtc();
    final row = _remoteToLocalRow(remote, remoteTable);
    row['supabase_id'] = _str(remote['id']);
    row['dirty'] = 0;
    row['deleted'] = isDeleted ? 1 : 0;
    row['synced_at'] = now;
    row['created_at'] = _str(remote['created_at']).isEmpty ? now : _str(remote['created_at']);
    row['updated_at'] = _str(remote['updated_at']).isEmpty ? now : _str(remote['updated_at']);
    if (localTable == LocalTable.knowledge) {
      final subjectSupabaseId = _str(remote['subject_id']);
      if (subjectSupabaseId.isNotEmpty) {
        final sub = await _localDb.getBySupabaseId(LocalTable.subjects, subjectSupabaseId);
        if (sub != null) row['subject_local_id'] = sub['local_id'];
      }
    } else if (localTable == LocalTable.memorizationCards) {
      final subjectSupabaseId = _str(remote['subject_id']);
      final knowledgeSupabaseId = _str(remote['knowledge_id']);
      if (subjectSupabaseId.isNotEmpty) {
        final sub = await _localDb.getBySupabaseId(LocalTable.subjects, subjectSupabaseId);
        if (sub != null) row['subject_local_id'] = sub['local_id'];
      }
      if (knowledgeSupabaseId.isNotEmpty) {
        final k = await _localDb.getBySupabaseId(LocalTable.knowledge, knowledgeSupabaseId);
        if (k != null) row['knowledge_local_id'] = k['local_id'];
      }
    } else if (localTable == LocalTable.questions) {
      final knowledgeSupabaseId = _str(remote['knowledge_id']);
      if (knowledgeSupabaseId.isNotEmpty) {
        final k = await _localDb.getBySupabaseId(LocalTable.knowledge, knowledgeSupabaseId);
        if (k != null) row['knowledge_local_id'] = k['local_id'];
      }
    } else if (localTable == LocalTable.questionChoices) {
      final questionSupabaseId = _str(remote['question_id']);
      if (questionSupabaseId.isEmpty) {
        if (kDebugMode) debugPrint('SyncEngine: skip insert question_choices — missing question_id');
        return;
      }
      final q = await _ensureQuestionInLocalDb(client, questionSupabaseId);
      if (q == null) {
        if (kDebugMode) {
          debugPrint('SyncEngine: skip insert question_choices — could not resolve question $questionSupabaseId');
        }
        return;
      }
      row['question_local_id'] = q['local_id'];
    } else if (localTable == LocalTable.questionAnswerLogs || localTable == LocalTable.questionLearningStates) {
      final questionSupabaseId = _str(remote['question_id']);
      if (questionSupabaseId.isEmpty) {
        if (kDebugMode) {
          debugPrint('SyncEngine: skip insert $localTable — missing question_id (remote id ${remote['id']})');
        }
        return;
      }
      final q = await _ensureQuestionInLocalDb(client, questionSupabaseId);
      if (q == null) {
        if (kDebugMode) {
          debugPrint('SyncEngine: skip insert $localTable — could not resolve question $questionSupabaseId');
        }
        return;
      }
      row['question_local_id'] = q['local_id'];
    }
    await _localDb.db.insert(localTable, row);
  }

  Future<void> _updateLocalFromRemote(String localTable, Map<String, dynamic> remote, String remoteTable, int localId, bool isDeleted) async {
    // Pull が deleted_at を含まない（legacy 列セット等）とき、ローカルの墓石を deleted=0 で上書きしない
    if (localTable == LocalTable.knowledge && !isDeleted) {
      final cur = await _localDb.getByLocalId(localTable, localId);
      if (cur != null && (cur['deleted'] == 1 || cur['deleted'] == true)) {
        if (!remote.containsKey('deleted_at')) {
          if (kDebugMode) {
            debugPrint(
              'SyncEngine: skip resurrect local_knowledge local_id=$localId '
              '(local deleted=1, remote payload has no deleted_at key)',
            );
          }
          return;
        }
      }
    }
    final row = _remoteToLocalRow(remote, remoteTable);
    row['supabase_id'] = _str(remote['id']);
    row['dirty'] = 0;
    row['deleted'] = isDeleted ? 1 : 0;
    row['synced_at'] = LocalDatabase.nowUtc();
    row['updated_at'] = _str(remote['updated_at']).isEmpty ? LocalDatabase.nowUtc() : _str(remote['updated_at']);
    if (localTable == LocalTable.knowledge) {
      final subjectSupabaseId = _str(remote['subject_id']);
      if (subjectSupabaseId.isNotEmpty) {
        final sub = await _localDb.getBySupabaseId(LocalTable.subjects, subjectSupabaseId);
        if (sub != null) row['subject_local_id'] = sub['local_id'];
      }
    } else if (localTable == LocalTable.memorizationCards) {
      final subjectSupabaseId = _str(remote['subject_id']);
      final knowledgeSupabaseId = _str(remote['knowledge_id']);
      if (subjectSupabaseId.isNotEmpty) {
        final sub = await _localDb.getBySupabaseId(LocalTable.subjects, subjectSupabaseId);
        if (sub != null) row['subject_local_id'] = sub['local_id'];
      }
      if (knowledgeSupabaseId.isNotEmpty) {
        final k = await _localDb.getBySupabaseId(LocalTable.knowledge, knowledgeSupabaseId);
        if (k != null) row['knowledge_local_id'] = k['local_id'];
      }
    } else if (localTable == LocalTable.questions) {
      final knowledgeSupabaseId = _str(remote['knowledge_id']);
      if (knowledgeSupabaseId.isNotEmpty) {
        final k = await _localDb.getBySupabaseId(LocalTable.knowledge, knowledgeSupabaseId);
        if (k != null) row['knowledge_local_id'] = k['local_id'];
      }
    } else if (localTable == LocalTable.questionChoices) {
      final questionSupabaseId = _str(remote['question_id']);
      if (questionSupabaseId.isNotEmpty) {
        final q = await _localDb.getBySupabaseId(LocalTable.questions, questionSupabaseId);
        if (q != null) row['question_local_id'] = q['local_id'];
      }
    } else if (localTable == LocalTable.questionAnswerLogs || localTable == LocalTable.questionLearningStates) {
      final questionSupabaseId = _str(remote['question_id']);
      if (questionSupabaseId.isNotEmpty) {
        final q = await _localDb.getBySupabaseId(LocalTable.questions, questionSupabaseId);
        if (q != null) row['question_local_id'] = q['local_id'];
      }
    }
    await _localDb.db.update(localTable, row, where: 'local_id = ?', whereArgs: [localId]);
  }

  Map<String, dynamic> _remoteToLocalRow(Map<String, dynamic> remote, String remoteTable) {
    final map = <String, dynamic>{};
    if (remoteTable == 'subjects') {
      map['name'] = remote['name'];
      map['display_order'] = remote['display_order'] ?? 0;
    } else if (remoteTable == 'knowledge') {
      map['subject'] = remote['subject'];
      map['unit'] = remote['unit'];
      map['content'] = remote['content'] ?? '';
      map['description'] = remote['description'];
      map['display_order'] = remote['display_order'];
      map['type'] = remote['type'] ?? 'grammar';
      map['construction'] = (remote['construction'] == true) ? 1 : 0;
      map['author_comment'] = remote['author_comment'];
      map['dev_completed'] =
          (remote['dev_completed'] == true || remote['dev_completed'] == 1) ? 1 : 0;
    } else if (remoteTable == 'memorization_cards') {
      map['unit'] = remote['unit'];
      map['front_content'] = remote['front_content'] ?? '';
      map['back_content'] = remote['back_content'];
      map['display_order'] = remote['display_order'];
    } else if (remoteTable == 'questions') {
      map['question_type'] = remote['question_type'] ?? 'text_input';
      map['question_text'] = remote['question_text'] ?? '';
      map['correct_answer'] = remote['correct_answer'] ?? '';
      map['explanation'] = remote['explanation'];
      map['reference'] = remote['reference'];
      map['choices'] = remote['choices']?.toString();
      map['dev_completed'] =
          (remote['dev_completed'] == true || remote['dev_completed'] == 1) ? 1 : 0;
    } else if (remoteTable == 'question_choices') {
      map['position'] = remote['position'] ?? 0;
      map['choice_text'] = remote['choice_text'] ?? '';
      map['is_correct'] = (remote['is_correct'] == true) ? 1 : 0;
    } else if (remoteTable == 'question_answer_logs') {
      map['learner_id'] = remote['learner_id'] ?? '';
      map['selected_choice_text'] = remote['selected_choice_text'];
      map['selected_index'] = remote['selected_index'];
      map['is_correct'] = (remote['is_correct'] == true) ? 1 : 0;
      map['answered_at'] = remote['answered_at']?.toString() ?? LocalDatabase.nowUtc();
    } else if (remoteTable == 'question_learning_states') {
      map['learner_id'] = remote['learner_id'] ?? '';
      map['question_supabase_id'] = _str(remote['question_id']);
      map['stability'] = (remote['stability'] as num?)?.toDouble() ?? 1.0;
      map['difficulty'] = (remote['difficulty'] as num?)?.toDouble() ?? 0.5;
      map['retrievability'] = (remote['retrievability'] as num?)?.toDouble() ?? 0.5;
      map['success_streak'] = remote['success_streak'] ?? 0;
      map['lapse_count'] = remote['lapse_count'] ?? 0;
      map['reviewed_count'] = remote['reviewed_count'] ?? 0;
      map['last_is_correct'] = remote['last_is_correct'] == null ? null : ((remote['last_is_correct'] == true) ? 1 : 0);
      map['last_selected_choice_text'] = remote['last_selected_choice_text'];
      map['last_selected_index'] = remote['last_selected_index'];
      map['last_review_at'] = remote['last_review_at']?.toString();
      map['next_review_at'] = remote['next_review_at']?.toString() ?? LocalDatabase.nowUtc();
    } else if (remoteTable == 'knowledge_tags' || remoteTable == 'memorization_tags') {
      map['name'] = remote['name'] ?? '';
    }
    return map;
  }

  /// 中間テーブル Pull。リモートに無いテーブル（PGRST205）はスキップ
  Future<void> _pullJunctionFullSafe(SupabaseClient client) async {
    try {
      await _pullKnowledgeCardTagsFull(client);
    } on PostgrestException catch (e) {
      if (e.code != 'PGRST205') rethrow;
      if (kDebugMode) debugPrint('SyncEngine: skip knowledge_card_tags (table not in remote)');
    }
    try {
      await _pullMemorizationCardTagsFull(client);
    } on PostgrestException catch (e) {
      if (e.code != 'PGRST205') rethrow;
      if (kDebugMode) debugPrint('SyncEngine: skip memorization_card_tags (table not in remote)');
    }
    try {
      await _pullQuestionKnowledgeFull(client);
    } on PostgrestException catch (e) {
      if (e.code != 'PGRST205') rethrow;
      if (kDebugMode) debugPrint('SyncEngine: skip question_knowledge (table not in remote)');
    }
  }

  Future<void> _pullJunctionIncremental(SupabaseClient client, String lastPullAt) async {
    // 中間テーブルには updated_at が無いため、差分取得が不可能。
    // フル取得を実行するが、重複チェック済みなので繰り返し実行しても安全。
    await _pullJunctionFullSafe(client);
  }

  Future<void> _pullKnowledgeCardTagsFull(SupabaseClient client) async {
    // knowledge_tags と JOIN して一括取得（N+1 クエリを回避）
    final rows = await client
        .from('knowledge_card_tags')
        .select('knowledge_id, tag_id, knowledge_tags(name)');
    if (rows.isEmpty) return;
    for (final row in rows as List) {
      final r = row as Map<String, dynamic>;
      final knowledgeId = _str(r['knowledge_id']);
      final tagId = _str(r['tag_id']);
      final tagData = r['knowledge_tags'] as Map<String, dynamic>?;
      final tagName = tagData != null ? _str(tagData['name']) : '';
      if (tagName.isEmpty) continue;
      final localKnowledge = await _localDb.db.query(
        LocalTable.knowledge,
        where: 'supabase_id = ?',
        whereArgs: [knowledgeId],
      );
      if (localKnowledge.isEmpty) continue;
      final localKnowledgeId = localKnowledge.first['local_id'] as int;
      // 重複チェック（繰り返し Pull で重複レコードが積み上がるのを防ぐ）
      final existing = await _localDb.db.query(
        LocalTable.knowledgeCardTags,
        where: 'local_knowledge_id = ? AND tag_name = ?',
        whereArgs: [localKnowledgeId, tagName],
      );
      if (existing.isNotEmpty) {
        // supabase_tag_id が未設定なら補完
        if (existing.first['supabase_tag_id'] == null) {
          await _localDb.db.update(
            LocalTable.knowledgeCardTags,
            {'supabase_tag_id': tagId, 'synced': 1},
            where: 'local_id = ?',
            whereArgs: [existing.first['local_id']],
          );
        }
        continue;
      }
      await _localDb.db.insert(LocalTable.knowledgeCardTags, {
        'local_knowledge_id': localKnowledgeId,
        'tag_name': tagName,
        'supabase_tag_id': tagId,
        'synced': 1,
      });
    }
  }

  Future<void> _pullMemorizationCardTagsFull(SupabaseClient client) async {
    final rows = await client
        .from('memorization_card_tags')
        .select('memorization_card_id, tag_id, memorization_tags(name)');
    if (rows.isEmpty) return;
    for (final row in rows as List) {
      final r = row as Map<String, dynamic>;
      final cardId = _str(r['memorization_card_id']);
      final tagId = _str(r['tag_id']);
      final tagData = r['memorization_tags'] as Map<String, dynamic>?;
      final tagName = tagData != null ? _str(tagData['name']) : '';
      if (tagName.isEmpty) continue;
      final localCards = await _localDb.db.query(
        LocalTable.memorizationCards,
        where: 'supabase_id = ?',
        whereArgs: [cardId],
      );
      if (localCards.isEmpty) continue;
      final localCardId = localCards.first['local_id'] as int;
      // 重複チェック
      final existing = await _localDb.db.query(
        LocalTable.memorizationCardTags,
        where: 'local_memorization_card_id = ? AND tag_name = ?',
        whereArgs: [localCardId, tagName],
      );
      if (existing.isNotEmpty) {
        if (existing.first['supabase_tag_id'] == null) {
          await _localDb.db.update(
            LocalTable.memorizationCardTags,
            {'supabase_tag_id': tagId, 'synced': 1},
            where: 'local_id = ?',
            whereArgs: [existing.first['local_id']],
          );
        }
        continue;
      }
      await _localDb.db.insert(LocalTable.memorizationCardTags, {
        'local_memorization_card_id': localCardId,
        'tag_name': tagName,
        'supabase_tag_id': tagId,
        'synced': 1,
      });
    }
  }

  Future<void> _pullQuestionKnowledgeFull(SupabaseClient client) async {
    final rows = await client.from('question_knowledge').select('question_id, knowledge_id, is_core');
    if (rows.isEmpty) return;
    for (final row in rows as List) {
      final r = row as Map<String, dynamic>;
      final questionId = _str(r['question_id']);
      final knowledgeId = _str(r['knowledge_id']);
      final isCore = (r['is_core'] == true) ? 1 : 0;
      final qRows = await _localDb.db.query(LocalTable.questions, where: 'supabase_id = ?', whereArgs: [questionId]);
      final kRows = await _localDb.db.query(LocalTable.knowledge, where: 'supabase_id = ?', whereArgs: [knowledgeId]);
      if (qRows.isEmpty || kRows.isEmpty) continue;
      final questionLocalId = qRows.first['local_id'] as int;
      final knowledgeLocalId = kRows.first['local_id'] as int;
      // 重複チェック
      final existing = await _localDb.db.query(
        LocalTable.questionKnowledge,
        where: 'question_local_id = ? AND knowledge_local_id = ?',
        whereArgs: [questionLocalId, knowledgeLocalId],
      );
      if (existing.isNotEmpty) {
        // is_core が変わっている場合は更新
        if (existing.first['is_core'] != isCore) {
          await _localDb.db.update(
            LocalTable.questionKnowledge,
            {'is_core': isCore},
            where: 'local_id = ?',
            whereArgs: [existing.first['local_id']],
          );
        }
        continue;
      }
      await _localDb.db.insert(LocalTable.questionKnowledge, {
        'question_local_id': questionLocalId,
        'knowledge_local_id': knowledgeLocalId,
        'is_core': isCore,
        'synced': 1,
      });
    }
  }

  /// リモートにテーブルが無い場合（PGRST205）はスキップ
  Future<void> _pushTableSafe(
    SupabaseClient client,
    String localTable,
    String remoteTable,
    Future<void> Function(SupabaseClient, Map<String, dynamic>) pushOne,
  ) async {
    try {
      await _pushTable(client, localTable, remoteTable, pushOne);
    } on PostgrestException catch (e) {
      if (e.code == 'PGRST205') {
        if (kDebugMode) debugPrint('SyncEngine: skip push $remoteTable (table not in remote)');
        return;
      }
      rethrow;
    }
  }

  Future<void> _push(SupabaseClient client) async {
    await _pushTable(client, LocalTable.subjects, 'subjects', _pushSubjectRow);
    await _pushTable(client, LocalTable.knowledge, 'knowledge', _pushKnowledgeRow);
    await _pushTableSafe(client, LocalTable.memorizationCards, 'memorization_cards', _pushMemorizationCardRow);
    await _pushTable(client, LocalTable.questions, 'questions', _pushQuestionRow);
    await _pushTableSafe(client, LocalTable.questionChoices, 'question_choices', _pushQuestionChoiceRow);
    await _pushTableSafe(client, LocalTable.questionAnswerLogs, 'question_answer_logs', _pushQuestionAnswerLogRow);
    await _pushTableSafe(client, LocalTable.questionLearningStates, 'question_learning_states', _pushQuestionLearningStateRow);
    await _pushTagsAndJunctions(client);
  }

  Future<void> _pushTable(
    SupabaseClient client,
    String localTable,
    String remoteTable,
    Future<void> Function(SupabaseClient, Map<String, dynamic>) pushOne,
  ) async {
    // 更新系: 1行ずつ個別 try/catch（1行の失敗が全体を止めない）
    final dirty = await _localDb.getDirty(localTable);
    for (final row in dirty) {
      try {
        await pushOne(client, row);
      } catch (e) {
        if (kDebugMode) debugPrint('SyncEngine: push failed for $localTable/${row["local_id"]}: $e');
        // dirty=1 のまま次回同期で再試行
      }
    }

    // 削除系: Supabase 側への soft delete が確認できた場合のみローカルを物理削除
    final dirtyDeleted = await _localDb.getDirtyDeleted(localTable);
    for (final row in dirtyDeleted) {
      final supabaseId = row['supabase_id'] as String?;
      if (supabaseId != null && supabaseId.isNotEmpty) {
        // soft delete: 物理 DELETE ではなく deleted_at をセット
        try {
          await client
              .from(remoteTable)
              .update({'deleted_at': LocalDatabase.nowUtc()})
              .eq('id', supabaseId);
          // Supabase 側の確認が取れた場合のみローカルも物理削除
          await _localDb.delete(localTable, where: 'local_id = ?', whereArgs: [row['local_id']]);
        } catch (e) {
          if (kDebugMode) {
            debugPrint('SyncEngine: soft delete failed for $remoteTable/$supabaseId: $e');
          }
          // Supabase 削除失敗 → dirty=1, deleted=1 のまま次回リトライ
        }
      } else {
        // supabase_id なし = オフライン中に作成してそのまま削除 → リモートには存在しないのでローカルのみ物理削除
        await _localDb.delete(localTable, where: 'local_id = ?', whereArgs: [row['local_id']]);
      }
    }
  }

  Future<void> _pushSubjectRow(SupabaseClient client, Map<String, dynamic> row) async {
    final supabaseId = row['supabase_id'] as String?;
    final payload = {'name': row['name'], 'display_order': row['display_order'] ?? 0};
    if (supabaseId == null || supabaseId.isEmpty) {
      final inserted = await client.from('subjects').insert(payload).select('id').single();
      final id = (inserted as Map)['id']?.toString();
      if (id != null) await _localDb.markSynced(LocalTable.subjects, row['local_id'] as int, supabaseId: id);
    } else {
      await client.from('subjects').upsert({...payload, 'id': supabaseId}, onConflict: 'id');
      await _localDb.markSynced(LocalTable.subjects, row['local_id'] as int, supabaseId: supabaseId);
    }
  }

  Future<void> _pushKnowledgeRow(SupabaseClient client, Map<String, dynamic> row) async {
    final subjectLocalId = row['subject_local_id'];
    if (subjectLocalId == null) return;
    final subjectRow = await _localDb.getByLocalId(LocalTable.subjects, subjectLocalId as int);
    final subjectSupabaseId = subjectRow?['supabase_id'] as String?;
    if (subjectSupabaseId == null || subjectSupabaseId.isEmpty) return;

    final supabaseId = row['supabase_id'] as String?;
    final payload = {
      'subject_id': subjectSupabaseId,
      'subject': row['subject'],
      'unit': row['unit'],
      'content': row['content'],
      'description': row['description'],
      'display_order': row['display_order'],
      'construction': row['construction'] == true || row['construction'] == 1,
      'author_comment': row['author_comment'],
      'dev_completed': row['dev_completed'] == true || row['dev_completed'] == 1,
    };
    if (supabaseId == null || supabaseId.isEmpty) {
      final inserted = await client.from('knowledge').insert(payload).select('id').single();
      final id = (inserted as Map)['id']?.toString();
      if (id != null) await _localDb.markSynced(LocalTable.knowledge, row['local_id'] as int, supabaseId: id);
    } else {
      await client.from('knowledge').upsert({...payload, 'id': supabaseId}, onConflict: 'id');
      await _localDb.markSynced(LocalTable.knowledge, row['local_id'] as int, supabaseId: supabaseId);
    }
  }

  Future<void> _pushMemorizationCardRow(SupabaseClient client, Map<String, dynamic> row) async {
    final subjectLocalId = row['subject_local_id'];
    final subjectRow = subjectLocalId != null ? await _localDb.getByLocalId(LocalTable.subjects, subjectLocalId as int) : null;
    final subjectSupabaseId = subjectRow?['supabase_id'] as String?;
    if (subjectSupabaseId == null || subjectSupabaseId.isEmpty) return;

    String? knowledgeSupabaseId;
    final knowledgeLocalId = row['knowledge_local_id'];
    if (knowledgeLocalId != null) {
      final kr = await _localDb.getByLocalId(LocalTable.knowledge, knowledgeLocalId as int);
      knowledgeSupabaseId = kr?['supabase_id'] as String?;
    }

    final supabaseId = row['supabase_id'] as String?;
    final payload = {
      'subject_id': subjectSupabaseId,
      'knowledge_id': knowledgeSupabaseId,
      'unit': row['unit'],
      'front_content': row['front_content'],
      'back_content': row['back_content'],
      'display_order': row['display_order'],
    };
    if (supabaseId == null || supabaseId.isEmpty) {
      final inserted = await client.from('memorization_cards').insert(payload).select('id').single();
      final id = (inserted as Map)['id']?.toString();
      if (id != null) await _localDb.markSynced(LocalTable.memorizationCards, row['local_id'] as int, supabaseId: id);
    } else {
      await client.from('memorization_cards').upsert({...payload, 'id': supabaseId}, onConflict: 'id');
      await _localDb.markSynced(LocalTable.memorizationCards, row['local_id'] as int, supabaseId: supabaseId);
    }
  }

  Future<void> _pushQuestionRow(SupabaseClient client, Map<String, dynamic> row) async {
    final knowledgeLocalId = row['knowledge_local_id'];
    String? knowledgeSupabaseId;
    if (knowledgeLocalId != null) {
      final kr = await _localDb.getByLocalId(LocalTable.knowledge, knowledgeLocalId as int);
      knowledgeSupabaseId = kr?['supabase_id'] as String?;
    }
    if (knowledgeSupabaseId == null || knowledgeSupabaseId.isEmpty) return;

    final supabaseId = row['supabase_id'] as String?;
    final payload = {
      'knowledge_id': knowledgeSupabaseId,
      'question_type': row['question_type'] ?? 'text_input',
      'question_text': row['question_text'],
      'correct_answer': row['correct_answer'],
      'explanation': row['explanation'],
      'reference': row['reference'],
      'choices': row['choices'],
      'dev_completed': row['dev_completed'] == true || row['dev_completed'] == 1,
    };
    if (supabaseId == null || supabaseId.isEmpty) {
      final inserted = await client.from('questions').insert(payload).select('id').single();
      final id = (inserted as Map)['id']?.toString();
      if (id != null) await _localDb.markSynced(LocalTable.questions, row['local_id'] as int, supabaseId: id);
    } else {
      await client.from('questions').upsert({...payload, 'id': supabaseId}, onConflict: 'id');
      await _localDb.markSynced(LocalTable.questions, row['local_id'] as int, supabaseId: supabaseId);
    }
  }

  Future<void> _pushQuestionChoiceRow(SupabaseClient client, Map<String, dynamic> row) async {
    final questionLocalId = row['question_local_id'];
    final qr = await _localDb.getByLocalId(LocalTable.questions, questionLocalId as int);
    final questionSupabaseId = qr?['supabase_id'] as String?;
    if (questionSupabaseId == null || questionSupabaseId.isEmpty) return;

    final supabaseId = row['supabase_id'] as String?;
    final payload = {
      'question_id': questionSupabaseId,
      'position': row['position'],
      'choice_text': row['choice_text'],
      'is_correct': (row['is_correct'] == 1),
    };
    if (supabaseId == null || supabaseId.isEmpty) {
      final inserted = await client.from('question_choices').insert(payload).select('id').single();
      final id = (inserted as Map)['id']?.toString();
      if (id != null) await _localDb.markSynced(LocalTable.questionChoices, row['local_id'] as int, supabaseId: id);
    } else {
      await client.from('question_choices').upsert({...payload, 'id': supabaseId}, onConflict: 'id');
      await _localDb.markSynced(LocalTable.questionChoices, row['local_id'] as int, supabaseId: supabaseId);
    }
  }

  Future<void> _pushQuestionAnswerLogRow(SupabaseClient client, Map<String, dynamic> row) async {
    final questionLocalId = row['question_local_id'];
    final qr = await _localDb.getByLocalId(LocalTable.questions, questionLocalId as int);
    final questionSupabaseId = qr?['supabase_id'] as String?;
    if (questionSupabaseId == null || questionSupabaseId.isEmpty) return;

    final supabaseId = row['supabase_id'] as String?;
    final payload = {
      'learner_id': row['learner_id'],
      'question_id': questionSupabaseId,
      'selected_choice_text': row['selected_choice_text'],
      'selected_index': row['selected_index'],
      'is_correct': (row['is_correct'] == 1),
      'answered_at': row['answered_at'],
    };
    if (supabaseId == null || supabaseId.isEmpty) {
      final inserted = await client.from('question_answer_logs').insert(payload).select('id').single();
      final id = (inserted as Map)['id']?.toString();
      if (id != null) {
        await _localDb.markSynced(LocalTable.questionAnswerLogs, row['local_id'] as int, supabaseId: id);
      }
    } else {
      await client.from('question_answer_logs').upsert({...payload, 'id': supabaseId}, onConflict: 'id');
      await _localDb.markSynced(LocalTable.questionAnswerLogs, row['local_id'] as int, supabaseId: supabaseId);
    }
  }

  Future<void> _pushQuestionLearningStateRow(SupabaseClient client, Map<String, dynamic> row) async {
    final questionLocalId = row['question_local_id'];
    final fromRow = _str(row['question_supabase_id'] as String?);
    final qr = await _localDb.getByLocalId(LocalTable.questions, questionLocalId as int);
    final fromQuestion = _str(qr?['supabase_id'] as String?);
    final questionSupabaseId = fromRow.isNotEmpty ? fromRow : fromQuestion;
    if (questionSupabaseId.isEmpty) {
      if (kDebugMode) {
        debugPrint(
          'SyncEngine: skip push question_learning_states local_id=${row['local_id']} '
          '(no question UUID; question_local_id=$questionLocalId)',
        );
      }
      return;
    }

    final supabaseId = row['supabase_id'] as String?;
    final learnerId = row['learner_id']?.toString() ?? '';
    if (learnerId.isEmpty) return;

    final stateFields = <String, dynamic>{
      'stability': row['stability'],
      'difficulty': row['difficulty'],
      'retrievability': row['retrievability'],
      'success_streak': row['success_streak'],
      'lapse_count': row['lapse_count'],
      'reviewed_count': row['reviewed_count'],
      'last_is_correct': row['last_is_correct'] == null ? null : (row['last_is_correct'] == 1),
      'last_selected_choice_text': row['last_selected_choice_text'],
      'last_selected_index': row['last_selected_index'],
      'last_review_at': row['last_review_at'],
      'next_review_at': row['next_review_at'],
      'updated_at': LocalDatabase.nowUtc(),
    };

    final remoteId = await QuestionLearningStateRemote.upsertState(
      client: client,
      learnerId: learnerId,
      questionId: questionSupabaseId,
      knownRemoteRowId: supabaseId != null && supabaseId.isNotEmpty ? supabaseId : null,
      stateFields: stateFields,
    );
    if (remoteId != null) {
      await _localDb.markSynced(LocalTable.questionLearningStates, row['local_id'] as int, supabaseId: remoteId);
    }
  }

  Future<void> _pushTagsAndJunctions(SupabaseClient client) async {
    // 1. 知識タグマスタ: supabase_id が null のもの = ローカルで新規作成、未Push
    final unsyncedKnowledgeTags = await _localDb.db.query(
      LocalTable.knowledgeTags,
      where: 'supabase_id IS NULL',
    );
    for (final tag in unsyncedKnowledgeTags) {
      try {
        // 同名タグが Supabase に既存でも upsert で問題なく取得
        final result = await client
            .from('knowledge_tags')
            .upsert({'name': tag['name']}, onConflict: 'name')
            .select('id')
            .single();
        final id = (result as Map)['id']?.toString();
        if (id != null) {
          await _localDb.db.update(
            LocalTable.knowledgeTags,
            {'supabase_id': id, 'synced_at': LocalDatabase.nowUtc()},
            where: 'local_id = ?',
            whereArgs: [tag['local_id']],
          );
          // 中間テーブルの supabase_tag_id も更新
          await _localDb.db.update(
            LocalTable.knowledgeCardTags,
            {'supabase_tag_id': id},
            where: 'tag_name = ? AND supabase_tag_id IS NULL',
            whereArgs: [tag['name']],
          );
        }
      } catch (e) {
        if (kDebugMode) debugPrint('SyncEngine: push knowledge_tag "${tag["name"]}" failed: $e');
      }
    }

    // 2. 知識-タグ 中間テーブル: synced=0 のもの
    final unsyncedKCardTags = await _localDb.db.query(
      LocalTable.knowledgeCardTags,
      where: 'synced = ?',
      whereArgs: [0],
    );
    for (final ct in unsyncedKCardTags) {
      try {
        final kr = await _localDb.getByLocalId(LocalTable.knowledge, ct['local_knowledge_id'] as int);
        final knowledgeSupabaseId = kr?['supabase_id'] as String?;
        final tagSupabaseId = ct['supabase_tag_id'] as String?;
        if (knowledgeSupabaseId == null || knowledgeSupabaseId.isEmpty) continue;
        if (tagSupabaseId == null || tagSupabaseId.isEmpty) continue;
        await client.from('knowledge_card_tags').upsert(
          {'knowledge_id': knowledgeSupabaseId, 'tag_id': tagSupabaseId},
          onConflict: 'knowledge_id,tag_id',
        );
        await _localDb.db.update(
          LocalTable.knowledgeCardTags,
          {'synced': 1},
          where: 'local_id = ?',
          whereArgs: [ct['local_id']],
        );
      } catch (e) {
        if (kDebugMode) debugPrint('SyncEngine: push knowledge_card_tag failed: $e');
      }
    }

    // 3. 暗記タグマスタ: supabase_id が null のもの
    final unsyncedMemTags = await _localDb.db.query(
      LocalTable.memorizationTags,
      where: 'supabase_id IS NULL',
    );
    for (final tag in unsyncedMemTags) {
      try {
        final result = await client
            .from('memorization_tags')
            .upsert({'name': tag['name']}, onConflict: 'name')
            .select('id')
            .single();
        final id = (result as Map)['id']?.toString();
        if (id != null) {
          await _localDb.db.update(
            LocalTable.memorizationTags,
            {'supabase_id': id, 'synced_at': LocalDatabase.nowUtc()},
            where: 'local_id = ?',
            whereArgs: [tag['local_id']],
          );
          await _localDb.db.update(
            LocalTable.memorizationCardTags,
            {'supabase_tag_id': id},
            where: 'tag_name = ? AND supabase_tag_id IS NULL',
            whereArgs: [tag['name']],
          );
        }
      } catch (e) {
        if (kDebugMode) debugPrint('SyncEngine: push memorization_tag "${tag["name"]}" failed: $e');
      }
    }

    // 4. 暗記カード-タグ 中間テーブル: synced=0 のもの
    final unsyncedMCardTags = await _localDb.db.query(
      LocalTable.memorizationCardTags,
      where: 'synced = ?',
      whereArgs: [0],
    );
    for (final ct in unsyncedMCardTags) {
      try {
        final cr = await _localDb.getByLocalId(LocalTable.memorizationCards, ct['local_memorization_card_id'] as int);
        final cardSupabaseId = cr?['supabase_id'] as String?;
        final tagSupabaseId = ct['supabase_tag_id'] as String?;
        if (cardSupabaseId == null || cardSupabaseId.isEmpty) continue;
        if (tagSupabaseId == null || tagSupabaseId.isEmpty) continue;
        await client.from('memorization_card_tags').upsert(
          {'memorization_card_id': cardSupabaseId, 'tag_id': tagSupabaseId},
          onConflict: 'memorization_card_id,tag_id',
        );
        await _localDb.db.update(
          LocalTable.memorizationCardTags,
          {'synced': 1},
          where: 'local_id = ?',
          whereArgs: [ct['local_id']],
        );
      } catch (e) {
        if (kDebugMode) debugPrint('SyncEngine: push memorization_card_tag failed: $e');
      }
    }

    // 5. 問題-知識 中間テーブル: synced=0 のもの
    final unsyncedQK = await _localDb.db.query(
      LocalTable.questionKnowledge,
      where: 'synced = ?',
      whereArgs: [0],
    );
    for (final qk in unsyncedQK) {
      try {
        final qr = await _localDb.getByLocalId(LocalTable.questions, qk['question_local_id'] as int);
        final kr = await _localDb.getByLocalId(LocalTable.knowledge, qk['knowledge_local_id'] as int);
        final qSupabaseId = qr?['supabase_id'] as String?;
        final kSupabaseId = kr?['supabase_id'] as String?;
        if (qSupabaseId == null || qSupabaseId.isEmpty) continue;
        if (kSupabaseId == null || kSupabaseId.isEmpty) continue;
        await client.from('question_knowledge').upsert(
          {'question_id': qSupabaseId, 'knowledge_id': kSupabaseId, 'is_core': (qk['is_core'] == 1)},
          onConflict: 'question_id,knowledge_id',
        );
        await _localDb.db.update(
          LocalTable.questionKnowledge,
          {'synced': 1},
          where: 'local_id = ?',
          whereArgs: [qk['local_id']],
        );
      } catch (e) {
        if (kDebugMode) debugPrint('SyncEngine: push question_knowledge failed: $e');
      }
    }
  }

  static String _str(dynamic v) => v?.toString().trim() ?? '';

  static DateTime? _parseUtc(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      return DateTime.parse(s).toUtc();
    } catch (_) {
      return null;
    }
  }
}
