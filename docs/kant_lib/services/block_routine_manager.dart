import '../models/block.dart';
import 'block_service.dart';
import 'data_sync_service.dart';
import '../services/routine_task_v2_service.dart';
import '../services/routine_block_v2_service.dart';
import '../services/inbox_task_service.dart';
import '../services/task_sync_manager.dart';
import 'dart:async';

/// ルーティンブロック関連の処理を担当するクラス
class BlockRoutineManager {
  /// 指定日付集合に属するルーティン由来ブロックのリストを返す（削除バッチ用）
  static List<Block> getRoutineBlocksForDates(List<DateTime> dates) {
    final Set<String> dateLabels = dates
        .map((d) => _normalizeExecutionDateToUtcMidnight(d))
        .map((d) =>
            '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}')
        .toSet();
    final all = BlockService.getAllBlocks();
    return all.where((b) {
      final isRoutine = b.isRoutineDerived == true ||
          b.creationMethod.toString().contains('routine');
      if (!isRoutine) return false;
      final exec = _normalizeExecutionDateToUtcMidnight(b.executionDate);
      final label =
          '${exec.year.toString().padLeft(4, '0')}-${exec.month.toString().padLeft(2, '0')}-${exec.day.toString().padLeft(2, '0')}';
      return dateLabels.contains(label);
    }).toList();
  }

  /// ブロックに紐づくインボックスタスクの紐づけのみ解除（削除バッチ時の事前処理）
  static Future<void> unlinkInboxForBlock(Block block) async {
    if (block.taskId == null || block.taskId!.isEmpty) return;
    try {
      final inboxTask = InboxTaskService.getInboxTask(block.taskId!);
      if (inboxTask != null && inboxTask.blockId == block.id) {
        inboxTask.blockId = null;
        await InboxTaskService.updateInboxTask(inboxTask);
        unawaited(
          TaskSyncManager.syncInboxTaskImmediately(
            inboxTask,
            'update',
            origin: 'BlockRoutineManager.unlinkInboxForBlock',
          ),
        );
      }
    } catch (_) {}
  }

  /// ルーティンブロックを物理削除する
  /// 削除前に、紐づいているインボックスタスクとの紐づけを解除する
  static Future<void> deleteRoutineBlockPhysically(
      String blockId, DataSyncService<Block> syncService) async {
    try {
      final blocks = BlockService.getAllBlocks();
      final block = blocks.where((b) => b.id == blockId).firstOrNull;
      if (block == null) {
        return;
      }

      await unlinkInboxForBlock(block);

      // Firebase から論理削除
      if (block.cloudId != null) {
        try {
          await syncService.deleteFromFirebase(block.cloudId!);
        } catch (e) {
          // continue
        }
      }

      // ローカルから物理削除
      await BlockService.deleteBlock(block.id);
    } catch (e) {
      rethrow;
    }
  }

  /// ルーティンブロックのうち taskId が null のものを削除（移行時データの整理）。
  static Future<void> cleanupRoutineBlocksWithNullTaskId(
      DataSyncService<Block> syncService,
      bool Function() isSyncing,
      void Function(bool) setSyncing) async {
    // 同期処理の競合を防ぐ
    if (isSyncing()) {
      int waitCount = 0;
      while (isSyncing() && waitCount < 50) {
        await Future.delayed(const Duration(milliseconds: 100));
        waitCount++;
      }
    }

    setSyncing(true);

    try {
      final blocks = BlockService.getAllBlocks();

      // taskId が null のルーティンブロックを検索
      final blocksWithNullTaskId = blocks
          .where((block) =>
              block.creationMethod.toString().contains('routine') &&
              block.taskId == null)
          .toList();

      if (blocksWithNullTaskId.isEmpty) {
        return;
      }

      // Firebase から削除
      for (final block in blocksWithNullTaskId) {
        if (block.cloudId != null) {
          try {
            await syncService.deleteFromFirebase(block.cloudId!);
          } catch (e) {
            // continue
          }
        }
      }

      // ローカルから削除
      await _deleteRoutineBlocksPhysically(blocksWithNullTaskId, syncService);

      // 事後確認
      final afterBlocks = BlockService.getAllBlocks();
      final remaining = afterBlocks
          .where((b) =>
              b.creationMethod.toString().contains('routine') &&
              b.taskId == null)
          .length;
      // remaining count for internal state only
    } finally {
      setSyncing(false);
    }
  }

  /// デバイス重複ブロックのクリーンアップ
  static Future<void> cleanupDuplicateDeviceBlocks(
      DataSyncService<Block> syncService,
      bool Function() isSyncing,
      void Function(bool) setSyncing) async {
    // 同期処理の競合を防ぐ
    if (isSyncing()) {
      int waitCount = 0;
      while (isSyncing() && waitCount < 50) {
        await Future.delayed(const Duration(milliseconds: 100));
        waitCount++;
      }
    }

    setSyncing(true);

    try {
      final blocks = BlockService.getAllBlocks();

      // デバイス重複ブロックを検索（ID に _device_ が含まれるもの）
      final duplicateBlocks =
          blocks.where((block) => block.id.contains('_device_')).toList();

      if (duplicateBlocks.isEmpty) {
        return;
      }

      // Firebase から削除
      for (final block in duplicateBlocks) {
        if (block.cloudId != null) {
          try {
            await syncService.deleteFromFirebase(block.cloudId!);
          } catch (e) {
            // continue
          }
        }
      }

      // ローカルから削除
      await _deleteRoutineBlocksPhysically(duplicateBlocks, syncService);

      // 事後確認
      final afterBlocks = BlockService.getAllBlocks();
      final remaining =
          afterBlocks.where((b) => b.id.contains('_device_')).length;
      // remaining for internal state
    } finally {
      setSyncing(false);
    }
  }

  /// すべてのルーティンブロックを物理削除
  static Future<void> deleteRoutineBlocksWithSync(
      DataSyncService<Block> syncService,
      bool Function() isSyncing,
      void Function(bool) setSyncing) async {
    // 同期処理の競合を防ぐ
    if (isSyncing()) {
      int waitCount = 0;
      while (isSyncing() && waitCount < 50) {
        // 最大5秒待機
        await Future.delayed(const Duration(milliseconds: 100));
        waitCount++;
      }
    }

    // 同期フラグを設定
    setSyncing(true);

    try {
      // 🔍 PHASE 1: 削除対象の特定
      final blocks = BlockService.getAllBlocks();

      final routineBlocks = blocks
          .where(
            (block) => block.creationMethod.toString().contains('routine'),
          )
          .toList();

      if (routineBlocks.isEmpty) {
        return;
      }

      // 🔍 PHASE 2: Firebase物理削除の実行
      final blocksWithCloudId = routineBlocks
          .where((block) => block.cloudId != null && block.cloudId!.isNotEmpty)
          .toList();

      int firebaseDeletedCount = 0;
      int firebaseFailedCount = 0;

      for (final block in blocksWithCloudId) {
        try {
          await syncService.deleteFromFirebase(block.cloudId!);
          firebaseDeletedCount++;
        } catch (e) {
          firebaseFailedCount++;

          // Firebase物理削除失敗時のリトライ（最大3回）
          bool retrySuccess = false;
          for (int retryCount = 1; retryCount <= 3; retryCount++) {
            await Future.delayed(Duration(milliseconds: 500 * retryCount));

            try {
              await syncService.deleteFromFirebase(block.cloudId!);
              retrySuccess = true;
              firebaseDeletedCount++;
              firebaseFailedCount--;
              break;
            } catch (retryError) {
              // continue to next retry
            }
          }
        }
      }

      // 🔍 PHASE 3: ローカル物理削除の実行
      await _deleteRoutineBlocksPhysically(routineBlocks, syncService);

      // Firebase consistency確保のため追加待機
      if (routineBlocks.isNotEmpty) {
        await Future.delayed(const Duration(seconds: 3));
      }

      // Firebase内容の確認（デバッグ用メソッドは呼び出しのみ残す）
      await _debugFirebaseContents(syncService);

      // 最終結果レポート
      final totalOriginalRoutineBlocks = routineBlocks.length;
      final finalRemainingBlocks = BlockService.getAllBlocks()
          .where((block) => block.creationMethod == TaskCreationMethod.routine)
          .length;

      if (finalRemainingBlocks == 0) {
        // success
      } else {
        throw Exception(
            'Failed to physically delete all routine blocks: $finalRemainingBlocks blocks remain');
      }
    } finally {
      setSyncing(false);
    }
  }

  /// ルーティン由来フラグを用いて、特定テンプレートのブロックのみを開始日以降で物理削除
  ///
  /// 仕様:
  /// - `Block.isRoutineDerived == true` を第一条件として使用
  /// - さらに `taskId` -> RoutineTask -> routineTemplateId が一致するものだけを対象
  /// - `taskId` が空だが `cloudId` にルーティン由来フォーマット(blk_rt_...)がある場合はそこから taskId を抽出して判定
  /// - 適用日(weekday/holidayなど)の判定は行わず、開始日以降の同テンプレート由来を確実にクリア
  static Future<void> deleteRoutineBlocksForTemplateFromDateUsingFlagWithSync(
    String routineTemplateId,
    DateTime startDate,
    DataSyncService<Block> syncService,
  ) async {
    final startLabel = startDate.toIso8601String().substring(0, 10);
    // セッション識別用のRunID
    final String _runId = DateTime.now().millisecondsSinceEpoch.toString();

    bool sameOrAfter(DateTime a, DateTime b) {
      // UTCの深夜に正規化してから比較
      final al = _normalizeExecutionDateToUtcMidnight(a);
      final bl = _normalizeExecutionDateToUtcMidnight(b);
      return al.isAfter(bl) || al.isAtSameMomentAs(bl);
    }

    String? templateIdForBlock(Block b) {
      try {
        // 1) 直接の taskId からルーティンタスクを引く
        if (b.taskId != null && b.taskId!.isNotEmpty) {
          // V2: ブロック単位フォールバックは taskId="block:<blockId>" で運用する
          if (b.taskId!.startsWith('block:')) {
            final blockId = b.taskId!.substring('block:'.length);
            final rb = RoutineBlockV2Service.getById(blockId);
            if (rb != null && rb.routineTemplateId.isNotEmpty) {
              return rb.routineTemplateId;
            }
          }

          // V2 taskId
          final v2 = RoutineTaskV2Service.getById(b.taskId!);
          if (v2 != null) {
            return v2.routineTemplateId;
          }
        }

        // 2) cloudId が blk_rt_ 形式なら taskId を抽出して判定
        if (b.cloudId != null && b.cloudId!.startsWith('blk_rt_')) {
          final taskId = _extractTaskIdFromRoutineCloudId(b.cloudId!);
          if (taskId != null && taskId.isNotEmpty) {
            final v2 = RoutineTaskV2Service.getById(taskId);
            if (v2 != null) {
              return v2.routineTemplateId;
            }
          }
        }
      } catch (e) {
        // ignore
      }
      return null;
    }

    try {
      final all = BlockService.getAllBlocks();
      final totalBlocks = all.length;

      // 集計用カウンタ
      int cntRoutineDerived = 0;
      int cntRoutineOnOrAfter = 0;
      int cntWithTaskId = 0;
      int cntTaskFound = 0;
      int cntTaskMissing = 0;
      int cntCloudIdRtPattern = 0;
      int cntMatchedTemplate = 0;
      int cntExcludedTemplateMismatch = 0;
      int cntExcludedIndeterminable = 0;
      int cntExcludedNotRoutine = 0;
      int cntExcludedBeforeStart = 0;
      int cntCreationMethodRoutineFlagFalse =
          0; // creationMethod=routine だが isRoutineDerived!=true

      final candidates = <Block>[];
      final sampleExcludedTemplateMismatch = <Block>[];
      final sampleExcludedIndeterminable = <Block>[];
      final sampleExcludedNotRoutine = <Block>[];
      final sampleExcludedBeforeStart = <Block>[];
      final sampleCreationMethodRoutineFlagFalse = <Block>[];

      // 旧仕様（RoutineTask startTime）に依存した推定は撤去し、
      // 明示的なV2リンク（taskId/cloudId/blockId）で特定できるもののみ対象とする。
      for (final b in all) {
        // 期間判定（開始日以降）
        if (!sameOrAfter(b.executionDate, startDate)) {
          cntExcludedBeforeStart++;
          if (sampleExcludedBeforeStart.length < 3)
            sampleExcludedBeforeStart.add(b);
          continue;
        }
        cntRoutineOnOrAfter++;

        final isRoutineFlag = b.isRoutineDerived == true;
        final isRoutineCreation =
            b.creationMethod.toString().contains('routine');

        if (!isRoutineFlag && !isRoutineCreation) {
          cntExcludedNotRoutine++;
          if (sampleExcludedNotRoutine.length < 3)
            sampleExcludedNotRoutine.add(b);
          continue;
        }

        if (isRoutineFlag) {
          cntRoutineDerived++;
        } else if (isRoutineCreation) {
          // creationMethod=routine だが isRoutineDerived=false
          cntCreationMethodRoutineFlagFalse++;
          if (sampleCreationMethodRoutineFlagFalse.length < 3) {
            sampleCreationMethodRoutineFlagFalse.add(b);
          }
        }

        if (b.taskId != null && b.taskId!.isNotEmpty) cntWithTaskId++;
        if (b.cloudId != null && b.cloudId!.startsWith('blk_rt_')) {
          cntCloudIdRtPattern++;
        }

        final tid = templateIdForBlock(b);

        // RoutineTaskV2 の存在確認メトリクス（統計用）
        final taskId = (b.taskId != null && b.taskId!.isNotEmpty)
            ? b.taskId!
            : _extractTaskIdFromRoutineCloudId(b.cloudId ?? '') ?? '';
        if (taskId.isNotEmpty) {
          final v2 = RoutineTaskV2Service.getById(taskId);
          if (v2 != null) {
            cntTaskFound++;
          } else {
            cntTaskMissing++;
          }
        }

        final matchesTemplate = (tid == routineTemplateId);
        if (matchesTemplate) {
          candidates.add(b);
          cntMatchedTemplate++;
        } else {
          if ((isRoutineFlag || isRoutineCreation) && tid == null) {
            cntExcludedIndeterminable++;
            if (sampleExcludedIndeterminable.length < 3) {
              sampleExcludedIndeterminable.add(b);
            }
          } else {
            cntExcludedTemplateMismatch++;
            if (sampleExcludedTemplateMismatch.length < 3) {
              sampleExcludedTemplateMismatch.add(b);
            }
          }
        }
      }

      int deleted = 0;
      for (final b in candidates) {
        try {
          await deleteRoutineBlockPhysically(b.id, syncService);
          deleted++;
        } catch (e) {
          // continue with next
        }
      }

      // 事後検証: 開始日以降の routineDerived / creationMethod=routine の残存状況
      try {
        final afterAll = BlockService.getAllBlocks();
        final remainingRoutineDerived = afterAll
            .where((b) =>
                b.isRoutineDerived == true &&
                sameOrAfter(b.executionDate, startDate))
            .toList();
        final remainingCreationMethodRoutineFlagFalse = afterAll
            .where((b) =>
                b.creationMethod.toString().contains('routine') &&
                b.isRoutineDerived != true &&
                sameOrAfter(b.executionDate, startDate))
            .toList();
        // 残存した対象ブロックを再評価（検証用変数は参照のみ、ログ出力は削除済み）
        for (final b
            in afterAll.where((b) => sameOrAfter(b.executionDate, startDate))) {
          final isRoutineFlag = b.isRoutineDerived == true;
          final isRoutineCreation =
              b.creationMethod.toString().contains('routine');
          if (!isRoutineFlag && !isRoutineCreation) continue; // 非対象
          final tid = templateIdForBlock(b);
          const bool legacyTimeMatch = false;
          const bool supersededTimeMatch = false;
          final matchesTemplate = (tid == routineTemplateId);
          final wasCandidate =
              matchesTemplate || legacyTimeMatch || supersededTimeMatch;
          if (!wasCandidate) {
            // was excluded (reason for verification only, no log)
          }
        }
        // use remainingRoutineDerived, remainingCreationMethodRoutineFlagFalse for any future verification
      } catch (e) {
        // verification failed, non-fatal
      }
    } catch (e) {
      rethrow;
    }
  }

  /// executionDateをUTCの深夜（00:00:00 UTC）に正規化
  /// これにより、タイムゾーンの違いによる日付のずれを防ぐ
  static DateTime _normalizeExecutionDateToUtcMidnight(DateTime date) {
    // Blockクラスの正規化メソッドを使用
    return Block.normalizeExecutionDateToUtcMidnight(date);
  }

  /// 指定日のみを対象に「ルーティン由来」のブロックを物理削除する
  /// 条件:
  /// - creationMethod が routine もしくは isRoutineDerived == true
  /// - executionDate が dates のいずれか（年月日一致）
  static Future<void> deleteRoutineBlocksByDatesUsingFlagWithSync(
    List<DateTime> dates,
    DataSyncService<Block> syncService,
  ) async {
    // 正規化（UTCの深夜として統一）
    final Set<String> dateLabels = dates
        .map((d) => _normalizeExecutionDateToUtcMidnight(d))
        .map((d) =>
            '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}')
        .toSet();

    bool sameDay(DateTime a, DateTime b) {
      return a.year == b.year && a.month == b.month && a.day == b.day;
    }

    try {
      final all = BlockService.getAllBlocks();
      int candidates = 0;
      int deleted = 0;

      for (final b in all) {
        final isRoutineFlag = b.isRoutineDerived == true;
        final isRoutineCreation =
            b.creationMethod.toString().contains('routine');
        if (!isRoutineFlag && !isRoutineCreation) {
          continue;
        }

        // executionDateをUTCの深夜に正規化してから比較
        final exec = _normalizeExecutionDateToUtcMidnight(b.executionDate);
        final label =
            '${exec.year.toString().padLeft(4, '0')}-${exec.month.toString().padLeft(2, '0')}-${exec.day.toString().padLeft(2, '0')}';
        if (!dateLabels.contains(label)) {
          continue;
        }

        candidates++;
        try {
          await deleteRoutineBlockPhysically(b.id, syncService);
          deleted++;
        } catch (e) {
          // continue with next
        }
      }
    } catch (e) {
      rethrow;
    }
  }

  /// cloudId: blk_rt_{userId}_{taskId}_{yyyymmdd}_{hhmm} から taskId を抽出
  ///
  /// taskId 自体に `_` が含まれる場合（例: 睡眠の `block:{templateId}_sleep`）は
  /// 末尾の YYYYMMDD（8桁）+ HHMM（4桁）で区切って復元する。
  static String? _extractTaskIdFromRoutineCloudId(String cloudId) {
    try {
      const prefix = 'blk_rt_';
      if (!cloudId.startsWith(prefix)) return null;
      final rest = cloudId.substring(prefix.length);
      final parts = rest.split('_');
      if (parts.length < 4) return null;

      final hhmm = parts.last;
      final ymd = parts[parts.length - 2];
      if (!RegExp(r'^\d{4}$').hasMatch(hhmm)) return null;
      if (!RegExp(r'^\d{8}$').hasMatch(ymd)) return null;

      // parts[0] = userId（Firebase UID は通常 `_` なし）。taskId = その次〜日付手前まで
      if (parts.length == 4) {
        return parts[1];
      }
      return parts.sublist(1, parts.length - 2).join('_');
    } catch (_) {
      return null;
    }
  }

  /// ルーティンブロックの物理削除を実行（内部メソッド）
  static Future<void> _deleteRoutineBlocksPhysically(
      List<Block> routineBlocks, DataSyncService<Block> syncService) async {
    int localDeletedCount = 0;
    int localFailedCount = 0;

    for (final block in routineBlocks) {
      try {
        await BlockService.deleteBlock(block.id);
        localDeletedCount++;

        // 削除確認（デバッグ用の参照のみ、カウントは変更しない）
        try {
          final finalCheck = BlockService.getBlockById(block.id);
          if (finalCheck == null) {
            // success
          }
          // else: block persists (no counter change, same as original)
        } catch (e) {
          // cleanup check error
        }
      } catch (e) {
        localFailedCount++;

        // ローカル物理削除失敗時のリトライ（最大3回）
        bool retrySuccess = false;
        for (int retryCount = 1; retryCount <= 3; retryCount++) {
          await Future.delayed(Duration(milliseconds: 200 * retryCount));

          try {
            await BlockService.deleteBlock(block.id);
            retrySuccess = true;
            localDeletedCount++;
            localFailedCount--;
            break;
          } catch (retryError) {
            // continue to next retry
          }
        }
      }
    }
  }

  /// Firebase内容の確認（デバッグ用・呼び出し元で必要に応じて利用）
  static Future<void> _debugFirebaseContents(
      DataSyncService<Block> syncService) async {
    try {
      await syncService.downloadFromFirebase();
      // 取得のみ行い、デバッグ出力は行わない
    } catch (e) {
      // non-fatal
    }
  }
}
