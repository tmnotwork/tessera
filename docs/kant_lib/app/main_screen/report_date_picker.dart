import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:table_calendar/table_calendar.dart';
import 'report_period.dart';

class ReportDatePickerResult {
  final ReportPeriod period;
  final DateTime? baseDate; // daily, weekly, monthly, yearly は基準日; customは開始日のみ
  final DateTime? startDate; // custom の開始日（追加）
  final DateTime? endDate; // custom の終了日（追加）
  final bool switchToReportTab;
  const ReportDatePickerResult({
    required this.period,
    required this.baseDate,
    this.startDate,
    this.endDate,
    required this.switchToReportTab,
  });
}

Future<ReportDatePickerResult?> showDatePickerForPeriod({
  required BuildContext context,
  required ReportPeriod period,
  DateTime? currentStartDate,
  DateTime? currentEndDate,
  DateTime? currentBaseDate,
  ReportPeriod? currentPeriod,
  int? firstYear,
  int? lastYear,
}) async {
  final now = DateTime.now();
  final initialBase =
      (currentPeriod == period && currentBaseDate != null) ? currentBaseDate : now;
  int resolvedLastYear = lastYear ?? now.year;
  if (resolvedLastYear < 1) resolvedLastYear = now.year;
  int resolvedFirstYear = firstYear ?? 2020;
  if (resolvedFirstYear < 1) resolvedFirstYear = 1;
  if (resolvedFirstYear > resolvedLastYear) {
    resolvedFirstYear = resolvedLastYear;
  }

  // 先に期間選択ダイアログを閉じる（main.dart の既存挙動を踏襲）
  Navigator.of(context, rootNavigator: true).pop();
  await Future.delayed(const Duration(milliseconds: 10));

  switch (period) {
    case ReportPeriod.daily:
      {
        final picked = await _showSingleDatePickerDialogImmediate(
          context: context,
          initialDate: initialBase,
          firstDate: DateTime(2020),
          lastDate: DateTime(2030),
        );
        if (picked != null) {
          return ReportDatePickerResult(
            period: ReportPeriod.daily,
            baseDate: picked,
            switchToReportTab: true,
          );
        }
        return null;
      }
    case ReportPeriod.weekly:
      {
        final picked =
            await _showWeeklyPickerDialog(context: context, initialDate: initialBase);
        if (picked != null) {
          return ReportDatePickerResult(
            period: ReportPeriod.weekly,
            baseDate: picked,
            switchToReportTab: true,
          );
        }
        return null;
      }
    case ReportPeriod.monthly:
      {
        // 月次も日付カレンダーではなく、年月(yyyy/MM)を選択できるUIにする。
        // showDatePicker だと「日付」選択が必須になり、表示も日付寄りになってしまう。
        final picked = await _showMonthPickerDialog(
          context: context,
          initialDate: initialBase,
          firstYear: resolvedFirstYear,
          lastYear: resolvedLastYear,
        );
        if (picked != null) {
          return ReportDatePickerResult(
            period: ReportPeriod.monthly,
            // 月次は基準日を YYYY-MM-01 に正規化して扱う
            baseDate: DateTime(picked.year, picked.month, 1),
            switchToReportTab: true,
          );
        }
        return null;
      }
    case ReportPeriod.yearly:
      {
        // 年次は「日付カレンダー」ではなく、年そのものを選択できるUIにする。
        // showDatePicker だと年を選んでも日付選択が必須になり、意図とズレるため。
        final picked = await _showYearPickerDialog(
          context: context,
          initialDate: initialBase,
          firstYear: resolvedFirstYear,
          lastYear: resolvedLastYear,
        );
        if (picked != null) {
          return ReportDatePickerResult(
            period: ReportPeriod.yearly,
            // 年次は基準日を YYYY-01-01 に正規化して扱う（表示も集計も年単位）
            baseDate: DateTime(picked.year, 1, 1),
            switchToReportTab: true,
          );
        }
        return null;
      }
    case ReportPeriod.custom:
      {
        final range = await _showCustomRangePickerDialog(
          context: context,
          initialDate: now,
          firstDate: DateTime(2020),
          lastDate: DateTime(2030),
          initialStart: currentStartDate,
          initialEnd: currentEndDate,
        );
        if (range != null) {
          final start = DateTime(
            range.start.year,
            range.start.month,
            range.start.day,
          );
          final end = DateTime(
            range.end.year,
            range.end.month,
            range.end.day,
          );
          return ReportDatePickerResult(
            period: ReportPeriod.custom,
            baseDate: start,
            startDate: start,
            endDate: end,
            switchToReportTab: true,
          );
        }
        return null;
      }
  }
}

DateTime _dateOnly(DateTime dt) => DateTime(dt.year, dt.month, dt.day);

Future<DateTimeRange?> _showCustomRangePickerDialog({
  required BuildContext context,
  required DateTime initialDate,
  required DateTime firstDate,
  required DateTime lastDate,
  DateTime? initialStart,
  DateTime? initialEnd,
}) async {
  DateTime focused = _dateOnly(initialDate);
  DateTime? rangeStart =
      initialStart != null ? _dateOnly(initialStart) : null;
  DateTime? rangeEnd = initialEnd != null ? _dateOnly(initialEnd) : null;
  if (rangeStart != null) {
    focused = rangeEnd ?? rangeStart;
  }

  return showDialog<DateTimeRange>(
    context: context,
    useRootNavigator: true,
    builder: (ctx) {
      return AlertDialog(
        title: const Text('期間を選択'),
        content: StatefulBuilder(
          builder: (ctx, setLocal) {
            String rangeLabel;
            if (rangeStart == null) {
              rangeLabel = '開始日を選択';
            } else {
              final startStr = DateFormat('yyyy/MM/dd').format(rangeStart!);
              final endStr =
                  DateFormat('yyyy/MM/dd').format(rangeEnd ?? rangeStart!);
              rangeLabel = rangeEnd == null
                  ? '開始日: $startStr'
                  : '$startStr - $endStr';
            }
            final bool canSubmit = rangeStart != null;
            return SizedBox(
              width: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.event, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            rangeLabel,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  TableCalendar(
                    locale: 'ja_JP',
                    firstDay: firstDate,
                    lastDay: lastDate,
                    focusedDay: focused,
                    availableCalendarFormats: const {CalendarFormat.month: '月'},
                    calendarFormat: CalendarFormat.month,
                    selectedDayPredicate: (day) => false,
                    rangeSelectionMode: RangeSelectionMode.toggledOn,
                    rangeStartDay: rangeStart,
                    rangeEndDay: rangeEnd,
                    onRangeSelected: (start, end, foc) {
                      setLocal(() {
                        rangeStart = start != null ? _dateOnly(start) : null;
                        rangeEnd = end != null ? _dateOnly(end) : null;
                        focused = _dateOnly(foc);
                      });
                    },
                    onPageChanged: (foc) => setLocal(() => focused = foc),
                  ),
                  if (!canSubmit)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '開始日を選ぶと確定できます',
                          style: TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: rangeStart == null
                ? null
                : () {
                    final start = _dateOnly(rangeStart!);
                    final end = _dateOnly(rangeEnd ?? rangeStart!);
                    Navigator.pop(
                      ctx,
                      DateTimeRange(start: start, end: end),
                    );
                  },
            child: const Text('決定'),
          ),
        ],
      );
    },
  );
}

Future<DateTime?> _showSingleDatePickerDialogImmediate({
  required BuildContext context,
  required DateTime initialDate,
  required DateTime firstDate,
  required DateTime lastDate,
  String? title,
}) async {
  DateTime focused =
      DateTime(initialDate.year, initialDate.month, initialDate.day);
  DateTime selected = focused;

  return showDialog<DateTime>(
    context: context,
    useRootNavigator: true,
    builder: (ctx) {
      return AlertDialog(
        title: Text(title ?? '日付を選択'),
        content: StatefulBuilder(
          builder: (ctx, setLocal) {
            return SizedBox(
              width: 360,
              child: TableCalendar(
                locale: 'ja_JP',
                firstDay: firstDate,
                lastDay: lastDate,
                focusedDay: focused,
                availableCalendarFormats: const {CalendarFormat.month: '月'},
                calendarFormat: CalendarFormat.month,
                selectedDayPredicate: (day) => isSameDay(day, selected),
                onDaySelected: (sel, foc) {
                  final picked = DateTime(sel.year, sel.month, sel.day);
                  Navigator.pop(ctx, picked);
                },
                onPageChanged: (foc) => setLocal(() => focused = foc),
              ),
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('キャンセル'),
          ),
        ],
      );
    },
  );
}

Future<DateTime?> _showMonthPickerDialog({
  required BuildContext context,
  required DateTime initialDate,
  required int firstYear,
  required int lastYear,
}) async {
  final today = DateTime.now();
  final int initialYear = today.year.clamp(firstYear, lastYear) as int;
  final int initialMonth = initialDate.month.clamp(1, 12) as int;
  final int yearCount = lastYear - firstYear + 1;
  const double itemExtent = 44.0;
  const double pickerHeight = itemExtent * 5;
  const double pickerTitleAreaHeight = 32.0;
  int selectedYear = initialYear;
  int selectedMonth = initialMonth;
  final yearScroll = FixedExtentScrollController(
    initialItem: selectedYear - firstYear,
  );
  final monthScroll = FixedExtentScrollController(
    initialItem: selectedMonth - 1,
  );

  try {
    return await showDialog<DateTime>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            Widget buildWheelPicker({
              required String title,
              required int itemCount,
              required FixedExtentScrollController controller,
              required bool Function(int index) isSelected,
              required String Function(int index) labelFor,
              required void Function(int index) onSelectedItemChanged,
            }) {
              return Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.labelLarge,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Container(
                      height: pickerHeight,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                      ),
                      child: Stack(
                        children: [
                          ListWheelScrollView.useDelegate(
                            controller: controller,
                            physics: const FixedExtentScrollPhysics(),
                            itemExtent: itemExtent,
                            diameterRatio: 1.45,
                            squeeze: 1.0,
                            onSelectedItemChanged: onSelectedItemChanged,
                            childDelegate: ListWheelChildBuilderDelegate(
                              childCount: itemCount,
                              builder: (context, index) {
                                if (index == null ||
                                    index < 0 ||
                                    index >= itemCount) {
                                  return null;
                                }
                                final selected = isSelected(index);
                                final scheme = Theme.of(context).colorScheme;
                                return Center(
                                  child: Text(
                                    labelFor(index),
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(
                                          fontWeight: selected
                                              ? FontWeight.w700
                                              : FontWeight.w400,
                                          color: selected
                                              ? scheme.onSurface
                                              : scheme.onSurfaceVariant,
                                        ),
                                  ),
                                );
                              },
                            ),
                          ),
                          IgnorePointer(
                            child: Center(
                              child: Container(
                                height: itemExtent,
                                decoration: BoxDecoration(
                                  border: Border.symmetric(
                                    horizontal: BorderSide(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .outlineVariant,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            }

            return AlertDialog(
              title: const Text('年月を選択'),
              content: SizedBox(
                width: 420,
                // ダイアログが縦方向に過剰伸長しないよう高さを固定する。
                // これにより「決定」ボタンがピッカーの直下に配置される。
                height: pickerHeight + pickerTitleAreaHeight,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    buildWheelPicker(
                      title: '年',
                      itemCount: yearCount,
                      controller: yearScroll,
                      isSelected: (index) => firstYear + index == selectedYear,
                      labelFor: (index) => '${firstYear + index}年',
                      onSelectedItemChanged: (index) =>
                          setLocal(() => selectedYear = firstYear + index),
                    ),
                    const SizedBox(width: 12),
                    buildWheelPicker(
                      title: '月',
                      itemCount: 12,
                      controller: monthScroll,
                      isSelected: (index) => index + 1 == selectedMonth,
                      labelFor: (index) => '${index + 1}月',
                      onSelectedItemChanged: (index) =>
                          setLocal(() => selectedMonth = index + 1),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('キャンセル'),
                ),
                ElevatedButton(
                  onPressed: () =>
                      Navigator.pop(ctx, DateTime(selectedYear, selectedMonth, 1)),
                  child: const Text('決定'),
                ),
              ],
            );
          },
        );
      },
    );
  } finally {
    yearScroll.dispose();
    monthScroll.dispose();
  }
}

Future<DateTime?> _showYearPickerDialog({
  required BuildContext context,
  required DateTime initialDate,
  required int firstYear,
  required int lastYear,
}) async {
  final initYear = initialDate.year.clamp(firstYear, lastYear) as int;
  final selected = DateTime(initYear, 1, 1);
  final years = List<int>.generate(lastYear - firstYear + 1, (i) => firstYear + i);
  final initialIndex = (initYear - firstYear).clamp(0, years.length - 1);
  // ListTile の標準高さに近い値で初期スクロール位置を合わせる
  final scroll = ScrollController(initialScrollOffset: initialIndex * 56.0);

  try {
    return await showDialog<DateTime>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('年を選択'),
          content: SizedBox(
            width: 320,
            height: 360,
            child: Scrollbar(
              thumbVisibility: true,
              controller: scroll,
              child: ListView.builder(
                controller: scroll,
                itemCount: years.length,
                itemBuilder: (context, index) {
                  final y = years[index];
                  final isSelected = y == selected.year;
                  return ListTile(
                    dense: true,
                    title: Text('$y年'),
                    trailing: isSelected ? const Icon(Icons.check) : null,
                    onTap: () => Navigator.pop(ctx, DateTime(y, 1, 1)),
                  );
                },
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('キャンセル'),
            ),
          ],
        );
      },
    );
  } finally {
    scroll.dispose();
  }
}

Future<DateTime?> _showWeeklyPickerDialog({
  required BuildContext context,
  required DateTime initialDate,
}) async {
  DateTime focused =
      DateTime(initialDate.year, initialDate.month, initialDate.day);
  DateTime selected = focused; // 初期表示で選択日を末日とする帯を表示

  return showDialog<DateTime>(
    context: context,
    builder: (ctx) {
      return AlertDialog(
        title: const Text('週の基準日を選択'),
        content: StatefulBuilder(
          builder: (ctx, setLocal) {
            final endBase = selected.toLocal();
            final end = DateTime(endBase.year, endBase.month, endBase.day);
            final start = end.subtract(const Duration(days: 6));
            return SizedBox(
              width: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TableCalendar(
                    locale: 'ja_JP',
                    firstDay: DateTime(2020, 1, 1),
                    lastDay: DateTime(2030, 12, 31),
                    focusedDay: focused,
                    availableCalendarFormats: const {CalendarFormat.month: '月'},
                    calendarFormat: CalendarFormat.month,
                    // 単独日を強調しない（週帯のみを強調する）
                    selectedDayPredicate: (day) => false,
                    onDaySelected: (sel, foc) {
                      setLocal(() {
                        selected = DateTime(sel.year, sel.month, sel.day);
                        focused = DateTime(foc.year, foc.month, foc.day);
                      });
                    },
                    onPageChanged: (foc) => setLocal(() => focused = foc),
                    calendarBuilders: CalendarBuilders(
                      defaultBuilder: (context, day, focusedDay) {
                        final isInMonth = day.month == focused.month;
                        final dayOnly = DateTime(day.year, day.month, day.day);
                        final inWeek =
                            (!dayOnly.isBefore(start) && !dayOnly.isAfter(end));
                        if (!inWeek) {
                          return SizedBox.expand(
                            child: Container(
                              alignment: Alignment.center,
                              decoration: const BoxDecoration(), // 明示的に装飾なし
                              child: Text(
                                '${day.day}',
                                style: TextStyle(
                                  color: isInMonth
                                      ? Theme.of(context)
                                          .textTheme
                                          .bodyLarge
                                          ?.color
                                      : Theme.of(context).disabledColor,
                                ),
                              ),
                            ),
                          );
                        }
                        final isStart = isSameDay(day, start);
                        final isEnd = isSameDay(day, end);
                        final bg = Theme.of(context)
                            .colorScheme
                            .primary
                            .withOpacity( 0.18);
                        final borderSide = BorderSide(
                            color: Theme.of(context)
                                .colorScheme
                                .primary
                                .withOpacity( 0.5));
                        // 縦線を完全に消すため、週内セルは常に上下のみボーダーを描画
                        final BoxBorder border =
                            Border.symmetric(horizontal: borderSide);
                        final radius = BorderRadius.horizontal(
                          left: isStart
                              ? const Radius.circular(999)
                              : Radius.zero,
                          right:
                              isEnd ? const Radius.circular(999) : Radius.zero,
                        );
                        return Container(
                          decoration: BoxDecoration(
                              color: bg, border: border, borderRadius: radius),
                          alignment: Alignment.center,
                          child: Text(
                            '${day.day}',
                            style: TextStyle(
                              color: isInMonth
                                  ? Theme.of(context).textTheme.bodyLarge?.color
                                  : Theme.of(context).disabledColor,
                            ),
                          ),
                        );
                      },
                      todayBuilder: (context, day, focusedDay) {
                        final isInMonth = day.month == focused.month;
                        final dayOnly = DateTime(day.year, day.month, day.day);
                        final inWeek =
                            (!dayOnly.isBefore(start) && !dayOnly.isAfter(end));
                        if (!inWeek) {
                          return SizedBox.expand(
                            child: Container(
                              alignment: Alignment.center,
                              decoration: const BoxDecoration(),
                              child: Text(
                                '${day.day}',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: isInMonth
                                      ? Theme.of(context)
                                          .textTheme
                                          .bodyLarge
                                          ?.color
                                      : Theme.of(context).disabledColor,
                                ),
                              ),
                            ),
                          );
                        }
                        final isStart = isSameDay(day, start);
                        final isEnd = isSameDay(day, end);
                        final bg = Theme.of(context)
                            .colorScheme
                            .primary
                            .withOpacity( 0.18);
                        final borderSide = BorderSide(
                            color: Theme.of(context)
                                .colorScheme
                                .primary
                                .withOpacity( 0.5));
                        // 縦線を完全に消すため、週内セルは常に上下のみボーダーを描画
                        final BoxBorder border =
                            Border.symmetric(horizontal: borderSide);
                        final radius = BorderRadius.horizontal(
                          left: isStart
                              ? const Radius.circular(999)
                              : Radius.zero,
                          right:
                              isEnd ? const Radius.circular(999) : Radius.zero,
                        );
                        return Container(
                          decoration: BoxDecoration(
                              color: bg, border: border, borderRadius: radius),
                          alignment: Alignment.center,
                          child: Text(
                            '${day.day}',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: isInMonth
                                  ? Theme.of(context).textTheme.bodyLarge?.color
                                  : Theme.of(context).disabledColor,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('キャンセル')),
          ElevatedButton(
            onPressed: () => Navigator.pop(
              ctx,
              DateTime(selected.year, selected.month, selected.day),
            ),
            child: const Text('決定'),
          ),
        ],
      );
    },
  );
}
