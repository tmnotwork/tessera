import 'dart:async';

import '../models/inbox_task.dart';
import '../models/syncable_model.dart';
import '../utils/async_mutex.dart';
import 'conflict_detector.dart';
import 'data_sync_service.dart';
import 'inbox_task_service.dart';
import 'device_info_service.dart';
import 'auth_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'app_settings_service.dart';
import 'sync_kpi.dart';
import 'sync_context.dart';
import '../utils/kant_inbox_trace.dart';

/// ローカルにブロック割当があり、リモートが blockId 未設定のとき、
/// 「他端末で意図的に未割当にした新しい版」でない限りリモートを信じない。
///
/// [localVersion] / [localLastModified] はマージ前のローカル値（saveToLocal 用）。
bool _inboxRemoteNullBlockLooksStaleVsLocal({
  required InboxTask remote,
  required int localVersion,
  required DateTime localLastModified,
}) {
  final remoteHasBlock = remote.blockId != null && remote.blockId!.isNotEmpty;
  if (remoteHasBlock) return false;
  if (remote.version > localVersion) return false;
  if (remote.version < localVersion) return true;
  if (remote.lastModified
      .isAfter(localLastModified.add(const Duration(seconds: 2)))) {
    return false;
  }
  return true;
}

bool _inboxKeepBlockAssignmentOverRemoteNull(InboxTask local, InboxTask remote) {
  final localHasBlock = local.blockId != null && local.blockId!.isNotEmpty;
  final remoteHasBlock = remote.blockId != null && remote.blockId!.isNotEmpty;
  if (!localHasBlock || remoteHasBlock) return false;
  return _inboxRemoteNullBlockLooksStaleVsLocal(
    remote: remote,
    localVersion: local.version,
    localLastModified: local.lastModified,
  );
}

/// InboxTask同期サービス
class InboxTaskSyncService extends DataSyncService<InboxTask> {
  static final InboxTaskSyncService _instance =
      InboxTaskSyncService._internal();
  factory InboxTaskSyncService() => _instance;
  InboxTaskSyncService._internal() : super('inbox_tasks');

  @override
  String? get diffCursorKey => AppSettingsService.keyCursorInbox;

  @override
  InboxTask createFromCloudJson(Map<String, dynamic> json) {
    final originalKeys = Set<String>.from(json.keys);
    final normalized = Map<String, dynamic>.from(json);

    // InboxTask は予定専用: 実績フィールドは破棄
    normalized['startTime'] = null;
    normalized['endTime'] = null;

    DateTime? dt0(dynamic v) => FirestoreHelper.timestampToDateTime(v);
    void norm(String key) {
      final dt = dt0(normalized[key]);
      if (dt != null) normalized[key] = dt.toIso8601String();
    }

    norm('createdAt');
    norm('lastModified');
    norm('lastSynced');
    norm('executionDate');
    norm('dueDate');
    norm('startTime');
    norm('endTime');

    final task = InboxTask.fromJson(normalized);
    // 欠落キー保持マージのため、元JSONに存在したキー集合を保持する
    task.setPresentCloudKeys(originalKeys);
    return task;
  }

  @override
  Future<List<InboxTask>> getLocalItems() async {
    try {
      // cursorSeed（ローカルlastModified由来）を成立させるため、同期前に必ずBoxを開く。
      // 未初期化だと getAllInboxTasks() が例外→空配列となり、fullFetch に落ちやすい。
      await InboxTaskService.initialize();
      return InboxTaskService.getAllInboxTasks();
    } catch (e) {
      print('❌ Failed to get local inbox tasks: $e');
      return [];
    }
  }

  @override
  Future<InboxTask?> getLocalItemByCloudId(String cloudId) async {
    try {
      await InboxTaskService.initialize();
      final tasks = InboxTaskService.getAllInboxTasks();
      return tasks.where((t) => t.cloudId == cloudId).firstOrNull;
    } catch (e) {
      print('❌ Failed to get local inbox task by cloudId: $e');
      return null;
    }
  }

  @override
  Future<void> saveToLocal(InboxTask task) async {
    try {
      // 既存のタスクを確認
      final existingTask = await getLocalItemByCloudId(task.cloudId!);
      kantInboxTrace(
        'saveToLocal',
        'id=${task.id} cloudId=${task.cloudId} blockId=${task.blockId} v=${task.version} hadLocal=${existingTask != null} '
        'localBlockId=${existingTask?.blockId} localV=${existingTask?.version} origin=${SyncContext.origin}',
      );

      if (existingTask != null) {
        final localVersionBefore = existingTask.version;
        final localLmBefore = existingTask.lastModified;
        final priorBlockId = existingTask.blockId;

        // 巻き戻り原因確定用: 上書きを起こした同期のトリガーを必ずログに残す
        print(
            '[InboxSaveToLocal] overwrite local with remote id=${task.id} cloudId=${task.cloudId} blockId=${task.blockId} '
            'origin=${SyncContext.origin}',
        );
        // 欠落キー保持でのマージ:
        // - createFromCloudJson が保持した presentCloudKeys を使い、
        //   「リモートに存在しなかったキー」を適用しない。
        final json = task.toCloudJson();
        final present = task.presentCloudKeys;
        if (present != null && present.isNotEmpty) {
          json.removeWhere((k, _) => !present.contains(k));
        }
        existingTask.fromCloudJson(json);
        // InboxTask は予定専用: 実績フィールドは常にローカルでも破棄
        existingTask.startTime = null;
        existingTask.endTime = null;

        // リモートが blockId=null の古い版のとき、マージで割当だけ消えるのを防ぐ
        if (priorBlockId != null &&
            priorBlockId.isNotEmpty &&
            (existingTask.blockId == null || existingTask.blockId!.isEmpty) &&
            _inboxRemoteNullBlockLooksStaleVsLocal(
              remote: task,
              localVersion: localVersionBefore,
              localLastModified: localLmBefore,
            )) {
          existingTask.blockId = priorBlockId;
          kantInboxTrace(
            'saveToLocal_restore_blockId_stale_remote_null',
            'id=${existingTask.id} cloudId=${existingTask.cloudId} restored=$priorBlockId',
          );
        }

        await InboxTaskService.updateInboxTask(existingTask);
      } else {
        // 巻き戻り確定用: 新規としてリモートを保存（localItem==null 経路で呼ばれた場合あり）
        print(
            '[InboxSaveToLocal] new local (existingTask==null) id=${task.id} cloudId=${task.cloudId} blockId=${task.blockId}',
        );
        // 新規タスクを作成
        task.startTime = null;
        task.endTime = null;
        await InboxTaskService.addInboxTask(task);
      }

      // print('✅ Saved inbox task locally: ${task.title}'); // ログを無効化
    } catch (e) {
      print('❌ Failed to save inbox task locally: $e');
      rethrow;
    }
  }

  @override
  Future<void> uploadToFirebase(InboxTask item) async {
    // 実績フィールドは常に null で上書き（InboxTaskは予定専用）
    item.startTime = null;
    item.endTime = null;
    await uploadToFirebaseWithOutcome(item);
  }

  /// アップロード結果を返す版（isCompleted巻き戻し防止）
  ///
  /// InboxTaskの「復活」（isCompleted: true → false）は意図的な操作なので、
  /// ローカルの lastModified がリモートより新しい場合はローカルを優先する。
  @override
  Future<UploadResult<InboxTask>> uploadToFirebaseWithOutcome(
      InboxTask item,
      {bool skipPreflight = false}) async {
    if (skipPreflight) {
      kantInboxTrace(
        'upload_delegate_skipPreflight',
        'id=${item.id} cloudId=${item.cloudId} v=${item.version} blockId=${item.blockId}',
      );
      return super.uploadToFirebaseWithOutcome(item, skipPreflight: true);
    }

    // Guard against rollback by consulting remote before write
    var preflightThrew = false;
    try {
      final String? key = (item.cloudId != null && item.cloudId!.isNotEmpty)
          ? item.cloudId
          : item.id;
      if (key != null && key.isNotEmpty) {
        DocumentSnapshot? docSnap;
        for (var attempt = 0; attempt < 3; attempt++) {
          try {
            docSnap = await userCollection
                .doc(key)
                .get(const GetOptions(source: Source.server))
                .timeout(const Duration(seconds: 10));
            break;
          } on TimeoutException {
            if (attempt >= 2) rethrow;
            await Future<void>.delayed(const Duration(milliseconds: 400));
          }
        }
        final doc = docSnap!;
        if (doc.exists) {
          final data = doc.data() as Map<String, dynamic>;
          final bool remoteDeleted = (data['isDeleted'] ?? false) == true;
          if (remoteDeleted) {
            // Tombstone をローカルにも反映
            try {
              final adopted =
                  createFromCloudJson({...data, 'cloudId': doc.id});
              adopted.markAsSynced();
              await InboxTaskService.updateInboxTaskPreservingLastModified(
                  adopted);
              item.cloudId ??= doc.id;
              kantInboxTrace(
                'upload_preflight_remote_deleted_adopted',
                'id=${item.id} cloudId=${doc.id}',
              );
              return UploadResult<InboxTask>(
                outcome: UploadOutcome.skippedRemoteDeleted,
                cloudId: doc.id,
                adoptedRemote: adopted,
                localApplied: true,
                reason: 'remoteDeleted',
              );
            } catch (_) {
              return UploadResult<InboxTask>(
                outcome: UploadOutcome.skippedRemoteDeleted,
                cloudId: doc.id,
                localApplied: false,
                reason: 'remoteDeleted',
              );
            }
          }
          // Compare lastModified, version, and isCompleted progression
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
          final bool remoteIsCompleted = (data['isCompleted'] ?? false) == true;
          final bool localIsCompleted = item.isCompleted == true;
          final bool remoteIsNewer =
              remoteLm != null && remoteLm.isAfter(item.lastModified);
          // isCompleted の progression: false < true
          final bool localAhead = localIsCompleted && !remoteIsCompleted;
          final bool remoteAhead = remoteIsCompleted && !localIsCompleted;
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
              await InboxTaskService.updateInboxTaskPreservingLastModified(
                  merged);
              item.cloudId ??= doc.id;
              kantInboxTrace(
                'upload_preflight_remote_ahead_adopted',
                'id=${item.id} localV=${item.version} remoteV=$remoteVer '
                'localBlock=${item.blockId} remoteBlock=${data['blockId']}',
              );
              return UploadResult<InboxTask>(
                outcome: UploadOutcome.skippedRemoteNewerAdopted,
                cloudId: doc.id,
                adoptedRemote: merged,
                localApplied: true,
                reason: 'remoteAhead',
              );
            } catch (_) {
              return UploadResult<InboxTask>(
                outcome: UploadOutcome.skippedRemoteNewerAdopted,
                cloudId: doc.id,
                localApplied: false,
                reason: 'remoteAhead',
              );
            }
          }
        }
      }
    } catch (e) {
      preflightThrew = true;
      print(
        '⚠️ [InboxUpload] preflight failed id=${item.id} cloudId=${item.cloudId} error=$e',
      );
      kantInboxTrace(
        'upload_preflight_exception',
        'id=${item.id} cloudId=${item.cloudId} v=${item.version} err=$e',
      );
    }

    // 既に cloudId がある＝サーバー上の既存 doc を更新し得る。preflight 不能時は
    // skipPreflight で無条件 set せず失敗扱いにし、Lost Update / 巻き戻りを避ける。
    if (preflightThrew &&
        item.cloudId != null &&
        item.cloudId!.isNotEmpty) {
      kantInboxTrace(
        'upload_abort_preflight_no_blind_set',
        'id=${item.id} cloudId=${item.cloudId} v=${item.version} blockId=${item.blockId}',
      );
      return UploadResult<InboxTask>(
        outcome: UploadOutcome.failed,
        cloudId: item.cloudId,
        reason: 'preflightFailed',
      );
    }

    // Fallback to default upload (includes deterministic docId via super)
    kantInboxTrace(
      'upload_super_skipPreflight',
      'id=${item.id} cloudId=${item.cloudId} v=${item.version} blockId=${item.blockId} preflightThrew=$preflightThrew',
    );
    final result =
        await super.uploadToFirebaseWithOutcome(item, skipPreflight: true);
    kantInboxTrace(
      'upload_super_result',
      'id=${item.id} outcome=${result.outcome.name} cloudId=${item.cloudId}',
    );
    if (result.outcome == UploadOutcome.written) {
      // Persist updated cloudId/lastSynced locally WITHOUT changing lastModified
      try {
        await InboxTaskService.updateInboxTaskPreservingLastModified(item);
      } catch (_) {}
      return result.copyWith(
        cloudId: item.cloudId,
        localApplied: true,
      );
    }
    return result;
  }

  @override
  Future<InboxTask> handleManualConflict(
      InboxTask local, InboxTask remote) async {
    await saveToLocal(remote);
    return remote;
  }

  @override
  Future<InboxTask> resolveConflict(InboxTask local, InboxTask remote) async {
    // NOTE:
    // 以前は「常にリモート勝ち」だったが、これだと
    // - ローカル更新が未送信（オフライン/一時失敗/エラー握りつぶし）なだけで
    //   次の差分同期で未完了へ“巻き戻る”事故が起こり得る。
    //
    // InboxTask は version/lastModified/deviceId を持つため、
    // ConflictDetector の結果に従い “新しい方” を採用する。
    final resolution = ConflictDetector.detectConflict(local, remote);
    kantInboxTrace(
      'resolveConflict_enter',
      'id=${local.id} cloudId=${local.cloudId} resolution=${resolution.name} '
      'localV=${local.version} remoteV=${remote.version} localBlock=${local.blockId} remoteBlock=${remote.blockId} '
      'localLm=${local.lastModified.toIso8601String()} remoteLm=${remote.lastModified.toIso8601String()}',
    );
    switch (resolution) {
      case ConflictResolution.localNewer:
      case ConflictResolution.localWins:
        // ローカルを保持（必要なアップロードは outbox/即時同期側に委譲）
        kantInboxTrace(
          'resolveConflict_keep_local',
          'id=${local.id} ${resolution.name}',
        );
        return local;
      case ConflictResolution.remoteNewer:
      case ConflictResolution.remoteWins:
        if (_inboxKeepBlockAssignmentOverRemoteNull(local, remote)) {
          kantInboxTrace(
            'resolveConflict_keep_local_block_vs_remote_null',
            'id=${local.id} cloudId=${local.cloudId} resolution=${resolution.name} '
            'localV=${local.version} remoteV=${remote.version} localBlock=${local.blockId}',
          );
          return local;
        }
        print(
            '[InboxResolveConflict] remote wins id=${local.id} cloudId=${local.cloudId} '
            'resolution=${resolution.name} localVer=${local.version} remoteVer=${remote.version} '
            'localBlockId=${local.blockId} remoteBlockId=${remote.blockId}',
        );
        await saveToLocal(remote);
        return remote;
      case ConflictResolution.needsManual:
        // 更新 vs 削除などの競合は、復活を避けるためリモート（墓石含む）を優先
        if (_inboxKeepBlockAssignmentOverRemoteNull(local, remote)) {
          kantInboxTrace(
            'resolveConflict_keep_local_block_needsManual_remote_null',
            'id=${local.id} cloudId=${local.cloudId} localBlock=${local.blockId}',
          );
          return local;
        }
        print(
            '[InboxResolveConflict] remote wins (needsManual) id=${local.id} cloudId=${local.cloudId} '
            'localBlockId=${local.blockId} remoteBlockId=${remote.blockId}',
        );
        await saveToLocal(remote);
        return remote;
    }
  }

  /// InboxTask作成時の同期対応
  Future<InboxTask> createTaskWithSync({
    required String title,
    String? projectId,
    DateTime? dueDate,
    required DateTime executionDate,
    int? startHour,
    int? startMinute,
    int estimatedDuration = 5,
    String? memo,
    String? blockId,
    String? subProjectId,
    bool isImportant = false,
  }) async {
    try {
      final deviceId = await DeviceInfoService.getDeviceId();
      final userId = AuthService.getCurrentUserId() ?? '';

      // ローカルでタスク作成
      final now = DateTime.now();
      final task = InboxTask(
        id: 'inbox_${now.millisecondsSinceEpoch}_${now.microsecond}',
        title: title,
        projectId: projectId,
        dueDate: dueDate,
        executionDate: executionDate,
        startHour: startHour,
        startMinute: startMinute,
        estimatedDuration: estimatedDuration,
        memo: memo,
        createdAt: now,
        lastModified: now,
        userId: userId,
        blockId: blockId,
        subProjectId: subProjectId,
        isImportant: isImportant,
        deviceId: deviceId,
        version: 1,
      );

      // ローカル保存
      await InboxTaskService.addInboxTask(task);

      // Firebase同期（ネットワークがあれば）
      try {
        await uploadToFirebase(task);
      } catch (e) {
        print('⚠️ Failed to sync new inbox task to Firebase: $e');
      }

      return task;
    } catch (e) {
      print('❌ Failed to create inbox task with sync: $e');
      rethrow;
    }
  }

  /// InboxTask更新時の同期対応
  Future<void> updateTaskWithSync(InboxTask task) async {
    try {
      final deviceId = await DeviceInfoService.getDeviceId();

      // 同期メタデータを更新
      task.markAsModified(deviceId);

      // ローカル更新
      await InboxTaskService.updateInboxTask(task);

      // Firebase同期（ネットワークがあれば）
      try {
        await uploadToFirebase(task);
      } catch (e) {
        print('⚠️ Failed to sync updated inbox task to Firebase: $e');
      }
    } catch (e) {
      print('❌ Failed to update inbox task with sync: $e');
      rethrow;
    }
  }

  /// InboxTask削除時の同期対応
  Future<void> deleteTaskWithSync(String taskId) async {
    try {
      final tasks = InboxTaskService.getAllInboxTasks();
      final task = tasks.where((t) => t.id == taskId).firstOrNull;
      if (task == null) return;

      final deviceId = await DeviceInfoService.getDeviceId();

      // 論理削除マークを設定
      task.isDeleted = true;
      task.markAsModified(deviceId);

      // ローカル削除
      await InboxTaskService.deleteInboxTask(taskId);

      // Firebase削除同期（ネットワークがあれば）
      try {
        if (task.cloudId != null) {
          await deleteFromFirebase(task.cloudId!);
        }
      } catch (e) {
        print('⚠️ Failed to sync inbox task deletion to Firebase: $e');
      }
    } catch (e) {
      print('❌ Failed to delete inbox task with sync: $e');
      rethrow;
    }
  }

  /// 実行日別InboxTask同期
  Future<SyncResult> syncTasksByDate(DateTime date) async {
    try {
      final dateStr = date.toIso8601String().split('T')[0]; // YYYY-MM-DD形式
      final nextDateStr =
          date.add(const Duration(days: 1)).toIso8601String().split('T')[0];

      // 指定日のFirestoreクエリ
      final querySnapshot = await userCollection
          .where('isDeleted', isEqualTo: false)
          .where('executionDate',
              isGreaterThanOrEqualTo: '${dateStr}T00:00:00')
          .where('executionDate', isLessThan: '${nextDateStr}T00:00:00')
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 15));
      try {
        SyncKpi.queryReads += querySnapshot.docs.length;
      } catch (_) {}

      final remoteTasks = <InboxTask>[];
      for (final doc in querySnapshot.docs) {
        try {
          final data = doc.data() as Map<String, dynamic>;
          data['cloudId'] = doc.id;
          final task = createFromCloudJson(data);
          remoteTasks.add(task);
        } catch (e) {
          print('⚠️ Failed to parse inbox task ${doc.id}: $e');
        }
      }

      // ローカルタスクとの競合解決
      int syncedCount = 0;
      int failedCount = 0;
      final conflicts = <ConflictResolution>[];

      for (final remoteTask in remoteTasks) {
        try {
          final localTask = await getLocalItemByCloudId(remoteTask.cloudId!);

          if (localTask == null) {
            await saveToLocal(remoteTask);
            syncedCount++;
          } else if (localTask.hasConflictWith(remoteTask)) {
            await resolveConflict(localTask, remoteTask);
            conflicts.add(ConflictResolution.localNewer); // 簡易的な記録
            syncedCount++;
          }
        } catch (e) {
          print('❌ Failed to process remote inbox task: $e');
          failedCount++;
        }
      }

      return SyncResult(
        success: failedCount == 0,
        syncedCount: syncedCount,
        failedCount: failedCount,
        conflicts: conflicts,
      );
    } catch (e) {
      print('❌ Date-based sync failed: $e');
      return SyncResult(
        success: false,
        error: e.toString(),
        failedCount: 1,
      );
    }
  }

  /// プロジェクト別InboxTask同期
  Future<SyncResult> syncTasksByProject(String projectId) async {
    try {
      // 指定プロジェクトのFirestoreクエリ
      final querySnapshot = await userCollection
          .where('isDeleted', isEqualTo: false)
          .where('projectId', isEqualTo: projectId)
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 15));
      try {
        SyncKpi.queryReads += querySnapshot.docs.length;
      } catch (_) {}

      final remoteTasks = <InboxTask>[];
      for (final doc in querySnapshot.docs) {
        try {
          final data = doc.data() as Map<String, dynamic>;
          data['cloudId'] = doc.id;
          final task = createFromCloudJson(data);
          remoteTasks.add(task);
        } catch (e) {
          print('⚠️ Failed to parse inbox task ${doc.id}: $e');
        }
      }

      // ローカルタスクとの競合解決
      int syncedCount = 0;
      int failedCount = 0;
      final conflicts = <ConflictResolution>[];

      for (final remoteTask in remoteTasks) {
        try {
          final localTask = await getLocalItemByCloudId(remoteTask.cloudId!);

          if (localTask == null) {
            await saveToLocal(remoteTask);
            syncedCount++;
          } else if (localTask.hasConflictWith(remoteTask)) {
            await resolveConflict(localTask, remoteTask);
            conflicts.add(ConflictResolution.localNewer); // 簡易的な記録
            syncedCount++;
          }
        } catch (e) {
          print('❌ Failed to process remote inbox task: $e');
          failedCount++;
        }
      }

      return SyncResult(
        success: failedCount == 0,
        syncedCount: syncedCount,
        failedCount: failedCount,
        conflicts: conflicts,
      );
    } catch (e) {
      print('❌ Project-based sync failed: $e');
      return SyncResult(
        success: false,
        error: e.toString(),
        failedCount: 1,
      );
    }
  }

  Future<List<InboxTask>> fetchTasksForDb({
    DateTime? executionStart,
    DateTime? executionEnd,
    bool includeDeleted = false,
    bool? isCompleted,
    bool? isSomeday,
    int limit = 500,
  }) async {
    try {
      await InboxTaskService.initialize();
      Iterable<InboxTask> items = InboxTaskService.getAllInboxTasks();
      if (!includeDeleted) {
        items = items.where((task) => task.isDeleted != true);
      }
      if (isCompleted != null) {
        items = items.where((task) => task.isCompleted == isCompleted);
      }
      if (isSomeday != null) {
        items = items.where((task) => task.isSomeday == isSomeday);
      }
      if (executionStart != null) {
        final start = DateTime(
          executionStart.year,
          executionStart.month,
          executionStart.day,
        );
        items = items.where(
          (task) => !task.executionDate.isBefore(start),
        );
      }
      if (executionEnd != null) {
        final end = DateTime(
          executionEnd.year,
          executionEnd.month,
          executionEnd.day,
        );
        items = items.where(
          (task) => !task.executionDate.isAfter(end),
        );
      }
      final sorted = items.toList()
        ..sort((a, b) {
          final execCompare = b.executionDate.compareTo(a.executionDate);
          if (execCompare != 0) return execCompare;
          return b.lastModified.compareTo(a.lastModified);
        });
      final cappedLimit = limit.clamp(1, 2000);
      return sorted.take(cappedLimit).toList();
    } catch (e) {
      print('❌ Failed to fetch inbox tasks for DB: $e');
      return [];
    }
  }

  /// 完了状態での同期対応
  Future<void> markTaskCompletedWithSync(
      String taskId, bool isCompleted) async {
    try {
      final tasks = InboxTaskService.getAllInboxTasks();
      final task = tasks.where((t) => t.id == taskId).firstOrNull;
      if (task == null) return;

      task.isCompleted = isCompleted;
      await updateTaskWithSync(task);

      print(
          '✅ Updated inbox task completion status with sync: ${task.title} -> $isCompleted');
    } catch (e) {
      print('❌ Failed to update inbox task completion status with sync: $e');
      rethrow;
    }
  }

  // 実行状態の同期はActualTaskで管理するため、InboxTask側のisRunningは廃止

  /// 未完了タスクの同期
  Future<SyncResult> syncIncompleteTasks() async {
    try {
      // 未完了タスクのFirestoreクエリ
      final querySnapshot = await userCollection
          .where('isDeleted', isEqualTo: false)
          .where('isCompleted', isEqualTo: false)
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 15));
      try {
        SyncKpi.queryReads += querySnapshot.docs.length;
      } catch (_) {}

      final remoteTasks = <InboxTask>[];
      for (final doc in querySnapshot.docs) {
        try {
          final data = doc.data() as Map<String, dynamic>;
          data['cloudId'] = doc.id;
          final task = createFromCloudJson(data);
          remoteTasks.add(task);
        } catch (e) {
          print('⚠️ Failed to parse inbox task ${doc.id}: $e');
        }
      }

      // ローカルタスクとの競合解決
      int syncedCount = 0;
      int failedCount = 0;
      final conflicts = <ConflictResolution>[];

      for (final remoteTask in remoteTasks) {
        try {
          final localTask = await getLocalItemByCloudId(remoteTask.cloudId!);

          if (localTask == null) {
            await saveToLocal(remoteTask);
            syncedCount++;
          } else if (localTask.hasConflictWith(remoteTask)) {
            await resolveConflict(localTask, remoteTask);
            conflicts.add(ConflictResolution.localNewer); // 簡易的な記録
            syncedCount++;
          }
        } catch (e) {
          print('❌ Failed to process remote inbox task: $e');
          failedCount++;
        }
      }

      print(
          '✅ Incomplete tasks sync completed: $syncedCount synced, $failedCount failed');
      return SyncResult(
        success: failedCount == 0,
        syncedCount: syncedCount,
        failedCount: failedCount,
        conflicts: conflicts,
      );
    } catch (e) {
      print('❌ Incomplete tasks sync failed: $e');
      return SyncResult(
        success: false,
        error: e.toString(),
        failedCount: 1,
      );
    }
  }

  /// すべてのInboxTaskを同期
  ///
  /// 複数の呼び出し元（postAuthWork経由のSyncManager.syncAll、インボックスタブ開閉など）が
  /// 同時に呼び出しても、[_syncMutex] によって直列化される。
  /// 先行する同期が走っている間に追加で呼び出された場合は、前の結果を待って返す。
  static final AsyncMutex _syncMutex = AsyncMutex();

  static Future<SyncResult> syncAllInboxTasks({bool forceFullSync = false}) async {
    return _syncMutex.protect(() async {
      try {
        final syncService = InboxTaskSyncService();
        // NOTE:
        // 画面表示/ウィジェット更新など「読取目的の同期」で、
        // ローカルのneedsSync（lastModified>lastSynced）を理由に自動アップロードが走ると
        // 「ユーザー無操作でも書き込みが増える」ため、ここではアップロードPhaseを無効化する。
        final res = await syncService.performSync(
          forceFullSync: forceFullSync,
          uploadLocalChanges: false,
        );
        return res;
      } catch (e) {
        print('❌ Failed to sync all inbox tasks: $e');
        return SyncResult(
          success: false,
          error: e.toString(),
          failedCount: 1,
        );
      }
    });
  }

  /// InboxTaskの変更を監視
  Stream<List<InboxTask>> watchInboxTaskChanges() {
    // read削減: 全件監視ではなく「未完了」に限定（UIに必要な範囲へ縮小）
    return watchIncompleteTasks();
  }

  /// 日付別InboxTask監視
  Stream<List<InboxTask>> watchTasksByDate(DateTime date) {
    final dateStr = date.toIso8601String().split('T')[0]; // YYYY-MM-DD形式
    final nextDateStr =
        date.add(const Duration(days: 1)).toIso8601String().split('T')[0];
    bool first = true;
    return userCollection
        .where('isDeleted', isEqualTo: false)
        .where('executionDate',
            isGreaterThanOrEqualTo: '${dateStr}T00:00:00')
        .where('executionDate', isLessThan: '${nextDateStr}T00:00:00')
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
      final items = <InboxTask>[];
      for (final doc in snapshot.docs) {
        try {
          final data = doc.data() as Map<String, dynamic>;
          data['cloudId'] = doc.id;
          final item = createFromCloudJson(data);
          items.add(item);
        } catch (e) {
          print('⚠️ Failed to parse inbox task ${doc.id}: $e');
        }
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

  /// 今日のInboxTask監視
  Stream<List<InboxTask>> watchTodayTasks() {
    return watchTasksByDate(DateTime.now());
  }

  /// 未完了InboxTask監視
  Stream<List<InboxTask>> watchIncompleteTasks() {
    bool first = true;
    return userCollection
        .where('isDeleted', isEqualTo: false)
        .where('isCompleted', isEqualTo: false)
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
      final items = <InboxTask>[];
      for (final doc in snapshot.docs) {
        try {
          final data = doc.data() as Map<String, dynamic>;
          data['cloudId'] = doc.id;
          final item = createFromCloudJson(data);
          items.add(item);
        } catch (e) {
          print('⚠️ Failed to parse inbox task ${doc.id}: $e');
        }
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

  /// 実行中InboxTask監視
  Stream<List<InboxTask>> watchRunningTasks() {
    // InboxTask側の実行中状態は廃止。必要ならActualTask側の監視を使用してください。
    return const Stream<List<InboxTask>>.empty();
  }

  /// ローカルインボックスタスクを削除する（同期処理で使用）
  @override
  Future<void> deleteLocalItem(InboxTask item) async {
    try {
      // ローカルHiveから削除
      await InboxTaskService.deleteInboxTask(item.id);
    } catch (e) {
      print('❌ Failed to delete local inbox task: ${item.title}, error: $e');
      rethrow;
    }
  }

  /// リモートに論理削除を保証（cloudId/id/検索の順で試行）
  Future<void> ensureRemoteLogicalDelete(InboxTask task) async {
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
      final snap = await userCollection
          .where('id', isEqualTo: task.id)
          .limit(5)
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 10));
      if (snap.docs.isEmpty) return;
      for (final d in snap.docs) {
        try {
          await deleteFromFirebase(d.id);
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 差分同期: lastModified >= cursor のインボックスタスク
  Future<SyncResult> syncInboxSince(DateTime cursorUtc) async {
    try {
      final from = cursorUtc.subtract(const Duration(seconds: 10));
      final snapshot = await userCollection
          .where('lastModified', isGreaterThanOrEqualTo: from.toIso8601String())
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 15));
      try {
        SyncKpi.queryReads += snapshot.docs.length;
      } catch (_) {}

      int synced = 0;
      int failed = 0;
      final conflicts = <ConflictResolution>[];
      for (final doc in snapshot.docs) {
        try {
          final data = doc.data() as Map<String, dynamic>;
          data['cloudId'] = doc.id;
          final remote = createFromCloudJson(data);
          final local = await getLocalItemByCloudId(remote.cloudId!);
          if (local == null) {
            await saveToLocal(remote);
            synced++;
          } else if (local.hasConflictWith(remote)) {
            await resolveConflict(local, remote);
            conflicts.add(ConflictResolution.remoteNewer);
            synced++;
          }
        } catch (_) {
          failed++;
        }
      }
      return SyncResult(
          success: failed == 0,
          syncedCount: synced,
          failedCount: failed,
          conflicts: conflicts);
    } catch (e) {
      return SyncResult(success: false, error: e.toString(), failedCount: 1);
    }
  }
}
