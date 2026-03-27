import '../../widgets/calendar_settings.dart';

CalendarViewType? parseViewType(String s) {
  switch (s) {
    case 'day':
      return CalendarViewType.day;
    case 'week':
      return CalendarViewType.week;
    case 'month':
      return CalendarViewType.month;
    case 'year':
      return CalendarViewType.year;
  }
  return null;
}

int getWeekOfYear(DateTime date) {
  final firstDayOfYear = DateTime(date.year, 1, 1);
  final daysSinceFirstDay = date.difference(firstDayOfYear).inDays;
  return (daysSinceFirstDay / 7).ceil();
}

