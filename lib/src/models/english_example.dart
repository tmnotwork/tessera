/// Supabase `english_examples` 1行に対応（知識と 1:1）
class EnglishExample {
  EnglishExample({
    required this.id,
    required this.knowledgeId,
    required this.frontJa,
    required this.backEn,
    this.explanation,
    this.supplement,
  });

  final String id;
  final String knowledgeId;
  final String frontJa;
  final String backEn;
  final String? explanation;
  final String? supplement;

  factory EnglishExample.fromRow(Map<String, dynamic> row) {
    return EnglishExample(
      id: row['id'] as String,
      knowledgeId: row['knowledge_id'] as String,
      frontJa: row['front_ja'] as String? ?? '',
      backEn: row['back_en'] as String? ?? '',
      explanation: row['explanation'] as String?,
      supplement: row['supplement'] as String?,
    );
  }
}
