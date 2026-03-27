import '../models/actual_task.dart';
import '../models/inbox_task.dart';
import '../models/task_outbox_entry.dart';
import 'task_sync_transport.dart';

/// タスク同期処理への統一的なエントリポイント。
class TaskSyncEntryPoint {
  const TaskSyncEntryPoint._();

  static Future<TaskSyncTransportResult> syncActualTask(
    ActualTask task,
    String operation,
  ) {
    return TaskSyncTransport.syncActualTask(task, operation);
  }

  static Future<TaskSyncTransportResult> syncInboxTask(
    InboxTask task,
    String operation,
  ) {
    return TaskSyncTransport.syncInboxTask(task, operation);
  }

  static Future<TaskSyncTransportResult> syncOutboxEntry(
    TaskOutboxEntry entry,
  ) {
    return TaskSyncTransport.process(entry);
  }
}
