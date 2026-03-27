import 'package:flutter/material.dart';

import '../../../services/app_settings_service.dart';
import '../../../widgets/block_editor/block_editor_page.dart';
import '../../../utils/unified_screen_dialog.dart';

const _defaultDurationMinutes = 60;

class AddBlockDialogResult {
  final DateTime selectedDate; // date-only (local)
  final TimeOfDay startTime;
  final int estimatedMinutes;
  final int workingMinutes;
  final String title;
  final String? blockName;
  final String? projectId;
  final String? subProjectId;
  final String? subProjectName;
  final String? modeId;
  final String? memo;
  final String? location;
  final bool isEvent;
  final bool excludeFromReport;

  const AddBlockDialogResult({
    required this.selectedDate,
    required this.startTime,
    required this.estimatedMinutes,
    required this.workingMinutes,
    required this.title,
    this.blockName,
    this.projectId,
    this.subProjectId,
    this.subProjectName,
    this.modeId,
    this.memo,
    this.location,
    this.isEvent = false,
    this.excludeFromReport = false,
  });
}

Future<AddBlockDialogResult?> showAddBlockDialog({
  required BuildContext context,
  required DateTime initialDate,
  TimeOfDay? initialStart,
  // 全画面表示に統一（従来のダイアログ表示は廃止）
  bool fullscreen = true,
}) async {
  // NOTE: fullscreen パラメータは互換のため残しているが、現在は常に全画面で表示する。
  // ignore: unused_local_variable
  final _ = fullscreen;

  final startTime = initialStart ?? TimeOfDay.fromDateTime(DateTime.now());
  final startDate = DateTime(initialDate.year, initialDate.month, initialDate.day);
  final startDt = DateTime(
    startDate.year,
    startDate.month,
    startDate.day,
    startTime.hour,
    startTime.minute,
  );
  final endDt = startDt.add(const Duration(minutes: _defaultDurationMinutes));

  // 設定から初期休憩時間の割合を取得して反映（従来通り）
  final breakRatio = AppSettingsService.getInt(
    AppSettingsService.keyCalendarInitialBreakRatio,
    defaultValue: 100, // デフォルト100% (稼働0%)
  );
  final initialBreak = (_defaultDurationMinutes * breakRatio / 100).round();

  return showUnifiedScreenDialog<AddBlockDialogResult>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => BlockEditorPage(
      title: '予定ブロックを追加',
      primaryActionLabel: '追加',
      autofocusBlockName: true,
      initialStartDate: startDate,
      initialStartTime: startTime,
      initialEndDate: DateTime(endDt.year, endDt.month, endDt.day),
      initialEndTime: TimeOfDay(hour: endDt.hour, minute: endDt.minute),
      initialBreakMinutes: initialBreak,
      // タイムライン起点のデフォルトは従来通り isEvent=false
      initialIsEvent: false,
      initialAllDay: false,
      // タイムライン起点で終日を作ると「保存後にタイムラインから消える」ため、ここでは無効化する
      allowAllDay: false,
      initialTitle: '',
      allowEditTitle: true,
      initialBlockName: '',
      initialMemo: '',
      initialLocation: '',
      initialProjectId: null,
      initialProjectName: '',
      initialSubProjectId: null,
      initialSubProjectName: '',
      initialModeId: null,
      initialModeName: '',
      onPrimary: (r) async {
        Navigator.of(ctx).pop(
          AddBlockDialogResult(
            selectedDate: r.startDate,
            startTime: r.startTime,
            estimatedMinutes: r.estimatedMinutes,
            workingMinutes: r.workingMinutes,
            title: r.title,
            blockName: r.blockName,
            projectId: r.projectId,
            subProjectId: r.subProjectId,
            subProjectName: r.subProjectName,
            modeId: r.modeId,
            memo: r.memo,
            location: r.location,
            isEvent: r.isEvent,
            excludeFromReport: r.excludeFromReport,
          ),
        );
      },
    ),
  );
}

