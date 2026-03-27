import '../models/block.dart';
import 'block_service.dart';

/// ブロックデータの検証・変換・自然キー生成を担当するクラス
class BlockDataValidator {
  static const int _maxPlannedTimedMinutes = 48 * 60;

  /// Blockオブジェクトをサニタイズして安全な値に変換する
  static Block sanitizeBlock(Block block) {
    try {
      final int normalizedEstimated = () {
        final raw = block.estimatedDuration;
        if (raw <= 0) return 60;
        // planned timed only (allDay=false): max 48h
        if (block.allDay != true && raw > _maxPlannedTimedMinutes) {
          return _maxPlannedTimedMinutes;
        }
        return raw;
      }();

      // Create a copy with safe values
      final sanitizedBlock = Block(
        id: block.id,
        title: block.title,
        creationMethod: TaskCreationMethod.manual, // Always use safe default
        projectId: block.projectId,
        dueDate: block.dueDate,
        executionDate: block.executionDate,
        startHour: block.startHour.clamp(0, 23), // Ensure valid hour range
        startMinute:
            block.startMinute.clamp(0, 59), // Ensure valid minute range
        estimatedDuration: normalizedEstimated,
        workingMinutes: block.workingMinutes,
        startAt: block.startAt,
        endAtExclusive: block.endAtExclusive,
        allDay: block.allDay,
        dayKeys: block.dayKeys,
        monthKeys: block.monthKeys,
        memo: block.memo,
        createdAt: block.createdAt,
        lastModified: block.lastModified,
        userId: block.userId,
        subProjectId: block.subProjectId,
        subProject: block.subProject,
        modeId: block.modeId,
        blockName: block.blockName,
        isCompleted: block.isCompleted,
        taskId: block.taskId,
        cloudId: block.cloudId,
        lastSynced: block.lastSynced,
        isDeleted: block.isDeleted,
        deviceId: block.deviceId,
        version: block.version,
        isEvent: block.isEvent,
        isPauseDerived: block.isPauseDerived,
        isRoutineDerived: block.isRoutineDerived,
        isSkipped: block.isSkipped,
      );

      // Try to preserve original creationMethod if it's valid
      try {
        final originalMethodIndex = block.creationMethod.index;
        if (originalMethodIndex >= 0 &&
            originalMethodIndex < TaskCreationMethod.values.length) {
          sanitizedBlock.creationMethod = block.creationMethod;
        }
      } catch (e) {
        // Keep the safe default (manual)
        print(
            '🔧 DEBUG: Using safe default creationMethod due to corruption: $e');
      }

      return sanitizedBlock;
    } catch (e) {
      print('❌ Failed to sanitize block: $e');
      rethrow;
    }
  }

  /// 自然キーを生成（ID/CloudIDが一致しない場合の照合用）
  static String naturalKey(Block block) {
    final y = block.executionDate.year.toString().padLeft(4, '0');
    final m = block.executionDate.month.toString().padLeft(2, '0');
    final d = block.executionDate.day.toString().padLeft(2, '0');
    final hh = block.startHour.toString().padLeft(2, '0');
    final mm = block.startMinute.toString().padLeft(2, '0');
    return '${block.userId}|$y-$m-$d|$hh:$mm|${block.creationMethod.index}|${block.title}|${block.blockName ?? ''}|${block.estimatedDuration}';
  }

  /// 自然キーでローカルブロックを検索（削除されていないもの）
  static Block? findLocalByNaturalKey(Block candidate) {
    final key = naturalKey(candidate);
    for (final b in BlockService.getAllBlocks()) {
      if (!b.isDeleted && naturalKey(b) == key) {
        return b;
      }
    }
    return null;
  }

  /// 自然キーに一致する墓石（削除されたブロック）が存在するかチェック
  static bool existsTombstoneForNaturalKey(Block candidate) {
    final key = naturalKey(candidate);
    for (final b in BlockService.getAllBlocks()) {
      if (b.isDeleted && naturalKey(b) == key) {
        return true;
      }
    }
    return false;
  }

  /// 自然キーに一致するローカル墓石（isDeleted=true）を取得
  static Block? getTombstoneForNaturalKey(Block candidate) {
    final key = naturalKey(candidate);
    for (final b in BlockService.getAllBlocks()) {
      if (b.isDeleted && naturalKey(b) == key) {
        return b;
      }
    }
    return null;
  }
}
