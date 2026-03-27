import '../models/block.dart';
import '../models/inbox_task.dart';
import 'device_info_service.dart';
import 'inbox_task_service.dart';
import 'task_sync_manager.dart';
import 'block_utilities.dart';

/// ブロック時刻変更時に、紐づく InboxTask の開始時刻を「前から詰める」再配置を行う。
///
/// 仕様:
/// - 対象: 未削除・未完了で、InboxTask.blockId が block.id / block.cloudId / old.cloudId に一致するもの
/// - 順序: 元の開始時刻(= executionDate + startHour/startMinute) 昇順。開始時刻が無いものは末尾。
/// - 配置: ブロック開始から順に cursor を進めて start を設定（ギャップ探索なし）
/// - オーバー: overflow してもそのままセットし、通知（UI側で「オーバーしています」表示）を発行する
class BlockTaskRescheduler {
  static bool _isTimeChanged(Block oldBlock, Block newBlock) {
    bool sameDay(DateTime a, DateTime b) =>
        a.year == b.year && a.month == b.month && a.day == b.day;
    return !sameDay(oldBlock.executionDate, newBlock.executionDate) ||
        oldBlock.startHour != newBlock.startHour ||
        oldBlock.startMinute != newBlock.startMinute ||
        oldBlock.estimatedDuration != newBlock.estimatedDuration;
  }

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  static DateTime? _plannedStart(InboxTask t) {
    final sh = t.startHour;
    final sm = t.startMinute;
    if (sh == null || sm == null) return null;
    final d = t.executionDate;
    return DateTime(d.year, d.month, d.day, sh, sm);
  }

  /// ブロック更新後に呼び出し、必要なら紐づくInboxTaskを再配置する。
  ///
  /// 戻り値: 再配置した件数とオーバー分（分）
  static Future<BlockRescheduleNotice?> rescheduleIfNeeded({
    required Block? oldBlock,
    required Block newBlock,
  }) async {
    if (oldBlock == null) return null;
    if (!_isTimeChanged(oldBlock, newBlock)) return null;

    await InboxTaskService.initialize();

    final Set<String> keys = <String>{
      newBlock.id,
      if ((newBlock.cloudId ?? '').isNotEmpty) newBlock.cloudId!,
      if ((oldBlock.cloudId ?? '').isNotEmpty) oldBlock.cloudId!,
    };

    final tasks = InboxTaskService.getAllInboxTasks()
        .where((t) => t.isDeleted != true)
        .where((t) => t.isCompleted != true)
        .where((t) {
          final bid = t.blockId;
          if (bid == null || bid.isEmpty) return false;
          return keys.contains(bid);
        })
        .toList();

    if (tasks.isEmpty) return null;

    // Sort by original planned start time (ascending); tasks with no start time go last.
    tasks.sort((a, b) {
      final sa = _plannedStart(a);
      final sb = _plannedStart(b);
      if (sa != null && sb != null) {
        final c = sa.compareTo(sb);
        if (c != 0) return c;
      } else if (sa != null && sb == null) {
        return -1;
      } else if (sa == null && sb != null) {
        return 1;
      }
      // Stable tie-breakers
      final c1 = a.createdAt.compareTo(b.createdAt);
      if (c1 != 0) return c1;
      return a.id.compareTo(b.id);
    });

    final deviceId = await DeviceInfoService.getDeviceId();

    DateTime cursor = DateTime(
      newBlock.executionDate.year,
      newBlock.executionDate.month,
      newBlock.executionDate.day,
      newBlock.startHour,
      newBlock.startMinute,
    );

    final updatedTasks = <InboxTask>[];
    for (final t in tasks) {
      final duration = t.estimatedDuration < 0 ? 0 : t.estimatedDuration;
      final start = cursor;
      final updated = t.copyWith(
        executionDate: _dateOnly(start),
        startHour: start.hour,
        startMinute: start.minute,
      );
      updated.markAsModified(deviceId);
      updatedTasks.add(updated);
      cursor = cursor.add(Duration(minutes: duration));
    }

    // Persist + enqueue sync
    for (final t in updatedTasks) {
      await InboxTaskService.updateInboxTask(t);
      // Sync (offline-safe)
      // ignore: unawaited_futures
      TaskSyncManager.syncInboxTaskImmediately(
        t,
        'update',
        origin: 'BlockTaskRescheduler.rescheduleIfNeeded',
      );
    }

    final blockEnd = DateTime(
      newBlock.executionDate.year,
      newBlock.executionDate.month,
      newBlock.executionDate.day,
      newBlock.startHour,
      newBlock.startMinute,
    ).add(Duration(minutes: newBlock.estimatedDuration));

    final overflowMinutes =
        cursor.isAfter(blockEnd) ? cursor.difference(blockEnd).inMinutes : 0;

    final label = (newBlock.blockName != null && newBlock.blockName!.trim().isNotEmpty)
        ? newBlock.blockName!.trim()
        : (newBlock.title.trim().isNotEmpty ? newBlock.title.trim() : null);

    final notice = BlockRescheduleNotice(
      blockId: newBlock.id,
      blockCloudId: (newBlock.cloudId ?? '').isEmpty ? null : newBlock.cloudId,
      blockLabel: label,
      overflowMinutes: overflowMinutes,
      rescheduledTaskCount: updatedTasks.length,
    );

    if (overflowMinutes > 0) {
      BlockUtilities.notifyRescheduleNotice(notice);
    }
    return notice;
  }
}

