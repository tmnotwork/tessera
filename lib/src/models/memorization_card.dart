/// 暗記カード（表・裏の2面で丸暗記する用）
///
/// 知識カード = 解説メイン / 暗記カード = 表・裏のコンテンツで暗記
/// Supabase の memorization_cards テーブルに対応
/// タグは中間テーブル memorization_card_tags + memorization_tags で多対多
class MemorizationCard {
  final String id;
  final String? subjectId;
  final String? knowledgeId;  // 紐づく知識カード（任意）
  final String? unit;         // セクション表示用（例: 仮定法）
  final String frontContent;  // 表のコンテンツ
  final String? backContent;  // 裏のコンテンツ
  final List<String> tags;   // タグ（中間DB経由）
  final int? displayOrder;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  MemorizationCard({
    required this.id,
    this.subjectId,
    this.knowledgeId,
    this.unit,
    required this.frontContent,
    this.backContent,
    this.tags = const [],
    this.displayOrder,
    this.createdAt,
    this.updatedAt,
  });

  /// 単一行（JOIN なし）用
  factory MemorizationCard.fromSupabase(Map<String, dynamic> row) {
    return MemorizationCard(
      id: row['id'] as String,
      subjectId: row['subject_id'] as String?,
      knowledgeId: row['knowledge_id'] as String?,
      unit: row['unit'] as String?,
      frontContent: row['front_content'] as String? ?? '',
      backContent: row['back_content'] as String?,
      tags: _parseTagsFromRow(row),
      displayOrder: row['display_order'] as int?,
      createdAt: row['created_at'] != null ? DateTime.tryParse(row['created_at'].toString()) : null,
      updatedAt: row['updated_at'] != null ? DateTime.tryParse(row['updated_at'].toString()) : null,
    );
  }

  /// memorization_card_tags(tag_id, memorization_tags(name)) の embed 結果からタグ名を抽出
  static List<String> _parseTagsFromRow(Map<String, dynamic> row) {
    final raw = row['memorization_card_tags'];
    if (raw is! List) return [];
    final names = <String>[];
    for (final e in raw) {
      if (e is! Map<String, dynamic>) continue;
      final tag = e['memorization_tags'];
      if (tag is Map<String, dynamic>) {
        final name = tag['name']?.toString();
        if (name != null && name.isNotEmpty) names.add(name);
      }
    }
    return names..sort();
  }

  /// Supabase INSERT/UPDATE 用ペイロード（カード本体のみ。タグは中間テーブル memorization_card_tags で別更新）
  static Map<String, dynamic> toPayload({
    required String? subjectId,
    String? knowledgeId,
    String? unit,
    required String frontContent,
    String? backContent,
    int? displayOrder,
  }) {
    return {
      if (subjectId != null) 'subject_id': subjectId,
      'knowledge_id': knowledgeId,
      'unit': unit?.trim().isEmpty == true ? null : unit,
      'front_content': frontContent,
      'back_content': backContent?.trim().isEmpty == true ? null : backContent,
      'display_order': displayOrder,
    };
  }
}
