import 'package:flutter/material.dart';
import '../models/routine_shortcut_task_row.dart';

import '../services/mode_service.dart';

import 'mode_input_field.dart';

class RoutineTaskModeSelector extends StatefulWidget {
  final RoutineShortcutTaskRow task;
  final void Function() onModeChanged;

  const RoutineTaskModeSelector({
    super.key,
    required this.task,
    required this.onModeChanged,
  });

  @override
  State<RoutineTaskModeSelector> createState() =>
      _RoutineTaskModeSelectorState();
}

class _RoutineTaskModeSelectorState extends State<RoutineTaskModeSelector> {
  late TextEditingController _modeController;

  @override
  void initState() {
    super.initState();
    _modeController = TextEditingController(text: _currentModeName());
  }

  @override
  void didUpdateWidget(covariant RoutineTaskModeSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 参照タスクが変わった際に名称を同期
    _modeController.text = _currentModeName();
  }

  @override
  void dispose() {
    _modeController.dispose();
    super.dispose();
  }

  String _currentModeName() {
    if (widget.task.modeId == null) return '';
    final name = ModeService.getModeById(widget.task.modeId!)?.name ?? '';
    final trimmed = name.trim();
    return trimmed == '未設定' ? '' : trimmed;
  }

  @override
  Widget build(BuildContext context) {
    return ModeInputField(
      controller: _modeController,
      hintText: '未設定',
      useOutlineBorder: false,
      withBackground: false,
      height: 32,
      onModeChanged: (modeId) {
        widget.task.modeId = modeId;
        _modeController.text = _currentModeName();
        widget.onModeChanged();
        setState(() {});
      },
      onAutoSave: () {},
    );
  }
}
