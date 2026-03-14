/// 四択問題の選択肢（question_choices テーブル対応）
class QuestionChoice {
  final String id;
  final String questionId;
  final int position;   // 1〜4
  final String choiceText;
  final bool isCorrect;

  QuestionChoice({
    required this.id,
    required this.questionId,
    required this.position,
    required this.choiceText,
    required this.isCorrect,
  });

  factory QuestionChoice.fromSupabase(Map<String, dynamic> row) {
    return QuestionChoice(
      id: row['id'] as String,
      questionId: row['question_id'] as String,
      position: row['position'] as int,
      choiceText: row['choice_text'] as String? ?? '',
      isCorrect: row['is_correct'] as bool? ?? false,
    );
  }

  static Map<String, dynamic> toPayload({
    required String questionId,
    required int position,
    required String choiceText,
    required bool isCorrect,
  }) {
    return {
      'question_id': questionId,
      'position': position,
      'choice_text': choiceText,
      'is_correct': isCorrect,
    };
  }
}
