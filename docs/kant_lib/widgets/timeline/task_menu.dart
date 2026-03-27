import 'package:flutter/material.dart';
import '../../models/block.dart' as block;
import '../../models/actual_task.dart' as actual;
import '../../models/inbox_task.dart' as inbox;
import '../../providers/task_provider.dart';
import '../../screens/mobile_task_edit_screen.dart';
import '../../screens/inbox_task_edit_screen.dart';
import '../inbox/inbox_memo_dialog.dart' show showMemoEditorFullScreen;
import 'timeline_helpers.dart';
import 'block_edit_dialog.dart';
import '../../utils/ime_safe_dialog.dart';
import '../../utils/unified_screen_dialog.dart';

class TaskMenu extends StatelessWidget {
  final dynamic task;
  // 予定ブロック文脈（ブロックヘッダーのメニューなどで task が実績になり得るため）
  final block.Block? plannedBlock;
  final TaskProvider taskProvider;
  final VoidCallback? onDelete;
  final VoidCallback? onShowDetails;
  final VoidCallback? onAssignInbox;
  final VoidCallback? onAddTaskToBlock;
  /// true のときダイアログ上部のタスク名タイトルを出さない（PCタイムラインの行メニュー＝anchor 付き表示時）
  final bool omitTitle;

  const TaskMenu({
    super.key,
    required this.task,
    this.plannedBlock,
    required this.taskProvider,
    this.onDelete,
    this.onShowDetails,
    this.onAssignInbox,
    this.onAddTaskToBlock,
    this.omitTitle = false,
  });

  @override
  Widget build(BuildContext context) {
    // showDialog でそのまま出すと内容幅（タイトル文字数）に引っ張られて
    // 「文章分しかない」極端に細いダイアログになることがあるため、
    // 最低限の幅を明示して常に“広く”見えるようにする。
    final screenWidth = MediaQuery.of(context).size.width;
    final available = (screenWidth - 48).clamp(0.0, double.infinity);
    double targetWidth = screenWidth >= 1200 ? 480 : 420;
    if (targetWidth > available) targetWidth = available;
    if (targetWidth < 320) targetWidth = 320;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final neutralTextColor =
        theme.textTheme.bodyMedium?.color ?? scheme.onSurface;
    final neutralIconColor =
        theme.iconTheme.color ?? theme.colorScheme.onSurfaceVariant;
    final dialogTheme = theme.copyWith(
      iconTheme: theme.iconTheme.copyWith(color: neutralIconColor),
      listTileTheme: theme.listTileTheme.copyWith(
        iconColor: neutralIconColor,
        textColor: neutralTextColor,
        titleTextStyle: theme.textTheme.bodyLarge?.copyWith(
          color: neutralTextColor,
        ),
        subtitleTextStyle: theme.textTheme.bodySmall?.copyWith(
          color: neutralTextColor.withOpacity(0.7),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: neutralTextColor),
      ),
    );

    return Theme(
      data: dialogTheme,
      child: AlertDialog(
        title: omitTitle ? null : Text('${task.title}'),
        content: SizedBox(
          width: targetWidth,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 予定ブロックは「編集」を最上段へ（= 最優先アクション）
              if (plannedBlock != null || task is block.Block)
                ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: const Text('予定を編集'),
                  onTap: () async {
                    // メニューを閉じてから編集ダイアログを開く（位置決めダイアログの上に重ねない）
                    final b = plannedBlock ?? (task as block.Block);
                    final navigator = Navigator.of(context, rootNavigator: true);
                    navigator.pop();
                    await Future<void>.delayed(Duration.zero);
                    await showUnifiedScreenDialog<bool>(
                      context: navigator.context,
                      builder: (_) => BlockEditDialog(
                        target: b,
                        taskProvider: taskProvider,
                      ),
                    );
                  },
                ),
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('詳細を表示'),
                onTap: () {
                  Navigator.of(context).pop();
                  onShowDetails?.call();
                },
              ),
              // 予定ブロックヘッダー（スマホ）からメニューを開く場合、
              // task が実績（primary）になり得るため、ブロック文脈の操作は
              // task型に依存せず callback があるときに表示する。
              if (onAddTaskToBlock != null)
                ListTile(
                  leading: const Icon(Icons.playlist_add),
                  title: const Text('新規タスクを追加'),
                  onTap: () async {
                    final navigator = Navigator.of(context, rootNavigator: true);
                    navigator.pop();
                    await Future<void>.delayed(Duration.zero);
                    onAddTaskToBlock?.call();
                  },
                ),
              if (onAssignInbox != null)
                ListTile(
                  leading: const Icon(Icons.add_circle_outline),
                  title: const Text('インボックスから割当'),
                  onTap: () {
                    Navigator.of(context).pop();
                    onAssignInbox?.call();
                  },
                ),
              if (task is actual.ActualTask) ...[
                ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: const Text('編集'),
                  onTap: () async {
                    // メニューを閉じてから編集画面へ（ダイアログの上に重ねない）
                    final navigator = Navigator.of(context, rootNavigator: true);
                    navigator.pop();
                    await Future<void>.delayed(Duration.zero);
                    await showUnifiedScreenDialog<void>(
                      context: navigator.context,
                      builder: (_) => MobileTaskEditScreen(task: task),
                    );
                  },
                ),
              ],
              if (task is block.Block) ...[
                ListTile(
                  leading: const Icon(Icons.comment_outlined),
                  title: const Text('コメントを編集'),
                  onTap: () async {
                    final b = task as block.Block;
                    // メニューを閉じてから全画面編集を開く
                    final navigator = Navigator.of(context, rootNavigator: true);
                    navigator.pop();
                    await Future<void>.delayed(Duration.zero);
                    await showMemoEditorFullScreen(
                      context: navigator.context,
                      initialValue: b.memo,
                      onSave: (memoValue) async {
                        final updated = b.copyWith(
                          memo: memoValue,
                          version: b.version + 1,
                        );
                        await taskProvider.updateBlock(updated);
                      },
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.play_arrow),
                  title: const Text('タスクを開始'),
                  onTap: () {
                    Navigator.of(context).pop();
                    _startTask(context);
                  },
                ),
              ],
              if (task is inbox.InboxTask) ...[
                const Divider(height: 12),
                ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: const Text('編集'),
                  onTap: () async {
                    // メニューを閉じてから編集画面へ（ダイアログの上に重ねない）
                    final navigator = Navigator.of(context, rootNavigator: true);
                    navigator.pop();
                    await Future<void>.delayed(Duration.zero);
                    await showUnifiedScreenDialog<void>(
                      context: navigator.context,
                      builder: (_) =>
                          InboxTaskEditScreen(task: task as inbox.InboxTask),
                    );
                  },
                ),
                if ((task as inbox.InboxTask).isSomeday != true)
                  ListTile(
                    leading: const Icon(Icons.nights_stay),
                    title: const Text('「いつか」にする'),
                    onTap: () async {
                      Navigator.of(context).pop();
                      try {
                        final t = task as inbox.InboxTask;
                        final updated = t.copyWith(
                          isSomeday: true,
                          lastModified: DateTime.now(),
                          version: t.version + 1,
                        );
                        await taskProvider.updateInboxTask(updated);
                      } catch (_) {}
                    },
                  ),
                if ((task as inbox.InboxTask).isCompleted != true)
                  ListTile(
                    leading: const Icon(Icons.check),
                    title: const Text('完了'),
                    onTap: () {
                      Navigator.of(context).pop();
                      _completeTask(context);
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.undo),
                  title: const Text('未割り当てに戻す'),
                  onTap: () async {
                    Navigator.of(context).pop();
                    try {
                      await taskProvider.revertInboxTaskToUnassigned(task.id);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('未割り当てに戻しました')),
                        );
                      }
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('未割り当てに戻せませんでした: $e')),
                        );
                      }
                    }
                  },
                ),
              ],
              if (task is actual.ActualTask && task.isRunning) ...[
                ListTile(
                  leading: const Icon(Icons.pause),
                  title: const Text('一時停止'),
                  onTap: () {
                    Navigator.of(context).pop();
                    _pauseTask(context);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.check),
                  title: const Text('完了'),
                  onTap: () {
                    Navigator.of(context).pop();
                    _completeTask(context);
                  },
                ),
              ],
              if (task is actual.ActualTask && task.isPaused) ...[
                ListTile(
                  leading: const Icon(Icons.check_circle),
                  title: const Text('完了に変更'),
                  onTap: () {
                    Navigator.of(context).pop();
                    _completeTask(context);
                  },
                ),
              ],
              // 完了実績は「中断に変更」で復活 or 新規インボックス生成（ショートカット/予定ブロック由来）
              if (task is actual.ActualTask &&
                  TimelineHelpers.isTaskCompleted(task)) ...[
                ListTile(
                  leading: const Icon(Icons.pause_circle_filled),
                  title: const Text('中断に変更'),
                  onTap: () {
                    Navigator.of(context).pop();
                    _pauseTask(context);
                  },
                ),
              ],
              ListTile(
                leading: const Icon(Icons.delete),
                title: const Text('削除'),
                onTap: () {
                  Navigator.of(context).pop();
                  _showDeleteConfirmDialog(context);
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('キャンセル'),
          ),
        ],
      ),
    );
  }

  void _startTask(BuildContext context) async {
    try {
      if (task is block.Block) {
        await taskProvider.createActualTask(task);
      } else if (task is inbox.InboxTask) {
        // インボックスタスクも実績開始フローへ統一
        await taskProvider.createActualTaskFromInbox(task.id);
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('タスク開始エラー: $e')));
      }
    }
  }

  void _pauseTask(BuildContext context) async {
    try {
      if (task is actual.ActualTask) {
        await taskProvider.pauseActualTask(task.id);
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('タスク一時停止エラー: $e')));
      }
    }
  }

  void _completeTask(BuildContext context) async {
    try {
      if (task is actual.ActualTask) {
        await taskProvider.completeActualTask(task.id);
      } else if (task is inbox.InboxTask) {
        await taskProvider.completeInboxTaskWithZeroActual(task.id);
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('タスク完了エラー: $e')));
      }
    }
  }

  void _showDeleteConfirmDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('削除確認'),
        content: Text('「${_deleteTargetLabel()}」を削除しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(context).pop();

              // 型ごとに確実に削除
              try {
                if (task is block.Block) {
                  await taskProvider.deleteBlock(task.id);
                } else if (task is actual.ActualTask) {
                  await taskProvider.deleteActualTask(task.id);
                } else if (task is inbox.InboxTask) {
                  await taskProvider.deleteInboxTask(task.id);
                } else {
                  onDelete?.call();
                }
              } catch (_) {
                onDelete?.call();
              }
            },
            child: const Text('削除'),
          ),
        ],
      ),
    );
  }

  String _deleteTargetLabel() {
    try {
      // ブロック名 > タスク名 > プロジェクト名 の順で採用
      if (task is block.Block) {
        final b = task as block.Block;
        final blockName = (b.blockName ?? '').trim();
        if (blockName.isNotEmpty) return blockName;
        final title = (b.title).trim();
        if (title.isNotEmpty) return title;
        // プロジェクト名は ID しか持っていない場合があるのでフォールバック表示
        final project = (b.subProject?.trim().isNotEmpty == true)
            ? b.subProject!.trim()
            : (b.projectId ?? '').trim();
        if (project.isNotEmpty) return project;
        return 'このブロック';
      }
      if (task is inbox.InboxTask) {
        final t = task as inbox.InboxTask;
        final title = (t.title).trim();
        if (title.isNotEmpty) return title;
        return 'このタスク';
      }
      if (task is actual.ActualTask) {
        final t = task as actual.ActualTask;
        final title = (t.title).trim();
        if (title.isNotEmpty) return title;
        return 'この実績タスク';
      }
    } catch (_) {}
    return 'この項目';
  }
}
