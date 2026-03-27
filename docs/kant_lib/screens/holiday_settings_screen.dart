import 'package:flutter/material.dart';
import 'package:table_calendar/table_calendar.dart';
import '../services/app_settings_service.dart';
import '../services/calendar_service.dart';
import 'package:holiday_jp/holiday_jp.dart' as holiday_jp;

class HolidaySettingsScreen extends StatefulWidget {
  /// 遷移元(カレンダー等)で「表示中の月」を引き継ぐための初期フォーカス日。
  /// null の場合は現在日(DateTime.now)を使用。
  final DateTime? initialFocusedDay;

  const HolidaySettingsScreen({super.key, this.initialFocusedDay});

  @override
  State<HolidaySettingsScreen> createState() => _HolidaySettingsScreenState();
}

class _HolidaySettingsScreenState extends State<HolidaySettingsScreen> {
  late DateTime _focusedDay;
  DateTime? _selectedDay;

  // key: yyyy-mm-dd, value: isHoliday (customized entries only)
  final Map<String, bool> _customHolidayMap = {};
  bool _loading = false;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialFocusedDay ?? DateTime.now();
    // TableCalendar の focusedDay は日付でも動くが、月初に正規化しておくと
    // 「見ていた月」を確実に初期表示できる。
    _focusedDay = DateTime(initial.year, initial.month, 1);
    // 初期ロードが完了するまでカレンダー自体を表示しない（ちらつき防止）
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _loadMonth(_focusedDay);
      if (mounted) setState(() => _initialized = true);
    });
  }

  String _keyOf(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _loadMonth(DateTime month) async {
    setState(() => _loading = true);
    final start = DateTime(month.year, month.month, 1);
    final end = DateTime(month.year, month.month + 1, 0);
    try {
      _customHolidayMap.clear();
      final entries =
          await CalendarService.getCalendarEntriesForPeriod(start, end);
      for (final e in entries) {
        _customHolidayMap[_keyOf(e.date)] = e.isHoliday;
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool _computeIsHoliday(DateTime day) {
    final key = _keyOf(day);
    if (_customHolidayMap.containsKey(key)) {
      return _customHolidayMap[key] ?? false;
    }
    // default: weekend or holiday_jp
    if (day.weekday == DateTime.saturday || day.weekday == DateTime.sunday) {
      return true;
    }
    return holiday_jp.isHoliday(day);
  }

  Future<void> _toggleDay(DateTime day) async {
    final current = _computeIsHoliday(day);
    await CalendarService.customizeHoliday(day, !current);
    setState(() {
      _customHolidayMap[_keyOf(day)] = !current;
      _selectedDay = day;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('休日設定'),
      ),
      body: Column(
        children: [
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Container(
                    width: 14,
                    height: 14,
                    color: Theme.of(context)
                        .colorScheme
                        .error
                        .withOpacity( 0.08)),
                const SizedBox(width: 6),
                const Text('休日'),
                const SizedBox(width: 16),
                Container(
                    width: 14,
                    height: 14,
                    color: Theme.of(context).colorScheme.surface,
                    foregroundDecoration: BoxDecoration(
                        border:
                            Border.all(color: Theme.of(context).dividerColor))),
                const SizedBox(width: 6),
                const Text('平日'),
                const Spacer(),
                const Text('日付をタップで切替')
              ],
            ),
          ),
          if (!_initialized)
            const Expanded(
              child: Center(child: CircularProgressIndicator()),
            )
          else
            Expanded(
              child: TableCalendar(
                firstDay: DateTime(2020, 1, 1),
                lastDay: DateTime(2030, 12, 31),
                focusedDay: _focusedDay,
                calendarFormat: CalendarFormat.month,
                startingDayOfWeek: _mapWeekStart(AppSettingsService.weekStartNotifier.value),
                selectedDayPredicate: (day) =>
                    _selectedDay != null && isSameDay(_selectedDay, day),
                onDaySelected: (selectedDay, focusedDay) async {
                  await _toggleDay(selectedDay);
                  setState(() {
                    _focusedDay = focusedDay;
                  });
                },
                onPageChanged: (focusedDay) async {
                  _focusedDay = focusedDay;
                  await _loadMonth(_focusedDay);
                },
                calendarBuilders: CalendarBuilders(
                  defaultBuilder: (context, day, focusedDay) {
                    final isHol = _computeIsHoliday(day);
                    return _dayCell(day, isHol);
                  },
                  outsideBuilder: (context, day, focusedDay) {
                    final isHol = _computeIsHoliday(day);
                    return Opacity(
                      opacity: 0.6,
                      child: _dayCell(day, isHol),
                    );
                  },
                  todayBuilder: (context, day, focusedDay) {
                    final isHol = _computeIsHoliday(day);
                    return Container(
                      decoration: BoxDecoration(
                        color: isHol
                            ? Theme.of(context)
                                .colorScheme
                                .error
                                .withOpacity( 0.08)
                            : Theme.of(context).colorScheme.surface,
                        border: Border.all(
                            color: Theme.of(context).colorScheme.primary,
                            width: 1.2),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      alignment: Alignment.center,
                      child: Text('${day.day}',
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                    );
                  },
                  selectedBuilder: (context, day, focusedDay) {
                    final isHol = _computeIsHoliday(day);
                    return Container(
                      decoration: BoxDecoration(
                        color: isHol
                            ? Theme.of(context)
                                .colorScheme
                                .error
                                .withOpacity( 0.08)
                            : Theme.of(context).colorScheme.surface,
                        border: Border.all(
                            color: Theme.of(context).dividerColor, width: 1.0),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      alignment: Alignment.center,
                      child: Text('${day.day}',
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                    );
                  },
                ),
                calendarStyle: CalendarStyle(
                  outsideDaysVisible: true,
                  defaultDecoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                  ),
                  todayDecoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                  ),
                  selectedDecoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                headerStyle: const HeaderStyle(
                  formatButtonVisible: false,
                  titleCentered: true,
                ),
              ),
            ),
        ],
      ),
    );
  }

  StartingDayOfWeek _mapWeekStart(String key) {
    switch (key) {
      case 'monday':
        return StartingDayOfWeek.monday;
      case 'tuesday':
        return StartingDayOfWeek.tuesday;
      case 'wednesday':
        return StartingDayOfWeek.wednesday;
      case 'thursday':
        return StartingDayOfWeek.thursday;
      case 'friday':
        return StartingDayOfWeek.friday;
      case 'saturday':
        return StartingDayOfWeek.saturday;
      case 'sunday':
      default:
        return StartingDayOfWeek.sunday;
    }
  }

  Widget _dayCell(DateTime day, bool isHoliday) {
    return Container(
      decoration: BoxDecoration(
        color: isHoliday
            ? Theme.of(context).colorScheme.error.withOpacity( 0.08)
            : Theme.of(context).colorScheme.surface,
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(6),
      ),
      alignment: Alignment.center,
      child: Text('${day.day}'),
    );
  }
}
