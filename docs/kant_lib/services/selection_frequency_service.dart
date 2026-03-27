import 'dart:async';

import 'actual_task_service.dart';

/// 実績タスク（直近90日）の出現頻度に基づき、プロジェクト / サブプロジェクト / モード候補のソートに使う。
///
/// セッション内メモリキャッシュ。`ActualTaskService.updateStream` で無効化する。
class SelectionFrequencyService {
  SelectionFrequencyService._();

  static const Duration _window = Duration(days: 90);

  static Map<String, int>? _projectCounts;
  static Map<String, int>? _subProjectCounts;
  static Map<String, int>? _modeCounts;

  static StreamSubscription<void>? _subscription;

  /// [ActualTaskService.initialize] の後に呼ぶ。
  static Future<void> initialize() async {
    await _subscription?.cancel();
    _subscription = ActualTaskService.updateStream.listen((_) {
      invalidate();
    });
  }

  /// キャッシュ破棄（次回参照で再集計）
  static void invalidate() {
    _projectCounts = null;
    _subProjectCounts = null;
    _modeCounts = null;
  }

  static int getProjectCount(String projectId) {
    _ensureComputed();
    return _projectCounts![projectId] ?? 0;
  }

  static int getSubProjectCount(String subProjectId) {
    _ensureComputed();
    return _subProjectCounts![subProjectId] ?? 0;
  }

  static int getModeCount(String modeId) {
    _ensureComputed();
    return _modeCounts![modeId] ?? 0;
  }

  static void _ensureComputed() {
    if (_projectCounts != null) return;
    _recompute();
  }

  static void _recompute() {
    final projectCounts = <String, int>{};
    final subProjectCounts = <String, int>{};
    final modeCounts = <String, int>{};

    try {
      final cutoff = DateTime.now().subtract(_window);
      final tasks = ActualTaskService.getAllActualTasks();
      for (final task in tasks) {
        if (task.isDeleted) continue;
        if (task.startTime.isBefore(cutoff)) continue;

        final pid = task.projectId;
        if (pid != null && pid.isNotEmpty) {
          projectCounts[pid] = (projectCounts[pid] ?? 0) + 1;
        }
        final spid = task.subProjectId;
        if (spid != null && spid.isNotEmpty) {
          subProjectCounts[spid] = (subProjectCounts[spid] ?? 0) + 1;
        }
        final mid = task.modeId;
        if (mid != null && mid.isNotEmpty) {
          modeCounts[mid] = (modeCounts[mid] ?? 0) + 1;
        }
      }
    } catch (_) {
      // 未初期化など
    }

    _projectCounts = projectCounts;
    _subProjectCounts = subProjectCounts;
    _modeCounts = modeCounts;
  }
}
