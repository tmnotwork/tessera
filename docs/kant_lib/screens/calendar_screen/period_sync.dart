import '../../widgets/calendar_settings.dart';
import '../../services/calendar_service.dart';
import 'helpers.dart' as helpers;

class PeriodRange {
  final DateTime start;
  final DateTime end;

  PeriodRange({required this.start, required this.end});
}

class PeriodSyncPlan {
  final String periodKey;
  final Future<void> syncFuture;

  PeriodSyncPlan({
    required this.periodKey,
    required this.syncFuture,
  });
}

PeriodSyncPlan buildPeriodSyncPlan({
  required CalendarViewType viewType,
  required DateTime focusedDate,
  DateTime? selectedDate,
}) {
  switch (viewType) {
    case CalendarViewType.day:
      if (selectedDate != null) {
        final key = 'day_${selectedDate.year}-${selectedDate.month}-${selectedDate.day}';
        return PeriodSyncPlan(
          periodKey: key,
          syncFuture: CalendarService.syncCalendarEntryForDate(selectedDate),
        );
      } else {
        final key = 'day_${focusedDate.year}-${focusedDate.month}-${focusedDate.day}';
        return PeriodSyncPlan(
          periodKey: key,
          syncFuture: CalendarService.syncCalendarEntryForDate(focusedDate),
        );
      }
    case CalendarViewType.week:
      final week = helpers.getWeekOfYear(focusedDate);
      return PeriodSyncPlan(
        periodKey: 'week_${focusedDate.year}-$week',
        syncFuture: CalendarService.syncCalendarEntriesForWeek(focusedDate),
      );
    case CalendarViewType.month:
      return PeriodSyncPlan(
        periodKey: 'month_${focusedDate.year}-${focusedDate.month}',
        syncFuture: CalendarService.syncCalendarEntriesForMonth(focusedDate),
      );
    case CalendarViewType.year:
      return PeriodSyncPlan(
        periodKey: 'year_${focusedDate.year}',
        syncFuture: CalendarService.syncCalendarEntriesForYear(focusedDate.year),
      );
  }
}

PeriodRange computePeriodRange({
  required CalendarViewType viewType,
  required DateTime focusedDate,
  DateTime? selectedDate,
}) {
  switch (viewType) {
    case CalendarViewType.day:
      final d = selectedDate ?? focusedDate;
      final start = DateTime(d.year, d.month, d.day);
      final end = start.add(const Duration(days: 1));
      return PeriodRange(start: start, end: end);
    case CalendarViewType.week:
      final startOfWeek = focusedDate.subtract(Duration(days: focusedDate.weekday - 1));
      final start = DateTime(startOfWeek.year, startOfWeek.month, startOfWeek.day);
      final endOfWeek = start.add(const Duration(days: 6));
      final end = DateTime(endOfWeek.year, endOfWeek.month, endOfWeek.day)
          .add(const Duration(days: 1));
      return PeriodRange(start: start, end: end);
    case CalendarViewType.month:
      final start = DateTime(focusedDate.year, focusedDate.month, 1);
      final lastDay = DateTime(focusedDate.year, focusedDate.month + 1, 0);
      final end = DateTime(lastDay.year, lastDay.month, lastDay.day)
          .add(const Duration(days: 1));
      return PeriodRange(start: start, end: end);
    case CalendarViewType.year:
      final start = DateTime(focusedDate.year, 1, 1);
      final end = DateTime(focusedDate.year, 12, 31).add(const Duration(days: 1));
      return PeriodRange(start: start, end: end);
  }
}

/// 表示期間に含まれる日付のリストを返す（差分同期で version 確認する対象日）。
List<DateTime> computePeriodDates({
  required CalendarViewType viewType,
  required DateTime focusedDate,
  DateTime? selectedDate,
}) {
  final range = computePeriodRange(
    viewType: viewType,
    focusedDate: focusedDate,
    selectedDate: selectedDate,
  );
  final dates = <DateTime>[];
  var cursor = DateTime(range.start.year, range.start.month, range.start.day);
  final endExclusive = DateTime(
    range.end.year,
    range.end.month,
    range.end.day,
  );
  while (cursor.isBefore(endExclusive)) {
    dates.add(cursor);
    cursor = cursor.add(const Duration(days: 1));
  }
  return dates;
}

