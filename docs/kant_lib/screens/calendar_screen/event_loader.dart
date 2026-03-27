import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/task_provider.dart';
import '../../services/app_settings_service.dart';
import '../../services/calendar_service.dart';
import '../../services/inbox_task_service.dart';
import '../../models/actual_task.dart' as actual;
import '../../models/block.dart' as block;
import '../../models/inbox_task.dart' as inbox;
import '../../widgets/calendar_settings.dart';

List<dynamic> getEventsForDay({
  required BuildContext context,
  required CalendarSettings settings,
  required DateTime day,
}) {
  final taskProvider = Provider.of<TaskProvider>(context, listen: false);

  // Month view must show multi-day blocks on each overlapping day.
  // NOTE: UI (TableCalendar cell rendering) remains unchanged; we only fix the
  // day-to-events mapping used by `eventLoader`.
  var blocks = taskProvider
      .getBlocksForDate(day)
      .where((b) => b.isPauseDerived != true)
      .toList();
  final actualTasks = taskProvider.getActualTasksForDate(day);
  final inboxTasks = taskProvider.getInboxTasksForDate(day);

  final allTasks = <dynamic>[];
  final bool isMonthOrWeek =
      settings.viewType == CalendarViewType.month ||
          settings.viewType == CalendarViewType.week;
  if (!isMonthOrWeek) {
    allTasks.addAll(actualTasks);
    allTasks.addAll(inboxTasks);
  }

  final hideRoutine = settings.hideRoutineBlocksWithoutInboxInMonth ||
      CalendarService.hideRoutineBlocksWithoutInboxInMonth;
  final shouldApplyRoutineFilter =
      (settings.viewType == CalendarViewType.month ||
              settings.viewType == CalendarViewType.year) &&
          hideRoutine;
  final inboxPresenceCache = <String, bool>{};
  final inboxTaskIds =
      taskProvider.allInboxTasks.map((task) => task.id).toSet();

  bool hasLinkedInboxTask(String? taskId) {
    final id = taskId?.trim();
    if (id == null || id.isEmpty) {
      return false;
    }
    if (inboxPresenceCache.containsKey(id)) {
      return inboxPresenceCache[id]!;
    }
    final existsInProvider = inboxTaskIds.contains(id);
    if (existsInProvider) {
      inboxPresenceCache[id] = true;
      return true;
    }
    final inboxTask = InboxTaskService.getInboxTask(id);
    final exists = inboxTask != null && inboxTask.isDeleted != true;
    inboxPresenceCache[id] = exists;
    return exists;
  }

  if (shouldApplyRoutineFilter) {
    blocks = blocks.where((e) {
      try {
        final isRoutine = e.isRoutineDerived ||
            e.creationMethod == block.TaskCreationMethod.routine;
        final hasInboxLink = hasLinkedInboxTask(e.taskId);
        final noInbox = !hasInboxLink;
        return !(isRoutine && noInbox);
      } catch (_) {}
      return true;
    }).toList();
  }

  if (settings.viewType == CalendarViewType.month &&
      AppSettingsService.calendarShowEventsOnlyNotifier.value) {
    blocks = blocks.where((e) => e.isEvent == true).toList();
  }
  allTasks.addAll(blocks);

  allTasks.sort(_compareEvents);

  return allTasks;
}

int _compareEvents(dynamic a, dynamic b) {
  // Phase 1: month/week（TableCalendarセル内）では終日を先頭に寄せる
  if (a is block.Block && b is block.Block) {
    final aAllDay = a.allDay == true;
    final bAllDay = b.allDay == true;
    if (aAllDay != bAllDay) {
      return aAllDay ? -1 : 1;
    }
  }

  final startA = _eventStartDateTime(a);
  final startB = _eventStartDateTime(b);

  if (startA != null && startB != null) {
    final comparison = startA.compareTo(startB);
    if (comparison != 0) {
      return comparison;
    }
  } else if (startA != null) {
    return -1;
  } else if (startB != null) {
    return 1;
  }

  final typeComparison =
      _eventTypePriority(a).compareTo(_eventTypePriority(b));
  if (typeComparison != 0) {
    return typeComparison;
  }

  return _eventLabel(a).toLowerCase().compareTo(_eventLabel(b).toLowerCase());
}

DateTime? _eventStartDateTime(dynamic event) {
  if (event is block.Block) {
    final date = event.executionDate;
    return DateTime(
      date.year,
      date.month,
      date.day,
      event.startHour,
      event.startMinute,
    );
  }
  if (event is actual.ActualTask) {
    return event.startTime;
  }
  if (event is inbox.InboxTask) {
    if (event.startHour != null && event.startMinute != null) {
      final date = event.executionDate;
      return DateTime(
        date.year,
        date.month,
        date.day,
        event.startHour!,
        event.startMinute!,
      );
    }
  }
  return null;
}

int _eventTypePriority(dynamic event) {
  if (event is block.Block) {
    return 0;
  }
  if (event is actual.ActualTask) {
    return 1;
  }
  if (event is inbox.InboxTask) {
    return 2;
  }
  return 3;
}

String _eventLabel(dynamic event) {
  if (event is block.Block) {
    final names = [
      event.blockName,
      event.title,
    ].whereType<String>().where((value) => value.isNotEmpty);
    if (names.isNotEmpty) {
      return names.first;
    }
    return '${event.startHour.toString().padLeft(2, '0')}:${event.startMinute.toString().padLeft(2, '0')}';
  }
  if (event is actual.ActualTask) {
    return event.title;
  }
  if (event is inbox.InboxTask) {
    return event.title;
  }
  return '';
}

