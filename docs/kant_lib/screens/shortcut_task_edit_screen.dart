// ignore_for_file: use_build_context_synchronously

import 'package:flutter/material.dart';

import '../models/routine_shortcut_task_row.dart';
import '../models/routine_task_v2.dart' as v2task;
import '../services/mode_service.dart';
import '../services/project_service.dart';
import '../services/routine_mutation_facade.dart';
import '../services/routine_task_v2_service.dart';
import '../services/sub_project_service.dart';
import '../widgets/mode_input_field.dart';
import '../widgets/project_input_field.dart';
import '../widgets/sub_project_input_field.dart';

/// ショートカットタスク編集画面（インボックス編集画面のUIに合わせる）。
///
/// - 一覧は「表示カード」、編集は別画面で行う（インボックス方式）
/// - ショートカットでは「タスク」だけを扱い、ブロック表示はしない
class ShortcutTaskEditScreen extends StatefulWidget {
  final String templateId;
  final RoutineShortcutTaskRow displayTask;

  const ShortcutTaskEditScreen({
    super.key,
    required this.templateId,
    required this.displayTask,
  });

  @override
  State<ShortcutTaskEditScreen> createState() => _ShortcutTaskEditScreenState();
}

class _ShortcutTaskEditScreenState extends State<ShortcutTaskEditScreen> {
  final RoutineMutationFacade _mutationFacade = RoutineMutationFacade.instance;

  // InputDecorator(外側 padding 8) + Project/Mode 等の内部 TextField(padding 10) に合わせる
  // => タスク名など通常 TextField の文字開始位置を揃えるための左余白
  static const double _alignedTextStartHorizontalPadding = 18.0;

  late final TextEditingController _titleController;
  late final TextEditingController _projectController;
  late final TextEditingController _subProjectController;
  late final TextEditingController _modeController;
  late final TextEditingController _locationController;
  late final TextEditingController _durationController;

  String? _selectedProjectId;
  String? _selectedSubProjectId;
  String? _selectedSubProjectName;
  String? _selectedModeId;
  int _estimatedDuration = 0;

  v2task.RoutineTaskV2? _findV2() {
    try {
      return RoutineTaskV2Service.getById(widget.displayTask.id);
    } catch (_) {
      return null;
    }
  }

  String _sanitizePlaceholder(String? value) {
    if (value == null) return '';
    final trimmed = value.trim();
    return trimmed == '未設定' ? '' : trimmed;
  }

  @override
  void initState() {
    super.initState();
    final t = widget.displayTask;
    // Mode候補（未初期化のケースに備える）
    try {
      ModeService.initialize();
    } catch (_) {}

    _titleController = TextEditingController(text: t.name);
    _locationController = TextEditingController(text: _sanitizePlaceholder(t.location));

    final v2 = _findV2();
    _estimatedDuration = v2?.estimatedDuration ?? 0;
    _durationController = TextEditingController(text: _estimatedDuration.toString());

    _selectedProjectId =
        (t.projectId != null && t.projectId!.isNotEmpty) ? t.projectId : null;
    final projectName = _selectedProjectId != null
        ? (ProjectService.getProjectById(_selectedProjectId!)?.name ?? '')
        : '';
    _projectController = TextEditingController(text: _sanitizePlaceholder(projectName));

    _selectedSubProjectId = (t.subProjectId != null && t.subProjectId!.isNotEmpty)
        ? t.subProjectId
        : null;
    final subProjectName = _selectedSubProjectId != null
        ? (SubProjectService.getSubProjectById(_selectedSubProjectId!)?.name ?? '')
        : '';
    _selectedSubProjectName =
        _sanitizePlaceholder(subProjectName).isEmpty ? null : subProjectName;
    _subProjectController =
        TextEditingController(text: _sanitizePlaceholder(subProjectName));

    _selectedModeId = (t.modeId != null && t.modeId!.isNotEmpty) ? t.modeId : null;
    final modeName = _selectedModeId != null
        ? (ModeService.getModeById(_selectedModeId!)?.name ?? '')
        : '';
    _modeController = TextEditingController(text: _sanitizePlaceholder(modeName));
  }

  @override
  void dispose() {
    _titleController.dispose();
    _projectController.dispose();
    _subProjectController.dispose();
    _modeController.dispose();
    _locationController.dispose();
    _durationController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('タスク名は必須です')));
      return;
    }

    final v2 = _findV2();
    if (v2 == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('対象タスクが見つかりませんでした')),
      );
      return;
    }

    final parsedMinutes = int.tryParse(_durationController.text.trim());
    if (parsedMinutes == null || parsedMinutes < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('作業時間(分)は0以上の数値で入力してください')),
      );
      return;
    }

    // 既存挙動に合わせる: プロジェクト変更時はサブプロをクリア
    final normalizedProject =
        (_selectedProjectId == null || _selectedProjectId!.isEmpty)
            ? null
            : _selectedProjectId;
    final projectChanged = normalizedProject != v2.projectId;

    final normalizedLocation = _locationController.text.trim();

    final updated = v2.copyWith(
      name: title,
      estimatedDuration: parsedMinutes,
      projectId: normalizedProject,
      subProjectId: projectChanged ? null : _selectedSubProjectId,
      subProject: projectChanged ? null : _selectedSubProjectName,
      modeId: _selectedModeId,
      location: normalizedLocation.isEmpty ? null : normalizedLocation,
    );

    await _mutationFacade.updateTask(updated);
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  Future<void> _confirmDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('削除確認'),
        content: Text('「${_titleController.text.trim().isEmpty ? '(無題)' : _titleController.text.trim()}」を削除しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final v2 = _findV2();
    if (v2 == null) return;
    await _mutationFacade.deleteTask(v2.id, widget.templateId);
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final double unifiedFontSize =
        Theme.of(context).textTheme.titleMedium?.fontSize ?? 16.0;
    const alignedTextContentPadding = EdgeInsets.symmetric(
      horizontal: _alignedTextStartHorizontalPadding,
      vertical: 12,
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('ショートカットタスク編集'),
        actions: [
          IconButton(
            tooltip: '削除',
            icon: const Icon(Icons.delete_outline),
            onPressed: _confirmDelete,
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _titleController,
                style: TextStyle(fontSize: unifiedFontSize),
                decoration: const InputDecoration(
                  labelText: 'タスク名 *',
                  border: OutlineInputBorder(),
                  floatingLabelBehavior: FloatingLabelBehavior.always,
                ).copyWith(
                  isDense: true,
                  contentPadding: alignedTextContentPadding,
                ),
              ),
              const SizedBox(height: 12),
              InputDecorator(
                decoration: InputDecoration(
                  labelText: 'プロジェクト',
                  border: const OutlineInputBorder(),
                  floatingLabelBehavior: FloatingLabelBehavior.always,
                  filled: true,
                  fillColor: Theme.of(context).inputDecorationTheme.fillColor ??
                      Theme.of(context).colorScheme.surfaceContainerHighest,
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                ),
                isEmpty: _projectController.text.isEmpty,
                child: ProjectInputField(
                  controller: _projectController,
                  height: 44,
                  fontSize: unifiedFontSize,
                  includeArchived: false,
                  showAllOnTap: true,
                  onProjectChanged: (projectId) {
                    setState(() {
                      _selectedProjectId = projectId;
                      // プロジェクト変更時はサブプロジェクトをクリア（インボックスと同様）
                      _subProjectController.text = '';
                      _selectedSubProjectId = null;
                      _selectedSubProjectName = null;
                    });
                  },
                  withBackground: false,
                  useOutlineBorder: false,
                ),
              ),
              const SizedBox(height: 12),
              InputDecorator(
                decoration: InputDecoration(
                  labelText: 'サブプロジェクト',
                  border: const OutlineInputBorder(),
                  floatingLabelBehavior: FloatingLabelBehavior.always,
                  filled: true,
                  fillColor: Theme.of(context).inputDecorationTheme.fillColor ??
                      Theme.of(context).colorScheme.surfaceContainerHighest,
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                ),
                isEmpty: _subProjectController.text.isEmpty,
                child: SubProjectInputField(
                  controller: _subProjectController,
                  projectId: _selectedProjectId,
                  height: 44,
                  fontSize: unifiedFontSize,
                  onSubProjectChanged: (subProjectId, subProjectName) {
                    setState(() {
                      _selectedSubProjectId = subProjectId;
                      _selectedSubProjectName = subProjectName;
                    });
                  },
                  withBackground: false,
                  useOutlineBorder: false,
                ),
              ),
              const SizedBox(height: 12),
              InputDecorator(
                decoration: InputDecoration(
                  labelText: 'モード',
                  border: const OutlineInputBorder(),
                  floatingLabelBehavior: FloatingLabelBehavior.always,
                  filled: true,
                  fillColor: Theme.of(context).inputDecorationTheme.fillColor ??
                      Theme.of(context).colorScheme.surfaceContainerHighest,
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                ),
                isEmpty: _modeController.text.isEmpty,
                child: ModeInputField(
                  controller: _modeController,
                  height: 44,
                  fontSize: unifiedFontSize,
                  onModeChanged: (modeId) {
                    setState(() => _selectedModeId = modeId);
                  },
                  withBackground: false,
                  useOutlineBorder: false,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _locationController,
                style: TextStyle(fontSize: unifiedFontSize),
                decoration: const InputDecoration(
                  labelText: '場所',
                  border: OutlineInputBorder(),
                  floatingLabelBehavior: FloatingLabelBehavior.always,
                ).copyWith(
                  isDense: true,
                  contentPadding: alignedTextContentPadding,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _durationController,
                style: TextStyle(fontSize: unifiedFontSize),
                decoration: const InputDecoration(
                  labelText: '作業時間 (分)',
                  border: OutlineInputBorder(),
                  floatingLabelBehavior: FloatingLabelBehavior.always,
                ).copyWith(
                  isDense: true,
                  contentPadding: alignedTextContentPadding,
                ),
                keyboardType: TextInputType.number,
                onChanged: (v) {
                  final val = int.tryParse(v.trim());
                  if (val != null && val >= 0) {
                    setState(() => _estimatedDuration = val);
                  }
                },
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _save,
        tooltip: '保存',
        child: const Icon(Icons.check),
      ),
    );
  }
}

