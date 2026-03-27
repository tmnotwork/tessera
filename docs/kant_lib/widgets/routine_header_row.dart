import 'package:flutter/material.dart';

import 'routine_table_columns.dart';

class RoutineHeaderRow extends StatelessWidget {
  final String timeZoneName;
  final TimeOfDay startTime;
  final TimeOfDay endTime;
  final String Function(TimeOfDay, TimeOfDay) calculateDuration;
  final bool showTimeColumns;
  final bool showDurationColumn;
  final VoidCallback? onSortTimePressed;
  final List<RoutineTableColumn>? columns;

  const RoutineHeaderRow({
    super.key,
    required this.timeZoneName,
    required this.startTime,
    required this.endTime,
    required this.calculateDuration,
    this.showTimeColumns = true,
    this.showDurationColumn = true,
    this.onSortTimePressed,
    this.columns,
  });

  Widget _buildCell(
    BuildContext context, {
    double? width,
    int? flex,
    required Widget child,
    bool isLast = false,
  }) {
    final container = Container(
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        border: Border(
          right: isLast
              ? BorderSide.none
              : BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: child,
    );
    if (width != null) return SizedBox(width: width, child: container);
    return Expanded(flex: flex ?? 1, child: container);
  }

  Widget _buildHeaderForColumn(
    BuildContext context,
    RoutineTableColumn col, {
    required bool isLast,
  }) {
    switch (col) {
      case RoutineTableColumn.time:
        return _buildCell(
          context,
          width: RoutineTableLayout.timeWidth,
          isLast: isLast,
          child: Row(
            children: [
              const Text(
                '時間',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
              ),
              if (onSortTimePressed != null) ...[
                const Spacer(),
                IconButton(
                  onPressed: onSortTimePressed,
                  icon: const Icon(Icons.sort, size: 16),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 24,
                    minHeight: 24,
                  ),
                  visualDensity: VisualDensity.compact,
                  tooltip: '時刻で並べ替え',
                ),
              ],
            ],
          ),
        );
      case RoutineTableColumn.duration:
        return _buildCell(
          context,
          width: RoutineTableLayout.durationWidth,
          isLast: isLast,
          child: const Text(
            '所要',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
          ),
        );
      case RoutineTableColumn.blockName:
        return _buildCell(
          context,
          flex: RoutineTableLayout.blockNameFlex,
          isLast: isLast,
          child: const Text(
            'ブロック名',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
          ),
        );
      case RoutineTableColumn.project:
        return _buildCell(
          context,
          flex: RoutineTableLayout.projectFlex,
          isLast: isLast,
          child: const Text(
            'プロジェクト',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
          ),
        );
      case RoutineTableColumn.subProject:
        return _buildCell(
          context,
          flex: RoutineTableLayout.subProjectFlex,
          isLast: isLast,
          child: const Text(
            'サブプロジェクト',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
          ),
        );
      case RoutineTableColumn.taskName:
        return _buildCell(
          context,
          flex: RoutineTableLayout.taskNameFlex,
          isLast: isLast,
          child: const Text(
            'タスク名',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
          ),
        );
      case RoutineTableColumn.location:
        return _buildCell(
          context,
          width: RoutineTableLayout.locationWidth,
          isLast: isLast,
          child: const Text(
            '場所',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
          ),
        );
      case RoutineTableColumn.mode:
        return _buildCell(
          context,
          flex: RoutineTableLayout.modeFlex,
          isLast: isLast,
          child: const Text(
            'モード',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
          ),
        );
      case RoutineTableColumn.delete:
        return _buildCell(
          context,
          width: RoutineTableLayout.deleteWidth,
          isLast: isLast,
          child: const Center(
            child: Text(
              '削除',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
            ),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cols = columns ??
        RoutineTableLayout.defaultColumns(
          showTimeColumns: showTimeColumns,
          showDurationColumn: showDurationColumn,
        );

    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(
            Theme.of(context).brightness == Brightness.light ? 1 : 0.2),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Row(
        children: [
          for (int i = 0; i < cols.length; i++)
            _buildHeaderForColumn(
              context,
              cols[i],
              isLast: i == cols.length - 1,
            ),
        ],
      ),
    );
  }
}
