import 'package:flutter/foundation.dart';

import '../models/synced_day.dart';
import 'synced_day_service.dart';
import 'sync_kpi.dart';
import 'sync_all_history_service.dart';
import 'timeline_version_service.dart';
import 'version_cursor_service.dart';

class VersionFeedService {
  VersionFeedService._();

  static const _maxBatch = 50;
  static DateTime? _lastPullAtUtc;
  static Future<void>? _inFlight;
  static DateTime? _lastSkipRecordedAtUtc;

  static Future<void> pullTimelineUpdates({
    bool mirrorToInbox = true,
    Duration minInterval = const Duration(seconds: 30),
    bool force = false,
  }) async {
    final now = DateTime.now().toUtc();
    final last = _lastPullAtUtc;
    if (!force && last != null && now.difference(last) < minInterval) {
      // スキップが多い場合の調査用（スパム防止のため記録は間引く）
      final lastSkip = _lastSkipRecordedAtUtc;
      if (lastSkip == null || now.difference(lastSkip) > const Duration(seconds: 60)) {
        _lastSkipRecordedAtUtc = now;
        await SyncAllHistoryService.recordSimpleEvent(
          type: 'versionFeed',
          reason: 'versionFeed pull skipped (minInterval)',
          origin: 'VersionFeedService.pullTimelineUpdates',
          extra: <String, dynamic>{
            'force': force,
            'minIntervalMs': minInterval.inMilliseconds,
            'sinceLastMs': now.difference(last).inMilliseconds,
            'mirrorToInbox': mirrorToInbox,
            'maxBatch': _maxBatch,
          },
        );
      }
      return;
    }
    final inflight = _inFlight;
    if (inflight != null) {
      final lastSkip = _lastSkipRecordedAtUtc;
      if (lastSkip == null || now.difference(lastSkip) > const Duration(seconds: 60)) {
        _lastSkipRecordedAtUtc = now;
        await SyncAllHistoryService.recordSimpleEvent(
          type: 'versionFeed',
          reason: 'versionFeed pull skipped (inFlight)',
          origin: 'VersionFeedService.pullTimelineUpdates',
          extra: <String, dynamic>{
            'force': force,
            'minIntervalMs': minInterval.inMilliseconds,
            'mirrorToInbox': mirrorToInbox,
            'maxBatch': _maxBatch,
          },
        );
      }
      return await inflight;
    }

    _lastPullAtUtc = now;
    _inFlight = () async {
      final historyId = await SyncAllHistoryService.recordEventStart(
        type: 'versionFeed',
        reason: 'versionFeed pull',
        origin: 'VersionFeedService.pullTimelineUpdates',
        extra: <String, dynamic>{
          'force': force,
          'minIntervalMs': minInterval.inMilliseconds,
          'mirrorToInbox': mirrorToInbox,
          'maxBatch': _maxBatch,
        },
      );
      await SyncedDayService.initialize();

      final baseCursor = await VersionCursorService.load(SyncedDayKind.timeline);
      final result = await TimelineVersionService.fetchUpdatesSince(
        kind: SyncedDayKind.timeline,
        cursor: baseCursor,
        limit: _maxBatch,
      );

      if (result.entries.isEmpty) {
        await VersionCursorService.save(SyncedDayKind.timeline, result.cursor);
        if (mirrorToInbox) {
          await VersionCursorService.save(SyncedDayKind.inbox, result.cursor);
        }
        await SyncAllHistoryService.recordFinish(
          id: historyId,
          success: true,
          syncedCount: 0,
          failedCount: 0,
          extra: <String, dynamic>{
            'entries': 0,
            'hasMore': result.hasMore,
          },
        );
        return;
      }

      for (final entry in result.entries) {
        final date = entry.date;
        if (date == null) {
          if (kDebugMode) {
            print('?? VersionFeed: invalid dateKey=${entry.dateKey}');
          }
          continue;
        }

        await SyncedDayService.recordVersionCheck(
          date: date,
          kind: SyncedDayKind.timeline,
          versionHash: entry.hash ?? entry.version?.toString(),
          versionWriteAt: entry.lastWriteAt,
        );
        await SyncedDayService.markStatus(
          date,
          SyncedDayKind.timeline,
          SyncedDayStatus.stale,
        );

        if (mirrorToInbox) {
          await SyncedDayService.recordVersionCheck(
            date: date,
            kind: SyncedDayKind.inbox,
            versionHash: entry.hash ?? entry.version?.toString(),
            versionWriteAt: entry.lastWriteAt,
          );
          await SyncedDayService.markStatus(
            date,
            SyncedDayKind.inbox,
            SyncedDayStatus.stale,
          );
        }
      }

      SyncKpi.recordVersionFeed(result.entries.length);

      await VersionCursorService.save(
        SyncedDayKind.timeline,
        result.cursor,
      );
      if (mirrorToInbox) {
        await VersionCursorService.save(
          SyncedDayKind.inbox,
          result.cursor,
        );
      }
      await SyncAllHistoryService.recordFinish(
        id: historyId,
        success: true,
        syncedCount: result.entries.length,
        failedCount: 0,
        extra: <String, dynamic>{
          'entries': result.entries.length,
          'hasMore': result.hasMore,
        },
      );
    }();
    try {
      await _inFlight;
    } finally {
      _inFlight = null;
    }
  }
}
