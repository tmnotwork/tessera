/// SM-2 アルゴリズムの計算ロジック
///
/// yomiage の ReviewModeScreen._updateSM2 を純粋な計算クラスとして移植。
/// quality の意味:
///   0 = 当日中（もう一度）
///   1 = 難しい
///   3 = 正解
///   4 = 簡単
class Sm2Calculator {
  /// SM-2 で次の状態を計算して返す。
  ///
  /// [repetitions]  連続正解回数
  /// [eFactor]      熟練度係数（初期値 2.5、下限 1.3）
  /// [intervalDays] 前回計算した間隔（日）
  /// [quality]      評価（0/1/3/4）
  static Sm2Result calculate({
    required int repetitions,
    required double eFactor,
    required int intervalDays,
    required int quality,
  }) {
    final now = DateTime.now();

    if (quality == 0) {
      // 当日中: リセットして今日に再出題
      return Sm2Result(
        repetitions: 0,
        eFactor: eFactor,
        intervalDays: 0,
        nextReviewAt: now,
      );
    }

    if (quality == 1) {
      // 難しい: eFactor を少し下げ、間隔を短縮（リセットはしない）
      double newEFactor = eFactor - 0.15;
      if (newEFactor < 1.3) newEFactor = 1.3;

      final int prevI = intervalDays > 0 ? intervalDays : 1;
      int newInterval;
      if (prevI >= 21) {
        newInterval = 7;
      } else {
        newInterval = (prevI * 0.5).round();
        if (newInterval < 3) newInterval = 3;
      }

      return Sm2Result(
        repetitions: repetitions, // 維持
        eFactor: newEFactor,
        intervalDays: newInterval,
        nextReviewAt: now.add(Duration(days: newInterval)),
      );
    }

    // quality >= 3（正解 or 簡単）
    final int newRep = repetitions + 1;

    int newInterval;
    if (newRep == 1) {
      newInterval = quality >= 4 ? 4 : 2;
    } else if (newRep == 2) {
      newInterval = quality >= 4 ? 8 : 6;
    } else {
      final double multiplier = quality >= 4 ? 1.5 : 1.0;
      newInterval = (intervalDays * eFactor * multiplier).round();
      if (newInterval <= 0) newInterval = 1;
    }

    double newEFactor =
        eFactor + (0.1 - (5 - quality) * (0.08 + (5 - quality) * 0.02));
    if (newEFactor < 1.3) newEFactor = 1.3;

    return Sm2Result(
      repetitions: newRep,
      eFactor: newEFactor,
      intervalDays: newInterval,
      nextReviewAt: now.add(Duration(days: newInterval)),
    );
  }

  /// 評価を押した場合の「次回まで何日後か」のプレビューを返す。
  static int daysUntilNextReview({
    required int repetitions,
    required double eFactor,
    required int intervalDays,
    required int quality,
  }) {
    final result = calculate(
      repetitions: repetitions,
      eFactor: eFactor,
      intervalDays: intervalDays,
      quality: quality,
    );
    return result.intervalDays;
  }
}

/// SM-2 計算結果
class Sm2Result {
  const Sm2Result({
    required this.repetitions,
    required this.eFactor,
    required this.intervalDays,
    required this.nextReviewAt,
  });

  final int repetitions;
  final double eFactor;
  final int intervalDays;
  final DateTime nextReviewAt;

  Map<String, dynamic> toSupabaseFields() => {
        'repetitions': repetitions,
        'e_factor': eFactor,
        'interval_days': intervalDays,
        'next_review_at': nextReviewAt.toUtc().toIso8601String(),
      };
}
