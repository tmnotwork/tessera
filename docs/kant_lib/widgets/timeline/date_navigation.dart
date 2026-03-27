import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class DateNavigation extends StatelessWidget {
  final DateTime selectedDate;
  final Function(DateTime) onDateChanged;
  final bool showWeekStrip;

  const DateNavigation({
    super.key,
    required this.selectedDate,
    required this.onDateChanged,
    this.showWeekStrip = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0x00000000),
        border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: () {
              onDateChanged(selectedDate.subtract(const Duration(days: 1)));
            },
            tooltip: '前の日',
          ),
          Expanded(
            child: Center(
              child: showWeekStrip
                  ? _WeekStrip(
                      anchorDate: selectedDate,
                      onTapDay: onDateChanged,
                    )
                  : Text(
                      _formatDateWithWeekday(selectedDate),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                    ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: () {
              onDateChanged(selectedDate.add(const Duration(days: 1)));
            },
            tooltip: '次の日',
          ),
          IconButton(
            icon: const Icon(Icons.calendar_today),
            onPressed: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: selectedDate,
                firstDate: DateTime(2020),
                lastDate: DateTime(2030),
              );
              if (picked != null) {
                onDateChanged(picked);
              }
            },
            tooltip: '日付選択',
          ),
        ],
      ),
    );
  }

  String _formatDateWithWeekday(DateTime date) {
    try {
      final formatter = DateFormat('M月d日 (E)', 'ja_JP');
      return formatter.format(date);
    } catch (e) {
      // フォールバック: ロケールが初期化されていない場合
      final weekdays = ['月', '火', '水', '木', '金', '土', '日'];
      final weekday = weekdays[date.weekday - 1];
      return '${date.month}月${date.day}日 ($weekday)';
    }
  }
}

class _WeekStrip extends StatelessWidget {
  final DateTime anchorDate;
  final ValueChanged<DateTime> onTapDay;

  const _WeekStrip({
    required this.anchorDate,
    required this.onTapDay,
  });

  @override
  Widget build(BuildContext context) {
    final startOfWeek = anchorDate.subtract(Duration(days: anchorDate.weekday % 7));
    final days = List.generate(7, (i) => DateTime(startOfWeek.year, startOfWeek.month, startOfWeek.day + i));
    const weekdaySymbols = ['日', '月', '火', '水', '木', '金', '土'];
    final primary = Theme.of(context).colorScheme.primary;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (int i = 0; i < 7; i++)
          Expanded(
            child: InkWell(
              onTap: () => onTapDay(days[i]),
              borderRadius: BorderRadius.circular(16),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: _isSameYmd(days[i], anchorDate)
                          ? primary
                          : const Color(0x00000000),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      '${days[i].month}/${days[i].day} (${weekdaySymbols[i]})',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: _isSameYmd(days[i], anchorDate) ? Theme.of(context).colorScheme.onPrimary : Theme.of(context).textTheme.bodyLarge?.color,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  bool _isSameYmd(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }
}

// 旧Chip表示は廃止（2行表示へ）
