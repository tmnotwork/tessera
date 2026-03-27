import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/task_provider.dart';
import '../../services/block_outbox_manager.dart';
import '../../services/block_sync_service.dart';
import '../../services/actual_task_sync_service.dart';
import '../../services/inbox_task_sync_service.dart';
import '../../services/auth_service.dart';
import '../../services/mode_sync_service.dart';
import '../../services/routine_template_v2_sync_service.dart';
import '../../services/routine_block_v2_sync_service.dart';
import '../../services/routine_task_v2_sync_service.dart';
import '../../services/on_demand_sync_service.dart';
import '../../services/project_sync_service.dart';
import '../../services/sub_project_sync_service.dart';
import '../../services/category_sync_service.dart';
import '../../services/network_manager.dart';
import '../../services/sync_manager.dart';
import '../../models/syncable_model.dart';
import '../../screens/db_hub_screen.dart';

class BackgroundSyncOutcome {
  final bool attempted;
  final bool blockedByAuth;
  final bool blockedByNetwork;
  final bool hadFailure;
  final bool refreshSucceeded;

  const BackgroundSyncOutcome({
    required this.attempted,
    required this.blockedByAuth,
    required this.blockedByNetwork,
    required this.hadFailure,
    required this.refreshSucceeded,
  });

  bool get shouldRetry => blockedByAuth || blockedByNetwork || hadFailure;
}

Future<BackgroundSyncOutcome> syncForSelectedScreenInBackground({
  required BuildContext context,
  required int selectedIndex,
  /// タイムラインタブ(0)のとき、表示中の日付。渡すとその日付の on-demand 同期を行う（他端末の完了反映に必須）。
  DateTime? timelineDisplayDate,
}) async {
  Future<bool> _waitForAuthReady({
    Duration timeout = const Duration(seconds: 6),
    Duration poll = const Duration(milliseconds: 200),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final uid = AuthService.getCurrentUserId();
        if (uid != null && uid.isNotEmpty) {
          return true;
        }
      } catch (_) {}
      await Future.delayed(poll);
    }
    return false;
  }
  var blockedByAuth = false;
  var blockedByNetwork = false;
  var hadFailure = false;
  var refreshSucceeded = false;
  try {
    final requiresRemoteSync = selectedIndex != 2;
    if (requiresRemoteSync && !NetworkManager.isOnline) {
      blockedByNetwork = true;
    }
    final taskProvider = Provider.of<TaskProvider>(context, listen: false);
    switch (selectedIndex) {
      case 0:
        try {
          await BlockOutboxManager.flush();
        } catch (_) {
          hadFailure = true;
        }
        try {
          final ready = await _waitForAuthReady();
          if (ready) {
            // Requirement: on first login on a device, all non-deleted blocks must be downloaded.
            // Run the one-time full blocks sync before dayKey-based on-demand sync.
            await AuthService.ensureInitialBlocksDownloaded();
            // 軽量な実行中タスクの取り込み
            await ActualTaskSyncService().syncAllRunningTasksOnce();
          } else {
            blockedByAuth = true;
          }
        } catch (_) {
          hadFailure = true;
        }
        try {
          final ready = await _waitForAuthReady();
          if (ready) {
            await ModeSyncService.syncAllModes();
          } else {
            blockedByAuth = true;
          }
        } catch (_) {
          hadFailure = true;
        }
        // ログイン直後の post-auth sync がスキップされた場合のフォールバック（Android 等で空表示を防ぐ）
        // 起動を重くしないため syncAll は非ブロッキングで実行。完了後に refreshTasks で再描画。
        try {
          final ready = await _waitForAuthReady();
          if (ready &&
              NetworkManager.isOnline &&
              !(await AuthService.hasCompletedPostAuthSync())) {
            await SyncManager.initialize();
            if (SyncManager.currentStatus != SyncStatus.syncing) {
              final uid = AuthService.getCurrentUserId();
              final taskProv = taskProvider;
              Future(() async {
                try {
                  final result = await SyncManager.syncAll(
                    reason: 'fallback initial sync (timeline)',
                    origin: 'sync_for_screen.tab0',
                    userId: uid,
                  );
                  if (result.success && uid != null && uid.isNotEmpty) {
                    await AuthService.markPostAuthSyncCompleted();
                  }
                  if (context.mounted) {
                    await taskProv.refreshTasks(showLoading: false);
                  }
                } catch (_) {}
              });
            }
          }
        } catch (_) {
          hadFailure = true;
        }
        // 表示日付の on-demand 同期（他端末で完了したブロック/実績を取得。新UIでタブ戻り時も必須）
        try {
          final ready = await _waitForAuthReady();
          if (ready && context.mounted) {
            final date = timelineDisplayDate ?? DateTime.now();
            final normalized = DateTime(date.year, date.month, date.day);
            await OnDemandSyncService.ensureTimelineDay(
              normalized,
              pullVersionFeed: true,
              caller: 'sync_for_screen.tab0',
            );
            await OnDemandSyncService.ensureInboxDay(
              normalized,
              pullVersionFeed: false,
              caller: 'sync_for_screen.tab0',
            );
          }
        } catch (_) {
          hadFailure = true;
        }
        // NOTE:
        // 「実行中タスク監視（Firestore watch）」は MainScreen がタブ選択/ライフサイクルに合わせて
        // 開始/停止を制御する。ここで開始すると、バックグラウンド同期のたびに watch が張り直され、
        // 初回スナップショット read が増える原因になるため禁止。
        if (context.mounted) {
          await taskProvider.refreshTasks();
          refreshSucceeded = true;
        }
        break;
      case 1:
        try {
          final ready = await _waitForAuthReady();
          if (!ready) {
            // ignore: avoid_print
            print('⚠️ Inbox sync skipped (auth not ready)');
          } else {
            // Inbox 画面側で inboxVersion(1doc) による更新検知→必要時のみ差分同期を行う。
            // ここでの自動同期は重複しやすく、画面オープン時の read を増やすため廃止。
          }
        } catch (_) {
          hadFailure = true;
        }
        if (context.mounted) {
          await taskProvider.refreshTasks();
          refreshSucceeded = true;
        }
        break;
      case 2:
        // カレンダー画面は再生バーを表示しないため、監視不要（通信量削減）
        if (context.mounted) {
          await taskProvider.refreshTasks();
          refreshSucceeded = true;
        }
        break;
      case 3:
        try {
          // read削減: Routine V2 は差分同期（cursor）を既定とする。フル同期は手動復旧のみ許可。
          await RoutineTemplateV2SyncService.syncAll(forceFullSync: false);
          await RoutineBlockV2SyncService.syncAll(forceFullSync: false);
          await RoutineTaskV2SyncService.syncAll(forceFullSync: false);
        } catch (_) {
          hadFailure = true;
        }
        try {
          await ModeSyncService.syncAllModes();
        } catch (_) {
          hadFailure = true;
        }
        // ルーティン画面は再生バーを表示しないため、監視不要（通信量削減）
        if (context.mounted) {
          await taskProvider.refreshTasks();
          refreshSucceeded = true;
        }
        break;
      case 4:
        try {
          final ready = await _waitForAuthReady();
          if (!ready) {
            // ignore: avoid_print
            print('⚠️ Project sync skipped (auth not ready)');
            blockedByAuth = true;
          } else {
            // SyncManager経由で、二重実行と過剰頻度を抑止
            await SyncManager.syncIfStale({DataSyncTarget.projects});
          }
        } catch (_) {
          hadFailure = true;
        }
        // プロジェクト周辺のマスタは直接同期（DataSyncTargetに含まれていないものがある）
        try {
          final ready = await _waitForAuthReady();
          if (ready) {
            await SubProjectSyncService.syncAllSubProjects();
          } else {
            blockedByAuth = true;
          }
        } catch (_) {
          hadFailure = true;
        }
        try {
          final ready = await _waitForAuthReady();
          if (ready) {
            await ModeSyncService.syncAllModes();
          } else {
            blockedByAuth = true;
          }
        } catch (_) {
          hadFailure = true;
        }
        try {
          final ready = await _waitForAuthReady();
          if (ready) {
            await CategorySyncService.syncAllCategories();
          } else {
            blockedByAuth = true;
          }
        } catch (_) {
          hadFailure = true;
        }
        // プロジェクト画面は再生バーを表示しないため、監視不要（通信量削減）
        if (context.mounted) {
          await taskProvider.refreshTasks();
          refreshSucceeded = true;
        }
        break;
      case 5:
        // ReportScreen 側で ReportSyncService.ensureRange() を実行するため、
        // ここで actual/blocks の全体差分を追加実行すると read が二重化しやすい。
        // レポートタブ遷移時の自動同期は行わない。
        refreshSucceeded = true;
        break;
    }
  } catch (_) {
    hadFailure = true;
  }
  return BackgroundSyncOutcome(
    attempted: true,
    blockedByAuth: blockedByAuth,
    blockedByNetwork: blockedByNetwork,
    hadFailure: hadFailure,
    refreshSucceeded: refreshSucceeded,
  );
}

/// DBサブ画面（インボックス・実績ブロック等）表示前に Hive を差分同期する。
/// 旧UI MainScreen と新UI（NewUIScreen 等）の両方から利用する。
Future<void> syncDbView(DbSubView view, {required bool forceHeavy}) async {
  final targets = <DataSyncTarget>{};
  switch (view) {
    case DbSubView.hub:
      return;
    case DbSubView.inbox:
      targets.add(DataSyncTarget.inboxTasks);
      break;
    case DbSubView.blocks:
      targets.add(DataSyncTarget.blocks);
      break;
    case DbSubView.actualBlocks:
      targets.add(DataSyncTarget.actualTasks);
      break;
    case DbSubView.projects:
      targets.add(DataSyncTarget.projects);
      break;
    case DbSubView.routineTemplatesV2:
      try {
        await RoutineTemplateV2SyncService().performSync(forceFullSync: forceHeavy);
        await RoutineBlockV2SyncService().performSync(forceFullSync: forceHeavy);
        await RoutineTaskV2SyncService().performSync(forceFullSync: forceHeavy);
      } catch (_) {}
      return;
    case DbSubView.routineTasksV2:
      try {
        await RoutineTaskV2SyncService().performSync(forceFullSync: forceHeavy);
      } catch (_) {}
      return;
    case DbSubView.categories:
      try {
        await CategorySyncService.syncAllCategories();
      } catch (_) {}
      return;
  }
  if (targets.isEmpty) return;
  try {
    if (forceHeavy) {
      await SyncManager.syncDataFor(targets, forceHeavy: true);
    } else {
      await SyncManager.syncIfStale(targets);
    }
  } catch (_) {}
}
