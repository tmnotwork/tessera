/// 1冊の参考書を表すモデル
class ReferenceBook {
  const ReferenceBook({
    required this.id,
    required this.name,
    this.group,
    required this.knowledgeFile,
    required this.questionsFile,
  });

  final String id;
  final String name;
  /// グルーピング用（例: "文法", "語彙"）。null の場合は「その他」などにまとめる
  final String? group;
  final String knowledgeFile;
  final String questionsFile;

  factory ReferenceBook.fromJson(Map<String, dynamic> json) {
    return ReferenceBook(
      id: json['id'] as String,
      name: json['name'] as String,
      group: json['group'] as String?,
      knowledgeFile: json['knowledge_file'] as String? ?? 'knowledge.json',
      questionsFile: json['questions_file'] as String? ?? 'questions.json',
    );
  }
}
