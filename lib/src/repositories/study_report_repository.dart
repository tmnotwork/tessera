import 'package:sqflite/sqflite.dart';

/// SQLite の study_sessions テーブルから日/週/月/年の集計を返すユーティリティ。
/// 「予定」は持たないため実績のみを集計する。
class StudyReportRepository {
  const StudyReportRepository._();

  static DateTime _dateOnly(DateTime dt) {
    final d = dt.toLocal();
    return DateTime(d.year, d.month, d.day);
  }

  // ─── 日次 ───────────────────────────────────────────────────────────────

  /// [date] の session_type 別秒数マップを返す。
  static Future<Map<String, int>> loadDailySummary(
    Database db,
    DateTime date,
  ) async {
    final day = _dateOnly(date);
    final nextDay = day.add(const Duration(days: 1));
    final rows = await db.rawQuery(
      '''
      SELECT session_type, SUM(duration_sec) AS total
      FROM study_sessions
      WHERE ended_at IS NOT NULL
        AND TRIM(COALESCE(ended_at, '')) != ''
        AND ended_at >= ?
        AND ended_at < ?
        AND deleted = 0
      GROUP BY session_type
      ''',
      [
        day.toUtc().toIso8601String(),
        nextDay.toUtc().toIso8601String(),
      ],
    );
    final result = <String, int>{};
    for (final r in rows) {
      final t = r['session_type']?.toString() ?? 'other';
      final total = (r['total'] as int?) ?? 0;
      if (total > 0) result[t] = total;
    }
    return result;
  }

  // ─── 週次 ───────────────────────────────────────────────────────────────

  /// [weekStart] から [days] 日間の、日別 × session_type 別秒数マップを返す。
  /// 戻り値のキーは date-only（ローカル時刻）の DateTime。
  static Future<Map<DateTime, Map<String, int>>> loadWeeklySummary(
    Database db,
    DateTime weekStart,
    int days,
  ) async {
    final start = _dateOnly(weekStart);
    final end = start.add(Duration(days: days));
    final rows = await db.rawQuery(
      '''
      SELECT session_type, duration_sec, ended_at
      FROM study_sessions
      WHERE ended_at IS NOT NULL
        AND TRIM(COALESCE(ended_at, '')) != ''
        AND ended_at >= ?
        AND ended_at < ?
        AND deleted = 0
        AND duration_sec > 0
      ''',
      [
        start.toUtc().toIso8601String(),
        end.toUtc().toIso8601String(),
      ],
    );

    // 全日付を初期化
    final result = <DateTime, Map<String, int>>{};
    for (int i = 0; i < days; i++) {
      result[start.add(Duration(days: i))] = {};
    }

    for (final r in rows) {
      final endedRaw = r['ended_at']?.toString();
      if (endedRaw == null || endedRaw.isEmpty) continue;
      final ended = DateTime.tryParse(endedRaw)?.toLocal();
      if (ended == null) continue;
      final day = DateTime(ended.year, ended.month, ended.day);
      if (!result.containsKey(day)) continue;
      final t = r['session_type']?.toString() ?? 'other';
      final sec = (r['duration_sec'] as int?) ?? 0;
      if (sec > 0) {
        result[day]![t] = (result[day]![t] ?? 0) + sec;
      }
    }
    return result;
  }

  // ─── 月次 ───────────────────────────────────────────────────────────────

  /// [monthStart] の月のウィーク別合計と session_type 別集計を返す。
  static Future<({
    List<({DateTime weekStart, int totalSec})> weekBuckets,
    Map<String, int> byType,
  })> loadMonthlySummary(Database db, DateTime monthStart) async {
    final start = DateTime(monthStart.year, monthStart.month, 1);
    final end = DateTime(start.year, start.month + 1, 1);
    final rows = await db.rawQuery(
      '''
      SELECT session_type, duration_sec, ended_at
      FROM study_sessions
      WHERE ended_at IS NOT NULL
        AND TRIM(COALESCE(ended_at, '')) != ''
        AND ended_at >= ?
        AND ended_at < ?
        AND deleted = 0
        AND duration_sec > 0
      ''',
      [
        start.toUtc().toIso8601String(),
        end.toUtc().toIso8601String(),
      ],
    );

    final weekMap = <DateTime, int>{};
    final byType = <String, int>{};

    for (final r in rows) {
      final endedRaw = r['ended_at']?.toString();
      if (endedRaw == null || endedRaw.isEmpty) continue;
      final ended = DateTime.tryParse(endedRaw)?.toLocal();
      if (ended == null) continue;
      final sec = (r['duration_sec'] as int?) ?? 0;
      if (sec <= 0) continue;
      final t = r['session_type']?.toString() ?? 'other';
      byType[t] = (byType[t] ?? 0) + sec;
      // 月曜始まりのウィーク開始日を計算
      final dayLocal = DateTime(ended.year, ended.month, ended.day);
      final delta = (dayLocal.weekday - DateTime.monday + 7) % 7;
      final ws = dayLocal.subtract(Duration(days: delta));
      weekMap[ws] = (weekMap[ws] ?? 0) + sec;
    }

    // 月内のすべてのウィーク開始日を列挙（月曜始まり）
    final allWeeks = <DateTime>{};
    var d = start;
    while (d.isBefore(end)) {
      final delta = (d.weekday - DateTime.monday + 7) % 7;
      allWeeks.add(d.subtract(Duration(days: delta)));
      d = d.add(const Duration(days: 7));
    }
    allWeeks.addAll(weekMap.keys);

    final sorted = allWeeks.toList()..sort();
    final weekBuckets = sorted
        .map((ws) => (weekStart: ws, totalSec: weekMap[ws] ?? 0))
        .toList();

    return (weekBuckets: weekBuckets, byType: byType);
  }

  // ─── 年次 ───────────────────────────────────────────────────────────────

  /// [yearStart] の年の月別合計秒数リスト（インデックス 0 = 1月）と
  /// session_type 別集計を返す。
  static Future<({List<int> monthlyTotals, Map<String, int> byType})>
      loadYearlySummary(Database db, DateTime yearStart) async {
    final start = DateTime(yearStart.year, 1, 1);
    final end = DateTime(start.year + 1, 1, 1);
    final rows = await db.rawQuery(
      '''
      SELECT session_type, duration_sec, ended_at
      FROM study_sessions
      WHERE ended_at IS NOT NULL
        AND TRIM(COALESCE(ended_at, '')) != ''
        AND ended_at >= ?
        AND ended_at < ?
        AND deleted = 0
        AND duration_sec > 0
      ''',
      [
        start.toUtc().toIso8601String(),
        end.toUtc().toIso8601String(),
      ],
    );

    final monthlyTotals = List<int>.filled(12, 0);
    final byType = <String, int>{};

    for (final r in rows) {
      final endedRaw = r['ended_at']?.toString();
      if (endedRaw == null || endedRaw.isEmpty) continue;
      final ended = DateTime.tryParse(endedRaw)?.toLocal();
      if (ended == null) continue;
      final sec = (r['duration_sec'] as int?) ?? 0;
      if (sec <= 0) continue;
      final monthIdx = ended.month - 1;
      if (monthIdx < 0 || monthIdx >= 12) continue;
      monthlyTotals[monthIdx] += sec;
      final t = r['session_type']?.toString() ?? 'other';
      byType[t] = (byType[t] ?? 0) + sec;
    }

    return (monthlyTotals: monthlyTotals, byType: byType);
  }
}
