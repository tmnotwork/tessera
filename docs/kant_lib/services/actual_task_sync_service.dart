import 'dart:async';
import '../models/actual_task.dart';
import '../models/syncable_model.dart';
import 'data_sync_service.dart';
import 'actual_task_service.dart';
import 'device_info_service.dart';
import 'auth_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'task_sync_manager.dart';
import 'app_settings_service.dart';
import 'sync_kpi.dart';

/// ActualTask同期サービス
class ActualTaskSyncService extends DataSyncService<ActualTask> {
  static final ActualTaskSyncService _instance =
      ActualTaskSyncService._internal();
  factory ActualTaskSyncService() => _instance;
  ActualTaskSyncService._internal() : super('actual_tasks');

  @override
  String? get diffCursorKey => AppSettingsService.keyCursorActual;

  @override
  ActualTask createFromCloudJson(Map<String, dynamic> json) {
    // Normalize date fields to ISO8601 strings to prevent FormatException
    DateTime? toDateTime(dynamic v) {
      if (v == null) return null;
      if (v is DateTime) return v;
      if (v is Timestamp) return v.toDate();
      if (v is int) {
        // Heuristic: treat >= 1e12 as ms, >= 1e9 as seconds
        if (v >= 1000000000000) return DateTime.fromMillisecondsSinceEpoch(v);
        if (v >= 1000000000)
          return DateTime.fromMillisecondsSinceEpoch(v * 1000);
        return null;
      }
      if (v is String) {
        return DateTime.tryParse(v);
      }
      return null;
    }

    final normalized = Map<String, dynamic>.from(json);
    final startTime = toDateTime(normalized['startTime']) ?? DateTime.now();
    final createdAt = toDateTime(normalized['createdAt']) ?? startTime;
    final lastModified = toDateTime(normalized['lastModified']);
    final endTime = toDateTime(normalized['endTime']);
    final dueDate = toDateTime(normalized['dueDate']);
    final lastSynced = toDateTime(normalized['lastSynced']);

    normalized['startTime'] = startTime.toIso8601String();
    normalized['createdAt'] = createdAt.toIso8601String();
    if (lastModified != null) {
      normalized['lastModified'] = lastModified.toIso8601String();
    }
    if (endTime != null) {
      normalized['endTime'] = endTime.toIso8601String();
    }
    if (dueDate != null) {
      normalized['dueDate'] = dueDate.toIso8601String();
    }
    if (lastSynced != null) {
      normalized['lastSynced'] = lastSynced.toIso8601String();
    }

    return ActualTask.fromJson(normalized);
  }

  int _statusRank(int statusIndex) {
    // Define progression: running(0) < paused(2) < completed(1)
    // Stored indices: running=0, completed=1, paused=2
    switch (statusIndex) {
      case 0:
        return 0; // running
      case 2:
        return 1; // paused
      case 1:
        return 2; // completed
      default:
        return 0;
    }
  }

  @override
  Future<void> uploadToFirebase(ActualTask item) async {
    await uploadToFirebaseWithOutcome(item);
  }

  /// アップロード結果を返す版（status優先・巻き戻し防止）
  @override
  Future<UploadResult<ActualTask>> uploadToFirebaseWithOutcome(
      ActualTask item,
      {bool skipPreflight = false}) async {
    // Guard against rollback by consulting remote before write
    try {
      final String? key = (item.cloudId != null && item.cloudId!.isNotEmpty)
          ? item.cloudId
          : item.id;
      if (key != null && key.isNotEmpty) {
        final doc = await userCollection
            .doc(key)
            .get(const GetOptions(source: Source.server))
            .timeout(const Duration(seconds: 10));
        if (doc.exists) {
          final data = doc.data() as Map<String, dynamic>;
          final bool remoteDeleted = (data['isDeleted'] ?? false) == true;
          if (remoteDeleted) {
            // Tombstone をローカルにも反映
            try {
              final adopted =
                  createFromCloudJson({...data, 'cloudId': doc.id});
              adopted.markAsSynced();
              await ActualTaskService.updateActualTaskPreservingLastModified(
                  adopted);
              item.cloudId ??= doc.id;
              return UploadResult<ActualTask>(
                outcome: UploadOutcome.skippedRemoteDeleted,
                cloudId: doc.id,
                adoptedRemote: adopted,
                localApplied: true,
                reason: 'remoteDeleted',
              );
            } catch (_) {
              return UploadResult<ActualTask>(
                outcome: UploadOutcome.skippedRemoteDeleted,
                cloudId: doc.id,
                localApplied: false,
                reason: 'remoteDeleted',
              );
            }
          }
          // Compare lastModified, version, and status progression
          DateTime? remoteLm;
          final lmRaw = data['lastModified'];
          if (lmRaw is String) {
            remoteLm = DateTime.tryParse(lmRaw);
          } else if (lmRaw is Timestamp) {
            remoteLm = lmRaw.toDate();
          }
          int? remoteVer;
          try {
            final v = data['version'];
            if (v is int) remoteVer = v;
            if (v is String) remoteVer = int.tryParse(v);
          } catch (_) {
            remoteVer = null;
          }
          final int remoteStatus =
              (data['status'] is int) ? (data['status'] as int) : 0;
          final int localStatus = item.status.index;
          final bool remoteIsNewer =
              remoteLm != null && remoteLm.isAfter(item.lastModified);
          final int remoteRank = _statusRank(remoteStatus);
          final int localRank = _statusRank(localStatus);
          final bool localAhead = localRank > remoteRank;
          final bool remoteAhead = remoteRank > localRank;
          final bool remoteWinsByVersion =
              remoteVer != null && remoteVer > item.version;

          final bool localIsNewer =
              remoteLm != null && item.lastModified.isAfter(remoteLm);
          if (remoteWinsByVersion ||
              (remoteAhead && !localIsNewer) ||
              (remoteIsNewer && !localAhead)) {
            // Adopt remote to local to avoid rollback
            try {
              final merged = createFromCloudJson({...data, 'cloudId': doc.id});
              merged.markAsSynced();
              await ActualTaskService.updateActualTaskPreservingLastModified(
                  merged);
              item.cloudId ??= doc.id;
              return UploadResult<ActualTask>(
                outcome: UploadOutcome.skippedRemoteNewerAdopted,
                cloudId: doc.id,
                adoptedRemote: merged,
                localApplied: true,
                reason: 'remoteAhead',
              );
            } catch (_) {
              return UploadResult<ActualTask>(
                outcome: UploadOutcome.skippedRemoteNewerAdopted,
                cloudId: doc.id,
                localApplied: false,
                reason: 'remoteAhead',
              );
            }
          }
        }
      }
    } catch (_) {}

    // Fallback to default upload (includes deterministic docId via super)
    final result =
        await super.uploadToFirebaseWithOutcome(item, skipPreflight: true);
    if (result.outcome == UploadOutcome.written) {
      // Persist updated cloudId/lastSynced locally WITHOUT changing lastModified
      try {
        await ActualTaskService.updateActualTaskPreservingLastModified(item);
      } catch (_) {}
      return result.copyWith(
        cloudId: item.cloudId,
        localApplied: true,
      );
    }
    return result;
  }

  @override
  Future<List<ActualTask>> getLocalItems() async {
    try {
      // cursorSeed（ローカルlastModified由来）を成立させるため、同期前に必ずBoxを開く。
      await ActualTaskService.initialize();
      return ActualTaskService.getAllActualTasks();
    } catch (e) {
      print('❌ Failed to get local actual tasks: $e');
      return [];
    }
  }

  @override
  Future<ActualTask?> getLocalItemByCloudId(String cloudId) async {
    try {
      await ActualTaskService.initialize();
      final tasks = ActualTaskService.getAllActualTasks();
      return tasks.where((t) => t.cloudId == cloudId).firstOrNull;
    } catch (e) {
      print('❌ Failed to get local actual task by cloudId: $e');
      return null;
    }
  }

  @override
  Future<void> saveToLocal(ActualTask task) async {
    try {
      // 既存のタスクを確認
      final existingTask = await getLocalItemByCloudId(task.cloudId!);

      if (existingTask != null) {
        // 既存タスクを更新
        existingTask.fromCloudJson(task.toCloudJson());
        // リモート反映で lastModified をローカル時刻に上げると、
        // 次回同期で差分が無限に増える（read爆発）ため保持する。
        await ActualTaskService.updateActualTaskPreservingLastModified(existingTask);
      } else {
        // 新規タスクを作成
        await ActualTaskService.addActualTask(task);
      }

      // print('✅ Saved actual task locally: ${task.title}'); // ログを無効化
    } catch (e) {
      print('❌ Failed to save actual task locally: $e');
      rethrow;
    }
  }

  @override
  Future<ActualTask> handleManualConflict(
      ActualTask local, ActualTask remote) async {
    // ActualTaskでは基本的に両方のレコードを保持する戦略

    // 異なる端末からの記録の場合は両方保持
    if (local.deviceId != remote.deviceId) {
      // リモートタスクに新しいIDを割り当てて両方保存
      final remoteTaskCopy = ActualTask.fromJson(remote.toCloudJson());
      remoteTaskCopy.id = '${remote.id}_${remote.deviceId}';
      remoteTaskCopy.cloudId = null; // 新しいcloudIdが割り当てられる

      await saveToLocal(remoteTaskCopy);
      return local; // ローカルタスクをそのまま返す
    }

    // 同じ端末からの場合は最新を採用
    if (remote.lastModified.isAfter(local.lastModified)) {
      await saveToLocal(remote);
      return remote;
    } else {
      return local;
    }
  }

  /// Device-Based-Append競合解決
  @override
  Future<ActualTask> resolveConflict(
      ActualTask local, ActualTask remote) async {
    // 異なる端末からの記録は両方保持する戦略
    if (local.deviceId != remote.deviceId) {
      // 両方のタスクを保存（リモートタスクは新しいIDで）
      final remoteTaskCopy = ActualTask.fromJson(remote.toCloudJson());
      remoteTaskCopy.id = '${remote.id}_device_${remote.deviceId}';
      remoteTaskCopy.cloudId = null;

      // リモートタスクを別レコードとして保存
      await uploadToFirebase(remoteTaskCopy);
      await saveToLocal(remoteTaskCopy);

      return local; // ローカルタスクをそのまま返す
    }

    // 状態優先（completed > paused > running）、次に lastModified
    int rank(ActualTaskStatus s) {
      switch (s) {
        case ActualTaskStatus.running:
          return 0;
        case ActualTaskStatus.paused:
          return 1;
        case ActualTaskStatus.completed:
          return 2;
      }
    }

    if (rank(remote.status) > rank(local.status)) {
      await saveToLocal(remote);
      return remote;
    }
    if (rank(remote.status) < rank(local.status)) {
      await uploadToFirebase(local);
      return local;
    }

    // 同ランクなら LWW
    return await super.resolveConflict(local, remote);
  }

  /// タスク作成時の同期対応
  Future<ActualTask> createTaskWithSync({
    required String title,
    String? projectId,
    DateTime? dueDate,
    String? memo,
    String? blockId,
    String? subProjectId,
    String? subProject,
    String? modeId,
    String? blockName,
  }) async {
    try {
      final deviceId = await DeviceInfoService.getDeviceId();
      final userId = AuthService.getCurrentUserId() ?? '';

      // ローカルでタスク作成
      final task = ActualTask(
        id: 'task_${DateTime.now().millisecondsSinceEpoch}_${DateTime.now().microsecond}',
        title: title,
        status: ActualTaskStatus.running,
        projectId: projectId,
        dueDate: dueDate,
        startTime: DateTime.now(),
        actualDuration: 0,
        memo: memo,
        createdAt: DateTime.now(),
        lastModified: DateTime.now(),
        userId: userId,
        blockId: blockId,
        subProjectId: subProjectId,
        subProject: subProject,
        modeId: modeId,
        blockName: blockName,
        deviceId: deviceId,
        version: 1,
      );

      // ローカル保存
      await ActualTaskService.addActualTask(task);

      // Firebase同期（ネットワークがあれば）
      try {
        await uploadToFirebase(task);
      } catch (e) {
        print('⚠️ Failed to sync new task to Firebase: $e');
      }

      return task;
    } catch (e) {
      print('❌ Failed to create task with sync: $e');
      rethrow;
    }
  }

  /// 0分の実績タスクを「完了」で直接作成（Runningバーを出さない）
  Future<ActualTask> createCompletedZeroTaskWithSync({
    required String title,
    String? projectId,
    DateTime? dueDate,
    String? memo,
    String? blockId,
    String? subProjectId,
    String? subProject,
    String? modeId,
    String? blockName,
    DateTime? startTime,
    DateTime? endTime,
    String? sourceInboxTaskId,
  }) async {
    try {
      final deviceId = await DeviceInfoService.getDeviceId();
      final userId = AuthService.getCurrentUserId() ?? '';

      final now = DateTime.now();
      final start = startTime ?? now;
      final end = endTime ?? start;
      final task = ActualTask(
        id: 'task_${now.millisecondsSinceEpoch}_${now.microsecond}',
        title: title,
        status: ActualTaskStatus.completed,
        projectId: projectId,
        dueDate: dueDate,
        startTime: start,
        endTime: end,
        actualDuration: 0,
        memo: memo,
        createdAt: start,
        lastModified: start,
        userId: userId,
        blockId: blockId,
        subProjectId: subProjectId,
        subProject: subProject,
        modeId: modeId,
        blockName: blockName,
        sourceInboxTaskId: sourceInboxTaskId,
        deviceId: deviceId,
        version: 1,
      );

      await ActualTaskService.addActualTask(task);
      try {
        await uploadToFirebase(task);
      } catch (e) {
        print('⚠️ Failed to sync completed zero task to Firebase: $e');
      }
      return task;
    } catch (e) {
      print('❌ Failed to create completed zero task with sync: $e');
      rethrow;
    }
  }

  /// 指定した開始・終了時刻で「完了」実績タスクを1件作成（ポモドーロ等で使用）
  Future<ActualTask> createCompletedTaskWithSync({
    required DateTime startTime,
    required DateTime endTime,
    required String title,
    String? projectId,
    DateTime? dueDate,
    String? memo,
    String? blockId,
    String? subProjectId,
    String? subProject,
    String? modeId,
    String? blockName,
    String? sourceInboxTaskId,
    String? location,
  }) async {
    try {
      final deviceId = await DeviceInfoService.getDeviceId();
      final userId = AuthService.getCurrentUserId() ?? '';
      final start = startTime.isBefore(endTime) ? startTime : endTime;
      final end = endTime.isAfter(startTime) ? endTime : startTime;
      final durationMinutes = end.difference(start).inMinutes;
      final now = DateTime.now();

      final task = ActualTask(
        id: 'task_${now.millisecondsSinceEpoch}_${now.microsecond}',
        title: title,
        status: ActualTaskStatus.completed,
        projectId: projectId,
        dueDate: dueDate,
        startTime: start,
        endTime: end,
        actualDuration: durationMinutes,
        memo: memo,
        createdAt: start,
        lastModified: now,
        userId: userId,
        blockId: blockId,
        subProjectId: subProjectId,
        subProject: subProject,
        modeId: modeId,
        blockName: blockName,
        sourceInboxTaskId: sourceInboxTaskId,
        location: location,
        deviceId: deviceId,
        version: 1,
      );

      await ActualTaskService.addActualTask(task);
      try {
        await uploadToFirebase(task);
      } catch (e) {
        print('⚠️ Failed to sync completed task to Firebase: $e');
      }
      return task;
    } catch (e) {
      print('❌ Failed to create completed task with sync: $e');
      rethrow;
    }
  }

  // ショートカット（RoutineTask）から即時に実績タスクを開始
  Future<ActualTask> startFromShortcut({
    required String title,
    String? projectId,
    String? memo,
    String? subProjectId,
    String? subProject,
    String? modeId,
    String? blockName,
  }) async {
    // 実績タスクを running で作成
    final task = await createTaskWithSync(
      title: title,
      projectId: projectId,
      memo: memo,
      subProjectId: subProjectId,
      subProject: subProject,
      modeId: modeId,
      blockName: blockName,
    );
    return task;
  }

  /// タスク更新時の同期対応
  Future<void> updateTaskWithSync(ActualTask task) async {
    try {
      final deviceId = await DeviceInfoService.getDeviceId();

      // 同期メタデータを更新
      task.markAsModified(deviceId);

      // ローカル更新
      await ActualTaskService.updateActualTask(task);

      // Firebase同期（ネットワークがあれば）
      try {
        await uploadToFirebase(task);
      } catch (e) {
        print('⚠️ Failed to sync updated task to Firebase: $e');
      }
    } catch (e) {
      print('❌ Failed to update task with sync: $e');
      rethrow;
    }
  }

  /// タスク削除時の同期対応
  Future<void> deleteTaskWithSync(String taskId) async {
    try {
      final tasks = ActualTaskService.getAllActualTasks();
      final task = tasks.where((t) => t.id == taskId).firstOrNull;
      if (task == null) return;

      final deviceId = await DeviceInfoService.getDeviceId();

      // ローカルは tombstone で即時非表示（復活防止）
      task.isDeleted = true;
      task.markAsModified(deviceId);
      await ActualTaskService.updateActualTask(task);

      // 即時同期（オフライン時はキューへ）
      unawaited(TaskSyncManager.syncActualTaskImmediately(task, 'delete'));
    } catch (e) {
      print('❌ Failed to delete task with sync: $e');
      rethrow;
    }
  }

  /// リモートに論理削除を保証（cloudId/id/検索の順で試行）
  Future<void> ensureRemoteLogicalDelete(ActualTask task) async {
    final docRef = userCollection;
    // 1) cloudId
    if (task.cloudId != null && task.cloudId!.isNotEmpty) {
      try {
        await deleteFromFirebase(task.cloudId!);
        return;
      } catch (_) {}
    }
    // 2) id を docId として
    try {
      await deleteFromFirebase(task.id);
      return;
    } catch (_) {}
    // 3) フィールド検索で docId を特定
    try {
      final snap = await docRef
          .where('id', isEqualTo: task.id)
          .limit(5)
          .get(const GetOptions(source: Source.server));
      if (snap.docs.isEmpty) return;
      for (final d in snap.docs) {
        try {
          await deleteFromFirebase(d.id);
        } catch (_) {}
      }
    } catch (_) {}
  }

  // Removed in Phase 8: use dayKeys-based sync only.

  static String _dayKey(DateTime date) {
    final d = DateTime(date.year, date.month, date.day);
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }

  /// monthKey での実績同期（レポート用）
  /// [monthKey]: 'YYYY-MM' 形式の文字列（例: '2025-01'）
  Future<SyncResult> syncTasksByMonthKey(String monthKey) async {
    try {
      final remoteTasks = <ActualTask>[];
      final remoteCloudIds = <String>{};

      // 1) monthKeys でクエリ
      final sw = Stopwatch()..start();
      final snap = await userCollection
          .where('monthKeys', arrayContains: monthKey)
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 30));
      try {
        SyncKpi.queryReads += snap.docs.length;
      } catch (_) {}

      for (final doc in snap.docs) {
        try {
          final data = doc.data() as Map<String, dynamic>;
          data['cloudId'] = doc.id;
          remoteCloudIds.add(doc.id);
          remoteTasks.add(createFromCloudJson(data));
        } catch (_) {}
      }

      // 2) running は別取得（件数が少ない想定）
      try {
        final runningIndex = ActualTaskStatus.running.index;
        final snap = await userCollection
            .where('isDeleted', isEqualTo: false)
            .where('status', isEqualTo: runningIndex)
            .get(const GetOptions(source: Source.server))
            .timeout(const Duration(seconds: 15));
        try {
          SyncKpi.queryReads += snap.docs.length;
        } catch (_) {}
        for (final doc in snap.docs) {
          try {
            final data = doc.data() as Map<String, dynamic>;
            data['cloudId'] = doc.id;
            remoteCloudIds.add(doc.id);
            remoteTasks.add(createFromCloudJson(data));
          } catch (_) {}
        }
      } catch (_) {}

      // dedupe（cloudId優先）
      final byKey = <String, ActualTask>{};
      for (final t in remoteTasks) {
        final key =
            (t.cloudId != null && t.cloudId!.isNotEmpty) ? t.cloudId! : t.id;
        final existing = byKey[key];
        if (existing == null) {
          byKey[key] = t;
        } else {
          if (t.lastModified.isAfter(existing.lastModified)) {
            byKey[key] = t;
          }
        }
      }

      // isDeleted=true の tombstone をローカルに削除反映
      int deleted = 0;
      for (final remote in byKey.values) {
        if (remote.isDeleted == true) {
          try {
            final local = await getLocalItemByCloudId(remote.cloudId!);
            if (local != null) {
              await ActualTaskService.deleteActualTask(local.id);
              deleted++;
            }
          } catch (_) {}
        }
      }

      int applied = 0;
      for (final remote in byKey.values) {
        if (remote.isDeleted == true) continue;
        try {
          ActualTask? local;
          try {
            if (remote.cloudId != null && remote.cloudId!.isNotEmpty) {
              local = await getLocalItemByCloudId(remote.cloudId!);
            }
          } catch (_) {}
          local ??= ActualTaskService.getActualTask(remote.id);

          final shouldApply = () {
            if (local == null) return true;
            return remote.lastModified.isAfter(local.lastModified);
          }();
          if (shouldApply) {
            await ActualTaskService.updateActualTask(remote);
            applied++;
          }
        } catch (_) {}
      }

      // ローカルに存在するがサーバー結果に無い cloudId は whereIn で確認し、削除/移動を反映
      try {
        final parts = monthKey.split('-');
        if (parts.length == 2) {
          final year = int.tryParse(parts[0]);
          final month = int.tryParse(parts[1]);
          if (year != null && month != null) {
            final monthStartUtc = DateTime.utc(year, month, 1);
            final monthEndUtc = DateTime.utc(year, month + 1, 1);
            
            final locals = ActualTaskService.getAllActualTasks();
            final candidates = locals
                .where((t) => t.isDeleted != true)
                .where((t) {
                  final keys = t.monthKeys;
                  if (keys != null && keys.contains(monthKey)) return true;
                  // フォールバック: startAt で範囲チェック
                  final start = t.startAt ?? t.startTime.toUtc();
                  return !start.isBefore(monthStartUtc) && start.isBefore(monthEndUtc);
                })
                .toList();
            
            final missingCloudIds = <String>[];
            for (final t in candidates) {
              final cid = t.cloudId;
              if (cid == null || cid.isEmpty) continue;
              if (!remoteCloudIds.contains(cid)) {
                missingCloudIds.add(cid);
              }
            }

            const whereInMax = 10;
            for (int i = 0; i < missingCloudIds.length; i += whereInMax) {
              final chunk = missingCloudIds.sublist(
                i,
                (i + whereInMax) > missingCloudIds.length ? missingCloudIds.length : (i + whereInMax),
              );
              try {
                final extraSnap = await userCollection
                    .where(FieldPath.documentId, whereIn: chunk)
                    .get(const GetOptions(source: Source.server))
                    .timeout(const Duration(seconds: 15));
                try {
                  SyncKpi.queryReads += extraSnap.docs.length;
                } catch (_) {}
                
                final returnedIds = <String>{};
                for (final doc in extraSnap.docs) {
                  returnedIds.add(doc.id);
                  try {
                    final data = doc.data() as Map<String, dynamic>;
                    data['cloudId'] = doc.id;
                    final remote = createFromCloudJson(data);
                    final local = await getLocalItemByCloudId(doc.id);
                    if (remote.isDeleted == true) {
                      if (local != null) {
                        await ActualTaskService.deleteActualTask(local.id);
                        deleted++;
                      }
                      continue;
                    }
                    if (local != null) {
                      if (remote.lastModified.isAfter(local.lastModified)) {
                        await ActualTaskService.updateActualTask(remote);
                        applied++;
                      }
                    } else {
                      await ActualTaskService.updateActualTask(remote);
                      applied++;
                    }
                  } catch (_) {}
                }
                
                // Not returned => treat as deleted
                for (final id in chunk) {
                  if (returnedIds.contains(id)) continue;
                  final local = await getLocalItemByCloudId(id);
                  if (local != null) {
                    await ActualTaskService.deleteActualTask(local.id);
                    deleted++;
                  }
                }
              } catch (_) {
                // whereIn 失敗時はスキップ
                continue;
              }
            }
          }
        }
      } catch (e) {
        print('⚠️ Actual monthKey diff deletion failed: $e');
      }

      return SyncResult(
        success: true,
        syncedCount: applied + deleted,
        failedCount: 0,
        conflicts: const [],
      );
    } catch (e) {
      return SyncResult(
        success: false,
        failedCount: 1,
        error: e.toString(),
        conflicts: const [],
      );
    }
  }

  /// dayKey での実績同期（Phase 4）
  /// [skipRunningQuery]: trueの場合、runningタスクの取得をスキップ（レポート同期用）
  Future<SyncResult> syncTasksByDayKey(
    DateTime date, {
    bool skipRunningQuery = false,
  }) async {
    final dayKey = _dayKey(date);
    try {

      final remoteTasks = <ActualTask>[];
      final remoteCloudIds = <String>{};

      // 1) completed/paused 等（dayKeys）
      final sw = Stopwatch()..start();
      final snap = await userCollection
          .where('dayKeys', arrayContains: dayKey)
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 20));
      try {
        SyncKpi.queryReads += snap.docs.length;
      } catch (_) {}
      for (final doc in snap.docs) {
        try {
          final data = doc.data() as Map<String, dynamic>;
          data['cloudId'] = doc.id;
          remoteCloudIds.add(doc.id);
          remoteTasks.add(createFromCloudJson(data));
        } catch (_) {}
      }

      // 2) running は別取得（件数が少ない想定）
      // レポート同期からの呼び出しでは不要なためスキップ可能
      if (!skipRunningQuery) {
        try {
          final runningIndex = ActualTaskStatus.running.index;
          final snap = await userCollection
              .where('isDeleted', isEqualTo: false)
              .where('status', isEqualTo: runningIndex)
              .get(const GetOptions(source: Source.server))
              .timeout(const Duration(seconds: 15));
          try {
            SyncKpi.queryReads += snap.docs.length;
          } catch (_) {}
          for (final doc in snap.docs) {
            try {
              final data = doc.data() as Map<String, dynamic>;
              data['cloudId'] = doc.id;
              remoteCloudIds.add(doc.id);
              remoteTasks.add(createFromCloudJson(data));
            } catch (_) {}
          }
        } catch (_) {}
      }

      // dedupe（cloudId優先）
      final byKey = <String, ActualTask>{};
      for (final t in remoteTasks) {
        final key =
            (t.cloudId != null && t.cloudId!.isNotEmpty) ? t.cloudId! : t.id;
        final existing = byKey[key];
        if (existing == null) {
          byKey[key] = t;
        } else {
          if (t.lastModified.isAfter(existing.lastModified)) {
            byKey[key] = t;
          }
        }
      }

      int applied = 0;
      for (final remote in byKey.values) {
        try {
          // getLocalItemByCloudId は cloudId 前提なので、fallback を考慮して直接検索
          ActualTask? local;
          try {
            if (remote.cloudId != null && remote.cloudId!.isNotEmpty) {
              local = await getLocalItemByCloudId(remote.cloudId!);
            }
          } catch (_) {}
          local ??= ActualTaskService.getActualTask(remote.id);

          final shouldApply = () {
            if (local == null) return true;
            return remote.lastModified.isAfter(local.lastModified);
          }();
          if (shouldApply) {
            await ActualTaskService.updateActualTask(remote);
            applied++;
          }
        } catch (_) {}
      }

      // Phase 8: dayKeys 同期が正なので diff deletion を復帰（移動/短縮で dayKey から外れたものをローカルから外す）
      try {
        final locals = ActualTaskService.getAllActualTasks();
        int deleted = 0;
        for (final t in locals) {
          if (t.isDeleted) continue;
          if (t.isRunning) continue;
          final cid = t.cloudId;
          if (cid == null || cid.isEmpty) continue; // local-onlyは守る
          final keys = t.dayKeys;
          if (keys == null || !keys.contains(dayKey)) continue;
          if (!remoteCloudIds.contains(cid)) {
            await ActualTaskService.deleteActualTask(t.id);
            deleted++;
          }
        }
      } catch (e) {
        print('⚠️ Actual diff deletion failed: $e');
      }

      return SyncResult(
        success: true,
        syncedCount: applied,
        failedCount: 0,
        conflicts: const [],
      );
    } catch (e) {
      return SyncResult(
        success: false,
        failedCount: 1,
        error: e.toString(),
        conflicts: const [],
      );
    }
  }

  /// 差分同期: lastModified >= cursor のタスクのみ適用（当日範囲に限定）
  Future<SyncResult> syncTasksSince(DateTime cursorUtc, DateTime date) async {
    try {
      final from = cursorUtc
          .subtract(const Duration(seconds: 5)); // clock skew tolerance
      final dayStart = DateTime(date.year, date.month, date.day);
      final dayEndExclusive = dayStart.add(const Duration(days: 1));

      QuerySnapshot? querySnapshot;
      try {
        querySnapshot = await userCollection
            .where('isDeleted', isEqualTo: false)
            .where('lastModified',
                isGreaterThanOrEqualTo: from.toIso8601String())
            .get(const GetOptions(source: Source.server));
      } catch (e) {
        // フォールバック: 全件取得→クライアントで lastModified と日付範囲フィルタ
        querySnapshot = await userCollection
            .where('isDeleted', isEqualTo: false)
            .get(const GetOptions(source: Source.server));
      }

      final remoteTasks = <ActualTask>[];
      for (final doc in querySnapshot.docs) {
        try {
          final data = doc.data() as Map<String, dynamic>;
          data['cloudId'] = doc.id;
          final task = createFromCloudJson(data);
          final st = task.startTime;
          final inDay = !st.isBefore(dayStart) && st.isBefore(dayEndExclusive);
          if (inDay) remoteTasks.add(task);
        } catch (_) {}
      }

      int applied = 0;
      for (final remote in remoteTasks) {
        try {
          final local = await getLocalItemByCloudId(remote.cloudId!);
          final shouldApply = () {
            if (local == null) return true;
            return remote.lastModified.isAfter(local.lastModified);
          }();
          if (shouldApply) {
            await ActualTaskService.updateActualTask(remote);
            applied++;
          }
        } catch (_) {}
      }

      return SyncResult(
          success: true,
          syncedCount: applied,
          failedCount: 0,
          conflicts: const []);
    } catch (e) {
      return SyncResult(
          success: false,
          failedCount: 1,
          error: e.toString(),
          conflicts: const []);
    }
  }

  /// すべてのActualTaskを同期
  static Future<SyncResult> syncAllTasks() async {
    try {
      final syncService = ActualTaskSyncService();
      // NOTE:
      // タスク系は outbox / 即時同期（TaskSyncManager）でアップロードする方針。
      // ここ（read目的の全体同期）でローカルneedsSyncを拾って自動アップロードすると
      // 「ユーザー無操作でも書き込みが増える」ため、アップロードPhaseを無効化する。
      final res = await syncService.performSync(uploadLocalChanges: false);
      return res;
    } catch (e) {
      print('❌ Failed to sync all actual tasks: $e');
      return SyncResult(
        success: false,
        error: e.toString(),
        failedCount: 1,
      );
    }
  }

  /// 実行中タスクの同期（リアルタイム更新用）
  Future<void> syncRunningTasks() async {
    try {
      final runningTasks = ActualTaskService.getRunningTasks();

      for (final task in runningTasks) {
        if (task.needsSync) {
          await updateTaskWithSync(task);
        }
      }
    } catch (e) {
      print('❌ Failed to sync running tasks: $e');
    }
  }

  /// 実行中タスクを一度だけサーバーから取得してローカルに反映
  Future<int> syncAllRunningTasksOnce() async {
    try {
      final runningIndex = ActualTaskStatus.running.index;
      final snapshot = await userCollection
          .where('isDeleted', isEqualTo: false)
          .where('status', isEqualTo: runningIndex)
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 15));
      try {
        SyncKpi.queryReads += snapshot.docs.length;
      } catch (_) {}

      int applied = 0;
      for (final doc in snapshot.docs) {
        try {
          final data = doc.data() as Map<String, dynamic>;
          data['cloudId'] = doc.id;
          final remote = createFromCloudJson(data);
          final local = ActualTaskService.getActualTask(remote.id);
          final shouldApply = () {
            if (local == null) return true;
            return remote.lastModified.isAfter(local.lastModified);
          }();
          if (shouldApply) {
            await ActualTaskService.updateActualTask(remote);
            applied++;
          }
        } catch (_) {}
      }
      return applied;
    } catch (e) {
      return 0;
    }
  }

  /// タスクの変更を監視
  Stream<List<ActualTask>> watchTaskChanges() {
    return watchFirebaseChanges();
  }

  /// 実行中タスクを監視（read上限のため「実行中のみ」にスコープ）
  /// - 30秒ポーリングは禁止（計画書G-18）
  /// - 監視対象は「実行中のみ」かつ上限件数を設ける
  /// - 実行中から外れた（paused/completed）場合は、呼び出し側で必要最小限の補完取得を行う
  Stream<List<ActualTask>> watchRunningTasksByDateRange(
      DateTime fromInclusive, DateTime toExclusive) {
    // NOTE: from/to は互換のため引数として残す（将来の監視窓調整用）
    // 現仕様では read を抑えるため「実行中のみ」に限定する。
    final runningIndex = ActualTaskStatus.running.index;
    bool first = true;
    return userCollection
        .where('isDeleted', isEqualTo: false)
        .where('status', isEqualTo: runningIndex)
        .limit(20)
        .snapshots()
        .map((snapshot) {
      try {
        if (first) {
          first = false;
          SyncKpi.watchStarts += 1;
          SyncKpi.watchInitialReads += snapshot.docs.length;
        } else {
          SyncKpi.watchChangeReads += snapshot.docChanges.length;
        }
      } catch (_) {}
      final items = <ActualTask>[];
      for (final doc in snapshot.docs) {
        try {
          final data = doc.data() as Map<String, dynamic>;
          data['cloudId'] = doc.id;
          items.add(createFromCloudJson(data));
        } catch (_) {}
      }
      return items;
    }).handleError((e, st) {
      // 監視エラーを握ってUI継続（ネットワーク一時障害/認証再水和対策）
      try {
        // ignore: avoid_print
        print('⚠️ Firestore watch error: $e');
      } catch (_) {}
    });
  }

  /// 全タスクを監視（日付フィルタなし、すべてのステータス）
  /// クロス端末での状態変更を即座に反映するため、statusフィルタなしで監視
  Stream<List<ActualTask>> watchAllRunningTasks() {
    bool first = true;
    return userCollection
        .where('isDeleted', isEqualTo: false)
        .snapshots()
        .map((snapshot) {
      try {
        if (first) {
          first = false;
          SyncKpi.watchStarts += 1;
          SyncKpi.watchInitialReads += snapshot.docs.length;
        } else {
          SyncKpi.watchChangeReads += snapshot.docChanges.length;
        }
      } catch (_) {}
      final items = <ActualTask>[];
      for (final doc in snapshot.docs) {
        try {
          final data = doc.data() as Map<String, dynamic>;
          data['cloudId'] = doc.id;
          items.add(createFromCloudJson(data));
        } catch (_) {}
      }
      return items;
    }).handleError((e, st) {
      // 監視エラーを握ってUI継続（ネットワーク一時障害/認証再水和対策）
      try {
        // ignore: avoid_print
        print('⚠️ Firestore watch error: $e');
      } catch (_) {}
    });
  }

  /// ローカル実績タスクを削除する（同期処理で使用）
  @override
  Future<void> deleteLocalItem(ActualTask item) async {
    try {
      // ローカルHiveから削除
      await ActualTaskService.deleteActualTask(item.id);
    } catch (e) {
      print('❌ Failed to delete local actual task: ${item.title}, error: $e');
      rethrow;
    }
  }

  /// Firebaseから指定期間の実績タスクを直接取得（ローカルへ保存しない）
  Future<List<ActualTask>> fetchTasksByDateRangeServer(
      DateTime startDate, DateTime endDate) async {
    try {
      final List<ActualTask> results = [];
      QuerySnapshot? querySnapshot;
      try {
        querySnapshot = await userCollection
            .where('isDeleted', isEqualTo: false)
            .where('startTime',
                isGreaterThanOrEqualTo: startDate.toIso8601String())
            .where('startTime', isLessThanOrEqualTo: endDate.toIso8601String())
            .get(const GetOptions(source: Source.server));
      } catch (e) {
        // IMPORTANT: 失敗時に黙って全件取得へフォールバックしない（read爆発防止）
        print('❌ fetchTasksByDateRangeServer failed (no full fallback): $e');
        return [];
      }

      for (final doc in querySnapshot.docs) {
        try {
          final data = doc.data() as Map<String, dynamic>;
          data['cloudId'] = doc.id;
          final task = createFromCloudJson(data);
          final st = task.startTime;
          final inRange =
              (st.isAfter(startDate) || st.isAtSameMomentAs(startDate)) &&
                  (st.isBefore(endDate) || st.isAtSameMomentAs(endDate));
          if (inRange) results.add(task);
        } catch (_) {}
      }
      return results;
    } catch (e) {
      print('❌ fetchTasksByDateRangeServer failed: $e');
      return [];
    }
  }
}
