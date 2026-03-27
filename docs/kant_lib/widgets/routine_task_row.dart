// ignore_for_file: use_build_context_synchronously

import 'package:flutter/material.dart';
import '../models/routine_shortcut_task_row.dart';
import 'routine_task_time_input.dart';
import 'routine_task_duration_display.dart';
import 'routine_task_block_name_input.dart';
import 'routine_task_mode_selector.dart';
import 'routine_task_delete_button.dart';
import 'project_input_field.dart';
import 'sub_project_input_field.dart';
import 'inbox/excel_like_title_cell.dart';
import 'routine_table_columns.dart';

class RoutineTaskRow extends StatelessWidget {
  final RoutineShortcutTaskRow task;
  final TextEditingController? blockNameController;
  final TextEditingController? taskNameController;
  final TextEditingController? projectController;
  final TextEditingController? subProjectController;
  final void Function(String) onBlockNameSubmitted;
  final void Function(String) onTaskNameSubmitted;
  final void Function(String)? onTaskNameChanged;
  final TextEditingController? locationController;
  final void Function(String) onLocationSubmitted;
  final void Function(String?) onProjectChanged;
  final void Function(String?, String?) onSubProjectChanged;
  final void Function() onDelete;
  final void Function() onTimeChanged;
  final void Function() onModeChanged;
  final String Function(String?) getProjectName;
  final String Function(String?) getSubProjectName;
  final String Function(TimeOfDay, TimeOfDay) calculateDuration;
  final bool showTimeColumns;
  final bool showDurationColumn;
  final List<RoutineTableColumn>? columns;

  const RoutineTaskRow({
    super.key,
    required this.task,
    required this.blockNameController,
    required this.taskNameController,
    this.projectController,
    this.subProjectController,
    required this.onBlockNameSubmitted,
    required this.onTaskNameSubmitted,
    this.onTaskNameChanged,
    required this.locationController,
    required this.onLocationSubmitted,
    required this.onProjectChanged,
    required this.onSubProjectChanged,
    required this.onDelete,
    required this.onTimeChanged,
    required this.onModeChanged,
    required this.getProjectName,
    required this.getSubProjectName,
    required this.calculateDuration,
    this.showTimeColumns = true,
    this.showDurationColumn = true,
    this.columns,
  });

  String _sanitizePlaceholder(String? value) {
    if (value == null) return '';
    final trimmed = value.trim();
    return trimmed == '未設定' ? '' : trimmed;
  }

  Widget _buildSizedCell(
    BuildContext context, {
    double? width,
    int? flex,
    required Widget child,
    Alignment alignment = Alignment.centerLeft,
    bool isLast = false,
    EdgeInsets padding = const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
  }) {
    final borderColor = Theme.of(context).dividerColor;
    final container = Container(
      alignment: alignment,
      padding: padding,
      decoration: BoxDecoration(
        border: Border(
          right: isLast ? BorderSide.none : BorderSide(color: borderColor),
        ),
      ),
      child: child,
    );
    if (width != null) {
      return SizedBox(width: width, child: container);
    }
    return Expanded(flex: flex ?? 1, child: container);
  }

  Widget _buildCellForColumn(
    BuildContext context,
    RoutineTableColumn col, {
    required bool isLast,
    required TextEditingController locationFieldController,
    required String projectNameText,
    required String subProjectNameText,
  }) {
    switch (col) {
      case RoutineTableColumn.time:
        return _buildSizedCell(
          context,
          width: RoutineTableLayout.timeWidth,
          alignment: Alignment.center,
          padding: EdgeInsets.zero,
          isLast: isLast,
          child: RoutineTaskTimeInput(
            task: task,
            onTimeChanged: onTimeChanged,
          ),
        );
      case RoutineTableColumn.duration:
        return _buildSizedCell(
          context,
          width: RoutineTableLayout.durationWidth,
          alignment: Alignment.center,
          padding: EdgeInsets.zero,
          isLast: isLast,
          child: RoutineTaskDurationDisplay(
            task: task,
            calculateDuration: calculateDuration,
          ),
        );
      case RoutineTableColumn.blockName:
        return _buildSizedCell(
          context,
          flex: RoutineTableLayout.blockNameFlex,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          isLast: isLast,
          child: RoutineTaskBlockNameInput(
            controller:
                blockNameController ?? TextEditingController(text: task.blockName ?? ''),
            onBlockNameSubmitted: onBlockNameSubmitted,
          ),
        );
      case RoutineTableColumn.project:
        return _buildSizedCell(
          context,
          flex: RoutineTableLayout.projectFlex,
          padding: EdgeInsets.zero,
          isLast: isLast,
          child: ProjectInputField(
            controller: projectController ?? TextEditingController(text: projectNameText),
            useOutlineBorder: false,
            includeArchived: false,
            showAllOnTap: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 6.0,
              vertical: 10.0,
            ),
            onProjectChanged: (projectId) => onProjectChanged(projectId),
          ),
        );
      case RoutineTableColumn.subProject:
        return _buildSizedCell(
          context,
          flex: RoutineTableLayout.subProjectFlex,
          padding: EdgeInsets.zero,
          isLast: isLast,
          child: SubProjectInputField(
            controller: subProjectController ?? TextEditingController(text: subProjectNameText),
            projectId: task.projectId ?? '',
            useOutlineBorder: false,
            onSubProjectChanged: (subProjectId, subProjectName) {
              onSubProjectChanged(subProjectId, subProjectName);
            },
          ),
        );
      case RoutineTableColumn.taskName:
        return _buildSizedCell(
          context,
          flex: RoutineTableLayout.taskNameFlex,
          padding: EdgeInsets.zero,
          isLast: isLast,
          child: ExcelLikeTitleCell(
            controller: taskNameController ?? TextEditingController(text: task.name),
            rowHeight: 36,
            borderColor: const Color(0x00000000),
            placeholder: '(無題)',
            onChanged: (value) => onTaskNameChanged?.call(value),
            onCommit: () {
              final value =
                  (taskNameController ?? TextEditingController(text: task.name)).text;
              onTaskNameSubmitted(value);
            },
          ),
        );
      case RoutineTableColumn.location:
        return _buildSizedCell(
          context,
          width: RoutineTableLayout.locationWidth,
          padding: EdgeInsets.zero,
          isLast: isLast,
          child: ExcelLikeTitleCell(
            controller: locationFieldController,
            rowHeight: 36,
            borderColor: const Color(0x00000000),
            placeholder: '未設定',
            onChanged: (_) {},
            onCommit: () {
              onLocationSubmitted(locationFieldController.text);
            },
          ),
        );
      case RoutineTableColumn.mode:
        return _buildSizedCell(
          context,
          flex: RoutineTableLayout.modeFlex,
          padding: EdgeInsets.zero,
          isLast: isLast,
          child: RoutineTaskModeSelector(
            task: task,
            onModeChanged: onModeChanged,
          ),
        );
      case RoutineTableColumn.delete:
        return _buildSizedCell(
          context,
          width: RoutineTableLayout.deleteWidth,
          alignment: Alignment.center,
          isLast: isLast,
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: RoutineTaskDeleteButton(onDelete: onDelete),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (outerContext, outerConstraints) {
        final projectNameText =
            _sanitizePlaceholder(getProjectName(task.projectId));
        final subProjectNameText =
            _sanitizePlaceholder(getSubProjectName(task.subProjectId));
        final providedLocationController = locationController;
        if (providedLocationController != null &&
            providedLocationController.text.trim() == '未設定') {
          providedLocationController.text = '';
        }
        final locationFieldController = providedLocationController ??
            TextEditingController(
              text: _sanitizePlaceholder(task.location),
            );
        final cols = columns ??
            RoutineTableLayout.defaultColumns(
              showTimeColumns: showTimeColumns,
              showDurationColumn: showDurationColumn,
            );

        double focus = 1.0;
        bool _isFocusable(RoutineTableColumn c) {
          switch (c) {
            case RoutineTableColumn.duration:
              return false;
            case RoutineTableColumn.delete:
              return false;
            default:
              return true;
          }
        }

        Widget _wrapFocus(RoutineTableColumn c, Widget child) {
          if (!_isFocusable(c)) return child;
          final wrapped = FocusTraversalOrder(
            order: NumericFocusOrder(focus),
            child: child,
          );
          focus += 1.0;
          return wrapped;
        }

        final row = FocusTraversalGroup(
          policy: OrderedTraversalPolicy(),
          child: SizedBox(
            height: 36,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (int i = 0; i < cols.length; i++)
                  _wrapFocus(
                    cols[i],
                    _buildCellForColumn(
                      context,
                      cols[i],
                      isLast: i == cols.length - 1,
                      locationFieldController: locationFieldController,
                      projectNameText: projectNameText,
                      subProjectNameText: subProjectNameText,
                    ),
                  ),
              ],
            ),
          ),
        );

        return row;
      },
    );
  }
}
