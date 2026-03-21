import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../database/local_database.dart';
import '../models/knowledge.dart';
import '../sync/ensure_synced_for_local_read.dart';

/// 知識カードの取得・保存・削除
abstract class KnowledgeRepository {
  Future<List<Knowledge>> getBySubject(String subjectId);
  Future<Knowledge> save(Knowledge item, {required String subjectId, required String subjectName});
  Future<void> delete(String id);
}

/// Web: Supabase 直接
class KnowledgeRepositorySupabase implements KnowledgeRepository {
  @override
  Future<List<Knowledge>> getBySubject(String subjectId) async {
    final client = Supabase.instance.client;
    List<dynamic> rows;
    try {
      rows = await client
          .from('knowledge')
          .select('*, knowledge_card_tags(tag_id, knowledge_tags(name))')
          .eq('subject_id', subjectId)
          .order('display_order', ascending: true)
          .order('created_at', ascending: true);
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[KnowledgeRepositorySupabase.getBySubject] try1 failed subjectId=$subjectId: $e');
        debugPrint('[KnowledgeRepositorySupabase.getBySubject] try1 stack: $st');
      }
      rows = await client
          .from('knowledge')
          .select()
          .eq('subject_id', subjectId)
          .order('display_order', ascending: true)
          .order('created_at', ascending: true);
    }
    if (kDebugMode) debugPrint('[KnowledgeRepositorySupabase.getBySubject] subjectId=$subjectId result count=${rows.length}');
    return (rows as List<Map<String, dynamic>>).map(Knowledge.fromSupabase).toList();
  }

  @override
  Future<Knowledge> save(Knowledge item, {required String subjectId, required String subjectName}) async {
    final client = Supabase.instance.client;
    final payload = {
      'subject_id': subjectId,
      'subject': subjectName,
      'content': item.content,
      'description': item.description,
      'unit': item.unit,
      'display_order': item.displayOrder,
      'construction': item.construction,
      'author_comment': item.authorComment,
      'dev_completed': item.devCompleted,
    };
    if (item.id.startsWith('local_')) {
      final inserted = await client.from('knowledge').insert(payload).select().single();
      final saved = Knowledge.fromSupabase(inserted);
      await Knowledge.syncTags(client, saved.id, item.tags);
      return saved;
    }
    await client.from('knowledge').update(payload).eq('id', item.id);
    await Knowledge.syncTags(client, item.id, item.tags);
    return item;
  }

  @override
  Future<void> delete(String id) async {
    if (id.startsWith('local_')) return;
    await Supabase.instance.client.from('knowledge').delete().eq('id', id);
  }
}

/// Mobile/Desktop: ローカルDB（deleted=0 のみ）。保存時は dirty=1 にして SyncEngine で Push。
class KnowledgeRepositoryLocal implements KnowledgeRepository {
  KnowledgeRepositoryLocal(this._localDb);

  final LocalDatabase _localDb;

  /// Supabase の科目 ID を `local_subjects.local_id` に解決する。
  ///
  /// 一覧が [KnowledgeListScreen] の Supabase フォールバックだけで表示されているとき、
  /// 科目行が未同期でも保存できるようにする。
  Future<int> _subjectLocalIdForSupabaseId(String subjectId) async {
    final existing = await _localDb.getBySupabaseId('local_subjects', subjectId);
    if (existing != null) return existing['local_id'] as int;

    await ensureSyncedForLocalRead();
    final afterSync = await _localDb.getBySupabaseId('local_subjects', subjectId);
    if (afterSync != null) return afterSync['local_id'] as int;

    final remote = await Supabase.instance.client.from('subjects').select().eq('id', subjectId).maybeSingle();
    if (remote == null) {
      throw StateError('Subject not found: $subjectId');
    }
    final row = Map<String, dynamic>.from(remote);
    row['name'] = row['name']?.toString() ?? '';
    row['display_order'] = (row['display_order'] as num?)?.toInt() ?? 0;
    await _localDb.upsertBySupabaseId(
      'local_subjects',
      row,
      businessColumns: const ['name', 'display_order'],
      supabaseIdColumnName: 'id',
    );
    final resolved = await _localDb.getBySupabaseId('local_subjects', subjectId);
    if (resolved == null) {
      throw StateError('Subject not found: $subjectId');
    }
    return resolved['local_id'] as int;
  }

  @override
  Future<List<Knowledge>> getBySubject(String subjectId) async {
    List<Map<String, dynamic>> rows;
    if (subjectId.startsWith('local_')) {
      final localId = int.tryParse(subjectId.substring(6)) ?? -1;
      if (localId < 0) return [];
      rows = await _localDb.db.query(
        'local_knowledge',
        where: 'subject_local_id = ? AND deleted = ?',
        whereArgs: [localId, 0],
        orderBy: 'display_order ASC, local_id ASC',
      );
    } else {
      final subRows = await _localDb.db.query('local_subjects', where: 'supabase_id = ?', whereArgs: [subjectId]);
      if (subRows.isEmpty) return [];
      final subjectLocalId = subRows.first['local_id'] as int;
      rows = await _localDb.db.query(
        'local_knowledge',
        where: 'subject_local_id = ? AND deleted = ?',
        whereArgs: [subjectLocalId, 0],
        orderBy: 'display_order ASC, local_id ASC',
      );
    }
    final result = <Knowledge>[];
    for (final row in rows) {
      final knowledgeLocalId = row['local_id'] as int;
      final tagRows = await _localDb.db.query(
        'local_knowledge_card_tags',
        where: 'local_knowledge_id = ?',
        whereArgs: [knowledgeLocalId],
      );
      final tags = tagRows.map((t) => t['tag_name'] as String? ?? '').where((s) => s.isNotEmpty).toList();
      result.add(Knowledge.fromLocal(row, tags: tags));
    }
    return result;
  }

  @override
  Future<Knowledge> save(Knowledge item, {required String subjectId, required String subjectName}) async {
    late final int subjectLocalId;
    if (subjectId.startsWith('local_')) {
      final parsed = int.tryParse(subjectId.substring(6));
      if (parsed == null) throw StateError('Subject not found: $subjectId');
      subjectLocalId = parsed;
    } else {
      subjectLocalId = await _subjectLocalIdForSupabaseId(subjectId);
    }

    if (item.id.startsWith('local_')) {
      final localIdStr = item.id.substring(6);
      final localId = int.tryParse(localIdStr);
      if (localId != null && localId > 0) {
        await _localDb.updateWithSync(
          'local_knowledge',
          {
            'subject_local_id': subjectLocalId,
            'subject': subjectName,
            'unit': item.unit,
            'content': item.content,
            'description': item.description,
            'display_order': item.displayOrder,
            'type': item.type,
            'construction': item.construction ? 1 : 0,
            'author_comment': item.authorComment,
            'dev_completed': item.devCompleted ? 1 : 0,
          },
          where: 'local_id = ?',
          whereArgs: [localId],
        );
        await _saveTagsForLocalKnowledge(localId, item.tags);
        return Knowledge.fromLocal(
          (await _localDb.getByLocalId('local_knowledge', localId))!,
          tags: item.tags,
        );
      }
    }

    final supabaseId = item.id.startsWith('local_') ? null : item.id;
    if (supabaseId != null && supabaseId.isNotEmpty) {
      final existing = await _localDb.getBySupabaseId('local_knowledge', supabaseId);
      if (existing != null) {
        final localId = existing['local_id'] as int;
        await _localDb.updateWithSync(
          'local_knowledge',
          {
            'subject_local_id': subjectLocalId,
            'subject': subjectName,
            'unit': item.unit,
            'content': item.content,
            'description': item.description,
            'display_order': item.displayOrder,
            'type': item.type,
            'construction': item.construction ? 1 : 0,
            'author_comment': item.authorComment,
            'dev_completed': item.devCompleted ? 1 : 0,
          },
          where: 'local_id = ?',
          whereArgs: [localId],
        );
        await _saveTagsForLocalKnowledge(localId, item.tags);
        return Knowledge.fromLocal(
          (await _localDb.getByLocalId('local_knowledge', localId))!,
          tags: item.tags,
        );
      }
    }
    final idForPush = supabaseId ?? const Uuid().v4();
    final row = {
      'subject_local_id': subjectLocalId,
      'subject': subjectName,
      'unit': item.unit,
      'content': item.content,
      'description': item.description,
      'display_order': item.displayOrder,
      'type': item.type,
      'construction': item.construction ? 1 : 0,
      'author_comment': item.authorComment,
      'dev_completed': item.devCompleted ? 1 : 0,
      'supabase_id': idForPush,
    };
    final id = await _localDb.insertWithSync('local_knowledge', row);
    await _saveTagsForLocalKnowledge(id, item.tags);
    final inserted = await _localDb.getByLocalId('local_knowledge', id);
    return Knowledge.fromLocal(inserted!, tags: item.tags);
  }

  Future<void> _saveTagsForLocalKnowledge(int localKnowledgeId, List<String> tags) async {
    await _localDb.db.delete('local_knowledge_card_tags', where: 'local_knowledge_id = ?', whereArgs: [localKnowledgeId]);
    final trimmed = tags.map((s) => s.trim()).where((s) => s.isNotEmpty).toSet().toList()..sort();
    for (final name in trimmed) {
      await _localDb.db.insert('local_knowledge_card_tags', {
        'local_knowledge_id': localKnowledgeId,
        'tag_name': name,
        'synced': 0,
      });
    }
  }

  @override
  Future<void> delete(String id) async {
    if (id.startsWith('local_')) {
      final localId = int.tryParse(id.substring(6));
      if (localId != null && localId > 0) {
        await _localDb.softDelete('local_knowledge', localId);
      }
      return;
    }
    final row = await _localDb.getBySupabaseId('local_knowledge', id);
    if (row != null) {
      await _localDb.softDelete('local_knowledge', row['local_id'] as int);
    }
  }
}

KnowledgeRepository createKnowledgeRepository(LocalDatabase? localDb) {
  if (kIsWeb || localDb == null) {
    return KnowledgeRepositorySupabase();
  }
  return KnowledgeRepositoryLocal(localDb);
}
