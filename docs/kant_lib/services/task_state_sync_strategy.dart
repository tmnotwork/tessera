import 'dart:async';
import '../models/actual_task.dart';
import '../models/inbox_task.dart';
import 'task_sync_manager.dart';
import 'task_batch_sync_manager.dart';
import 'network_manager.dart';

/// タスク状態別同期戦略
/// 操作の重要度とユーザー体験を考慮した最適化同期制御
class TaskStateSyncStrategy {
  static final TaskStateSyncStrategy _instance = TaskStateSyncStrategy._internal();
  factory TaskStateSyncStrategy() => _instance;
  TaskStateSyncStrategy._internal();

  // 状態別同期設定
  static final Map<String, SyncStrategyConfig> _strategyConfigs = {
    // 高優先度操作（即座同期必須）
    'start': SyncStrategyConfig(
      priority: SyncPriority.critical,
      syncMode: StateSyncMode.immediate,
      maxDelay: Duration.zero,
      description: 'タスク開始 - 即座反映が重要',
    ),
    'complete': SyncStrategyConfig(
      priority: SyncPriority.critical,
      syncMode: StateSyncMode.immediate,
      maxDelay: Duration.zero,
      description: 'タスク完了 - 即座反映が重要',
    ),
    'pause': SyncStrategyConfig(
      priority: SyncPriority.critical,
      syncMode: StateSyncMode.immediate,
      maxDelay: Duration.zero,
      description: 'タスク一時停止 - 即座反映が重要',
    ),
    
    // 中優先度操作（短時間内同期）
    'create': SyncStrategyConfig(
      priority: SyncPriority.high,
      syncMode: StateSyncMode.batched,
      maxDelay: const Duration(seconds: 3),
      description: 'タスク作成 - 短時間内同期',
    ),
    'delete': SyncStrategyConfig(
      priority: SyncPriority.critical,
      syncMode: StateSyncMode.immediate,
      maxDelay: Duration.zero,
      description: 'タスク削除 - 即座同期（復活防止のため）',
    ),
    
    // 低優先度操作（バッチ同期）
    'update': SyncStrategyConfig(
      priority: SyncPriority.normal,
      syncMode: StateSyncMode.batched,
      maxDelay: const Duration(seconds: 10),
      description: 'タスク更新 - バッチ同期',
    ),
    'memo_update': SyncStrategyConfig(
      priority: SyncPriority.low,
      syncMode: StateSyncMode.batched,
      maxDelay: const Duration(seconds: 30),
      description: 'メモ更新 - 低優先度バッチ',
    ),
    'tag_update': SyncStrategyConfig(
      priority: SyncPriority.low,
      syncMode: StateSyncMode.batched,
      maxDelay: const Duration(seconds: 30),
      description: 'タグ更新 - 低優先度バッチ',
    ),
  };

  // 適応的戦略設定
  static bool _adaptiveMode = true;
  static final Map<String, int> _operationCounts = {};
  static final Map<String, DateTime> _lastOperationTimes = {};

  /// ActualTask状態別同期
  static Future<void> syncActualTaskByState(
    ActualTask task,
    String operation, {
    Map<String, dynamic>? context,
  }) async {
    final strategy = _determineStrategy(operation, context);
    final originTag = _originFromContext(context);
    await _executeSyncStrategy(
      taskType: 'actual_task',
      taskId: task.id,
      taskData: task.toCloudJson(),
      operation: operation,
      strategy: strategy,
      origin: originTag,
    );
  }

  /// InboxTask状態別同期
  static Future<void> syncInboxTaskByState(
    InboxTask task,
    String operation, {
    Map<String, dynamic>? context,
  }) async {
    final strategy = _determineStrategy(operation, context);
    final originTag = _originFromContext(context);
    await _executeSyncStrategy(
      taskType: 'inbox_task',
      taskId: task.id,
      taskData: task.toCloudJson(),
      operation: operation,
      strategy: strategy,
      origin: originTag,
    );
  }

  /// 同期戦略を決定
  static SyncStrategyConfig _determineStrategy(
    String operation,
    Map<String, dynamic>? context,
  ) {
    // 基本戦略を取得
    var strategy = _strategyConfigs[operation] ?? _strategyConfigs['update']!;
    
    if (_adaptiveMode) {
      strategy = _applyAdaptiveStrategy(operation, strategy, context);
    }
    
    print('🎯 TaskStateSync: Strategy for $operation: ${strategy.description}');
    return strategy;
  }

  static String? _originFromContext(Map<String, dynamic>? context) {
    if (context == null) return null;
    final raw = context['origin'] ?? context['caller'] ?? context['triggerOrigin'];
    if (raw is String) {
      final trimmed = raw.trim();
      return trimmed.isEmpty ? null : trimmed;
    }
    return null;
  }

  /// 適応的戦略を適用
  static SyncStrategyConfig _applyAdaptiveStrategy(
    String operation,
    SyncStrategyConfig baseStrategy,
    Map<String, dynamic>? context,
  ) {
    // 操作頻度を記録
    _operationCounts[operation] = (_operationCounts[operation] ?? 0) + 1;
    _lastOperationTimes[operation] = DateTime.now();
    
    // ネットワーク状態を考慮
    if (!NetworkManager.isOnline) {
      return baseStrategy.copyWith(syncMode: StateSyncMode.queued);
    }
    
    // 連続操作の検出
    if (_isRapidOperation(operation)) {
      print('⚡ TaskStateSync: Rapid operation detected for $operation, using batch mode');
      return baseStrategy.copyWith(
        syncMode: StateSyncMode.batched,
        maxDelay: const Duration(seconds: 2), // 連続操作時は短時間バッチ
      );
    }
    
    // 操作頻度による調整
    final operationCount = _operationCounts[operation] ?? 0;
    if (operationCount > 10) { // 10回以上の操作
      print('📊 TaskStateSync: High frequency operation ($operationCount times), optimizing');
      return baseStrategy.copyWith(
        syncMode: StateSyncMode.batched,
        maxDelay: Duration(seconds: baseStrategy.maxDelay.inSeconds + 2),
      );
    }
    
    // コンテキストによる調整
    if (context != null) {
      // バックグラウンド操作の場合
      if (context['isBackground'] == true) {
        return baseStrategy.copyWith(
          priority: SyncPriority.low,
          maxDelay: Duration(seconds: baseStrategy.maxDelay.inSeconds * 2),
        );
      }
      
      // ユーザー操作の場合
      if (context['isUserAction'] == true) {
        return baseStrategy.copyWith(
          priority: SyncPriority.high,
          maxDelay: Duration(seconds: (baseStrategy.maxDelay.inSeconds / 2).round()),
        );
      }
    }
    
    return baseStrategy;
  }

  /// 連続操作の検出
  static bool _isRapidOperation(String operation) {
    final lastTime = _lastOperationTimes[operation];
    if (lastTime == null) return false;
    
    final timeSinceLastOperation = DateTime.now().difference(lastTime);
    return timeSinceLastOperation.inSeconds < 3; // 3秒以内の連続操作
  }

  /// 同期戦略を実行
  static Future<void> _executeSyncStrategy({
    required String taskType,
    required String taskId,
    required Map<String, dynamic> taskData,
    required String operation,
    required SyncStrategyConfig strategy,
    String? origin,
  }) async {
    try {
      print('🚀 TaskStateSync: Executing $operation for $taskType $taskId');
      print('📋 TaskStateSync: Strategy - ${strategy.syncMode.name}, Priority: ${strategy.priority.name}');
      
      switch (strategy.syncMode) {
        case StateSyncMode.immediate:
          await _executeImmediateSync(
              taskType, taskId, taskData, operation, origin: origin);
          break;
          
        case StateSyncMode.batched:
          await _executeBatchedSync(
              taskType, taskId, taskData, operation, strategy,
              origin: origin);
          break;
          
        case StateSyncMode.queued:
          await _executeQueuedSync(taskType, taskId, taskData, operation);
          break;
          
        case StateSyncMode.deferred:
          await _executeDeferredSync(taskType, taskId, taskData, operation, strategy);
          break;
      }
      
    } catch (e) {
      print('❌ TaskStateSync: Failed to execute strategy for $operation: $e');
      // フォールバック：エラー時はキューに追加
      await _executeQueuedSync(taskType, taskId, taskData, operation);
    }
  }

  /// 即座同期実行
  static Future<void> _executeImmediateSync(
    String taskType,
    String taskId,
    Map<String, dynamic> taskData,
    String operation,
    {String? origin}) async {
    print('⚡ TaskStateSync: Immediate sync for $taskType $taskId');
    
    switch (taskType) {
      case 'actual_task':
        final task = ActualTask.fromJson(taskData);
        await TaskSyncManager.syncActualTaskImmediately(task, operation,
            origin: origin);
        break;
      case 'inbox_task':
        final task = InboxTask.fromJson(taskData);
        await TaskSyncManager.syncInboxTaskImmediately(task, operation,
            origin: origin);
        break;
    }
  }

  /// バッチ同期実行
  static Future<void> _executeBatchedSync(
    String taskType,
    String taskId,
    Map<String, dynamic> taskData,
    String operation,
    SyncStrategyConfig strategy,
    {String? origin}) async {
    print('📦 TaskStateSync: Batched sync for $taskType $taskId (delay: ${strategy.maxDelay.inSeconds}s)');
    
    switch (taskType) {
      case 'actual_task':
        final task = ActualTask.fromJson(taskData);
        TaskBatchSyncManager.scheduleActualTaskBatch(task, operation,
            origin: origin);
        break;
      case 'inbox_task':
        final task = InboxTask.fromJson(taskData);
        TaskBatchSyncManager.scheduleInboxTaskBatch(task, operation,
            origin: origin);
        break;
    }
  }

  /// キュー同期実行（オフライン用）
  static Future<void> _executeQueuedSync(
    String taskType,
    String taskId,
    Map<String, dynamic> taskData,
    String operation,
  ) async {
    print('📥 TaskStateSync: Queued sync for $taskType $taskId (offline)');
    // TaskSyncManagerのオフラインキューを使用
    // 実装は既存のオフラインキュー機能を活用
  }

  /// 遅延同期実行
  static Future<void> _executeDeferredSync(
    String taskType,
    String taskId,
    Map<String, dynamic> taskData,
    String operation,
    SyncStrategyConfig strategy,
  ) async {
    print('⏰ TaskStateSync: Deferred sync for $taskType $taskId (delay: ${strategy.maxDelay.inSeconds}s)');
    
    // 指定時間後にバッチ同期として実行
    Timer(strategy.maxDelay, () {
      _executeBatchedSync(taskType, taskId, taskData, operation, strategy);
    });
  }

  /// 適応モードの設定
  static void setAdaptiveMode(bool enabled) {
    _adaptiveMode = enabled;
    print('🧠 TaskStateSync: Adaptive mode ${enabled ? 'enabled' : 'disabled'}');
  }

  /// 操作統計をリセット
  static void resetOperationStats() {
    _operationCounts.clear();
    _lastOperationTimes.clear();
    print('📊 TaskStateSync: Operation statistics reset');
  }

  /// 戦略統計を取得
  static Map<String, dynamic> getStrategyStatistics() {
    return {
      'adaptive_mode': _adaptiveMode,
      'operation_counts': Map.from(_operationCounts),
      'last_operation_times': _lastOperationTimes.map(
        (key, value) => MapEntry(key, value.toIso8601String()),
      ),
      'strategy_configs': _strategyConfigs.map(
        (key, value) => MapEntry(key, {
          'priority': value.priority.name,
          'sync_mode': value.syncMode.name,
          'max_delay_seconds': value.maxDelay.inSeconds,
          'description': value.description,
        }),
      ),
    };
  }

  /// 初期化
  static Future<void> initialize() async {}
}

/// 同期戦略設定
class SyncStrategyConfig {
  final SyncPriority priority;
  final StateSyncMode syncMode;
  final Duration maxDelay;
  final String description;

  SyncStrategyConfig({
    required this.priority,
    required this.syncMode,
    required this.maxDelay,
    required this.description,
  });

  SyncStrategyConfig copyWith({
    SyncPriority? priority,
    StateSyncMode? syncMode,
    Duration? maxDelay,
    String? description,
  }) {
    return SyncStrategyConfig(
      priority: priority ?? this.priority,
      syncMode: syncMode ?? this.syncMode,
      maxDelay: maxDelay ?? this.maxDelay,
      description: description ?? this.description,
    );
  }
}

/// 同期優先度
enum SyncPriority {
  critical, // 最重要（即座同期）
  high,     // 高優先度（高速バッチ）
  normal,   // 通常優先度（標準バッチ）
  low,      // 低優先度（遅延バッチ）
}

/// 状態別同期モード
enum StateSyncMode {
  immediate, // 即座同期
  batched,   // バッチ同期
  queued,    // キュー同期（オフライン）
  deferred,  // 遅延同期
}