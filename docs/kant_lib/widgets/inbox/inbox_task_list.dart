import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/inbox_task.dart' as inbox;
import '../../services/project_service.dart';
import '../../providers/task_provider.dart';

class InboxTaskListWidget extends StatelessWidget {
  final void Function(inbox.InboxTask) onEdit;
  final void Function(inbox.InboxTask) onDelete;
  const InboxTaskListWidget({
    super.key,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer<TaskProvider>(
      builder: (context, taskProvider, child) {
        final tasks = taskProvider.allInboxTasks
            .where((t) => !t.isCompleted)
            .toList();
        if (tasks.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.inbox,
                    size: 64,
                    color: Theme.of(context)
                        .iconTheme
                        .color
                        ?.withOpacity( 0.6)),
                const SizedBox(height: 8),
                Text('インボックスは空です',
                    style: TextStyle(
                        fontSize: 18,
                        color: Theme.of(context).textTheme.bodySmall?.color)),
              ],
            ),
          );
        }
        return ListView.builder(
          itemCount: tasks.length,
          itemBuilder: (context, index) {
            final task = tasks[index];
            final project = task.projectId != null
                ? ProjectService.getProjectById(task.projectId!)
                : null;
            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: ListTile(
                leading: Icon(Icons.inbox,
                    color: Theme.of(context).colorScheme.tertiary),
                title: Text(task.title),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (task.memo != null && task.memo!.isNotEmpty)
                      Text(
                        'メモ: ${task.memo!}',
                        style: TextStyle(
                          color: Theme.of(context).textTheme.bodySmall?.color,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    if (project != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .primary
                              .withOpacity( 0.12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          project.name,
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    if (task.dueDate != null)
                      Text(
                        '期日: ${_formatDate(task.dueDate!)} (${_getDaysUntilDue(task.dueDate!)})',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    Text(
                      '作成日: ${_formatDate(task.createdAt)}',
                      style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).textTheme.bodySmall?.color),
                    ),
                  ],
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: Icon(Icons.edit,
                          color: Theme.of(context).colorScheme.primary),
                      onPressed: () => onEdit(task),
                    ),
                    IconButton(
                      icon: Icon(Icons.delete,
                          color: Theme.of(context).colorScheme.error),
                      onPressed: () => onDelete(task),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  String _formatDate(DateTime date) => '${date.month}/${date.day}';
  String _getDaysUntilDue(DateTime dueDate) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final dueDay = DateTime(dueDate.year, dueDate.month, dueDate.day);
    final difference = dueDay.difference(today);
    if (difference.inDays == 0) return '今日';
    if (difference.inDays == 1) return '明日';
    if (difference.inDays > 1) return 'あと${difference.inDays}日';
    return '期限切れ';
  }
}
