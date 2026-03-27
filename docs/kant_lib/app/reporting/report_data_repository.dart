import 'dart:async';
import 'dart:collection';

import 'package:hive/hive.dart';

import '../../models/actual_task.dart';
import '../../models/block.dart';
import '../../services/actual_task_service.dart';
import '../../services/auth_service.dart';
import '../../services/block_service.dart';

class DailyReportData {
  DailyReportData({
    required this.actualMinutesByProject,
    required this.plannedMinutesByProject,
  });

  final Map<String, int> actualMinutesByProject;
  final Map<String, int> plannedMinutesByProject;
}

class WeeklyReportData {
  WeeklyReportData({
    required this.start,
    required this.end,
    required this.actualByDayProject,
    required this.plannedByDayProject,
    required this.weeklyActualTotals,
    required this.weeklyPlannedTotals,
  });

  final DateTime start;
  final DateTime end;
  final Map<DateTime, Map<String, int>> actualByDayProject;
  final Map<DateTime, Map<String, int>> plannedByDayProject;
  final Map<String, int> weeklyActualTotals;
  final Map<String, int> weeklyPlannedTotals;
}

class MonthlyWeekBucket {
  MonthlyWeekBucket({
    required this.start,
    required this.end,
    required this.plannedMinutes,
    required this.actualMinutes,
  });

  final DateTime start;
  final DateTime end;
  final int plannedMinutes;
  final int actualMinutes;
}

class MonthlyReportData {
  MonthlyReportData({
    required this.monthStart,
    required this.monthEnd,
    required this.weekBuckets,
    required this.plannedByProject,
    required this.actualByProject,
  });

  final DateTime monthStart;
  final DateTime monthEnd;
  final List<MonthlyWeekBucket> weekBuckets;
  final Map<String, int> plannedByProject;
  final Map<String, int> actualByProject;
}

class MonthlyAggregate {
  MonthlyAggregate({
    required this.plannedMinutes,
    required this.actualMinutes,
  });

  final int plannedMinutes;
  final int actualMinutes;
}

class YearlyReportData {
  YearlyReportData({
    required this.yearStart,
    required this.yearEnd,
    required this.monthlyAggregates,
    required this.plannedByProject,
    required this.actualByProject,
  });

  final DateTime yearStart;
  final DateTime yearEnd;
  final List<MonthlyAggregate> monthlyAggregates;
  final Map<String, int> plannedByProject;
  final Map<String, int> actualByProject;
}

class ReportDataRepository {
  ReportDataRepository._() {
    // Keep compatibility: some call paths only emit coarse "updated" signals.
    _subscriptions
        .add(ActualTaskService.updateStream.listen(_handleCoarseSourceChange));
    _subscriptions.add(BlockService.updateStream.listen(_handleCoarseSourceChange));
    _ensureInitialized();
  }

  static final ReportDataRepository instance = ReportDataRepository._();

  final _changesController = StreamController<void>.broadcast();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  StreamSubscription<BoxEvent>? _taskBoxSub;
  StreamSubscription<BoxEvent>? _blockBoxSub;

  // Cache (per current user)
  bool _initialized = false;
  String _cachedUserId = '';
  final Map<String, ActualTask> _tasksById = <String, ActualTask>{};
  final Map<String, Block> _blocksById = <String, Block>{};

  // Aggregates: day -> (projectId -> minutes)
  final Map<DateTime, Map<String, int>> _actualByDayProject =
      <DateTime, Map<String, int>>{};
  final Map<DateTime, Map<String, int>> _plannedByDayProject =
      <DateTime, Map<String, int>>{};

  // Totals per day (fast month/week bucketing)
  final Map<DateTime, int> _actualTotalByDay = <DateTime, int>{};
  final Map<DateTime, int> _plannedTotalByDay = <DateTime, int>{};

  // Dedupe structures for blocks (match previous behavior)
  final Map<String, Set<String>> _blockIdsByDedupeKey = <String, Set<String>>{};
  final Map<String, String> _canonicalBlockIdByDedupeKey = <String, String>{};

  Timer? _emitDebounce;
  Timer? _rebuildDebounce;

  Stream<void> get changes => _changesController.stream;

  /// レポート表示前に呼ぶ。ブロック・実績の最新状態でキャッシュを再構築する。
  /// （タイムラインで予定のプロジェクトを変えたあと「レポートを開いただけ」で反映させるため）
  void refreshCache() {
    final userId = AuthService.getCurrentUserId() ?? '';
    _ensureInitialized();
    _rebuildCachesForUser(userId);
  }

  void dispose() {
    _taskBoxSub?.cancel();
    _blockBoxSub?.cancel();
    _emitDebounce?.cancel();
    _rebuildDebounce?.cancel();
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
    _changesController.close();
  }

  void _ensureInitialized() {
    final userId = AuthService.getCurrentUserId() ?? '';
    if (_initialized && userId == _cachedUserId) return;
    _rebuildCachesForUser(userId);
    _attachBoxWatchers();
  }

  void _attachBoxWatchers() {
    // Attach only once; if user changes we keep watching but caches rebuild.
    _taskBoxSub ??= ActualTaskService.watchChanges().listen((event) {
      _ensureInitialized();
      _handleActualTaskBoxEvent(event);
    });
    _blockBoxSub ??= BlockService.watchChanges().listen((event) {
      _ensureInitialized();
      _handleBlockBoxEvent(event);
    });
  }

  void _emitChangeDebounced() {
    if (_changesController.isClosed) return;
    _emitDebounce?.cancel();
    _emitDebounce = Timer(const Duration(milliseconds: 40), () {
      if (!_changesController.isClosed) _changesController.add(null);
    });
  }

  DateTime _dayOnlyLocal(DateTime dt) {
    final d = dt.toLocal();
    return DateTime(d.year, d.month, d.day);
  }

  void _addMinutes(
    Map<DateTime, Map<String, int>> table,
    Map<DateTime, int> totals,
    DateTime day,
    String projectId,
    int minutes,
  ) {
    if (minutes == 0) return;
    final bucket = table.putIfAbsent(day, () => <String, int>{});
    bucket[projectId] = (bucket[projectId] ?? 0) + minutes;
    if (bucket[projectId] == 0) bucket.remove(projectId);
    if (bucket.isEmpty) table.remove(day);
    totals[day] = (totals[day] ?? 0) + minutes;
    if (totals[day] == 0) totals.remove(day);
  }

  bool _isCountableTask(ActualTask task) {
    if (task.isDeleted == true) return false;
    if (task.excludeFromReport == true) return false;
    if (_cachedUserId.isEmpty) return false;
    return task.userId == _cachedUserId;
  }

  void _applyTaskDelta(ActualTask task, {required int sign}) {
    final pid = task.projectId ?? '';
    final alloc = _allocateTaskMinutesByDay(task);
    for (final entry in alloc.entries) {
      _addMinutes(
        _actualByDayProject,
        _actualTotalByDay,
        entry.key,
        pid,
        entry.value * sign,
      );
    }
  }

  bool _isCountableBlock(Block block) {
    if (block.isPauseDerived == true) return false;
    if (block.isDeleted == true) return false;
    if (block.excludeFromReport == true) return false;
    if (block.estimatedDuration <= 0) return false;
    if (block.workingMinutes <= 0) return false;
    if (_cachedUserId.isEmpty) return false;
    if (block.userId != _cachedUserId) return false;
    return true;
  }

  String _blockDedupeKey(Block block) {
    final exec = _dayOnlyLocal(block.executionDate);
    return '${block.userId}|${exec.toIso8601String()}|${block.startHour}|${block.startMinute}|${block.estimatedDuration}|${block.workingMinutes}|${block.projectId ?? ''}|${block.blockName ?? ''}';
  }

  void _applyBlockDelta(Block block, {required int sign}) {
    final pid = block.projectId ?? '';
    final alloc = _allocateBlockWorkingMinutesByDay(block);
    for (final entry in alloc.entries) {
      _addMinutes(
        _plannedByDayProject,
        _plannedTotalByDay,
        entry.key,
        pid,
        entry.value * sign,
      );
    }
  }

  Map<DateTime, int> _allocateTaskMinutesByDay(ActualTask task) {
    // Canonical interval (prefer UTC -> local), fallback to legacy fields.
    final startLocal = (task.startAt?.toLocal() ?? task.startTime.toLocal());
    final DateTime endLocal = (() {
      final e = task.endAtExclusive?.toLocal() ?? task.endTime?.toLocal();
      if (e != null) return e;
      if (task.actualDuration > 0) {
        return startLocal.add(Duration(minutes: task.actualDuration));
      }
      return DateTime.now();
    })();

    if (!endLocal.isAfter(startLocal)) return const <DateTime, int>{};

    final totalMinutes = endLocal.difference(startLocal).inMinutes;
    if (totalMinutes <= 0) return const <DateTime, int>{};

    final totalSeconds = endLocal.difference(startLocal).inSeconds;
    // If seconds resolution is degenerate, place all minutes on start day.
    if (totalSeconds <= 0) {
      return <DateTime, int>{_dayOnlyLocal(startLocal): totalMinutes};
    }

    final Map<DateTime, int> out = <DateTime, int>{};
    DateTime cursor = startLocal;
    int remainingMinutes = totalMinutes;

    // Safety cap: avoid pathological loops for extremely long running tasks.
    // (Design constraints should prevent this in practice.)
    int guard = 0;
    while (cursor.isBefore(endLocal) && remainingMinutes > 0) {
      guard++;
      if (guard > 4000) break;

      final day = _dayOnlyLocal(cursor);
      final nextDayStart = day.add(const Duration(days: 1));
      final segEnd = endLocal.isBefore(nextDayStart) ? endLocal : nextDayStart;
      final segSeconds = segEnd.difference(cursor).inSeconds;

      final bool isLast = !segEnd.isBefore(endLocal);
      final int minutesForThisDay = isLast
          ? remainingMinutes
          : ((segSeconds * totalMinutes) / totalSeconds).floor();
      if (minutesForThisDay > 0) {
        out[day] = (out[day] ?? 0) + minutesForThisDay;
        remainingMinutes -= minutesForThisDay;
      }
      cursor = segEnd;
    }

    if (out.isEmpty) {
      // As a fallback, keep backward behavior.
      out[_dayOnlyLocal(task.startTime)] = totalMinutes;
    }
    return out;
  }

  Map<DateTime, int> _allocateBlockWorkingMinutesByDay(Block block) {
    if (block.workingMinutes <= 0) return const <DateTime, int>{};

    // Determine interval (local) for this planned block.
    final DateTime startLocal = (() {
      final s = block.startAt?.toLocal();
      if (s != null) return s;
      return DateTime(
        block.executionDate.year,
        block.executionDate.month,
        block.executionDate.day,
        block.startHour,
        block.startMinute,
      );
    })();
    final DateTime endLocal = (() {
      final e = block.endAtExclusive?.toLocal();
      if (e != null) return e;
      return DateTime(
        block.executionDate.year,
        block.executionDate.month,
        block.executionDate.day,
        block.startHour,
        block.startMinute,
      ).add(Duration(minutes: block.estimatedDuration));
    })();

    if (!endLocal.isAfter(startLocal)) {
      return <DateTime, int>{_dayOnlyLocal(startLocal): block.workingMinutes};
    }

    final totalMinutes = endLocal.difference(startLocal).inMinutes;
    if (totalMinutes <= 0) {
      return <DateTime, int>{_dayOnlyLocal(startLocal): block.workingMinutes};
    }

    final totalSeconds = endLocal.difference(startLocal).inSeconds;
    if (totalSeconds <= 0) {
      return <DateTime, int>{_dayOnlyLocal(startLocal): block.workingMinutes};
    }

    final Map<DateTime, int> out = <DateTime, int>{};
    DateTime cursor = startLocal;
    int remaining = block.workingMinutes;

    int guard = 0;
    while (cursor.isBefore(endLocal) && remaining > 0) {
      guard++;
      if (guard > 4000) break;

      final day = _dayOnlyLocal(cursor);
      final nextDayStart = day.add(const Duration(days: 1));
      final segEnd = endLocal.isBefore(nextDayStart) ? endLocal : nextDayStart;
      final segSeconds = segEnd.difference(cursor).inSeconds;

      final bool isLast = !segEnd.isBefore(endLocal);
      final minutesForThisDay = isLast
          ? remaining
          : ((segSeconds * block.workingMinutes) / totalSeconds).floor();
      if (minutesForThisDay > 0) {
        out[day] = (out[day] ?? 0) + minutesForThisDay;
        remaining -= minutesForThisDay;
      }
      cursor = segEnd;
    }

    if (out.isEmpty) {
      out[_dayOnlyLocal(block.executionDate)] = block.workingMinutes;
    }
    return out;
  }

  String? _recomputeCanonicalForKey(String key) {
    final ids = _blockIdsByDedupeKey[key];
    if (ids == null || ids.isEmpty) {
      _blockIdsByDedupeKey.remove(key);
      _canonicalBlockIdByDedupeKey.remove(key);
      return null;
    }
    // Deterministic: smallest id wins.
    final sorted = ids.toList()..sort();
    final canonical = sorted.first;
    _canonicalBlockIdByDedupeKey[key] = canonical;
    return canonical;
  }

  void _rebuildCachesForUser(String userId) {
    _cachedUserId = userId;
    _initialized = true;

    _tasksById.clear();
    _blocksById.clear();
    _actualByDayProject.clear();
    _plannedByDayProject.clear();
    _actualTotalByDay.clear();
    _plannedTotalByDay.clear();
    _blockIdsByDedupeKey.clear();
    _canonicalBlockIdByDedupeKey.clear();

    // Tasks: single pass (filtered by current user).
    try {
      for (final task in ActualTaskService.getAllActualTasks()) {
        if (!_isCountableTask(task)) continue;
        _tasksById[task.id] = task;
        _applyTaskDelta(task, sign: 1);
      }
    } catch (_) {
      // If boxes aren't ready, leave caches empty; they will self-heal on next call/event.
    }

    // Blocks: build candidate sets, then apply only canonical contributions (filtered by current user).
    try {
      for (final block in BlockService.getAllBlocks()) {
        _blocksById[block.id] = block;
        if (!_isCountableBlock(block)) continue;
        final k = _blockDedupeKey(block);
        (_blockIdsByDedupeKey[k] ??= <String>{}).add(block.id);
      }
      for (final entry in _blockIdsByDedupeKey.entries) {
        final canonical = _recomputeCanonicalForKey(entry.key);
        if (canonical == null) continue;
        final block = _blocksById[canonical];
        if (block == null) continue;
        if (_isCountableBlock(block)) {
          _applyBlockDelta(block, sign: 1);
        }
      }
    } catch (_) {}

    _emitChangeDebounced();
  }

  void _handleActualTaskBoxEvent(BoxEvent event) {
    final key = event.key;
    if (key == null) return;
    final id = key.toString();
    final old = _tasksById[id];
    if (old != null) {
      _applyTaskDelta(old, sign: -1);
      _tasksById.remove(id);
    }
    if (!event.deleted) {
      try {
        final next = ActualTaskService.getActualTask(id);
        if (next != null && _isCountableTask(next)) {
          _tasksById[id] = next;
          _applyTaskDelta(next, sign: 1);
        }
      } catch (_) {}
    }
    _emitChangeDebounced();
  }

  void _handleBlockBoxEvent(BoxEvent event) {
    final key = event.key;
    if (key == null) return;
    final id = key.toString();

    // Remove old contribution if needed.
    final old = _blocksById[id];
    String? oldDedupeKey;
    String? oldCanonical;
    if (old != null && _isCountableBlock(old)) {
      oldDedupeKey = _blockDedupeKey(old);
      oldCanonical = _canonicalBlockIdByDedupeKey[oldDedupeKey];
      if (oldCanonical == id) {
        _applyBlockDelta(old, sign: -1);
      }
      final set = _blockIdsByDedupeKey[oldDedupeKey];
      set?.remove(id);
      if (set != null && set.isEmpty) _blockIdsByDedupeKey.remove(oldDedupeKey);
      _blocksById.remove(id);
      // Recompute canonical for old key and add new canonical contribution if changed.
      final nextCanonical = _recomputeCanonicalForKey(oldDedupeKey);
      if (nextCanonical != null && nextCanonical != oldCanonical) {
        final b = _blocksById[nextCanonical];
        if (b != null && _isCountableBlock(b)) _applyBlockDelta(b, sign: 1);
      }
    } else {
      _blocksById.remove(id);
    }

    // Add/update with new value (filtered get).
    if (!event.deleted) {
      try {
        final next = BlockService.getBlockById(id);
        if (next != null) {
          _blocksById[id] = next;
          if (_isCountableBlock(next)) {
            final k = _blockDedupeKey(next);
            final prevCanonical = _canonicalBlockIdByDedupeKey[k];
            (_blockIdsByDedupeKey[k] ??= <String>{}).add(id);
            final newCanonical = _recomputeCanonicalForKey(k);
            if (newCanonical != prevCanonical) {
              // Canonical switched: remove prev canonical contrib, add new canonical contrib.
              if (prevCanonical != null) {
                final prevBlock = _blocksById[prevCanonical];
                if (prevBlock != null && _isCountableBlock(prevBlock)) {
                  _applyBlockDelta(prevBlock, sign: -1);
                }
              }
              if (newCanonical != null) {
                final newBlock = _blocksById[newCanonical];
                if (newBlock != null && _isCountableBlock(newBlock)) {
                  _applyBlockDelta(newBlock, sign: 1);
                }
              }
            } else if (newCanonical == id && old == null) {
              // First add for this canonical (already handled by canonical switch above);
              // keep as no-op.
            } else if (newCanonical == id && old != null) {
              // Update of canonical block where dedupe key didn't change:
              // old canonical contribution was already removed above (if old was canonical),
              // but if old wasn't countable (filters changed), nothing removed.
              if (oldDedupeKey == null || oldDedupeKey == k) {
                // Ensure latest canonical minutes are included.
                // If old was canonical and removed, adding back is needed.
                if (oldCanonical == id) {
                  _applyBlockDelta(next, sign: 1);
                }
              }
            }
          }
        }
      } catch (_) {}
    }

    _emitChangeDebounced();
  }

  void _handleCoarseSourceChange([dynamic _]) {
    // If some path doesn't trigger Box.watch (platform limitation), rebuild lazily.
    _rebuildDebounce?.cancel();
    _rebuildDebounce = Timer(const Duration(milliseconds: 120), () {
      _ensureInitialized();
      _rebuildCachesForUser(AuthService.getCurrentUserId() ?? '');
    });
  }

  DailyReportData loadDailySummary(DateTime date) {
    _ensureInitialized();
    final day = _dayOnlyLocal(date);
    return DailyReportData(
      actualMinutesByProject:
          Map<String, int>.from(_actualByDayProject[day] ?? const {}),
      plannedMinutesByProject:
          Map<String, int>.from(_plannedByDayProject[day] ?? const {}),
    );
  }

  WeeklyReportData loadWeeklySummary(DateTime weekStart, {int days = 7}) {
    _ensureInitialized();
    final normalizedStart = _dayOnlyLocal(weekStart);
    final normalizedEnd =
        _endOfDay(normalizedStart.add(Duration(days: days - 1)));

    final actualByDay = <DateTime, Map<String, int>>{};
    final plannedByDay = <DateTime, Map<String, int>>{};

    for (int i = 0; i < days; i++) {
      final day = normalizedStart.add(Duration(days: i));
      actualByDay[day] = {};
      plannedByDay[day] = {};
    }

    for (int i = 0; i < days; i++) {
      final day = normalizedStart.add(Duration(days: i));
      actualByDay[day] = Map<String, int>.from(_actualByDayProject[day] ?? const {});
      plannedByDay[day] = Map<String, int>.from(_plannedByDayProject[day] ?? const {});
    }

    final weeklyActualTotals = <String, int>{};
    final weeklyPlannedTotals = <String, int>{};
    for (final entry in actualByDay.values) {
      entry.forEach((pid, minutes) {
        weeklyActualTotals[pid] = (weeklyActualTotals[pid] ?? 0) + minutes;
      });
    }
    for (final entry in plannedByDay.values) {
      entry.forEach((pid, minutes) {
        weeklyPlannedTotals[pid] = (weeklyPlannedTotals[pid] ?? 0) + minutes;
      });
    }

    return WeeklyReportData(
      start: normalizedStart,
      end: normalizedEnd,
      actualByDayProject: actualByDay,
      plannedByDayProject: plannedByDay,
      weeklyActualTotals: weeklyActualTotals,
      weeklyPlannedTotals: weeklyPlannedTotals,
    );
  }

  MonthlyReportData loadMonthlySummary(DateTime baseDate) {
    _ensureInitialized();
    final monthStart = DateTime(baseDate.year, baseDate.month, 1);
    final monthEnd = _endOfDay(DateTime(baseDate.year, baseDate.month + 1, 0));

    final buckets = <MonthlyWeekBucket>[];
    var cursor = monthStart;

    while (!cursor.isAfter(monthEnd)) {
      final bucketStart = cursor;
      final bucketEnd = _endOfDay(
        cursor.add(const Duration(days: 6)).isAfter(monthEnd)
            ? monthEnd
            : cursor.add(const Duration(days: 6)),
      );
      int plannedMinutes = 0;
      int actualMinutes = 0;
      var d = _dayOnlyLocal(bucketStart);
      final endDay = _dayOnlyLocal(bucketEnd);
      while (!d.isAfter(endDay)) {
        plannedMinutes += _plannedTotalByDay[d] ?? 0;
        actualMinutes += _actualTotalByDay[d] ?? 0;
        d = d.add(const Duration(days: 1));
      }

      buckets.add(
        MonthlyWeekBucket(
          start: bucketStart,
          end: bucketEnd,
          plannedMinutes: plannedMinutes,
          actualMinutes: actualMinutes,
        ),
      );

      cursor = bucketStart.add(const Duration(days: 7));
    }

    final plannedByProject = <String, int>{};
    final actualByProject = <String, int>{};
    var day = _dayOnlyLocal(monthStart);
    final endDay = _dayOnlyLocal(monthEnd);
    while (!day.isAfter(endDay)) {
      final p = _plannedByDayProject[day];
      if (p != null) {
        p.forEach((pid, mins) {
          plannedByProject[pid] = (plannedByProject[pid] ?? 0) + mins;
        });
      }
      final a = _actualByDayProject[day];
      if (a != null) {
        a.forEach((pid, mins) {
          actualByProject[pid] = (actualByProject[pid] ?? 0) + mins;
        });
      }
      day = day.add(const Duration(days: 1));
    }

    return MonthlyReportData(
      monthStart: monthStart,
      monthEnd: monthEnd,
      weekBuckets: buckets,
      plannedByProject: plannedByProject,
      actualByProject: actualByProject,
    );
  }

  YearlyReportData loadYearlySummary(DateTime baseDate) {
    _ensureInitialized();
    final yearStart = DateTime(baseDate.year, 1, 1);
    final yearEnd = _endOfDay(DateTime(baseDate.year, 12, 31));

    final monthlyAggregates = List<MonthlyAggregate>.generate(12, (index) {
      final month = index + 1;
      final start = DateTime(yearStart.year, month, 1);
      final end = _endOfDay(DateTime(yearStart.year, month + 1, 0));
      int plannedMinutes = 0;
      int actualMinutes = 0;
      var d = _dayOnlyLocal(start);
      final endDay = _dayOnlyLocal(end);
      while (!d.isAfter(endDay)) {
        plannedMinutes += _plannedTotalByDay[d] ?? 0;
        actualMinutes += _actualTotalByDay[d] ?? 0;
        d = d.add(const Duration(days: 1));
      }

      return MonthlyAggregate(
        plannedMinutes: plannedMinutes,
        actualMinutes: actualMinutes,
      );
    });

    final plannedByProject = <String, int>{};
    final actualByProject = <String, int>{};
    var day = _dayOnlyLocal(yearStart);
    final endDay = _dayOnlyLocal(yearEnd);
    while (!day.isAfter(endDay)) {
      final p = _plannedByDayProject[day];
      if (p != null) {
        p.forEach((pid, mins) {
          plannedByProject[pid] = (plannedByProject[pid] ?? 0) + mins;
        });
      }
      final a = _actualByDayProject[day];
      if (a != null) {
        a.forEach((pid, mins) {
          actualByProject[pid] = (actualByProject[pid] ?? 0) + mins;
        });
      }
      day = day.add(const Duration(days: 1));
    }

    return YearlyReportData(
      yearStart: yearStart,
      yearEnd: yearEnd,
      monthlyAggregates: monthlyAggregates,
      plannedByProject: plannedByProject,
      actualByProject: actualByProject,
    );
  }

  /// 実績タスクの「日別配賦（レポート集計と同じロジック）」を返す。
  Map<DateTime, int> getActualTaskAllocatedMinutesByDay(ActualTask task) {
    _ensureInitialized();
    return Map<DateTime, int>.from(_allocateTaskMinutesByDay(task));
  }

  /// 予定ブロックの「日別配賦（レポート集計と同じロジック）」を返す。
  Map<DateTime, int> getBlockAllocatedWorkingMinutesByDay(Block block) {
    _ensureInitialized();
    return Map<DateTime, int>.from(_allocateBlockWorkingMinutesByDay(block));
  }

  bool _hasAnyAllocatedDayInRange(
    Map<DateTime, int> allocation,
    DateTime startDay,
    DateTime endDay,
  ) {
    for (final entry in allocation.entries) {
      if (entry.value <= 0) continue;
      final day = _dayOnlyLocal(entry.key);
      if (!day.isBefore(startDay) && !day.isAfter(endDay)) {
        return true;
      }
    }
    return false;
  }

  /// 指定日付範囲に「寄与する」実績タスク（ActualTask）を返す。
  /// [start] inclusive, [end] inclusive (date-only local)
  List<ActualTask> getActualTasksInRange(DateTime start, DateTime end) {
    _ensureInitialized();
    final s = _dayOnlyLocal(start);
    final e = _dayOnlyLocal(end);
    return _tasksById.values.where((task) {
      final allocation = _allocateTaskMinutesByDay(task);
      return _hasAnyAllocatedDayInRange(allocation, s, e);
    }).toList()
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
  }

  /// 指定日付範囲に「寄与する」予定ブロック（重複排除済み canonical のみ）を返す。
  /// [start] inclusive, [end] inclusive (date-only local)
  List<Block> getBlocksInRange(DateTime start, DateTime end) {
    _ensureInitialized();
    final s = _dayOnlyLocal(start);
    final e = _dayOnlyLocal(end);
    final canonicalIds = _canonicalBlockIdByDedupeKey.values.toSet();
    return canonicalIds
        .map((id) => _blocksById[id])
        .whereType<Block>()
        .where((block) {
      if (!_isCountableBlock(block)) return false;
      final allocation = _allocateBlockWorkingMinutesByDay(block);
      return _hasAnyAllocatedDayInRange(allocation, s, e);
    }).toList()
      ..sort((a, b) => a.startDateTime.compareTo(b.startDateTime));
  }

  DateTime _startOfDay(DateTime dt) =>
      DateTime(dt.year, dt.month, dt.day);

  DateTime _endOfDay(DateTime dt) =>
      DateTime(dt.year, dt.month, dt.day).add(const Duration(days: 1));

  bool _isBefore(DateTime value, DateTime other) =>
      value.isBefore(other);

  bool _isAfter(DateTime value, DateTime other) =>
      value.isAfter(other);
}
