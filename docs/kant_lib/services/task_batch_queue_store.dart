import 'package:hive/hive.dart';

import 'task_batch_sync_manager.dart';

/// 永続的にバッチ操作を保持する簡易ストア。
class TaskBatchQueueStore {
  static const String _boxName = 'task_batch_queue';
  static Box<dynamic>? _box;
  static bool _initialized = false;

  static Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    _box = await Hive.openBox<dynamic>(_boxName);
    _initialized = true;
  }

  static Future<void> saveOrUpdate(
      String key, BatchSyncOperation operation) async {
    if (!_initialized) {
      await initialize();
    }
    final existingRaw = _box!.get(key);
    if (existingRaw is Map) {
      final existing = _fromMap(existingRaw);
      final merged = mergeOperations(existing, operation);
      await _box!.put(key, _toMap(merged));
      return;
    }
    await _box!.put(key, _toMap(operation));
  }

  static String buildKey(String taskType, String taskId) =>
      '$taskType:$taskId';

  static Future<void> remove(String key) async {
    if (!_initialized) {
      await initialize();
    }
    await _box!.delete(key);
  }

  static Future<void> removeMany(Iterable<String> keys) async {
    if (!_initialized) {
      await initialize();
    }
    await _box!.deleteAll(keys);
  }

  static Future<Map<String, BatchSyncOperation>> loadAll() async {
    if (!_initialized) {
      await initialize();
    }
    final result = <String, BatchSyncOperation>{};
    for (final dynamic key in _box!.keys) {
      final raw = _box!.get(key);
      if (key is! String || raw is! Map) {
        continue;
      }
      try {
        result[key] = _fromMap(raw);
      } catch (_) {}
    }
    return result;
  }

  static Future<void> clear() async {
    if (!_initialized) {
      await initialize();
    }
    await _box!.clear();
  }

  static Map<String, dynamic> _toMap(BatchSyncOperation operation) {
    return <String, dynamic>{
      'taskType': operation.taskType,
      'taskId': operation.taskId,
      'operation': operation.operation,
      'taskData': operation.taskData,
      'timestamp': operation.timestamp.toIso8601String(),
      'priority': operation.priority.name,
      'origin': operation.origin,
    };
  }

  static BatchSyncOperation _fromMap(Map<dynamic, dynamic> raw) {
    DateTime timestamp;
    final ts = raw['timestamp'];
    if (ts is DateTime) {
      timestamp = ts;
    } else if (ts is String) {
      timestamp = DateTime.tryParse(ts) ?? DateTime.now();
    } else if (ts is int) {
      timestamp = DateTime.fromMillisecondsSinceEpoch(ts);
    } else {
      timestamp = DateTime.now();
    }

    BatchSyncPriority priority;
    final priorityName = raw['priority'] as String?;
    priority = BatchSyncPriority.values.firstWhere(
      (value) => value.name == priorityName,
      orElse: () => BatchSyncPriority.background,
    );

    final taskDataRaw = raw['taskData'];
    Map<String, dynamic> taskData = <String, dynamic>{};
    if (taskDataRaw is Map) {
      taskData = taskDataRaw.map(
        (key, value) => MapEntry(key.toString(), value),
      );
    }

    return BatchSyncOperation(
      taskType: raw['taskType'] as String,
      taskId: raw['taskId'] as String,
      taskData: taskData,
      operation: raw['operation'] as String,
      timestamp: timestamp,
      priority: priority,
      origin: raw['origin'] as String?,
    );
  }

  static BatchSyncOperation mergeOperations(
      BatchSyncOperation existing, BatchSyncOperation next) {
    final previous = existing.operation;
    final incoming = next.operation;
    final mergedOrigin = existing.origin ?? next.origin;

    if (incoming == 'delete') {
      return _createDelete(existing, next);
    }
    if (previous == 'delete') {
      return existing;
    }
    if (previous == 'create' && incoming == 'delete') {
      return _createDelete(existing, next);
    }
    if (previous == 'create' && incoming == 'update') {
      final mergedData = _mergeTaskData(existing.taskData, next.taskData);
      return existing.copyWith(
        taskData: mergedData,
        timestamp: next.timestamp,
        priority: _maxPriority(existing.priority, next.priority),
        origin: mergedOrigin,
      );
    }
    if (previous == 'update' && incoming == 'delete') {
      return _createDelete(existing, next);
    }
    if (previous == 'update' && incoming == 'update') {
      final mergedData = _mergeTaskData(existing.taskData, next.taskData);
      return existing.copyWith(
        taskData: mergedData,
        timestamp: next.timestamp,
        priority: _maxPriority(existing.priority, next.priority),
        origin: mergedOrigin,
      );
    }

    final mergedData = _mergeTaskData(existing.taskData, next.taskData);
    return next.copyWith(
      taskData: mergedData,
      priority: _maxPriority(existing.priority, next.priority),
      origin: mergedOrigin,
    );
  }

  static BatchSyncPriority _maxPriority(
      BatchSyncPriority a, BatchSyncPriority b) {
    return a.index >= b.index ? a : b;
  }

  static Map<String, dynamic> _mergeTaskData(
      Map<String, dynamic> previous, Map<String, dynamic> incoming) {
    final merged = <String, dynamic>{}
      ..addAll(previous)
      ..addAll(incoming);
    final previousCloudId = previous['cloudId'];
    if (previousCloudId is String && previousCloudId.isNotEmpty) {
      merged['cloudId'] = previousCloudId;
    }
    return merged;
  }

  static BatchSyncOperation _createDelete(
      BatchSyncOperation existing, BatchSyncOperation next) {
    final mergedData = _mergeTaskData(existing.taskData, next.taskData);
    return existing.copyWith(
      taskData: mergedData,
      operation: 'delete',
      timestamp: next.timestamp,
      priority: _maxPriority(existing.priority, next.priority),
      origin: existing.origin ?? next.origin,
    );
  }

  static String _resolveOperation(String previous, String next) {
    if (previous == 'create' && next == 'update') {
      return 'create';
    }
    if (previous == 'update' && next == 'update') {
      return 'update';
    }
    return next;
  }
}
