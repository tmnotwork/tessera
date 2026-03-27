import '../models/actual_task.dart';
import '../models/inbox_task.dart';
import '../models/task_outbox_entry.dart';
import 'auth_service.dart';
import 'actual_task_service.dart';
import 'actual_task_sync_service.dart';
import 'data_sync_service.dart';
import 'inbox_task_sync_service.dart';
import 'inbox_version_service.dart';
import 'sync_all_history_service.dart';
import 'sync_failure_notifier.dart';
import 'sync_context.dart';
import '../utils/kant_inbox_trace.dart';

/// アウトボックスエントリを Firebase へ送信する際の結果。
class TaskSyncTransportResult {
  const TaskSyncTransportResult({
    required this.success,
    this.cloudId,
    this.shouldDelete = false,
    this.permanentFailure = false,
    this.errorMessage,
    this.uploadOutcome,
  });

  final bool success;
  final String? cloudId;
  final bool shouldDelete;
  final bool permanentFailure;
  final String? errorMessage;
  // 実行結果の内訳（アップロードOutcomeがある場合のみ）
  final UploadOutcome? uploadOutcome;

  TaskSyncTransportResult copyWith({
    bool? success,
    String? cloudId,
    bool? shouldDelete,
    bool? permanentFailure,
    String? errorMessage,
    UploadOutcome? uploadOutcome,
  }) {
    return TaskSyncTransportResult(
      success: success ?? this.success,
      cloudId: cloudId ?? this.cloudId,
      shouldDelete: shouldDelete ?? this.shouldDelete,
      permanentFailure: permanentFailure ?? this.permanentFailure,
      errorMessage: errorMessage ?? this.errorMessage,
      uploadOutcome: uploadOutcome ?? this.uploadOutcome,
    );
  }

  static const successResult = TaskSyncTransportResult(success: true);
  static TaskSyncTransportResult failure({
    String? errorMessage,
    bool permanent = false,
    UploadOutcome? uploadOutcome,
  }) {
    return TaskSyncTransportResult(
      success: false,
      errorMessage: errorMessage,
      permanentFailure: permanent,
      uploadOutcome: uploadOutcome,
    );
  }
}

typedef TaskOutboxDispatcher = Future<TaskSyncTransportResult> Function(
  TaskOutboxEntry entry,
);

class TaskSyncTransport {
  static Future<TaskSyncTransportResult> process(TaskOutboxEntry entry) async {
    switch (entry.taskType) {
      case 'actual_task':
        final task =
            ActualTask.fromJson(Map<String, dynamic>.from(entry.payload));
        task.cloudId ??= entry.cloudId;
        return await syncActualTask(
          task,
          entry.operation,
          outboxEntryId: entry.entryId,
          outboxOrigin: entry.origin,
        );
      case 'inbox_task':
        final task =
            InboxTask.fromJson(Map<String, dynamic>.from(entry.payload));
        task.cloudId ??= entry.cloudId;
        return await syncInboxTask(
          task,
          entry.operation,
          outboxEntryId: entry.entryId,
          outboxOrigin: entry.origin,
        );
      default:
        return TaskSyncTransportResult.failure(
          errorMessage: 'Unknown task type: ${entry.taskType}',
          permanent: true,
        );
    }
  }

  static Future<TaskSyncTransportResult> syncActualTask(
      ActualTask task, String operation,
      {String? outboxEntryId, String? outboxOrigin}) async {
    final syncService = ActualTaskSyncService();
    String? historyId;
    try {
      String? uid;
      try {
        uid = AuthService.getCurrentUserId();
      } catch (_) {
        uid = null;
      }
      historyId = await SyncAllHistoryService.recordEventStart(
        type: 'cloudWrite',
        reason: 'syncActualTask',
        origin: 'TaskSyncTransport.syncActualTask',
        userId: uid,
        includeKpiSnapshot: false,
        extra: <String, dynamic>{
          'collection': 'actual_tasks',
          'taskType': 'actual_task',
          'operation': operation,
          'localTaskId': task.id,
          'cloudId': task.cloudId,
          if (outboxEntryId != null) 'outboxEntryId': outboxEntryId,
          if (outboxOrigin != null) 'outboxOrigin': outboxOrigin,
          if (SyncContext.origin != null)
            'triggerOrigin': SyncContext.origin,
        },
      );
    } catch (_) {}
    try {
      if (operation == 'delete') {
        await _deleteActualTask(task, syncService);
        final res = TaskSyncTransportResult(
          success: true,
          cloudId: task.cloudId,
          uploadOutcome: UploadOutcome.written,
        );
        try {
          if (historyId != null) {
            await SyncAllHistoryService.recordFinish(id: historyId, success: true);
          }
        } catch (_) {}
        return res;
      }

      final upload =
          await syncService.uploadToFirebaseWithOutcome(task);
      final outcome = upload.outcome;
      final resolvedCloudId = upload.cloudId ?? task.cloudId;
      if (resolvedCloudId != null && resolvedCloudId.isNotEmpty) {
        task.cloudId = resolvedCloudId;
      }

      if (outcome == UploadOutcome.written) {
        if (!upload.localApplied) {
          await ActualTaskService.updateActualTask(task);
        }
        final res = TaskSyncTransportResult(
          success: true,
          cloudId: task.cloudId,
          uploadOutcome: outcome,
        );
        try {
          if (historyId != null) {
            await SyncAllHistoryService.recordFinish(
              id: historyId,
              success: true,
              extra: <String, dynamic>{
                'uploadOutcome': outcome.name,
                'cloudId': task.cloudId,
              },
            );
          }
        } catch (_) {}
        return res;
      }

      if (outcome == UploadOutcome.skippedRemoteNewerAdopted ||
          outcome == UploadOutcome.skippedRemoteDeleted) {
        if (!upload.localApplied) {
          if (upload.adoptedRemote != null) {
            await ActualTaskService.updateActualTaskPreservingLastModified(
                upload.adoptedRemote!);
          } else if (outcome == UploadOutcome.skippedRemoteDeleted) {
            try {
              task.isDeleted = true;
              await ActualTaskService.updateActualTaskPreservingLastModified(
                  task);
            } catch (_) {}
          }
        }
        return TaskSyncTransportResult(
          success: false,
          permanentFailure: true,
          cloudId: task.cloudId,
          uploadOutcome: outcome,
          errorMessage: outcome == UploadOutcome.skippedRemoteDeleted
              ? 'Remote deletion detected'
              : 'Remote newer/adopted; upload skipped',
        );
      }

      return TaskSyncTransportResult.failure(
        errorMessage: 'Upload failed',
        uploadOutcome: outcome,
      );
    } catch (e) {
      final res = TaskSyncTransportResult.failure(
        errorMessage: e.toString(),
        uploadOutcome: UploadOutcome.failed,
      );
      try {
        if (historyId != null) {
          await SyncAllHistoryService.recordFailed(id: historyId, error: e.toString());
        }
      } catch (_) {}
      SyncFailureNotifier.show(
        'クラウド反映に失敗しました（再送待ち）。「同期/読取 履歴」で詳細を確認できます。',
        key: 'cloudWrite:actual_task',
      );
      return res;
    }
  }

  static Future<void> _deleteActualTask(
      ActualTask task, ActualTaskSyncService syncService) async {
    try {
      if (task.cloudId != null && task.cloudId!.isNotEmpty) {
        await syncService.deleteFromFirebase(task.cloudId!);
      } else {
        bool deleted = false;
        try {
          await syncService.deleteFromFirebase(task.id);
          deleted = true;
        } catch (_) {}
        if (!deleted && task.cloudId != null && task.cloudId!.isNotEmpty) {
          try {
            await syncService.deleteFromFirebase(task.cloudId!);
            deleted = true;
          } catch (_) {}
        }
        if (!deleted) {
          await syncService.ensureRemoteLogicalDelete(task);
        }
      }
      await ActualTaskService.deleteActualTask(task.id);
    } catch (e) {
      await ActualTaskService.addActualTask(task);
      rethrow;
    }
  }

  static Future<TaskSyncTransportResult> syncInboxTask(
      InboxTask task, String operation,
      {String? outboxEntryId, String? outboxOrigin}) async {
    final syncService = InboxTaskSyncService();
    String? historyId;
    try {
      String? uid;
      try {
        uid = AuthService.getCurrentUserId();
      } catch (_) {
        uid = null;
      }
      historyId = await SyncAllHistoryService.recordEventStart(
        type: 'cloudWrite',
        reason: 'syncInboxTask',
        origin: 'TaskSyncTransport.syncInboxTask',
        userId: uid,
        includeKpiSnapshot: false,
        extra: <String, dynamic>{
          'collection': 'inbox_tasks',
          'taskType': 'inbox_task',
          'operation': operation,
          'localTaskId': task.id,
          'cloudId': task.cloudId,
          'isCompleted': task.isCompleted,
          'isSomeday': task.isSomeday,
          if (outboxEntryId != null) 'outboxEntryId': outboxEntryId,
          if (outboxOrigin != null) 'outboxOrigin': outboxOrigin,
          if (SyncContext.origin != null)
            'triggerOrigin': SyncContext.origin,
        },
      );
    } catch (_) {}
    try {
      if (task.isSomeday == true) {
        _logSomedaySync('request', operation, task);
      }
      switch (operation) {
        case 'create':
        case 'update':
          final upload = await syncService.uploadToFirebaseWithOutcome(task);
          if (upload.cloudId != null && upload.cloudId!.isNotEmpty) {
            task.cloudId = upload.cloudId;
          }
          if (upload.outcome != UploadOutcome.written) {
            final msg = 'Upload skipped: ${upload.outcome.name}';
            // skippedRemoteNewerAdopted / skippedRemoteDeleted はリモートが権威を持ち
            // ローカルへの反映も完了している「解決済み」状態。実際の失敗ではない。
            final isResolved =
                upload.outcome == UploadOutcome.skippedRemoteNewerAdopted ||
                upload.outcome == UploadOutcome.skippedRemoteDeleted;
            print(
                '[InboxUpload] syncInboxTask result=${isResolved ? 'resolved' : 'failure'} taskId=${task.id} cloudId=${task.cloudId} outcome=${upload.outcome.name}',
            );
            kantInboxTrace(
              'transport_upload_not_written',
              'taskId=${task.id} outcome=${upload.outcome.name} resolved=$isResolved blockId=${task.blockId} v=${task.version}',
            );
            try {
              if (historyId != null) {
                if (isResolved) {
                  await SyncAllHistoryService.recordFinish(
                    id: historyId,
                    success: true,
                    extra: <String, dynamic>{'uploadOutcome': upload.outcome.name},
                  );
                } else {
                  await SyncAllHistoryService.recordFailed(id: historyId, error: msg);
                }
              }
            } catch (_) {}
            if (!isResolved) {
              SyncFailureNotifier.show(
                'クラウド反映に失敗しました（再送待ち）。「同期/読取 履歴」で詳細を確認できます。',
                key: 'cloudWrite:inbox_task',
              );
            }
            return TaskSyncTransportResult.failure(
              errorMessage: msg,
              permanent: isResolved,
              uploadOutcome: upload.outcome,
            );
          }
          kantInboxTrace(
            'transport_upload_written',
            'taskId=${task.id} cloudId=${task.cloudId} blockId=${task.blockId} v=${task.version}',
          );
          await _bumpInboxVersion(task);
          break;
        case 'delete':
          await _deleteInboxTask(task, syncService);
          await _bumpInboxVersion(task);
          break;
        default:
          final upload = await syncService.uploadToFirebaseWithOutcome(task);
          if (upload.cloudId != null && upload.cloudId!.isNotEmpty) {
            task.cloudId = upload.cloudId;
          }
          if (upload.outcome != UploadOutcome.written) {
            final msg = 'Upload skipped: ${upload.outcome.name}';
            final isResolved =
                upload.outcome == UploadOutcome.skippedRemoteNewerAdopted ||
                upload.outcome == UploadOutcome.skippedRemoteDeleted;
            print(
                '[InboxUpload] syncInboxTask result=${isResolved ? 'resolved' : 'failure'} taskId=${task.id} cloudId=${task.cloudId} outcome=${upload.outcome.name}',
            );
            kantInboxTrace(
              'transport_upload_not_written',
              'taskId=${task.id} outcome=${upload.outcome.name} resolved=$isResolved blockId=${task.blockId} v=${task.version}',
            );
            try {
              if (historyId != null) {
                if (isResolved) {
                  await SyncAllHistoryService.recordFinish(
                    id: historyId,
                    success: true,
                    extra: <String, dynamic>{'uploadOutcome': upload.outcome.name},
                  );
                } else {
                  await SyncAllHistoryService.recordFailed(id: historyId, error: msg);
                }
              }
            } catch (_) {}
            if (!isResolved) {
              SyncFailureNotifier.show(
                'クラウド反映に失敗しました（再送待ち）。「同期/読取 履歴」で詳細を確認できます。',
                key: 'cloudWrite:inbox_task',
              );
            }
            return TaskSyncTransportResult.failure(
              errorMessage: msg,
              permanent: isResolved,
              uploadOutcome: upload.outcome,
            );
          }
          kantInboxTrace(
            'transport_upload_written',
            'taskId=${task.id} cloudId=${task.cloudId} blockId=${task.blockId} v=${task.version}',
          );
          await _bumpInboxVersion(task);
      }
      if (task.isSomeday == true) {
        _logSomedaySync('success', operation, task);
        await _verifySomedayRemote(syncService, task, operation);
      }
      final res = TaskSyncTransportResult(
        success: true,
        cloudId: task.cloudId,
      );
      try {
        if (historyId != null) {
          await SyncAllHistoryService.recordFinish(
            id: historyId,
            success: true,
            extra: <String, dynamic>{
              'cloudId': task.cloudId,
            },
          );
        }
      } catch (_) {}
      return res;
    } catch (e) {
      print(
          '[InboxUpload] syncInboxTask result=exception taskId=${task.id} error=$e',
      );
      if (task.isSomeday == true) {
        _logSomedaySync('error', operation, task, error: e.toString());
      }
      try {
        if (historyId != null) {
          await SyncAllHistoryService.recordFailed(id: historyId, error: e.toString());
        }
      } catch (_) {}
      SyncFailureNotifier.show(
        'クラウド反映に失敗しました（再送待ち）。「同期/読取 履歴」で詳細を確認できます。',
        key: 'cloudWrite:inbox_task',
      );
      return TaskSyncTransportResult.failure(
        errorMessage: e.toString(),
        uploadOutcome: UploadOutcome.failed,
      );
    }
  }

  static Future<void> _deleteInboxTask(
      InboxTask task, InboxTaskSyncService syncService) async {
    if (task.cloudId != null && task.cloudId!.isNotEmpty) {
      await syncService.deleteFromFirebase(task.cloudId!);
      return;
    }
    bool deleted = false;
    try {
      await syncService.deleteFromFirebase(task.id);
      deleted = true;
    } catch (_) {}
    if (!deleted && task.cloudId != null && task.cloudId!.isNotEmpty) {
      await syncService.deleteFromFirebase(task.cloudId!);
      deleted = true;
    }
    if (!deleted) {
      await InboxTaskSyncService().ensureRemoteLogicalDelete(task);
    }
  }

  static Future<void> _bumpInboxVersion(InboxTask task) async {
    try {
      await InboxVersionService.bump();
    } catch (_) {}
  }

  static void _logSomedaySync(String stage, String operation, InboxTask task,
      {String? error}) {
    final cloud = task.cloudId?.isNotEmpty == true ? task.cloudId : '(pending)';
    final msg =
        '🌙 InboxSomedaySync[$stage][$operation] id=${task.id} cloudId=$cloud version=${task.version} lastModified=${task.lastModified.toIso8601String()}';
    if (error != null && error.isNotEmpty) {
      print('$msg error=$error');
    } else {
      print(msg);
    }
  }

  static Future<void> _verifySomedayRemote(
      InboxTaskSyncService syncService, InboxTask task, String operation) async {
    final cloudId = task.cloudId;
    if (cloudId == null || cloudId.isEmpty) {
      _logSomedaySync('verify-skip', operation, task,
          error: 'cloudId missing');
      return;
    }
    try {
      final remote = await syncService.downloadItemFromFirebase(cloudId);
      final flag = remote?.isSomeday == true;
      final remoteLm =
          remote?.lastModified.toIso8601String() ?? '(null lastModified)';
      print(
          '🌙 InboxSomedaySync[remote][$operation] id=${task.id} cloudId=$cloudId remoteIsSomeday=$flag remoteLastModified=$remoteLm');
    } catch (e) {
      _logSomedaySync('verify-error', operation, task, error: e.toString());
    }
  }

}
