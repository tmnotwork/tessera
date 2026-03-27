import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/actual_task.dart';
import '../models/inbox_task.dart';
import 'auth_service.dart';
import 'day_key_service.dart';
import 'network_manager.dart';
import 'sync_kpi.dart';
import 'task_batch_queue_store.dart';
import 'task_outbox_manager.dart';
import '../models/task_outbox_entry.dart';
import 'sync_all_history_service.dart';
import 'sync_context.dart';

/// タスクバッチ同期マネージャー
/// 短時間内の複数変更をまとめて効率的に同期
class TaskBatchSyncManager {
  static final TaskBatchSyncManager _instance =
      TaskBatchSyncManager._internal();
  factory TaskBatchSyncManager() => _instance;
  TaskBatchSyncManager._internal();

  // バッチ処理用のキュー
  static final Map<String, BatchSyncOperation> _pendingOperations = {};
  static Timer? _batchTimer;
  static bool _isProcessingBatch = false;

  // バッチ設定
  static const Duration _batchWindow = Duration(seconds: 5); // 5秒以内の変更をまとめる
  static const int _maxBatchSize = 50; // 最大50件まで一括処理
  static const Duration _maxWaitTime = Duration(seconds: 30); // 最大30秒で強制実行

  static String? _normalizeOrigin(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// ActualTaskのバッチ同期をスケジュール
  static void scheduleActualTaskBatch(ActualTask task, String operation,
      {String? origin}) {
    _scheduleBatchOperation(BatchSyncOperation(
      taskType: 'actual_task',
      taskId: task.id,
      taskData: task.toCloudJson(),
      operation: operation,
      timestamp: DateTime.now(),
      priority: _getOperationPriority(operation),
    ), origin: origin);
  }

  /// InboxTaskのバッチ同期をスケジュール
  static void scheduleInboxTaskBatch(InboxTask task, String operation,
      {String? origin}) {
    _scheduleBatchOperation(BatchSyncOperation(
      taskType: 'inbox_task',
      taskId: task.id,
      taskData: task.toCloudJson(),
      operation: operation,
      timestamp: DateTime.now(),
      priority: _getOperationPriority(operation),
    ), origin: origin);
  }

  /// バッチ操作をスケジュール
  static void _scheduleBatchOperation(BatchSyncOperation operation,
      {String? origin}) {
    final key =
        TaskBatchQueueStore.buildKey(operation.taskType, operation.taskId);
    final originTag =
        _normalizeOrigin(origin) ?? _normalizeOrigin(SyncContext.origin);
    final decorated = operation.copyWith(origin: originTag);

    final existing = _pendingOperations[key];
    if (existing != null) {
      final merged =
          TaskBatchQueueStore.mergeOperations(existing, decorated);
      _pendingOperations[key] = merged;
      unawaited(TaskBatchQueueStore.saveOrUpdate(key, merged));
    } else {
      _pendingOperations[key] = decorated;
      unawaited(TaskBatchQueueStore.saveOrUpdate(key, decorated));
    }

    // バッチタイマーをリセット
    _resetBatchTimer();

    // 即座実行が必要な操作の場合は短時間で実行
    if (operation.priority == BatchSyncPriority.immediate) {
      _resetBatchTimer(const Duration(seconds: 2));
    }

    // バッチサイズ制限チェック
    if (_pendingOperations.length >= _maxBatchSize) {
      _executeBatch();
    }
    try {
      unawaited(SyncAllHistoryService.recordSimpleEvent(
        type: 'taskBatchEnqueue',
        reason: 'task batch enqueue',
        origin: 'TaskBatchSyncManager.schedule',
        extra: <String, dynamic>{
          'taskType': decorated.taskType,
          'operation': decorated.operation,
          'taskId': decorated.taskId,
          'priority': decorated.priority.name,
          if (decorated.origin != null) 'triggerOrigin': decorated.origin,
          'pendingCount': _pendingOperations.length,
        },
      ));
    } catch (_) {}
  }

  /// バッチタイマーをリセット
  static void _resetBatchTimer([Duration? customWindow]) {
    _batchTimer?.cancel();

    final window = customWindow ?? _batchWindow;
    _batchTimer = Timer(window, () {
      if (_pendingOperations.isNotEmpty) {
        _executeBatch();
      }
    });
  }

  /// バッチを実行
  static Future<void> _executeBatch() async {
    if (_isProcessingBatch || _pendingOperations.isEmpty) return;

    _isProcessingBatch = true;
    _batchTimer?.cancel();
    final keys = List<String>.from(_pendingOperations.keys);
    String? historyId;
    try {
      final originCounts = <String, int>{};
      final byType = <String, int>{};
      for (final op in _pendingOperations.values) {
        final origin = op.origin ?? 'unknown';
        originCounts[origin] = (originCounts[origin] ?? 0) + 1;
        byType[op.taskType] = (byType[op.taskType] ?? 0) + 1;
      }
      historyId = await SyncAllHistoryService.recordEventStart(
        type: 'taskBatchCommit',
        reason: 'task batch commit',
        origin: 'TaskBatchSyncManager.executeBatch',
        extra: <String, dynamic>{
          'pendingCount': _pendingOperations.length,
          'byType': byType,
          'originCounts': originCounts,
        },
      );
    } catch (_) {}

    try {
      final startTime = DateTime.now();

      // 操作をタイプ別にグループ化
      final operationsByType = <String, List<BatchSyncOperation>>{};
      for (final operation in _pendingOperations.values) {
        operationsByType
            .putIfAbsent(operation.taskType, () => [])
            .add(operation);
      }

      int successCount = 0;
      int failedCount = 0;

      // タイプ別にバッチ処理実行
      for (final entry in operationsByType.entries) {
        try {
          await _executeBatchByType(entry.key, entry.value);
          successCount += entry.value.length;
        } catch (e) {
          print('❌ TaskBatch: Failed to execute batch for ${entry.key}: $e');
          await _fallbackOperations(entry.value);
          failedCount += entry.value.length;
        }
      }

      // Firebase使用量統計
      _logFirebaseUsage(successCount);
      try {
        if (historyId != null) {
          await SyncAllHistoryService.recordFinish(
            id: historyId!,
            success: failedCount == 0,
            extra: <String, dynamic>{
              'successCount': successCount,
              'failedCount': failedCount,
            },
          );
        }
      } catch (_) {}
    } catch (e) {
      print('❌ TaskBatch: Batch execution failed: $e');
      try {
        if (historyId != null) {
          await SyncAllHistoryService.recordFailed(
            id: historyId!,
            error: e.toString(),
          );
        }
      } catch (_) {}
    } finally {
      await TaskBatchQueueStore.removeMany(keys);
      _pendingOperations.clear();
      _isProcessingBatch = false;
    }
  }

  /// タイプ別バッチ実行
  static Future<void> _executeBatchByType(
      String taskType, List<BatchSyncOperation> operations) async {
    if (!NetworkManager.isOnline) {
      throw Exception('Network offline');
    }

    final userId = AuthService.getCurrentUserId();
    if (userId == null) {
      throw Exception('User not authenticated');
    }

    // Ensure timezone is ready before computing dayKeys/monthKeys.
    // If it fails, DayKeyService will fall back to UTC (still produces non-null keys).
    if (taskType == 'actual_task') {
      try {
        await DayKeyService.initialize();
      } catch (_) {}
    }

    // Firebase バッチライター
    final batch = FirebaseFirestore.instance.batch();
    final collectionName = _getCollectionName(taskType);
    final userCollection = FirebaseFirestore.instance
        .collection('users')
        .doc(userId)
        .collection(collectionName);

    final attempted = <BatchSyncOperation>[];
    int pendingWriteOps = 0;

    for (final operation in operations) {
      try {
        final docRef = operation.taskData['cloudId'] != null
            ? userCollection.doc(operation.taskData['cloudId'])
            : userCollection.doc(operation.taskId);

        // Safety: Avoid resurrecting logically deleted documents & state rollback
        // 事前GETは ActualTask の状態遷移（start/pause/complete）のみに限定
        final bool needsPrecheck = operation.taskType == 'actual_task' &&
            (operation.operation == 'start' ||
                operation.operation == 'pause' ||
                operation.operation == 'complete');
        if (needsPrecheck) {
          try {
            final snap =
                await docRef.get(const GetOptions(source: Source.server));
            try {
              SyncKpi.preWriteChecks += 1;
              SyncKpi.docGets += 1;
            } catch (_) {}
            if (snap.exists) {
              final data = snap.data() as Map<String, dynamic>;
              if ((data['isDeleted'] ?? false) == true) {
                // Skip this op to avoid resurrection
                continue;
              }
              // Prevent state rollback (completed > paused > running)
              int rank(int idx) {
                switch (idx) {
                  case 0: // running
                    return 0;
                  case 2: // paused
                    return 1;
                  case 1: // completed
                    return 2;
                  default:
                    return 0;
                }
              }

              final remoteStatusIdx =
                  (data['status'] is int) ? (data['status'] as int) : 0;
              final localStatusIdx = (operation.taskData['status'] is int)
                  ? (operation.taskData['status'] as int)
                  : 0;
              if (rank(remoteStatusIdx) > rank(localStatusIdx)) {
                continue;
              }
              // If same rank, prefer remote newer lastModified
              DateTime? remoteLm;
              final lmRaw = data['lastModified'];
              if (lmRaw is String) remoteLm = DateTime.tryParse(lmRaw);
              if (lmRaw is Timestamp) remoteLm = lmRaw.toDate();
              DateTime? localLm;
              final llmRaw = operation.taskData['lastModified'];
              if (llmRaw is String) localLm = DateTime.tryParse(llmRaw);
              if (remoteLm != null &&
                  localLm != null &&
                  remoteLm.isAfter(localLm)) {
                continue;
              }
            }
          } catch (_) {}
        }

        switch (operation.operation) {
          case 'create':
          case 'update':
          case 'start':
          case 'pause':
          case 'complete':
            // 作成・更新操作
            final data = taskType == 'actual_task'
                ? _buildActualTaskWriteMap(operation, docRef)
                : _buildDefaultWriteMap(operation, docRef);
            batch.set(docRef, data, SetOptions(merge: true));
            pendingWriteOps += 1;
            attempted.add(operation);
            break;

          case 'delete':
            // 論理削除
            batch.update(docRef, {
              'isDeleted': true,
              'lastModified': DateTime.now().toIso8601String(),
            });
            pendingWriteOps += 1;
            attempted.add(operation);
            break;

          default:
            print('⚠️ TaskBatch: Unknown operation: ${operation.operation}');
        }
      } catch (e) {
        print(
            '❌ TaskBatch: Failed to prepare operation ${operation.taskId}: $e');
      }
    }

    // バッチ実行
    try {
      await batch.commit().timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          throw TimeoutException(
              'Batch commit timeout', const Duration(seconds: 30));
        },
      );
      // KPI: Firestore writes (approx) for this batch commit
      try {
        SyncKpi.batchCommits += 1;
        SyncKpi.writes += pendingWriteOps;
      } catch (_) {}
    } catch (e) {
      await _fallbackOperations(attempted);
      rethrow;
    }

  }

  /// コレクション名を取得
  static String _getCollectionName(String taskType) {
    switch (taskType) {
      case 'actual_task':
        return 'actual_tasks';
      case 'inbox_task':
        return 'inbox_tasks';
      default:
        throw ArgumentError('Unknown task type: $taskType');
    }
  }

  /// 操作の優先度を決定
  static BatchSyncPriority _getOperationPriority(String operation) {
    switch (operation) {
      case 'start':
      case 'complete':
      case 'pause':
        return BatchSyncPriority.immediate;
      case 'create':
      case 'delete':
        return BatchSyncPriority.immediate;
      case 'update':
      default:
        return BatchSyncPriority.background;
    }
  }

  /// Firebase使用量をログ出力（将来の統計用に保持）
  static void _logFirebaseUsage(int operationCount) {}

  /// 強制バッチ実行
  static Future<void> forceExecuteBatch() async {
    await _executeBatch();
  }

  /// バッチ統計情報を取得
  static Map<String, dynamic> getBatchStatistics() {
    return {
      'pending_operations': _pendingOperations.length,
      'is_processing': _isProcessingBatch,
      'batch_window_seconds': _batchWindow.inSeconds,
      'max_batch_size': _maxBatchSize,
      'max_wait_time_seconds': _maxWaitTime.inSeconds,
    };
  }

  /// バッチキューをクリア
  static void clearBatchQueue() {
    _batchTimer?.cancel();
    _pendingOperations.clear();
    unawaited(TaskBatchQueueStore.clear());
  }

  /// バッチマネージャーを停止
  static void dispose() {
    _batchTimer?.cancel();
    _pendingOperations.clear();
    _isProcessingBatch = false;
  }

  /// 初期化
  static Future<void> initialize() async {
    await TaskBatchQueueStore.initialize();
    final persisted = await TaskBatchQueueStore.loadAll();
    if (persisted.isNotEmpty) {
      _pendingOperations
        ..clear()
        ..addAll(persisted);
      _resetBatchTimer();
    }

    // ネットワーク状態監視
    NetworkManager.connectivityStream.listen((isOnline) {
      if (isOnline && _pendingOperations.isNotEmpty) {
        _executeBatch();
      }
    });

    // 定期的な強制実行タイマー（安全装置）
    Timer.periodic(_maxWaitTime, (timer) {
      if (_pendingOperations.isNotEmpty && !_isProcessingBatch) {
        _executeBatch();
      }
    });
  }

  static Future<void> _fallbackOperations(
      List<BatchSyncOperation> operations) async {
    for (final operation in operations) {
      try {
        await TaskOutboxManager.enqueue(
          taskType: operation.taskType,
          localTaskId: operation.taskId,
          operation: operation.operation,
          payload: operation.taskData,
          priority: _mapOutboxPriority(operation.priority),
          cloudId: operation.taskData['cloudId'] as String?,
          origin: operation.origin,
        );
      } catch (e) {
        print(
            '❌ TaskBatch: Failed to fallback operation ${operation.taskId}: $e');
      }
    }
  }

  static TaskOutboxPriority _mapOutboxPriority(BatchSyncPriority priority) {
    switch (priority) {
      case BatchSyncPriority.immediate:
        return TaskOutboxPriority.immediate;
      case BatchSyncPriority.background:
        return TaskOutboxPriority.background;
      case BatchSyncPriority.normal:
        return TaskOutboxPriority.normal;
    }
  }

  static Map<String, dynamic> _buildDefaultWriteMap(
    BatchSyncOperation operation,
    DocumentReference docRef,
  ) {
    final data = Map<String, dynamic>.from(operation.taskData);
    // IMPORTANT:
    // `lastModified` は「ユーザーにとって意味のある更新」を表すメタデータ。
    // 送信/再送/バッチ化の都合で無条件に上書きすると、
    // - 実質内容が変わっていなくても差分同期が「更新あり」と判定され続ける
    // - ユーザー無操作でも更新扱いが増えて read/write が止まらない
    //
    // そのため、送信時は既存値を尊重し、欠損時のみ補完する。
    final lm = data['lastModified'];
    if (lm == null || (lm is String && lm.trim().isEmpty)) {
      data['lastModified'] = DateTime.now().toIso8601String();
    }
    data['needsSync'] = false;
    // cloudIdが未設定の場合は新規作成
    data['cloudId'] ??= docRef.id;
    return data;
  }

  /// Build Firestore write map for ActualTask with canonical fields.
  ///
  /// Why:
  /// - Some write paths (TaskBatch) used to write `toCloudJson()` directly, which
  ///   can omit canonical fields like `startAt/dayKeys/monthKeys`.
  /// - This would create missing-key documents in Firestore, forcing repeated
  ///   backfills and harming dayKeys-based sync.
  static Map<String, dynamic> _buildActualTaskWriteMap(
    BatchSyncOperation operation,
    DocumentReference docRef,
  ) {
    final raw = Map<String, dynamic>.from(operation.taskData);
    final task = ActualTask.fromJson(raw);
    task.cloudId ??= docRef.id;
    final map = task.toFirestoreWriteMap();
    // Align with existing TaskBatch behavior.
    map['cloudId'] ??= docRef.id;
    // Preserve `lastModified` (set only if missing).
    final lm = map['lastModified'];
    if (lm == null || (lm is String && lm.trim().isEmpty)) {
      map['lastModified'] = DateTime.now().toIso8601String();
    }
    map['needsSync'] = false;
    return map;
  }
}

/// バッチ同期操作
class BatchSyncOperation {
  final String taskType;
  final String taskId;
  final Map<String, dynamic> taskData;
  final String operation;
  final DateTime timestamp;
  final BatchSyncPriority priority;
  final String? origin;

  BatchSyncOperation({
    required this.taskType,
    required this.taskId,
    required this.taskData,
    required this.operation,
    required this.timestamp,
    required this.priority,
    this.origin,
  });

  BatchSyncOperation copyWith({
    Map<String, dynamic>? taskData,
    String? operation,
    DateTime? timestamp,
    BatchSyncPriority? priority,
    String? origin,
  }) {
    return BatchSyncOperation(
      taskType: taskType,
      taskId: taskId,
      taskData: taskData ?? this.taskData,
      operation: operation ?? this.operation,
      timestamp: timestamp ?? this.timestamp,
      priority: priority ?? this.priority,
      origin: origin ?? this.origin,
    );
  }
}

/// バッチ同期優先度
enum BatchSyncPriority {
  immediate, // 即座バッチ実行（2秒以内）
  normal, // 通常バッチ実行（5秒以内）
  background, // バックグラウンドバッチ実行（5秒以内）
}
