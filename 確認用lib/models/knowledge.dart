/// 1件の knowledge の型
class Knowledge {
  final String id;
  final String type;
  final String? topic;
  final int? order;
  final String title;
  final String explanation;
  /// Construction（文の形・パターン）について説明したカードかどうか
  final bool construction;
  /// タグ（例: 基本, TOEIC700点, GMARCH）- 何を目標にするか
  final List<String> tags;
  /// 執筆者用メモ（参考書には出さない）
  final String? authorComment;

  Knowledge({
    required this.id,
    required this.type,
    this.topic,
    this.order,
    required this.title,
    required this.explanation,
    this.construction = false,
    this.tags = const [],
    this.authorComment,
  });

  factory Knowledge.fromJson(Map<String, dynamic> json) {
    final tagsRaw = json['tags'];
    List<String> tagList = const [];
    if (tagsRaw is List) {
      tagList = tagsRaw.map((e) => e.toString()).toList();
    } else if ((json['basic'] as bool?) == true) {
      tagList = ['基本'];
    }
    final authorCommentRaw = json['author_comment'] ?? json['authorComment'];
    final authorComment = authorCommentRaw is String ? authorCommentRaw : null;
    return Knowledge(
      id: json['id'] as String,
      type: json['type'] as String,
      topic: json['topic'] as String?,
      order: json['order'] as int?,
      title: json['title'] as String,
      explanation: json['explanation'] as String,
      construction: json['construction'] as bool? ?? json['syntax'] as bool? ?? false,
      tags: tagList,
      authorComment: authorComment,
    );
  }
}
