/// 四択問題（questions）の執筆・レビュー状態。Supabase `dev_review_status` と対応。
enum QuestionDevReviewStatus {
  /// 未着手・枠のみ
  blank,

  /// 内容あり・確認待ち（旧 dev_completed=false に相当）
  pending,

  /// 確認済み・完了（旧 dev_completed=true に相当。UI 表記は「完了」）
  completed;

  static QuestionDevReviewStatus fromRemote(
    Object? devReviewStatus,
    Object? devCompletedLegacy,
  ) {
    final s = devReviewStatus?.toString();
    if (s == 'blank') return QuestionDevReviewStatus.blank;
    if (s == 'pending') return QuestionDevReviewStatus.pending;
    if (s == 'completed') return QuestionDevReviewStatus.completed;
    final done = devCompletedLegacy == true || devCompletedLegacy == 1;
    return done ? QuestionDevReviewStatus.completed : QuestionDevReviewStatus.pending;
  }

  /// API / DB 用（public.questions.dev_review_status）
  String get apiValue => switch (this) {
        QuestionDevReviewStatus.blank => 'blank',
        QuestionDevReviewStatus.pending => 'pending',
        QuestionDevReviewStatus.completed => 'completed',
      };

  bool get devCompletedBool => this == QuestionDevReviewStatus.completed;
}
