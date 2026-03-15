import 'package:sqflite/sqflite.dart';

/// ローカルDBのテーブル名（同期用）
class LocalTable {
  static const subjects = 'local_subjects';
  static const knowledge = 'local_knowledge';
  static const memorizationCards = 'local_memorization_cards';
  static const questions = 'local_questions';
  static const questionChoices = 'local_question_choices';
  static const knowledgeTags = 'local_knowledge_tags';
  static const knowledgeCardTags = 'local_knowledge_card_tags';
  static const memorizationTags = 'local_memorization_tags';
  static const memorizationCardTags = 'local_memorization_card_tags';
  static const questionKnowledge = 'local_question_knowledge';
}

/// 双方向同期用ローカルDBの CRUD と dirty 管理。
/// Repository / SyncEngine から利用する。
class LocalDatabase {
  LocalDatabase(this._db);

  final Database _db;

  Database get db => _db;

  /// UTC の ISO8601 文字列（同期・比較用に統一）
  static String nowUtc() {
    return DateTime.now().toUtc().toIso8601String();
  }

  /// 新規挿入（dirty=1, created_at/updated_at をセット）
  Future<int> insertWithSync(String table, Map<String, dynamic> values) async {
    final now = nowUtc();
    final row = Map<String, dynamic>.from(values)
      ..['dirty'] = 1
      ..['deleted'] = values['deleted'] ?? 0
      ..['created_at'] = values['created_at'] ?? now
      ..['updated_at'] = values['updated_at'] ?? now;
    return _db.insert(table, row);
  }

  /// 更新（dirty=1, updated_at をセット）
  Future<int> updateWithSync(
    String table,
    Map<String, dynamic> values, {
    required String where,
    required List<Object?> whereArgs,
  }) async {
    final row = Map<String, dynamic>.from(values)
      ..['dirty'] = 1
      ..['updated_at'] = nowUtc();
    return _db.update(table, row, where: where, whereArgs: whereArgs);
  }

  /// ソフトデリート（deleted=1, dirty=1, updated_at）
  Future<int> softDelete(String table, int localId) async {
    return _db.update(
      table,
      {'deleted': 1, 'dirty': 1, 'updated_at': nowUtc()},
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  /// 物理削除（Push 完了後の削除済みレコードなど）
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) async {
    return _db.delete(table, where: where, whereArgs: whereArgs);
  }

  /// dirty=1 かつ deleted=0 のレコードを取得（Push 用）
  Future<List<Map<String, dynamic>>> getDirty(String table) async {
    return _db.query(
      table,
      where: 'dirty = ? AND deleted = ?',
      whereArgs: [1, 0],
    );
  }

  /// dirty=1 かつ deleted=1 のレコードを取得（Push で削除反映用）
  Future<List<Map<String, dynamic>>> getDirtyDeleted(String table) async {
    return _db.query(
      table,
      where: 'dirty = ? AND deleted = ?',
      whereArgs: [1, 1],
    );
  }

  /// 同期完了後に dirty=0, synced_at をセットし supabase_id を保存
  Future<void> markSynced(
    String table,
    int localId, {
    required String? supabaseId,
  }) async {
    final values = <String, dynamic>{
      'dirty': 0,
      'synced_at': nowUtc(),
    };
    if (supabaseId != null) {
      values['supabase_id'] = supabaseId;
    }
    await _db.update(
      table,
      values,
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  /// Pull で取得した行をマージ: 存在しなければ INSERT、存在すれば updated_at 比較で上書き or 維持
  /// supabase_id で照合。返り値は upsert 後の local_id。
  Future<int> upsertBySupabaseId(
    String table,
    Map<String, dynamic> remote, {
    required List<String> businessColumns,
    required String supabaseIdColumnName,
  }) async {
    final supabaseId = remote[supabaseIdColumnName] as String?;
    if (supabaseId == null || supabaseId.isEmpty) return -1;

    final existing = await _db.query(
      table,
      where: 'supabase_id = ?',
      whereArgs: [supabaseId],
    );

    final now = nowUtc();
    final row = <String, dynamic>{};
    for (final col in businessColumns) {
      if (remote.containsKey(col)) row[col] = remote[col];
    }
    row['supabase_id'] = supabaseId;
    row['updated_at'] = remote['updated_at'] ?? now;
    row['synced_at'] = now;
    row['dirty'] = 0;
    row['deleted'] = 0;

    if (existing.isEmpty) {
      row['created_at'] = remote['created_at'] ?? now;
      return await _db.insert(table, row);
    }

    final localId = existing.first['local_id'] as int;
    row.remove('created_at');
    await _db.update(
      table,
      row,
      where: 'local_id = ?',
      whereArgs: [localId],
    );
    return localId;
  }

  /// supabase_id でレコードを取得
  Future<Map<String, dynamic>?> getBySupabaseId(String table, String supabaseId) async {
    final rows = await _db.query(
      table,
      where: 'supabase_id = ?',
      whereArgs: [supabaseId],
    );
    return rows.isNotEmpty ? rows.first : null;
  }

  /// local_id でレコードを取得
  Future<Map<String, dynamic>?> getByLocalId(String table, int localId) async {
    final rows = await _db.query(
      table,
      where: 'local_id = ?',
      whereArgs: [localId],
    );
    return rows.isNotEmpty ? rows.first : null;
  }
}
