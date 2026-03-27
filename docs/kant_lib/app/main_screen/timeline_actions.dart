import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/block.dart';
import '../../providers/task_provider.dart';
import '../../widgets/app_notifications.dart';
import '../../services/block_outbox_manager.dart';
import '../../services/block_sync_service.dart';
import '../../services/actual_task_sync_service.dart';
import '../../services/inbox_task_sync_service.dart';
import '../../services/sync_context.dart';
import '../../services/mode_sync_service.dart';
import '../../screens/calendar_screen/dialogs/add_block_dialog.dart';
import '../../services/day_key_service.dart';

class TimelineActions {
  static Future<void> forceSyncTimeline(BuildContext context) async {
    final totalSw = Stopwatch()..start();
    try {
      // 1) Outbox flush
      await BlockOutboxManager.flush();

      // 2) Blocks
      await BlockSyncService.syncAllBlocks();

      // 3) Actual tasks
      await ActualTaskSyncService.syncAllTasks();

      // 4) Inbox tasks
      await SyncContext.runWithOrigin(
        'TimelineActions.forceSyncTimeline',
        () => InboxTaskSyncService.syncAllInboxTasks(),
      );

      // 5) Modes
      await ModeSyncService.syncAllModes();

      // 6) Refresh UI data
      if (context.mounted) {
        final taskProvider = Provider.of<TaskProvider>(context, listen: false);
        await taskProvider.refreshTasks();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('タイムラインの強制同期が完了しました')),
        );
      }
    } catch (e) {
      print(
          '❌ FORCE-SYNC: error: $e (total so far ${totalSw.elapsedMilliseconds} ms)');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('強制同期エラー: $e')),
        );
      }
    }
  }

  static Future<void> addBlockToTimeline(
    BuildContext context, {
    required DateTime day,
    required String snackbarLabel,
    TimeOfDay? initialStart,
    // 全画面表示に統一（従来のダイアログ表示は廃止）
    bool fullscreen = true,
  }) async {
    try {
      // 入力ダイアログを表示してから作成
      final result = await showAddBlockDialog(
        context: context,
        initialDate: day,
        initialStart: initialStart ?? TimeOfDay.fromDateTime(DateTime.now()),
        fullscreen: fullscreen,
      );

      if (result == null) {
        // キャンセル時は何もしない
        return;
      }

      final taskProvider = Provider.of<TaskProvider>(context, listen: false);
      final startWall = DateTime(
        result.selectedDate.year,
        result.selectedDate.month,
        result.selectedDate.day,
        result.startTime.hour,
        result.startTime.minute,
      );
      final endWall = startWall.add(Duration(minutes: result.estimatedMinutes));
      final startAtUtc = DayKeyService.toUtcFromAccountWallClock(startWall);
      final endAtUtcExclusive = DayKeyService.toUtcFromAccountWallClock(endWall);

      final created = await BlockSyncService().createBlockWithSyncRange(
        title: result.title,
        startAtUtc: startAtUtc,
        endAtExclusiveUtc: endAtUtcExclusive,
        workingMinutes: result.workingMinutes,
        projectId: result.projectId,
        memo: result.memo,
        subProjectId: result.subProjectId,
        subProject: result.subProjectName,
        modeId: result.modeId,
        blockName: result.blockName,
        location: result.location,
        isEvent: result.isEvent,
        excludeFromReport: result.excludeFromReport,
      );
      await taskProvider.refreshTasks();
      // 今の時間帯に追加したブロックはその場で展開する
      if (context.mounted) {
        final now = DateTime.now();
        if (!now.isBefore(startWall) && now.isBefore(endWall)) {
          TimelineExpandBlockRequestNotification(
            blockId: created.id,
            date: DateTime(result.selectedDate.year, result.selectedDate.month, result.selectedDate.day),
          ).dispatch(context);
        }
      }
      // 仕様変更: 予定ブロック追加時のスナックバーは表示しない
      // ignore: unused_local_variable
      // (戻り値互換のため。このメソッドは void のまま維持)
      final Block _ = created;
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('エラー: $e')),
        );
      }
    }
  }

  /// ギャップ等から「追加したブロック」を呼び出し側で扱いたい場合に使用。
  /// `addBlockToTimeline` は互換のため void を維持し、このメソッドで Block を返す。
  static Future<Block?> addBlockToTimelineReturningBlock(
    BuildContext context, {
    required DateTime day,
    required String snackbarLabel,
    TimeOfDay? initialStart,
    bool fullscreen = true,
  }) async {
    try {
      final result = await showAddBlockDialog(
        context: context,
        initialDate: day,
        initialStart: initialStart ?? TimeOfDay.fromDateTime(DateTime.now()),
        fullscreen: fullscreen,
      );

      if (result == null) return null;

      final taskProvider = Provider.of<TaskProvider>(context, listen: false);
      final startWall = DateTime(
        result.selectedDate.year,
        result.selectedDate.month,
        result.selectedDate.day,
        result.startTime.hour,
        result.startTime.minute,
      );
      final endWall = startWall.add(Duration(minutes: result.estimatedMinutes));
      final startAtUtc = DayKeyService.toUtcFromAccountWallClock(startWall);
      final endAtUtcExclusive = DayKeyService.toUtcFromAccountWallClock(endWall);

      final created = await BlockSyncService().createBlockWithSyncRange(
        title: result.title,
        startAtUtc: startAtUtc,
        endAtExclusiveUtc: endAtUtcExclusive,
        workingMinutes: result.workingMinutes,
        projectId: result.projectId,
        memo: result.memo,
        subProjectId: result.subProjectId,
        subProject: result.subProjectName,
        modeId: result.modeId,
        blockName: result.blockName,
        location: result.location,
        isEvent: result.isEvent,
        excludeFromReport: result.excludeFromReport,
      );
      await taskProvider.refreshTasks();
      // 今の時間帯に追加したブロックはその場で展開する
      if (context.mounted) {
        final now = DateTime.now();
        if (!now.isBefore(startWall) && now.isBefore(endWall)) {
          TimelineExpandBlockRequestNotification(
            blockId: created.id,
            date: DateTime(result.selectedDate.year, result.selectedDate.month, result.selectedDate.day),
          ).dispatch(context);
        }
      }
      return created;
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('エラー: $e')),
        );
      }
      return null;
    }
  }
}
