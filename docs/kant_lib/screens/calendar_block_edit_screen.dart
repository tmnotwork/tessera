import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/block.dart' as block;
import '../providers/task_provider.dart';
import '../services/block_sync_service.dart';
import '../services/mode_service.dart';
import '../services/notification_service.dart';
import '../services/app_settings_service.dart';
import '../services/project_service.dart';
import '../services/day_key_service.dart';
import '../widgets/block_editor/block_editor_form.dart';
import '../widgets/block_editor/block_editor_page.dart';

class CalendarBlockEditScreen extends StatefulWidget {
  final block.Block? initialBlock;
  final DateTime? initialDate;
  final TimeOfDay? initialStart;
  final bool isEvent;

  const CalendarBlockEditScreen(
      {super.key,
      this.initialBlock,
      this.initialDate,
      this.initialStart,
      this.isEvent = true});

  @override
  State<CalendarBlockEditScreen> createState() =>
      _CalendarBlockEditScreenState();
}

class _CalendarBlockEditScreenState extends State<CalendarBlockEditScreen> {
  static const int _defaultDurationMinutes = 60;

  late final bool _isEditing;

  late DateTime _initialStartDate;
  late TimeOfDay _initialStartTime;
  late DateTime _initialEndDate;
  late TimeOfDay _initialEndTime;
  late int _initialBreakMinutes;
  late bool _initialIsEvent;
  late bool _initialExcludeFromReport;

  late String _initialTitle;
  late bool _allowEditTitle;

  String? _initialBlockName;
  String? _initialMemo;
  String? _initialLocation;

  String? _initialProjectId;
  String? _initialProjectName;
  String? _initialSubProjectId;
  String? _initialSubProjectName;
  String? _initialModeId;
  String? _initialModeName;

  @override
  void initState() {
    super.initState();
    _isEditing = widget.initialBlock != null;
    final b = widget.initialBlock;
    if (b != null) {
      DateTime startWall;
      DateTime endWallExclusive;
      if (b.startAt != null && b.endAtExclusive != null) {
        startWall = DayKeyService.toAccountWallClockFromUtc(b.startAt!);
        endWallExclusive = DayKeyService.toAccountWallClockFromUtc(b.endAtExclusive!);
      } else {
        final startDate = DateTime(
          b.executionDate.year,
          b.executionDate.month,
          b.executionDate.day,
        );
        final startTime = TimeOfDay(hour: b.startHour, minute: b.startMinute);
        startWall = DateTime(
          startDate.year,
          startDate.month,
          startDate.day,
          startTime.hour,
          startTime.minute,
        );
        endWallExclusive = startWall.add(Duration(minutes: b.estimatedDuration));
      }
      final durationMinutes = endWallExclusive.difference(startWall).inMinutes;

      final isAllDay = b.allDay == true;
      _initialStartDate = DateTime(startWall.year, startWall.month, startWall.day);
      _initialStartTime = isAllDay
          ? const TimeOfDay(hour: 0, minute: 0)
          : TimeOfDay(hour: startWall.hour, minute: startWall.minute);
      // endAtExclusive を UI（inclusive endDate）へ変換（終日だけ -1日）
      final endDateInclusive = isAllDay
          ? DateTime(endWallExclusive.year, endWallExclusive.month, endWallExclusive.day)
              .add(const Duration(days: -1))
          : DateTime(endWallExclusive.year, endWallExclusive.month, endWallExclusive.day);
      _initialEndDate = endDateInclusive;
      _initialEndTime = isAllDay
          ? const TimeOfDay(hour: 0, minute: 0)
          : TimeOfDay(
              hour: endWallExclusive.hour,
              minute: endWallExclusive.minute,
            );
      final initialBreak = durationMinutes - b.workingMinutes;
      _initialBreakMinutes = initialBreak <= 0 ? 0 : initialBreak;
      _initialIsEvent = b.isEvent == true;
      _initialExcludeFromReport = b.excludeFromReport == true;

      _initialTitle = b.title;
      // カレンダー編集は従来通りタイトルを維持（編集UIから除外の扱い）
      _allowEditTitle = false;

      _initialBlockName = b.blockName;
      _initialMemo = b.memo;
      _initialLocation = b.location;

      _initialProjectId = b.projectId;
      _initialProjectName =
          (b.projectId != null && b.projectId!.isNotEmpty)
              ? (ProjectService.getProjectById(b.projectId!)?.name ?? '')
              : '';
      _initialSubProjectId = b.subProjectId;
      _initialSubProjectName = b.subProject;
      _initialModeId = b.modeId;
      _initialModeName = (() {
        final id = b.modeId ?? '';
        if (id.isEmpty) return '';
        return ModeService.getModeById(id)?.name ?? '';
      })();
    } else {
      final d = widget.initialDate ?? DateTime.now();
      final s = widget.initialStart ?? const TimeOfDay(hour: 9, minute: 0);
      final startDate = DateTime(d.year, d.month, d.day);
      final startDt = DateTime(startDate.year, startDate.month, startDate.day, s.hour, s.minute);
      final endDt = startDt.add(const Duration(minutes: _defaultDurationMinutes));

      _initialStartDate = startDate;
      _initialStartTime = s;
      _initialEndDate = DateTime(endDt.year, endDt.month, endDt.day);
      _initialEndTime = TimeOfDay(hour: endDt.hour, minute: endDt.minute);
      _initialIsEvent = widget.isEvent;
      _initialExcludeFromReport = false;

      _initialTitle = '';
      _allowEditTitle = true;
      _initialBlockName = '';
      _initialMemo = '';
      _initialLocation = '';
      _initialProjectId = null;
      _initialProjectName = '';
      _initialSubProjectId = null;
      _initialSubProjectName = '';
      _initialModeId = null;
      _initialModeName = '';

      // 設定から初期休憩時間の割合を取得して反映（従来通り）
      final breakRatio = AppSettingsService.getInt(
        AppSettingsService.keyCalendarInitialBreakRatio,
        defaultValue: 100, // デフォルト100% (稼働0%)
      );
      final initialBreak = (_defaultDurationMinutes * breakRatio / 100).round();
      _initialBreakMinutes = initialBreak;
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlockEditorPage(
      title: _isEditing ? '予定ブロックを編集' : '予定ブロックを追加',
      primaryActionLabel: _isEditing ? '保存' : '追加',
      onDelete: _isEditing ? _deleteWithoutPop : null,
      initialStartDate: _initialStartDate,
      initialStartTime: _initialStartTime,
      initialEndDate: _initialEndDate,
      initialEndTime: _initialEndTime,
      initialBreakMinutes: _initialBreakMinutes,
      initialIsEvent: _initialIsEvent,
      initialAllDay: widget.initialBlock?.allDay == true,
      initialExcludeFromReport: _initialExcludeFromReport,
      initialTitle: _initialTitle,
      allowEditTitle: _allowEditTitle,
      initialBlockName: _initialBlockName,
      initialMemo: _initialMemo,
      initialLocation: _initialLocation,
      initialProjectId: _initialProjectId,
      initialProjectName: _initialProjectName,
      initialSubProjectId: _initialSubProjectId,
      initialSubProjectName: _initialSubProjectName,
      initialModeId: _initialModeId,
      initialModeName: _initialModeName,
      onPrimary: (result) async {
        await _saveFromResult(result);
        if (!context.mounted) return;
        Navigator.of(context).pop(true);
      },
    );
  }

  Future<void> _saveFromResult(BlockEditorResult result) async {
    if (_isEditing) {
      final e = widget.initialBlock!;
      final bool isAllDay = result.allDay == true;
      final updatedLegacy = e.copyWith(
        title: e.title, // カレンダー編集は従来通り維持
        blockName: result.blockName,
        executionDate:
            DateTime(result.startDate.year, result.startDate.month, result.startDate.day),
        startHour: isAllDay ? 0 : result.startTime.hour,
        startMinute: isAllDay ? 0 : result.startTime.minute,
        estimatedDuration: isAllDay ? 24 * 60 : result.estimatedMinutes,
        workingMinutes: isAllDay ? 24 * 60 : result.workingMinutes,
        projectId: result.projectId,
        subProjectId: result.subProjectId,
        subProject: result.subProjectName,
        modeId: result.modeId,
        memo: result.memo,
        location: result.location,
        isEvent: result.isEvent,
        excludeFromReport: result.excludeFromReport,
        allDay: isAllDay,
        lastModified: DateTime.now(),
        version: e.version + 1,
      );
      final startLocal = DateTime(
        result.startDate.year,
        result.startDate.month,
        result.startDate.day,
        isAllDay ? 0 : result.startTime.hour,
        isAllDay ? 0 : result.startTime.minute,
      );
      // 終日のUIは endDate inclusive なので、保存時は endExclusive に変換する
      final endLocalExclusive = isAllDay
          ? DateTime(
              result.endDate.year,
              result.endDate.month,
              result.endDate.day,
            ).add(const Duration(days: 1))
          : DateTime(
              result.endDate.year,
              result.endDate.month,
              result.endDate.day,
              result.endTime.hour,
              result.endTime.minute,
            );
      final updated = updatedLegacy.recomputeCanonicalRange(
        startLocalOverride: startLocal,
        endLocalExclusiveOverride: endLocalExclusive,
        allDayOverride: isAllDay,
      );
      await BlockSyncService().updateBlockWithSync(updated);
      try {
        await NotificationService().scheduleEventReminder(updated);
      } catch (_) {}
    } else {
      final bool isAllDay = result.allDay == true;
      final created = await BlockSyncService().createBlockWithSync(
        title: result.title,
        executionDate:
            DateTime(result.startDate.year, result.startDate.month, result.startDate.day),
        startHour: isAllDay ? 0 : result.startTime.hour,
        startMinute: isAllDay ? 0 : result.startTime.minute,
        estimatedDuration: isAllDay ? 24 * 60 : result.estimatedMinutes,
        workingMinutes: isAllDay ? 24 * 60 : result.workingMinutes,
        projectId: result.projectId,
        subProjectId: result.subProjectId,
        subProject: result.subProjectName,
        modeId: result.modeId,
        blockName: result.blockName,
        memo: result.memo,
        location: result.location,
        isEvent: result.isEvent,
        excludeFromReport: result.excludeFromReport,
        allDay: isAllDay,
        startLocalOverride: isAllDay
            ? DateTime(result.startDate.year, result.startDate.month, result.startDate.day)
            : null,
        endLocalExclusiveOverride: isAllDay
            ? DateTime(result.endDate.year, result.endDate.month, result.endDate.day)
                .add(const Duration(days: 1))
            : null,
      );
      try {
        await NotificationService().scheduleEventReminder(created);
      } catch (_) {}
    }

    if (!mounted) return;
    await context.read<TaskProvider>().refreshTasks();
  }

  Future<void> _deleteWithoutPop() async {
    final b = widget.initialBlock;
    if (b == null) return;
    await BlockSyncService().deleteBlockWithSync(b.id);
    try {
      await NotificationService().cancelEventReminder(b);
    } catch (_) {}
    if (!mounted) return;
    await context.read<TaskProvider>().refreshTasks();
  }
}
