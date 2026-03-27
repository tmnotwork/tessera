// ignore_for_file: use_build_context_synchronously

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'dart:async';
import 'package:provider/provider.dart';
import '../models/inbox_task.dart' as inbox;
import '../models/actual_task.dart' as actual;

import '../providers/task_provider.dart';
import '../services/project_service.dart';
import '../services/sub_project_service.dart';

import 'inbox_task_edit_screen.dart';
import '../widgets/inbox/inbox_task_table.dart';
import '../widgets/timeline/running_task_bar.dart';
import '../widgets/timeline/mobile_running_task_bar.dart';
import 'inbox_task_add_screen.dart';
import '../services/inbox_task_sync_service.dart';
import '../services/auth_service.dart';
import '../services/sync_manager.dart';
import '../services/inbox_version_service.dart';
import '../app/app_material.dart' as appmat;
import 'mobile_task_edit_screen.dart';
import 'inbox_controller_interface.dart';
import '../utils/unified_screen_dialog.dart';

final DateTime kInboxDummyDate = DateTime(2100, 1, 1);

class InboxScreenController implements InboxControllerInterface {
  InboxScreenController();

  _InboxScreenState? _state;
  @override
  final ValueNotifier<bool> isSyncing = ValueNotifier(false);
  bool _disposed = false;

  @override
  Future<void> requestSync() async {
    if (_disposed) return;
    final state = _state;
    if (state == null) return;
    // 手動同期は stale ガード無し（ただし SyncManager のミューテックスで二重実行は抑止）
    await state._syncInboxEnsuringAuth(minFreshDuration: Duration.zero);
  }

  void _attach(_InboxScreenState state) {
    if (_disposed) return;
    _state = state;
    _setSyncing(state._isSyncing);
  }

  void _detach(_InboxScreenState state) {
    if (_disposed) return;
    if (_state == state) {
      _state = null;
      _setSyncing(false);
    }
  }

  void _setSyncing(bool value) {
    if (_disposed) return;
    if (isSyncing.value != value) {
      isSyncing.value = value;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _state = null;
    isSyncing.dispose();
  }
}

class InboxScreen extends StatefulWidget {
  final InboxScreenController? controller;
  /// 「割り当て済みも表示」行の右端に並べるウィジェット（同期・CSVインポート・設定など）。null のときは何も表示しない。
  final List<Widget>? filterRowTrailingActions;

  /// 割り当て済みも表示するかどうか（AppBarから制御）。未指定時は false。
  final bool showAssigned;

  /// 再生バー表示時、Main 側の FAB 位置合わせ用に実高さを通知する（タイムラインと同様）。
  final ValueChanged<double>? onRunningBarHeightChanged;

  const InboxScreen({
    super.key,
    this.controller,
    this.filterRowTrailingActions,
    this.showAssigned = false,
    this.onRunningBarHeightChanged,
  });

  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {
  bool _initialSynced = false;
  bool _isSyncing = false;
  final GlobalKey _runningBarKey = GlobalKey(debugLabel: 'inbox_running_bar');
  double _lastReportedRunningBarHeight = 0;

  void _scheduleRunningBarHeightMeasurement() {
    if (widget.onRunningBarHeightChanged == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ro = _runningBarKey.currentContext?.findRenderObject();
      final box = ro is RenderBox ? ro : null;
      final height =
          (box != null && box.hasSize) ? box.size.height : 0.0;
      _updateRunningBarHeight(height);
    });
  }

  void _updateRunningBarHeight(double height) {
    if ((height - _lastReportedRunningBarHeight).abs() < 0.5) return;
    _lastReportedRunningBarHeight = height;
    widget.onRunningBarHeightChanged?.call(height);
  }

  bool _isMobilePlatform() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
        return true;
      case TargetPlatform.fuchsia:
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        return false;
    }
  }

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(this);
    // 画面初回表示時:
    // - dayVersions の watch(最大30 read) は廃止
    // - inboxVersion(1doc) を 1回だけ server get して「更新あり」なら差分同期
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || _initialSynced) return;
      _initialSynced = true;

      try {
        final ready = await _waitForAuthReady();
        if (!ready) return;

        final remoteRev = await InboxVersionService.fetchRemoteRev();
        if (remoteRev == null) {
          // フォールバック: リモート取得に失敗した場合のみ stale ガード同期
          await _syncInboxEnsuringAuth(
            minFreshDuration: const Duration(seconds: 30),
          );
          return;
        }

        final localSeen = InboxVersionService.getLocalSeenRev();
        if (remoteRev > localSeen) {
          // 更新あり: stale 判定に依存せず差分同期を実行（更新件数分のreadだけが増える）
          await SyncManager.syncDataFor({DataSyncTarget.inboxTasks});
        } else {
          // 互換/保険:
          // - functions 側の bump 未反映（旧端末/未デプロイ）でも取りこぼさないよう、
          //   低頻度の stale ガード差分同期だけは残す（変更0件ならreadは増えない）。
          await SyncManager.syncIfStale(
            {DataSyncTarget.inboxTasks},
            minFreshDuration: const Duration(seconds: 30),
          );
        }
        // 見たrevを更新（リモートが小さいことは通常無いが、安全にmax）
        final nextSeen = remoteRev > localSeen ? remoteRev : localSeen;
        await InboxVersionService.setLocalSeenRev(nextSeen);

        if (mounted) {
          await Provider.of<TaskProvider>(context, listen: false)
              .refreshTasks(showLoading: false);
        }
      } catch (_) {
        // 失敗時の最後の保険: stale ガード同期
        try {
          await _syncInboxEnsuringAuth(minFreshDuration: const Duration(seconds: 30));
        } catch (_) {}
      }
    });
  }

  @override
  void didUpdateWidget(covariant InboxScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._detach(this);
      widget.controller?._attach(this);
    }
  }

  Future<bool> _waitForAuthReady({
    Duration timeout = const Duration(seconds: 5),
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

  Future<void> _syncInboxEnsuringAuth({
    int maxAttempts = 3,
    Duration? minFreshDuration,
  }) async {
    if (_isSyncing) return;
    _setSyncing(true);
    try {
      for (int attempt = 1; attempt <= maxAttempts; attempt++) {
        final ready = await _waitForAuthReady();
        if (!ready && attempt == maxAttempts) {
          // 認証未確立のまま最終試行: 明示的に通知して終了
          _showSnackSafe('インボックスの同期に失敗しました（認証未確立）。後でもう一度お試しください。');
          return;
        }
        try {
          // read削減: 同期の主導権をSyncManagerへ一本化（ミューテックス＋staleガード）
          final results = await SyncManager.syncIfStale(
            {DataSyncTarget.inboxTasks},
            minFreshDuration: minFreshDuration ?? const Duration(seconds: 30),
          );
          final result = results[DataSyncTarget.inboxTasks];
          final ok = result == null || result.success == true;
          if (ok) {
            try {
              await Provider.of<TaskProvider>(context, listen: false)
                  .refreshTasks();
            } catch (_) {}
            return; // 成功
          } else {
            // 明示的に失敗として扱い、リトライへ
            if (attempt == maxAttempts) {
              _showSnackSafe('インボックスの同期に失敗しました（サーバー応答）。後でもう一度お試しください。');
            } else {
              await Future.delayed(Duration(milliseconds: 400 * attempt));
            }
          }
        } catch (e) {
          if (attempt == maxAttempts) {
            _showSnackSafe('インボックスの同期に失敗しました（通信/認証）。後でもう一度お試しください。');
          } else {
            await Future.delayed(Duration(milliseconds: 400 * attempt));
          }
        }
      }
    } finally {
      _setSyncing(false);
    }
  }

  // グローバルコンテキストにフォールバックして確実にスナックバーを出す
  void _showSnackSafe(String message) {
    try {
      final ctx =
          appmat.navigatorKey.currentContext ?? (mounted ? context : null);
      if (ctx != null) {
        ScaffoldMessenger.of(ctx)
            .showSnackBar(SnackBar(content: Text(message)));
      }
    } catch (_) {}
  }

  void _showEditTaskDialog(inbox.InboxTask task) {
    showUnifiedScreenDialog<void>(
      context: context,
      builder: (_) => InboxTaskEditScreen(task: task),
    );
  }

  @override
  void dispose() {
    widget.controller?._detach(this);
    super.dispose();
  }

  void _setSyncing(bool value) {
    if (_isSyncing == value) return;
    _isSyncing = value;
    widget.controller?._setSyncing(value);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isMobileWidth = MediaQuery.of(context).size.width < 800;
    return Scaffold(
      backgroundColor:
          isMobileWidth ? scheme.surfaceContainerLowest : null,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isMobile = constraints.maxWidth < 800;
          final useMobileBar = isMobile && _isMobilePlatform();
          if (!isMobile) {
            return Consumer<TaskProvider>(
              builder: (context, taskProvider, child) {
                final runningTask =
                    context.select<TaskProvider, actual.ActualTask?>(
                  (p) => p.runningActualTasks.isNotEmpty
                      ? p.runningActualTasks.first
                      : null,
                );

                if (widget.onRunningBarHeightChanged != null) {
                  if (runningTask != null) {
                    _scheduleRunningBarHeightMeasurement();
                  } else if (_lastReportedRunningBarHeight != 0) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted) return;
                      _updateRunningBarHeight(0);
                    });
                  }
                }

                return Column(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(8),
                        child: InboxTaskTableWidget(
                          filterRowTrailingActions:
                              widget.filterRowTrailingActions,
                          showAssigned: widget.showAssigned,
                        ),
                      ),
                    ),
                    if (runningTask != null)
                      KeyedSubtree(
                        key: _runningBarKey,
                        child: RunningTaskBar(
                          runningTask: runningTask,
                          onPause: () => _pauseTask(runningTask.id),
                          onComplete: () => _completeTask(runningTask.id),
                        ),
                      ),
                  ],
                );
              },
            );
          }
            return Consumer<TaskProvider>(
              builder: (context, taskProvider, child) {
                final runningTask =
                    context.select<TaskProvider, actual.ActualTask?>(
                  (p) => p.runningActualTasks.isNotEmpty
                      ? p.runningActualTasks.first
                      : null,
                );

                if (widget.onRunningBarHeightChanged != null) {
                  if (runningTask != null) {
                    _scheduleRunningBarHeightMeasurement();
                  } else if (_lastReportedRunningBarHeight != 0) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted) return;
                      _updateRunningBarHeight(0);
                    });
                  }
                }

                // PC版と同様: 未割当（開始時刻未設定）のみを表示
                // 未完了・未割当のみ（PCと一致）。ID/CloudID重複はProvider側で集約済み。
                final tasks = taskProvider.allInboxTasks.where((t) {
                  if (t.isCompleted == true) return false;
                  return taskProvider.shouldShowInboxTask(t);
                }).toList();
                if (tasks.isEmpty) {
                  return Column(
                    children: [
                      const Expanded(
                        child: Center(
                          child: Padding(
                            padding: EdgeInsets.only(top: 48),
                            child: Text('インボックスタスクはありません'),
                          ),
                        ),
                      ),
                      if (runningTask != null)
                        KeyedSubtree(
                          key: _runningBarKey,
                          child: useMobileBar
                              ? InkWell(
                                  onTap: () {
                                    showUnifiedScreenDialog<void>(
                                      context: context,
                                      builder: (_) =>
                                          MobileTaskEditScreen(
                                              task: runningTask),
                                    );
                                  },
                                  child: MobileRunningTaskBar(
                                    runningTask: runningTask,
                                    onPause: () =>
                                        _pauseTask(runningTask.id),
                                    onComplete: () =>
                                        _completeTask(runningTask.id),
                                  ),
                                )
                              : RunningTaskBar(
                                  runningTask: runningTask,
                                  onPause: () => _pauseTask(runningTask.id),
                                  onComplete: () =>
                                      _completeTask(runningTask.id),
                                ),
                        ),
                    ],
                  );
                }
                return Column(
                  children: [
                    Expanded(
                      child: ListView.builder(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 8),
                        itemCount: tasks.length,
                        itemBuilder: (context, index) {
                        final t = tasks[index];
                        final projectName =
                            t.projectId != null && t.projectId!.isNotEmpty
                                ? (ProjectService.getProjectById(t.projectId!)
                                        ?.name ??
                                    '')
                                : '';
                        final subProjectName =
                            t.subProjectId != null && t.subProjectId!.isNotEmpty
                                ? (SubProjectService.getSubProjectById(
                                            t.subProjectId!)
                                        ?.name ??
                                    '')
                                : '';
                        String fmt2(int v) => v.toString().padLeft(2, '0');
                        final timeStr = (t.startHour != null &&
                                t.startMinute != null)
                            ? '${fmt2(t.startHour!)}/${fmt2(t.startMinute!)}'
                            : '';
                        final durationStr = '${t.estimatedDuration}分';
                        return Card(
                          color: scheme.surfaceContainerLow,
                          margin: const EdgeInsets.symmetric(vertical: 6),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8)),
                          child: InkWell(
                            // カード全体に選択（押下）フィードバックを出す
                            borderRadius: BorderRadius.circular(8),
                            onTap: () => _showEditTaskDialog(t),
                            onLongPress: () => _showTaskContextMenu(t),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 10),
                              child: Row(
                                children: [
                                  // メインコンテンツ
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        // 1行目: タイトル
                                        Text(
                                          t.title.isEmpty ? '(無題)' : t.title,
                                          style: const TextStyle(
                                              fontSize: 15,
                                              fontWeight: FontWeight.w600),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        const SizedBox(height: 6),
                                        // 2行目: プロジェクト/サブプロジェクト
                                        Row(
                                          children: [
                                            if (projectName.isNotEmpty) ...[
                                              Icon(Icons.folder,
                                                  size: 14,
                                                  color: Theme.of(context)
                                                      .iconTheme
                                                      .color
                                                      ?.withOpacity(0.6)),
                                              const SizedBox(width: 4),
                                              Expanded(
                                                child: Text(projectName,
                                                    style: TextStyle(
                                                        fontSize: 12,
                                                        color: Theme.of(context)
                                                            .textTheme
                                                            .bodySmall
                                                            ?.color),
                                                    overflow:
                                                        TextOverflow.ellipsis),
                                              ),
                                            ],
                                            if (projectName.isNotEmpty &&
                                                subProjectName.isNotEmpty)
                                              const SizedBox(width: 8),
                                            if (subProjectName.isNotEmpty) ...[
                                              Icon(
                                                  Icons.folder_open,
                                                  size: 14,
                                                  color: Theme.of(context)
                                                      .iconTheme
                                                      .color
                                                      ?.withOpacity(0.6)),
                                              const SizedBox(width: 4),
                                              Expanded(
                                                child: Text(subProjectName,
                                                    style: TextStyle(
                                                        fontSize: 12,
                                                        color: Theme.of(context)
                                                            .textTheme
                                                            .bodySmall
                                                            ?.color),
                                                    overflow:
                                                        TextOverflow.ellipsis),
                                              ),
                                            ],
                                          ],
                                        ),
                                        const SizedBox(height: 6),
                                        // 3行目: 時間/作業時間
                                        Row(
                                          children: [
                                            Icon(Icons.access_time,
                                                size: 14,
                                                color: Theme.of(context)
                                                    .iconTheme
                                                    .color
                                                    ?.withOpacity(0.6)),
                                            const SizedBox(width: 4),
                                            Text(
                                              timeStr.isEmpty ? '—' : timeStr,
                                              style: TextStyle(
                                                  fontSize: 12,
                                                  color: Theme.of(context)
                                                      .textTheme
                                                      .bodySmall
                                                      ?.color),
                                            ),
                                            const SizedBox(width: 12),
                                            Icon(Icons.timelapse,
                                                size: 14,
                                                color: Theme.of(context)
                                                    .iconTheme
                                                    .color
                                                    ?.withOpacity(0.6)),
                                            const SizedBox(width: 4),
                                            Text(durationStr,
                                                style: TextStyle(
                                                    fontSize: 12,
                                                    color: Theme.of(context)
                                                        .textTheme
                                                        .bodySmall
                                                        ?.color)),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                  // 右側アクション（タイムラインに合わせて「0秒実績で完了」も追加）
                                  SizedBox(
                                    height: 80,
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        SizedBox(
                                          width: 48,
                                          child: IconButton(
                                            icon: Icon(
                                              Icons.check,
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .primary,
                                              size: 22,
                                            ),
                                            tooltip: '0秒実績で完了',
                                            onPressed: () async {
                                              await context
                                                  .read<TaskProvider>()
                                                  .completeInboxTaskWithZeroActual(
                                                    t.id,
                                                  );
                                            },
                                          ),
                                        ),
                                        SizedBox(
                                          width: 48,
                                          child: IconButton(
                                            icon: Icon(
                                              Icons.play_arrow,
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .primary,
                                              size: 24,
                                            ),
                                            tooltip: 'このタスクを実行',
                                            onPressed: () async {
                                              await context
                                                  .read<TaskProvider>()
                                                  .createActualTaskFromInbox(
                                                      t.id);
                                            },
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  if (runningTask != null)
                    KeyedSubtree(
                      key: _runningBarKey,
                      child: useMobileBar
                          ? InkWell(
                              onTap: () {
                                showUnifiedScreenDialog<void>(
                                  context: context,
                                  builder: (_) =>
                                      MobileTaskEditScreen(task: runningTask),
                                );
                              },
                              child: MobileRunningTaskBar(
                                runningTask: runningTask,
                                onPause: () => _pauseTask(runningTask.id),
                                onComplete: () =>
                                    _completeTask(runningTask.id),
                              ),
                            )
                          : RunningTaskBar(
                              runningTask: runningTask,
                              onPause: () => _pauseTask(runningTask.id),
                              onComplete: () => _completeTask(runningTask.id),
                            ),
                    ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  void _pauseTask(String taskId) async {
    try {
      await Provider.of<TaskProvider>(context, listen: false)
          .pauseActualTask(taskId);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('一時停止に失敗しました: $e')),
        );
      }
    }
  }

  void _showTaskContextMenu(inbox.InboxTask task) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('削除'),
                onTap: () async {
                  Navigator.of(ctx).pop();
                  await _deleteInboxTask(task.id);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<void> _deleteInboxTask(String taskId) async {
    try {
      await Provider.of<TaskProvider>(context, listen: false)
          .deleteInboxTask(taskId);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('削除に失敗しました: $e')),
        );
      }
    }
  }

  void _completeTask(String taskId) async {
    try {
      final provider = Provider.of<TaskProvider>(context, listen: false);
      // 存在チェック（当日/今日）
      try {
        provider
            .getActualTasksForDate(DateTime.now())
            .firstWhere((t) => t.id == taskId);
      } catch (_) {}
      await provider.completeActualTask(taskId);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('完了エラー: $e')),
        );
      }
    }
  }
}
