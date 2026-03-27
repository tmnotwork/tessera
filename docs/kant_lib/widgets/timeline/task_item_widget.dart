import 'package:flutter/material.dart';
import '../../models/inbox_task.dart' as inbox;

class TaskItemWidget extends StatelessWidget {
  final inbox.InboxTask task;
  final VoidCallback? onStart;
  final VoidCallback? onLongPress;
  final VoidCallback? onShowDetails;

  const TaskItemWidget({
    super.key,
    required this.task,
    this.onStart,
    this.onLongPress,
    this.onShowDetails,
  });

  @override
  Widget build(BuildContext context) {
    final isCompleted = task.isCompleted;
    final isRunning = task.isRunning;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: InkWell(
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 1行目: カテゴリ/タスク名/詳細ボタン
              Row(
                children: [
                  // 左側アイコン
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: isCompleted ? Theme.of(context).colorScheme.secondary : Theme.of(context).colorScheme.primary,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Icon(
                      isCompleted ? Icons.check : (isRunning ? Icons.stop : Icons.play_arrow),
                      color: Theme.of(context).colorScheme.onPrimary,
                    ),
                  ),
                  const SizedBox(width: 12),

                  // タスク情報
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          task.title,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            decoration:
                                isCompleted ? TextDecoration.lineThrough : null,
                          ),
                        ),
                        if (task.projectId != null)
                          Text(
                            'プロジェクト: ${task.projectId}',
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).textTheme.bodySmall?.color,
                            ),
                          ),
                      ],
                    ),
                  ),

                  // 詳細ボタン
                  IconButton(
                    icon: const Icon(Icons.info_outline),
                    onPressed: onShowDetails,
                  ),
                ],
              ),

              const SizedBox(height: 8),

              // 3行目: 予定開始・予定終了（startHour/startMinute + estimatedDuration）
              if (task.startHour != null && task.startMinute != null)
                Row(
                  children: [
                    Icon(Icons.access_time, size: 16, color: Theme.of(context).iconTheme.color),
                    const SizedBox(width: 4),
                    Text(
                      '開始: ${task.startHour!.toString().padLeft(2, '0')}:${task.startMinute!.toString().padLeft(2, '0')}',
                      style: TextStyle(fontSize: 12, color: Theme.of(context).textTheme.bodySmall?.color),
                    ),
                    const SizedBox(width: 16),
                    Text(
                      '終了: ${DateTime(0, 1, 1, task.startHour!, task.startMinute!).add(Duration(minutes: task.estimatedDuration)).hour.toString().padLeft(2, '0')}:${DateTime(0, 1, 1, task.startHour!, task.startMinute!).add(Duration(minutes: task.estimatedDuration)).minute.toString().padLeft(2, '0')}',
                      style: TextStyle(fontSize: 12, color: Theme.of(context).textTheme.bodySmall?.color),
                    ),
                  ],
                ),

              // 実行ボタン（未完了タスクのみ）
              if (!isCompleted && !isRunning)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: ElevatedButton.icon(
                    onPressed: onStart,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('開始'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      foregroundColor: Theme.of(context).colorScheme.onPrimary,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
