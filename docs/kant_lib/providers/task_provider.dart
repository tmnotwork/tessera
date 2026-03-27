import 'dart:async';
import 'package:flutter/foundation.dart' show kDebugMode, mapEquals, debugPrint;
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/block.dart';
import '../models/actual_task.dart';
import '../models/inbox_task.dart' as inbox;
import '../services/block_service.dart';
import '../services/block_sync_service.dart';
import '../services/actual_task_service.dart';
import '../services/inbox_task_service.dart';
import '../services/inbox_task_sync_service.dart';
import '../services/actual_task_sync_service.dart';
import '../services/auth_service.dart';
import '../services/task_sync_manager.dart';
import '../services/device_info_service.dart';
import '../services/block_outbox_manager.dart';
import '../services/sub_project_service.dart';

import '../services/block_sync_operations.dart';
// unused imports removed
import '../services/timeline_version_service.dart';
import '../services/app_settings_service.dart';
import '../services/notification_service.dart';
import '../services/on_demand_sync_service.dart';
import '../services/sync_manager.dart';
import '../utils/kant_inbox_trace.dart';

class TaskProvider extends ChangeNotifier {
  List<Block> _blocks = [];
  List<ActualTask> _actualTasks = [];
  List<inbox.InboxTask> _inboxTasks = [];
  bool _isLoading = false;
  // 通知バッチング用（過剰な再ビルドを抑制）
  Timer? _notifyTimer;
  bool _notifyPending = false;

  late StreamSubscription<void> _blockUpdateSubscription;
  StreamSubscription<void>? _actualUpdateSubscription;
  StreamSubscription<List<ActualTask>>? _actualTaskWatchSub;
  StreamSubscription<List<ActualTask>>? _allRunningWatchSub;
  Timer? _runningTaskPollingTimer;
  bool _dataCheckPerformed = false;
  // 「実行中」監視で対象から外れたタスクの補完確認（過剰GET抑制）
  final Map<String, DateTime> _runningMissingProbeAt = <String, DateTime>{};

  final Map<String, Set<String>> _timelineExpandedBlocks = {};

  bool get _isAppInForeground {
    final binding = WidgetsBinding.instance;
    final state = binding.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  String _timelineKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  Set<String> getExpandedBlocksForDate(DateTime date) {
    final key = _timelineKey(date);
    final stored = _timelineExpandedBlocks[key];
    if (stored == null) return <String>{};
    return Set<String>.from(stored);
  }

  void setExpandedBlocksForDate(DateTime date, Set<String> blockIds) {
    final key = _timelineKey(date);
    _timelineExpandedBlocks[key] = Set<String>.from(blockIds);
  }

  // インボックスタスクID単位での自動ブロック作成ロック（多重発火防止）
  // static final Set<String> _inboxAutoCreateLock = <String>{};

  // コンストラクタ
  TaskProvider() {
    // BlockServiceの更新通知を購読
    _blockUpdateSubscription = BlockService.updateStream.listen((_) {
      refreshTasks();
    });
    // ActualTaskの更新通知も購読
    _actualUpdateSubscription = ActualTaskService.updateStream.listen((_) {
      refreshTasks();
    });

    // 初回表示で空にならないよう、最低限の再読込をキックする。
    // NOTE: 各Serviceのinitializeは内部で二重実行を避ける想定。
    unawaited(refreshTasks(showLoading: false));
  }

  @override
  void dispose() {
    _blockUpdateSubscription.cancel();
    _actualUpdateSubscription?.cancel();
    _actualTaskWatchSub?.cancel();
    _allRunningWatchSub?.cancel();
    _runningTaskPollingTimer?.cancel();
    super.dispose();
  }

  List<Block> get blocks => _blocks;
  List<ActualTask> get actualTasks => _actualTasks;
  List<inbox.InboxTask> get inboxTasks => _inboxTasks;
  bool get isLoading => _isLoading;

  // ブロック関連
  List<Block> get allBlocks => _blocks;

  // 実績タスク関連
  List<ActualTask> get allActualTasks => _actualTasks;
  List<ActualTask> get runningActualTasks =>
      _actualTasks.where((task) => task.isRunning).toList();
  List<ActualTask> get completedActualTasks =>
      _actualTasks.where((task) => task.isCompleted).toList();
  List<ActualTask> get pausedActualTasks =>
      _actualTasks.where((task) => task.isPaused).toList();

  // インボックスタスク関連
  List<inbox.InboxTask> get allInboxTasks => _inboxTasks;

  bool shouldShowInboxTask(
    inbox.InboxTask task, {
    bool includeAssigned = false,
  }) {
    if (includeAssigned) return true;

    final hasStart = task.startHour != null && task.startMinute != null;
    final hasBlockLink = (task.blockId ?? '').isNotEmpty;

    // 方針:
    // - インボックスには「やる日 + やる時刻」が未確定のものだけを出す
    // - 逆に、時刻が確定しているものはタイムライン側で扱う（blockId の有無は問わない）
    //
    // NOTE: この判定は startHour/startMinute（=予定時刻）を基準にする。
    // startTime は実績/レガシー用途のため、ここでは扱わない（別対応）。
    if (hasStart) return false;

    // ブロックへ割り当て済み（blockId が入っている）なのに startHour/startMinute が欠落している
    // データでも、インボックスには出さない（「割り当てたのに消えない」不具合の防止）。
    if (hasBlockLink) return false;

    return true;
  }

  // 初期化
  Future<void> initialize() async {
    await refreshTasks();
    // Phase 8: 旧レンジ同期を廃止し、dayKeys中心の on-demand 同期へ一本化
    try {
      final today = DateTime.now();
      final prev = today.subtract(const Duration(days: 1));
      await OnDemandSyncService.ensureTimelineDay(
          DateTime(prev.year, prev.month, prev.day),
          caller: 'TaskProvider.initialize(prev)',
      );
      await OnDemandSyncService.ensureTimelineDay(
          DateTime(today.year, today.month, today.day),
          caller: 'TaskProvider.initialize(today)',
      );
      await refreshTasks();
    } catch (_) {}

    // NOTE:
    // 多日キー(startAt/dayKeys/monthKeys)のバックフィルは「手動実行」に移行。
    // 設定画面から明示的に実行し、結果を確認できるようにする（自動実行はしない）。
  }

  // タスクを再読み込み
  Future<void> refreshTasks({bool showLoading = true}) async {
    if (showLoading) _setLoading(true);
    try {
      // 防御的: 起動順・復旧経路・WebのIndexedDB都合で box が開いていないことがある。
      // ここで開けるものは開いてから読み取る（開けなければ空で継続）。
      try {
        await BlockService.initialize();
      } catch (e) {
        // continue
      }
      try {
        await ActualTaskService.initialize();
      } catch (e) {
        // continue
      }
      try {
        await InboxTaskService.initialize();
      } catch (e) {
        // continue
      }

      _blocks = BlockService.getAllBlocks();

      // 追加: 論理削除されたブロックはUIに出さない
      _blocks = _blocks.where((b) => !b.isDeleted).toList();

      // 追加: cloudId重複をUI層で集約（最新lastModifiedを採用し、skip/completeは論理OR）
      try {
        final Map<String, List<Block>> byCid = {};
        final List<Block> noCid = [];
        for (final b in _blocks) {
          final cid = b.cloudId ?? '';
          if (cid.isEmpty) {
            noCid.add(b);
          } else {
            (byCid[cid] ??= []).add(b);
          }
        }
        final List<Block> collapsed = [];
        for (final entry in byCid.entries) {
          final list = entry.value;
          if (list.length == 1) {
            collapsed.add(list.first);
          } else {
            // lastModified 降順で選択
            list.sort((a, b) => b.lastModified.compareTo(a.lastModified));
            final keep = list.first;
            // skip/complete はどれかが true なら true に寄せる（UI表示の一貫性）
            final anySkipped = list.any((x) => x.isSkipped);
            final anyCompleted = list.any((x) => x.isCompleted);
            if (keep.isSkipped != anySkipped ||
                keep.isCompleted != anyCompleted) {
              keep.isSkipped = anySkipped;
              keep.isCompleted = anyCompleted;
            }
            collapsed.add(keep);
          }
        }
        // cloudIdが無いものはそのまま追加
        collapsed.addAll(noCid);
        _blocks = collapsed;
      } catch (_) {}

      // cloudId 重複と isSkipped 不整合の検知（ログ出力は削除）
      try {
        final Map<String, List<Block>> byCid = {};
        for (final b in _blocks) {
          final cid = b.cloudId ?? '';
          if (cid.isEmpty) continue;
          (byCid[cid] ??= []).add(b);
        }
        for (final entry in byCid.entries) {
          if (entry.value.length > 1) {
            final hasTrue = entry.value.any((b) => b.isSkipped);
            final hasFalse = entry.value.any((b) => !b.isSkipped);
            if (hasTrue && hasFalse) {
              // mixed isSkipped states for same cid
            }
          }
        }
      } catch (_) {}

      _actualTasks = ActualTaskService.getAllActualTasks();

      // Inbox は最初から「表示すべきもの」だけに整形
      final allInbox = InboxTaskService.getAllInboxTasks();
      // 1) 論理削除は除外
      var filtered = allInbox
          .where((t) => t.isDeleted != true)
          // PC版と同様の基準: 未完了のみ
          .where((t) => t.isCompleted != true)
          // Someday は通常の一覧から除外
          .where((t) => (t.isSomeday != true))
          .toList();
      // 2) 重複排除（cloudId優先→idでも集約）
      try {
        // 2-1) cloudIdで集約
        final Map<String, List<inbox.InboxTask>> byCid = {};
        final List<inbox.InboxTask> noCid = [];
        for (final t in filtered) {
          final cid = t.cloudId ?? '';
          if (cid.isEmpty) {
            noCid.add(t);
          } else {
            (byCid[cid] ??= []).add(t);
          }
        }
        final List<inbox.InboxTask> cloudCollapsed = [];
        for (final entry in byCid.entries) {
          final list = entry.value;
          if (list.length == 1) {
            cloudCollapsed.add(list.first);
          } else {
            list.sort((a, b) => b.lastModified.compareTo(a.lastModified));
            cloudCollapsed.add(list.first);
          }
        }
        cloudCollapsed.addAll(noCid);

        // 2-2) idでも集約（cloudIdを持たないレコードや端末間のズレ対策）
        final Map<String, List<inbox.InboxTask>> byId = {};
        for (final t in cloudCollapsed) {
          (byId[t.id] ??= []).add(t);
        }
        final List<inbox.InboxTask> idCollapsed = [];
        for (final entry in byId.entries) {
          final list = entry.value;
          if (list.length == 1) {
            idCollapsed.add(list.first);
          } else {
            list.sort((a, b) => b.lastModified.compareTo(a.lastModified));
            idCollapsed.add(list.first);
          }
        }
        filtered = idCollapsed;
      } catch (_) {}
      _inboxTasks = filtered;
      // データ整合性チェックを一度だけ実行
      // _blocks / _actualTasks / _inboxTasks を全てセットした後に行う。
      // チェック中に BlockService.updateBlock() が発火しても、
      // 全データがセット済みなので表示に段差が出ない。
      if (!_dataCheckPerformed && _blocks.isNotEmpty) {
        _dataCheckPerformed = true;
        await checkAndCleanData();
        await _migrateRoutineProvenance();
      }

      // 通知はバッチングして1フレーム内の多重呼び出しを抑制
      _scheduleNotify();
      // イベントブロックの通知を再スケジュール（Androidの通知漏れ対策）
      // 大量ログ抑制のため、"未完了・未削除・未来トリガ" のみ対象に絞る
      try {
        final now = DateTime.now();
        final leadStr = AppSettingsService.getString(
            AppSettingsService.keyCalendarEventReminderMinutes);
        final lead = int.tryParse(leadStr ?? '') ?? 10;
        final eventBlocks = _blocks
            .where((b) =>
                b.isEvent == true &&
                b.allDay != true &&
                !b.isDeleted &&
                !b.isCompleted)
            .where((b) {
          final start = b.startAt?.toLocal() ??
              DateTime(b.executionDate.year, b.executionDate.month,
                  b.executionDate.day, b.startHour, b.startMinute);
          final trigger =
              start.subtract(Duration(minutes: lead > 0 ? lead : 0));
          return trigger.isAfter(now);
        }).toList();
        await NotificationService()
            .scheduleEventRemindersForBlocks(eventBlocks);
        final importantTasks = _inboxTasks
            .where((t) =>
                t.isImportant == true &&
                t.isSomeday != true &&
                !t.isDeleted &&
                !t.isCompleted &&
                t.startHour != null &&
                t.startMinute != null)
            .where((t) {
          final start = DateTime(
            t.executionDate.year,
            t.executionDate.month,
            t.executionDate.day,
            t.startHour!,
            t.startMinute!,
          );
          final trigger =
              start.subtract(Duration(minutes: lead > 0 ? lead : 0));
          return trigger.isAfter(now);
        }).toList();
        await NotificationService().scheduleTaskRemindersForTasks(importantTasks);
        // 余計な保留中通知をキャンセル（削除・完了・過去化・非イベント化などの変化に追随）
        await NotificationService()
            .reconcilePendingWithBlocksAndTasks(_blocks, _inboxTasks);
      } catch (_) {}
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[revertUnassign] refreshTasks error: $e\n$st');
      }
      // エラーハンドリング
    } finally {
      if (showLoading) _setLoading(false);
    }
  }

  // 通知のバッチング（50ms デバウンス）
  void _scheduleNotify() {
    _notifyPending = true;
    _notifyTimer ??= Timer(const Duration(milliseconds: 50), () {
      _notifyTimer?.cancel();
      _notifyTimer = null;
      if (_notifyPending) {
        _notifyPending = false;
        notifyListeners();
      }
    });
  }

  // ルーティン由来の紐づけを taskId から isRoutineDerived へ移行
  Future<void> _migrateRoutineProvenance() async {
    try {
      int migrated = 0;
      for (final b in _blocks) {
        // creationMethod が routine のものは確実に isRoutineDerived を立てる
        if (b.creationMethod == TaskCreationMethod.routine &&
            b.isRoutineDerived == false) {
          final updated = b.copyWith(
            isRoutineDerived: true,
            lastModified: DateTime.now(),
            version: b.version + 1,
          );
          await BlockService.updateBlock(updated);
          migrated++;
        }
      }
      if (migrated > 0) {
        _blocks = BlockService.getAllBlocks();
      }
    } catch (e) {
      // ignore
    }
  }

  // 特定日付のタスク取得
  List<dynamic> getTasksForDate(DateTime date) {
    String toYmd(DateTime d) {
      final l = d.toLocal();
      return '${l.year.toString().padLeft(4, '0')}-${l.month.toString().padLeft(2, '0')}-${l.day.toString().padLeft(2, '0')}';
    }

    final targetYmd = toYmd(date);
    final filteredBlocks = _blocks
        // 追加: 論理削除済みは除外
        .where((block) => !block.isDeleted)
        .where((block) => toYmd(block.executionDate) == targetYmd)
        .toList();
    // ここはUIのホットパスなので、ログはデバッグ時のみ最小限に抑える
    if (kDebugMode) {
      // ignore: avoid_print
    }

    // Blockのみを返す
    final allTasks = <dynamic>[];
    allTasks.addAll(filteredBlocks);

    return allTasks;
  }

  // 特定日付のブロック取得
  List<Block> getBlocksForDate(DateTime date) {
    final d = DateTime(date.year, date.month, date.day);
    final dayStart = DateTime(d.year, d.month, d.day);
    final dayEndExclusive = dayStart.add(const Duration(days: 1));
    final dayKey =
        '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

    bool overlapsDay(DateTime startLocal, DateTime endLocalExclusive) {
      return startLocal.isBefore(dayEndExclusive) && endLocalExclusive.isAfter(dayStart);
    }

    final result = _blocks.where((b) {
      if (b.isDeleted) return false;

      // Preferred: dayKeys match
      final keys = b.dayKeys;
      if (keys != null && keys.contains(dayKey)) return true;

      // Canonical range if present
      final s = b.startAt?.toLocal();
      final e = b.endAtExclusive?.toLocal();
      if (s != null && e != null) {
        return overlapsDay(s, e);
      }

      // Legacy: executionDate match
      return b.executionDate.year == d.year &&
          b.executionDate.month == d.month &&
          b.executionDate.day == d.day;
    }).toList();

    return result;
  }

  // 特定日付の実績タスク取得
  List<ActualTask> getActualTasksForDate(DateTime date) {
    final d = DateTime(date.year, date.month, date.day);
    final dayStart = DateTime(d.year, d.month, d.day);
    final dayEndExclusive = dayStart.add(const Duration(days: 1));
    final now = DateTime.now();
    final dayKey =
        '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

    bool overlapsDay(DateTime startLocal, DateTime endLocalExclusive) {
      return startLocal.isBefore(dayEndExclusive) && endLocalExclusive.isAfter(dayStart);
    }

    // メモリ上の一覧から“日と交差する”ものを抽出（跨日対応）
    return _actualTasks.where((t) {
      if (t.isDeleted) return false;

      // Preferred: dayKeys match (completed/paused)
      final keys = t.dayKeys;
      if (keys != null && keys.contains(dayKey)) return true;

      // Canonical range if present
      final s = t.startAt?.toLocal() ?? t.startTime.toLocal();
      final e = t.endAtExclusive?.toLocal() ?? t.endTime?.toLocal();
      if (e != null) {
        return overlapsDay(s, e);
      }

      // Running: treat end as now (clamped later in UI)
      if (!now.isAfter(dayStart)) return false; // day is in the future relative to now
      return s.isBefore(dayEndExclusive);
    }).toList();
  }

  // 特定日付のインボックスタスク取得
  List<inbox.InboxTask> getInboxTasksForDate(DateTime date) {
    final d = DateTime(date.year, date.month, date.day);
    // メモリ上の一覧から日付一致のみ抽出（サービス層のBox走査を避ける）
    return _inboxTasks.where((t) {
      final ed = t.executionDate;
      return ed.year == d.year && ed.month == d.month && ed.day == d.day;
    }).toList();
  }

  // 特定プロジェクトのブロック取得
  List<Block> getBlocksByProject(String projectId) {
    return _blocks.where((block) => block.projectId == projectId).toList();
  }

  // 特定プロジェクトの実績タスク取得
  List<ActualTask> getActualTasksByProject(String projectId) {
    return ActualTaskService.getActualTasksByProject(projectId);
  }

  // ブロック追加（同期対応）
  Future<void> addBlock(Block blockObj) async {
    try {
      // deviceIdとsync metadataを設定
      final deviceId = await DeviceInfoService.getDeviceId();
      blockObj.deviceId = deviceId;
      blockObj.markAsModified(deviceId);

      // ローカル保存
      await BlockService.addBlock(blockObj);

      // Firebase同期（既存のブロックオブジェクトを使用）
      try {
        await BlockSyncService().uploadToFirebase(blockObj);
        // cloudId/lastSynced が付与されたのでローカルにも反映
        await BlockService.updateBlock(blockObj);
      } catch (e) {
      }

      await refreshTasks();
    } catch (e) {
      // エラーハンドリング
    }
  }

  // 実績タスク追加
  Future<void> addActualTask(ActualTask task,
      {bool skipRefresh = false}) async {
    try {
      await ActualTaskService.addActualTask(task);

      // ここでは送信しない。開始時の'start'で即時同期し、二重作成を防ぐ。
      if (!skipRefresh) {
        await refreshTasks();
      }
    } catch (e) {
      // エラーハンドリング
    }
  }

  // ブロック更新
  Future<void> updateBlock(Block blockObj) async {
    try {
      // 最新ローカルと比較し、意味のある差分がある場合のみ更新・同期する
      // UIから渡された lastModified は信頼せず、Service 層でのみ更新する
      var merged = blockObj;
      try {
        final current = BlockService.getBlockById(blockObj.id);
        if (current != null) {
          // デバッグ: 時刻系の変更要求が来ているかを出す（巻き戻り調査用）
          try {
            final timeRequested =
                (blockObj.startHour != current.startHour) ||
                    (blockObj.startMinute != current.startMinute) ||
                    (blockObj.estimatedDuration != current.estimatedDuration) ||
                    (blockObj.executionDate.toIso8601String() !=
                        current.executionDate.toIso8601String());
            if (timeRequested) {
              // time change requested
            }
          } catch (_) {}

          // 差分検知（ビジネス値のみ）
          bool different(String? a, String? b) => a != b;
          bool differentBool(bool a, bool b) => a != b;
          bool differentInt(int a, int b) => a != b;
          bool differentDT(DateTime? a, DateTime? b) =>
              a?.toIso8601String() != b?.toIso8601String();

          final hasDiff = different(blockObj.title, current.title) ||
              different(blockObj.projectId, current.projectId) ||
              differentDT(blockObj.dueDate, current.dueDate) ||
              differentDT(blockObj.executionDate, current.executionDate) ||
              differentInt(blockObj.startHour, current.startHour) ||
              differentInt(blockObj.startMinute, current.startMinute) ||
              differentInt(
                  blockObj.estimatedDuration, current.estimatedDuration) ||
              differentInt(blockObj.workingMinutes, current.workingMinutes) ||
              different(blockObj.memo, current.memo) ||
              different(blockObj.location, current.location) ||
              different(blockObj.subProjectId, current.subProjectId) ||
              different(blockObj.subProject, current.subProject) ||
              different(blockObj.modeId, current.modeId) ||
              different(blockObj.blockName, current.blockName) ||
              differentBool(blockObj.isCompleted, current.isCompleted) ||
              differentBool(blockObj.isSkipped, current.isSkipped) ||
              differentBool(blockObj.isEvent, current.isEvent) ||
              differentBool(
                  blockObj.excludeFromReport, current.excludeFromReport) ||
              differentBool(blockObj.allDay, current.allDay) ||
              different(blockObj.taskId, current.taskId);

          if (!hasDiff) {
            // 変更なし: 何もしない
            return;
          }

          // provenance フラグは現状維持
          if (merged.isRoutineDerived != current.isRoutineDerived) {
            merged =
                merged.copyWith(isRoutineDerived: current.isRoutineDerived);
          }
          if (merged.isPauseDerived != current.isPauseDerived) {
            merged = merged.copyWith(isPauseDerived: current.isPauseDerived);
          }

          // UIからの lastModified は無視し、ここでは変更しない
          merged = merged.copyWith(lastModified: current.lastModified);
        }
      } catch (_) {}

      // Ensure fresh sync metadata so remote overwrite checks don't block our update
      final deviceId = await DeviceInfoService.getDeviceId();
      merged.deviceId = deviceId;
      // 差分がある場合のみここで lastModified を更新
      merged.markAsModified(deviceId);
      // 即時一貫性: 同一 cloudId を持つローカル複製に skip/complete を反映
      try {
        final cid = merged.cloudId;
        if (cid != null && cid.isNotEmpty) {
          final all = BlockService.getAllBlocks();
          for (final b in all) {
            if (b.id == merged.id) continue;
            if (b.cloudId == cid) {
              bool changed = false;
              if (b.isSkipped != merged.isSkipped) {
                b.isSkipped = merged.isSkipped;
                changed = true;
              }
              if (b.isCompleted != merged.isCompleted) {
                b.isCompleted = merged.isCompleted;
                changed = true;
              }
              if (changed) {
                await BlockService.updateBlock(b);
              }
            }
          }
        }
      } catch (_) {}
      await BlockSyncService().updateBlockWithSync(merged);
      try {
        await BlockOutboxManager.flush();
      } catch (_) {}
      await refreshTasks();
    } catch (e) {
      // エラーハンドリング
    }
  }

  // 実績タスク更新
  Future<void> updateActualTask(ActualTask task) async {
    try {
      // 重要:
      // ActualTaskService.updateActualTask は lastModified を自動更新しない方針。
      // UI起点の更新はここで明示的に同期メタデータを更新する。
      try {
        final deviceId = await DeviceInfoService.getDeviceId();
        task.markAsModified(deviceId);
      } catch (_) {
        task.markAsModified();
      }
      await ActualTaskService.updateActualTask(task);

      // リアルタイム同期
      unawaited(TaskSyncManager.syncActualTaskImmediately(task, 'update'));

      // タイムライン当日のバージョンをインクリメント（開始日のローカル日付を基準）
      try {
        final d = task.startTime.toLocal();
        final dateOnly = DateTime(d.year, d.month, d.day);
        await TimelineVersionService.bumpVersionForDate(dateOnly);
      } catch (_) {}

      await refreshTasks();
    } catch (e) {
      // エラーハンドリング
    }
  }

  // ブロック削除（同期対応、ルーティンブロックは物理削除、通常ブロックは論理削除、関連解除付き）
  Future<void> deleteBlock(String blockId) async {
    try {
      // 削除対象ブロックの詳細を確認
      final blocks = BlockService.getAllBlocks();
      final block = blocks.where((b) => b.id == blockId).firstOrNull;

      if (block != null) {
        // 関連インボックスタスクとの結びつきを解除
        if (block.taskId != null && block.taskId!.isNotEmpty) {
          await unlinkInboxTaskFromBlock(block.taskId!, blockId);
        }
      }

      // BlockSyncServiceの同期対応削除を使用（自動的に物理/論理削除が選択される）
      await BlockSyncService().deleteBlockWithSync(blockId);

      await refreshTasks();
    } catch (e) {
      // エラーハンドリング
    }
  }

  // 実績タスク削除
  Future<void> deleteActualTask(String taskId) async {
    try {
      // 同期対応削除（Firebaseにも反映）
      await ActualTaskSyncService().deleteTaskWithSync(taskId);
      await refreshTasks();
    } catch (e) {
      // エラーハンドリング
    }
  }

  // 実績タスク開始
  Future<void> startActualTask(String taskId) async {
    try {
      final task = ActualTaskService.getActualTask(taskId);
      if (task != null) {
        task.start();
        await ActualTaskService.updateActualTask(task);

        // リアルタイム同期（高優先度）
        unawaited(TaskSyncManager.syncActualTaskImmediately(task, 'start'));

        await refreshTasks();
      }
    } catch (e) {
      // エラーハンドリング
    }
  }

  // 実績タスク一時停止（中断時に新たな予定ブロックを作成）
  Future<void> pauseActualTask(String taskId) async {
    try {
      final task = ActualTaskService.getActualTask(taskId);
      if (task != null) {
        final start = task.startTime;
        final tick = DateTime.now();
        // 完了実績を「中断に変更」する場合、pause() が endTime を上書きする前に
        // 完了時刻までを経過として使う（放置後に操作すると残り時間が全損しない）。
        int elapsedMinutes;
        if (task.isCompleted && task.endTime != null) {
          elapsedMinutes = task.endTime!.difference(start).inMinutes;
        } else {
          elapsedMinutes = tick.difference(start).inMinutes;
        }
        if (elapsedMinutes < 0) elapsedMinutes = 0;

        // タスクを一時停止
        task.pause();
        await ActualTaskService.updateActualTask(task);

        // リアルタイム同期（高優先度）
        unawaited(TaskSyncManager.syncActualTaskImmediately(task, 'pause'));

        // インボックス起源の実績は sourceInboxTaskId を基に元タスクを復活
        try {
          final sourceId = task.sourceInboxTaskId;
          var revivedInbox = false;
          if (sourceId != null && sourceId.isNotEmpty) {
            final origin = InboxTaskService.getInboxTask(sourceId);
            if (origin != null) {
              final now = DateTime.now();
              int remaining = origin.estimatedDuration - elapsedMinutes;
              if (remaining < 1) remaining = 1;
              final revived = origin.copyWith(
                isCompleted: false,
                isRunning: false,
                startTime: null,
                endTime: null,
                estimatedDuration: remaining,
                memo: task.memo,
                lastModified: now,
                version: origin.version + 1,
              );
              await InboxTaskService.updateInboxTask(revived);
              unawaited(
                TaskSyncManager.syncInboxTaskImmediately(revived, 'update'),
              );
              revivedInbox = true;
            }
          }
          if (!revivedInbox) {
            // sourceInboxTaskId が無い、またはローカルに元タスクが無い（削除・UID不一致等）ときは
            // 新規インボックスタスクを生成する。前者のみ処理すると「復活しない」になる。
            // startHour/startMinute を設定しないとタイムラインに表示されないため、現在時刻を入れる。
            final now = DateTime.now();
            final defaultMinutes = AppSettingsService.getInt(
              AppSettingsService.keyTaskDefaultEstimatedMinutes,
              defaultValue: 0,
            );
            final estimatedDuration =
                (defaultMinutes > 0 ? defaultMinutes : 15);
            await createTaskForInbox(
              title: task.title,
              memo: task.memo,
              projectId: task.projectId,
              subProjectId: task.subProjectId,
              dueDate: task.dueDate,
              executionDate: now,
              startHour: now.hour,
              startMinute: now.minute,
              estimatedDuration: estimatedDuration,
              modeId: task.modeId,
              isSomeday: false,
            );
          }
        } catch (e) {
          // inbox revival failed
        }

        await refreshTasks();
      }
    } catch (e) {
      // エラーハンドリング
    }
  }

  // 旧: 中断されたタスクから新たな予定ブロックを作成
  // 仕様変更により未使用。将来の参考として残す場合はコメントアウトのまま保持。

  // 実績タスク再開
  Future<void> restartActualTask(String taskId) async {
    try {
      final task = ActualTaskService.getActualTask(taskId);
      if (task != null) {
        // 仕様変更: 完了済みを再実行した場合は「完了を取り消し→一時停止」にし、
        // 一時停止と同様に予定ブロックを再作成する
        if (task.isCompleted) {
          // 完了を取り消し、ステータスを一時停止に
          task.status = ActualTaskStatus.paused;
          await ActualTaskService.updateActualTask(task);

          // リアルタイム同期（高優先度）: 一時停止として扱う
          unawaited(TaskSyncManager.syncActualTaskImmediately(task, 'pause'));

          // 仕様変更: 予定ブロックは新規作成しない

          await refreshTasks();
        } else {
          // 従来の動作: 一時停止中からの再開等は通常の再開
          task.restart();
          await ActualTaskService.updateActualTask(task);

          // リアルタイム同期（高優先度）: 開始として扱う
          unawaited(TaskSyncManager.syncActualTaskImmediately(task, 'start'));

          await refreshTasks();
        }
      }
    } catch (e) {
      // エラーハンドリング
    }
  }

  // 実績タスク再開（完了済みでも予定ブロックを作らず即時記録開始）
  Future<void> restartActualTaskWithoutPlanned(String taskId) async {
    try {
      final original = ActualTaskService.getActualTask(taskId);
      if (original != null) {
        // 元の実績は変更せず、新しい実績レコードを起票して開始
        final now = DateTime.now();
        final newActual = ActualTask(
          id: now.millisecondsSinceEpoch.toString(),
          title: original.title,
          projectId: original.projectId,
          dueDate: original.dueDate,
          startTime: now,
          status: ActualTaskStatus.running,
          memo: original.memo,
          createdAt: now,
          lastModified: now,
          userId: AuthService.getCurrentUserId() ?? original.userId,
          blockId: null, // 予定ブロックは作らない方針のため、リンクは外す
          subProjectId: original.subProjectId,
          subProject: original.subProject,
          modeId: original.modeId,
          blockName: original.blockName,
        );

        await ActualTaskService.addActualTask(newActual);
        // リアルタイム同期（高優先度）: 開始として扱う
        unawaited(
            TaskSyncManager.syncActualTaskImmediately(newActual, 'start'));
        await refreshTasks();
      }
    } catch (e) {
      // エラーハンドリング
    }
  }

  // 実績タスク完了
  Future<void> completeActualTask(String taskId,
      {bool suppressRemaining = false}) async {
    try {
      final task = ActualTaskService.getActualTask(taskId);
      if (task != null) {
        task.complete();
        await ActualTaskService.updateActualTask(task);

        // リアルタイム同期（高優先度）
        unawaited(TaskSyncManager.syncActualTaskImmediately(task, 'complete'));

        // Inbox起源の実績であれば元タスクも完了に戻す
        try {
          final sourceId = task.sourceInboxTaskId;
          if (sourceId != null && sourceId.isNotEmpty) {
            final origin = InboxTaskService.getInboxTask(sourceId);
            if (origin != null) {
              final now = DateTime.now();
              final completed = origin.copyWith(
                isCompleted: true,
                isRunning: false,
                endTime: now,
                lastModified: now,
                version: origin.version + 1,
              );
              await InboxTaskService.updateInboxTask(completed);
              unawaited(
                TaskSyncManager.syncInboxTaskImmediately(completed, 'update'),
              );
            }
          }
        } catch (_) {}

        // 追加: 紐づくインボックスタスクがあれば完了に連動
        try {
          final linkedBlockId = task.blockId;
          if (linkedBlockId != null && linkedBlockId.isNotEmpty) {
            // Block.taskId から InboxTask を特定
            final block = BlockService.getBlockById(linkedBlockId);
            final inboxId = block?.taskId;
            if (inboxId != null && inboxId.isNotEmpty) {
              await completeInboxTask(inboxId);
            }
            // 残り時間ブロックの自動作成仕様は廃止
          }
        } catch (_) {}

        await refreshTasks();
      }
    } catch (e) {
      // エラーハンドリング
    }
  }

  /// 表示対象日付のブロックについて、サーバの最新値をローカルへ反映（読込欠落の矯正）
  /// 前日分も含めて同期し、日付跨ぎの実行・完了を取りこぼさない
  Future<void> reconcileSkippedFlagsForDate(DateTime date) async {
    try {
      // 徹底して差分同期（lastModified cursor）に寄せる。
      // dayKey による日付スコープ全件取得は、日次データ量に比例してreadが増えるため禁止。
      //
      // NOTE:
      // - 本来の目的は「サーバの最新値（isSkipped等）をローカルへ反映」なので、
      //   lastModified が更新されている限り差分同期で十分に矯正できる。
      await SyncManager.syncDataFor(
        {DataSyncTarget.blocks},
        forceHeavy: false,
      );
      await refreshTasks();
    } catch (_) {}
  }

  // 指定日付のデータをバックグラウンド同期して完了後に反映
  // 追加: 前日分も含めて同期
  Future<void> syncDateInBackground(DateTime date) async {
    try {
      // VersionFeed pull は同一フローで1回にまとめる（read削減）
      const caller = 'TaskProvider.syncDateInBackground';
      await OnDemandSyncService.ensureTimelineDay(
        date,
        pullVersionFeed: true,
        caller: caller,
      );
      await OnDemandSyncService.ensureInboxDay(
        date,
        pullVersionFeed: false,
        caller: caller,
      );
    } catch (e) {
      // continue
    } finally {
      await refreshTasks();
    }
  }

  // 残り時間ブロック自動作成機能は廃止

  // 実績版タスク作成（予定ブロックから変換）
  Future<ActualTask> createActualTask(Block blockObj) async {
    try {
      final now = DateTime.now();

      final actualTask = ActualTask(
        id: now.millisecondsSinceEpoch.toString(),
        title: blockObj.title,
        projectId: blockObj.projectId,
        dueDate: blockObj.dueDate,
        startTime: now, // 一時的に設定（start()メソッドで上書きされる）
        status: ActualTaskStatus.paused, // 作成時は一時停止状態
        memo: blockObj.memo,
        createdAt: now,
        lastModified: now,
        userId: AuthService.getCurrentUserId() ?? '',
        blockId: (blockObj.cloudId != null && blockObj.cloudId!.isNotEmpty)
            ? blockObj.cloudId!
            : blockObj.id,
        subProjectId: blockObj.subProjectId,
        subProject: blockObj.subProject,
        modeId: blockObj.modeId,
        blockName: blockObj.blockName,
      );

      // 実績タスクを追加（ブロック更新と同一タイミングでUIを更新するため、ここではリフレッシュを遅延）
      await addActualTask(actualTask, skipRefresh: true);

      actualTask.start(); // タスクを開始して正しい開始時刻を設定
      await ActualTaskService.updateActualTask(actualTask);
      // 開始状態を即時同期（別端末の再生バー反映のため）
      unawaited(TaskSyncManager.syncActualTaskImmediately(actualTask, 'start'));

      // 予定ブロックはユーザーの情報源として残す（完了フラグは触らない）
      // 実績作成後に即リフレッシュして UI を整合させる
      await refreshTasks();

      return actualTask;
    } catch (e) {
      rethrow;
    }
  }

  // インボックスタスクから実績タスクを作成して即時開始（予定ブロックは作らない）
  Future<void> createActualTaskFromInbox(String inboxTaskId) async {
    try {
      final task = InboxTaskService.getInboxTask(inboxTaskId);
      if (task == null) return;

      final now = DateTime.now();

      // 先にインボックス側を完了扱いにしてローカル表示から即座に除外する
      final completedInbox = task.copyWith(
        isCompleted: true,
        endTime: now,
      );
      try {
        completedInbox.markAsModified(await DeviceInfoService.getDeviceId());
      } catch (_) {}

      final idx = _inboxTasks.indexWhere((t) => t.id == inboxTaskId);
      if (idx != -1) {
        final updatedList = List<inbox.InboxTask>.from(_inboxTasks)
          ..removeAt(idx);
        _inboxTasks = updatedList;
        _scheduleNotify();
      }
      await InboxTaskService.updateInboxTask(completedInbox);
      // 送信失敗時も outbox に残して再送させる（巻き戻り防止）
      unawaited(TaskSyncManager.syncInboxTaskImmediately(completedInbox, 'update'));

      final newActual = ActualTask(
        id: now.millisecondsSinceEpoch.toString(),
        title: task.title,
        projectId: task.projectId,
        dueDate: task.dueDate,
        startTime: now,
        status: ActualTaskStatus.running,
        memo: task.memo,
        createdAt: now,
        lastModified: now,
        userId: AuthService.getCurrentUserId() ?? task.userId,
        blockId: null, // 予定ブロックを作らない
        subProjectId: task.subProjectId,
        subProject: null,
        modeId: task.modeId,
        blockName: null,
        sourceInboxTaskId: task.id,
      );

      await ActualTaskService.addActualTask(newActual);
      // 即時同期して他画面でも再生バーを表示可能に
      unawaited(TaskSyncManager.syncActualTaskImmediately(newActual, 'start'));

      await refreshTasks();
    } catch (e) {
      // エラーハンドリング
    }
  }

  // インボックスタスク完了
  Future<void> completeInboxTask(String taskId) async {
    try {
      final task = InboxTaskService.getInboxTask(taskId);
      if (task != null) {
        final now = DateTime.now();
        task.isCompleted = true;
        task.endTime = now;
        try {
          task.markAsModified(await DeviceInfoService.getDeviceId());
        } catch (_) {}
        await InboxTaskService.updateInboxTask(task);
        // 送信失敗時も outbox に残して再送させる（巻き戻り防止）
        unawaited(TaskSyncManager.syncInboxTaskImmediately(task, 'update'));

        await refreshTasks();
      }
    } catch (e) {
      // エラーハンドリング
    }
  }

  // インボックスタスク完了 + 0分実績作成（Runningバーなし）
  Future<void> completeInboxTaskWithZeroActual(String taskId) async {
    try {
      final task = InboxTaskService.getInboxTask(taskId);
      if (task == null) return;

      // 楽観的にインボックス一覧から除外（0分実績作成と並走しても二重表示させない）
      final idx = _inboxTasks.indexWhere((t) => t.id == taskId);
      if (idx != -1) {
        final updatedList = List<inbox.InboxTask>.from(_inboxTasks)
          ..removeAt(idx);
        _inboxTasks = updatedList;
        _scheduleNotify();
      }

      final now = DateTime.now();
      final completedInbox = task.copyWith(
        isCompleted: true,
        endTime: now,
      );
      try {
        completedInbox.markAsModified(await DeviceInfoService.getDeviceId());
      } catch (_) {}
      await InboxTaskService.updateInboxTask(completedInbox);

      final DateTime scheduledStart = now;

      await ActualTaskSyncService().createCompletedZeroTaskWithSync(
        title: task.title,
        projectId: task.projectId,
        dueDate: task.dueDate,
        memo: task.memo,
        blockId: task.blockId,
        subProjectId: task.subProjectId,
        subProject: _resolveInboxSubProjectName(task.subProjectId),
        modeId: task.modeId,
        blockName: _resolveInboxBlockName(task.blockId),
        startTime: scheduledStart,
        endTime: scheduledStart,
        sourceInboxTaskId: task.id,
      );

      // 送信失敗時も outbox に残して再送させる（巻き戻り防止）
      unawaited(
        TaskSyncManager.syncInboxTaskImmediately(completedInbox, 'update'),
      );

      await refreshTasks(showLoading: false);
    } catch (e) {
      rethrow;
    }
  }

  // インボックスタスク更新（ブロックとの関連付け変更に対応）
  Future<void> updateInboxTask(inbox.InboxTask task) async {
    try {
      // 既存のタスクを取得して変更内容を確認
      final existingTask = InboxTaskService.getInboxTask(task.id);

      if (existingTask != null) {
        // ブロック関連付けの変更を確認
        final oldBlockId = existingTask.blockId;
        final newBlockId = task.blockId;
        final titleChanged = existingTask.title != task.title;

        // ブロック関連付けが変わる場合は、保存前に “ブロック基準の再スケジュール” を反映しておく。
        // これにより、lastModified/version を「1回だけ」更新すればよくなる（不要な再更新を防止）。
        if (oldBlockId != newBlockId &&
            newBlockId != null &&
            newBlockId.isNotEmpty) {
          try {
            final blk = BlockService.getBlockById(newBlockId);
            if (blk != null) {
              final scheduled = _scheduleInboxInsideBlock(task, blk);
              if (scheduled != null) {
                task.executionDate = scheduled.executionDate;
                task.startHour = scheduled.startHour;
                task.startMinute = scheduled.startMinute;
              } else {
                // ギャップが確保できない場合も、少なくとも実行日だけはブロック日に合わせる
                final d = blk.executionDate;
                task.executionDate = DateTime(d.year, d.month, d.day);
                task.startHour = null;
                task.startMinute = null;
              }
            }
          } catch (_) {}
        }

        // メタデータ（lastModified/version/deviceId）は「意味のある変更」がある場合にのみ更新する。
        await _ensureInboxMetadata(task, existingTask);

        // タスクを更新（ローカル）
        await InboxTaskService.updateInboxTask(task);

        // 関連付けの変更処理
        if (oldBlockId != newBlockId) {
          // 古い関連付けを解除
          if (oldBlockId != null && oldBlockId.isNotEmpty) {
            await unlinkInboxTaskFromBlock(task.id, oldBlockId);
          }

          // 新しい関連付けを設定
          if (newBlockId != null && newBlockId.isNotEmpty) {
            await _linkInboxTaskToBlock(task.id, newBlockId, task.title);
          }
        } else if (newBlockId != null &&
            newBlockId.isNotEmpty &&
            titleChanged) {
          // 関連付けは変わらないがタイトルが変更された場合、
          // primaryリンクのブロックに限ってタイトルを追従させる
          await _updateLinkedBlockTitleIfPrimary(newBlockId, task.id, task.title);
        } else {
          // 仕様変更: 自動で予定ブロックを作成しない（リンクレス運用）
        }
      } else {
        await _ensureInboxMetadata(task, null);
        // 既存タスクが見つからない場合は単純に更新
        await InboxTaskService.updateInboxTask(task);
      }
      // 即時同期（更新）
      unawaited(TaskSyncManager.syncInboxTaskImmediately(task, 'update'));

      await refreshTasks();
    } catch (e) {
      // エラーハンドリング
    }
  }

  static const Set<String> _inboxMetadataKeys = {
    'lastModified',
    'lastSynced',
    'deviceId',
    'version',
  };

  Map<String, dynamic> _stripInboxMetadata(inbox.InboxTask task) {
    final data = Map<String, dynamic>.from(task.toCloudJson());
    data.removeWhere((key, value) => _inboxMetadataKeys.contains(key));
    return data;
  }

  Future<void> _ensureInboxMetadata(
      inbox.InboxTask task, inbox.InboxTask? existing) async {
    if (existing == null) {
      final deviceId = await DeviceInfoService.getDeviceId();
      task.lastModified = DateTime.now();
      task.version = task.version > 0 ? task.version : 1;
      task.deviceId = deviceId;
      return;
    }

    final hasMeaningfulChange =
        !mapEquals(_stripInboxMetadata(task), _stripInboxMetadata(existing));
    if (!hasMeaningfulChange) {
      return;
    }

    final callerUpdatedMetadata =
        task.lastModified.isAfter(existing.lastModified) &&
            task.version > existing.version;

    if (callerUpdatedMetadata) {
      return;
    }

    final deviceId = await DeviceInfoService.getDeviceId();
    task.lastModified = DateTime.now();
    task.version = existing.version + 1;
    task.deviceId = deviceId;
  }

  String? _resolveInboxSubProjectName(String? subProjectId) {
    if (subProjectId == null || subProjectId.isEmpty) {
      return null;
    }
    final subProject = SubProjectService.getSubProjectById(subProjectId);
    final rawName = subProject?.name;
    final name = rawName?.trim();
    return (name != null && name.isNotEmpty) ? name : null;
  }

  String? _resolveInboxBlockName(String? blockId) {
    if (blockId == null || blockId.isEmpty) {
      return null;
    }
    final block = BlockService.getBlockById(blockId);
    final blockName = block?.blockName;
    final name = blockName?.trim();
    if (name != null && name.isNotEmpty) {
      return name;
    }
    final rawTitle = block?.title;
    final title = rawTitle?.trim();
    return (title != null && title.isNotEmpty) ? title : null;
  }

  // 汎用削除メソッド（タスクの型に応じて適切な削除処理を実行）
  Future<void> deleteTask(String taskId) async {
    try {
      // ブロック検索
      final block = BlockService.getBlockById(taskId);
      if (block != null) {
        await deleteBlock(taskId);
        return;
      }

      // 実績タスク検索
      final actualTask = ActualTaskService.getActualTask(taskId);
      if (actualTask != null) {
        await deleteActualTask(taskId);
        return;
      }

      // インボックスタスク検索
      final inboxTask = InboxTaskService.getInboxTask(taskId);
      if (inboxTask != null) {
        await deleteInboxTask(taskId);
        return;
      }
    } catch (e) {
      rethrow;
    }
  }

  // 統一されたタスク追加メソッド
  Future<void> addTask(dynamic task) async {
    try {
      if (task is inbox.InboxTask) {
        await addInboxTask(task);
      } else if (task is Block) {
        await addBlock(task);
      } else if (task is ActualTask) {
        await addActualTask(task);
      }
    } catch (e) {
      // エラーハンドリング
    }
  }

  // 統一されたタスク完了メソッド
  Future<void> completeTask(String taskId) async {
    try {
      // インボックスタスクとして完了を試行
      final inboxTask = InboxTaskService.getInboxTask(taskId);
      if (inboxTask != null) {
        await completeInboxTask(taskId);
        return;
      }

      // 実績タスクとして完了を試行
      final actualTask = ActualTaskService.getActualTask(taskId);
      if (actualTask != null) {
        await completeActualTask(taskId);
        return;
      }
    } catch (e) {
      // エラーハンドリング
    }
  }

  // 統一されたタスク作成メソッド（カレンダー用）
  Future<void> createTaskForCalendar({
    required String title,
    String? memo,
    DateTime? executionDate,
    String? projectId,
    int estimatedDuration = 60,
  }) async {
    try {
      final now = DateTime.now();
      final blockObj = Block(
        id: now.millisecondsSinceEpoch.toString(),
        title: title,
        memo: memo,
        projectId: projectId,
        executionDate: executionDate ?? now,
        startHour: 9,
        startMinute: 0,
        estimatedDuration: estimatedDuration,
        lastModified: now,
        userId: AuthService.getCurrentUserId() ?? '',
        createdAt: now,
      );
      await addBlock(blockObj);
    } catch (e) {
      rethrow;
    }
  }

  // インボックスタスク追加
  Future<void> addInboxTask(inbox.InboxTask task) async {
    try {
      await InboxTaskService.addInboxTask(task);
      unawaited(TaskSyncManager.syncInboxTaskImmediately(task, 'create'));
      await refreshTasks();
    } catch (e) {
      // エラーハンドリング
    }
  }

  // 過ぎ去った予定（ブロック終了/タスク終了）を未割当に戻す（リンク解除＋時刻リセット）
  Future<int> revertAssignedButIncompleteInboxTasks() async {
    try {
      final now = DateTime.now();
      int changed = 0;

      // タイムライン仕様メモ:
      // - Inbox は startHour/startMinute があるだけでタイムラインに出る（blockId は必須ではない）
      // - そのため「過ぎ去ったか」の判定も、blockId の有無に依存せず、
      //   (1) blockId がある場合はリンク先ブロック
      //   (2) blockId が無い場合は開始時刻が包含されるブロック（start <= tStart < end）
      //   を優先して「ブロックの終了」を基準にする。
      //
      // これにより、進行中ブロック内の前半タスク（タスク終了は過去でもブロック自体は未終了）が
      // 誤って未割当に戻るバグを防ぐ。

      // id/cloudId の両方でブロックを引けるようにMap化
      final Map<String, Block> blockByKey = {};
      for (final b in _blocks) {
        blockByKey[b.id] = b;
        final cid = b.cloudId;
        if (cid != null && cid.isNotEmpty) {
          blockByKey.putIfAbsent(cid, () => b);
        }
      }

      for (final task in _inboxTasks) {
        if (task.isCompleted == true) continue;
        final sh = task.startHour;
        final sm = task.startMinute;
        if (sh == null || sm == null) continue; // そもそも未割当

        final taskStart = DateTime(
          task.executionDate.year,
          task.executionDate.month,
          task.executionDate.day,
          sh,
          sm,
        );

        // 1) blockId があるならリンク先ブロックの終了を基準にする
        final String? blockId = task.blockId;
        final Block? linked = (blockId != null && blockId.isNotEmpty)
            ? blockByKey[blockId]
            : null;

        // 2) blockId が無い（またはリンクブロックが見つからない）なら、
        //    開始時刻が包含されるブロックを推定して、その終了を基準にする
        final Block? containing =
            (linked == null) ? _inferContainingBlockByStart(taskStart) : linked;

        // 判定の締切（cutoff）:
        // - ブロックに属するなら「ブロック終了」
        // - どのブロックにも属さない（ギャップ等）なら従来通り「タスク終了」
        DateTime cutoff;
        if (containing != null) {
          final d = containing.executionDate;
          final bStart = DateTime(d.year, d.month, d.day, containing.startHour, containing.startMinute);
          cutoff = bStart.add(Duration(minutes: containing.estimatedDuration));
        } else {
          cutoff = taskStart.add(Duration(minutes: task.estimatedDuration));
        }

        if (cutoff.isAfter(now)) {
          // まだ過ぎ去っていない（進行中ブロック内、未来ブロック内、または未終了タスク）
          continue;
        }

        // ここに来たものだけを「未割当」に戻す
        // - blockId がある場合は双方向リンク解除も行う
        if (blockId != null && blockId.isNotEmpty) {
          try {
            await unlinkInboxTaskFromBlock(task.id, blockId);
          } catch (_) {}
        }

        final updated = task.copyWith(
          startHour: null,
          startMinute: null,
          blockId: null,
          lastModified: DateTime.now(),
          version: task.version + 1,
        );

        await InboxTaskService.updateInboxTask(updated);
        unawaited(TaskSyncManager.syncInboxTaskImmediately(updated, 'update'));
        changed++;
      }

      if (changed > 0) {
        await refreshTasks();
      }

      return changed;
    } catch (_) {
      return 0;
    }
  }

  // 特定のインボックスタスクを「未割り当て」に戻す（タイムラインのメニュー用）
  // NOTE: getInboxTask の戻り値を in-place で書き換えると、box や _inboxTasks と参照を共有している場合に
  // 不整合や unlink に伴う refresh との競合で表示が崩れるため、copyWith で新オブジェクトを作って保存する。
  Future<void> revertInboxTaskToUnassigned(String inboxTaskId) async {
    try {
      final task = InboxTaskService.getInboxTask(inboxTaskId);
      if (task == null) return;

      // ブロックにリンクされていれば解除（双方向）
      if (task.blockId != null && task.blockId!.isNotEmpty) {
        try {
          await unlinkInboxTaskFromBlock(task.id, task.blockId!);
        } catch (e, st) {
          if (kDebugMode) debugPrint('revertInboxTaskToUnassigned unlinkInboxTaskFromBlock error: $e\n$st');
        }
      }

      // 解除後は getInboxTask で再取得（unlink 内で box が更新されているため）
      final latest = InboxTaskService.getInboxTask(inboxTaskId) ?? task;
      final updated = latest.copyWith(
        startHour: null,
        startMinute: null,
        blockId: null,
        lastModified: DateTime.now(),
        version: latest.version + 1,
      );
      await InboxTaskService.updateInboxTask(updated);
      // 即時同期（完了を待たないと Phase 2 が古いリモートで上書きし巻き戻る）
      await TaskSyncManager.syncInboxTaskImmediately(updated, 'update');

      await refreshTasks();
    } catch (e, st) {
      if (kDebugMode) debugPrint('revertInboxTaskToUnassigned error: $e\n$st');
    }
  }

  Block? _findOngoingBlock(DateTime now) {
    // 進行中ブロック = start <= now < end のブロック（跨日も許容）
    //
    // 重要:
    // - UI（タイムライン）は TaskProvider の `_blocks`（cloudId重複をUI層で集約済み）を参照する。
    // - ここで BlockService.getAllBlocks() を直接見ると「同一cloudIdの複製」の別IDを拾うことがあり、
    //   その場合「繰り越し/集約は成功しているが、表示中のブロックIDと一致しないため反映されない」
    //   という体験になり得る。
    //
    // そのため、原則は `_blocks` から進行中を選ぶ。

    DateTime startLocal(Block b) {
      final s = b.startAt?.toLocal();
      if (s != null) return s;
      final d = b.executionDate;
      return DateTime(d.year, d.month, d.day, b.startHour, b.startMinute);
    }

    DateTime endLocalExclusive(Block b, DateTime start) {
      final e = b.endAtExclusive?.toLocal();
      if (e != null) return e;
      return start.add(Duration(minutes: b.estimatedDuration));
    }

    List<Block> candidates = _blocks
        .where((b) => !b.isDeleted)
        .where((b) => b.isCompleted != true)
        .toList()
      ..sort((a, b) => startLocal(a).compareTo(startLocal(b)));

    Block? pickFrom(List<Block> list) {
      for (final b in list) {
        final s = startLocal(b);
        final e = endLocalExclusive(b, s);
        if (!now.isBefore(s) && now.isBefore(e)) {
          return b;
        }
      }
      return null;
    }

    final fromProvider = pickFrom(candidates);
    if (fromProvider != null) return fromProvider;

    // フォールバック: まだ provider が古い / 初期化途中でも動けるようにServiceを参照。
    // ただし、見つかったブロックが cloudId を持つ場合は `_blocks` 側の代表に寄せる。
    try {
      final raw = BlockService.getAllBlocks()
          .where((b) => !b.isDeleted)
          .where((b) => b.isCompleted != true)
          .toList()
        ..sort((a, b) => startLocal(a).compareTo(startLocal(b)));
      final picked = pickFrom(raw);
      if (picked == null) return null;
      final cid = picked.cloudId;
      if (cid != null && cid.isNotEmpty) {
        try {
          final rep = _blocks.firstWhere((b) => (b.cloudId ?? '') == cid);
          return rep;
        } catch (_) {}
      }
      return picked;
    } catch (_) {
      return null;
    }
  }

  /// 現在時刻を含む予定ブロックを1件返す（ポモドーロ等で初期値引き継ぎに使用）。
  Block? getBlockAtCurrentTime() => _findOngoingBlock(DateTime.now());

  Block? _inferContainingBlockByStart(DateTime taskStart) {
    Block? selected;
    Duration? bestOffset;
    for (final b in _blocks) {
      if (b.isDeleted) continue;
      final start = b.startAt?.toLocal() ??
          DateTime(
            b.executionDate.year,
            b.executionDate.month,
            b.executionDate.day,
            b.startHour,
            b.startMinute,
          );
      final end = b.endAtExclusive?.toLocal() ??
          start.add(Duration(minutes: b.estimatedDuration));
      if (taskStart.isBefore(start)) continue;
      if (!taskStart.isBefore(end)) continue;
      final offset = taskStart.difference(start);
      if (selected == null || offset < bestOffset!) {
        selected = b;
        bestOffset = offset;
      }
    }
    return selected;
  }

  bool _isAssignedToPastBlock(inbox.InboxTask t, DateTime now) {
    final blockId = t.blockId;

    // providerキャッシュからブロックを探す（id/cloudId両対応）
    Block? linked;
    if (blockId != null && blockId.isNotEmpty) {
      for (final b in _blocks) {
        if (b.id == blockId) {
          linked = b;
          break;
        }
        final cid = b.cloudId;
        if (cid != null && cid.isNotEmpty && cid == blockId) {
          linked = b;
          break;
        }
      }
    }

    DateTime? taskStart;
    final sh = t.startHour;
    final sm = t.startMinute;
    if (sh != null && sm != null) {
      taskStart = DateTime(
        t.executionDate.year,
        t.executionDate.month,
        t.executionDate.day,
        sh,
        sm,
      );
    }

    if (linked == null && taskStart != null) {
      linked = _inferContainingBlockByStart(taskStart);
    }

    if (linked != null) {
      final start = linked.startAt?.toLocal() ??
          DateTime(
            linked.executionDate.year,
            linked.executionDate.month,
            linked.executionDate.day,
            linked.startHour,
            linked.startMinute,
          );
      final end = linked.endAtExclusive?.toLocal() ??
          start.add(Duration(minutes: linked.estimatedDuration));
      return !end.isAfter(now); // end <= now
    }

    // ブロックが見つからない場合はタスク側の開始時刻でフォールバック
    if (taskStart != null) {
      final end = taskStart.add(Duration(minutes: t.estimatedDuration));
      return !end.isAfter(now);
    }

    // 開始時刻も無い場合は、日付ベースでざっくり判定（過去日なら対象）
    if (blockId != null && blockId.isNotEmpty) {
      final taskDay = DateTime(
        t.executionDate.year,
        t.executionDate.month,
        t.executionDate.day,
      );
      final today = DateTime(now.year, now.month, now.day);
      final isPastDay = taskDay.isBefore(today);
      return isPastDay;
    }
    return false;
  }

  /// タイムライン用:
  /// 過去ブロックに割当済みだが未完了のインボックスタスクを、
  /// 「現在進行中（今この瞬間を含む）」のブロックへ集約する。
  ///
  /// 戻り値:
  /// - null: 成功（または既に進行中ブロックに居るため何もしない）
  /// - non-null: 失敗理由（例: 進行中ブロックが無い）
  Future<String?> consolidateInboxTaskToOngoingBlock(String inboxTaskId) async {
    try {
      kantInboxTrace(
        'aggregate_single_begin',
        'inboxTaskId=$inboxTaskId',
      );
      final now = DateTime.now();
      final task = InboxTaskService.getInboxTask(inboxTaskId);
      if (task == null) return '対象のタスクが見つかりませんでした';

      final ongoing = _findOngoingBlock(now);
      if (ongoing == null) {
        return '現在進行中のブロックがありません';
      }

      // 既に進行中ブロックに居れば何もしない
      if (task.blockId != null &&
          task.blockId!.isNotEmpty &&
          (task.blockId == ongoing.id ||
              (ongoing.cloudId != null &&
                  ongoing.cloudId!.isNotEmpty &&
                  task.blockId == ongoing.cloudId))) {
        return null;
      }

      // 旧ブロックにリンクされていれば解除（双方向）
      if (task.blockId != null && task.blockId!.isNotEmpty) {
        try {
          await unlinkInboxTaskFromBlock(task.id, task.blockId!);
          kantInboxTrace(
            'aggregate_single_after_unlink',
            'id=${task.id} oldBlockId=${task.blockId}',
          );
        } catch (_) {}
      }

      // 進行中ブロックへ割当（ブロック内のギャップに自動配置）
      await assignInboxToBlockWithScheduling(task.id, ongoing.id);
      kantInboxTrace(
        'aggregate_single_after_assign',
        'id=$inboxTaskId ongoing=${ongoing.id}',
      );
      return null;
    } catch (e) {
      return '集約に失敗しました: $e';
    }
  }

  /// タイムラインAppBar用（=一括操作）:
  /// 「過去ブロックに割当済みだが未完了」のインボックスタスクを、進行中ブロックへまとめて集約する。
  ///
  /// 返り値はユーザー向けメッセージ（SnackBar表示用）。
  Future<String> consolidateAssignedButIncompleteInboxTasksToOngoingBlock() async {
    final now = DateTime.now();
    final ongoing = _findOngoingBlock(now);
    if (ongoing == null) {
      return '現在進行中のブロックがありません';
    }
    kantInboxTrace(
      'aggregate_batch_begin',
      'ongoingId=${ongoing.id} ongoingCloudId=${ongoing.cloudId} inboxCount=${_inboxTasks.length}',
    );
    final copy = List<inbox.InboxTask>.from(_inboxTasks);
    if (kDebugMode) {
      final withBlock = copy.where((t) => (t.blockId ?? '').isNotEmpty).length;
      debugPrint(
          '[Aggregate] start ongoingBlockId=${ongoing.id} ongoingCloudId=${ongoing.cloudId} '
          'inboxTotal=${copy.length} withBlockId=$withBlock',
      );
    }

    int moved = 0;
    try {
      // 進行中ブロックに対して、対象タスクを順に割当（最後にまとめてrefresh）
      for (final t0 in copy) {
        if (t0.isCompleted == true) {
          if (kDebugMode) {
            debugPrint('[Aggregate] skip id=${t0.id} reason=completed');
          }
          continue;
        }
        final blockId = t0.blockId;

        // 「過去ブロックに割当」判定
        if (!_isAssignedToPastBlock(t0, now)) {
          if (kDebugMode) {
            final dateStr = t0.executionDate.toIso8601String().split('T')[0];
            debugPrint(
                '[Aggregate] skip id=${t0.id} reason=notPastBlock blockId=$blockId executionDate=$dateStr',
            );
          }
          continue;
        }

        // 既に進行中ブロックに居ればスキップ
        if (blockId != null &&
            blockId.isNotEmpty &&
            (blockId == ongoing.id ||
                (ongoing.cloudId != null &&
                    ongoing.cloudId!.isNotEmpty &&
                    blockId == ongoing.cloudId))) {
          if (kDebugMode) {
            debugPrint('[Aggregate] skip id=${t0.id} reason=alreadyOngoing blockId=$blockId');
          }
          continue;
        }

        // 旧リンク解除（双方向）
        if (blockId != null && blockId.isNotEmpty) {
          try {
            await unlinkInboxTaskFromBlock(t0.id, blockId);
            kantInboxTrace(
              'aggregate_batch_after_unlink',
              'taskId=${t0.id} unlinkedFromBlockId=$blockId',
            );
          } catch (_) {}
        }

        // ブロック内に自動配置（refreshは最後に1回）
        final latest = InboxTaskService.getInboxTask(t0.id) ?? t0;
        final scheduled = _scheduleInboxInsideBlock(latest, ongoing);
        final DateTime blockDate = DateTime(
          ongoing.executionDate.year,
          ongoing.executionDate.month,
          ongoing.executionDate.day,
        );
        final updated = (scheduled != null)
            ? latest.copyWith(
                blockId: (ongoing.cloudId != null && ongoing.cloudId!.isNotEmpty)
                    ? ongoing.cloudId!
                    : ongoing.id,
                executionDate: scheduled.executionDate,
                startHour: scheduled.startHour,
                startMinute: scheduled.startMinute,
                isSomeday: false,
                lastModified: DateTime.now(),
                version: latest.version + 1,
              )
            : latest.copyWith(
                blockId: (ongoing.cloudId != null && ongoing.cloudId!.isNotEmpty)
                    ? ongoing.cloudId!
                    : ongoing.id,
                executionDate: blockDate,
                // estimatedDuration=0などで配置不可の場合でも、ブロックの開始時刻を
                // フォールバックとして使用する（assignInboxToBlockWithSchedulingと同様の挙動）。
                // startHourがnullのままだとブロック折り畳み時にタスクが完全に非表示になる。
                startHour: ongoing.startHour,
                startMinute: ongoing.startMinute,
                isSomeday: false,
                lastModified: DateTime.now(),
                version: latest.version + 1,
              );

        await InboxTaskService.updateInboxTask(updated);
        if (kDebugMode) {
          debugPrint(
              '[Aggregate] moved taskId=${updated.id} cloudId=${updated.cloudId} newBlockId=${updated.blockId} version=${updated.version}',
          );
        }
        // 同一 task.id の Upload は TaskSyncManager 側で直列化。UI はローカル更新後すぐ進める。
        unawaited(TaskSyncManager.syncInboxTaskImmediately(updated, 'update'));
        try {
          await _linkInboxTaskToBlock(updated.id, ongoing.id, updated.title);
        } catch (_) {}

        // メモリ上のリストも更新して、同一ブロック内の自動配置が次タスクに反映されるようにする
        try {
          final idx = _inboxTasks.indexWhere((x) => x.id == updated.id);
          if (idx != -1) {
            final list = List<inbox.InboxTask>.from(_inboxTasks);
            list[idx] = updated;
            _inboxTasks = list;
          }
        } catch (_) {}

        moved++;
      }
    } catch (e) {
      return '集約に失敗しました: $e';
    } finally {
      kantInboxTrace('aggregate_batch_refreshTasks_before', 'moved=$moved');
      await refreshTasks(showLoading: false);
      kantInboxTrace(
        'aggregate_batch_refreshTasks_after',
        'moved=$moved inboxMemCount=${_inboxTasks.length}',
      );
      if (kDebugMode) {
        final countWithBlock = _inboxTasks
            .where((t) =>
                (t.blockId ?? '') == (ongoing.cloudId ?? '') ||
                (t.blockId ?? '') == ongoing.id)
            .length;
        debugPrint(
            '[Aggregate] after refreshTasks: moved=$moved inMemoryWithOngoingBlock=$countWithBlock',
        );
      }
    }

    if (moved == 0) {
      return '集約対象のタスクがありません';
    }
    kantInboxTrace('aggregate_batch_done', 'moved=$moved');
    return '$moved件を進行中ブロックに集約しました';
  }

  // インボックスタスク削除（関連ブロックとの結びつき解除付き）
  Future<void> deleteInboxTask(String taskId) async {
    try {
      // 削除前に関連ブロックとの結びつきを確認・解除
      final task = InboxTaskService.getInboxTask(taskId);
      if (task != null && task.blockId != null && task.blockId!.isNotEmpty) {
        await unlinkInboxTaskFromBlock(taskId, task.blockId!);
      }

      // 同期対応削除（Firebaseにも反映）
      await InboxTaskSyncService().deleteTaskWithSync(taskId);
      await refreshTasks();
    } catch (e) {
      // エラーハンドリング
    }
  }

  // インボックスタスク作成（ブロックとの双方向関連付けとタスク名更新付き）
  Future<void> createTaskForInbox({
    required String title,
    String? memo,
    DateTime? dueDate,
    String? projectId,
    String? subProjectId,
    DateTime? executionDate,
    int? startHour,
    int? startMinute,
    int? estimatedDuration,
    String? blockId,
    String? modeId,
    bool isSomeday = false,
    bool isImportant = false,
  }) async {
    try {
      final now = DateTime.now();
      final defaultMinutes = AppSettingsService.getInt(
        AppSettingsService.keyTaskDefaultEstimatedMinutes,
        defaultValue: 0,
      );
      final inboxTask = inbox.InboxTask(
        id: now.millisecondsSinceEpoch.toString(),
        title: title,
        memo: memo,
        projectId: projectId,
        subProjectId: subProjectId,
        dueDate: dueDate,
        executionDate: executionDate ?? now,
        startHour: isSomeday ? null : startHour,
        startMinute: isSomeday ? null : startMinute,
        estimatedDuration: estimatedDuration ?? defaultMinutes,
        blockId: isSomeday ? null : blockId,
        isSomeday: isSomeday,
        isImportant: isImportant,
        modeId: modeId,
        createdAt: now,
        lastModified: now,
        userId: AuthService.getCurrentUserId() ?? '',
      );

      await addInboxTask(inboxTask);

      // ブロックとの関連付けが指定されている場合、双方向リンクを設定
      if (!isSomeday && blockId != null && blockId.isNotEmpty) {
        await _linkInboxTaskToBlock(inboxTask.id, blockId, title);
      }
    } catch (e) {
      rethrow;
    }
  }

  // インボックスタスクとブロックをリンクする
  //
  // NOTE:
  // 以前は「Block(予定) 1件に InboxTask 1件」を前提に、
  //   - Block.taskId を InboxTask.id に設定
  //   - Block.title を InboxTask.title に上書き
  // していたが、現在は「1つのブロックに複数InboxTaskを割当」できるため、
  // 一般的な割当操作で Block.title を変更すると「予定ブロック名が勝手に変わる」副作用になる。
  //
  // そのため、Block.title の更新は「そのブロックが当該InboxTaskを primary として保持している」
  // (= block.taskId == inboxTaskId) 場合にのみ行い、新規割当ではブロック側を変更しない。
  Future<void> _linkInboxTaskToBlock(
      String inboxTaskId, String blockId, String newTitle) async {
    try {
      final inboxTask = InboxTaskService.getInboxTask(inboxTaskId);
      final block = BlockService.getBlockById(blockId);

      if (inboxTask != null && block != null) {
        // InboxTask側の関連付け（cloudIdがあればcloudIdを優先して保存する）
        // localId(=blockId)とcloudIdの両方で「既にリンク済み」と判定し、
        // どちらでも一致していれば上書きしない。これにより、集約処理が
        // 正しくcloudIdを設定した後にlocalIdで上書きされるバグを防ぐ。
        final preferredLinkId =
            (block.cloudId != null && block.cloudId!.isNotEmpty)
                ? block.cloudId!
                : blockId;
        final alreadyLinked = inboxTask.blockId == blockId ||
            inboxTask.blockId == preferredLinkId;
        if (!alreadyLinked) {
          inboxTask.blockId = preferredLinkId;
          if (block.modeId != null && block.modeId!.isNotEmpty) {
            inboxTask.modeId = block.modeId;
          }
          await InboxTaskService.updateInboxTask(inboxTask);
          // 即時同期（更新）
          unawaited(
            TaskSyncManager.syncInboxTaskImmediately(inboxTask, 'update'),
          );
        } else if (block.modeId != null && block.modeId!.isNotEmpty &&
            (inboxTask.modeId == null || inboxTask.modeId!.isEmpty)) {
          // blockIdは正しいがmodeIdが未設定の場合のみmodeIdを同期する
          inboxTask.modeId = block.modeId;
          await InboxTaskService.updateInboxTask(inboxTask);
          unawaited(
            TaskSyncManager.syncInboxTaskImmediately(inboxTask, 'update'),
          );
        }

        // Block側の更新は「primaryリンク (= taskId一致)」のときだけ許可する。
        // これにより、割当/集約で予定ブロック名が書き換わるのを防ぐ。
        bool blockUpdated = false;
        if (block.taskId != null &&
            block.taskId!.isNotEmpty &&
            block.taskId == inboxTaskId) {
          if (block.title != newTitle) {
            block.title = newTitle;
            blockUpdated = true;
          }
        }

        if (blockUpdated) {
          await BlockSyncService().updateBlockWithSync(block);
        }
      }
    } catch (e) {
      rethrow;
    }
  }

  // ブロック内にインボックスタスクを自動配置する（開始時刻のみ決定）
  // 返り値: 配置後の(実行日/開始時刻)を埋めた簡易ダミーInbox。nullの場合は配置不可
  inbox.InboxTask? _scheduleInboxInsideBlock(inbox.InboxTask task, Block blk) {
    final date = DateTime(
        blk.executionDate.year, blk.executionDate.month, blk.executionDate.day);
    final blockStart = DateTime(
        date.year, date.month, date.day, blk.startHour, blk.startMinute);
    final blockEnd = blockStart.add(Duration(minutes: blk.estimatedDuration));

    final int duration = task.estimatedDuration;
    if (duration <= 0) return null;

    // 1) ブロック時間帯に既に配置済みのInbox（当日・時間あり・未完了）を収集（リンク有無は不問）
    final assigned = _inboxTasks
        .where((t) =>
            t.executionDate.year == date.year &&
            t.executionDate.month == date.month &&
            t.executionDate.day == date.day &&
            t.startHour != null &&
            t.startMinute != null &&
            (t.isCompleted != true))
        .map((t) {
          final tStart = DateTime(
              date.year, date.month, date.day, t.startHour!, t.startMinute!);
          final tEnd = tStart.add(Duration(minutes: t.estimatedDuration));
          final s = tStart.isAfter(blockStart) ? tStart : blockStart;
          final e = tEnd.isBefore(blockEnd) ? tEnd : blockEnd;
          return [s, e];
        })
        .where((iv) => iv[0].isBefore(iv[1]))
        .toList();

    // 2) 実績を占有化（リンク有無は不問、ブロック時間帯と重なる範囲）
    final actuals = getActualTasksForDate(date)
        .map((a) {
          final s = a.startTime.isAfter(blockStart) ? a.startTime : blockStart;
          final now = DateTime.now();
          final aEnd = a.endTime ?? now;
          final e = aEnd.isBefore(blockEnd) ? aEnd : blockEnd;
          return [s, e];
        })
        .where((iv) => iv[0].isBefore(iv[1]))
        .toList();

    // 3) 占有リスト結合＋正規化
    final intervals = <List<DateTime>>[...assigned, ...actuals]
      ..sort((a, b) => a[0].compareTo(b[0]));
    final merged = <List<DateTime>>[];
    for (final iv in intervals) {
      if (merged.isEmpty) {
        merged.add(iv);
      } else {
        final last = merged.last;
        if (iv[0].isAfter(last[1])) {
          merged.add(iv);
        } else {
          if (iv[1].isAfter(last[1])) last[1] = iv[1];
        }
      }
    }

    // 4) ギャップ探索（最初に入る場所）: 過去に置かないため now 以降から探索
    final now = DateTime.now();
    final DateTime searchStart = now.isAfter(blockStart) ? now : blockStart;
    // ブロックが既に終了している場合でも「割り当て済み扱い」になるよう開始時刻は付与する。
    // （過去ブロックへ割り当てたときに startHour/startMinute が欠落して未割り当て扱いになる不具合対策）
    if (!searchStart.isBefore(blockEnd)) {
      DateTime s = blockEnd.subtract(Duration(minutes: duration));
      if (s.isBefore(blockStart)) s = blockStart;
      return task.copyWith(
        executionDate: date,
        startHour: s.hour,
        startMinute: s.minute,
      );
    }
    DateTime cursor = searchStart;
    for (final iv in merged) {
      // 完全に過去の占有はスキップしつつ、探索は常に cursor から
      if (!iv[1].isAfter(cursor)) {
        continue;
      }
      final gapStart = cursor;
      final gapEnd = iv[0].isBefore(blockEnd) ? iv[0] : blockEnd;
      final gapMinutes = gapEnd.difference(gapStart).inMinutes;
      if (gapMinutes >= duration) {
        final s = gapStart;
        return task.copyWith(
          executionDate: date,
          startHour: s.hour,
          startMinute: s.minute,
          // 終了時刻フィールドは無いので、UI側は start+duration を使用
        );
      }
      if (iv[1].isAfter(cursor)) cursor = iv[1];
      if (cursor.isAfter(blockEnd)) break;
    }

    // 5) ギャップ無し:
    // - 残り時間で開始できるなら cursor から
    // - できなければ「終端寄せ」で開始時刻だけは必ず付与する
    //
    // NOTE:
    // タイムライン表示は startHour/startMinute を前提に並べるため、
    // 空き不足でも start を付与しないと「割り当て済みにならない/行方不明」になる。
    // ただし二重表示を避けるため、開始時刻は必ず [blockStart, blockEnd) に収める。
    final remaining = blockEnd.difference(cursor).inMinutes;
    if (remaining >= duration) {
      final s = cursor;
      return task.copyWith(
        executionDate: date,
        startHour: s.hour,
        startMinute: s.minute,
      );
    }
    // 終端寄せ（重なり許容）:
    // - 基本: blockEnd - duration
    // - ただし「過去に置かない」ため searchStart 以降へ寄せる
    // - さらに開始はブロック内へ収める（duration がブロック長より長い場合は blockStart）
    DateTime s = blockEnd.subtract(Duration(minutes: duration));
    if (s.isBefore(searchStart)) s = searchStart;
    if (s.isBefore(blockStart)) s = blockStart;
    if (!s.isBefore(blockEnd)) {
      return null;
    }
    return task.copyWith(
      executionDate: date,
      startHour: s.hour,
      startMinute: s.minute,
    );
  }

  // インボックスタスクとブロックの関連を解除（外部からも呼び出し可能）
  Future<void> unlinkInboxTaskFromBlock(
      String inboxTaskId, String blockId) async {
    try {
      final inboxTask = InboxTaskService.getInboxTask(inboxTaskId);
      // blockId は「ローカルID」だけでなく「cloudId」が入っている場合があるため、
      // まずローカルIDで引き、無ければ cloudId でフォールバックする。
      Block? block = BlockService.getBlockById(blockId);
      if (block == null) {
        try {
          block = BlockService.getAllBlocks()
              .where((b) => !b.isDeleted)
              .firstWhere((b) => (b.cloudId ?? '') == blockId);
        } catch (_) {
          block = null;
        }
      }

      if (inboxTask != null && block != null) {
        // InboxTask側の関連付けを解除（blockId/cloudId どちらで呼ばれても解除できるようにする）
        final link = inboxTask.blockId;
        final matches = link != null &&
            link.isNotEmpty &&
            (link == block.id ||
                ((block.cloudId ?? '').isNotEmpty && link == block.cloudId));
        if (matches) {
          final updated = inboxTask.copyWith(
            blockId: null,
            lastModified: DateTime.now(),
            version: inboxTask.version + 1,
          );
          await InboxTaskService.updateInboxTask(updated);
          // 即時同期（更新）。TaskSyncManager が同一 task.id の Upload を直列化するため unawaited 可。
          unawaited(
            TaskSyncManager.syncInboxTaskImmediately(updated, 'update'),
          );
          kantInboxTrace(
            'unlink_fire_sync',
            'taskId=$inboxTaskId v=${updated.version} blockId=null cloudId=${updated.cloudId}',
          );
        }

        // Block側のtaskIdを解除
        if (block.taskId == inboxTaskId) {
          block.taskId = null;
          await BlockSyncService().updateBlockWithSync(block);
        }
      }
    } catch (e) {
      rethrow;
    }
  }

  // 1:N 仕様の割当: 既存インボックスタスクを指定ブロックへスケジューリングしてリンクする
  // ルール概要（新タイムラインと同一）:
  // - ブロック内の既割当インボックスタスク(開始時刻あり)と実績(Actual)を占有として扱い、
  //   ブロック開始から推定作業時間(estimatedDuration)が入る最初のギャップに配置。
  // - 実績は [max(actual.start, block.start), min(actual.end(なければnow), block.end)] を占有。
  // - 空きがない場合は終端寄せ（end=block.end, start=end-duration）で重なり許容。
  // - executionDateはブロック日に更新。
  Future<void> assignInboxToBlockWithScheduling(
      String inboxTaskId, String blockId) async {
    final t = InboxTaskService.getInboxTask(inboxTaskId);
    final blk = BlockService.getBlockById(blockId);
    if (t == null || blk == null) return;

    final DateTime blockDate = DateTime(
      blk.executionDate.year,
      blk.executionDate.month,
      blk.executionDate.day,
    );

    // 配置不可(null)でも、少なくとも「開始時刻」を必ず付与して割り当て済みとして扱う。
    // （startHour/startMinute が null のままだと、インボックス側に残ったり未割り当て表示になる）
    final scheduled = _scheduleInboxInsideBlock(t, blk) ??
        t.copyWith(
          executionDate: blockDate,
          startHour: blk.startHour,
          startMinute: blk.startMinute,
        );

    final updated = t.copyWith(
      blockId: (blk.cloudId != null && blk.cloudId!.isNotEmpty)
          ? blk.cloudId!
          : blk.id,
      executionDate: scheduled.executionDate,
      startHour: scheduled.startHour,
      startMinute: scheduled.startMinute,
      isSomeday: false,
      lastModified: DateTime.now(),
      version: t.version + 1,
    );

    await InboxTaskService.updateInboxTask(updated);
    unawaited(TaskSyncManager.syncInboxTaskImmediately(updated, 'update'));
    kantInboxTrace(
      'assign_block_sync_queued',
      'taskId=${updated.id} blockId=${updated.blockId} v=${updated.version} cloudId=${updated.cloudId}',
    );

    try {
      await _linkInboxTaskToBlock(updated.id, blk.id, updated.title);
    } catch (e) {
      // link failed
    }

    await refreshTasks(showLoading: false);
  }

  // ブロック未指定のギャップ（= 任意の時間窓）へ、既存インボックスタスクを開始時刻付きで割り当てる。
  // - blockId は付けない（= 未リンクのまま）
  // - ギャップ内に既に存在する「時間ありインボックス」と「実績」を占有として扱い、最初に入る場所へ配置する
  // - 空きがない場合は終端寄せ（重なり許容）で開始時刻だけは必ず付与する
  Future<void> assignInboxToUnassignedGapWithScheduling(
    String inboxTaskId, {
    required DateTime gapStart,
    required DateTime gapEndExclusive,
  }) async {
    final t = InboxTaskService.getInboxTask(inboxTaskId);
    if (t == null) return;

    // 防御: start/end が逆転していても落とさない
    DateTime windowStart = gapStart;
    DateTime windowEnd = gapEndExclusive;
    if (!windowStart.isBefore(windowEnd)) {
      // 0分ギャップ等: とりあえず start に寄せる
      windowEnd = windowStart.add(const Duration(minutes: 1));
    }

    final DateTime dateOnly =
        DateTime(windowStart.year, windowStart.month, windowStart.day);

    // 配置不可(null)でも、開始時刻は必ず付与して「時間あり」としてタイムラインに出す。
    final scheduled = _scheduleInboxInsideWindow(t, windowStart, windowEnd) ??
        t.copyWith(
          executionDate: dateOnly,
          startHour: windowStart.hour,
          startMinute: windowStart.minute,
        );

    final updated = t.copyWith(
      blockId: null,
      executionDate: scheduled.executionDate,
      startHour: scheduled.startHour,
      startMinute: scheduled.startMinute,
      isSomeday: false,
      lastModified: DateTime.now(),
      version: t.version + 1,
    );

    // updateInboxTask は blockId 変更（新ブロック割当）時のみブロック内再スケジュールを行う。
    // ここでは blockId=null のため、その副作用は発生しない。
    await updateInboxTask(updated);
  }

  /// 指定ブロックの時間帯 [blockStartLocal, blockEndExclusiveLocal) に開始する
  /// 「未リンク（blockIdなし）の時間ありインボックスタスク」を、開始時刻を保持したまま blockId を付与して紐づける。
  ///
  /// 重要: `updateInboxTask` を使うとブロック内再スケジュールが走り得るため、
  /// ここでは Service 層へ直接 update して開始時刻を維持する。
  ///
  /// 戻り値: 紐づけた件数
  Future<int> linkUnassignedTimedInboxTasksInRangeToBlockPreservingTime({
    required String blockId,
    required DateTime blockStartLocal,
    required DateTime blockEndExclusiveLocal,
  }) async {
    // 防御: ブロックが存在することを確認（modeId 反映にも使用）
    final blk = BlockService.getBlockById(blockId);
    if (blk == null) return 0;

    DateTime start = blockStartLocal;
    DateTime end = blockEndExclusiveLocal;
    if (!start.isBefore(end)) {
      end = start.add(const Duration(minutes: 1));
    }

    bool sameDay(DateTime a, DateTime b) =>
        a.year == b.year && a.month == b.month && a.day == b.day;

    int linked = 0;

    // 候補は「同日」「時間あり」「未完了」「未削除」「Someday除外」「未リンク」
    final candidates = List<inbox.InboxTask>.from(_inboxTasks)
        .where((t) => t.isDeleted != true)
        .where((t) => t.isCompleted != true)
        .where((t) => t.isSomeday != true)
        .where((t) => t.blockId == null || t.blockId!.isEmpty)
        .where((t) => t.startHour != null && t.startMinute != null)
        .where((t) => sameDay(t.executionDate, start))
        .toList();

    for (final t in candidates) {
      final sh = t.startHour;
      final sm = t.startMinute;
      if (sh == null || sm == null) continue;

      final taskStart = DateTime(
        t.executionDate.year,
        t.executionDate.month,
        t.executionDate.day,
        sh,
        sm,
      );
      // 判定: start がブロック区間内に入っている（start <= taskStart < end）
      if (taskStart.isBefore(start) || !taskStart.isBefore(end)) {
        continue;
      }

      // modeId はブロックに合わせる（既存リンク処理と同様）
      final updated = t.copyWith(
        blockId: (blk.cloudId != null && blk.cloudId!.isNotEmpty)
            ? blk.cloudId!
            : blk.id,
        isSomeday: false,
        modeId: (blk.modeId != null && blk.modeId!.isNotEmpty) ? blk.modeId : t.modeId,
      );

      await _ensureInboxMetadata(updated, t);
      await InboxTaskService.updateInboxTask(updated);
      // 即時同期（更新）
      unawaited(TaskSyncManager.syncInboxTaskImmediately(updated, 'update'));

      // メモリ上も更新（同一フレーム内の後続処理の整合用）
      try {
        final idx = _inboxTasks.indexWhere((x) => x.id == updated.id);
        if (idx != -1) {
          final list = List<inbox.InboxTask>.from(_inboxTasks);
          list[idx] = updated;
          _inboxTasks = list;
        }
      } catch (_) {}

      linked++;
    }

    if (linked > 0) {
      await refreshTasks(showLoading: false);
    }
    return linked;
  }

  /// 指定区間 [rangeStartLocal, rangeEndExclusiveLocal) に開始する
  /// 「未リンク（blockIdなし）の時間ありインボックスタスク」のID一覧を返す（副作用なし）。
  List<String> collectUnassignedTimedInboxTaskIdsStartingInRange({
    required DateTime rangeStartLocal,
    required DateTime rangeEndExclusiveLocal,
  }) {
    DateTime start = rangeStartLocal;
    DateTime end = rangeEndExclusiveLocal;
    if (!start.isBefore(end)) {
      end = start.add(const Duration(minutes: 1));
    }

    bool sameDay(DateTime a, DateTime b) =>
        a.year == b.year && a.month == b.month && a.day == b.day;

    final ids = <String>[];
    for (final t in _inboxTasks) {
      if (t.isDeleted == true) continue;
      if (t.isCompleted == true) continue;
      if (t.isSomeday == true) continue;
      if (t.blockId != null && t.blockId!.isNotEmpty) continue;
      final sh = t.startHour;
      final sm = t.startMinute;
      if (sh == null || sm == null) continue;
      if (!sameDay(t.executionDate, start)) continue;

      final taskStart = DateTime(
        t.executionDate.year,
        t.executionDate.month,
        t.executionDate.day,
        sh,
        sm,
      );
      if (taskStart.isBefore(start) || !taskStart.isBefore(end)) continue;
      ids.add(t.id);
    }
    return ids;
  }

  /// 既存インボックスタスク（指定ID）へ、開始時刻を維持したまま blockId を付与して紐づける。
  /// 戻り値: 実際に更新した件数
  Future<int> linkInboxTaskIdsToBlockPreservingTime({
    required String blockId,
    required List<String> inboxTaskIds,
  }) async {
    final blk = BlockService.getBlockById(blockId);
    if (blk == null) return 0;
    if (inboxTaskIds.isEmpty) return 0;

    int linked = 0;
    for (final id in inboxTaskIds) {
      inbox.InboxTask? existing = InboxTaskService.getInboxTask(id);
      existing ??= (() {
        try {
          return _inboxTasks.firstWhere((t) => t.id == id);
        } catch (_) {
          return null;
        }
      })();
      if (existing == null) continue;
      if (existing.isDeleted == true) continue;
      if (existing.isCompleted == true) continue;
      if (existing.isSomeday == true) continue;

      // 既にリンクされていたらスキップ（race対策）
      if (existing.blockId != null && existing.blockId!.isNotEmpty) continue;

      final updated = existing.copyWith(
        blockId: (blk.cloudId != null && blk.cloudId!.isNotEmpty)
            ? blk.cloudId!
            : blk.id,
        isSomeday: false,
        modeId: (blk.modeId != null && blk.modeId!.isNotEmpty)
            ? blk.modeId
            : existing.modeId,
      );

      await _ensureInboxMetadata(updated, existing);
      await InboxTaskService.updateInboxTask(updated);
      unawaited(TaskSyncManager.syncInboxTaskImmediately(updated, 'update'));

      // メモリ上も更新
      try {
        final idx = _inboxTasks.indexWhere((x) => x.id == updated.id);
        if (idx != -1) {
          final list = List<inbox.InboxTask>.from(_inboxTasks);
          list[idx] = updated;
          _inboxTasks = list;
        }
      } catch (_) {}

      linked++;
    }

    if (linked > 0) {
      await refreshTasks(showLoading: false);
    }
    return linked;
  }

  // 任意の時間窓 [windowStart, windowEndExclusive) に、推定作業時間が入る最初のギャップへ配置する。
  // null の場合は「どうしても収められない」ことを意味する（呼び出し側でフォールバックする）。
  inbox.InboxTask? _scheduleInboxInsideWindow(
    inbox.InboxTask task,
    DateTime windowStart,
    DateTime windowEndExclusive,
  ) {
    // 正規化: windowStart はローカル日時のまま、executionDate は日付として保存する
    final DateTime dateOnly =
        DateTime(windowStart.year, windowStart.month, windowStart.day);
    final DateTime start = windowStart;
    final DateTime end = windowEndExclusive;

    if (!start.isBefore(end)) return null;

    // 0分タスクでも「開始時刻を付ける」ため、ここでは 1分として扱う（表示上は estimatedDuration を維持）
    final int durationForFit = task.estimatedDuration > 0 ? task.estimatedDuration : 1;

    // 1) 同日・時間ありのInbox（未完了）を占有として扱う（リンク有無は不問）
    final assigned = _inboxTasks
        .where((t) =>
            t.id != task.id &&
            t.isCompleted != true &&
            t.isDeleted != true &&
            t.executionDate.year == dateOnly.year &&
            t.executionDate.month == dateOnly.month &&
            t.executionDate.day == dateOnly.day &&
            t.startHour != null &&
            t.startMinute != null)
        .map((t) {
          final tStart = DateTime(
              dateOnly.year, dateOnly.month, dateOnly.day, t.startHour!, t.startMinute!);
          final tEnd = tStart.add(Duration(minutes: t.estimatedDuration));
          final s = tStart.isAfter(start) ? tStart : start;
          final e = tEnd.isBefore(end) ? tEnd : end;
          return [s, e];
        })
        .where((iv) => iv[0].isBefore(iv[1]))
        .toList();

    // 2) 実績を占有化（リンク有無は不問、時間窓と重なる範囲）
    final actuals = getActualTasksForDate(dateOnly)
        .map((a) {
          final aStart = a.startTime.toLocal();
          final now = DateTime.now();
          final aEnd = (a.endTime ?? now).toLocal();
          final s = aStart.isAfter(start) ? aStart : start;
          final e = aEnd.isBefore(end) ? aEnd : end;
          return [s, e];
        })
        .where((iv) => iv[0].isBefore(iv[1]))
        .toList();

    // 3) 占有リスト結合＋正規化
    final intervals = <List<DateTime>>[...assigned, ...actuals]
      ..sort((a, b) => a[0].compareTo(b[0]));
    final merged = <List<DateTime>>[];
    for (final iv in intervals) {
      if (merged.isEmpty) {
        merged.add(iv);
      } else {
        final last = merged.last;
        if (iv[0].isAfter(last[1])) {
          merged.add(iv);
        } else {
          if (iv[1].isAfter(last[1])) last[1] = iv[1];
        }
      }
    }

    // 4) ギャップ探索（最初に入る場所）: 過去に置かないため now 以降から探索
    final now = DateTime.now();
    final DateTime searchStart = now.isAfter(start) ? now : start;
    if (!searchStart.isBefore(end)) {
      // 窓が既に終了している場合: 終端寄せで開始時刻だけは必ず付与
      DateTime s = end.subtract(Duration(minutes: durationForFit));
      if (s.isBefore(start)) s = start;
      return task.copyWith(
        executionDate: dateOnly,
        startHour: s.hour,
        startMinute: s.minute,
      );
    }

    DateTime cursor = searchStart;
    for (final iv in merged) {
      if (!iv[1].isAfter(cursor)) {
        continue;
      }
      final gapStart = cursor;
      final gapEnd = iv[0].isBefore(end) ? iv[0] : end;
      final gapMinutes = gapEnd.difference(gapStart).inMinutes;
      if (gapMinutes >= durationForFit) {
        final s = gapStart;
        return task.copyWith(
          executionDate: dateOnly,
          startHour: s.hour,
          startMinute: s.minute,
        );
      }
      if (iv[1].isAfter(cursor)) cursor = iv[1];
      if (!cursor.isBefore(end)) break;
    }

    // 5) ギャップ無し: 終端寄せ（重なり許容）で開始時刻だけは必ず付与
    DateTime s = end.subtract(Duration(minutes: durationForFit));
    if (s.isBefore(searchStart)) s = searchStart;
    if (s.isBefore(start)) s = start;
    if (!s.isBefore(end)) {
      return null;
    }
    return task.copyWith(
      executionDate: dateOnly,
      startHour: s.hour,
      startMinute: s.minute,
    );
  }

  // ブロックのタイトルをインボックスタスクのタイトルに更新（primaryリンクのみ）
  Future<void> _updateLinkedBlockTitleIfPrimary(
      String blockId, String inboxTaskId, String newTitle) async {
    try {
      final block = BlockService.getBlockById(blockId);
      if (block != null) {
        final isPrimary = (block.taskId != null &&
            block.taskId!.isNotEmpty &&
            block.taskId == inboxTaskId);
        if (!isPrimary) {
          // 1:N割当ではブロック名をタスク名へ寄せない
          return;
        }
        if (block.title != newTitle) {
          block.title = newTitle;
          await BlockSyncService().updateBlockWithSync(block);
        }
      }
    } catch (e) {
      rethrow;
    }
  }

  // データ整合性チェック・修復機能
  Future<void> checkAndCleanData() async {
    // 1. 重複ブロックの検出
    final duplicateGroups = <String, List<Block>>{};
    for (final block in _blocks) {
      final key =
          '${block.title}_${block.blockName}_${block.executionDate}_${block.startHour}_${block.startMinute}';
      duplicateGroups.putIfAbsent(key, () => []).add(block);
    }

    final duplicates = duplicateGroups.entries
        .where((entry) => entry.value.length > 1)
        .toList();

    // 2. 空のタイトル・ブロック名の検出
    final emptyTitleBlocks =
        _blocks.where((block) => block.title.isEmpty).toList();
    final emptyBlockNameBlocks =
        _blocks.where((block) => (block.blockName ?? '').isEmpty).toList();

    // 3. 未来すぎる日付の検出（1年以上先）
    final now = DateTime.now();
    final futureThreshold = now.add(const Duration(days: 365));
    final futureDateBlocks = _blocks
        .where((block) => block.executionDate.isAfter(futureThreshold))
        .toList();

    // 4. 統計情報（変数は将来のログ/UI用に保持）
    if (_blocks.isNotEmpty) {
      final dateRange = _blocks.map((b) => b.executionDate).toList()..sort();
      final earliestDate = dateRange.first;
      final latestDate = dateRange.last;
      final uniqueDates = _blocks
          .map((b) =>
              '${b.executionDate.year}-${b.executionDate.month.toString().padLeft(2, '0')}-${b.executionDate.day.toString().padLeft(2, '0')}')
          .toSet();
      // duplicates, emptyTitleBlocks, emptyBlockNameBlocks, futureDateBlocks, earliestDate, latestDate, uniqueDates
    }
  }

  // 重複データの自動削除（最新のcloudIdを持つものを残す）
  Future<void> removeDuplicateBlocks() async {
    final duplicateGroups = <String, List<Block>>{};
    for (final block in _blocks) {
      final key =
          '${block.title}_${block.blockName}_${block.executionDate}_${block.startHour}_${block.startMinute}';
      duplicateGroups.putIfAbsent(key, () => []).add(block);
    }

    int removedCount = 0;
    for (final entry in duplicateGroups.entries) {
      if (entry.value.length > 1) {
        // 最新のlastModifiedを持つブロックを残す
        entry.value.sort((a, b) => b.lastModified.compareTo(a.lastModified));
        final toRemove = entry.value.skip(1).toList();

        for (final duplicate in toRemove) {
          try {
            await deleteBlock(duplicate.id);
            removedCount++;
          } catch (e) {
            // skip failed removal
          }
        }
      }
    }

    if (removedCount > 0) {
      await refreshTasks();
    }
  }

  void _setLoading(bool loading) {
    if (_isLoading != loading) {
      _isLoading = loading;
      // 状態変更の通知もバッチング
      _scheduleNotify();
    }
  }

  void startWatchingRunningTasks(
      {required DateTime fromInclusive, required DateTime toExclusive}) {
    try {
      if (!_isAppInForeground) {
        return;
      }

      _actualTaskWatchSub?.cancel();
      _allRunningWatchSub?.cancel();
      _runningTaskPollingTimer?.cancel();
      _runningTaskPollingTimer = null;

      final service = ActualTaskSyncService();

      // read削減（G-18）:
      // - 監視は「実行中のみ」に限定（初回スナップショット上限=20）
      // - ただし、他端末で paused/completed になった場合は監視対象から外れるため、
      //   ローカルで「まだ実行中」と見えている分については必要最小限のdoc GETで補完確認する。
      _actualTaskWatchSub = service
          .watchRunningTasksByDateRange(fromInclusive, toExclusive)
          .listen((remoteTasks) async {
        try {
          final remoteKeys = <String>{};
          // ローカル保存で整合（古いリモートでローカルを巻き戻さない）
          for (final remote in remoteTasks) {
            if (remote.isDeleted == true) continue;
            final k = (remote.cloudId != null && remote.cloudId!.isNotEmpty)
                ? remote.cloudId!
                : remote.id;
            if (k.isNotEmpty) remoteKeys.add(k);
            final local = ActualTaskService.getActualTask(remote.id);
            final shouldApply = () {
              if (local == null) return true;
              return remote.lastModified.isAfter(local.lastModified);
            }();
            if (shouldApply) {
              await ActualTaskService.updateActualTask(remote);
            }
          }

          // 監視対象から外れた（= running ではなくなった）可能性のあるローカル実行中タスクを補完確認
          // 想定: running は通常1件程度。ここでのdoc GETは最大でも少数に抑える。
          final now = DateTime.now();
          final localRunning = runningActualTasks;
          for (final t in localRunning) {
            final key = (t.cloudId != null && t.cloudId!.isNotEmpty)
                ? t.cloudId!
                : t.id;
            if (key.isEmpty) continue;
            if (remoteKeys.contains(key)) continue;
            final lastProbe = _runningMissingProbeAt[key];
            if (lastProbe != null &&
                now.difference(lastProbe) < const Duration(seconds: 10)) {
              continue;
            }
            _runningMissingProbeAt[key] = now;
            try {
              final snap = await service.userCollection
                  .doc(key)
                  .get(const GetOptions(source: Source.server))
                  .timeout(const Duration(seconds: 6));
              if (!snap.exists) {
                continue; // 非存在は削除根拠にしない（G-15）
              }
              final raw = snap.data();
              if (raw is! Map<String, dynamic>) continue;
              final data = Map<String, dynamic>.from(raw);
              data['cloudId'] = snap.id;
              final fetched = service.createFromCloudJson(data);
              // fetched が running 以外ならローカルへ反映してバーを止める
              if (!fetched.isRunning || fetched.isPaused || fetched.isCompleted) {
                await ActualTaskService.updateActualTask(fetched);
              }
            } catch (_) {}
          }

          await refreshTasks();
        } catch (_) {}
      });
    } catch (_) {}
  }

  void stopWatchingRunningTasks() {
    _actualTaskWatchSub?.cancel();
    _actualTaskWatchSub = null;
    _allRunningWatchSub?.cancel();
    _allRunningWatchSub = null;
    _runningTaskPollingTimer?.cancel();
    _runningTaskPollingTimer = null;
  }
}
