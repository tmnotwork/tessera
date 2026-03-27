import 'package:flutter/material.dart';

class WeekNavigationNotification extends Notification {
  final int deltaWeeks; // -1: 前週, 0: 今週, 1: 次週
  final DateTime? targetDate; // 特定の日付を指定する場合
  final DateTime? highlightDate; // レポート上で強調表示したい基準日

  WeekNavigationNotification(this.deltaWeeks)
      : targetDate = null,
        highlightDate = null;
  WeekNavigationNotification.forDate(DateTime date, {DateTime? highlight})
      : deltaWeeks = 0,
        targetDate = date,
        highlightDate = highlight ?? date;
}

class DayNavigationNotification extends Notification {
  final int deltaDays; // -1: 前日, 0: 今日, 1: 翌日
  final bool pickDate; // 日付選択ダイアログを表示するか
  final DateTime? targetDate; // 特定の日付を指定する場合

  DayNavigationNotification(this.deltaDays)
      : pickDate = false,
        targetDate = null;
  DayNavigationNotification.pickDate()
      : deltaDays = 0,
        pickDate = true,
        targetDate = null;
  DayNavigationNotification.forDate(DateTime date)
      : deltaDays = 0,
        pickDate = false,
        targetDate = date;
}

class ReportPeriodDialogRequestNotification extends Notification {
  const ReportPeriodDialogRequestNotification();
}

