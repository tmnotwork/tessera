/// 英語例文 読み上げ「復習モード」の対象判定。
///
/// 含める例:
/// - 未学習（状態なし）
/// - 不正解系（last_quality 0 / 1）
/// - 正解（3 / 4）だが [next_review_at] がリストの「今日」フィルタと同じ基準で締切以内
class EnglishExampleReviewFilter {
  EnglishExampleReviewFilter._();

  /// 「今日までに復習」と同じ終端（翌日 0 時より前）
  static DateTime get _todayEnd => DateTime.now().add(const Duration(days: 1));

  static bool needsReview(Map<String, dynamic>? state) {
    if (state == null) return true;

    final lastQ = state['last_quality'] as int?;
    if (lastQ == null) return true;
    if (lastQ == 0 || lastQ == 1) return true;

    if (lastQ == 3 || lastQ == 4) {
      final nextStr = state['next_review_at'] as String?;
      if (nextStr == null) return true;
      final next = DateTime.tryParse(nextStr);
      if (next == null) return true;
      return next.isBefore(_todayEnd);
    }

    return true;
  }
}
