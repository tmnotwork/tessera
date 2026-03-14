/// 1件の question（問題）の型
class Question {
  final String id;
  final String title;
  final String question;
  final String answer;
  final String? explanation;
  final String? supplement;
  final String questionLang;
  final String answerLang;
  final List<String> knowledgeIds;
  final int? order;
  /// タグ（例: 基本, TOEIC700点, GMARCH）- 何を目標にするか
  final List<String> tags;

  Question({
    required this.id,
    required this.title,
    required this.question,
    required this.answer,
    this.explanation,
    this.supplement,
    required this.questionLang,
    required this.answerLang,
    this.knowledgeIds = const [],
    this.order,
    this.tags = const [],
  });

  factory Question.fromJson(Map<String, dynamic> json) {
    final knowledgeIdsRaw = json['knowledge_ids'];
    final knowledgeIds = knowledgeIdsRaw is List
        ? (knowledgeIdsRaw).map((e) => e.toString()).toList()
        : <String>[];
    final tagsRaw = json['tags'];
    List<String> tagList = const [];
    if (tagsRaw is List) {
      tagList = tagsRaw.map((e) => e.toString()).toList();
    } else if ((json['basic'] as bool?) == true) {
      tagList = ['基本'];
    }
    return Question(
      id: json['id'] as String,
      title: json['title'] as String? ?? '',
      question: json['question'] as String,
      answer: json['answer'] as String,
      explanation: json['explanation'] as String?,
      supplement: json['supplement'] as String?,
      questionLang: json['question_lang'] as String? ?? 'ja',
      answerLang: json['answer_lang'] as String? ?? 'en',
      knowledgeIds: knowledgeIds,
      order: (json['order'] as num?)?.toInt(),
      tags: tagList,
    );
  }
}
