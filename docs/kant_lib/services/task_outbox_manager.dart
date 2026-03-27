import 'dart:async';
import 'dart:math';

import 'package:hive/hive.dart';

import '../models/task_outbox_entry.dart';
import '../utils/async_mutex.dart';
import 'actual_task_service.dart';
import 'inbox_task_service.dart';
import 'retry_scheduler.dart';
import 'task_id_link_repository.dart';
import 'task_sync_transport.dart';
import 'sync_all_history_service.dart';
import 'sync_context.dart';

/// タスク系操作のアウトボックス管理。
class TaskOutboxManager {
  static const _outboxBoxName = 'task_outbox';
  static const _metaBoxName = 'task_outbox_meta';
  static const _orderKeyField = 'orderCounter';
  static const _retryHandlerKey = 'task_outbox';
  static final AsyncMutex _mutationMutex = AsyncMutex();
  static final AsyncMutex _flushMutex = AsyncMutex();
  static final Random _random = Random();
  static final StreamController<List<TaskOutboxEntry>> _updatesController =
      StreamController<List<TaskOutboxEntry>>.broadcast();

  static bool _initialized = false;
  static Box<dynamic>? _outboxBox;
  static Box<dynamic>? _metaBox;
  static late TaskIdLinkRepository _idLinkRepository;
  static late RetryScheduler _retryScheduler;
  static TaskOutboxDispatcher? _dispatcher;

  /// スナップショット更新を購読するストリーム。
  static Stream<List<TaskOutboxEntry>> get updates => _updatesController.stream;

  static Future<void> initialize({
    TaskIdLinkRepository? idLinkRepository,
    RetryScheduler? retryScheduler,
  }) async {
    if (_initialized) {
      return;
    }
    _idLinkRepository = idLinkRepository ?? TaskIdLinkRepository.instance;
    _retryScheduler = retryScheduler ?? RetryScheduler();
    await _retryScheduler.initialize();
    _retryScheduler.registerHandler(
      _retryHandlerKey,
      (record) => RetryTask(
        id: record.id,
        execute: () async => await flush(),
        nextRunAt: record.nextRunAt,
        maxAttempts: record.maxAttempts,
        attempts: record.attempts,
        context: record.context,
        lifecycleScope: record.lifecycleScope,
        handlerKey: record.handlerKey,
      ),
    );
    _outboxBox ??= await Hive.openBox<dynamic>(_outboxBoxName);
    _metaBox ??= await Hive.openBox<dynamic>(_metaBoxName);
    _initialized = true;
    await _emitSnapshot();
    await _rehydrateRetryTasks();
  }

  static Future<TaskOutboxEntry> enqueue({
    required String taskType,
    required String localTaskId,
    required String operation,
    required Map<String, dynamic> payload,
    TaskOutboxPriority priority = TaskOutboxPriority.normal,
    String? cloudId,
    String? dedupeKey,
    String? origin,
  }) async {
    await _ensureInitialized();

    return _mutationMutex.protect(() async {
      String? normalizeOrigin(String? value) {
        if (value == null) return null;
        final trimmed = value.trim();
        return trimmed.isEmpty ? null : trimmed;
      }
      final originTag =
          normalizeOrigin(origin) ?? normalizeOrigin(SyncContext.origin);
      final resolvedCloudId =
          cloudId ?? await _idLinkRepository.lookup(localTaskId);
      final orderKey = await _nextOrderKey();
      final entry = TaskOutboxEntry(
        entryId: _generateEntryId(),
        taskType: taskType,
        localTaskId: localTaskId,
        operation: operation,
        payload: payload,
        timestamp: DateTime.now(),
        priority: priority,
        cloudId: resolvedCloudId,
        dedupeKey: dedupeKey,
        orderKey: orderKey,
        dependencyKey: '$taskType:$localTaskId',
        origin: originTag,
      );

      if (dedupeKey != null) {
        await _removeByDedupeKey(dedupeKey);
      }

      await _outboxBox!.put(entry.entryId, entry.toMap());
      await _outboxBox!.flush();
      await _emitSnapshot();
      try {
        await SyncAllHistoryService.recordSimpleEvent(
          type: 'outboxEnqueue',
          reason: 'task outbox enqueue',
          origin: 'TaskOutboxManager.enqueue',
          extra: <String, dynamic>{
            'entryId': entry.entryId,
            'taskType': taskType,
            'operation': operation,
            'localTaskId': localTaskId,
            if (resolvedCloudId != null) 'cloudId': resolvedCloudId,
            if (dedupeKey != null) 'dedupeKey': dedupeKey,
            'priority': priority.name,
            if (originTag != null) 'triggerOrigin': originTag,
          },
        );
      } catch (_) {}
      return entry;
    });
  }

  static Future<List<TaskOutboxEntry>> snapshot({DateTime? until}) async {
    await _ensureInitialized();
    final entries = _outboxBox!.values
        .whereType<Map>()
        .map((raw) => TaskOutboxEntry.fromMap(raw))
        .toList(growable: false)
      ..sort((a, b) => a.orderKey.compareTo(b.orderKey));
    if (until == null) {
      return entries;
    }
    return entries
        .where(
          (entry) =>
              entry.nextRetryAt == null || !entry.nextRetryAt!.isAfter(until),
        )
        .toList(growable: false);
  }

  static Future<void> markSuccess(String entryId) async {
    await _ensureInitialized();
    await _mutationMutex.protect(() async {
      await _outboxBox!.delete(entryId);
      await _outboxBox!.flush();
      await _retryScheduler.cancel(_retryTaskId(entryId));
      await _emitSnapshot();
    });
  }

  static Future<void> markRetry(String entryId, {String? lastError}) async {
    await _ensureInitialized();
    await _mutationMutex.protect(() async {
      final raw = _outboxBox!.get(entryId);
      if (raw is! Map) {
        return;
      }
      var entry = TaskOutboxEntry.fromMap(raw);
      final attempts = entry.attempts + 1;
      final nextRetryAt = _calculateNextRetryAt(attempts);
      entry = entry.copyWith(
        attempts: attempts,
        nextRetryAt: nextRetryAt,
        lastError: lastError ?? entry.lastError,
      );
      await _outboxBox!.put(entryId, entry.toMap());
      await _outboxBox!.flush();
      await _registerRetryTask(entry);
      await _emitSnapshot();
    });
  }

  static Future<void> updateCloudId(String localTaskId, String cloudId) async {
    await _ensureInitialized();
    await _mutationMutex.protect(() async {
      final updates = <String, Map<String, dynamic>>{};
      for (final key in _outboxBox!.keys) {
        final raw = _outboxBox!.get(key);
        if (raw is! Map) continue;
        final entry = TaskOutboxEntry.fromMap(raw);
        if (entry.localTaskId != localTaskId) continue;
        final updated = entry.copyWith(cloudId: cloudId);
        updates[key.toString()] = updated.toMap();
      }
      for (final entry in updates.entries) {
        await _outboxBox!.put(entry.key, entry.value);
      }
      if (updates.isNotEmpty) {
        await _outboxBox!.flush();
        await _emitSnapshot();
      }
    });
  }

  static void configureDispatcher(TaskOutboxDispatcher dispatcher) {
    _dispatcher = dispatcher;
  }

  static Future<void> flush({TaskOutboxDispatcher? dispatcher}) async {
    await _ensureInitialized();
    final TaskOutboxDispatcher? effectiveDispatcher = dispatcher ?? _dispatcher;
    if (effectiveDispatcher == null) {
      throw StateError('TaskOutboxDispatcher is not configured.');
    }

    await _flushMutex.protect(() async {
      final now = DateTime.now();
      final entries = await snapshot();
      final Map<String, List<TaskOutboxEntry>> chains =
          <String, List<TaskOutboxEntry>>{};

      for (final entry in entries) {
        chains
            .putIfAbsent(entry.dependencyKey, () => <TaskOutboxEntry>[])
            .add(entry);
      }

      final List<TaskOutboxEntry> readyEntries = <TaskOutboxEntry>[];

      for (final queue in chains.values) {
        queue.sort((a, b) => a.orderKey.compareTo(b.orderKey));
        if (queue.isEmpty) {
          continue;
        }
        final TaskOutboxEntry head = queue.first;
        if (head.nextRetryAt != null && head.nextRetryAt!.isAfter(now)) {
          await _registerRetryTask(head);
          continue;
        }
        readyEntries.add(head);
      }

      for (final entry in readyEntries) {
        try {
          final result = await effectiveDispatcher(entry);
          if (result.success) {
            if (result.cloudId != null && result.cloudId!.isNotEmpty) {
              await _idLinkRepository.updateLink(
                  entry.localTaskId, result.cloudId!);
              await updateCloudId(entry.localTaskId, result.cloudId!);
            }
            await markSuccess(entry.entryId);
          } else {
            if (result.permanentFailure) {
              await markSuccess(entry.entryId);
            } else {
              await markRetry(entry.entryId, lastError: result.errorMessage);
            }
          }
        } catch (error) {
          await markRetry(entry.entryId, lastError: error.toString());
        }
      }
    });
  }

  static Future<void> seedLinksFromLocalData() async {
    await _ensureInitialized();
    int seeded = 0;

    Future<void> seedActualTasks() async {
      try {
        await ActualTaskService.initialize();
      } catch (_) {}
      try {
        final tasks = ActualTaskService.getAllActualTasks();
        for (final task in tasks) {
          if (task.cloudId != null && task.cloudId!.isNotEmpty) {
            await _idLinkRepository.updateLink(task.id, task.cloudId!);
            seeded++;
          } else {
            await _idLinkRepository.registerLocalOnly(task.id);
          }
        }
      } catch (e) {
        print('⚠️ TaskOutboxManager: Failed to seed actual task links: $e');
      }
    }

    Future<void> seedInboxTasks() async {
      try {
        await InboxTaskService.initialize();
      } catch (_) {}
      try {
        final tasks = InboxTaskService.getAllInboxTasks();
        for (final task in tasks) {
          if (task.cloudId != null && task.cloudId!.isNotEmpty) {
            await _idLinkRepository.updateLink(task.id, task.cloudId!);
            seeded++;
          } else {
            await _idLinkRepository.registerLocalOnly(task.id);
          }
        }
      } catch (e) {
        print('⚠️ TaskOutboxManager: Failed to seed inbox task links: $e');
      }
    }

    await seedActualTasks();
    await seedInboxTasks();

  }

  static Future<void> clear() async {
    await _ensureInitialized();
    await _mutationMutex.protect(() async {
      await _outboxBox!.clear();
      await _outboxBox!.flush();
      await _emitSnapshot();
    });
  }

  static Future<void> dispose() async {
    await _mutationMutex.protect(() async {
      if (_initialized) {
        await _outboxBox?.close();
        await _metaBox?.close();
      }
      _retryScheduler.dispose();
      _updatesController.close();
      _initialized = false;
      _outboxBox = null;
      _metaBox = null;
    });
  }

  static Future<void> _emitSnapshot() async {
    if (!_updatesController.hasListener) {
      return;
    }
    final current = await snapshot();
    _updatesController.add(current);
  }

  static Future<void> _removeByDedupeKey(String dedupeKey) async {
    final keysToRemove = <dynamic>[];
    for (final key in _outboxBox!.keys) {
      final raw = _outboxBox!.get(key);
      if (raw is! Map) continue;
      final entry = TaskOutboxEntry.fromMap(raw);
      if (entry.dedupeKey == dedupeKey) {
        keysToRemove.add(key);
      }
    }
    for (final key in keysToRemove) {
      await _outboxBox!.delete(key);
    }
  }

  static Future<int> _nextOrderKey() async {
    final current = (_metaBox?.get(_orderKeyField) as int?) ?? 0;
    final next = current + 1;
    await _metaBox?.put(_orderKeyField, next);
    return next;
  }

  static DateTime _calculateNextRetryAt(int attempts) {
    const schedule = <Duration>[
      Duration(minutes: 1),
      Duration(minutes: 5),
      Duration(minutes: 15),
      Duration(minutes: 30),
    ];
    if (attempts <= schedule.length) {
      return DateTime.now().add(schedule[attempts - 1]);
    }
    final multiplier = attempts - schedule.length + 1;
    return DateTime.now().add(schedule.last * multiplier);
  }

  static Future<void> _ensureInitialized() async {
    if (_initialized) return;
    await initialize();
  }

  static String _generateEntryId() {
    final timestamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    // 1 << 32 はDart/JSでは0になりnextInt(0)がRangeErrorになるため、定数で指定する
    const maxRandom = 0xFFFFFFFF; // 2^32 - 1
    final random = _random.nextInt(maxRandom).toRadixString(36);
    return 'toe_${timestamp}_$random';
  }

  static String _retryTaskId(String entryId) => 'task_outbox:$entryId';

  static Future<void> _rehydrateRetryTasks() async {
    final entries = await snapshot();
    final now = DateTime.now();
    for (final entry in entries) {
      if (entry.nextRetryAt != null && entry.nextRetryAt!.isAfter(now)) {
        await _registerRetryTask(entry);
      }
    }
  }

  static Future<void> _registerRetryTask(TaskOutboxEntry entry) async {
    final next = entry.nextRetryAt ?? DateTime.now();
    await _retryScheduler.registerOrUpdate(
      RetryTask(
        id: _retryTaskId(entry.entryId),
        execute: () async {
          await flush();
        },
        nextRunAt: next.isAfter(DateTime.now()) ? next : DateTime.now(),
        attempts: entry.attempts,
        lifecycleScope: RetryTaskLifecycleScope.persisted,
        handlerKey: _retryHandlerKey,
      ),
    );
  }
}
