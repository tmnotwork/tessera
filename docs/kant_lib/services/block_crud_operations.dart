import '../models/block.dart';
import 'block_service.dart';
import 'device_info_service.dart';
import 'auth_service.dart';
import 'network_manager.dart';
import 'block_outbox_manager.dart';
import 'block_utilities.dart';
import 'block_routine_manager.dart';
import 'log_service.dart';

/// ブロックのCRUD操作を担当するクラス
class BlockCRUDOperations {
  static const int _maxPlannedTimedMinutes = 48 * 60;

  /// ブロック作成時の同期対応
  static Future<Block> createBlockWithSync({
    required String title,
    required DateTime executionDate,
    required int startHour,
    required int startMinute,
    int estimatedDuration = 60,
    int? workingMinutes,
    bool allDay = false,
    DateTime? startLocalOverride,
    DateTime? endLocalExclusiveOverride,
    dynamic creationMethod, // TaskCreationMethod.manual,
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
    dynamic syncService,
    Future<void> Function(Block block)? verifyUpload,
  }) async {
    try {
      // Final State (planned timed): cap to max 48h to prevent invalid long ranges.
      // UI側でも弾くが、import/旧経路/不正データ流入を防ぐためサービス層でも担保する。
      if (estimatedDuration < 1) {
        estimatedDuration = 1;
      } else if (estimatedDuration > _maxPlannedTimedMinutes) {
        try {
          print(
              '⚠️ planned estimatedDuration too large ($estimatedDuration). Capping to $_maxPlannedTimedMinutes.');
        } catch (_) {}
        estimatedDuration = _maxPlannedTimedMinutes;
      }
      if (workingMinutes != null) {
        if (workingMinutes < 0) {
          workingMinutes = 0;
        } else if (workingMinutes > estimatedDuration) {
          workingMinutes = estimatedDuration;
        }
      }

      final deviceId = await DeviceInfoService.getDeviceId();
      final userId = AuthService.getCurrentUserId();
      if (userId == null) {
        throw Exception('User not authenticated');
      }

      final now = DateTime.now();

      // 並行作成防止のキー生成
      final naturalKey = _generateNaturalKey(
        userId: userId,
        executionDate: executionDate,
        startHour: startHour,
        startMinute: startMinute,
        creationMethod: creationMethod,
        title: title,
        blockName: blockName,
        estimatedDuration: estimatedDuration,
      );

      // 並行作成チェック
      if (_inFlightCreationKeys.contains(naturalKey)) {
        print('⚠️ Block creation already in progress for key: $naturalKey');
        await Future.delayed(const Duration(milliseconds: 100));
        // 再帰的にリトライ（最大3回）
        return createBlockWithSync(
          title: title,
          executionDate: executionDate,
          startHour: startHour,
          startMinute: startMinute,
          estimatedDuration: estimatedDuration,
          workingMinutes: workingMinutes,
          creationMethod: creationMethod,
          projectId: projectId,
          dueDate: dueDate,
          memo: memo,
          subProjectId: subProjectId,
          subProject: subProject,
          modeId: modeId,
          blockName: blockName,
          taskId: taskId,
          isCompleted: isCompleted,
          isEvent: isEvent,
          syncService: syncService,
        );
      }

      _inFlightCreationKeys.add(naturalKey);

      final block = Block(
        id: 'block_${now.millisecondsSinceEpoch}_${now.microsecond}',
        title: title,
        creationMethod: creationMethod,
        projectId: projectId,
        dueDate: dueDate,
        executionDate: executionDate,
        startHour: startHour,
        startMinute: startMinute,
        estimatedDuration: estimatedDuration,
        workingMinutes: workingMinutes,
        allDay: allDay,
        memo: memo,
        createdAt: now,
        lastModified: now,
        userId: userId,
        subProjectId: subProjectId,
        subProject: subProject,
        modeId: modeId,
        blockName: blockName,
        location: location,
        // ルーティン由来では taskId に RoutineTask のIDを保持し、テンプレ判定に使用
        taskId: creationMethod.toString().contains('routine') ? taskId : null,
        isRoutineDerived: creationMethod.toString().contains('routine'),
        isCompleted: isCompleted,
        isEvent: isEvent,
        excludeFromReport: excludeFromReport,
        deviceId: deviceId,
        version: 1,
      );

      // Final State 方向（multi-day）:
      // 作成時点で startAt/endAtExclusive/dayKeys/monthKeys を必ず付与し、
      // 表示/同期の“正”を executionDate ではなく区間/キーへ寄せる。
      final normalized = block.recomputeCanonicalRange(
        startLocalOverride: startLocalOverride,
        endLocalExclusiveOverride: endLocalExclusiveOverride,
        allDayOverride: allDay,
      );
      // keep reference for subsequent operations (cloudId assignment etc.)
      block.startAt = normalized.startAt;
      block.endAtExclusive = normalized.endAtExclusive;
      block.allDay = normalized.allDay;
      block.dayKeys = normalized.dayKeys;
      block.monthKeys = normalized.monthKeys;

      // 生成時のcloudId付与
      // ルーティン由来はデバイス間で一意・決定的になるように docId を固定化
      if (creationMethod.toString().contains('routine') && (taskId != null && taskId.isNotEmpty)) {
        final y = executionDate.year.toString().padLeft(4, '0');
        final m = executionDate.month.toString().padLeft(2, '0');
        final d = executionDate.day.toString().padLeft(2, '0');
        final hh = startHour.toString().padLeft(2, '0');
        final mm = startMinute.toString().padLeft(2, '0');
        block.cloudId = 'blk_rt_${userId}_${taskId}_${y}${m}${d}_${hh}${mm}';
      } else {
        // それ以外は従来通りデバイス由来のユニークID
        block.cloudId = 'blk_${deviceId}_${now.microsecondsSinceEpoch}';
      }

      // ローカル保存
      await BlockService.initialize();
      await BlockService.addBlock(block);

      // イベント作成ログ（通知ログへ記録）
      if (block.isEvent == true) {
        try {
          final y = block.executionDate.year.toString().padLeft(4, '0');
          final m = block.executionDate.month.toString().padLeft(2, '0');
          final d = block.executionDate.day.toString().padLeft(2, '0');
          final hh = block.startHour.toString().padLeft(2, '0');
          final mm = block.startMinute.toString().padLeft(2, '0');
          final name = (block.blockName != null && block.blockName!.isNotEmpty) ? block.blockName! : (block.title.isNotEmpty ? block.title : 'イベント');
          await AppLogService.appendNotification(
              'EVENT CREATE id=${block.id} date=$y-$m-$d start=$hh:$mm dur=${block.estimatedDuration} title="$name"');
        } catch (_) {}
      }

      // Firebase同期
      final isOnline = NetworkManager.isOnline;

      if (isOnline) {
        try {
          await syncService.uploadToFirebase(block);
          // cloudId/lastSynced が更新されたのでローカルにも反映
          await BlockService.updateBlock(block);
          if (verifyUpload != null) {
            try {
              await verifyUpload(block);
            } catch (e) {
              print('⚠️ Failed to run block upload verification: $e');
            }
          }
        } catch (e) {
          print('⚠️ Failed to sync new block to Firebase, enqueueing: $e');
          await BlockOutboxManager.enqueue(block, 'create');
        }
      } else {
        // オフライン時はOutboxへ
        await BlockOutboxManager.enqueue(block, 'create');
      }

      return block;
    } catch (e) {
      print('❌ Failed to create block with sync: $e');
      rethrow;
    } finally {
      try {
        final userId = AuthService.getCurrentUserId() ?? '';
        final naturalKey = _generateNaturalKey(
          userId: userId,
          executionDate: executionDate,
          startHour: startHour,
          startMinute: startMinute,
          creationMethod: creationMethod,
          title: title,
          blockName: blockName,
          estimatedDuration: estimatedDuration,
        );
        _inFlightCreationKeys.remove(naturalKey);
      } catch (e) {
        print('⚠️ Failed to cleanup creation key: $e');
      }
    }
  }

  /// ルーティン反映バッチ用: ブロックを組み立ててローカルに追加するだけ（Firebase・Outboxは呼び出し元で一括処理）
  static Future<Block> createBlockLocalOnly({
    required String title,
    required DateTime executionDate,
    required int startHour,
    required int startMinute,
    int estimatedDuration = 60,
    int? workingMinutes,
    bool allDay = false,
    DateTime? startLocalOverride,
    DateTime? endLocalExclusiveOverride,
    dynamic creationMethod,
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
    bool saveLocally = true,
  }) async {
    if (estimatedDuration < 1) estimatedDuration = 1;
    if (estimatedDuration > _maxPlannedTimedMinutes) {
      estimatedDuration = _maxPlannedTimedMinutes;
    }
    if (workingMinutes != null) {
      if (workingMinutes < 0) workingMinutes = 0;
      if (workingMinutes > estimatedDuration) workingMinutes = estimatedDuration;
    }
    final deviceId = await DeviceInfoService.getDeviceId();
    final userId = AuthService.getCurrentUserId();
    if (userId == null) throw Exception('User not authenticated');
    final now = DateTime.now();
    final block = Block(
      id: 'block_${now.millisecondsSinceEpoch}_${now.microsecond}',
      title: title,
      creationMethod: creationMethod,
      projectId: projectId,
      dueDate: dueDate,
      executionDate: executionDate,
      startHour: startHour,
      startMinute: startMinute,
      estimatedDuration: estimatedDuration,
      workingMinutes: workingMinutes ?? estimatedDuration,
      allDay: allDay,
      memo: memo,
      createdAt: now,
      lastModified: now,
      userId: userId,
      subProjectId: subProjectId,
      subProject: subProject,
      modeId: modeId,
      blockName: blockName,
      location: location,
      taskId: creationMethod.toString().contains('routine') ? taskId : null,
      isRoutineDerived: creationMethod.toString().contains('routine'),
      isCompleted: isCompleted,
      isEvent: isEvent,
      excludeFromReport: excludeFromReport,
      deviceId: deviceId,
      version: 1,
    );
    final normalized = block.recomputeCanonicalRange(
      startLocalOverride: startLocalOverride,
      endLocalExclusiveOverride: endLocalExclusiveOverride,
      allDayOverride: allDay,
    );
    block.startAt = normalized.startAt;
    block.endAtExclusive = normalized.endAtExclusive;
    block.allDay = normalized.allDay;
    block.dayKeys = normalized.dayKeys;
    block.monthKeys = normalized.monthKeys;
    if (creationMethod.toString().contains('routine') &&
        (taskId != null && taskId.isNotEmpty)) {
      final y = executionDate.year.toString().padLeft(4, '0');
      final m = executionDate.month.toString().padLeft(2, '0');
      final d = executionDate.day.toString().padLeft(2, '0');
      final hh = startHour.toString().padLeft(2, '0');
      final mm = startMinute.toString().padLeft(2, '0');
      block.cloudId = 'blk_rt_${userId}_${taskId}_${y}${m}${d}_${hh}${mm}';
    } else {
      block.cloudId = 'blk_${deviceId}_${now.microsecondsSinceEpoch}';
    }
    if (saveLocally) {
      await BlockService.initialize();
      await BlockService.addBlock(block);
    }
    return block;
  }

  /// ブロック更新時の同期対応
  static Future<void> updateBlockWithSync(
      Block block, dynamic syncService) async {
    try {
      // planned timed: enforce max 48h at service layer as well.
      if (block.allDay != true) {
        if (block.estimatedDuration < 1) {
          block.estimatedDuration = 1;
        } else if (block.estimatedDuration > _maxPlannedTimedMinutes) {
          try {
            print(
                '⚠️ planned estimatedDuration too large (${block.estimatedDuration}). Capping to $_maxPlannedTimedMinutes. id=${block.id}');
          } catch (_) {}
          block.estimatedDuration = _maxPlannedTimedMinutes;
        }
        if (block.workingMinutes < 0) {
          block.workingMinutes = 0;
        } else if (block.workingMinutes > block.estimatedDuration) {
          block.workingMinutes = block.estimatedDuration;
        }
      }

      await BlockService.initialize();
      await BlockService.updateBlock(block);

      // Firebase同期
      if (NetworkManager.isOnline) {
        try {
          await syncService.uploadToFirebase(block);
          await BlockService.updateBlock(block); // persist lastSynced
        } catch (e) {
          print('⚠️ Failed to sync updated block to Firebase, enqueueing: $e');
          await BlockOutboxManager.enqueue(block, 'update');
        }
      } else {
        await BlockOutboxManager.enqueue(block, 'update');
      }
    } catch (e) {
      print('❌ Failed to update block with sync: $e');
      rethrow;
    }
  }

  /// ブロック削除時の同期対応（通常のブロック用 - 論理削除）
  static Future<void> deleteBlockWithSync(
      String blockId, dynamic syncService) async {
    try {
      final blocks = BlockService.getAllBlocks();
      final block = blocks.where((b) => b.id == blockId).firstOrNull;
      if (block == null) {
        return;
      }

      // ルーティン由来のブロックは物理削除を使用
      if (block.creationMethod.toString().contains('routine')) {
        await BlockRoutineManager.deleteRoutineBlockPhysically(
            blockId, syncService);
        return;
      }

      // 通常のブロックは論理削除を使用
      final deviceId = await DeviceInfoService.getDeviceId();

      // 論理削除マークを設定
      block.isDeleted = true;
      block.markAsModified(deviceId);

      // ローカル更新
      await BlockService.updateBlock(block);

      // Firebase同期
      if (NetworkManager.isOnline) {
        try {
          await syncService.uploadToFirebase(block);
        } catch (e) {
          print(
              '❌ SYNC DELETE: Failed to sync deleted block to Firebase, enqueueing: $e');
          await BlockOutboxManager.enqueue(block, 'delete');
        }
      } else {
        await BlockOutboxManager.enqueue(block, 'delete');
      }

      // TaskProviderに更新を通知
      BlockUtilities.notifyTaskProviderUpdate();
    } catch (e) {
      print('❌ Failed to delete block with sync: $e');
      rethrow;
    }
  }

  /// 自然キー生成（並行作成防止用）
  static String _generateNaturalKey({
    required String userId,
    required DateTime executionDate,
    required int startHour,
    required int startMinute,
    required dynamic creationMethod,
    required String title,
    String? blockName,
    required int estimatedDuration,
  }) {
    final y = executionDate.year.toString().padLeft(4, '0');
    final m = executionDate.month.toString().padLeft(2, '0');
    final d = executionDate.day.toString().padLeft(2, '0');
    final hh = startHour.toString().padLeft(2, '0');
    final mm = startMinute.toString().padLeft(2, '0');
    return '$userId|$y-$m-$d|$hh:$mm|${creationMethod.toString()}|$title|${blockName ?? ''}|$estimatedDuration';
  }

  // 並行作成防止用のキーセット
  static final Set<String> _inFlightCreationKeys = <String>{};
}
