import 'dart:async';
import '../models/block.dart';
import '../models/syncable_model.dart';
import 'data_sync_service.dart';
import 'block_service.dart';
import 'device_info_service.dart';
import '../services/routine_task_v2_service.dart';
import 'app_settings_service.dart';
import 'block_utilities.dart';
import 'block_watcher.dart';
import 'day_key_service.dart';
import 'block_local_data_manager.dart';
import 'block_routine_manager.dart';
import 'block_sync_operations.dart';
import 'block_crud_operations.dart';
import 'block_conflict_resolver.dart';
import 'block_cloud_operations.dart';
import 'block_task_rescheduler.dart';
import 'block_outbox_manager.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'sync_all_history_service.dart';
import 'sync_kpi.dart';

/// Block同期サービス
class BlockSyncService extends DataSyncService<Block> {
  static final BlockSyncService _instance = BlockSyncService._internal();
  factory BlockSyncService() => _instance;
  BlockSyncService._internal() : super('blocks') {
    _watcher = BlockWatcher(this);
  }

  @override
  String? get diffCursorKey => AppSettingsService.keyCursorBlocks;

  // 同期処理のロック（競合防止）
  static bool _isSyncing = false;
  // 同一キーの並行作成を防ぐロック
  // ignore: unused_field
  static final Set<String> _inFlightCreationKeys = <String>{};

  // ブロック監視用インスタンス
  late final BlockWatcher _watcher;

  /// TaskProvider更新通知用ストリーム
  static Stream<void> get updateStream => BlockUtilities.updateStream;

  @override
  Block createFromCloudJson(Map<String, dynamic> json) {
    return BlockCloudOperations.createFromCloudJson(json);
  }

  @override
  Future<void> uploadToFirebase(Block item) async {
    return BlockCloudOperations.uploadToFirebase(item, this, userCollection);
  }

  /// 内部アップロード処理（BlockCloudOperationsから呼び出される）
  Future<void> uploadToFirebaseInternal(Block item) async {
    await super.uploadToFirebase(item);
  }

  @override
  Future<List<Block>> getLocalItems() async {
    return BlockLocalDataManager.getLocalItems();
  }

  @override
  Future<Block?> getLocalItemByCloudId(String cloudId) async {
    return BlockLocalDataManager.getLocalItemByCloudId(cloudId);
  }

  @override
  Future<void> saveToLocal(Block block) async {
    return BlockLocalDataManager.saveToLocal(block);
  }

  @override
  Future<Block> handleManualConflict(Block local, Block remote) async {
    return BlockConflictResolver.handleManualConflict(local, remote);
  }

  /// 競合解決: 端末に依らず Last-Write-Wins（lastModified 新しい方を採用）
  @override
  Future<Block> resolveConflict(Block local, Block remote) async {
    return BlockConflictResolver.resolveConflict(local, remote);
  }

  /// ブロック作成時の同期対応
  Future<Block> createBlockWithSync({
    required String title,
    required DateTime executionDate,
    required int startHour,
    required int startMinute,
    int estimatedDuration = 60,
    int? workingMinutes,
    bool allDay = false,
    DateTime? startLocalOverride,
    DateTime? endLocalExclusiveOverride,
    TaskCreationMethod creationMethod = TaskCreationMethod.manual,
    String? projectId,
    DateTime? dueDate,
    String? memo,
    String? subProjectId,
    String? subProject,
    String? modeId,
    String? blockName,
    String? location,
    String? taskId,
    bool isCompleted = false,
    bool isEvent = false,
    bool excludeFromReport = false,
  }) async {
    return BlockCRUDOperations.createBlockWithSync(
      title: title,
      executionDate: executionDate,
      startHour: startHour,
      startMinute: startMinute,
      estimatedDuration: estimatedDuration,
      workingMinutes: workingMinutes,
      allDay: allDay,
      startLocalOverride: startLocalOverride,
      endLocalExclusiveOverride: endLocalExclusiveOverride,
      creationMethod: creationMethod,
      projectId: projectId,
      dueDate: dueDate,
      memo: memo,
      subProjectId: subProjectId,
      subProject: subProject,
      modeId: modeId,
      blockName: blockName,
      location: location,
      taskId: taskId,
      isCompleted: isCompleted,
      isEvent: isEvent,
      excludeFromReport: excludeFromReport,
      syncService: this,
      verifyUpload: _logRoutineBlockUploadVerification,
    );
  }

  /// Final State 方向: planned の正は UTC区間（startAt/endAtExclusive）。
  /// UI入力（日付+時刻）は accountTimeZoneId の wall-clock として解釈し、UTCへ正規化する。
  ///
  /// 互換のため、レガシー fields（executionDate/startHour/startMinute/estimatedDuration）も派生して埋める。
  Future<Block> createBlockWithSyncRange({
    required String title,
    required DateTime startAtUtc,
    required DateTime endAtExclusiveUtc,
    int? workingMinutes,
    TaskCreationMethod creationMethod = TaskCreationMethod.manual,
    String? projectId,
    DateTime? dueDate,
    String? memo,
    String? subProjectId,
    String? subProject,
    String? modeId,
    String? blockName,
    String? location,
    String? taskId,
    bool isCompleted = false,
    bool isEvent = false,
    bool excludeFromReport = false,
  }) async {
    final start = startAtUtc.toUtc();
    final end = endAtExclusiveUtc.toUtc();
    final dur = end.difference(start).inMinutes;
    final safeDur = dur < 1 ? 1 : dur;

    // Derive legacy fields from accountTimeZoneId wall-clock (not device local).
    final startWall = DayKeyService.toAccountWallClockFromUtc(start);
    final executionDate = DateTime(startWall.year, startWall.month, startWall.day);
    final startHour = startWall.hour;
    final startMinute = startWall.minute;

    final created = await createBlockWithSync(
      title: title,
      executionDate: executionDate,
      startHour: startHour,
      startMinute: startMinute,
      estimatedDuration: safeDur,
      workingMinutes: workingMinutes,
      creationMethod: creationMethod,
      projectId: projectId,
      dueDate: dueDate,
      memo: memo,
      subProjectId: subProjectId,
      subProject: subProject,
      modeId: modeId,
      blockName: blockName,
      location: location,
      taskId: taskId,
      isCompleted: isCompleted,
      isEvent: isEvent,
      excludeFromReport: excludeFromReport,
    );

    // Ensure canonical fields match the requested range (not just legacy-derived).
    final normalized = created.copyWith(
      startAt: start,
      endAtExclusive: end,
      dayKeys: null,
      monthKeys: null,
    ).recomputeCanonicalRange(
      startLocalOverride: DateTime(
        startWall.year,
        startWall.month,
        startWall.day,
        startWall.hour,
        startWall.minute,
      ),
      // endWallExclusive uses account TZ conversion of the UTC end.
      endLocalExclusiveOverride: (() {
        final endWall = DayKeyService.toAccountWallClockFromUtc(end);
        return DateTime(endWall.year, endWall.month, endWall.day, endWall.hour, endWall.minute);
      })(),
      allDayOverride: false,
    );
    await updateBlockWithSync(normalized);
    return normalized;
  }

  Future<void> _logRoutineBlockUploadVerification(Block block) async {
    final isRoutine =
        block.creationMethod.toString().contains('routine') || block.isRoutineDerived;
    if (!isRoutine) return;

    final cloudId = block.cloudId;
    if (cloudId == null || cloudId.isEmpty) {
      print(
        '⚠️ Routine block upload completed but cloudId is missing (localId=${block.id}, title=${block.title})',
      );
      return;
    }

    try {
      final remote = await downloadItemFromFirebase(cloudId);
      if (remote != null) {
        print(
          '✅ Routine block confirmed on Firebase (cloudId=$cloudId, title=${block.title})',
        );
      } else {
        print(
          '⚠️ Routine block upload verification failed (cloudId=$cloudId, title=${block.title})',
        );
      }
    } catch (e) {
      print(
        '⚠️ Failed to verify routine block upload (cloudId=$cloudId, title=${block.title}): $e',
      );
    }
  }

  /// ブロック更新時の同期対応
  Future<void> updateBlockWithSync(Block block) async {
    // UI起点の更新で「ブロック時刻が変わった」場合は、紐づくInboxTaskを前詰めで再配置する。
    // そのために、更新前のローカル状態を保持する（時刻変更判定・cloudId揺れ対策にも使用）。
    Block? oldBlock;
    try {
      oldBlock = BlockService.getBlockById(block.id);
    } catch (_) {}

    final deviceId = await DeviceInfoService.getDeviceId();
    // 同期メタデータを更新
    block.markAsModified(deviceId);

    await BlockCRUDOperations.updateBlockWithSync(block, this);

    // ブロック更新が成功した後に、必要であれば紐づくタスクを再配置して同期キューへ。
    try {
      await BlockTaskRescheduler.rescheduleIfNeeded(
        oldBlock: oldBlock,
        newBlock: block,
      );
    } catch (e) {
      // 再配置失敗はブロック更新自体を失敗扱いにしない（ユーザーの編集を守る）
      print('⚠️ BlockTaskRescheduler failed: $e');
    }
  }

  /// ブロック削除時の同期対応（通常のブロック用 - 論理削除）
  Future<void> deleteBlockWithSync(String blockId) async {
    return BlockCRUDOperations.deleteBlockWithSync(blockId, this);
  }

  /// ルーティン由来ブロックの物理削除（論理削除フラグを使わない）
  Future<void> deleteRoutineBlockPhysically(String blockId) async {
    return BlockRoutineManager.deleteRoutineBlockPhysically(blockId, this);
  }

  /// ローカルブロックを削除する（同期処理で使用）
  @override
  Future<void> deleteLocalItem(Block item) async {
    return BlockLocalDataManager.deleteLocalItem(item);
  }

  /// ルーティンブロックのうち taskId が null のものを削除（移行時データの整理）。
  Future<void> cleanupRoutineBlocksWithNullTaskId() async {
    return BlockRoutineManager.cleanupRoutineBlocksWithNullTaskId(
        this, () => _isSyncing, (value) => _isSyncing = value);
  }

  /// デバイス重複ブロックのクリーンアップ
  Future<void> cleanupDuplicateDeviceBlocks() async {
    return BlockRoutineManager.cleanupDuplicateDeviceBlocks(
        this, () => _isSyncing, (value) => _isSyncing = value);
  }

  /// 特定のルーティンテンプレートのブロックのみを物理削除
  Future<void> deleteRoutineBlocksForTemplateWithSync(
      String routineTemplateId) async {
    // 同期処理の競合を防ぐ
    if (_isSyncing) {
      print('⚠️ Block sync in progress, waiting for completion...');
      int waitCount = 0;
      while (_isSyncing && waitCount < 50) {
        // 最大5秒待機
        await Future.delayed(const Duration(milliseconds: 100));
        waitCount++;
      }
    }

    // 同期フラグを設定
    _isSyncing = true;

    try {
      print(
          '🗑️ Starting PHYSICAL deletion of routine blocks for template: $routineTemplateId');

      // 🔍 PHASE 1: 削除対象の特定
      final blocks = BlockService.getAllBlocks();
      print('🗑️ Total blocks found: ${blocks.length}');

      // 特定のルーティンテンプレートのブロックのみを取得
      final targetRoutineBlocks = blocks
          .where((block) =>
              block.creationMethod == TaskCreationMethod.routine &&
              _isBlockFromTemplate(block, routineTemplateId))
          .toList();

      print(
          '🗑️ Found ${targetRoutineBlocks.length} routine blocks for template $routineTemplateId for PHYSICAL deletion');

      if (targetRoutineBlocks.isEmpty) {
        print('ℹ️ No routine blocks to delete for template $routineTemplateId');
        return;
      }

      // ルーティンブロックの詳細表示
      print('🗑️ Target routine blocks for PHYSICAL deletion:');
      for (final block in targetRoutineBlocks) {
        print(
            '  - "${block.title}" (ID: ${block.id}, cloudId: ${block.cloudId})');
      }

      // 🔍 PHASE 2: Firebase物理削除の実行
      print('🔄 Phase 2: Starting Firebase PHYSICAL deletion...');
      final blocksWithCloudId = targetRoutineBlocks
          .where((block) => block.cloudId != null && block.cloudId!.isNotEmpty)
          .toList();

      int firebaseDeletedCount = 0;
      int firebaseFailedCount = 0;

      for (final block in blocksWithCloudId) {
        try {
          print(
              '🔄 Attempting Firebase PHYSICAL deletion for cloudId: ${block.cloudId}');
          await deleteFromFirebase(block.cloudId!);
          firebaseDeletedCount++;
          print(
              '✅ Firebase PHYSICAL deletion successful for: "${block.title}"');
        } catch (e) {
          firebaseFailedCount++;
          print('❌ Firebase PHYSICAL deletion failed for "${block.title}": $e');
        }
      }

      print(
          '📊 Firebase PHYSICAL deletion results: $firebaseDeletedCount successful, $firebaseFailedCount failed');

      // 🔍 PHASE 3: ローカル物理削除の実行
      print('🔄 Phase 3: Starting local PHYSICAL deletion...');

      try {
        await _deleteRoutineBlocksPhysically(targetRoutineBlocks);
        print(
            '📊 Local PHYSICAL deletion results: ${targetRoutineBlocks.length} successful, 0 failed');
      } catch (e) {
        print('❌ Local PHYSICAL deletion failed: $e');
        rethrow;
      }

      // 🔍 PHASE 4: 最終確認
      print('🔄 Phase 4: Final verification after PHYSICAL deletion...');
      final remainingBlocks = BlockService.getAllBlocks();
      final remainingTargetBlocks = remainingBlocks
          .where((block) =>
              block.creationMethod == TaskCreationMethod.routine &&
              _isBlockFromTemplate(block, routineTemplateId))
          .toList();

      print('🔍 DEBUG: After PHYSICAL deletion verification:');
      print('  - Total blocks remaining: ${remainingBlocks.length}');
      print(
          '  - Target routine blocks remaining: ${remainingTargetBlocks.length}');

      if (remainingTargetBlocks.isEmpty) {
        print(
            '✅ PHYSICAL DELETION SUCCESS: All target routine blocks have been permanently deleted');
      } else {
        final error =
            'PHYSICAL DELETION FAILED: ${remainingTargetBlocks.length} blocks still exist';
        print('❌ $error');
        throw Exception(error);
      }

      // 同期冷却期間を設定
      print('⏳ Waiting for Firebase consistency (3 seconds)...');
      await Future.delayed(const Duration(seconds: 3));

      // 削除時刻を記録（同期冷却のため）
      print('🕒 Deletion time recorded for sync cooldown');

      print('📊 PHYSICAL DELETION SUMMARY for template $routineTemplateId:');
      print('  - Original routine blocks: ${targetRoutineBlocks.length}');
      print(
          '  - Firebase PHYSICAL deletions: $firebaseDeletedCount successful, $firebaseFailedCount failed');
      print(
          '  - Local PHYSICAL deletions: ${targetRoutineBlocks.length} successful, 0 failed');
      print(
          '  - Final remaining target blocks: ${remainingTargetBlocks.length}');

      print(
          '🎉 COMPLETE PHYSICAL DELETION SUCCESS for template $routineTemplateId: All target routine blocks permanently deleted');
    } finally {
      // 🔓 同期フラグを解除
      _isSyncing = false;
      // sync flag released
    }
  }

  /// ブロックが特定のルーティンテンプレートから作成されたかチェック
  bool _isBlockFromTemplate(Block block, String routineTemplateId) {
    print(
        '🔍 DEBUG: Checking block "${block.title}" (taskId: ${block.taskId}) for template: $routineTemplateId');

    // taskIdからルーティンタスクを取得してテンプレートIDを確認
    if (block.isRoutineDerived &&
        block.taskId != null &&
        block.taskId!.isNotEmpty) {
      final v2 = RoutineTaskV2Service.getById(block.taskId!);
      if (v2 != null) {
        print(
          '🔍 DEBUG: RoutineTask lookup result: ${v2.name} (templateId: ${v2.routineTemplateId})',
        );
        if (v2.routineTemplateId == routineTemplateId) {
          print(
            '✅ DEBUG: Block "${block.title}" MATCHES template $routineTemplateId',
          );
          return true;
        }
        print(
          '❌ DEBUG: Block "${block.title}" does NOT match template $routineTemplateId',
        );
        print('   - Block template: ${v2.routineTemplateId}');
        print('   - Target template: $routineTemplateId');
        return false;
      }
      // V2-only: legacyタスク参照は撤去
    } else {
      print(
          '❌ DEBUG: Block "${block.title}" is not marked as routine-derived or has no taskId');
    }
    return false;
  }

  /// ルーティンブロックをローカルから物理削除
  Future<void> _deleteRoutineBlocksPhysically(List<Block> routineBlocks) async {
    print('🗑️ DEBUG: Attempting to delete ${routineBlocks.length} blocks');

    int localDeletedCount = 0;
    int localFailedCount = 0;

    // 効率的なバッチ削除を試行
    if (routineBlocks.length > 5) {
      print(
          '🔄 Attempting batch PHYSICAL deletion for ${routineBlocks.length} blocks...');
      try {
        final blockIds = routineBlocks.map((block) => block.id).toList();
        await BlockService.deleteBlocks(blockIds);

        // バッチ削除後の確認
        int remainingCount = 0;
        for (final block in routineBlocks) {
          final stillExists = BlockService.getBlockById(block.id);
          if (stillExists == null) {
            localDeletedCount++;
          } else {
            localFailedCount++;
            remainingCount++;
          }
        }

        print(
            '🗑️ DEBUG: Bulk deletion completed: $localDeletedCount deleted, $remainingCount failed');

        // バッチ削除で失敗したものは個別削除
        if (remainingCount > 0) {
          print(
              '🔄 Attempting individual PHYSICAL deletion for remaining ${remainingCount} blocks...');
          for (final block in routineBlocks) {
            final stillExists = BlockService.getBlockById(block.id);
            if (stillExists != null) {
              try {
                print(
                    '🗑️ DEBUG: Attempting to delete block with ID: ${block.id}');
                await BlockService.deleteBlock(block.id);
                final finalCheck = BlockService.getBlockById(block.id);
                if (finalCheck == null) {
                  localDeletedCount++;
                  localFailedCount--;
                }
              } catch (e) {
                print(
                    '❌ Individual PHYSICAL deletion failed for "${block.title}": $e');
              }
            }
          }
        }
      } catch (batchError) {
        print('❌ Batch PHYSICAL deletion failed: $batchError');
        print('🔄 Falling back to individual PHYSICAL deletion...');
        // バッチ削除失敗時は個別削除にフォールバック
        localDeletedCount = 0;
        localFailedCount = 0;
      }
    }

    // 少数の場合または バッチ削除失敗時は個別削除
    if (routineBlocks.length <= 5 || localDeletedCount == 0) {
      for (final block in routineBlocks) {
        try {
          print('🗑️ DEBUG: Attempting to delete block with ID: ${block.id}');
          print(
              '🗑️ DEBUG: Deleting block: "${block.title}" (ID: ${block.id})');
          await BlockService.deleteBlock(block.id);

          // 削除確認
          final deletedBlock = BlockService.getBlockById(block.id);
          if (deletedBlock == null) {
            print(
                '✅ DEBUG: Block successfully deleted from local storage: "${block.title}" (ID: ${block.id})');
            localDeletedCount++;

            // TaskProviderに更新を通知
            print('📢 DEBUG: Notifying TaskProvider of block update');
            BlockUtilities.notifyTaskProviderUpdate();
          } else {
            print(
                '❌ DEBUG: Block still exists after deletion attempt: "${block.title}" (ID: ${block.id})');
            localFailedCount++;
          }
        } catch (e) {
          print(
              '❌ DEBUG: Exception during block deletion: "${block.title}" (ID: ${block.id}) - $e');
          localFailedCount++;
        }
      }
    }

    // 最終的なTaskProvider通知
    print('📢 DEBUG: Notifying TaskProvider of block update');
    BlockUtilities.notifyTaskProviderUpdate();

    if (localFailedCount > 0) {
      throw Exception('Failed to delete ${localFailedCount} blocks locally');
    }
  }

  /// すべてのルーティンブロックを物理削除（既存のメソッド）
  Future<void> deleteRoutineBlocksWithSync() async {
    return BlockRoutineManager.deleteRoutineBlocksWithSync(
        this, () => _isSyncing, (value) => _isSyncing = value);
  }

  /// 日付範囲でのブロック同期
  // Removed in Phase 8: use dayKeys-based sync only.

  /// プロジェクト別ブロック同期
  Future<SyncResult> syncBlocksByProject(String projectId) async {
    return BlockSyncOperations.syncBlocksByProject(projectId, this);
  }

  /// ブロック完了状態の同期対応
  Future<void> markBlockCompletedWithSync(
      String blockId, bool isCompleted) async {
    return BlockSyncOperations.markBlockCompletedWithSync(
        blockId, isCompleted, this);
  }

  /// Blockの同期処理をオーバーライド（削除直後の再ダウンロード防止）
  @override
  Future<SyncResult> performSync({
    bool forceFullSync = false,
    bool uploadLocalChanges = true,
  }) async {
    return BlockSyncOperations.performSync(
      this,
      deleteBlockWithSync,
      forceFullSync: forceFullSync,
      uploadLocalChanges: uploadLocalChanges,
    );
  }

  /// すべてのBlockを同期
  static Future<SyncResult> syncAllBlocks() async {
    final syncService = BlockSyncService();
    return BlockSyncOperations.syncAllBlocks(
        syncService, () => _isSyncing, (value) => _isSyncing = value);
  }

  /// ブロックの変更を監視
  Stream<List<Block>> watchBlockChanges() {
    return _watcher.watchBlockChanges();
  }

  /// 日付別ブロック監視
  Stream<List<Block>> watchBlocksByDate(DateTime date) {
    return _watcher.watchBlocksByDate(date);
  }

  /// 今日のブロック監視
  Stream<List<Block>> watchTodayBlocks() {
    return _watcher.watchTodayBlocks();
  }

  /// ルーティンテンプレートのブロックを開始日以降で削除（フラグ方式で確実に削除）
  Future<void> deleteRoutineBlocksForTemplateFromDateWithSync(
    String routineTemplateId,
    DateTime startDate,
    String applyDayType,
  ) async {
    // isRoutineDerived + taskId/cloudId をベースに確実に削除
    return BlockRoutineManager
        .deleteRoutineBlocksForTemplateFromDateUsingFlagWithSync(
            routineTemplateId, startDate, this);
  }

  /// 指定した日付集合に属する「ルーティン由来」のブロックのみを物理削除
  /// 条件:
  /// - creationMethod == routine または isRoutineDerived == true
  /// - executionDate が dates のいずれか（年月日一致）
  Future<void> deleteRoutineBlocksByDatesWithSync(
      List<DateTime> dates) async {
    return BlockRoutineManager.deleteRoutineBlocksByDatesUsingFlagWithSync(
        dates, this);
  }

  /// 指定日付のルーティン由来ブロックをバッチで削除（指定日反映の高速化用）
  /// - 対象ブロック取得 → インボックス紐づけ解除 → Firebase 論理削除バッチ（ベストエフォート）
  /// - ローカル削除は **取得した全件** に対して必ず実行（Firebase 成否・cloudId の有無に依存しない）
  Future<void> deleteRoutineBlocksByDatesWithSyncBatch(
      List<DateTime> dates) async {
    final blocks = BlockRoutineManager.getRoutineBlocksForDates(dates);
    if (blocks.isEmpty) return;
    for (final b in blocks) {
      await BlockRoutineManager.unlinkInboxForBlock(b);
    }
    await deleteRoutineBlocksFromFirebaseBatch(blocks);
    final allIds = blocks.map((b) => b.id).toList();
    await BlockService.deleteBlocks(allIds);
    BlockUtilities.notifyTaskProviderUpdate();
  }

  /// ルーティンブロックの Firebase 論理削除をバッチで実行（最大500件ずつ）
  /// 戻り値: コミットに成功したブロックの id のリスト
  Future<List<String>> deleteRoutineBlocksFromFirebaseBatch(
      List<Block> blocks) async {
    if (blocks.isEmpty) return [];
    const int chunkSize = 500;
    final now = DateTime.now().toUtc().toIso8601String();
    final result = <String>[];
    for (int i = 0; i < blocks.length; i += chunkSize) {
      final end = (i + chunkSize).clamp(0, blocks.length);
      if (end <= i) break;
      final chunk = blocks.sublist(i, end);
      final batch = FirebaseFirestore.instance.batch();
      for (final b in chunk) {
        if (b.cloudId == null || b.cloudId!.isEmpty) continue;
        final docRef = userCollection.doc(b.cloudId!);
        final updateData = <String, dynamic>{
          'isDeleted': true,
          'lastModified': now,
        };
        batch.set(docRef, updateData, SetOptions(merge: true));
      }
      try {
        await batch.commit();
        for (final b in chunk) {
          if (b.cloudId != null && b.cloudId!.isNotEmpty) result.add(b.id);
        }
        try {
          SyncKpi.writes += chunk.length;
        } catch (_) {}
      } catch (e) {
        print('❌ Batch logical delete for routine blocks failed: $e');
      }
    }
    return result;
  }

  /// ルーティンブロックを Firebase にバッチでアップロード（最大500件ずつ）
  /// 成功したブロックは lastSynced を更新してローカルに保存。失敗したチャンクは Outbox に積む。
  Future<void> uploadRoutineBlocksToFirebaseBatch(List<Block> blocks) async {
    if (blocks.isEmpty) return;
    const int chunkSize = 500;
    final now = DateTime.now();
    for (int i = 0; i < blocks.length; i += chunkSize) {
      final end = (i + chunkSize).clamp(0, blocks.length);
      if (end <= i) break;
      final chunk = blocks.sublist(i, end);
      final batch = FirebaseFirestore.instance.batch();
      for (final b in chunk) {
        if (b.cloudId == null || b.cloudId!.isEmpty) continue;
        final docRef = userCollection.doc(b.cloudId!);
        batch.set(docRef, b.toFirestoreWriteMap(), SetOptions(merge: true));
      }
      try {
        await batch.commit();
        try {
          SyncKpi.writes += chunk.length;
        } catch (_) {}
        for (final b in chunk) {
          b.lastSynced = now;
        }
        await BlockService.batchPutBlocks(toUpdate: chunk, toAdd: []);
      } catch (e) {
        print('❌ Batch upload for routine blocks failed: $e');
        for (final b in chunk) {
          try {
            await BlockOutboxManager.enqueue(b, 'create');
          } catch (_) {}
        }
      }
    }
  }

  /// Firebaseから指定期間のブロックを直接取得（ローカルへ保存しない）
  Future<List<Block>> fetchBlocksByDateRangeServer(
      DateTime startDate, DateTime endDate) async {
    try {
      final List<Block> results = [];
      QuerySnapshot? querySnapshot;
      try {
        querySnapshot = await userCollection
            .where('isDeleted', isEqualTo: false)
            .where('executionDate',
                isGreaterThanOrEqualTo: startDate.toIso8601String())
            .where('executionDate',
                isLessThanOrEqualTo: endDate.toIso8601String())
            .get(const GetOptions(source: Source.server));
      } catch (e) {
        // IMPORTANT: 失敗時に黙って全件取得へフォールバックしない（read爆発防止）
        print('❌ fetchBlocksByDateRangeServer failed (no full fallback): $e');
        return [];
      }

      for (final doc in querySnapshot.docs) {
        try {
          final data = doc.data() as Map<String, dynamic>;
          data['cloudId'] = doc.id;
          final block = createFromCloudJson(data);
          final d = DateTime(block.executionDate.year,
              block.executionDate.month, block.executionDate.day);
          final inRange = (!d.isBefore(startDate)) && (!d.isAfter(endDate));
          if (inRange) results.add(block);
        } catch (_) {}
      }
      return results;
    } catch (e) {
      print('❌ fetchBlocksByDateRangeServer failed: $e');
      return [];
    }
  }

  static String _dayKey(DateTime date) {
    final d = DateTime(date.year, date.month, date.day);
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }

  static bool _belongsToDay(Block b, String dayKey) {
    try {
      final keys = b.dayKeys;
      if (keys != null && keys.contains(dayKey)) return true;
    } catch (_) {}
    try {
      // legacy fallback
      return b.executionDate.year.toString().padLeft(4, '0') +
              '-' +
              b.executionDate.month.toString().padLeft(2, '0') +
              '-' +
              b.executionDate.day.toString().padLeft(2, '0') ==
          dayKey;
    } catch (_) {
      return false;
    }
  }

  /// monthKey でのブロック同期（レポート用）
  /// [monthKey]: 'YYYY-MM' 形式の文字列（例: '2025-01'）
  Future<SyncResult> syncBlocksByMonthKey(String monthKey) async {
    try {
      await BlockService.initialize();
    } catch (_) {}

    QuerySnapshot<Object?> snap;
    try {
      snap = await userCollection
          .where('monthKeys', arrayContains: monthKey)
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 30));
    } catch (e) {
      // フォールバック: executionDate 範囲で月を取得
      final parts = monthKey.split('-');
      if (parts.length == 2) {
        final year = int.tryParse(parts[0]);
        final month = int.tryParse(parts[1]);
        if (year != null && month != null) {
          final monthStartUtc = DateTime.utc(year, month, 1);
          final monthEndUtc = DateTime.utc(year, month + 1, 1);
          try {
            snap = await userCollection
                .where('executionDate', isGreaterThanOrEqualTo: monthStartUtc.toIso8601String())
                .where('executionDate', isLessThan: monthEndUtc.toIso8601String())
                .get(const GetOptions(source: Source.server))
                .timeout(const Duration(seconds: 30));
          } catch (e2) {
            return SyncResult(success: false, error: 'block month fetch failed: $e2', failedCount: 1);
          }
        } else {
          return SyncResult(success: false, error: 'invalid monthKey format: $monthKey', failedCount: 1);
        }
      } else {
        return SyncResult(success: false, error: 'invalid monthKey format: $monthKey', failedCount: 1);
      }
    }
    try {
      SyncKpi.queryReads += snap.docs.length;
    } catch (_) {}

    // local index
    final locals = BlockService.getAllBlocks();
    final byCloudId = <String, Block>{};
    final byId = <String, Block>{};
    for (final b in locals) {
      byId[b.id] = b;
      final cid = b.cloudId;
      if (cid != null && cid.isNotEmpty) {
        byCloudId[cid] = b;
      }
    }

    int applied = 0;
    int failed = 0;
    final remoteCloudIds = <String>{};

    for (final doc in snap.docs) {
      try {
        final raw = doc.data();
        if (raw is! Map<String, dynamic>) continue;
        final data = Map<String, dynamic>.from(raw);
        data['cloudId'] = doc.id;
        final remote = createFromCloudJson(data);
        final cid = doc.id;
        remoteCloudIds.add(cid);

        if (remote.isDeleted == true) {
          final local = byCloudId[cid] ?? byId[remote.id];
          if (local != null) {
            await deleteLocalItem(local);
            applied++;
          }
          continue;
        }

        final local = byCloudId[cid] ?? byId[remote.id];
        if (local == null) {
          await saveToLocal(remote);
          applied++;
          continue;
        }

        // Remote newer? (prefer version, then lastModified)
        final bool remoteNewer = remote.version > local.version ||
            (remote.version == local.version && remote.lastModified.isAfter(local.lastModified));
        if (remoteNewer) {
          await saveToLocal(remote);
          applied++;
        }
      } catch (_) {
        failed++;
      }
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
          
          final candidates = locals
              .where((b) => b.isDeleted != true)
              .where((b) {
                final keys = b.monthKeys;
                if (keys != null && keys.contains(monthKey)) return true;
                // フォールバック: executionDate で範囲チェック
                final exec = b.executionDate.toUtc();
                return !exec.isBefore(monthStartUtc) && exec.isBefore(monthEndUtc);
              })
              .toList();
          
          final missingCloudIds = <String>[];
          for (final b in candidates) {
            final cid = b.cloudId;
            if (cid == null || cid.isEmpty) continue; // local-only: keep
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
            QuerySnapshot<Object?> extraSnap;
            try {
              extraSnap = await userCollection
                  .where(FieldPath.documentId, whereIn: chunk)
                  .get(const GetOptions(source: Source.server))
                  .timeout(const Duration(seconds: 15));
            } catch (_) {
              // If whereIn fails (index/limit), skip reconciliation for this chunk.
              continue;
            }
            try {
              SyncKpi.queryReads += extraSnap.docs.length;
            } catch (_) {}

            final returnedIds = <String>{};
            for (final doc in extraSnap.docs) {
              returnedIds.add(doc.id);
              try {
                final raw = doc.data();
                if (raw is! Map<String, dynamic>) continue;
                final data = Map<String, dynamic>.from(raw);
                data['cloudId'] = doc.id;
                final remote = createFromCloudJson(data);

                final local = byCloudId[doc.id] ?? byId[remote.id];
                if (remote.isDeleted == true) {
                  if (local != null) {
                    await deleteLocalItem(local);
                    applied++;
                  }
                  continue;
                }
                if (local == null) {
                  await saveToLocal(remote);
                  applied++;
                  continue;
                }
                final bool remoteNewer = remote.version > local.version ||
                    (remote.version == local.version && remote.lastModified.isAfter(local.lastModified));
                if (remoteNewer) {
                  await saveToLocal(remote);
                  applied++;
                }
              } catch (_) {
                failed++;
              }
            }

            // Not returned => treat as deleted (doc missing)
            for (final id in chunk) {
              if (returnedIds.contains(id)) continue;
              final local = byCloudId[id];
              if (local != null) {
                try {
                  await deleteLocalItem(local);
                  applied++;
                } catch (_) {
                  failed++;
                }
              }
            }
          }
        }
      }
    } catch (_) {}

    return SyncResult(
      success: failed == 0,
      syncedCount: applied,
      failedCount: failed,
      conflicts: const [],
    );
  }

  /// 日付スコープの Block 同期（タイムライン表示用）
  ///
  /// 目的:
  /// - 「表示中の日付」に必要な blocks だけを最新化し、全体差分（lastModified cursor）で
  ///   他日付の更新まで拾って read が増えるのを避ける。
  ///
  /// 挙動:
  /// - dayKeys を優先してサーバーから取得（失敗時は executionDate 範囲でフォールバック）
  /// - isDeleted=true の tombstone はローカルから削除へ反映
  /// - “この日から移動した” ブロックも追従できるよう、ローカルに居るがリモート結果に居ない cloudId は
  ///   docId whereIn で補完取得して更新/削除する（小さく安全な追加read）
  Future<SyncResult> syncBlocksByDayKey(DateTime date) async {
    final dayKey = _dayKey(date);
    try {
      await BlockService.initialize();
    } catch (_) {}

    QuerySnapshot<Object?> snap;
    bool usedDayKeysQuery = false;
    try {
      snap = await userCollection
          .where('dayKeys', arrayContains: dayKey)
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 20));
      usedDayKeysQuery = true;
    } catch (e) {
      // フォールバック: executionDate 範囲（UTC midnight）で日付一致の予定を取得
      final startUtc = DateTime.utc(date.year, date.month, date.day);
      final endUtcExclusive = startUtc.add(const Duration(days: 1));
      try {
        snap = await userCollection
            .where('executionDate', isGreaterThanOrEqualTo: startUtc.toIso8601String())
            .where('executionDate', isLessThan: endUtcExclusive.toIso8601String())
            .get(const GetOptions(source: Source.server))
            .timeout(const Duration(seconds: 20));
      } catch (e2) {
        return SyncResult(success: false, error: 'block day fetch failed: $e2', failedCount: 1);
      }
    }
    try {
      SyncKpi.queryReads += snap.docs.length;
    } catch (_) {}

    // 1日分を一括適用（1件ずつ saveToLocal だと getLocalItemByCloudId で毎回全件読むため遅い）
    final remoteCloudIds = <String>{};
    final normalizedJsonList = <Map<String, dynamic>>[];
    for (final doc in snap.docs) {
      try {
        final raw = doc.data();
        if (raw is! Map<String, dynamic>) continue;
        final data = Map<String, dynamic>.from(raw);
        data['cloudId'] = doc.id;
        remoteCloudIds.add(doc.id);
        final normalized = Map<String, dynamic>.from(
          BlockCloudOperations.normalizeCloudJson(Map<String, dynamic>.from(data)),
        );
        BlockCloudOperations.normalizeTimestamps(normalized);
        normalizedJsonList.add(normalized);
      } catch (_) {}
    }

    int applied = 0;
    int failed = 0;
    try {
      applied = await BlockLocalDataManager.applyRemoteJsonToLocalBatch(normalizedJsonList);
    } catch (_) {
      failed += normalizedJsonList.length;
    }

    // 補正後ローカルを再取得（reconciliation 用）
    final locals = BlockService.getAllBlocks();
    final byCloudId = <String, Block>{};
    final byId = <String, Block>{};
    for (final b in locals) {
      byId[b.id] = b;
      final cid = b.cloudId;
      if (cid != null && cid.isNotEmpty) {
        byCloudId[cid] = b;
      }
    }

    // Evicted / moved-out reconciliation:
    // Local blocks that belong to this day but are not present in remote results could have moved to another day,
    // or been deleted. Fetch them by docId (whereIn) in small batches to update local state.
    try {
      final candidates = locals
          .where((b) => b.isDeleted != true)
          .where((b) => _belongsToDay(b, dayKey))
          .toList();
      final missingCloudIds = <String>[];
      for (final b in candidates) {
        final cid = b.cloudId;
        if (cid == null || cid.isEmpty) continue; // local-only: keep
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
        QuerySnapshot<Object?> extraSnap;
        try {
          extraSnap = await userCollection
              .where(FieldPath.documentId, whereIn: chunk)
              .get(const GetOptions(source: Source.server))
              .timeout(const Duration(seconds: 15));
        } catch (_) {
          // If whereIn fails (index/limit), skip reconciliation for this chunk.
          continue;
        }
        try {
          SyncKpi.queryReads += extraSnap.docs.length;
        } catch (_) {}

        final returnedIds = <String>{};
        for (final doc in extraSnap.docs) {
          returnedIds.add(doc.id);
          try {
            final raw = doc.data();
            if (raw is! Map<String, dynamic>) continue;
            final data = Map<String, dynamic>.from(raw);
            data['cloudId'] = doc.id;
            final remote = createFromCloudJson(data);

            final local = byCloudId[doc.id] ?? byId[remote.id];
            if (remote.isDeleted == true) {
              if (local != null) {
                await deleteLocalItem(local);
                applied++;
              }
              continue;
            }
            if (local == null) {
              await saveToLocal(remote);
              applied++;
              continue;
            }
            final bool remoteNewer = remote.version > local.version ||
                (remote.version == local.version && remote.lastModified.isAfter(local.lastModified));
            if (remoteNewer) {
              await saveToLocal(remote);
              applied++;
            }
          } catch (_) {
            failed++;
          }
        }

        // Not returned => treat as deleted (doc missing)
        for (final id in chunk) {
          if (returnedIds.contains(id)) continue;
          final local = byCloudId[id];
          if (local != null) {
            try {
              await deleteLocalItem(local);
              applied++;
            } catch (_) {
              failed++;
            }
          }
        }
      }
    } catch (_) {}

    // Optional: record a lightweight diagnostic event to help read analysis.
    try {
      await SyncAllHistoryService.recordSimpleEvent(
        type: 'dayScopedFetch',
        reason: 'syncBlocksByDayKey',
        origin: 'BlockSyncService.syncBlocksByDayKey',
        extra: <String, dynamic>{
          'collection': 'blocks',
          'dayKey': dayKey,
          'mode': usedDayKeysQuery ? 'dayKeys' : 'executionDateFallback',
          'docs': snap.docs.length,
          'applied': applied,
          'failed': failed,
        },
      );
    } catch (_) {}

    return SyncResult(
      success: failed == 0,
      syncedCount: applied,
      failedCount: failed,
      conflicts: const [],
    );
  }
}
