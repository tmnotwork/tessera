import 'package:flutter/material.dart';
import '../../models/block.dart' as block;
import '../../models/inbox_task.dart' as inbox;
import '../../models/actual_task.dart' as actual;
import '../../providers/task_provider.dart';
import '../../services/project_service.dart';
import '../../services/sub_project_service.dart';

/// スマホ版専用のタスクカード（デスクトップ版に準拠した左アイコン配置）
class MobileTaskCard extends StatelessWidget {
  final dynamic task;
  final TaskProvider taskProvider;
  final VoidCallback? onLongPress;
  final VoidCallback? onShowDetails;
  final VoidCallback? onStart;
  final VoidCallback? onRestart;
  final VoidCallback? onDelete;

  const MobileTaskCard({
    super.key,
    required this.task,
    required this.taskProvider,
    this.onLongPress,
    this.onShowDetails,
    this.onStart,
    this.onRestart,
    this.onDelete,
  });

  bool _isActual() => task is actual.ActualTask;
  bool _isRunning() => _isActual() && (task as actual.ActualTask).isRunning;
  bool _isPaused() => _isActual() && (task as actual.ActualTask).isPaused;
  bool _isCompleted() => _isActual() && (task as actual.ActualTask).isCompleted;

  Color _statusIconColor(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_isActual()) {
      // Actual(実績)は「完了/記録済み」なので、未着手タスク（再生）より目立たせない。
      if (_isRunning()) return scheme.onSurfaceVariant.withOpacity(0.85);
      if (_isPaused()) return scheme.onSurfaceVariant.withOpacity(0.70);
      if (_isCompleted()) return scheme.onSurfaceVariant.withOpacity(0.60);
      return scheme.onSurfaceVariant.withOpacity(0.60);
    }

    // 予定ブロック: イベントは tertiary、通常は primary（=残タスク優先）
    if (task is block.Block && (task as block.Block).isEvent == true) {
      try {
        final b = task as block.Block;
        final start = DateTime(b.executionDate.year, b.executionDate.month,
            b.executionDate.day, b.startHour, b.startMinute);
        final end = start.add(Duration(minutes: b.estimatedDuration));
        final ended = DateTime.now().isAfter(end);
        return ended
            ? scheme.onSurfaceVariant.withOpacity(0.60)
            : scheme.tertiary.withOpacity(0.95);
      } catch (_) {
        return scheme.tertiary.withOpacity(0.95);
      }
    }

    // 残タスク（予定/Inbox）は最優先で目立たせる
    return scheme.primary;
  }

  IconData _getStatusIcon() {
    if (_isActual()) {
      if (_isPaused()) return Icons.pause;
      if (_isCompleted()) return Icons.check_circle;
      if (_isRunning()) return Icons.stop_circle;
      return Icons.check_circle;
    }
    // 予定ブロック: イベントは再生不可
    if (task is block.Block && (task as block.Block).isEvent == true) {
      try {
        final b = task as block.Block;
        final start = DateTime(b.executionDate.year, b.executionDate.month, b.executionDate.day, b.startHour, b.startMinute);
        final end = start.add(Duration(minutes: b.estimatedDuration));
        final ended = DateTime.now().isAfter(end);
        return ended ? Icons.check_circle : Icons.event;
      } catch (_) {
        return Icons.event;
      }
    }
    // 予定ブロック/Inboxは再生
    return Icons.play_circle;
  }

  VoidCallback? _getStatusIconAction() {
    if (_isActual()) {
      if (_isCompleted()) return onRestart; // 完了は再実行
      if (_isPaused()) return onRestart; // 一時停止は再開
      if (_isRunning()) return onShowDetails; // 実行中は編集を開く
      return onShowDetails; // その他の実績も編集を開く
    }
    return onStart; // ブロック/Inboxは開始
  }

  String _getTaskTitle() {
    if (task is actual.ActualTask) return (task as actual.ActualTask).title;
    if (task is inbox.InboxTask) return (task as inbox.InboxTask).title;
    if (task is block.Block) return (task as block.Block).title;
    return '';
  }

  String _getProjectName() {
    String? projectId;
    if (task is actual.ActualTask) {
      projectId = (task as actual.ActualTask).projectId;
    }
    if (task is inbox.InboxTask) {
      projectId = (task as inbox.InboxTask).projectId;
    }
    if (task is block.Block) projectId = (task as block.Block).projectId;
    if (projectId == null || projectId.isEmpty) return '';
    final p = ProjectService.getProjectById(projectId);
    return p?.name ?? '';
  }

  String _getSubProjectName() {
    String? subName;
    String? subId;
    if (task is actual.ActualTask) {
      subName = (task as actual.ActualTask).subProject;
      subId = (task as actual.ActualTask).subProjectId;
    } else if (task is block.Block) {
      subName = (task as block.Block).subProject;
      subId = (task as block.Block).subProjectId;
    } else if (task is inbox.InboxTask) {
      subId = (task as inbox.InboxTask).subProjectId;
    }
    if (subName != null && subName.isNotEmpty) return subName;
    if (subId == null || subId.isEmpty) return '';
    return SubProjectService.getSubProjectById(subId)?.name ?? '';
  }

  String _getLocationText() {
    if (task is actual.ActualTask) return (task as actual.ActualTask).location ?? '';
    if (task is block.Block) return (task as block.Block).location ?? '';
    return '';
  }

  String _fmt2(int v) => v.toString().padLeft(2, '0');

  String _formatHHMM(DateTime dt) => '${_fmt2(dt.hour)}:${_fmt2(dt.minute)}';

  String _getStartTimeText() {
    if (task is actual.ActualTask) {
      final t = task as actual.ActualTask;
      return _formatHHMM(t.startTime.toLocal());
    } else if (task is inbox.InboxTask) {
      final t = task as inbox.InboxTask;
      if (t.startHour != null && t.startMinute != null) {
        return '${_fmt2(t.startHour!)}:${_fmt2(t.startMinute!)}';
      }
      return '—';
    } else if (task is block.Block) {
      final t = task as block.Block;
      return '${_fmt2(t.startHour)}:${_fmt2(t.startMinute)}';
    }
    return '—';
  }

  String _getEndTimeText() {
    if (task is actual.ActualTask) {
      final t = task as actual.ActualTask;
      if (t.endTime != null) return _formatHHMM(t.endTime!.toLocal());
      // 推定（開始 + actualDuration）
      if (t.actualDuration > 0) {
        return _formatHHMM(
            t.startTime.add(Duration(minutes: t.actualDuration)).toLocal());
      }
      return '—';
    } else if (task is inbox.InboxTask) {
      final t = task as inbox.InboxTask;
      if (t.startHour != null && t.startMinute != null) {
        final start = DateTime(0, 1, 1, t.startHour!, t.startMinute!);
        return _formatHHMM(start.add(Duration(minutes: t.estimatedDuration)));
      }
      return '—';
    } else if (task is block.Block) {
      final t = task as block.Block;
      final start = DateTime(0, 1, 1, t.startHour, t.startMinute);
      return _formatHHMM(start.add(Duration(minutes: t.estimatedDuration)));
    }
    return '—';
  }

  String _getDurationText() {
    if (task is actual.ActualTask) {
      final t = task as actual.ActualTask;
      if (t.endTime != null) {
        final mins = t.endTime!.difference(t.startTime).inMinutes;
        return '${mins}分';
      }
      if (t.actualDuration > 0) return '${t.actualDuration}分';
      return '—';
    } else if (task is inbox.InboxTask) {
      final t = task as inbox.InboxTask;
      // InboxTask は「予定専用」: 実績(startTime/endTime)は使わない
      return '${t.estimatedDuration}分';
    } else if (task is block.Block) {
      final t = task as block.Block;
      return '${t.estimatedDuration}分';
    }
    return '—';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final rawTitle = _getTaskTitle();
    final projectName = _getProjectName();
    final subProjectName = _getSubProjectName();
    // 実績ブロック含む：タスク名が空白のときはサブプロジェクト、それも無いときはプロジェクトを表示（表示のみ・代入なし）
    final title = rawTitle.trim().isNotEmpty
        ? rawTitle
        : (subProjectName.isNotEmpty ? subProjectName : projectName);

    final bool isPlannedBlock = task is block.Block;
    final bool isEvent = isPlannedBlock && (task as block.Block).isEvent == true;

    final Color leftAccent = () {
      if (isPlannedBlock) return isEvent ? scheme.tertiary : scheme.primary;
      if (_isActual()) return scheme.outlineVariant;
      // Inbox（=残タスク側）
      return scheme.primary;
    }();

    final List<Color> gradientColors = () {
      // Goal: make planned blocks visually distinct from tasks/actuals on mobile.
      if (isPlannedBlock) {
        return <Color>[
          (isEvent ? scheme.tertiary : scheme.primary).withOpacity(0.12),
          scheme.surfaceContainerHighest,
        ];
      }
      // Actual/Inbox: keep a neutral surface gradient.
      return <Color>[
        scheme.surfaceContainerHighest,
        scheme.surfaceContainerHigh,
      ];
    }();

    return Card(
      // Mobile timeline: reduce horizontal whitespace (requested).
      margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      clipBehavior: Clip.antiAlias,
      child: Ink(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: gradientColors,
          ),
          border: Border(
            left: BorderSide(color: leftAccent, width: 3),
            top: BorderSide(color: theme.dividerColor.withOpacity(0.2)),
            right: BorderSide(color: theme.dividerColor.withOpacity(0.2)),
            bottom: BorderSide(color: theme.dividerColor.withOpacity(0.2)),
          ),
        ),
        child: InkWell(
          // 背景タップで編集画面を開く（ブロック/実績/インボックス共通）
          onTap: onShowDetails,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
              // 左: ステータスアイコン
              SizedBox(
                width: 40,
                child: Center(
                  child: IconButton(
                    icon: Icon(
                      _getStatusIcon(),
                      size: 24,
                      color: _statusIconColor(context),
                    ),
                    onPressed: _getStatusIconAction(),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    tooltip: () {
                      if (_isActual()) {
                        if (_isRunning()) return '実行中';
                        if (_isPaused()) return '再開';
                        if (_isCompleted()) return '完了';
                        return '実績タスク';
                      }
                      if (task is block.Block && (task as block.Block).isEvent == true) {
                        return 'イベント';
                      }
                      return '開始';
                    }(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
                // 中央: タスク名・プロジェクト（2行まで）。3行目（開始/終了/作業時間）は廃止
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // 1行目: タスク名（タップで編集を開く）
                      InkWell(
                        onTap: onShowDetails,
                        child: Text(
                          title,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(height: 4),
                      // 2行目: プロジェクト サブプロジェクト
                      Row(
                        children: [
                        if (projectName.isNotEmpty) ...[
                          Icon(Icons.folder,
                              size: 14,
                              color: theme
                                  .iconTheme
                                  .color
                                  ?.withOpacity( 0.6)),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              projectName,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: theme
                                      .textTheme
                                      .bodySmall
                                      ?.color),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                        if (projectName.isNotEmpty && subProjectName.isNotEmpty)
                          const SizedBox(width: 8),
                        if (subProjectName.isNotEmpty) ...[
                          Icon(Icons.folder_open,
                              size: 14,
                              color: theme
                                  .iconTheme
                                  .color
                                  ?.withOpacity( 0.6)),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              subProjectName,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: theme
                                      .textTheme
                                      .bodySmall
                                      ?.color),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ],
                    ),
                    // 場所（あれば）は2行目の直後に同じスタイルで表示
                    Builder(builder: (context) {
                      final loc = _getLocationText();
                      if (loc.isEmpty) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Row(
                          children: [
                            Icon(Icons.place,
                                size: 14,
                                color: theme
                                    .iconTheme
                                    .color
                                    ?.withOpacity( 0.6)),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                loc,
                                style: TextStyle(
                                    fontSize: 12,
                                    color: theme
                                        .textTheme
                                        .bodySmall
                                        ?.color),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                  ],
                ),
              ),
              // 右端: 作業時間のみ表示
              const SizedBox(width: 8),
              Text(
                _getDurationText(),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: theme.textTheme.bodySmall?.color,
                ),
              ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
