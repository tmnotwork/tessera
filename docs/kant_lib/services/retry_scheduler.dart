import 'dart:async';

import 'package:hive/hive.dart';

enum RetryTaskLifecycleScope { foregroundOnly, persisted }

typedef RetryTaskCallback = Future<void> Function();

class RetryTask {
  RetryTask({
    required this.id,
    required this.execute,
    required this.nextRunAt,
    this.maxAttempts = 5,
    this.attempts = 0,
    this.context,
    this.lifecycleScope = RetryTaskLifecycleScope.foregroundOnly,
    this.handlerKey,
  });

  final String id;
  final RetryTaskCallback execute;
  DateTime nextRunAt;
  final int maxAttempts;
  int attempts;
  final Map<String, dynamic>? context;
  final RetryTaskLifecycleScope lifecycleScope;
  final String? handlerKey;
}

class RetryTaskRecord {
  RetryTaskRecord({
    required this.id,
    required this.nextRunAt,
    required this.maxAttempts,
    required this.attempts,
    required this.lifecycleScope,
    this.context,
    this.handlerKey,
  });

  final String id;
  final DateTime nextRunAt;
  final int maxAttempts;
  final int attempts;
  final Map<String, dynamic>? context;
  final RetryTaskLifecycleScope lifecycleScope;
  final String? handlerKey;

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'id': id,
      'nextRunAt': nextRunAt.toIso8601String(),
      'maxAttempts': maxAttempts,
      'attempts': attempts,
      'context': context,
      'lifecycleScope': lifecycleScope.name,
      'handlerKey': handlerKey,
    };
  }

  static RetryTaskRecord fromMap(Map<dynamic, dynamic> raw) {
    final scopeName = raw['lifecycleScope'] as String? ??
        RetryTaskLifecycleScope.foregroundOnly.name;
    final scope = RetryTaskLifecycleScope.values.firstWhere(
      (value) => value.name == scopeName,
      orElse: () => RetryTaskLifecycleScope.foregroundOnly,
    );
    final nextRunAtRaw = raw['nextRunAt'];
    DateTime nextRunAt;
    if (nextRunAtRaw is DateTime) {
      nextRunAt = nextRunAtRaw;
    } else if (nextRunAtRaw is String) {
      nextRunAt = DateTime.tryParse(nextRunAtRaw) ?? DateTime.now();
    } else if (nextRunAtRaw is int) {
      nextRunAt = DateTime.fromMillisecondsSinceEpoch(nextRunAtRaw);
    } else {
      nextRunAt = DateTime.now();
    }
    final contextRaw = raw['context'];
    Map<String, dynamic>? context;
    if (contextRaw is Map) {
      context = contextRaw.map(
        (key, value) => MapEntry(key.toString(), value),
      );
    }
    return RetryTaskRecord(
      id: raw['id'] as String,
      nextRunAt: nextRunAt,
      maxAttempts: (raw['maxAttempts'] as int?) ?? 5,
      attempts: (raw['attempts'] as int?) ?? 0,
      context: context,
      lifecycleScope: scope,
      handlerKey: raw['handlerKey'] as String?,
    );
  }
}

typedef RetryTaskFactory = RetryTask Function(RetryTaskRecord record);

/// 永続化対応の再試行スケジューラ。
class RetryScheduler {
  RetryScheduler();

  static const _boxName = 'retry_scheduler';

  final Map<String, RetryTask> _tasks = <String, RetryTask>{};
  final Map<String, RetryTaskFactory> _factories = <String, RetryTaskFactory>{};

  Timer? _timer;
  bool _isExecuting = false;
  bool _initialized = false;
  Box<dynamic>? _box;

  Future<void> initialize() async {
    if (_initialized) return;
    _box = await Hive.openBox<dynamic>(_boxName);
    _initialized = true;
  }

  void registerHandler(String key, RetryTaskFactory factory) {
    _factories[key] = factory;
  }

  Future<void> registerOrUpdate(RetryTask task) async {
    await initialize();
    _tasks[task.id] = task;
    await _persistTask(task);
    _rescheduleTimer();
  }

  Future<void> cancel(String taskId) async {
    await initialize();
    _tasks.remove(taskId);
    await _box?.delete(taskId);
    _rescheduleTimer();
  }

  Future<void> rehydrateFromPersistence() async {
    await initialize();
    if (_box == null || _box!.isEmpty) {
      _rescheduleTimer();
      return;
    }
    for (final key in _box!.keys) {
      final raw = _box!.get(key);
      if (raw is! Map) continue;
      final record = RetryTaskRecord.fromMap(raw);
      final handlerKey = record.handlerKey;
      if (handlerKey == null) {
        continue;
      }
      final factory = _factories[handlerKey];
      if (factory == null) {
        continue;
      }
      final task = factory(record);
      _tasks[task.id] = task;
    }
    _rescheduleTimer();
  }

  void dispose() {
    _timer?.cancel();
    _tasks.clear();
    _factories.clear();
    _box?.close();
    _box = null;
    _initialized = false;
  }

  Future<void> _persistTask(RetryTask task) async {
    if (_box == null) return;
    final record = RetryTaskRecord(
      id: task.id,
      nextRunAt: task.nextRunAt,
      maxAttempts: task.maxAttempts,
      attempts: task.attempts,
      context: task.context,
      lifecycleScope: task.lifecycleScope,
      handlerKey: task.handlerKey,
    );
    await _box!.put(task.id, record.toMap());
  }

  void _rescheduleTimer() {
    _timer?.cancel();
    if (_tasks.isEmpty) {
      return;
    }
    final now = DateTime.now();
    final nextTask = _tasks.values.reduce((a, b) {
      return a.nextRunAt.isBefore(b.nextRunAt) ? a : b;
    });
    final duration = nextTask.nextRunAt.isAfter(now)
        ? nextTask.nextRunAt.difference(now)
        : Duration.zero;
    _timer = Timer(duration, _executeDueTasks);
  }

  Future<void> _executeDueTasks() async {
    if (_isExecuting) {
      return;
    }
    _isExecuting = true;
    try {
      final now = DateTime.now();
      final dueTasks = _tasks.values
          .where((task) => !task.nextRunAt.isAfter(now))
          .toList(growable: false);
      for (final task in dueTasks) {
        await _runTask(task);
      }
    } finally {
      _isExecuting = false;
      _rescheduleTimer();
    }
  }

  Future<void> _runTask(RetryTask task) async {
    try {
      await task.execute();
      _tasks.remove(task.id);
      await _box?.delete(task.id);
    } catch (_) {
      task.attempts += 1;
      if (task.attempts >= task.maxAttempts) {
        _tasks.remove(task.id);
        await _box?.delete(task.id);
        return;
      }
      final backoffMinutes = <int>[1, 5, 15, 30, 60];
      final index = task.attempts - 1;
      final minutes = index < backoffMinutes.length
          ? backoffMinutes[index]
          : backoffMinutes.last * (index - backoffMinutes.length + 2);
      task.nextRunAt = DateTime.now().add(Duration(minutes: minutes));
      await _persistTask(task);
    }
  }

  /// すべてのリトライタスクをクリア
  static Future<void> clearAll() async {
    try {
      final box = await Hive.openBox<dynamic>(_boxName);
      await box.clear();
    } catch (_) {}
  }
}
