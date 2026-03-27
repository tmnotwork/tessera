import 'dart:async';

import 'package:flutter/material.dart';

import '../models/routine_block_v2.dart' as rbv2;
import '../models/routine_task_v2.dart' as rtv2;
import '../models/routine_template_v2.dart';
import '../repositories/routine_editor_repository.dart';
import '../services/auth_service.dart';
import '../services/mode_service.dart';
import '../services/project_service.dart';
import '../services/routine_mutation_facade.dart';
import '../services/sub_project_service.dart';
import '../utils/ime_safe_dialog.dart';
import '../widgets/mode_input_field.dart';
import '../widgets/project_input_field.dart';
import '../widgets/sub_project_input_field.dart';

class RoutineBlockTaskAssignmentTableScreen extends StatefulWidget {
  const RoutineBlockTaskAssignmentTableScreen({
    super.key,
    required this.routine,
    required this.blockId,
  });

  final RoutineTemplateV2 routine;
  final String blockId;

  @override
  State<RoutineBlockTaskAssignmentTableScreen> createState() =>
      _RoutineBlockTaskAssignmentTableScreenState();
}

class _RoutineBlockTaskAssignmentTableScreenState
    extends State<RoutineBlockTaskAssignmentTableScreen> {
  static const double _nameColWidth = 220;
  static const double _durationColWidth = 64;
  static const double _projectColWidth = 170;
  static const double _subProjectColWidth = 170;
  static const double _modeColWidth = 130;
  static const double _locationColWidth = 150;
  static const double _editColWidth = 44;
  static const double _actionColWidth = 44;
  final RoutineEditorRepository _repository = RoutineEditorRepository.instance;
  final RoutineMutationFacade _mutationFacade = RoutineMutationFacade.instance;

  late Stream<RoutineEditorSnapshot> _templateStream;
  RoutineEditorSnapshot? _initialSnapshot;

  final Map<String, TextEditingController> _nameControllers = {};
  final Map<String, TextEditingController> _durationControllers = {};
  final Map<String, TextEditingController> _projectControllers = {};
  final Map<String, TextEditingController> _subProjectControllers = {};
  final Map<String, TextEditingController> _modeControllers = {};
  final Map<String, TextEditingController> _locationControllers = {};
  final Map<String, Timer> _nameSaveTimers = {};
  final Set<String> _pendingProjectClearByTaskId = {};

  @override
  void initState() {
    super.initState();
    _templateStream = _repository.watchTemplate(widget.routine.id);
    _initialSnapshot = _repository.snapshotTemplate(widget.routine.id);
    try {
      ModeService.initialize();
    } catch (_) {}
  }

  @override
  void dispose() {
    for (final t in _nameSaveTimers.values) {
      t.cancel();
    }
    for (final c in _nameControllers.values) {
      c.dispose();
    }
    for (final c in _durationControllers.values) {
      c.dispose();
    }
    for (final c in _projectControllers.values) {
      c.dispose();
    }
    for (final c in _subProjectControllers.values) {
      c.dispose();
    }
    for (final c in _modeControllers.values) {
      c.dispose();
    }
    for (final c in _locationControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<RoutineEditorSnapshot>(
      stream: _templateStream,
      initialData: _initialSnapshot,
      builder: (context, snapshot) {
        final data = snapshot.data ?? _initialSnapshot;
        if (data == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('-タスク登録')),
            body: const Center(child: CircularProgressIndicator()),
          );
        }
        final block = _findBlock(data);
        if (block == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('-タスク登録')),
            body: const Center(child: Text('対象の予定ブロックが見つかりません')),
          );
        }

        final blockTasks = data.tasksForBlock(block.id);
        final visibleIds = blockTasks.map((e) => e.id).toSet();
        final blockTitle = (block.blockName != null &&
                block.blockName!.trim().isNotEmpty)
            ? block.blockName!.trim()
            : '名称未設定';

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _purgeUnusedTaskControllers(visibleIds);
          }
        });

        return Scaffold(
          appBar: AppBar(
            title: Text('$blockTitle-タスク登録'),
          ),
          body: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              _buildBlockSummary(context, block, blockTasks.length),
              const SizedBox(height: 16),
              Text(
                'ルーティンタスク（表で編集）',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              _buildAssignedTaskTable(context, blockTasks),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Center(
                  child: FilledButton.icon(
                    onPressed: () => _addNewRoutineTask(block),
                    icon: const Icon(Icons.add_circle_outline),
                    label: const Text('タスクを追加'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 28, vertical: 14),
                      textStyle: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  rbv2.RoutineBlockV2? _findBlock(RoutineEditorSnapshot snapshot) {
    for (final block in snapshot.blocks) {
      if (block.id == widget.blockId) return block;
    }
    return null;
  }

  String _resolveUserId() {
    final uid = AuthService.getCurrentUserId();
    if (uid != null && uid.isNotEmpty) return uid;
    return widget.routine.userId;
  }

  String _displayText(String? text) {
    final t = text?.trim();
    if (t == null || t.isEmpty) return '';
    return t;
  }

  String _formatDate(DateTime date) {
    final d = date.toLocal();
    final yy = (d.year % 100).toString().padLeft(2, '0');
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '$yy/$mm/$dd';
  }

  String _formatTimeOfDay(TimeOfDay time) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }

  Widget _buildBlockSummary(
    BuildContext context,
    rbv2.RoutineBlockV2 block,
    int taskCount,
  ) {
    final title =
        (block.blockName == null || block.blockName!.trim().isEmpty)
            ? '名称未設定'
            : block.blockName!.trim();
    final project = _displayText(
      block.projectId != null
          ? ProjectService.getProjectById(block.projectId!)?.name
          : null,
    );
    final subProject = _displayText(
      block.subProject ??
          (block.subProjectId != null
              ? SubProjectService.getSubProjectById(block.subProjectId!)?.name
              : null),
    );
    final mode = _displayText(
      block.modeId != null ? ModeService.getModeById(block.modeId!)?.name : null,
    );

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Wrap(
        runSpacing: 6,
        spacing: 12,
        children: [
          Text('予定ブロック: $title'),
          Text(
            '時間: ${_formatTimeOfDay(block.startTime)} - ${_formatTimeOfDay(block.endTime)}',
          ),
          Text('タスク数: $taskCount'),
          if (project.isNotEmpty) Text('プロジェクト: $project'),
          if (subProject.isNotEmpty) Text('サブ: $subProject'),
          if (mode.isNotEmpty) Text('モード: $mode'),
        ],
      ),
    );
  }

  Widget _buildAssignedTaskTable(
    BuildContext context,
    List<rtv2.RoutineTaskV2> tasks,
  ) {
    final theme = Theme.of(context);
    final borderColor = theme.dividerColor;
    final tableWidth = _nameColWidth +
        _durationColWidth +
        _projectColWidth +
        _subProjectColWidth +
        _modeColWidth +
        _locationColWidth +
        _editColWidth +
        _actionColWidth;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: tableWidth,
        child: Column(
          children: [
            _buildTableHeaderRow(
              context,
              const [
                _TableHeader('タスク名', _nameColWidth),
                _TableHeader('所要', _durationColWidth, center: true),
                _TableHeader('プロジェクト', _projectColWidth),
                _TableHeader('サブプロジェクト', _subProjectColWidth),
                _TableHeader('モード', _modeColWidth),
                _TableHeader('場所', _locationColWidth),
                _TableHeader('編集', _editColWidth, center: true),
                _TableHeader('削除', _actionColWidth, center: true),
              ],
            ),
            if (tasks.isEmpty)
              Container(
                width: tableWidth,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  border: Border(
                    left: BorderSide(color: borderColor),
                    right: BorderSide(color: borderColor),
                    bottom: BorderSide(color: borderColor),
                  ),
                ),
                child: Text(
                  'まだタスクがありません',
                  style: theme.textTheme.bodySmall,
                ),
              )
            else
              for (int i = 0; i < tasks.length; i++)
                _buildAssignedTaskRow(
                  context,
                  tasks[i],
                ),
          ],
        ),
      ),
    );
  }

  Widget _buildAssignedTaskRow(
    BuildContext context,
    rtv2.RoutineTaskV2 task,
  ) {
    final theme = Theme.of(context);
    final borderColor = theme.dividerColor;
    const rowHeight = 36.0;

    final projectName = _displayText(
      task.projectId != null ? ProjectService.getProjectById(task.projectId!)?.name : null,
    );
    final subProjectName = _displayText(
      task.subProject ??
          (task.subProjectId != null
              ? SubProjectService.getSubProjectById(task.subProjectId!)?.name
              : null),
    );
    final modeName = _displayText(
      task.modeId != null ? ModeService.getModeById(task.modeId!)?.name : null,
    );

    final nameController = _nameControllers.putIfAbsent(
      task.id,
      () => TextEditingController(text: task.name),
    );
    if (nameController.text != task.name) {
      nameController.text = task.name;
    }

    final durationController = _durationControllers.putIfAbsent(
      task.id,
      () => TextEditingController(text: task.estimatedDuration.toString()),
    );
    final durationText = task.estimatedDuration.toString();
    if (durationController.text != durationText) {
      durationController.text = durationText;
    }

    final projectController =
        _ensureTaskProjectController(task, projectName);

    final subProjectController = _subProjectControllers.putIfAbsent(
      task.id,
      () => TextEditingController(text: subProjectName),
    );
    if (subProjectController.text != subProjectName) {
      subProjectController.text = subProjectName;
    }

    final modeController = _modeControllers.putIfAbsent(
      task.id,
      () => TextEditingController(text: modeName),
    );
    if (modeController.text != modeName) {
      modeController.text = modeName;
    }

    final locationController = _locationControllers.putIfAbsent(
      task.id,
      () => TextEditingController(text: task.location ?? ''),
    );
    final locationValue = task.location ?? '';
    if (locationController.text != locationValue) {
      locationController.text = locationValue;
    }

    Widget cell({
      required double width,
      required Widget child,
      bool center = false,
      bool addRightBorder = true,
      EdgeInsetsGeometry padding = const EdgeInsets.symmetric(horizontal: 8),
    }) {
      return SizedBox(
        width: width,
        child: Container(
          height: rowHeight,
          alignment: center ? Alignment.center : Alignment.centerLeft,
          padding: padding,
          decoration: BoxDecoration(
            border: Border(
              right: addRightBorder
                  ? BorderSide(color: borderColor)
                  : BorderSide.none,
            ),
          ),
          child: child,
        ),
      );
    }

    final hasProject = (task.projectId ?? '').isNotEmpty;
    Widget subProjectInput = SubProjectInputField(
      controller: subProjectController,
      projectId: task.projectId ?? '',
      currentSubProjectId: task.subProjectId,
      useOutlineBorder: false,
      withBackground: false,
      height: 32,
      onSubProjectChanged: (subProjectId, subProjectLabel) async {
        await _applyTaskSubProject(task, subProjectId, subProjectLabel);
      },
    );
    if (!hasProject) {
      subProjectInput = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('先にプロジェクトを設定してください')),
          );
        },
        child: AbsorbPointer(child: subProjectInput),
      );
    }

    return Container(
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: borderColor),
          right: BorderSide(color: borderColor),
          bottom: BorderSide(color: borderColor),
        ),
      ),
      child: Row(
        children: [
          cell(
            width: _nameColWidth,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: TextField(
              controller: nameController,
              style: const TextStyle(fontSize: 12),
              decoration: const InputDecoration(
                border: InputBorder.none,
                isCollapsed: true,
                hintText: 'タスク名',
              ),
              onChanged: (_) {
                _nameSaveTimers[task.id]?.cancel();
                _nameSaveTimers[task.id] = Timer(
                  const Duration(milliseconds: 700),
                  () => _applyTaskName(task, nameController.text),
                );
              },
              onSubmitted: (_) => _applyTaskName(task, nameController.text),
            ),
          ),
          cell(
            width: _durationColWidth,
            center: true,
            child: TextField(
              controller: durationController,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12),
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                border: InputBorder.none,
                isCollapsed: true,
                hintText: '分',
              ),
              onSubmitted: (_) =>
                  _applyTaskDuration(task, durationController.text),
            ),
          ),
          cell(
            width: _projectColWidth,
            child: ProjectInputField(
              controller: projectController,
              useOutlineBorder: false,
              withBackground: false,
              includeArchived: true,
              showAllOnTap: true,
              height: 32,
              onProjectChanged: (projectId) async {
                await _applyTaskProject(task, projectId);
              },
              onAutoSave: () {},
            ),
          ),
          cell(width: _subProjectColWidth, child: subProjectInput),
          cell(
            width: _modeColWidth,
            child: ModeInputField(
              controller: modeController,
              useOutlineBorder: false,
              withBackground: false,
              hintText: 'モード',
              height: 32,
              onModeChanged: (modeId) async {
                await _applyTaskMode(task, modeId);
              },
              onAutoSave: () {},
            ),
          ),
          cell(
            width: _locationColWidth,
            child: Focus(
              onFocusChange: (hasFocus) {
                if (!hasFocus) {
                  _applyTaskLocation(task, locationController.text);
                }
              },
              child: TextField(
                controller: locationController,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  isCollapsed: true,
                  hintText: '場所',
                ),
                onSubmitted: (_) =>
                    _applyTaskLocation(task, locationController.text),
              ),
            ),
          ),
          cell(
            width: _editColWidth,
            center: true,
            padding: EdgeInsets.zero,
            child: IconButton(
              iconSize: 18,
              splashRadius: 18,
              tooltip: '全項目を編集',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => _showTaskFullEditDialog(task),
            ),
          ),
          cell(
            width: _actionColWidth,
            center: true,
            addRightBorder: false,
            padding: EdgeInsets.zero,
            child: IconButton(
              iconSize: 18,
              splashRadius: 18,
              tooltip: '削除',
              icon: Icon(
                Icons.delete_outline,
                color: theme.colorScheme.error,
              ),
              onPressed: () => _deleteRoutineTask(task),
            ),
          ),
        ],
      ),
    );
  }

  String _getProjectName(String? projectId) {
    if (projectId == null || projectId.isEmpty) return '';
    return ProjectService.getProjectById(projectId)?.name ?? '';
  }

  String _getSubProjectName(String? subProjectId) {
    if (subProjectId == null || subProjectId.isEmpty) return '';
    return SubProjectService.getSubProjectById(subProjectId)?.name ?? '';
  }

  String _getModeName(String? modeId) {
    if (modeId == null || modeId.isEmpty) return '';
    return ModeService.getModeById(modeId)?.name ?? '';
  }

  Future<void> _showTaskFullEditDialog(rtv2.RoutineTaskV2 t) async {
    final nameCtrl = TextEditingController(text: t.name);
    final durationCtrl =
        TextEditingController(text: t.estimatedDuration.toString());
    final detailsCtrl = TextEditingController(text: t.details ?? '');
    final memoCtrl = TextEditingController(text: t.memo ?? '');
    final locationCtrl = TextEditingController(text: t.location ?? '');
    final blockNameCtrl = TextEditingController(text: t.blockName ?? '');
    final orderCtrl = TextEditingController(text: t.order.toString());

    String? dialogProjectId = t.projectId;
    String? dialogSubProjectId = t.subProjectId;
    String? dialogSubProjectName = t.subProject;
    String? dialogModeId = t.modeId;
    bool dialogIsEvent = t.isEvent;

    bool? saved = await showImeSafeDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            final mq = MediaQuery.of(ctx);
            final isPhoneLike = mq.size.shortestSide < 600;
            final double dialogWidth =
                (mq.size.width - (isPhoneLike ? 16 : 48))
                    .clamp(0.0, isPhoneLike ? 560.0 : 520.0)
                    .toDouble();

            Future<void> pickProject() async {
              final projects = ProjectService.getActiveProjects()
                ..sort((a, b) => a.name.compareTo(b.name));
              final selected = await showDialog<String>(
                context: ctx,
                builder: (dialogCtx) => SimpleDialog(
                  title: const Text('プロジェクトを選択'),
                  children: [
                    SimpleDialogOption(
                      onPressed: () => Navigator.of(dialogCtx).pop('__clear__'),
                      child: const Text('未設定（クリア）'),
                    ),
                    for (final project in projects)
                      SimpleDialogOption(
                        onPressed: () =>
                            Navigator.of(dialogCtx).pop(project.id),
                        child: Text(project.name),
                      ),
                  ],
                ),
              );
              if (selected != null) {
                setLocal(() {
                  dialogProjectId =
                      (selected == '__clear__' || selected.isEmpty)
                          ? null
                          : selected;
                  if (dialogProjectId == null) {
                    dialogSubProjectId = null;
                    dialogSubProjectName = null;
                  }
                });
              }
            }

            Future<void> pickSubProject() async {
              if (dialogProjectId == null || dialogProjectId!.isEmpty) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(
                      content: Text('先にプロジェクトを設定してください')),
                );
                return;
              }
              final subProjects =
                  SubProjectService.getSubProjectsByProjectId(dialogProjectId!)
                    ..sort((a, b) => a.name.compareTo(b.name));
              final selected = await showDialog<String>(
                context: ctx,
                builder: (dialogCtx) => SimpleDialog(
                  title: const Text('サブプロジェクトを選択'),
                  children: [
                    SimpleDialogOption(
                      onPressed: () => Navigator.of(dialogCtx).pop('__clear__'),
                      child: const Text('未設定'),
                    ),
                    for (final sp in subProjects)
                      SimpleDialogOption(
                        onPressed: () => Navigator.of(dialogCtx).pop(sp.id),
                        child: Text(sp.name),
                      ),
                  ],
                ),
              );
              if (selected != null) {
                setLocal(() {
                  dialogSubProjectId =
                      (selected == '__clear__' || selected.isEmpty)
                          ? null
                          : selected;
                  dialogSubProjectName =
                      (selected == '__clear__' || selected.isEmpty)
                          ? null
                          : _getSubProjectName(selected);
                });
              }
            }

            Future<void> pickMode() async {
              final modes = ModeService.getAllModes()
                ..sort((a, b) => a.name.compareTo(b.name));
              final selected = await showDialog<String>(
                context: ctx,
                builder: (dialogCtx) => SimpleDialog(
                  title: const Text('モードを選択'),
                  children: [
                    SimpleDialogOption(
                      onPressed: () => Navigator.of(dialogCtx).pop('__clear__'),
                      child: const Text('未設定'),
                    ),
                    for (final mode in modes)
                      SimpleDialogOption(
                        onPressed: () => Navigator.of(dialogCtx).pop(mode.id),
                        child: Text(mode.name),
                      ),
                  ],
                ),
              );
              if (selected != null) {
                setLocal(() {
                  dialogModeId =
                      (selected == '__clear__' || selected.isEmpty)
                          ? null
                          : selected;
                });
              }
            }

            return AlertDialog(
              insetPadding: isPhoneLike
                  ? const EdgeInsets.symmetric(horizontal: 8, vertical: 8)
                  : const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
              title: const Text('タスクの全項目を編集'),
              content: SizedBox(
                width: dialogWidth,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: nameCtrl,
                        decoration: const InputDecoration(
                          labelText: 'タスク名',
                          border: OutlineInputBorder(),
                          floatingLabelBehavior: FloatingLabelBehavior.always,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: durationCtrl,
                        decoration: const InputDecoration(
                          labelText: '作業時間 (分)',
                          border: OutlineInputBorder(),
                          floatingLabelBehavior: FloatingLabelBehavior.always,
                        ),
                        keyboardType: TextInputType.number,
                      ),
                      const SizedBox(height: 12),
                      ListTile(
                        title: Text(
                          dialogProjectId == null || dialogProjectId!.isEmpty
                              ? '未設定'
                              : _getProjectName(dialogProjectId),
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: pickProject,
                      ),
                      const SizedBox(height: 4),
                      ListTile(
                        title: Text(
                          dialogSubProjectId == null ||
                                  dialogSubProjectId!.isEmpty
                              ? '未設定'
                              : (dialogSubProjectName ??
                                  _getSubProjectName(dialogSubProjectId)),
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: pickSubProject,
                      ),
                      const SizedBox(height: 4),
                      ListTile(
                        title: Text(
                          dialogModeId == null || dialogModeId!.isEmpty
                              ? '未設定'
                              : _getModeName(dialogModeId),
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: pickMode,
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: detailsCtrl,
                        decoration: const InputDecoration(
                          labelText: '詳細',
                          border: OutlineInputBorder(),
                          floatingLabelBehavior: FloatingLabelBehavior.always,
                        ),
                        maxLines: 2,
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: memoCtrl,
                        decoration: const InputDecoration(
                          labelText: 'メモ',
                          border: OutlineInputBorder(),
                          floatingLabelBehavior: FloatingLabelBehavior.always,
                        ),
                        maxLines: 2,
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: locationCtrl,
                        decoration: const InputDecoration(
                          labelText: '場所',
                          border: OutlineInputBorder(),
                          floatingLabelBehavior: FloatingLabelBehavior.always,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: blockNameCtrl,
                        decoration: const InputDecoration(
                          labelText: 'ブロック名（行ラベル）',
                          border: OutlineInputBorder(),
                          floatingLabelBehavior: FloatingLabelBehavior.always,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: orderCtrl,
                        decoration: const InputDecoration(
                          labelText: '並び順',
                          border: OutlineInputBorder(),
                          floatingLabelBehavior: FloatingLabelBehavior.always,
                        ),
                        keyboardType: TextInputType.number,
                      ),
                      const SizedBox(height: 8),
                      CheckboxListTile(
                        title: const Text('通知（イベント）'),
                        value: dialogIsEvent,
                        onChanged: (value) {
                          setLocal(() => dialogIsEvent = value ?? false);
                        },
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('キャンセル'),
                ),
                ElevatedButton(
                  onPressed: () {
                    final minutes = int.tryParse(durationCtrl.text.trim());
                    if (minutes == null || minutes < 0) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        const SnackBar(
                          content: Text(
                              '作業時間(分)は0以上の数値で入力してください'),
                        ),
                      );
                      return;
                    }
                    final order = int.tryParse(orderCtrl.text.trim());
                    if (order == null || order < 0) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        const SnackBar(
                          content: Text(
                              '並び順は0以上の数値で入力してください'),
                        ),
                      );
                      return;
                    }
                    Navigator.of(ctx).pop(true);
                  },
                  child: const Text('保存'),
                ),
              ],
            );
          },
        );
      },
    );

    if (saved != true) {
      nameCtrl.dispose();
      durationCtrl.dispose();
      detailsCtrl.dispose();
      memoCtrl.dispose();
      locationCtrl.dispose();
      blockNameCtrl.dispose();
      orderCtrl.dispose();
      return;
    }

    final minutes = int.tryParse(durationCtrl.text.trim());
    final order = int.tryParse(orderCtrl.text.trim());
    final updated = t.copyWith(
      name: nameCtrl.text.trim().isEmpty ? t.name : nameCtrl.text.trim(),
      estimatedDuration:
          (minutes != null && minutes >= 0) ? minutes : t.estimatedDuration,
      projectId: dialogProjectId,
      subProjectId: dialogSubProjectId,
      subProject: dialogSubProjectName ??
          (dialogSubProjectId != null
              ? _getSubProjectName(dialogSubProjectId)
              : null),
      modeId: dialogModeId,
      details:
          detailsCtrl.text.trim().isEmpty ? null : detailsCtrl.text.trim(),
      memo: memoCtrl.text.trim().isEmpty ? null : memoCtrl.text.trim(),
      location:
          locationCtrl.text.trim().isEmpty ? null : locationCtrl.text.trim(),
      blockName:
          blockNameCtrl.text.trim().isEmpty ? null : blockNameCtrl.text.trim(),
      isEvent: dialogIsEvent,
      order: (order != null && order >= 0) ? order : t.order,
      lastModified: DateTime.now(),
      version: t.version + 1,
    );

    nameCtrl.dispose();
    durationCtrl.dispose();
    detailsCtrl.dispose();
    memoCtrl.dispose();
    locationCtrl.dispose();
    blockNameCtrl.dispose();
    orderCtrl.dispose();

    await _mutationFacade.updateTask(updated);
    if (mounted) setState(() {});
  }

  Future<void> _addNewRoutineTask(rbv2.RoutineBlockV2 block) async {
    int nextOrder = 0;
    final data = _repository.snapshotTemplate(widget.routine.id);
    final blockTasks = data.tasksForBlock(block.id);
    for (final task in blockTasks) {
      if (task.order >= nextOrder) nextOrder = task.order + 1;
    }
    final now = DateTime.now().toUtc();
    final newTask = rtv2.RoutineTaskV2(
      id: 'rtask_${now.microsecondsSinceEpoch}',
      routineTemplateId: widget.routine.id,
      routineBlockId: block.id,
      name: '',
      estimatedDuration: 15,
      projectId: block.projectId,
      subProjectId: block.subProjectId,
      subProject: block.subProject,
      modeId: block.modeId,
      details: null,
      memo: null,
      location: block.location,
      blockName: block.blockName,
      order: nextOrder,
      createdAt: now,
      lastModified: now,
      userId: _resolveUserId(),
    );
    await _mutationFacade.addTask(newTask);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('タスクを追加しました')),
      );
    }
  }

  Widget _buildTableHeaderRow(
    BuildContext context,
    List<_TableHeader> headers,
  ) {
    final theme = Theme.of(context);
    final borderColor = theme.dividerColor;
    final headerTextStyle = theme.textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.bold,
        ) ??
        const TextStyle(fontSize: 12, fontWeight: FontWeight.bold);
    final background = theme.colorScheme.surfaceContainerHighest
        .withOpacity(theme.brightness == Brightness.light ? 1 : 0.2);

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: borderColor),
      ),
      child: Row(
        children: [
          for (int i = 0; i < headers.length; i++)
            SizedBox(
              width: headers[i].width,
              child: Container(
                height: 36,
                alignment:
                    headers[i].center ? Alignment.center : Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: background,
                  border: Border(
                    right: i == headers.length - 1
                        ? BorderSide.none
                        : BorderSide(color: borderColor),
                  ),
                ),
                child: Text(
                  headers[i].label,
                  style: headerTextStyle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _applyTaskName(rtv2.RoutineTaskV2 task, String rawValue) async {
    final trimmed = rawValue.trim();
    final nextName = trimmed;
    if (task.name == nextName) return;
    await _mutationFacade.updateTask(task.copyWith(name: nextName));
  }

  Future<void> _applyTaskDuration(
    rtv2.RoutineTaskV2 task,
    String rawValue,
  ) async {
    final parsed = int.tryParse(rawValue.trim());
    if (parsed == null || parsed < 0) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('所要は0以上の数値で入力してください')),
      );
      return;
    }
    if (parsed == task.estimatedDuration) return;
    await _mutationFacade.updateTask(task.copyWith(estimatedDuration: parsed));
  }

  TextEditingController _ensureTaskProjectController(
    rtv2.RoutineTaskV2 task,
    String projectName,
  ) {
    if (_pendingProjectClearByTaskId.contains(task.id)) {
      if ((task.projectId ?? '').isEmpty) {
        _pendingProjectClearByTaskId.remove(task.id);
      } else {
        return _projectControllers.putIfAbsent(
          task.id,
          () => TextEditingController(text: projectName),
        );
      }
    }
    final controller = _projectControllers.putIfAbsent(
      task.id,
      () => TextEditingController(text: projectName),
    );
    if (controller.text != projectName) {
      controller.text = projectName;
    }
    return controller;
  }

  Future<void> _applyTaskProject(
    rtv2.RoutineTaskV2 task,
    String? projectId,
  ) async {
    final newProjectId =
        (projectId == null || projectId.isEmpty || projectId == '__clear__')
            ? null
            : projectId;
    if ((task.projectId ?? '') == (newProjectId ?? '')) return;
    if (newProjectId == null && (task.projectId ?? '').isNotEmpty) {
      _pendingProjectClearByTaskId.add(task.id);
    }
    await _mutationFacade.updateTask(
      task.copyWith(
        projectId: newProjectId,
        subProjectId: null,
        subProject: null,
      ),
    );
  }

  Future<void> _applyTaskSubProject(
    rtv2.RoutineTaskV2 task,
    String? subProjectId,
    String? subProjectLabel,
  ) async {
    final newSubProjectId =
        (subProjectId == null || subProjectId.isEmpty || subProjectId == '__clear__')
            ? null
            : subProjectId;
    final newSubProjectLabel =
        (subProjectLabel == null || subProjectLabel.trim().isEmpty)
            ? null
            : subProjectLabel.trim();
    if ((task.subProjectId ?? '') == (newSubProjectId ?? '') &&
        (task.subProject ?? '') == (newSubProjectLabel ?? '')) {
      return;
    }
    await _mutationFacade.updateTask(
      task.copyWith(
        subProjectId: newSubProjectId,
        subProject: newSubProjectLabel,
      ),
    );
  }

  Future<void> _applyTaskMode(
    rtv2.RoutineTaskV2 task,
    String? modeId,
  ) async {
    final newModeId =
        (modeId == null || modeId.isEmpty || modeId == '__clear__')
            ? null
            : modeId;
    if ((task.modeId ?? '') == (newModeId ?? '')) return;
    await _mutationFacade.updateTask(task.copyWith(modeId: newModeId));
  }

  Future<void> _applyTaskLocation(
    rtv2.RoutineTaskV2 task,
    String rawValue,
  ) async {
    final trimmed = rawValue.trim();
    final newLocation = trimmed.isEmpty ? null : trimmed;
    if ((task.location ?? '') == (newLocation ?? '')) return;
    await _mutationFacade.updateTask(task.copyWith(location: newLocation));
  }

  Future<void> _deleteRoutineTask(rtv2.RoutineTaskV2 task) async {
    await _mutationFacade.deleteTask(task.id, task.routineTemplateId);
  }

  void _purgeUnusedTaskControllers(Set<String> activeTaskIds) {
    void purge(Map<String, TextEditingController> map) {
      final stale = map.keys.where((id) => !activeTaskIds.contains(id)).toList();
      for (final id in stale) {
        map[id]?.dispose();
        map.remove(id);
      }
    }

    final staleTimers =
        _nameSaveTimers.keys.where((id) => !activeTaskIds.contains(id)).toList();
    for (final id in staleTimers) {
      _nameSaveTimers.remove(id)?.cancel();
    }

    purge(_nameControllers);
    purge(_durationControllers);
    purge(_projectControllers);
    purge(_subProjectControllers);
    purge(_modeControllers);
    purge(_locationControllers);
  }
}

class _TableHeader {
  const _TableHeader(this.label, this.width, {this.center = false});

  final String label;
  final double width;
  final bool center;
}
