import 'package:flutter/material.dart';
import '../models/routine_shortcut_task_row.dart';

class RoutineTaskDurationDisplay extends StatefulWidget {
  final RoutineShortcutTaskRow task;
  final String Function(TimeOfDay, TimeOfDay) calculateDuration;

  const RoutineTaskDurationDisplay({
    super.key,
    required this.task,
    required this.calculateDuration,
  });

  @override
  State<RoutineTaskDurationDisplay> createState() => _RoutineTaskDurationDisplayState();
}

class _RoutineTaskDurationDisplayState extends State<RoutineTaskDurationDisplay> {
  late TextEditingController _durationController;
  static const double _rowHeight = 36;

  String _formatDuration(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    // 既に括弧付きなら二重にしない（半角/全角どちらも許容）
    final alreadyWrapped =
        (trimmed.startsWith('（') && trimmed.endsWith('）')) ||
            (trimmed.startsWith('(') && trimmed.endsWith(')'));
    if (alreadyWrapped) return trimmed;
    return '（$trimmed）';
  }

  @override
  void initState() {
    super.initState();
    _durationController = TextEditingController(
      text: _formatDuration(
        widget.calculateDuration(widget.task.startTime, widget.task.endTime),
      ),
    );
  }

  @override
  void didUpdateWidget(covariant RoutineTaskDurationDisplay oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newDuration = _formatDuration(
      widget.calculateDuration(widget.task.startTime, widget.task.endTime),
    );
    if (_durationController.text != newDuration) {
      _durationController.text = newDuration;
    }
  }

  @override
  void dispose() {
    _durationController.dispose();
    super.dispose();
  }

  TextStyle _cellTextStyle(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final base = textTheme.bodyMedium ?? const TextStyle();
    final fallbackFamily =
        base.fontFamily ?? textTheme.bodySmall?.fontFamily ?? 'NotoSansJP';
    return base.copyWith(
      fontSize: 12,
      height: 1.0,
      fontFamily: fallbackFamily,
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _rowHeight,
      child: TextField(
        controller: _durationController,
        readOnly: true,
        textAlign: TextAlign.center,
        textAlignVertical: TextAlignVertical.center,
        style: _cellTextStyle(context),
        decoration: const InputDecoration(
          border: InputBorder.none,
          isCollapsed: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 4.0, vertical: 16.0),
          constraints: BoxConstraints(
            minHeight: _rowHeight,
            maxHeight: _rowHeight,
          ),
          hintText: '分',
          hintStyle: TextStyle(fontSize: 12),
        ),
      ),
    );
  }
}
