import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/actual_task.dart';
import '../models/block.dart';
import 'actual_task_service.dart';
import 'app_settings_service.dart';
import 'auth_service.dart';
import 'block_service.dart';
import 'day_key_service.dart';
import 'sync_kpi.dart';

enum MultiDayBackfillStatus {
  ran,
  skippedDone,
  skippedRunning,
  skippedNoUser,
  failed,
}

class MultiDayBackfillReport {
  MultiDayBackfillReport({
    required this.status,
    required this.startedAtUtc,
    required this.endedAtUtc,
    this.userId,
    this.tzName,
    this.updatedBlocks = 0,
    this.updatedActuals = 0,
    this.failedBlocks = 0,
    this.failedActuals = 0,
    this.remainingWork,
    this.note,
    this.sampleUpdatedBlockIds = const <String>[],
    this.sampleUpdatedActualIds = const <String>[],
    this.sampleErrors = const <String>[],
  });

  final MultiDayBackfillStatus status;
  final DateTime startedAtUtc;
  final DateTime endedAtUtc;
  final String? userId;
  final String? tzName;
  final int updatedBlocks;
  final int updatedActuals;
  final int failedBlocks;
  final int failedActuals;
  final bool? remainingWork;
  final String? note;
  final List<String> sampleUpdatedBlockIds;
  final List<String> sampleUpdatedActualIds;
  final List<String> sampleErrors;

  Duration get duration => endedAtUtc.difference(startedAtUtc);

  String _statusLabel() {
    switch (status) {
      case MultiDayBackfillStatus.ran:
        return 'ran';
      case MultiDayBackfillStatus.skippedDone:
        return 'skipped_done';
      case MultiDayBackfillStatus.skippedRunning:
        return 'skipped_running';
      case MultiDayBackfillStatus.skippedNoUser:
        return 'skipped_no_user';
      case MultiDayBackfillStatus.failed:
        return 'failed';
    }
  }

  String toText() {
    final b = StringBuffer();
    b.writeln('MultiDayBackfill report');
    b.writeln('status=${_statusLabel()}');
    if (userId != null && userId!.isNotEmpty) b.writeln('userId=$userId');
    if (tzName != null && tzName!.isNotEmpty) b.writeln('tz=$tzName');
    b.writeln('startedAtUtc=${startedAtUtc.toIso8601String()}');
    b.writeln('endedAtUtc=${endedAtUtc.toIso8601String()}');
    b.writeln('durationMs=${duration.inMilliseconds}');
    if (remainingWork != null) b.writeln('remainingWork=$remainingWork');
    b.writeln('updatedBlocks=$updatedBlocks failedBlocks=$failedBlocks');
    b.writeln('updatedActuals=$updatedActuals failedActuals=$failedActuals');
    if (sampleUpdatedBlockIds.isNotEmpty) {
      b.writeln('sampleUpdatedBlocks=${sampleUpdatedBlockIds.join(', ')}');
    }
    if (sampleUpdatedActualIds.isNotEmpty) {
      b.writeln('sampleUpdatedActuals=${sampleUpdatedActualIds.join(', ')}');
    }
    if (sampleErrors.isNotEmpty) {
      b.writeln('errors:');
      for (final e in sampleErrors) {
        b.writeln('- $e');
      }
    }
    if (note != null && note!.isNotEmpty) {
      b.writeln('note=$note');
    }
    return b.toString();
  }
}

/// Phase 7（任意）: 既存データ（あなた1人）向けのバックフィル。
///
/// - 旧データに `startAt/endAtExclusive/dayKeys/monthKeys` が欠けている場合、
///   クライアント側で補完して Firestore へ merge で書き戻す。
/// - 競合回避のため `lastModified/version` は更新しない（フィールド追加のみ）。
class MultiDayBackfillService {
  // v2: rerunnable if we still detect missing canonical fields.
  static const String _doneKey = 'migration.multi_day_backfill.v2.done';
  static const String _runningKey = 'migration.multi_day_backfill.v2.running';

  static Future<void> runIfNeeded() async {
    // Outbox/Sync が安定していない環境でも落とさない。
    try {
      // Ensure settings are available for done/running guards.
      try {
        await AppSettingsService.initialize();
      } catch (_) {}

      // Hard stop: once migration is done, never run again automatically.
      final done = AppSettingsService.getBool(_doneKey, defaultValue: false);
      if (done) return;

      // Ensure timezone is ready; otherwise dayKeys would be computed in UTC fallback.
      try {
        await DayKeyService.initialize();
      } catch (_) {}

      final running =
          AppSettingsService.getBool(_runningKey, defaultValue: false);
      if (running) return;
      await AppSettingsService.setBool(_runningKey, true);
      await _runInternal();
      // Mark done only when there's no remaining work.
      final remaining = await _hasRemainingWork();
      await AppSettingsService.setBool(_doneKey, !remaining);
    } catch (e) {
      // ignore: avoid_print
      print('⚠️ MultiDayBackfillService.runIfNeeded failed: $e');
    } finally {
      try {
        await AppSettingsService.setBool(_runningKey, false);
      } catch (_) {}
    }
  }

  /// 手動実行（設定画面用）。結果をレポートとして返す。
  ///
  /// - `force=true` の場合、doneフラグが立っていても実行する。
  /// - 既に実行中の場合はスキップして返す。
  static Future<MultiDayBackfillReport> runManual({bool force = false}) async {
    final startedAtUtc = DateTime.now().toUtc();
    String? uid;
    try {
      uid = AuthService.getCurrentUserId();
    } catch (_) {
      uid = null;
    }
    String? tzName;
    try {
      await DayKeyService.initialize();
      tzName = DayKeyService.location.name;
    } catch (_) {
      tzName = null;
    }

    try {
      try {
        await AppSettingsService.initialize();
      } catch (_) {}

      final running = AppSettingsService.getBool(_runningKey, defaultValue: false);
      if (running) {
        return MultiDayBackfillReport(
          status: MultiDayBackfillStatus.skippedRunning,
          startedAtUtc: startedAtUtc,
          endedAtUtc: DateTime.now().toUtc(),
          userId: uid,
          tzName: tzName,
          note: 'already running',
        );
      }
      if (!force) {
        final done = AppSettingsService.getBool(_doneKey, defaultValue: false);
        if (done) {
          return MultiDayBackfillReport(
            status: MultiDayBackfillStatus.skippedDone,
            startedAtUtc: startedAtUtc,
            endedAtUtc: DateTime.now().toUtc(),
            userId: uid,
            tzName: tzName,
            note: 'already done (use force to rerun)',
          );
        }
      }

      if (uid == null || uid.isEmpty) {
        return MultiDayBackfillReport(
          status: MultiDayBackfillStatus.skippedNoUser,
          startedAtUtc: startedAtUtc,
          endedAtUtc: DateTime.now().toUtc(),
          tzName: tzName,
          note: 'user not authenticated',
        );
      }

      await AppSettingsService.setBool(_runningKey, true);
      final result = await _runInternalWithReport(uid);
      final remaining = await _hasRemainingWork();
      await AppSettingsService.setBool(_doneKey, !remaining);
      return MultiDayBackfillReport(
        status: MultiDayBackfillStatus.ran,
        startedAtUtc: startedAtUtc,
        endedAtUtc: DateTime.now().toUtc(),
        userId: uid,
        tzName: tzName,
        updatedBlocks: result.updatedBlocks,
        updatedActuals: result.updatedActuals,
        failedBlocks: result.failedBlocks,
        failedActuals: result.failedActuals,
        remainingWork: remaining,
        sampleUpdatedBlockIds: result.sampleUpdatedBlockIds,
        sampleUpdatedActualIds: result.sampleUpdatedActualIds,
        sampleErrors: result.sampleErrors,
      );
    } catch (e) {
      return MultiDayBackfillReport(
        status: MultiDayBackfillStatus.failed,
        startedAtUtc: startedAtUtc,
        endedAtUtc: DateTime.now().toUtc(),
        userId: uid,
        tzName: tzName,
        note: e.toString(),
      );
    } finally {
      try {
        await AppSettingsService.setBool(_runningKey, false);
      } catch (_) {}
    }
  }

  static Future<bool> _hasRemainingWork() async {
    try {
      try {
        await BlockService.initialize();
      } catch (_) {}
      try {
        await ActualTaskService.initialize();
      } catch (_) {}
      final blocks = BlockService.getAllBlocks();
      for (final b in blocks) {
        if (b.isDeleted) continue;
        final needs = b.startAt == null ||
            b.endAtExclusive == null ||
            b.dayKeys == null ||
            b.monthKeys == null;
        if (needs) return true;
      }
      final actuals = ActualTaskService.getAllActualTasks();
      for (final t in actuals) {
        if (t.isDeleted) continue;
        final needs = t.startAt == null ||
            (t.isRunning ? false : (t.endAtExclusive == null)) ||
            (!t.isRunning && (t.dayKeys == null || t.monthKeys == null));
        if (needs) return true;
      }
    } catch (_) {}
    return false;
  }

  static Future<void> _runInternal() async {
    final uid = AuthService.getCurrentUserId() ?? '';
    if (uid.isEmpty) return;
    await _runInternalWithReport(uid);
  }

  static Future<_InternalBackfillResult> _runInternalWithReport(String uid) async {
    final firestore = FirebaseFirestore.instance;
    final userRef = firestore.collection('users').doc(uid);

    int updatedBlocks = 0;
    int updatedActuals = 0;
    int failedBlocks = 0;
    int failedActuals = 0;
    final sampleUpdatedBlocks = <String>[];
    final sampleUpdatedActuals = <String>[];
    final sampleErrors = <String>[];
    void recordError(String msg) {
      if (sampleErrors.length >= 20) return;
      sampleErrors.add(msg);
    }

    // --- Blocks ---
    try {
      await BlockService.initialize();
    } catch (_) {}
    final blocks = BlockService.getAllBlocks();
    for (final b in blocks) {
      if (b.isDeleted) continue;
      final needs =
          b.startAt == null ||
          b.endAtExclusive == null ||
          b.dayKeys == null ||
          b.monthKeys == null;
      if (!needs) continue;

      try {
        // Populate fields in-place (Phase 3 behavior).
        b.toFirestoreWriteMap();
        await BlockService.updateBlock(b);

        // Remote patch only when cloudId exists.
        final cid = b.cloudId;
        if (cid != null && cid.isNotEmpty) {
          final patch = <String, dynamic>{};
          if (b.startAt != null) patch['startAt'] = Timestamp.fromDate(b.startAt!);
          if (b.endAtExclusive != null) {
            patch['endAtExclusive'] = Timestamp.fromDate(b.endAtExclusive!);
          }
          patch['allDay'] = b.allDay;
          if (b.dayKeys != null) patch['dayKeys'] = b.dayKeys;
          if (b.monthKeys != null) patch['monthKeys'] = b.monthKeys;
          if (patch.isNotEmpty) {
            await userRef.collection('blocks').doc(cid).set(
                  patch,
                  SetOptions(merge: true),
                );
            try {
              SyncKpi.writes += 1;
            } catch (_) {}
          }
        }
        updatedBlocks++;
        if (sampleUpdatedBlocks.length < 10) {
          sampleUpdatedBlocks.add(b.cloudId ?? b.id);
        }
      } catch (e) {
        failedBlocks++;
        recordError('block id=${b.id} cloudId=${b.cloudId ?? '(null)'} err=$e');
      }
    }

    // --- ActualTasks ---
    try {
      await ActualTaskService.initialize();
    } catch (_) {}
    final actuals = ActualTaskService.getAllActualTasks();
    for (final t in actuals) {
      if (t.isDeleted) continue;
      final needs = t.startAt == null ||
          (t.isRunning ? false : (t.endAtExclusive == null)) ||
          (!t.isRunning && (t.dayKeys == null || t.monthKeys == null));
      if (!needs) continue;

      try {
        // Populate fields in-place (Phase 3 behavior).
        t.toFirestoreWriteMap();
        await ActualTaskService.updateActualTask(t);

        // Remote patch only when cloudId exists.
        final cid = t.cloudId;
        if (cid != null && cid.isNotEmpty) {
          final patch = <String, dynamic>{};
          if (t.startAt != null) patch['startAt'] = Timestamp.fromDate(t.startAt!);
          // running は endAtExclusive を null のまま維持
          if (t.endAtExclusive != null) {
            patch['endAtExclusive'] = Timestamp.fromDate(t.endAtExclusive!);
          } else if (t.isRunning) {
            patch['endAtExclusive'] = null;
          }
          patch['allDay'] = t.allDay;
          if (t.dayKeys != null) patch['dayKeys'] = t.dayKeys;
          if (t.monthKeys != null) patch['monthKeys'] = t.monthKeys;
          if (patch.isNotEmpty) {
            await userRef.collection('actual_tasks').doc(cid).set(
                  patch,
                  SetOptions(merge: true),
                );
            try {
              SyncKpi.writes += 1;
            } catch (_) {}
          }
        }
        updatedActuals++;
        if (sampleUpdatedActuals.length < 10) {
          sampleUpdatedActuals.add(t.cloudId ?? t.id);
        }
      } catch (e) {
        failedActuals++;
        recordError('actual id=${t.id} cloudId=${t.cloudId ?? '(null)'} err=$e');
      }
    }

    try {
      // ignore: avoid_print
      print('✅ MultiDayBackfillService: blocks=$updatedBlocks actuals=$updatedActuals failedBlocks=$failedBlocks failedActuals=$failedActuals');
    } catch (_) {}

    return _InternalBackfillResult(
      updatedBlocks: updatedBlocks,
      updatedActuals: updatedActuals,
      failedBlocks: failedBlocks,
      failedActuals: failedActuals,
      sampleUpdatedBlockIds: sampleUpdatedBlocks,
      sampleUpdatedActualIds: sampleUpdatedActuals,
      sampleErrors: sampleErrors,
    );
  }
}

class _InternalBackfillResult {
  _InternalBackfillResult({
    required this.updatedBlocks,
    required this.updatedActuals,
    required this.failedBlocks,
    required this.failedActuals,
    required this.sampleUpdatedBlockIds,
    required this.sampleUpdatedActualIds,
    required this.sampleErrors,
  });

  final int updatedBlocks;
  final int updatedActuals;
  final int failedBlocks;
  final int failedActuals;
  final List<String> sampleUpdatedBlockIds;
  final List<String> sampleUpdatedActualIds;
  final List<String> sampleErrors;
}

