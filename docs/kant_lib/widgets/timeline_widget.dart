import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/block.dart' as block;
import '../models/actual_task.dart' as actual;

import '../providers/task_provider.dart';
import '../widgets/timeline/task_card.dart';

class TimelineWidget extends StatelessWidget {
  final DateTime selectedDate;
  final Function(dynamic) onEditTask;
  final Function(dynamic) onDeleteTask;

  const TimelineWidget({
    super.key,
    required this.selectedDate,
    required this.onEditTask,
    required this.onDeleteTask,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer<TaskProvider>(
      builder: (context, taskProvider, child) {
        final blocks = taskProvider
            .getTasksForDate(selectedDate)
            .whereType<block.Block>()
            .where((b) => b.isCompleted != true)
            .toList();
        final actualTasks = taskProvider.getActualTasksForDate(selectedDate);

        final allTasks = <dynamic>[];

        // 指定された順序で追加：実績タスク > 予定ブロック
        allTasks.addAll(actualTasks);
        allTasks.addAll(blocks);

        // 種別に関わらず開始時刻でソート
        allTasks.sort((a, b) {
          DateTime getTaskTime(dynamic task) {
            if (task is actual.ActualTask) {
              return task.startTime;
            }
            if (task is block.Block) {
              return DateTime(
                task.executionDate.year,
                task.executionDate.month,
                task.executionDate.day,
                task.startHour,
                task.startMinute,
              );
            }
            return DateTime.now();
          }

          return getTaskTime(a).compareTo(getTaskTime(b));
        });

        if (allTasks.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.task,
                    size: 64,
                    color: Theme.of(context)
                        .iconTheme
                        .color
                        ?.withOpacity( 0.6)),
                const SizedBox(height: 16),
                Text('この日のタスクはありません',
                    style: TextStyle(
                        fontSize: 18,
                        color: Theme.of(context).textTheme.bodySmall?.color)),
                Text('新しいタスクを追加してください',
                    style: TextStyle(
                        color: Theme.of(context).textTheme.bodySmall?.color)),
              ],
            ),
          );
        }

        Key _taskKey(dynamic task) {
          if (task is actual.ActualTask) {
            return ValueKey<String>('task:actual:${task.id}');
          }
          if (task is block.Block) {
            return ValueKey<String>('task:block:${task.id}');
          }
          // fallback (should not happen)
          return ValueKey<String>('task:${task.runtimeType}:${task.hashCode}');
        }

        return ListView.builder(
          itemCount: allTasks.length,
          itemBuilder: (context, index) {
            final task = allTasks[index];
            return TaskCard(
              key: _taskKey(task),
              task: task,
              taskProvider: taskProvider,
              onLongPress: () {}, // 長押しメニューは無効化
              onShowDetails: () => onEditTask(task),
              onStart: () {}, // 開始機能は無効化
              onRestart: () {}, // 再開機能は無効化
              onDelete: () => onDeleteTask(task),
            );
          },
        );
      },
    );
  }
}
