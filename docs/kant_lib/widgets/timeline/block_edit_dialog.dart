import 'package:flutter/material.dart';

import '../../models/block.dart' as block;
import '../../providers/task_provider.dart';
import '../../services/block_sync_service.dart';
import '../../services/mode_service.dart';
import '../../services/notification_service.dart';
import '../../services/project_service.dart';
import '../../services/day_key_service.dart';
import '../block_editor/block_editor_page.dart';
import '../block_editor/block_editor_form.dart';

class BlockEditDialog extends StatefulWidget {
  final block.Block target;
  final TaskProvider taskProvider;

  const BlockEditDialog({
    super.key,
    required this.target,
    required this.taskProvider,
  });

  @override
  State<BlockEditDialog> createState() => _BlockEditDialogState();
}

class _BlockEditDialogState extends State<BlockEditDialog> {
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
    final b = widget.target;
    // Final State direction:
    // UI 初期値は canonical range（startAt/endAtExclusive）を優先し、無ければ旧フィールドへフォールバック。
    DateTime startWall;
    DateTime endWallExclusive;
    if (b.startAt != null && b.endAtExclusive != null) {
      startWall = DayKeyService.toAccountWallClockFromUtc(b.startAt!);
      endWallExclusive = DayKeyService.toAccountWallClockFromUtc(b.endAtExclusive!);
    } else {
      final startDate =
          DateTime(b.executionDate.year, b.executionDate.month, b.executionDate.day);
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
    _initialStartTime =
        isAllDay ? const TimeOfDay(hour: 0, minute: 0) : TimeOfDay(hour: startWall.hour, minute: startWall.minute);
    final endDateInclusive = isAllDay
        ? DateTime(endWallExclusive.year, endWallExclusive.month, endWallExclusive.day)
            .add(const Duration(days: -1))
        : DateTime(endWallExclusive.year, endWallExclusive.month, endWallExclusive.day);
    _initialEndDate = endDateInclusive;
    _initialEndTime = isAllDay
        ? const TimeOfDay(hour: 0, minute: 0)
        : TimeOfDay(hour: endWallExclusive.hour, minute: endWallExclusive.minute);

    final initialBreak = durationMinutes - b.workingMinutes;
    _initialBreakMinutes = initialBreak <= 0 ? 0 : initialBreak;
    _initialIsEvent = b.isEvent == true;
    _initialExcludeFromReport = b.excludeFromReport == true;

    _initialTitle = b.title;
    // タイムライン編集は従来通りタイトル編集を許可
    _allowEditTitle = true;

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
  }

  @override
  Widget build(BuildContext context) {
    // NOTE: 入口（カレンダー/タイムライン）で見た目がズレないよう、タイムライン準拠の見た目（Close + FAB）に統一する。
    return BlockEditorPage(
      title: '予定ブロックを編集',
      primaryActionLabel: '保存',
      onDelete: _deleteWithoutPop,
      initialStartDate: _initialStartDate,
      initialStartTime: _initialStartTime,
      initialEndDate: _initialEndDate,
      initialEndTime: _initialEndTime,
      initialBreakMinutes: _initialBreakMinutes,
      initialIsEvent: _initialIsEvent,
      initialAllDay: widget.target.allDay == true,
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
    final b = widget.target;
    final bool isAllDay = result.allDay == true;
    final updatedLegacy = b.copyWith(
      title: result.title,
      blockName: result.blockName,
      memo: result.memo,
      excludeFromReport: result.excludeFromReport,
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
      location: result.location,
      isEvent: result.isEvent,
      allDay: isAllDay,
    );

    final startLocal = DateTime(
      result.startDate.year,
      result.startDate.month,
      result.startDate.day,
      isAllDay ? 0 : result.startTime.hour,
      isAllDay ? 0 : result.startTime.minute,
    );
    final endLocalExclusive = isAllDay
        ? DateTime(result.endDate.year, result.endDate.month, result.endDate.day)
            .add(const Duration(days: 1))
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

    await widget.taskProvider.updateBlock(updated);
    try {
      await widget.taskProvider.refreshTasks(showLoading: false);
    } catch (_) {}
  }

  Future<void> _deleteWithoutPop() async {
    final b = widget.target;
    await BlockSyncService().deleteBlockWithSync(b.id);
    try {
      await NotificationService().cancelEventReminder(b);
    } catch (_) {}
    try {
      await widget.taskProvider.refreshTasks(showLoading: false);
    } catch (_) {}
  }
}
