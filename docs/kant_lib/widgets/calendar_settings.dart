import 'package:flutter/material.dart';
import 'package:table_calendar/table_calendar.dart';

import '../app/theme/domain_colors.dart';

enum CalendarViewType { day, week, month, year }

class CalendarSettings {
  bool showHolidays;
  bool showWeekendColors;
  bool showTaskMarkers;
  Color calendarThemeColor;
  CalendarViewType viewType;
  bool showYearView;
  bool hideRoutineBlocksWithoutInboxInMonth;

  CalendarSettings({
    this.showHolidays = true,
    this.showWeekendColors = true,
    this.showTaskMarkers = true,
    this.calendarThemeColor = DomainColors.applyDayWeekday,
    this.viewType = CalendarViewType.month,
    this.showYearView = false,
    this.hideRoutineBlocksWithoutInboxInMonth = true,
  });

  CalendarSettings copyWith({
    bool? showHolidays,
    bool? showWeekendColors,
    bool? showTaskMarkers,
    Color? calendarThemeColor,
    CalendarViewType? viewType,
    bool? showYearView,
    bool? hideRoutineBlocksWithoutInboxInMonth,
  }) {
    return CalendarSettings(
      showHolidays: showHolidays ?? this.showHolidays,
      showWeekendColors: showWeekendColors ?? this.showWeekendColors,
      showTaskMarkers: showTaskMarkers ?? this.showTaskMarkers,
      calendarThemeColor: calendarThemeColor ?? this.calendarThemeColor,
      viewType: viewType ?? this.viewType,
      showYearView: showYearView ?? this.showYearView,
      hideRoutineBlocksWithoutInboxInMonth: hideRoutineBlocksWithoutInboxInMonth ?? this.hideRoutineBlocksWithoutInboxInMonth,
    );
  }

  CalendarFormat get calendarFormat {
    switch (viewType) {
      case CalendarViewType.day:
        return CalendarFormat.week; // 日表示は週表示で実装（1日分のみ表示）
      case CalendarViewType.week:
        return CalendarFormat.week;
      case CalendarViewType.month:
        return CalendarFormat.month;
      case CalendarViewType.year:
        return CalendarFormat.month; // 年表示は月表示で実装
    }
  }
}
