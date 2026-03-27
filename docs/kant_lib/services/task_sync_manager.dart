import 'dart:async';

import '../models/actual_task.dart';
import '../models/inbox_task.dart';
import '../models/task_outbox_entry.dart';
import 'network_manager.dart';
import 'task_batch_sync_manager.dart';
import 'task_outbox_manager.dart';
import 'task_sync_entry_point.dart';
import 'task_sync_runtime.dart';
import 'task_sync_transport.dart';
import 'sync_context.dart';
import '../utils/kant_inbox_trace.dart';

/// タスク専用リアルタイム同期マネージャー
/// 1日30回の高頻度書き込みに最適化
class TaskSyncManager {
  static final TaskSyncManager _instance = TaskSyncManager._internal();
  factory TaskSyncManager() => _instance;
  TaskSyncManager._internal();

  // オフラインキュー
  static int _offlineQueueCount = 0;
  static bool _isProcessingQueue = false;
  static StreamSubscription<List<TaskOutboxEntry>>? _outboxSubscription;

  // 同期モード設定
  static TaskSyncMode _syncMode = TaskSyncMode.hybrid;

  /// 同一 InboxTask（ローカル `id`）に対する即時アップロードを直列化する。
  /// `unawaited` で呼んでも Firestore への書き込みは 1 本ずつ（呼び出し順）になり、
  /// preflight→set の隙間に別 Upload が割り込む Lost Update を同一端末内で抑える。
  /// キーは **cloudId ではなく id**（初回書き込みで cloudId が付いてもキューが分岐しないように）。
  static final Map<String, Future<void>> _inboxImmediateSyncChain = {};

  static int _inboxImmediateSyncTraceSeq = 0;

  static String? _normalizeOrigin(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static Future<T> _runWithOriginIfAny<T>(
    String? origin,
    Future<T> Function() fn,
  ) {
    final tag = _normalizeOrigin(origin);
    if (tag == null) return fn();
    return SyncContext.runWithOriginIfAbsent(tag, fn);
  }

  /// 同期モードを設定
  static void setSyncMode(TaskSyncMode mode) {
    _syncMode = mode;
  }

  /// 現在の同期モードを取得
  static TaskSyncMode getSyncMode() => _syncMode;

  /// ActualTask専用即座同期
  static Future<void> syncActualTaskImmediately(
      ActualTask task, String operation,
      {String? origin}) async {
    try {
      final originTag =
          _normalizeOrigin(origin) ?? _normalizeOrigin(SyncContext.origin);

      if (NetworkManager.isOnline) {
        // 同期モードに応じて処理を分岐
        switch (_syncMode) {
          case TaskSyncMode.immediate:
            // 即座同期
            await _performImmediateSync(task, operation, origin: originTag);
            break;
          case TaskSyncMode.batch:
            // バッチ同期
            TaskBatchSyncManager.scheduleActualTaskBatch(task, operation,
                origin: originTag);
            break;
          case TaskSyncMode.hybrid:
            // ハイブリッド：重要操作は即座、その他はバッチ
            if (_isHighPriorityOperation(operation)) {
              await _performImmediateSync(task, operation, origin: originTag);
            } else {
              TaskBatchSyncManager.scheduleActualTaskBatch(task, operation,
                  origin: originTag);
            }
            break;
        }
      } else {
        // オフライン時はキューに追加
        final pending = await _addToOfflineQueue(TaskSyncOperation(
          taskType: 'actual_task',
          taskId: task.id,
          taskData: task.toCloudJson(),
          operation: operation,
          timestamp: DateTime.now(),
          priority: _getOperationPriority(operation),
        ), origin: originTag);
      }
    } catch (e) {
      print('❌ TaskSync: Failed sync for ActualTask ${task.id}: $e');
      // エラー時もオフラインキューに追加
      final originTag =
          _normalizeOrigin(origin) ?? _normalizeOrigin(SyncContext.origin);
      final pending = await _addToOfflineQueue(TaskSyncOperation(
        taskType: 'actual_task',
        taskId: task.id,
        taskData: task.toCloudJson(),
        operation: operation,
        timestamp: DateTime.now(),
        priority: TaskSyncPriority.normal,
      ), origin: originTag);
    }
  }

  /// InboxTask専用即座同期
  ///
  /// 同一タスク id に対しては内部で直列化する。呼び出し側は UI を止めず `unawaited` でもよい。
  static Future<void> syncInboxTaskImmediately(
      InboxTask task, String operation,
      {String? origin}) {
    final key = task.id;
    if (key.isEmpty) {
      return _runInboxImmediateSyncBody(task, operation, origin);
    }
    final previous =
        _inboxImmediateSyncChain[key] ?? Future<void>.value();
    // 先行タスクが失敗してもキューを詰まらせない
    final chained = previous.then(
      (_) => _runInboxImmediateSyncBody(task, operation, origin),
      onError: (_, __) => _runInboxImmediateSyncBody(task, operation, origin),
    );
    _inboxImmediateSyncChain[key] = chained;
    chained.whenComplete(() {
      if (identical(_inboxImmediateSyncChain[key], chained)) {
        _inboxImmediateSyncChain.remove(key);
      }
    });
    return chained;
  }

  static Future<void> _runInboxImmediateSyncBody(
    InboxTask task,
    String operation,
    String? origin,
  ) async {
    final seq = ++_inboxImmediateSyncTraceSeq;
    kantInboxTrace(
      'inbox_immediate_sync_begin',
      'seq=$seq id=${task.id} op=$operation v=${task.version} blockId=${task.blockId} cloudId=${task.cloudId} online=${NetworkManager.isOnline}',
    );
    try {
      final originTag =
          _normalizeOrigin(origin) ?? _normalizeOrigin(SyncContext.origin);

      if (NetworkManager.isOnline) {
        await _performInboxTaskSync(task, operation, origin: originTag);
      } else {
        await _addToOfflineQueue(TaskSyncOperation(
          taskType: 'inbox_task',
          taskId: task.id,
          taskData: task.toCloudJson(),
          operation: operation,
          timestamp: DateTime.now(),
          priority: _getOperationPriority(operation),
        ), origin: originTag);
      }
      kantInboxTrace(
        'inbox_immediate_sync_ok',
        'seq=$seq id=${task.id} op=$operation',
      );
    } catch (e) {
      print('❌ TaskSync: Failed immediate sync for InboxTask ${task.id}: $e');
      kantInboxTrace(
        'inbox_immediate_sync_catch',
        'seq=$seq id=${task.id} err=$e',
      );
      final originTag =
          _normalizeOrigin(origin) ?? _normalizeOrigin(SyncContext.origin);
      await _addToOfflineQueue(TaskSyncOperation(
        taskType: 'inbox_task',
        taskId: task.id,
        taskData: task.toCloudJson(),
        operation: operation,
        timestamp: DateTime.now(),
        priority: TaskSyncPriority.normal,
      ), origin: originTag);
    }
  }

  /// 実際の同期処理（ActualTask）
  static Future<void> _performImmediateSync(
      ActualTask task, String operation,
      {String? origin}) async {
    final result = await _runWithOriginIfAny(
      origin,
      () => TaskSyncEntryPoint.syncActualTask(task, operation),
    );
    if (!result.success) {
      await _addToOfflineQueue(TaskSyncOperation(
        taskType: 'actual_task',
        taskId: task.id,
        taskData: task.toCloudJson(),
        operation: operation,
        timestamp: DateTime.now(),
        priority: TaskSyncPriority.normal,
      ), origin: origin);
      throw Exception(result.errorMessage ?? 'Failed to sync actual task');
    }
  }

  /// InboxTask同期処理
  static Future<void> _performInboxTaskSync(
      InboxTask task, String operation,
      {String? origin}) async {
    final result = await _runWithOriginIfAny(
      origin,
      () => TaskSyncEntryPoint.syncInboxTask(task, operation),
    );
    if (!result.success) {
      // 競合解決済み（リモートがローカルに採用済み）はエラーではなく正常終了。
      // アウトボックスへの追加もリトライも不要。
      if (result.permanentFailure) return;
      await _addToOfflineQueue(TaskSyncOperation(
        taskType: 'inbox_task',
        taskId: task.id,
        taskData: task.toCloudJson(),
        operation: operation,
        timestamp: DateTime.now(),
        priority: TaskSyncPriority.normal,
      ), origin: origin);
      throw Exception(result.errorMessage ?? 'Failed to sync inbox task');
    }
  }

  /// オフラインキューに追加
  static Future<int> _addToOfflineQueue(
    TaskSyncOperation operation, {
    String? origin,
  }) async {
    await TaskOutboxManager.enqueue(
      taskType: operation.taskType,
      localTaskId: operation.taskId,
      operation: operation.operation,
      payload: operation.taskData,
      priority: _mapOutboxPriority(operation.priority),
      origin: origin,
    );
    final snapshot = await TaskOutboxManager.snapshot();
    _offlineQueueCount = snapshot.length;
    if (NetworkManager.isOnline) {
      unawaited(processOfflineQueue());
    }
    return _offlineQueueCount;
  }

  /// オンライン復帰時のキュー処理
  static Future<void> processOfflineQueue() async {
    if (_isProcessingQueue || _offlineQueueCount == 0) return;
    _isProcessingQueue = true;
    try {
      await TaskOutboxManager.flush();
    } finally {
      _isProcessingQueue = false;
    }
  }

  /// キューされた操作を処理
  static Future<void> _processQueuedOperation(
      TaskSyncOperation operation) async {
    switch (operation.taskType) {
      case 'actual_task':
        final task = ActualTask.fromJson(operation.taskData);
        await _performImmediateSync(task, operation.operation);
        break;
      case 'inbox_task':
        final task = InboxTask.fromJson(operation.taskData);
        await _performInboxTaskSync(task, operation.operation);
        break;
    }
  }

  /// 操作の優先度を決定
  static TaskSyncPriority _getOperationPriority(String operation) {
    switch (operation) {
      case 'start':
      case 'complete':
      case 'pause':
        return TaskSyncPriority.immediate;
      case 'create':
      case 'delete':
        return TaskSyncPriority.immediate;
      case 'update':
      default:
        return TaskSyncPriority.background;
    }
  }

  /// 高優先度操作かどうか判定
  static bool _isHighPriorityOperation(String operation) {
    return _getOperationPriority(operation) == TaskSyncPriority.immediate;
  }

  static TaskOutboxPriority _mapOutboxPriority(TaskSyncPriority priority) {
    switch (priority) {
      case TaskSyncPriority.immediate:
        return TaskOutboxPriority.immediate;
      case TaskSyncPriority.normal:
        return TaskOutboxPriority.high;
      case TaskSyncPriority.background:
        return TaskOutboxPriority.background;
    }
  }

  static Future<TaskSyncTransportResult> _handleOutboxEntry(
      TaskOutboxEntry entry) {
    return TaskSyncEntryPoint.syncOutboxEntry(entry);
  }

  /// オフラインキューの状態取得
  static int getOfflineQueueSize() => _offlineQueueCount;

  /// オフラインキューをクリア
  static Future<void> clearOfflineQueue() async {
    await TaskOutboxManager.clear();
    _offlineQueueCount = 0;
  }

  /// ネットワーク状態変更リスナー設定
  static Future<void> initialize() async {
    await TaskSyncRuntime.initialize();
    TaskOutboxManager.configureDispatcher(_handleOutboxEntry);
    _outboxSubscription?.cancel();
    _outboxSubscription = TaskOutboxManager.updates.listen((entries) async {
      _offlineQueueCount = entries.length;
      if (NetworkManager.isOnline && entries.isNotEmpty) {
        unawaited(processOfflineQueue());
      }
    });
    final existing = await TaskOutboxManager.snapshot();
    _offlineQueueCount = existing.length;

    NetworkManager.connectivityStream.listen((isOnline) {
      if (isOnline && _offlineQueueCount > 0) {
        // オンライン復帰時にキュー処理
        unawaited(processOfflineQueue());
      }
    });

    // バッチマネージャーを初期化
    await TaskBatchSyncManager.initialize();

    if (NetworkManager.isOnline && _offlineQueueCount > 0) {
      unawaited(processOfflineQueue());
    }
  }
}

/// タスク同期操作
class TaskSyncOperation {
  final String taskType;
  final String taskId;
  final Map<String, dynamic> taskData;
  final String operation;
  final DateTime timestamp;
  TaskSyncPriority priority;

  TaskSyncOperation({
    required this.taskType,
    required this.taskId,
    required this.taskData,
    required this.operation,
    required this.timestamp,
    required this.priority,
  });
}

/// タスク同期優先度
enum TaskSyncPriority {
  immediate, // 即座同期（開始・完了・一時停止）
  normal, // 通常同期（作成・削除）
  background, // バックグラウンド同期（更新・メモ等）
}

/// タスク同期モード
enum TaskSyncMode {
  immediate, // 全て即座同期（高レスポンス、高通信量）
  batch, // 全てバッチ同期（低通信量、レスポンス遅延）
  hybrid, // ハイブリッド（重要操作は即座、その他はバッチ）
}
