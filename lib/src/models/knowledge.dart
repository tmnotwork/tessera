import 'package:supabase_flutter/supabase_flutter.dart';

/// Supabase の knowledge テーブルに対応するモデル
///
/// カラムマッピング:
///   content       = 知識のタイトル（旧 title）
///   description   = 詳細説明（旧 explanation）
///   unit          = チャプター区切り（旧 topic）
///   display_order = 並び順（旧 order）
/// タグは中間テーブル knowledge_card_tags + knowledge_tags で多対多
class Knowledge {
  final String id;
  final String? subjectId;
  final String? subject;
  final String? unit;
  final String content;
  final String? description;
  final String type;
  final int? displayOrder;
  final bool construction;
  final List<String> tags;  // knowledge_card_tags 経由
  final String? authorComment;

  Knowledge({
    required this.id,
    this.subjectId,
    this.subject,
    this.unit,
    required this.content,
    this.description,
    this.type = 'grammar',
    this.displayOrder,
    this.construction = false,
    this.tags = const [],
    this.authorComment,
  });

  // 旧モデルとの互換エイリアス
  String get title => content;
  String get explanation => description ?? '';
  String? get topic => unit;
  int? get order => displayOrder;

  factory Knowledge.fromSupabase(Map<String, dynamic> row) {
    return Knowledge(
      id: row['id'] as String,
      subjectId: row['subject_id'] as String?,
      subject: row['subject'] as String?,
      unit: row['unit'] as String?,
      content: row['content'] as String? ?? '',
      description: row['description'] as String?,
      type: row['type'] as String? ?? 'grammar',
      displayOrder: row['display_order'] as int?,
      construction: row['construction'] as bool? ?? false,
      tags: _parseTagsFromRow(row),
      authorComment: row['author_comment'] as String?,
    );
  }

  /// ローカルDBの local_knowledge 行から生成。tags は local_knowledge_card_tags から別途渡す。
  factory Knowledge.fromLocal(Map<String, dynamic> row, {List<String> tags = const []}) {
    final localId = row['local_id'] as int?;
    final supabaseId = row['supabase_id'] as String?;
    final id = (supabaseId != null && supabaseId.isNotEmpty) ? supabaseId : 'local_$localId';
    return Knowledge(
      id: id,
      subjectId: row['subject_id'] as String?,
      subject: row['subject'] as String?,
      unit: row['unit'] as String?,
      content: row['content'] as String? ?? '',
      description: row['description'] as String?,
      type: row['type'] as String? ?? 'grammar',
      displayOrder: row['display_order'] as int?,
      construction: (row['construction'] == 1),
      tags: List<String>.from(tags)..sort(),
      authorComment: row['author_comment'] as String?,
    );
  }

  /// knowledge_card_tags(tag_id, knowledge_tags(name)) の embed 結果からタグ名を抽出
  static List<String> _parseTagsFromRow(Map<String, dynamic> row) {
    final raw = row['knowledge_card_tags'];
    if (raw is! List) {
      // 旧: 行内の tags カラム（JSONB/配列）の互換
      final legacy = row['tags'];
      if (legacy is List) {
        return legacy.map((e) => e.toString()).toList();
      }
      return [];
    }
    final names = <String>[];
    for (final e in raw) {
      if (e is! Map<String, dynamic>) continue;
      final tag = e['knowledge_tags'];
      if (tag is Map<String, dynamic>) {
        final name = tag['name']?.toString();
        if (name != null && name.isNotEmpty) names.add(name);
      }
    }
    return names..sort();
  }

  /// Supabase UPDATE 用のペイロード（編集フィールドのみ。タグは中間テーブルで別更新）
  static Map<String, dynamic> toUpdatePayload({
    required String title,
    required String explanation,
    required String? topic,
    required bool construction,
    required String? authorComment,
  }) {
    final topicTrimmed = topic?.trim();
    final commentTrimmed = authorComment?.trim();
    return {
      'content': title,
      'description': explanation.isEmpty ? null : explanation,
      'unit': (topicTrimmed == null || topicTrimmed.isEmpty) ? null : topicTrimmed,
      'construction': construction,
      'author_comment': (commentTrimmed == null || commentTrimmed.isEmpty) ? null : commentTrimmed,
    };
  }

  /// 知識カードのタグを中間テーブルに同期する（保存時に呼ぶ）
  /// マイグレーション未適用で knowledge_tags / knowledge_card_tags が無い場合は何もしない
  static Future<void> syncTags(
    SupabaseClient client,
    String knowledgeId,
    List<String> tagNames,
  ) async {
    try {
      final trimmed = tagNames.map((s) => s.trim()).where((s) => s.isNotEmpty).toSet().toList()..sort();
      await client.from('knowledge_card_tags').delete().eq('knowledge_id', knowledgeId);
      for (final name in trimmed) {
        final existing = await client.from('knowledge_tags').select('id').eq('name', name).maybeSingle();
        String tagId;
        if (existing != null && existing['id'] != null) {
          tagId = existing['id'] as String;
        } else {
          final inserted = await client.from('knowledge_tags').insert({'name': name}).select('id').single();
          tagId = inserted['id'] as String;
        }
        await client.from('knowledge_card_tags').insert({'knowledge_id': knowledgeId, 'tag_id': tagId});
      }
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('knowledge_card_tags') ||
          msg.contains('knowledge_tags') ||
          msg.contains('PGRST204') ||
          msg.contains('relation') ||
          msg.contains('does not exist')) {
        return;
      }
      rethrow;
    }
  }
}
