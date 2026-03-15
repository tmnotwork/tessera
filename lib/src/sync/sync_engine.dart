import 'package:flutter/foundation.dart';
import 'package:postgrest/postgrest.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../database/local_database.dart';
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

  /// オンラインなら同期を実行。オフラインなら何もしない。
  Future<void> syncIfOnline() async {
    if (kIsWeb) return;
    try {
      // connectivity 未導入時は常に試行（失敗すれば is_syncing を戻す）
      await sync();
    } catch (_) {
      // ネット不可など
    }
  }

  /// 同期実行: 1) Pull 2) Push。完了時に SyncNotifier に通知。
  Future<void> sync() async {
    if (kIsWeb) return;
    if (_syncing) return;

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
        final isMissingColumn = e.code == '42703' || (e.message.contains('does not exist') && e.message.contains('deleted_at'));
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
    await _pullJunctionIncremental(client, lastPullAt);
  }

  static const _subjectCols = ['id', 'name', 'display_order', 'created_at', 'updated_at', 'deleted_at'];
  static const _knowledgeCols = ['id', 'subject_id', 'subject', 'unit', 'content', 'description', 'display_order', 'created_at', 'updated_at', 'deleted_at'];
  static const _memorizationCardCols = ['id', 'subject_id', 'knowledge_id', 'unit', 'front_content', 'back_content', 'display_order', 'created_at', 'updated_at', 'deleted_at'];
  static const _questionCols = ['id', 'knowledge_id', 'question_type', 'question_text', 'correct_answer', 'explanation', 'reference', 'choices', 'created_at', 'updated_at', 'deleted_at'];
  static const _questionChoiceCols = ['id', 'question_id', 'position', 'choice_text', 'is_correct', 'created_at', 'deleted_at'];
  /// deleted_at 未追加のリモート用（マイグレーション 00014_add_deleted_at_for_sync 未適用時）
  static const _subjectColsLegacy = ['id', 'name', 'display_order', 'created_at', 'updated_at'];
  static const _knowledgeColsLegacy = ['id', 'subject_id', 'subject', 'unit', 'content', 'description', 'display_order', 'created_at', 'updated_at'];
  static const _memorizationCardColsLegacy = ['id', 'subject_id', 'knowledge_id', 'unit', 'front_content', 'back_content', 'display_order', 'created_at', 'updated_at'];
  static const _questionColsLegacy = ['id', 'knowledge_id', 'question_type', 'question_text', 'correct_answer', 'explanation', 'reference', 'choices', 'created_at', 'updated_at'];
  static const _questionChoiceColsLegacy = ['id', 'question_id', 'position', 'choice_text', 'is_correct', 'created_at'];
  static const _knowledgeTagCols = ['id', 'name', 'created_at'];
  static const _memorizationTagCols = ['id', 'name', 'created_at'];

  bool _useLegacyCols = false;

  List<String> get _effectiveSubjectCols => _useLegacyCols ? _subjectColsLegacy : _subjectCols;
  List<String> get _effectiveKnowledgeCols => _useLegacyCols ? _knowledgeColsLegacy : _knowledgeCols;
  List<String> get _effectiveMemorizationCardCols => _useLegacyCols ? _memorizationCardColsLegacy : _memorizationCardCols;
  List<String> get _effectiveQuestionCols => _useLegacyCols ? _questionColsLegacy : _questionCols;
  List<String> get _effectiveQuestionChoiceCols => _useLegacyCols ? _questionChoiceColsLegacy : _questionChoiceCols;

  Future<void> _pullTableFull(SupabaseClient client, String remoteTable, String localTable, List<String> cols) async {
    int offset = 0;
    while (true) {
      final rows = await client.from(remoteTable).select(cols.join(',')).range(offset, offset + _pageSize - 1);
      if (rows.isEmpty) break;
      for (final row in rows as List) {
        await _mergeRow(localTable, row as Map<String, dynamic>, remoteTable, fullPull: true);
      }
      offset += _pageSize;
      if ((rows as List).length < _pageSize) break;
    }
  }

  Future<void> _pullTableIncremental(SupabaseClient client, String remoteTable, String localTable, List<String> cols, String lastPullAt) async {
    int offset = 0;
    while (true) {
      final rows = await client
          .from(remoteTable)
          .select(cols.join(','))
          .gte('updated_at', lastPullAt)
          .range(offset, offset + _pageSize - 1);
      if (rows.isEmpty) break;
      for (final row in rows as List) {
        await _mergeRow(localTable, row as Map<String, dynamic>, remoteTable, fullPull: false);
      }
      offset += _pageSize;
      if ((rows as List).length < _pageSize) break;
    }
  }

  Future<void> _mergeRow(String localTable, Map<String, dynamic> remote, String remoteTable, {required bool fullPull}) async {
    final supabaseId = _str(remote['id']);
    if (supabaseId.isEmpty) return;
    final deletedAt = remote['deleted_at'];
    final isDeleted = deletedAt != null && deletedAt.toString().isNotEmpty;

    final existing = await _localDb.getBySupabaseId(localTable, supabaseId);
    if (existing == null) {
      await _insertRemoteRow(localTable, remote, remoteTable, isDeleted);
      return;
    }
    if (existing['dirty'] == 1) {
      final localUpdated = _parseUtc(existing['updated_at']?.toString());
      final remoteUpdated = _parseUtc(remote['updated_at']?.toString());
      if (remoteUpdated != null && localUpdated != null && remoteUpdated.isAfter(localUpdated)) {
        await _updateLocalFromRemote(localTable, remote, remoteTable, existing['local_id'] as int, isDeleted);
      }
      return;
    }
    await _updateLocalFromRemote(localTable, remote, remoteTable, existing['local_id'] as int, isDeleted);
  }

  Future<void> _insertRemoteRow(String localTable, Map<String, dynamic> remote, String remoteTable, bool isDeleted) async {
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
      if (questionSupabaseId.isNotEmpty) {
        final q = await _localDb.getBySupabaseId(LocalTable.questions, questionSupabaseId);
        if (q != null) row['question_local_id'] = q['local_id'];
      }
    }
    await _localDb.db.insert(localTable, row);
  }

  Future<void> _updateLocalFromRemote(String localTable, Map<String, dynamic> remote, String remoteTable, int localId, bool isDeleted) async {
    final row = _remoteToLocalRow(remote, remoteTable);
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
    } else if (remoteTable == 'question_choices') {
      map['position'] = remote['position'] ?? 0;
      map['choice_text'] = remote['choice_text'] ?? '';
      map['is_correct'] = (remote['is_correct'] == true) ? 1 : 0;
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
    // 中間テーブルに updated_at が無いため、初回のみフル取得で対応。差分は現フェーズではスキップ（親の Pull で十分な場合が多い）
  }

  Future<void> _pullKnowledgeCardTagsFull(SupabaseClient client) async {
    final rows = await client.from('knowledge_card_tags').select('knowledge_id, tag_id');
    if (rows.isEmpty) return;
    for (final row in rows as List) {
      final r = row as Map<String, dynamic>;
      final knowledgeId = _str(r['knowledge_id']);
      final tagId = _str(r['tag_id']);
      final tagRow = await client.from('knowledge_tags').select('name').eq('id', tagId).maybeSingle();
      final tagName = tagRow != null ? _str((tagRow as Map)['name']) : '';
      if (tagName.isEmpty) continue;
      final localKnowledge = await _localDb.db.query(LocalTable.knowledge, where: 'supabase_id = ?', whereArgs: [knowledgeId]);
      if (localKnowledge.isEmpty) continue;
      final localKnowledgeId = localKnowledge.first['local_id'] as int;
      await _localDb.db.insert(LocalTable.knowledgeCardTags, {
        'local_knowledge_id': localKnowledgeId,
        'tag_name': tagName,
        'supabase_tag_id': tagId,
        'synced': 1,
      });
    }
  }

  Future<void> _pullMemorizationCardTagsFull(SupabaseClient client) async {
    final rows = await client.from('memorization_card_tags').select('memorization_card_id, tag_id');
    if (rows.isEmpty) return;
    for (final row in rows as List) {
      final r = row as Map<String, dynamic>;
      final cardId = _str(r['memorization_card_id']);
      final tagId = _str(r['tag_id']);
      final tagRow = await client.from('memorization_tags').select('name').eq('id', tagId).maybeSingle();
      final tagName = tagRow != null ? _str((tagRow as Map)['name']) : '';
      if (tagName.isEmpty) continue;
      final localCards = await _localDb.db.query(LocalTable.memorizationCards, where: 'supabase_id = ?', whereArgs: [cardId]);
      if (localCards.isEmpty) continue;
      await _localDb.db.insert(LocalTable.memorizationCardTags, {
        'local_memorization_card_id': localCards.first['local_id'],
        'tag_name': tagName,
        'supabase_tag_id': tagId,
        'synced': 1,
      });
    }
  }

  Future<void> _pullQuestionKnowledgeFull(SupabaseClient client) async {
    final rows = await client.from('question_knowledge').select('question_id, knowledge_id');
    if (rows.isEmpty) return;
    for (final row in rows as List) {
      final r = row as Map<String, dynamic>;
      final questionId = _str(r['question_id']);
      final knowledgeId = _str(r['knowledge_id']);
      final qRows = await _localDb.db.query(LocalTable.questions, where: 'supabase_id = ?', whereArgs: [questionId]);
      final kRows = await _localDb.db.query(LocalTable.knowledge, where: 'supabase_id = ?', whereArgs: [knowledgeId]);
      if (qRows.isEmpty || kRows.isEmpty) continue;
      await _localDb.db.insert(LocalTable.questionKnowledge, {
        'question_local_id': qRows.first['local_id'],
        'knowledge_local_id': kRows.first['local_id'],
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
    await _pushTagsAndJunctions(client);
  }

  Future<void> _pushTable(
    SupabaseClient client,
    String localTable,
    String remoteTable,
    Future<void> Function(SupabaseClient, Map<String, dynamic>) pushOne,
  ) async {
    final dirty = await _localDb.getDirty(localTable);
    for (final row in dirty) {
      await pushOne(client, row);
    }
    final dirtyDeleted = await _localDb.getDirtyDeleted(localTable);
    for (final row in dirtyDeleted) {
      final supabaseId = row['supabase_id'] as String?;
      if (supabaseId != null && supabaseId.isNotEmpty) {
        try {
          await client.from(remoteTable).delete().eq('id', supabaseId);
        } catch (_) {}
      }
      await _localDb.delete(localTable, where: 'local_id = ?', whereArgs: [row['local_id']]);
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

  Future<void> _pushTagsAndJunctions(SupabaseClient client) async {
    // タグマスタと中間テーブルは簡略化: dirty な knowledge に紐づく knowledge_card_tags を Push する場合は、SyncEngine 拡張で対応。現フェーズではエンティティの Push まで。
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
