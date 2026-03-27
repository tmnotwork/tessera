class CalendarScrollHelpers {
  static double computeDayInitialScrollY(
      {required double hourHeight, DateTime? now}) {
    final DateTime t = now ?? DateTime.now();
    return hourHeight * (t.hour + t.minute / 60.0);
  }

  static ({List<double> hourHeights, List<double> prefix, double totalHeight})
      computeWeekHourLayout({
    required List<List<({int start, int end, bool short})>> dayIntervals,
    double baseHourHeight = 88.0,
    double minBlockPixelHeight = 22.0,
  }) {
    final List<double> hourHeights = List<double>.generate(24, (h) {
      final int hrStart = h * 60;
      final int hrEnd = hrStart + 60;
      int maxConcurrency = 0;
      for (final intervals in dayIntervals) {
        // Build sweep-line events within this hour for current day
        final points = <({int t, int delta})>[];
        for (final it in intervals) {
          // intersect [it.start, it.end) with [hrStart, hrEnd)
          final s = it.start < hrStart ? hrStart : it.start;
          final e = it.end > hrEnd ? hrEnd : it.end;
          if (e <= s) continue;
          final s0 = s - hrStart; // 0..60
          final e0 = e - hrStart; // 0..60
          points.add((t: s0, delta: 1));
          points.add((t: e0, delta: -1));
        }
        if (points.isEmpty) continue;
        points.sort((a, b) => a.t == b.t ? a.delta.compareTo(b.delta) : a.t.compareTo(b.t));
        int active = 0;
        int localMax = 0;
        for (final p in points) {
          active += p.delta;
          if (active > localMax) localMax = active;
        }
        if (localMax > maxConcurrency) maxConcurrency = localMax;
      }
      if (maxConcurrency <= 0) return baseHourHeight;
      final required = maxConcurrency * minBlockPixelHeight;
      return required > baseHourHeight ? required : baseHourHeight;
    });
    final List<double> prefix = List<double>.generate(25, (i) => 0);
    for (int i = 1; i < 25; i++) {
      prefix[i] = prefix[i - 1] + hourHeights[i - 1];
    }
    final totalHeight = prefix[24];
    return (hourHeights: hourHeights, prefix: prefix, totalHeight: totalHeight);
  }

  /// Day view hour layout for mobile planned-only grid.
  ///
  /// - baseHourHeight: default compressed height per hour (e.g., 44.0)
  /// - rowUnitHeight: minimal vertical space per sequential, non-overlapping segment (e.g., 22.0)
  /// - hourSegments: for each hour 0..23, a list of segments within that hour in minutes [0,60)
  static ({List<double> hourHeights, List<double> prefix, double totalHeight})
      computeDayHourLayout({
    required List<List<({int start, int end})>> hourSegments,
    double baseHourHeight = 44.0,
    double rowUnitHeight = 22.0,
  }) {
    final List<double> hourHeights = List<double>.generate(24, (h) {
      final segs = hourSegments[h];
      if (segs.isEmpty) return baseHourHeight;

      // 1) 同時並行数（最大同時表示数）を計算
      final points = <({int t, int delta})>[];
      for (final s in segs) {
        final int s0 = s.start.clamp(0, 60);
        final int e0 = s.end.clamp(0, 60);
        if (e0 <= s0) continue;
        points.add((t: s0, delta: 1));
        points.add((t: e0, delta: -1));
      }
      points.sort((a, b) => a.t == b.t ? a.delta.compareTo(b.delta) : a.t.compareTo(b.t));
      int active = 0;
      int maxConcurrency = 0;
      for (final p in points) {
        active += p.delta;
        if (active > maxConcurrency) maxConcurrency = active;
      }
      if (maxConcurrency <= 0) maxConcurrency = 1;

      // 2) 必要な高さ：基準 + (同時行数に基づく確保)。単時間帯で足りない場合のみ行数分増やす。
      final double concurrencyRequired = maxConcurrency * rowUnitHeight;
      final double required = concurrencyRequired > baseHourHeight ? concurrencyRequired : baseHourHeight;
      return required;
    });

    final List<double> prefix = List<double>.generate(25, (i) => 0);
    for (int i = 1; i < 25; i++) {
      prefix[i] = prefix[i - 1] + hourHeights[i - 1];
    }
    final totalHeight = prefix[24];
    return (hourHeights: hourHeights, prefix: prefix, totalHeight: totalHeight);
  }
}
