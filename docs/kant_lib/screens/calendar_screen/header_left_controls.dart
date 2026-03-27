import 'package:flutter/material.dart';

import '../../widgets/calendar_settings.dart';

class CalendarHeaderLeftControls extends StatelessWidget {
  final CalendarViewType viewType;
  final DateTime focusedDate;
  final bool useDualLaneDayView;
  final ValueChanged<bool> onDualLaneChanged;
  final bool showEventsOnly;
  final ValueChanged<bool> onShowEventsOnlyChanged;
  final Future<void> Function() onPrevPeriod;
  final Future<void> Function() onNextPeriod;

  const CalendarHeaderLeftControls({
    super.key,
    required this.viewType,
    required this.focusedDate,
    required this.useDualLaneDayView,
    required this.onDualLaneChanged,
    required this.showEventsOnly,
    required this.onShowEventsOnlyChanged,
    required this.onPrevPeriod,
    required this.onNextPeriod,
  });

  @override
  Widget build(BuildContext context) {
    final bool isDayView = viewType == CalendarViewType.day;
    final bool isWeekView = viewType == CalendarViewType.week;
    final bool isDesktop = MediaQuery.of(context).size.width >= 900;

    final title = _buildTitle();
    final titleStyle = Theme.of(context).textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w700,
          fontSize: 18,
        ) ??
        const TextStyle(fontSize: 18, fontWeight: FontWeight.w700);

    final navigation = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: _buildPrevTooltip(),
          icon: const Icon(Icons.chevron_left),
          onPressed: () => onPrevPeriod(),
        ),
        Text(title, style: titleStyle),
        IconButton(
          tooltip: _buildNextTooltip(),
          icon: const Icon(Icons.chevron_right),
          onPressed: () => onNextPeriod(),
        ),
      ],
    );

    final children = <Widget>[
      navigation,
    ];

    if (isDayView && isDesktop) {
      children.add(const SizedBox(width: 16));
      children.add(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('予実2列', style: TextStyle(fontSize: 12)),
            Switch(
              value: useDualLaneDayView,
              onChanged: onDualLaneChanged,
            ),
          ],
        ),
      );
    }

    if (isWeekView && isDesktop) {
      children.add(const SizedBox(width: 16));
      children.add(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('イベントのみ表示', style: TextStyle(fontSize: 12)),
            Switch(
              value: showEventsOnly,
              onChanged: onShowEventsOnlyChanged,
            ),
          ],
        ),
      );
    }

    return Wrap(
      spacing: 16,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: children,
    );
  }

  String _buildPrevTooltip() {
    switch (viewType) {
      case CalendarViewType.day:
        return '前の日';
      case CalendarViewType.week:
        return '前の週';
      case CalendarViewType.month:
        return '前の月';
      case CalendarViewType.year:
        return '前の年';
    }
  }

  String _buildNextTooltip() {
    switch (viewType) {
      case CalendarViewType.day:
        return '次の日';
      case CalendarViewType.week:
        return '次の週';
      case CalendarViewType.month:
        return '次の月';
      case CalendarViewType.year:
        return '次の年';
    }
  }

  String _buildTitle() {
    switch (viewType) {
      case CalendarViewType.day:
        const weekdays = ['日', '月', '火', '水', '木', '金', '土'];
        final weekday = weekdays[focusedDate.weekday % 7];
        return '${focusedDate.year}年${focusedDate.month}月${focusedDate.day}日（$weekday）';
      case CalendarViewType.week:
        final first =
            focusedDate.subtract(Duration(days: focusedDate.weekday % 7));
        final last = first.add(const Duration(days: 6));
        return '${_formatMonthDay(first)} 〜 ${_formatMonthDay(last)}';
      case CalendarViewType.month:
        return '${focusedDate.year}年${focusedDate.month}月';
      case CalendarViewType.year:
        return '${focusedDate.year}年';
    }
  }

  static String _formatMonthDay(DateTime date) =>
      '${date.month}/${date.day}';
}

