/// Supabase の knowledge テーブルに対応するモデル
///
/// カラムマッピング:
///   content       = 知識のタイトル（旧 title）
///   description   = 詳細説明（旧 explanation）
///   unit          = チャプター区切り（旧 topic）
///   display_order = 並び順（旧 order）
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
  final List<String> tags;
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
    final tagsRaw = row['tags'];
    List<String> tagList = const [];
    if (tagsRaw is List) {
      tagList = tagsRaw.map((e) => e.toString()).toList();
    }
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
      tags: tagList,
      authorComment: row['author_comment'] as String?,
    );
  }

  /// Supabase UPDATE 用のペイロード（編集フィールドのみ）
  static Map<String, dynamic> toUpdatePayload({
    required String title,
    required String explanation,
    required String? topic,
    required bool construction,
    required List<String> tags,
    required String? authorComment,
  }) {
    final topicTrimmed = topic?.trim();
    final commentTrimmed = authorComment?.trim();
    return {
      'content': title,
      'description': explanation.isEmpty ? null : explanation,
      'unit': (topicTrimmed == null || topicTrimmed.isEmpty) ? null : topicTrimmed,
      'construction': construction,
      'tags': tags,
      'author_comment': (commentTrimmed == null || commentTrimmed.isEmpty) ? null : commentTrimmed,
    };
  }
}
