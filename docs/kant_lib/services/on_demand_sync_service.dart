import 'dart:async';

import '../models/actual_task.dart';
import '../models/block.dart';
import '../models/synced_day.dart';
import 'actual_task_sync_service.dart';
import 'actual_task_service.dart';
import 'auth_service.dart';
import 'block_outbox_manager.dart';
import 'block_sync_service.dart';
import 'block_service.dart';
import 'day_change_log_service.dart';
import 'inbox_task_sync_service.dart';
import 'inbox_version_service.dart';
import 'synced_day_service.dart';
import 'sync_manager.dart';
import 'sync_kpi.dart';
import 'sync_all_history_service.dart';
import 'timeline_version_service.dart';
import 'version_feed_service.dart';

class OnDemandSyncService {
  OnDemandSyncService._();

  static const Duration freshnessWindow = Duration(minutes: 15);
  // onDemand の「差分同期」は日付ごとに呼ばれ得るため、同一セッション内の連打を抑制する。
  static const Duration _diffSyncMinInterval = Duration(seconds: 30);
  static const Set<SyncedDayKind> _retentionKinds = {
    SyncedDayKind.timeline,
    SyncedDayKind.inbox,
  };

  static Future<void> ensureTimelineDay(
    DateTime date, {
    bool pullVersionFeed = true,
    bool force = false,
    String? caller,
  }) async {
    final normalized0 = DateTime(date.year, date.month, date.day);
    final callerTag = (caller ?? '').trim();
    String? resolvedUserId;
    try {
      resolvedUserId = AuthService.getCurrentUserId();
    } catch (_) {
      resolvedUserId = null;
    }
    final historyId = await SyncAllHistoryService.recordEventStart(
      type: 'onDemandSync',
      reason: 'ensureTimelineDay',
      origin: 'OnDemandSyncService.ensureTimelineDay',
      userId: resolvedUserId,
      extra: <String, dynamic>{
        'date': normalized0.toIso8601String(),
        'pullVersionFeed': pullVersionFeed,
        'force': force,
        if (callerTag.isNotEmpty) 'caller': callerTag,
      },
    );
    final normalized = DateTime(date.year, date.month, date.day);
    await SyncedDayService.initialize();

    try {
      bool performedRemoteCheck = false;
      bool performedFetch = false;
      String? fetchReason;
      String? fetchMode;
      if (pullVersionFeed) {
        await VersionFeedService.pullTimelineUpdates(force: force);
      }

      var meta = await SyncedDayService.get(normalized, SyncedDayKind.timeline) ??
          await SyncedDayService.upsert(
            normalized,
            SyncedDayKind.timeline,
            initialStatus: SyncedDayStatus.seeded,
          );

      bool needsRemoteCheck = force || meta.lastVersionCheckAt == null;
      if (!needsRemoteCheck && meta.lastVersionCheckAt != null) {
        needsRemoteCheck = DateTime.now().difference(meta.lastVersionCheckAt!) >= freshnessWindow;
      }
      if (meta.status != SyncedDayStatus.ready) {
        needsRemoteCheck = true;
      }

      DayVersionDoc? remoteDoc;
      if (needsRemoteCheck) {
        performedRemoteCheck = true;
        remoteDoc = await TimelineVersionService.fetchRemoteDoc(normalized);
        if (remoteDoc != null) {
          final previousLocalToken = meta.lastVersionHash;
          final remoteToken = remoteDoc.hash ?? remoteDoc.version?.toString();
          final tokenMismatch = remoteToken != previousLocalToken;
          final remoteMissing = !(remoteDoc.exists);
          await SyncedDayService.recordVersionCheck(
            date: normalized,
            kind: SyncedDayKind.timeline,
            versionHash: remoteToken,
            versionWriteAt: remoteDoc.lastWriteAt,
          );
          meta = await SyncedDayService.get(normalized, SyncedDayKind.timeline) ?? meta;
          if (force || remoteMissing || tokenMismatch) {
            await SyncedDayService.markStatus(
              normalized,
              SyncedDayKind.timeline,
              SyncedDayStatus.stale,
            );
            meta = await SyncedDayService.get(normalized, SyncedDayKind.timeline) ?? meta;
          }
        } else if (force) {
          await SyncedDayService.markStatus(
            normalized,
            SyncedDayKind.timeline,
            SyncedDayStatus.stale,
          );
          meta = await SyncedDayService.get(normalized, SyncedDayKind.timeline) ?? meta;
        }
      }

      if (meta.status != SyncedDayStatus.ready) {
        performedFetch = true;
        fetchReason = force
            ? 'forced'
            : (meta.lastFetchedAt == null
                ? 'missing'
                : (meta.status == SyncedDayStatus.evicted ? 'evicted' : 'stale'));
        fetchMode = await _fetchTimelineDay(
          normalized,
          remoteDoc: remoteDoc,
          force: force,
        );
        remoteDoc ??= await TimelineVersionService.fetchRemoteDoc(normalized);
        await SyncedDayService.recordFetch(
          date: normalized,
          kind: SyncedDayKind.timeline,
          status: SyncedDayStatus.ready,
          versionHash: remoteDoc?.hash ?? remoteDoc?.version?.toString(),
          versionWriteAt: remoteDoc?.lastWriteAt,
        );
        SyncKpi.recordOnDemandFetch('timeline');
        await SyncedDayService.enforceRetention(kinds: _retentionKinds);
      }
      await SyncAllHistoryService.recordFinish(
        id: historyId,
        success: true,
        extra: <String, dynamic>{
          'performedRemoteCheck': performedRemoteCheck,
          'performedFetch': performedFetch,
          'force': force,
          if (performedFetch) 'fetchReason': fetchReason,
          if (performedFetch) 'fetchMode': fetchMode ?? 'unknown',
          if (callerTag.isNotEmpty) 'caller': callerTag,
        },
      );
    } catch (e) {
      await SyncAllHistoryService.recordFailed(
        id: historyId,
        error: e.toString(),
        extra: callerTag.isNotEmpty ? <String, dynamic>{'caller': callerTag} : null,
      );
      rethrow;
    }
  }

  static Future<void> ensureInboxDay(
    DateTime date, {
    bool pullVersionFeed = true,
    bool force = false,
    String? caller,
  }) async {
    final normalized0 = DateTime(date.year, date.month, date.day);
    final callerTag = (caller ?? '').trim();
    String? resolvedUserId;
    try {
      resolvedUserId = AuthService.getCurrentUserId();
    } catch (_) {
      resolvedUserId = null;
    }
    final historyId = await SyncAllHistoryService.recordEventStart(
      type: 'onDemandSync',
      reason: 'ensureInboxDay',
      origin: 'OnDemandSyncService.ensureInboxDay',
      userId: resolvedUserId,
      extra: <String, dynamic>{
        'date': normalized0.toIso8601String(),
        'pullVersionFeed': pullVersionFeed,
        'force': force,
        if (callerTag.isNotEmpty) 'caller': callerTag,
      },
    );
    final normalized = DateTime(date.year, date.month, date.day);
    await SyncedDayService.initialize();
    try {
      bool performedRemoteCheck = false;
      bool performedFetch = false;
      String? fetchReason;
      String? fetchMode;
      if (pullVersionFeed) {
        await VersionFeedService.pullTimelineUpdates(force: force);
      }

      var meta = await SyncedDayService.get(normalized, SyncedDayKind.inbox) ??
          await SyncedDayService.upsert(
            normalized,
            SyncedDayKind.inbox,
            initialStatus: SyncedDayStatus.seeded,
          );

      // Inbox の更新検知は「1doc (inboxVersion)」へ移行済み。
      // dayVersions を使うとタイムライン側の stale 判定に波及しやすいため、
      // ここでは inboxVersion を優先し、取得に失敗した場合のみ dayVersions へフォールバックする。
      int? remoteRev;
      try {
        remoteRev = await InboxVersionService.fetchRemoteRev();
      } catch (_) {
        remoteRev = null;
      }
      if (remoteRev != null) {
        performedRemoteCheck = true;
        final localSeen = InboxVersionService.getLocalSeenRev();
        final hasUpdate = remoteRev > localSeen;
        final needsFetch = force || hasUpdate || meta.status != SyncedDayStatus.ready;
        if (needsFetch) {
          performedFetch = true;
          fetchMode = 'diffCursor';
          fetchReason = force
              ? 'forced'
              : (hasUpdate
                  ? 'inboxVersion'
                  : (meta.lastFetchedAt == null
                      ? 'missing'
                      : (meta.status == SyncedDayStatus.evicted ? 'evicted' : 'stale')));
          await _fetchInboxDay(normalized, force: force);
          await SyncedDayService.recordFetch(
            date: normalized,
            kind: SyncedDayKind.inbox,
            status: SyncedDayStatus.ready,
            versionHash: 'inboxRev:$remoteRev',
          );
          try {
            final nextSeen = remoteRev > localSeen ? remoteRev : localSeen;
            await InboxVersionService.setLocalSeenRev(nextSeen);
          } catch (_) {}
          SyncKpi.recordOnDemandFetch('inbox');
          await SyncedDayService.enforceRetention(kinds: _retentionKinds);
        } else {
          try {
            await SyncedDayService.recordVersionCheck(
              date: normalized,
              kind: SyncedDayKind.inbox,
              versionHash: 'inboxRev:$remoteRev',
            );
          } catch (_) {}
        }
        await SyncAllHistoryService.recordFinish(
          id: historyId,
          success: true,
          extra: <String, dynamic>{
            'performedRemoteCheck': performedRemoteCheck,
            'performedFetch': performedFetch,
            'force': force,
            if (performedFetch) 'fetchReason': fetchReason,
            if (performedFetch) 'fetchMode': fetchMode ?? 'diffCursor',
            'inboxVersionRemoteRev': remoteRev,
            'inboxVersionLocalSeen': localSeen,
            if (callerTag.isNotEmpty) 'caller': callerTag,
          },
        );
        return;
      }

      bool needsRemoteCheck = force || meta.lastVersionCheckAt == null;
      if (!needsRemoteCheck && meta.lastVersionCheckAt != null) {
        needsRemoteCheck =
            DateTime.now().difference(meta.lastVersionCheckAt!) >= freshnessWindow;
      }
      if (meta.status != SyncedDayStatus.ready) {
        needsRemoteCheck = true;
      }

      DayVersionDoc? remoteDoc;
      if (needsRemoteCheck) {
        performedRemoteCheck = true;
        remoteDoc = await TimelineVersionService.fetchRemoteDoc(normalized);
        if (remoteDoc != null) {
          final previousLocalToken = meta.lastVersionHash;
          final remoteToken = remoteDoc.hash ?? remoteDoc.version?.toString();
          final tokenMismatch = remoteToken != previousLocalToken;
          final remoteMissing = !(remoteDoc.exists);
          await SyncedDayService.recordVersionCheck(
            date: normalized,
            kind: SyncedDayKind.inbox,
            versionHash: remoteToken,
            versionWriteAt: remoteDoc.lastWriteAt,
          );
          meta = await SyncedDayService.get(normalized, SyncedDayKind.inbox) ?? meta;
          if (force || remoteMissing || tokenMismatch) {
            await SyncedDayService.markStatus(
              normalized,
              SyncedDayKind.inbox,
              SyncedDayStatus.stale,
            );
            meta = await SyncedDayService.get(normalized, SyncedDayKind.inbox) ?? meta;
          }
        } else if (force) {
          await SyncedDayService.markStatus(
            normalized,
            SyncedDayKind.inbox,
            SyncedDayStatus.stale,
          );
          meta = await SyncedDayService.get(normalized, SyncedDayKind.inbox) ?? meta;
        }
      }

      if (meta.status != SyncedDayStatus.ready) {
        performedFetch = true;
        fetchReason = force
            ? 'forced'
            : (meta.lastFetchedAt == null
                ? 'missing'
                : (meta.status == SyncedDayStatus.evicted ? 'evicted' : 'stale'));
        // ignore: avoid_print
        print('[NEEDFETCH][inbox] date=${normalized.toIso8601String()} reason=$fetchReason');
        await _fetchInboxDay(normalized, force: force);
        remoteDoc ??= await TimelineVersionService.fetchRemoteDoc(normalized);
        await SyncedDayService.recordFetch(
          date: normalized,
          kind: SyncedDayKind.inbox,
          status: SyncedDayStatus.ready,
          versionHash: remoteDoc?.hash ?? remoteDoc?.version?.toString(),
          versionWriteAt: remoteDoc?.lastWriteAt,
        );
        SyncKpi.recordOnDemandFetch('inbox');
        await SyncedDayService.enforceRetention(kinds: _retentionKinds);
      }
      await SyncAllHistoryService.recordFinish(
        id: historyId,
        success: true,
        extra: <String, dynamic>{
          'performedRemoteCheck': performedRemoteCheck,
          'performedFetch': performedFetch,
          'force': force,
          if (performedFetch) 'fetchReason': fetchReason,
          if (performedFetch) 'fetchMode': 'diffCursor',
          if (callerTag.isNotEmpty) 'caller': callerTag,
        },
      );
    } catch (e) {
      await SyncAllHistoryService.recordFailed(
        id: historyId,
        error: e.toString(),
        extra: callerTag.isNotEmpty ? <String, dynamic>{'caller': callerTag} : null,
      );
      rethrow;
    }
  }

  static Future<String> _fetchTimelineDay(
    DateTime date, {
    DayVersionDoc? remoteDoc,
    bool force = false,
  }) async {
    // タイムライン画面で必要なデータ（当日表示分）を「日付スコープ」で最新化する。
    //
    // 背景:
    // - 以前は `syncIfStale({actualTasks, blocks, inboxTasks})` による “全体差分” を使っていたが、
    //   タイムライン表示に無関係な blocks 更新まで拾って read が増えやすかった。
    // - ここでは「表示中の日付」だけを最新化する（画面要件に一致）。
    //
    // NOTE:
    // - InboxTask は TimelineScreen 側で ensureInboxDay(date) を同フローで呼ぶため、
    //   ここでは blocks/actual に限定する（重複同期を避ける）。
    try {
      await BlockOutboxManager.flush();
    } catch (_) {}

    if (!force) {
      final changeLogSupported = remoteDoc?.changeLogVersion != null;
      if (changeLogSupported) {
        final ok = await _applyTimelineChangeLog(date);
        if (ok) {
          return 'changeLog';
        }
      }
    }

    // Fallback: dayKey full sync (for legacy/missing change log).
    // 予定ブロックを先にDLする（実績ブロックは予定ブロックに紐づくため）。
    final blockRes = await BlockSyncService().syncBlocksByDayKey(date);
    if (blockRes.success != true) {
      throw StateError('onDemand timeline block dayKey sync failed');
    }
    final actualRes = await ActualTaskSyncService().syncTasksByDayKey(date);
    if (actualRes.success != true) {
      throw StateError('onDemand timeline actual dayKey sync failed');
    }
    return force ? 'dayKeyForced' : 'dayKey';
  }

  static Future<bool> _applyTimelineChangeLog(DateTime date) async {
    try {
      await SyncedDayService.initialize();
      final meta = await SyncedDayService.get(date, SyncedDayKind.timeline) ??
          await SyncedDayService.upsert(
            date,
            SyncedDayKind.timeline,
            initialStatus: SyncedDayStatus.seeded,
          );
      DateTime? cursorAt = meta.lastChangeAt;
      String? cursorDocId = meta.lastChangeDocId;
      DateTime? lastAt = cursorAt;
      String? lastDocId = cursorDocId;
      int processed = 0;
      bool hadErrors = false;
      int pages = 0;
      while (pages < 20) {
        pages++;
        final page = await DayChangeLogService.fetchChanges(
          date,
          cursorAt: lastAt,
          cursorDocId: lastDocId,
        );
        if (page.entries.isEmpty) break;
        for (final entry in page.entries) {
          try {
            await _applyTimelineChangeEntry(entry);
            processed++;
          } catch (_) {
            hadErrors = true;
          }
        }
        if (page.lastChangedAt == null || page.lastDocId == null) {
          hadErrors = true;
          break;
        }
        lastAt = page.lastChangedAt;
        lastDocId = page.lastDocId;
        if (!page.hasMore) break;
      }
      if (hadErrors) {
        return false;
      }
      if (processed > 0 && lastAt != null && lastDocId != null) {
        await SyncedDayService.recordChangeCursor(
          date: date,
          kind: SyncedDayKind.timeline,
          lastChangeAt: lastAt,
          lastChangeDocId: lastDocId,
        );
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _applyTimelineChangeEntry(DayChangeLogEntry entry) async {
    switch (entry.collection) {
      case 'blocks':
        if (entry.deleted) {
          await _deleteLocalBlock(entry.docId);
          return;
        }
        await _fetchAndApplyBlock(entry.docId);
        return;
      case 'actual_tasks':
        if (entry.deleted) {
          await _deleteLocalActualTask(entry.docId);
          return;
        }
        await _fetchAndApplyActualTask(entry.docId);
        return;
      default:
        return;
    }
  }

  static Future<void> _fetchAndApplyBlock(String cloudId) async {
    final sync = BlockSyncService();
    final remote = await sync.downloadItemFromFirebase(cloudId);
    if (remote == null) return;
    if (remote.isDeleted == true) {
      await _deleteLocalBlock(cloudId);
      return;
    }
    await sync.saveToLocal(remote);
  }

  static Future<void> _fetchAndApplyActualTask(String cloudId) async {
    final sync = ActualTaskSyncService();
    final remote = await sync.downloadItemFromFirebase(cloudId);
    if (remote == null) return;
    if (remote.isDeleted == true) {
      await _deleteLocalActualTask(cloudId);
      return;
    }
    await sync.saveToLocal(remote);
  }

  static Future<void> _deleteLocalBlock(String cloudId) async {
    final sync = BlockSyncService();
    Block? local;
    try {
      local = await sync.getLocalItemByCloudId(cloudId);
    } catch (_) {
      local = null;
    }
    local ??= BlockService.getBlockById(cloudId);
    if (local != null) {
      await sync.deleteLocalItem(local);
    }
  }

  static Future<void> _deleteLocalActualTask(String cloudId) async {
    final sync = ActualTaskSyncService();
    ActualTask? local;
    try {
      local = await sync.getLocalItemByCloudId(cloudId);
    } catch (_) {
      local = null;
    }
    local ??= ActualTaskService.getActualTask(cloudId);
    if (local != null) {
      await sync.deleteLocalItem(local);
    }
  }

  static Future<void> _fetchInboxDay(DateTime date, {bool force = false}) async {
    // 徹底して差分同期（lastModified cursor）に寄せる。
    final results = force
        ? await SyncManager.syncDataFor(
            {DataSyncTarget.inboxTasks},
            forceHeavy: false,
          )
        : await SyncManager.syncIfStale(
            {DataSyncTarget.inboxTasks},
            minFreshDuration: _diffSyncMinInterval,
            forceHeavy: false,
          );
    final r = results[DataSyncTarget.inboxTasks];
    if (force) {
      if (r == null || r.success != true) {
        throw StateError('onDemand inbox diff sync failed');
      }
      return;
    }
    if (r != null && r.success != true) {
      throw StateError('onDemand inbox diff sync failed');
    }
  }
}
