import 'dart:async';
import 'dart:collection';
import '../models/syncable_model.dart';

import 'device_info_service.dart';
import 'network_manager.dart';
import 'project_sync_service.dart';
import 'actual_task_sync_service.dart';
import 'sub_project_sync_service.dart';
import 'routine_template_v2_sync_service.dart';
import 'routine_block_v2_sync_service.dart';
import 'routine_task_v2_sync_service.dart';
import 'mode_sync_service.dart';
import 'category_sync_service.dart';
import 'block_sync_service.dart';
import 'inbox_task_sync_service.dart';
import 'app_settings_service.dart';
import 'sync_all_history_service.dart';
import 'sync_kpi.dart';
import 'sync_context.dart';

import 'block_outbox_manager.dart';
import 'task_outbox_manager.dart';
import '../utils/async_mutex.dart';

/// 同期マネージャー - 全ての同期処理を統括
class SyncManager {
  static bool _isInitialized = false;
  static SyncStatus _currentStatus = SyncStatus.idle;
  static final Queue<SyncOperation> _syncQueue = Queue<SyncOperation>();
  static final StreamController<SyncStatus> _statusController =
      StreamController<SyncStatus>.broadcast();
  static final Map<String, DateTime> _lastSyncTimes = {};
  static Timer? _periodicSyncTimer;
  static bool _isSyncing = false;
  static final AsyncMutex _targetSyncMutex = AsyncMutex();
  static final Map<DataSyncTarget, DateTime> _lastTargetSyncTimes = {};
  static const Map<DataSyncTarget, Duration> _defaultTargetFreshness = {
    DataSyncTarget.actualTasks: Duration(minutes: 2),
    DataSyncTarget.blocks: Duration(minutes: 2),
    DataSyncTarget.inboxTasks: Duration(minutes: 3),
    DataSyncTarget.projects: Duration(minutes: 10),
  };

  // 直近のエラー情報（最大50件）
  static final List<SyncErrorEntry> _recentErrors = <SyncErrorEntry>[];

  /// 現在の同期状態
  static SyncStatus get currentStatus => _currentStatus;

  /// 同期状態の変更を監視するストリーム
  static Stream<SyncStatus> get syncStatusStream => _statusController.stream;

  /// 直近のエラー一覧を取得
  static List<SyncErrorEntry> getRecentErrors() =>
      List.unmodifiable(_recentErrors);

  static void _recordError(String source, Object error) {
    final message = error.toString();
    _recentErrors.add(SyncErrorEntry(
      source: source,
      message: message.length > 200 ? '${message.substring(0, 200)}…' : message,
      occurredAt: DateTime.now(),
    ));
    // サイズ制限
    if (_recentErrors.length > 50) {
      _recentErrors.removeRange(0, _recentErrors.length - 50);
    }
  }

  /// 同期マネージャーを初期化
  static Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      // 依存サービスの初期化を確認
      await DeviceInfoService.initialize();
      await NetworkManager.initialize();

      // ネットワーク状態の変更を監視
      NetworkManager.connectivityStream.listen(_handleNetworkChange);

      // Disable periodic fallback sync; per-screen background sync will be triggered on UI navigation

      _updateStatus(SyncStatus.idle);
      _isInitialized = true;

      // 起動時の差分同期（軽量）をバックグラウンドで実行
      unawaited(runStartupDiffSync());
    } catch (e) {
      _recordError('Initialize', e);
      _updateStatus(SyncStatus.error);
      rethrow;
    }
  }

    /// 起動時に設定系/マスタ系の差分のみ同期
    ///
    /// NOTE:
    /// - 画面表示（タイムライン/インボックス）の onDemand 同期や post-auth sync と競合すると
    ///   初回に近い heavy read（fullFetch/巨大diff）が二重に走りやすい。
    /// - ここでは “マスタ系のみ” に限定し、タスク系（inbox 等）は画面側の差分同期に任せる。
    static Future<void> runStartupDiffSync() async {
      if (!NetworkManager.isOnline) return;
        try {
        // 画面初期描画・タイムラインの初期同期を優先するため、わずかに遅延
        await Future.delayed(const Duration(seconds: 2));
        await AppSettingsService.initialize();

          final projectsCur =
              AppSettingsService.getCursor(AppSettingsService.keyCursorProjects);
          final subProjectsCur =
              AppSettingsService.getCursor(AppSettingsService.keyCursorSubProjects);
          final modesCur =
              AppSettingsService.getCursor(AppSettingsService.keyCursorModes);
          final categoriesCur =
              AppSettingsService.getCursor(AppSettingsService.keyCursorCategories);

          final syncFutures = <String, Future<SyncResult>>{
            'projects': projectsCur != null
                ? ProjectSyncService().syncProjectsSince(projectsCur)
                : ProjectSyncService.syncAllProjects(),
            'subProjects': subProjectsCur != null
                ? SubProjectSyncService().syncSubProjectsSince(subProjectsCur)
                : SubProjectSyncService.syncAllSubProjects(),
            'modes': modesCur != null
                ? ModeSyncService().syncModesSince(modesCur)
                : ModeSyncService.syncAllModes(),
            'categories': categoriesCur != null
                ? CategorySyncService().syncCategoriesSince(categoriesCur)
                : CategorySyncService.syncAllCategories(),
          };

          final resultEntries = await Future.wait(syncFutures.entries.map(
            (entry) async {
              try {
                final result = await entry.value;
                return MapEntry(entry.key, result);
              } catch (e) {
                return MapEntry(
                  entry.key,
                  SyncResult(success: false, error: e.toString(), failedCount: 1),
                );
              }
            },
          ));
          final results = {
            for (final entry in resultEntries) entry.key: entry.value
          };

          final failedKeys = results.entries
              .where((entry) => entry.value.success != true)
              .map((entry) => entry.key)
              .toList();

          if (failedKeys.isEmpty) {
            final totalSynced =
                results.values.fold<int>(0, (s, r) => s + r.syncedCount);
            print('✅ Startup diff sync completed (synced=$totalSynced)');
          } else {
            for (final key in failedKeys) {
              final result = results[key];
              final message =
                  result?.error ?? 'Startup diff sync returned failure';
              _recordError('StartupDiff:$key', message);
            }
            print(
                '⚠️ Startup diff sync skipped cursor update due to failures: ${failedKeys.join(', ')}');
          }
      } catch (e) {
        _recordError('StartupDiff', e);
        print('⚠️ Startup diff sync failed: $e');
      }
    }

  /// 全データの同期を実行
  static Future<SyncResult> syncAll({
    String reason = 'unknown',
    String? origin,
    String? userId,
    Map<String, dynamic>? extra,
  }) async {
    if (!_isInitialized) {
      // 失敗しても「なぜ呼ばれたか」を残す
      final id = await SyncAllHistoryService.recordStart(
        reason: reason,
        origin: origin,
        userId: userId,
        extra: <String, dynamic>{'phase': 'precondition', if (extra != null) ...extra},
      );
      await SyncAllHistoryService.recordFailed(
        id: id,
        error: 'SyncManager not initialized',
      );
      throw StateError('SyncManager not initialized');
    }

    if (_isSyncing) {
      final id = await SyncAllHistoryService.recordStart(
        reason: reason,
        origin: origin,
        userId: userId,
        extra: <String, dynamic>{'phase': 'guard', if (extra != null) ...extra},
      );
      await SyncAllHistoryService.recordSkipped(
        id: id,
        reason: 'Sync already in progress',
      );
      return SyncResult(success: false, error: 'Sync already in progress');
    }

    if (!NetworkManager.isOnline) {
      final id = await SyncAllHistoryService.recordStart(
        reason: reason,
        origin: origin,
        userId: userId,
        extra: <String, dynamic>{'phase': 'guard', if (extra != null) ...extra},
      );
      await SyncAllHistoryService.recordSkipped(
        id: id,
        reason: 'Device is offline',
      );
      return SyncResult(success: false, error: 'Device is offline');
    }

    final historyId = await SyncAllHistoryService.recordStart(
      reason: reason,
      origin: origin,
      userId: userId,
      extra: extra,
    );

    try {
      _isSyncing = true;
      _updateStatus(SyncStatus.syncing);

      // アウトボックスを先にフラッシュ（未送信の作成/更新/削除を反映）
      try {
        await TaskOutboxManager.flush();
      } catch (e) {
        _recordError('TaskOutboxFlush', e);
      }
      try {
        await BlockOutboxManager.flush();
      } catch (e) {
        _recordError('BlockOutboxFlush', e);
      }

      final results = <SyncResult>[];
      int totalSynced = 0;
      int totalFailed = 0;
      final conflicts = <ConflictResolution>[];

      // Phase 1: マスタ・参照データを先に確実に取得（カテゴリ・ルーティン・プロジェクト等）
      // 他に依存されないものから順に実行。当日以外のブロック等は Phase 2 で後から取得する。

      // 1. Mode（他に依存されない）
      try {
        final modeResult = await ModeSyncService.syncAllModes();
        results.add(modeResult);
        totalSynced += modeResult.syncedCount;
        totalFailed += modeResult.failedCount;
        conflicts.addAll(modeResult.conflicts);
      } catch (e) {
        totalFailed++;
        _recordError('Mode', e);
      }

      // 2. Category（他に依存されない）
      try {
        final categoryResult = await CategorySyncService.syncAllCategories();
        results.add(categoryResult);
        totalSynced += categoryResult.syncedCount;
        totalFailed += categoryResult.failedCount;
        conflicts.addAll(categoryResult.conflicts);
      } catch (e) {
        totalFailed++;
        _recordError('Category', e);
      }

      // 3. Project
      try {
        final projectResult = await ProjectSyncService.syncAllProjects();
        results.add(projectResult);
        totalSynced += projectResult.syncedCount;
        totalFailed += projectResult.failedCount;
        conflicts.addAll(projectResult.conflicts);
      } catch (e) {
        totalFailed++;
        _recordError('Project', e);
      }

      // 4. SubProject（Project に依存）
      try {
        final subProjectResult =
            await SubProjectSyncService.syncAllSubProjects();
        results.add(subProjectResult);
        totalSynced += subProjectResult.syncedCount;
        totalFailed += subProjectResult.failedCount;
        conflicts.addAll(subProjectResult.conflicts);
      } catch (e) {
        totalFailed++;
        _recordError('SubProject', e);
      }

      // 5. Routine V2（Template → Block → Task の順。他に依存されないのでマスタとして先に取得）
      try {
        final tplV2 =
            await RoutineTemplateV2SyncService.syncAll(forceFullSync: false);
        results.add(tplV2);
        totalSynced += tplV2.syncedCount;
        totalFailed += tplV2.failedCount;
        conflicts.addAll(tplV2.conflicts);

        final blkV2 =
            await RoutineBlockV2SyncService.syncAll(forceFullSync: false);
        results.add(blkV2);
        totalSynced += blkV2.syncedCount;
        totalFailed += blkV2.failedCount;
        conflicts.addAll(blkV2.conflicts);

        final taskV2 =
            await RoutineTaskV2SyncService.syncAll(forceFullSync: false);
        results.add(taskV2);
        totalSynced += taskV2.syncedCount;
        totalFailed += taskV2.failedCount;
        conflicts.addAll(taskV2.conflicts);
      } catch (e) {
        totalFailed++;
        _recordError('RoutineV2', e);
      }

      // Phase 2: 実データ（ブロックは当日以外も含むが後回しでよい。マスタ取得後に実行）

      // 6. Block（予定ブロック。当日以外は後でもよいため Phase 2）
      try {
        final blockResult = await BlockSyncService.syncAllBlocks();
        results.add(blockResult);
        totalSynced += blockResult.syncedCount;
        totalFailed += blockResult.failedCount;
        conflicts.addAll(blockResult.conflicts);
      } catch (e) {
        totalFailed++;
        _recordError('Block', e);
      }

      // 7. ActualTask（実績。Project/Mode/Category/Block の後に取得）
      try {
        final taskResult = await ActualTaskSyncService.syncAllTasks();
        results.add(taskResult);
        totalSynced += taskResult.syncedCount;
        totalFailed += taskResult.failedCount;
        conflicts.addAll(taskResult.conflicts);
      } catch (e) {
        totalFailed++;
        _recordError('ActualTask', e);
      }

      // 8. InboxTask（受信ボックス。Project 等の後に取得）
      try {
        final inboxResult = await InboxTaskSyncService.syncAllInboxTasks();
        results.add(inboxResult);
        totalSynced += inboxResult.syncedCount;
        totalFailed += inboxResult.failedCount;
        conflicts.addAll(inboxResult.conflicts);
      } catch (e) {
        totalFailed++;
        _recordError('InboxTask', e);
      }

      final finalResult = SyncResult(
        success: totalFailed == 0,
        syncedCount: totalSynced,
        failedCount: totalFailed,
        conflicts: conflicts,
      );

      _updateStatus(totalFailed == 0 ? SyncStatus.synced : SyncStatus.error);
      _recordSyncTime();

      await SyncAllHistoryService.recordFinish(
        id: historyId,
        success: finalResult.success,
        syncedCount: finalResult.syncedCount,
        failedCount: finalResult.failedCount,
        error: finalResult.error,
      );
      return finalResult;
    } catch (e) {
      _recordError('SyncAll', e);
      _updateStatus(SyncStatus.error);
      await SyncAllHistoryService.recordFailed(
        id: historyId,
        error: e.toString(),
      );
      return SyncResult(success: false, error: e.toString());
    } finally {
      _isSyncing = false;
    }
  }

  /// 特定データ型の同期をキューに追加
  static void queueSync(SyncOperation operation) {
    _syncQueue.add(operation);

    // ネットワークが利用可能ならすぐに処理
    if (NetworkManager.isOnline && !_isSyncing) {
      _processSyncQueue();
    }
  }

  /// 同期キューを処理
  static Future<void> _processSyncQueue() async {
    if (_syncQueue.isEmpty || _isSyncing) return;

    try {
      _isSyncing = true;
      _updateStatus(SyncStatus.syncing);

      while (_syncQueue.isNotEmpty) {
        final operation = _syncQueue.removeFirst();
        await _processSyncOperation(operation);
      }

      _updateStatus(SyncStatus.synced);
    } catch (e) {
      _recordError('ProcessQueue', e);
      _updateStatus(SyncStatus.error);
    } finally {
      _isSyncing = false;
    }
  }

  /// 個別の同期操作を処理
  static Future<void> _processSyncOperation(SyncOperation operation) async {
    try {
      switch (operation.type) {
        case SyncOperationType.upload:
          await _processUploadOperation(operation);
          break;
        case SyncOperationType.download:
          await _processDownloadOperation(operation);
          break;
        case SyncOperationType.delete:
          await _processDeleteOperation(operation);
          break;
      }
    } catch (e) {
      _recordError('ProcessOp:${operation.dataType}', e);
      rethrow;
    }
  }

  /// アップロード操作を処理
  static Future<void> _processUploadOperation(SyncOperation operation) async {
    switch (operation.dataType) {
      case 'projects':
        final syncService = ProjectSyncService();
        await syncService.performSync();
        break;
      case 'blocks':
        final syncService = BlockSyncService();
        await syncService.performSync();
        break;
      case 'actual_tasks':
        final syncService = ActualTaskSyncService();
        await syncService.performSync();
        break;
      case 'sub_projects':
        final syncService = SubProjectSyncService();
        await syncService.performSync();
        break;
      case 'modes':
        final syncService = ModeSyncService();
        await syncService.performSync();
        break;
      case 'categories':
        final syncService = CategorySyncService();
        await syncService.performSync();
        break;
      case 'calendar_entries':
        // CalendarEntryは期間別同期のみサポート
        // 全件同期は非推奨 - 期間指定の同期メソッドを使用してください
        print('⚠️ CalendarEntry全件同期は非推奨です。期間別同期を使用してください。');
        break;
      case 'inbox_tasks':
        final syncService = InboxTaskSyncService();
        await syncService.performSync();
        break;
      case 'routines':
        // 旧 "routines" は廃止（V2へ一本化）
        break;
      default:
      // Unknown data type for upload
    }
  }

  /// ダウンロード操作を処理
  static Future<void> _processDownloadOperation(SyncOperation operation) async {
    // ダウンロードは基本的にperformSyncで処理される
    await _processUploadOperation(operation); // 双方向同期を実行
  }

  /// 削除操作を処理
  static Future<void> _processDeleteOperation(SyncOperation operation) async {
    if (operation.itemId == null) {
      return;
    }

    switch (operation.dataType) {
      case 'projects':
        await ProjectSyncService().deleteProjectWithSync(operation.itemId!);
        break;
      case 'blocks':
        await BlockSyncService().deleteBlockWithSync(operation.itemId!);
        break;
      case 'actual_tasks':
        await ActualTaskSyncService().deleteTaskWithSync(operation.itemId!);
        break;
      case 'sub_projects':
        await SubProjectSyncService()
            .deleteSubProjectWithSync(operation.itemId!);
        break;
      default:
      // Unknown data type for delete
    }
  }

  /// ネットワーク状態変更のハンドリング
  static void _handleNetworkChange(bool isOnline) {
    if (isOnline) {
      _updateStatus(SyncStatus.idle);
      _processSyncQueue();
    } else {
      _updateStatus(SyncStatus.offline);
    }
  }

  /// 同期状態を更新
  static void _updateStatus(SyncStatus status) {
    if (_currentStatus != status) {
      _currentStatus = status;
      _statusController.add(status);
    }
  }

  /// 同期時刻を記録
  static void _recordSyncTime([String? dataType]) {
    final now = DateTime.now();
    if (dataType != null) {
      _lastSyncTimes[dataType] = now;
    } else {
      _lastSyncTimes['all'] = now;
    }
  }

  /// 最終同期時刻を取得
  static DateTime? getLastSyncTime([String? dataType]) {
    return _lastSyncTimes[dataType ?? 'all'];
  }

  /// ターゲット別の最終同期時刻（アプリ起動中のみ有効）
  static DateTime? getLastTargetSyncTime(DataSyncTarget target) {
    return _lastTargetSyncTimes[target];
  }

  /// 指定ターゲット集合の「最も新しい」最終同期時刻（アプリ起動中のみ有効）
  static DateTime? getLastTargetsSyncTime(Iterable<DataSyncTarget> targets) {
    DateTime? latest;
    for (final t in targets) {
      final v = _lastTargetSyncTimes[t];
      if (v == null) continue;
      if (latest == null || v.isAfter(latest)) latest = v;
    }
    return latest;
  }

  /// 同期統計を取得
  static SyncStats getStats() {
    return SyncStats(
      currentStatus: _currentStatus,
      queueLength: _syncQueue.length,
      lastSyncTime: getLastSyncTime(),
      isNetworkAvailable: NetworkManager.isOnline,
      isSyncing: _isSyncing,
    );
  }

  /// 指定データ型を常に同期する
  static Future<Map<DataSyncTarget, SyncResult>> syncDataFor(
    Set<DataSyncTarget> targets, {
    bool forceHeavy = false,
  }) async {
    if (targets.isEmpty) return {};
    // Diff cursor（AppSettings/Hive）が未オープンだと、初回に fullFetch が連発してreadが爆増し得るため、
    // ここで先に開いておく（失敗しても同期自体は続行）。
    try {
      await AppSettingsService.initialize();
    } catch (_) {}
    final startedAt = DateTime.now().toUtc();
    final originTag =
        'SyncManager.syncDataFor targets=${targets.map((t) => t.name).join(',')}${forceHeavy ? ' forceHeavy' : ''}';
    final historyId = await SyncAllHistoryService.recordEventStart(
      type: 'syncDataFor',
      reason: 'syncDataFor',
      origin: 'SyncManager.syncDataFor',
      extra: <String, dynamic>{
        'targets': targets.map((t) => t.name).toList(),
        'forceHeavy': forceHeavy,
      },
    );
    return SyncContext.runWithOriginIfAbsent(originTag, () {
      return _targetSyncMutex.protect(() async {
      try {
        final enteredAt = DateTime.now().toUtc();
        final waitMs = enteredAt.difference(startedAt).inMilliseconds;
        final kpiBefore = SyncKpi.snapshot();
        final results = <DataSyncTarget, SyncResult>{};
        int ok = 0;
        int fail = 0;
        for (final target in targets) {
          final result = await _runTargetSync(target, forceHeavy);
          results[target] = result;
          if (result.success) {
            ok++;
            _lastTargetSyncTimes[target] = DateTime.now();
          } else {
            fail++;
          }
        }
        final kpiAfter = SyncKpi.snapshot();
        final kpiDeltaInMutex = SyncKpi.delta(kpiBefore, kpiAfter);
        await SyncAllHistoryService.recordFinish(
          id: historyId,
          success: fail == 0,
          syncedCount: ok,
          failedCount: fail,
          extra: <String, dynamic>{
            'okTargets': ok,
            'failedTargets': fail,
            'mutexWaitMs': waitMs,
            'kpiDeltaInMutex': kpiDeltaInMutex,
          },
        );
        return results;
      } catch (e) {
        await SyncAllHistoryService.recordFailed(
          id: historyId,
          error: e.toString(),
        );
        rethrow;
      }
      });
    });
  }

  /// 既定の鮮度を過ぎたデータ型のみ同期する
  static Future<Map<DataSyncTarget, SyncResult?>> syncIfStale(
    Set<DataSyncTarget> targets, {
    Duration? minFreshDuration,
    bool forceHeavy = false,
  }) async {
    if (targets.isEmpty) return {};
    // Diff cursor（AppSettings/Hive）が未オープンだと、初回に fullFetch が連発してreadが爆増し得るため、
    // ここで先に開いておく（失敗しても同期自体は続行）。
    try {
      await AppSettingsService.initialize();
    } catch (_) {}
    final startedAt = DateTime.now().toUtc();
    final originTag = 'SyncManager.syncIfStale targets=${targets.map((t) => t.name).join(',')}'
        '${minFreshDuration != null ? ' minFreshMs=${minFreshDuration.inMilliseconds}' : ''}'
        '${forceHeavy ? ' forceHeavy' : ''}';
    final historyId = await SyncAllHistoryService.recordEventStart(
      type: 'syncIfStale',
      reason: 'syncIfStale',
      origin: 'SyncManager.syncIfStale',
      extra: <String, dynamic>{
        'targets': targets.map((t) => t.name).toList(),
        'forceHeavy': forceHeavy,
        if (minFreshDuration != null)
          'minFreshMs': minFreshDuration.inMilliseconds,
      },
    );
    return SyncContext.runWithOriginIfAbsent(originTag, () {
      return _targetSyncMutex.protect(() async {
      try {
        final enteredAt = DateTime.now().toUtc();
        final waitMs = enteredAt.difference(startedAt).inMilliseconds;
        final kpiBefore = SyncKpi.snapshot();
        final results = <DataSyncTarget, SyncResult?>{};
        final now = DateTime.now();
        int freshSkipped = 0;
        int attempted = 0;
        int ok = 0;
        int fail = 0;
        for (final target in targets) {
          final freshness = minFreshDuration ??
              _defaultTargetFreshness[target] ??
              const Duration(minutes: 2);
          final last = _lastTargetSyncTimes[target];
          final isFresh = !forceHeavy && last != null && now.difference(last) < freshness;
          if (isFresh) {
            freshSkipped++;
            results[target] = null;
            continue;
          }
          attempted++;
          final result = await _runTargetSync(target, forceHeavy);
          results[target] = result;
          if (result.success) {
            ok++;
            _lastTargetSyncTimes[target] = DateTime.now();
          } else {
            fail++;
          }
        }
        final kpiAfter = SyncKpi.snapshot();
        final kpiDeltaInMutex = SyncKpi.delta(kpiBefore, kpiAfter);
        await SyncAllHistoryService.recordFinish(
          id: historyId,
          success: fail == 0,
          syncedCount: ok,
          failedCount: fail,
          extra: <String, dynamic>{
            'freshSkipped': freshSkipped,
            'attempted': attempted,
            'okTargets': ok,
            'failedTargets': fail,
            'mutexWaitMs': waitMs,
            'kpiDeltaInMutex': kpiDeltaInMutex,
          },
        );
        return results;
      } catch (e) {
        await SyncAllHistoryService.recordFailed(
          id: historyId,
          error: e.toString(),
        );
        rethrow;
      }
      });
    });
  }

  static Future<SyncResult> _runTargetSync(
    DataSyncTarget target,
    bool forceHeavy,
  ) async {
    try {
      switch (target) {
        case DataSyncTarget.actualTasks:
          return await ActualTaskSyncService()
              .performSync(forceFullSync: forceHeavy, uploadLocalChanges: false);
        case DataSyncTarget.blocks:
          return await BlockSyncService()
              .performSync(forceFullSync: forceHeavy, uploadLocalChanges: false);
        case DataSyncTarget.inboxTasks:
          return await InboxTaskSyncService()
              .performSync(forceFullSync: forceHeavy, uploadLocalChanges: false);
        case DataSyncTarget.projects:
          return await ProjectSyncService()
              .performSync(forceFullSync: forceHeavy);
      }
    } catch (e) {
      return SyncResult(
        success: false,
        error: e.toString(),
        failedCount: 1,
      );
    }
  }

  /// リソースをクリーンアップ
  static void dispose() {
    _periodicSyncTimer?.cancel();
    _statusController.close();
    _syncQueue.clear();
    _isInitialized = false;
  }

  /// 強制再同期
  static Future<SyncResult> forceSync() async {
    _lastSyncTimes.clear();
    return await syncAll(reason: 'forceSync', origin: 'SyncManager.forceSync');
  }
}

/// 同期エラーエントリ
class SyncErrorEntry {
  final String source;
  final String message;
  final DateTime occurredAt;

  SyncErrorEntry({
    required this.source,
    required this.message,
    required this.occurredAt,
  });
}

/// 同期操作
class SyncOperation {
  final String dataType;
  final SyncOperationType type;
  final String? itemId;
  final Map<String, dynamic>? data;
  final DateTime createdAt;

  SyncOperation({
    required this.dataType,
    required this.type,
    this.itemId,
    this.data,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  @override
  String toString() {
    return 'SyncOperation{type: $type, dataType: $dataType, itemId: $itemId}';
  }
}

/// 同期操作の種類
enum SyncOperationType {
  upload,
  download,
  delete,
}

/// 同期統計
class SyncStats {
  final SyncStatus currentStatus;
  final int queueLength;
  final DateTime? lastSyncTime;
  final bool isNetworkAvailable;
  final bool isSyncing;

  SyncStats({
    required this.currentStatus,
    required this.queueLength,
    this.lastSyncTime,
    required this.isNetworkAvailable,
    required this.isSyncing,
  });

  Map<String, dynamic> toJson() {
    return {
      'currentStatus': currentStatus.toString(),
      'queueLength': queueLength,
      'lastSyncTime': lastSyncTime?.toIso8601String(),
      'isNetworkAvailable': isNetworkAvailable,
      'isSyncing': isSyncing,
    };
  }

  @override
  String toString() {
    return 'SyncStats{status: $currentStatus, queue: $queueLength, '
        'lastSync: $lastSyncTime, online: $isNetworkAvailable}';
  }
}

/// 画面別同期ターゲット
enum DataSyncTarget {
  actualTasks,
  blocks,
  inboxTasks,
  projects,
}
