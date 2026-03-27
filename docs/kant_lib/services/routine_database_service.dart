import '../models/routine_block_v2.dart';
import '../models/routine_task_v2.dart';
import 'routine_block_v2_service.dart';
import 'routine_task_v2_service.dart';

/// ルーティン（V2）のローカル参照ユーティリティ。
///
/// 旧仕様（RoutineTemplate/RoutineTask/legacy同期）は撤去し、V2のみを扱う。
class RoutineDatabaseService {
  RoutineDatabaseService._();

  /// テンプレートIDに紐づくブロック一覧（開始時刻→order順）
  static List<RoutineBlockV2> getBlocksForTemplate(String templateId) {
    final blocks = RoutineBlockV2Service.getAllByTemplate(templateId);
    blocks.sort((a, b) {
      final aStart = a.startTime.hour * 60 + a.startTime.minute;
      final bStart = b.startTime.hour * 60 + b.startTime.minute;
      if (aStart != bStart) return aStart.compareTo(bStart);
      return a.order.compareTo(b.order);
    });
    return blocks;
  }

  /// ブロックIDに紐づくタスク一覧（order順）
  static List<RoutineTaskV2> getTasksForBlock(String blockId) {
    final tasks = RoutineTaskV2Service.getByBlock(blockId);
    tasks.sort((a, b) => a.order.compareTo(b.order));
    return tasks;
  }

  /// テンプレート全体のタスク一覧（ブロック順→タスク順）
  static List<RoutineTaskV2> getTasksForTemplate(String templateId) {
    final blocks = getBlocksForTemplate(templateId);
    final result = <RoutineTaskV2>[];
    for (final block in blocks) {
      result.addAll(getTasksForBlock(block.id));
    }
    return result;
  }
}

