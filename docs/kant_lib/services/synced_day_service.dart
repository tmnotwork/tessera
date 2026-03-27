import 'dart:async';

import 'package:hive/hive.dart';

import '../models/synced_day.dart';

class SyncedDayService {
  SyncedDayService._();

  static const _boxName = 'synced_days';

  static Box<SyncedDay>? _box;
  static bool _opening = false;

  static Future<void> initialize() async {
    if (_box != null && _box!.isOpen) {
      return;
    }
    if (_opening) {
      while (_opening) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      return;
    }
    _opening = true;
    try {
      _ensureAdapters();
      _box = await Hive.openBox<SyncedDay>(_boxName);
    } finally {
      _opening = false;
    }
  }

  static void _ensureAdapters() {
    if (!Hive.isAdapterRegistered(120)) {
      Hive.registerAdapter(SyncedDayKindAdapter());
    }
    if (!Hive.isAdapterRegistered(121)) {
      Hive.registerAdapter(SyncedDayStatusAdapter());
    }
    if (!Hive.isAdapterRegistered(122)) {
      Hive.registerAdapter(SyncedDayAdapter());
    }
  }

  static Future<Box<SyncedDay>> _requireBox() async {
    await initialize();
    final box = _box;
    if (box == null) {
      throw StateError('SyncedDayService box not initialized');
    }
    return box;
  }

  static String _dateKey(DateTime date) {
    final d = DateTime(date.year, date.month, date.day);
    return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  static Future<SyncedDay> upsert(
    DateTime date,
    SyncedDayKind kind, {
    SyncedDayStatus initialStatus = SyncedDayStatus.seeded,
  }) async {
    final box = await _requireBox();
    final key = _key(date, kind);
    final existing = box.get(key);
    if (existing != null) {
      return existing;
    }
    final next = SyncedDay(
      dateKey: _dateKey(date),
      kind: kind,
      status: initialStatus,
    );
    await box.put(key, next);
    await box.flush();
    return next;
  }

  static String _key(DateTime date, SyncedDayKind kind) => '${kind.name}#${_dateKey(date)}';

  static Future<SyncedDay?> get(DateTime date, SyncedDayKind kind) async {
    final box = await _requireBox();
    return box.get(_key(date, kind));
  }

  static Future<void> put(SyncedDay day) async {
    final box = await _requireBox();
    await box.put(day.id, day..updatedAt = DateTime.now());
    await box.flush();
  }

  static Future<SyncedDay> markStatus(
    DateTime date,
    SyncedDayKind kind,
    SyncedDayStatus status,
  ) async {
    final current = await upsert(date, kind);
    final next = current.markStatus(status);
    await put(next);
    return next;
  }

  static Future<void> markStatusBatch(
    Iterable<DateTime> dates,
    SyncedDayKind kind,
    SyncedDayStatus status,
  ) async {
    final box = await _requireBox();
    final updates = <String, SyncedDay>{};
    for (final date in dates) {
      final key = _key(date, kind);
      final current = box.get(key) ??
          SyncedDay(
            dateKey: _dateKey(date),
            kind: kind,
            status: SyncedDayStatus.seeded,
          );
      if (current.status == status) {
        continue;
      }
      updates[key] = current.markStatus(status);
    }
    if (updates.isEmpty) return;
    await box.putAll(updates);
    await box.flush();
  }

  static Future<SyncedDay> recordVersionCheck({
    required DateTime date,
    required SyncedDayKind kind,
    String? versionHash,
    DateTime? versionWriteAt,
    DateTime? checkAt,
  }) async {
    final base = await upsert(date, kind);
    final next = base.copyWith(
      lastVersionHash: versionHash,
      lastVersionWriteAt: versionWriteAt,
      lastVersionCheckAt: checkAt ?? DateTime.now(),
    );
    await put(next);
    return next;
  }

  static Future<SyncedDay> recordFetch({
    required DateTime date,
    required SyncedDayKind kind,
    SyncedDayStatus status = SyncedDayStatus.ready,
    DateTime? fetchedAt,
    String? versionHash,
    DateTime? versionWriteAt,
  }) async {
    final base = await upsert(date, kind);
    final next = base.copyWith(
      status: status,
      lastFetchedAt: fetchedAt ?? DateTime.now(),
      lastVersionHash: versionHash,
      lastVersionWriteAt: versionWriteAt,
      lastVersionCheckAt: DateTime.now(),
    );
    await put(next);
    return next;
  }

  static Future<SyncedDay> recordChangeCursor({
    required DateTime date,
    required SyncedDayKind kind,
    DateTime? lastChangeAt,
    String? lastChangeDocId,
    bool clearCursor = false,
  }) async {
    final base = await upsert(date, kind);
    final next = base.copyWith(
      lastChangeAt: lastChangeAt,
      clearLastChangeAt: clearCursor,
      lastChangeDocId: lastChangeDocId,
      clearLastChangeDocId: clearCursor,
    );
    await put(next);
    return next;
  }

  /// 全件同期完了時刻を記録する
  static Future<SyncedDay> recordFullSyncAt({
    required DateTime date,
    required SyncedDayKind kind,
    DateTime? fullSyncAt,
  }) async {
    final base = await upsert(date, kind);
    final next = base.copyWith(
      lastFullSyncAt: fullSyncAt ?? DateTime.now(),
    );
    await put(next);
    return next;
  }

  static Future<List<SyncedDay>> readyDays(
    SyncedDayKind kind, {
    int limit = 6,
  }) async {
    final box = await _requireBox();
    final values = box.values
        .where((d) => d.kind == kind && d.status == SyncedDayStatus.ready)
        .toList();
    values.sort((a, b) {
      final aTs = a.lastFetchedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bTs = b.lastFetchedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bTs.compareTo(aTs);
    });
    if (values.length <= limit) {
      return values;
    }
    return values.sublist(0, limit);
  }

  static Future<List<SyncedDay>> allDays(SyncedDayKind kind) async {
    final box = await _requireBox();
    return box.values.where((d) => d.kind == kind).toList();
  }

  static Future<void> remove(String id) async {
    final box = await _requireBox();
    await box.delete(id);
    await box.flush();
  }

  static Future<void> removeMany(Iterable<String> ids) async {
    final box = await _requireBox();
    final uniqueIds = ids.toSet().toList();
    if (uniqueIds.isEmpty) return;
    await box.deleteAll(uniqueIds);
    await box.flush();
  }

  static Future<void> enforceRetention({
    int pastDays = 30,
    int futureDays = 14,
    Iterable<SyncedDayKind>? kinds,
  }) async {
    final box = await _requireBox();
    final now = DateTime.now();
    final minDate = DateTime(now.year, now.month, now.day)
        .subtract(Duration(days: pastDays));
    final maxDate = DateTime(now.year, now.month, now.day)
        .add(Duration(days: futureDays));
    final kindFilter = kinds?.toSet();
    final removals = <String>[];
    for (final entry in box.values) {
      if (kindFilter != null && !kindFilter.contains(entry.kind)) {
        continue;
      }
      final parts = entry.dateKey.split('-');
      DateTime? dt;
      if (parts.length == 3) {
        final year = int.tryParse(parts[0]);
        final month = int.tryParse(parts[1]);
        final day = int.tryParse(parts[2]);
        if (year != null && month != null && day != null) {
          dt = DateTime(year, month, day);
        }
      }
      if (dt == null) {
        removals.add(entry.id);
        continue;
      }
      if (dt.isBefore(minDate) || dt.isAfter(maxDate)) {
        removals.add(entry.id);
      }
    }
    if (removals.isEmpty) {
      return;
    }
    await box.deleteAll(removals);
    await box.flush();
  }

  static Future<void> clear() async {
    final box = await _requireBox();
    await box.clear();
    await box.flush();
  }
}
