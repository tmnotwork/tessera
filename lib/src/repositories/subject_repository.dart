import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../database/local_database.dart';

/// 科目一覧の取得
abstract class SubjectRepository {
  Future<List<Map<String, dynamic>>> getSubjectsOrderByDisplayOrder();
}

/// Web: Supabase 直接
class SubjectRepositorySupabase implements SubjectRepository {
  @override
  Future<List<Map<String, dynamic>>> getSubjectsOrderByDisplayOrder() async {
    final client = Supabase.instance.client;
    final rows = await client.from('subjects').select().order('display_order');
    return List<Map<String, dynamic>>.from(rows);
  }
}

/// Mobile/Desktop: ローカルDB（deleted=0 のみ）
class SubjectRepositoryLocal implements SubjectRepository {
  SubjectRepositoryLocal(this._localDb);

  final LocalDatabase _localDb;

  @override
  Future<List<Map<String, dynamic>>> getSubjectsOrderByDisplayOrder() async {
    final rows = await _localDb.db.query(
      'local_subjects',
      where: 'deleted = ?',
      whereArgs: [0],
      orderBy: 'display_order ASC, local_id ASC',
    );
    return rows.map((r) {
      final id = r['supabase_id'] as String?;
      return <String, dynamic>{
        'id': id?.isNotEmpty == true ? id : 'local_${r['local_id']}',
        'name': r['name'],
        'display_order': r['display_order'],
        'local_id': r['local_id'],
      };
    }).toList();
  }
}

/// プラットフォームに応じた SubjectRepository を返す
SubjectRepository createSubjectRepository(LocalDatabase? localDb) {
  if (kIsWeb || localDb == null) {
    return SubjectRepositorySupabase();
  }
  return SubjectRepositoryLocal(localDb);
}
