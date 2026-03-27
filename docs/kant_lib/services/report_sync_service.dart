import 'dart:async';
import '../models/synced_day.dart';
import '../models/actual_task.dart';
import '../models/block.dart';
import 'synced_day_service.dart';
import 'day_key_service.dart';
import 'timeline_version_service.dart';
import 'actual_task_sync_service.dart';
import 'actual_task_service.dart';
import 'block_sync_service.dart';
import 'block_service.dart';
import 'day_change_log_service.dart';
import 'sync_kpi.dart';
import 'sync_all_history_service.dart';
import 'auth_service.dart';
import 'version_cursor_service.dart';

/// レポート同期の結果
class ReportSyncResult {
  final bool success;
  final List<DateTime> syncedDays;
  final List<DateTime> failedDays;
  final List<String> monthKeys;
  final String? error;
  final int readEstimate;
  final int syncedCount;
  final int failedCount;

  ReportSyncResult({
    required this.success,
    this.syncedDays = const [],
    this.failedDays = const [],
    this.monthKeys = const [],
    this.error,
    this.readEstimate = 0,
    this.syncedCount = 0,
    this.failedCount = 0,
  });
}

/// レポート画面専用の同期サービス
class ReportSyncService {
  ReportSyncService._();

  static const Duration _reportVersionFeedMinInterval = Duration(minutes: 5);
  static const Duration _versionCheckFreshnessWindow = Duration(minutes: 5);
  static const int _reportVersionFeedBatchLimit = 120;
  static DateTime? _lastReportVersionFeedAtUtc;

  static DateTime? _dateFromDayKey(String dayKey) {
    final parts = dayKey.split('-');
    if (parts.length != 3) return null;
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    if (year == null || month == null || day == null) return null;
    return DateTime(year, month, day);
  }

  static String _monthKeyFromDate(DateTime date) {
    final y = date.year.toString().padLeft(4, '0');
    final m = date.month.toString().padLeft(2, '0');
    return '$y-$m';
  }

  static Future<void> _refreshStatusesByDayVersions(List<String> dayKeys) async {
    final now = DateTime.now();
    for (final dayKey in dayKeys) {
      final date = _dateFromDayKey(dayKey);
      if (date == null) continue;
      try {
        final syncedDay = await SyncedDayService.get(date, SyncedDayKind.report);

        // ready かつ最近バージョンチェック済みならスキップ（Firebase読み取りを抑制）
        if (syncedDay != null &&
            syncedDay.status == SyncedDayStatus.ready &&
            syncedDay.lastVersionCheckAt != null &&
            now.difference(syncedDay.lastVersionCheckAt!) < _versionCheckFreshnessWindow) {
          continue;
        }

        final remoteDoc = await TimelineVersionService.fetchRemoteDoc(date);
        if (remoteDoc == null) continue;
        final remoteToken = remoteDoc.hash ?? remoteDoc.version?.toString();
        final localToken = syncedDay?.lastVersionHash;

        if (remoteToken != null &&
            localToken != null &&
            remoteToken != localToken) {
          await SyncedDayService.recordVersionCheck(
            date: date,
            kind: SyncedDayKind.report,
            versionHash: remoteToken,
            versionWriteAt: remoteDoc.lastWriteAt,
          );
          await SyncedDayService.markStatus(
            date,
            SyncedDayKind.report,
            SyncedDayStatus.stale,
          );
        } else {
          // ハッシュ一致 or 初回: バージョンチェック時刻を記録（staleにはしない）
          await SyncedDayService.recordVersionCheck(
            date: date,
            kind: SyncedDayKind.report,
            versionHash: remoteToken,
            versionWriteAt: remoteDoc.lastWriteAt,
          );
        }
      } catch (_) {
        // エラー時はスキップ
      }
    }
  }

  /// version feed で stale 判定を行う
  /// Phase 2: hasMore ループ対応、force パラメータ追加
  static Future<void> _pullReportVersionFeedForRange({
    required DateTime start,
    required DateTime end,
    bool force = false,
  }) async {
    final now = DateTime.now().toUtc();
    final lastPull = _lastReportVersionFeedAtUtc;

    // force=true 時は throttle をバイパス
    if (!force &&
        lastPull != null &&
        now.difference(lastPull) < _reportVersionFeedMinInterval) {
      return;
    }
    _lastReportVersionFeedAtUtc = now;

    try {
      var cursor = await VersionCursorService.load(SyncedDayKind.report);
      final isInitialCursor = cursor.lastSeenDocId.isEmpty &&
          cursor.lastSeenWriteAt.millisecondsSinceEpoch == 0;
      if (isInitialCursor) {
        await VersionCursorService.save(
          SyncedDayKind.report,
          VersionCursor(lastSeenWriteAt: now, lastSeenDocId: ''),
        );
        return;
      }

      // hasMore ループ対応（最大 10 ページ = 1200 件）
      int totalPages = 0;
      const maxPages = 10;
      bool hasMore = true;

      while (hasMore && totalPages < maxPages) {
        totalPages++;

        final result = await TimelineVersionService.fetchUpdatesSince(
          kind: SyncedDayKind.report,
          cursor: cursor,
          limit: _reportVersionFeedBatchLimit,
        );

        if (result.entries.isNotEmpty) {
          for (final entry in result.entries) {
            final date = entry.date;
            if (date == null) continue;
            if (date.isBefore(start) || !date.isBefore(end)) continue;
            final token = entry.hash ?? entry.version?.toString();

            // ローカルのハッシュと比較し、実際に変わっていなければstaleにしない
            final syncedDay =
                await SyncedDayService.get(date, SyncedDayKind.report);
            final localToken = syncedDay?.lastVersionHash;
            final actuallyChanged = localToken == null || token != localToken;

            await SyncedDayService.recordVersionCheck(
              date: date,
              kind: SyncedDayKind.report,
              versionHash: token,
              versionWriteAt: entry.lastWriteAt,
            );
            if (actuallyChanged) {
              await SyncedDayService.markStatus(
                date,
                SyncedDayKind.report,
                SyncedDayStatus.stale,
              );
            }
          }
        }

        cursor = result.cursor;
        await VersionCursorService.save(SyncedDayKind.report, cursor);
        hasMore = result.hasMore;
      }
    } catch (_) {
      // エラー時は呼び出し元で継続
    }
  }

  /// 定期全件再同期の間隔（7日）
  static const Duration _periodicFullSyncInterval = Duration(days: 7);

  /// 定期全件再同期が必要かどうかを判定
  static bool _needsPeriodicFullSync(SyncedDay day) {
    if (day.status != SyncedDayStatus.ready) return false;
    final lastFull = day.lastFullSyncAt;
    if (lastFull == null) return true; // 一度も全件同期していない
    return DateTime.now().difference(lastFull) > _periodicFullSyncInterval;
  }

  static Future<List<DateTime>> _collectDaysToSync(List<String> dayKeys) async {
    final daysToSync = <DateTime>[];
    for (final dayKey in dayKeys) {
      final date = _dateFromDayKey(dayKey);
      if (date == null) continue;
      final syncedDay = await SyncedDayService.get(date, SyncedDayKind.report);

      // 未取得 or stale → 同期必要
      if (syncedDay == null || syncedDay.status == SyncedDayStatus.stale) {
        daysToSync.add(date);
        continue;
      }

      // ready だが定期全件再同期が必要（7日ごと）
      if (_needsPeriodicFullSync(syncedDay)) {
        daysToSync.add(date);
        continue;
      }
    }
    return daysToSync;
  }

  /// 同期後にバージョンハッシュを記録する。
  /// markStatusBatch では lastVersionHash が設定されないため、
  /// 次回のバージョンチェックで正しく差分検出できるよう補完する。
  static Future<void> _recordVersionHashesAfterSync(List<DateTime> dates) async {
    for (final date in dates) {
      try {
        final syncedDay = await SyncedDayService.get(date, SyncedDayKind.report);
        if (syncedDay != null &&
            syncedDay.status == SyncedDayStatus.ready &&
            syncedDay.lastVersionHash != null) {
          continue;
        }
        final remoteDoc = await TimelineVersionService.fetchRemoteDoc(date);
        if (remoteDoc == null) continue;
        final token = remoteDoc.hash ?? remoteDoc.version?.toString();
        await SyncedDayService.recordVersionCheck(
          date: date,
          kind: SyncedDayKind.report,
          versionHash: token,
          versionWriteAt: remoteDoc.lastWriteAt,
        );
      } catch (_) {}
    }
  }

  // ============================================================
  // Phase 1: changeLog ベースの差分取得
  // ============================================================

  /// changeLog ベースの差分同期を試行する。
  /// 成功時は true を返す。失敗時は false を返す（呼び出し元でフォールバック）。
  /// processedDocIds: 日をまたぐ重複処理を防ぐためのセット（呼び出し元で管理）
  static Future<bool> _applyReportChangeLog(
    DateTime date, {
    Set<String>? processedDocIds,
  }) async {
    try {
      await SyncedDayService.initialize();
      final meta = await SyncedDayService.get(date, SyncedDayKind.report);

      // ────────────────────────────────────────
      // 安全策: カーソル未設定の場合は changeLog 差分を試みない。
      // cursorAt=null で fetchChanges すると全履歴が返り、reads 爆発する。
      // ────────────────────────────────────────
      if (meta == null || meta.lastChangeAt == null) {
        return false; // → 呼び出し元でフォールバック（全件取得）
      }

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
          // 日をまたぐ重複スキップ
          final dedupeKey = '${entry.collection}:${entry.docId}';
          if (processedDocIds != null && !processedDocIds.add(dedupeKey)) {
            continue;
          }
          try {
            await _applyReportChangeEntry(entry);
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
        return false; // → フォールバック
      }

      // ────────────────────────────────────────
      // 欠損検出: stale なのに changeLog が 0 件
      //   → Cloud Functions 失敗で changeLog が書かれなかった可能性
      //   → フォールバック（全件取得）で安全に同期
      // ────────────────────────────────────────
      if (processed == 0 && meta.status == SyncedDayStatus.stale) {
        return false; // → フォールバック
      }

      // カーソル更新
      if (processed > 0 && lastAt != null && lastDocId != null) {
        await SyncedDayService.recordChangeCursor(
          date: date,
          kind: SyncedDayKind.report,
          lastChangeAt: lastAt,
          lastChangeDocId: lastDocId,
        );
      }

      return true;
    } catch (_) {
      return false;
    }
  }

  /// changeLogエントリを適用する
  static Future<void> _applyReportChangeEntry(DayChangeLogEntry entry) async {
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

  /// 個別ブロックを取得して適用
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

  /// 個別実績タスクを取得して適用
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

  /// ローカルのブロックを削除
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

  /// ローカルの実績タスクを削除
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

  /// レポート画面表示前に、指定期間の actual_tasks / blocks を同期する
  ///
  /// [start]: 期間の開始日（date-only、ローカル時刻）
  /// [end]: 期間の終了日（date-only、ローカル時刻、exclusive）
  /// [force]: trueの場合、version feed の throttle をバイパス
  /// 戻り値: ReportSyncResult（success, syncedDays, monthKeys, error 等を含む）
  static Future<ReportSyncResult> ensureRange({
    required DateTime start,
    required DateTime end,
    bool force = false,
  }) async {
    final kpiBefore = SyncKpi.snapshot();

    String? historyId;
    try {
      historyId = await SyncAllHistoryService.recordEventStart(
        type: 'reportSync',
        reason: 'report sync ensureRange',
        origin: 'ReportSyncService.ensureRange',
        userId: AuthService.getCurrentUserId(),
        extra: <String, dynamic>{
          'start': start.toIso8601String(),
          'end': end.toIso8601String(),
          'force': force,
        },
        includeKpiSnapshot: true,
      );

      await evictOldReportDays();

      final startUtc = DateTime.utc(start.year, start.month, start.day);
      final endUtc = DateTime.utc(end.year, end.month, end.day);
      final dayKeys = DayKeyService.computeDayKeysUtc(startUtc, endUtc);

      // Phase 2: 全期間で version feed を使用（日単位処理に統一）
      await _pullReportVersionFeedForRange(start: start, end: end, force: force);

      final daysToSync = await _collectDaysToSync(dayKeys);

      final syncedDays = <DateTime>[];
      final syncedDayKeys = <String>{};
      final failedDays = <DateTime>[];
      int totalSyncedCount = 0;
      int totalFailedCount = 0;
      int changeLogSyncedCount = 0;
      int fallbackSyncedCount = 0;

      void appendSyncedDay(DateTime date) {
        final key = DayKeyService.formatDayKeyYmd(date.year, date.month, date.day);
        if (syncedDayKeys.add(key)) {
          syncedDays.add(date);
        }
      }

      // 日をまたぐ重複処理を防ぐためのセット（ensureRange 全体で共有）
      final processedDocIds = <String>{};

      // 日単位で処理（changeLog優先、失敗時はdayKey全件取得にフォールバック）
      for (final date in daysToSync) {
        try {
          final meta = await SyncedDayService.get(date, SyncedDayKind.report);

          // ── CASE A: changeLog カーソルあり → changeLog差分同期を試行 ──
          bool changeLogSuccess = false;
          if (meta != null && meta.lastChangeAt != null) {
            changeLogSuccess = await _applyReportChangeLog(
              date,
              processedDocIds: processedDocIds,
            );

            if (changeLogSuccess) {
              await SyncedDayService.markStatus(
                date,
                SyncedDayKind.report,
                SyncedDayStatus.ready,
              );
              // バージョンハッシュを最新化
              try {
                final remoteDoc = await TimelineVersionService.fetchRemoteDoc(date);
                if (remoteDoc != null) {
                  final token = remoteDoc.hash ?? remoteDoc.version?.toString();
                  await SyncedDayService.recordVersionCheck(
                    date: date,
                    kind: SyncedDayKind.report,
                    versionHash: token,
                    versionWriteAt: remoteDoc.lastWriteAt,
                  );
                }
              } catch (_) {}
              appendSyncedDay(date);
              changeLogSyncedCount++;
              totalSyncedCount++;
              continue;
            }
          }

          // ── CASE B: フォールバック（全件取得） ──
          // 実行条件:
          // - changeLog カーソル未設定（初回/移行期間）
          // - changeLog 差分取得失敗
          // - changeLog 欠損検出（stale なのに 0 件）
          // - SyncedDay が存在しない（missing）

          // 全件取得開始前の時刻を記録（カーソル初期化用）
          final beforeSync = DateTime.now();

          // レポート同期ではrunningタスクの取得は不要
          final taskResult = await ActualTaskSyncService().syncTasksByDayKey(
            date,
            skipRunningQuery: true,
          );
          final blockResult = await BlockSyncService().syncBlocksByDayKey(date);

          if (taskResult.success && blockResult.success) {
            await SyncedDayService.markStatus(
              date,
              SyncedDayKind.report,
              SyncedDayStatus.ready,
            );

            // バージョンハッシュを記録
            try {
              final remoteDoc = await TimelineVersionService.fetchRemoteDoc(date);
              if (remoteDoc != null) {
                final token = remoteDoc.hash ?? remoteDoc.version?.toString();
                await SyncedDayService.recordVersionCheck(
                  date: date,
                  kind: SyncedDayKind.report,
                  versionHash: token,
                  versionWriteAt: remoteDoc.lastWriteAt,
                );
              }
            } catch (_) {}

            // changeLogカーソルを初期化（次回から差分同期が可能に）
            // 注: 全件取得開始前の時刻を使用し、同期中の変更を取りこぼさない
            await SyncedDayService.recordChangeCursor(
              date: date,
              kind: SyncedDayKind.report,
              lastChangeAt: beforeSync,
              lastChangeDocId: '',
            );

            // 全件同期完了時刻を記録（定期再同期判定用）
            await SyncedDayService.recordFullSyncAt(
              date: date,
              kind: SyncedDayKind.report,
            );

            appendSyncedDay(date);
            fallbackSyncedCount++;
            totalSyncedCount += taskResult.syncedCount + blockResult.syncedCount;
          } else {
            failedDays.add(date);
            totalFailedCount += 1;
          }
        } catch (e) {
          print('⚠️ Report sync failed for date=$date: $e');
          failedDays.add(date);
          totalFailedCount += 1;
        }
      }

      final kpiAfter = SyncKpi.snapshot();
      final kpiDelta = SyncKpi.delta(kpiBefore, kpiAfter);
      final readEstimate = kpiDelta['queryReads'] ?? 0;

      final result = ReportSyncResult(
        success: totalFailedCount == 0,
        syncedDays: syncedDays,
        failedDays: failedDays,
        monthKeys: [], // monthKey同期は廃止
        readEstimate: readEstimate,
        syncedCount: totalSyncedCount,
        failedCount: totalFailedCount,
      );

      await SyncAllHistoryService.recordFinish(
        id: historyId,
        success: result.success,
        syncedCount: syncedDays.length,
        failedCount: failedDays.length,
        extra: <String, dynamic>{
          'syncedDays': syncedDays.length,
          'failedDays': failedDays.length,
          'changeLogSynced': changeLogSyncedCount,
          'fallbackSynced': fallbackSyncedCount,
          'readEstimate': readEstimate,
          'daysToSyncCount': daysToSync.length,
        },
        includeKpiDelta: true,
      );

      return result;
    } catch (e, stackTrace) {
      print('❌ Report sync ensureRange failed: $e\n$stackTrace');
      
      if (historyId != null) {
        await SyncAllHistoryService.recordFailed(
          id: historyId,
          error: e.toString(),
          extra: <String, dynamic>{
            'start': start.toIso8601String(),
            'end': end.toIso8601String(),
          },
        );
      }

      return ReportSyncResult(
        success: false,
        error: e.toString(),
        failedCount: 1,
      );
    }
  }

  /// 古い report:ready エントリを削除する
  static Future<void> evictOldReportDays({
    Duration retentionPeriod = const Duration(days: 365),
  }) async {
    await SyncedDayService.initialize();
    final allReportDays = await SyncedDayService.allDays(SyncedDayKind.report);
    final cutoff = DateTime.now().subtract(retentionPeriod);
    final toEvict = allReportDays
        .where((d) =>
            d.status == SyncedDayStatus.ready &&
            d.lastFetchedAt != null &&
            d.lastFetchedAt!.isBefore(cutoff))
        .toList();
    await SyncedDayService.removeMany(toEvict.map((d) => d.id));
  }
}
