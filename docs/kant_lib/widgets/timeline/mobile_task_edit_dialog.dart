// Deprecated: replaced by full-screen MobileTaskEditScreen for mobile timeline.
// Keeping for backward compatibility where dialog might still be referenced.
import 'package:flutter/material.dart';
import '../../models/block.dart' as block;
import '../../models/actual_task.dart' as actual;
import '../../providers/task_provider.dart';
import '../../services/project_service.dart';

import '../../services/mode_service.dart';
import '../project_input_field.dart';
import '../sub_project_input_field.dart';

class MobileTaskEditDialog extends StatefulWidget {
  final dynamic task;
  final TaskProvider taskProvider;

  const MobileTaskEditDialog(
      {super.key, required this.task, required this.taskProvider});

  @override
  State<MobileTaskEditDialog> createState() => _MobileTaskEditDialogState();
}

class _MobileTaskEditDialogState extends State<MobileTaskEditDialog> {
  late TextEditingController _blockNameController;
  late TextEditingController _titleController;
  late TextEditingController _projectController;
  late TextEditingController _subProjectController;
  late TextEditingController _modeController;
  late TextEditingController _startController;
  late TextEditingController _endController;
  late TextEditingController _durationController;

  String? _selectedProjectId;
  String? _selectedSubProjectId;
  String? _selectedSubProjectName;
  String? _selectedModeId;

  @override
  void initState() {
    super.initState();
    final t = widget.task;
    _blockNameController = TextEditingController(text: _getBlockName(t));
    _titleController = TextEditingController(text: _getTitle(t));
    _selectedProjectId = _getProjectId(t);
    _projectController =
        TextEditingController(text: _getProjectName(_selectedProjectId));
    final sp = _getSubProject(t);
    _selectedSubProjectId = sp.$1;
    _selectedSubProjectName = sp.$2;
    _subProjectController =
        TextEditingController(text: _selectedSubProjectName ?? '');
    _selectedModeId = _getModeId(t);
    _modeController =
        TextEditingController(text: _getModeName(_selectedModeId) ?? '');

    if (t is block.Block) {
      _startController =
          TextEditingController(text: _hhmm(t.startHour, t.startMinute));
      final end = DateTime(t.executionDate.year, t.executionDate.month,
              t.executionDate.day, t.startHour, t.startMinute)
          .add(Duration(minutes: t.estimatedDuration));
      _endController = TextEditingController(text: _hhmm(end.hour, end.minute));
      _durationController =
          TextEditingController(text: t.estimatedDuration.toString());
    } else {
      _startController = TextEditingController();
      _endController = TextEditingController();
      _durationController = TextEditingController();
    }
  }

  @override
  void dispose() {
    _blockNameController.dispose();
    _titleController.dispose();
    _projectController.dispose();
    _subProjectController.dispose();
    _modeController.dispose();
    _startController.dispose();
    _endController.dispose();
    _durationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isBlock = widget.task is block.Block;
    final isActual = widget.task is actual.ActualTask;

    return AlertDialog(
      title: Text(isActual ? '実績の編集' : '予定の編集'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isBlock)
              TextField(
                controller: _blockNameController,
                decoration: const InputDecoration(
                  labelText: 'ブロック名',
                  border: OutlineInputBorder(),
                  floatingLabelBehavior: FloatingLabelBehavior.always,
                ),
              ),
            const SizedBox(height: 12),
            TextField(
              controller: _titleController,
              decoration: const InputDecoration(
                labelText: 'タスク名',
                border: OutlineInputBorder(),
                floatingLabelBehavior: FloatingLabelBehavior.always,
              ),
            ),
            const SizedBox(height: 12),
            // プロジェクト
            InputDecorator(
              decoration: const InputDecoration(
                labelText: 'プロジェクト',
                border: OutlineInputBorder(),
                floatingLabelBehavior: FloatingLabelBehavior.always,
              ),
              isEmpty: _projectController.text.isEmpty,
              child: ProjectInputField(
                controller: _projectController,
                contentPadding: EdgeInsets.zero,
                onProjectChanged: (projectId) {
                  setState(() {
                    _selectedProjectId = projectId;
                  });
                },
                onAutoSave: () {},
                withBackground: false,
                useOutlineBorder: false,
              ),
            ),
            const SizedBox(height: 12),
            // サブプロジェクト
            InputDecorator(
              decoration: const InputDecoration(
                labelText: 'サブプロジェクト',
                border: OutlineInputBorder(),
                floatingLabelBehavior: FloatingLabelBehavior.always,
              ),
              isEmpty: _subProjectController.text.isEmpty,
              child: SubProjectInputField(
                controller: _subProjectController,
                projectId: _selectedProjectId,
                contentPadding: EdgeInsets.zero,
                onSubProjectChanged: (subProjectId, subProjectName) {
                  setState(() {
                    _selectedSubProjectId = subProjectId;
                    _selectedSubProjectName = subProjectName;
                  });
                },
                onAutoSave: () {},
                withBackground: false,
                useOutlineBorder: false,
              ),
            ),
            const SizedBox(height: 12),
            // モード
            TextField(
              controller: _modeController,
              readOnly: true,
              decoration: const InputDecoration(
                labelText: 'モード',
                border: OutlineInputBorder(),
                floatingLabelBehavior: FloatingLabelBehavior.always,
                suffixIcon: Icon(Icons.arrow_drop_down),
              ),
              onTap: _pickMode,
            ),
            if (isBlock) const SizedBox(height: 12),
            if (isBlock)
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _startController,
                      readOnly: true,
                      decoration: const InputDecoration(
                        labelText: '開始時刻',
                        border: OutlineInputBorder(),
                        floatingLabelBehavior: FloatingLabelBehavior.always,
                      ),
                      onTap: () => _pickTime(_startController),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _endController,
                      readOnly: true,
                      decoration: const InputDecoration(
                        labelText: '終了時刻',
                        border: OutlineInputBorder(),
                        floatingLabelBehavior: FloatingLabelBehavior.always,
                      ),
                      onTap: () => _pickTime(_endController),
                    ),
                  ),
                ],
              ),
            if (isBlock) const SizedBox(height: 12),
            if (isBlock)
              TextField(
                controller: _durationController,
                decoration: const InputDecoration(
                  labelText: '予定時間(分)',
                  border: OutlineInputBorder(),
                  floatingLabelBehavior: FloatingLabelBehavior.always,
                ),
                keyboardType: TextInputType.number,
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('キャンセル')),
        ElevatedButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }

  String _getBlockName(dynamic t) => (t is block.Block)
      ? (t.blockName ?? '')
      : (t is actual.ActualTask ? (t.blockName ?? '') : '');
  String _getTitle(dynamic t) =>
      (t is block.Block) ? t.title : (t is actual.ActualTask ? t.title : '');
  String? _getProjectId(dynamic t) => (t is block.Block)
      ? t.projectId
      : (t is actual.ActualTask ? t.projectId : null);
  String? _getModeId(dynamic t) => (t is block.Block)
      ? t.modeId
      : (t is actual.ActualTask ? t.modeId : null);
  String? _getModeName(String? modeId) =>
      modeId == null ? null : ModeService.getModeById(modeId)?.name;
  String _getProjectName(String? projectId) => projectId == null
      ? ''
      : (ProjectService.getProjectById(projectId)?.name ?? '');
  (String?, String?) _getSubProject(dynamic t) {
    if (t is block.Block) return (t.subProjectId, t.subProject);
    if (t is actual.ActualTask) return (t.subProjectId, t.subProject);
    return (null, null);
  }

  Future<void> _pickTime(TextEditingController ctrl) async {
    final now = TimeOfDay.now();
    final picked = await showTimePicker(context: context, initialTime: now);
    if (picked != null) {
      ctrl.text = _hhmm(picked.hour, picked.minute);
    }
  }

  Future<void> _pickMode() async {
    final modes = ModeService.getAllModes();
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('モードを選択'),
        content: SizedBox(
          width: 320,
          height: 240,
          child: ListView.builder(
            itemCount: modes.length,
            itemBuilder: (context, index) {
              final m = modes[index];
              final isSelected = m.id == _selectedModeId;
              return ListTile(
                dense: true,
                title: Text(m.name, style: const TextStyle(fontSize: 12)),
                trailing: isSelected
                    ? Icon(
                        Icons.check,
                        size: 16,
                        color: Theme.of(context).colorScheme.primary,
                      )
                    : null,
                onTap: () => Navigator.pop(context, m.id),
              );
            },
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル'))
        ],
      ),
    );
    if (selected != null) {
      setState(() {
        _selectedModeId = selected;
        _modeController.text = _getModeName(_selectedModeId) ?? '';
      });
    }
  }

  String _hhmm(int h, int m) =>
      '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';

  Future<void> _save() async {
    try {
      final t = widget.task;
      if (t is block.Block) {
        // parse start/end and duration
        final start = _parseHm(_startController.text) ??
            TimeOfDay(hour: t.startHour, minute: t.startMinute);
        final end = _parseHm(_endController.text);
        int duration = int.tryParse(_durationController.text.trim())
            .unwrapOr(t.estimatedDuration);
        if (end != null) {
          final startDt = DateTime(t.executionDate.year, t.executionDate.month,
              t.executionDate.day, start.hour, start.minute);
          final endDt = DateTime(t.executionDate.year, t.executionDate.month,
              t.executionDate.day, end.hour, end.minute);
          final d = endDt.difference(startDt).inMinutes;
          if (d > 0) duration = d;
        }
        final updated = t.copyWith(
          blockName: _blockNameController.text.trim(),
          title: _titleController.text.trim().isEmpty
              ? t.title
              : _titleController.text.trim(),
          projectId: _selectedProjectId,
          subProjectId: _selectedSubProjectId,
          subProject: _selectedSubProjectName,
          modeId: _selectedModeId,
          startHour: start.hour,
          startMinute: start.minute,
          estimatedDuration: duration,
          // lastModified は Service 層で更新
          version: t.version + 1,
        );
        await widget.taskProvider.updateBlock(updated);
      } else if (t is actual.ActualTask) {
        final updated = t.copyWith(
          title: _titleController.text.trim().isEmpty
              ? t.title
              : _titleController.text.trim(),
          projectId: _selectedProjectId,
          subProjectId: _selectedSubProjectId,
          subProject: _selectedSubProjectName,
          modeId: _selectedModeId,
          lastModified: DateTime.now(),
        );
        await widget.taskProvider.updateActualTask(updated);
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('保存に失敗しました: $e')));
      }
    }
  }
}

extension _ParseInt on int? {
  int unwrapOr(int fallback) => this ?? fallback;
}

TimeOfDay? _parseHm(String text) {
  final parts = text.split(':');
  if (parts.length != 2) return null;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (h == null || m == null) return null;
  return TimeOfDay(hour: h.clamp(0, 23), minute: m.clamp(0, 59));
}
