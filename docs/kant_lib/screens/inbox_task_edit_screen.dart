import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../utils/input_method_guard.dart';
import '../utils/web_scoped_save_shortcut_barrier.dart';

import '../models/inbox_task.dart' as inbox;
import '../models/block.dart' as block;
import '../providers/task_provider.dart';
import '../services/project_service.dart';
import '../services/sub_project_service.dart';
import '../services/inbox_task_service.dart';
import '../services/block_service.dart';
import '../services/mode_service.dart';
import '../widgets/project_input_field.dart';
import '../widgets/sub_project_input_field.dart';
import '../widgets/mode_input_field.dart';

class InboxTaskEditScreen extends StatefulWidget {
  final inbox.InboxTask task;

  const InboxTaskEditScreen({super.key, required this.task});

  @override
  State<InboxTaskEditScreen> createState() => _InboxTaskEditScreenState();
}

class _InboxTaskEditScreenState extends State<InboxTaskEditScreen> {
  late TextEditingController _titleController;
  late TextEditingController _memoController;
  late TextEditingController _projectController;
  late TextEditingController _subProjectController;
  late TextEditingController _modeController;

  String? _selectedProjectId;
  String? _selectedSubProjectId;
  String? _selectedModeId;
  String? _selectedBlockId;
  bool _isSomeday = false;
  bool _excludeFromReport = false;
  bool _isImportant = false;
  DateTime? _selectedDueDate;
  DateTime? _selectedExecutionDate;
  int? _selectedStartHour;
  int? _selectedStartMinute;
  int _estimatedDuration = 0;

  List<block.Block> _blockCandidates = <block.Block>[];

  @override
  void initState() {
    super.initState();
    final t = widget.task;
    // Mode候補（未初期化のケースに備える）
    try {
      ModeService.initialize();
    } catch (_) {}

    _titleController = TextEditingController(text: t.title);
    _memoController = TextEditingController(text: t.memo ?? '');
    _selectedProjectId = t.projectId;
    final projectName = t.projectId != null
        ? (ProjectService.getProjectById(t.projectId!)?.name ?? '')
        : '';
    _projectController = TextEditingController(text: projectName);
    _selectedSubProjectId = t.subProjectId;
    final subProjectName = t.subProjectId != null
        ? (SubProjectService.getSubProjectById(t.subProjectId!)?.name ?? '')
        : '';
    _subProjectController = TextEditingController(text: subProjectName);
    _selectedModeId = (t.modeId != null && t.modeId!.isNotEmpty) ? t.modeId : null;
    _modeController = TextEditingController(
      text: (_selectedModeId != null)
          ? (ModeService.getModeById(_selectedModeId!)?.name ?? '')
          : '',
    );
    _selectedBlockId = t.blockId;
    _isSomeday = t.isSomeday == true;
    _excludeFromReport = t.excludeFromReport == true;
    _isImportant = t.isImportant == true;
    _selectedDueDate = t.dueDate;
    _selectedExecutionDate = t.executionDate;
    _selectedStartHour = t.startHour;
    _selectedStartMinute = t.startMinute;
    _estimatedDuration = t.estimatedDuration;

    // いつかのときは、未割当扱いに揃える（ブロック/時刻は持たせない）
    if (_isSomeday) {
      _selectedBlockId = null;
      _selectedStartHour = null;
      _selectedStartMinute = null;
    }

    _blockCandidates = _getAvailableBlocksForTask(t);
    if (_selectedBlockId != null &&
        !_blockCandidates.any((b) => b.id == _selectedBlockId)) {
      _selectedBlockId = null;
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _memoController.dispose();
    _projectController.dispose();
    _subProjectController.dispose();
    _modeController.dispose();
    super.dispose();
  }

  Future<void> _openMemoFullScreenEditor() async {
    final current = _memoController.text;
    final next = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _InboxMemoFullScreenEditor(initialText: current),
      ),
    );
    if (next == null) return;
    if (!mounted) return;
    setState(() {
      _memoController.text = next;
    });
  }

  String _formatBlockLabel(block.Block blockItem) {
    final title = () {
      final t = blockItem.title.trim();
      if (t.isNotEmpty) return t;
      final name = blockItem.blockName?.trim();
      if (name != null && name.isNotEmpty) return name;
      return '（名称未設定）';
    }();
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final start =
        '${twoDigits(blockItem.startHour)}:${twoDigits(blockItem.startMinute)}';
    final endTime = blockItem.endDateTime.toLocal();
    final end = '${twoDigits(endTime.hour)}:${twoDigits(endTime.minute)}';
    final date =
        '${blockItem.executionDate.month}/${blockItem.executionDate.day}';
    return '$title ($date $start-$end)';
  }

  void _onSaveShortcut() {
    if (isImeComposing(_titleController)) return;
    // ignore: discarded_futures
    _save();
  }

  @override
  Widget build(BuildContext context) {
    // TextField の標準（テーマ準拠）に揃える
    final double unifiedFontSize =
        Theme.of(context).textTheme.titleMedium?.fontSize ?? 16.0;
    return WebScopedSaveShortcutBarrier(
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyS, control: true):
              _onSaveShortcut,
          const SingleActivator(LogicalKeyboardKey.keyS, meta: true):
              _onSaveShortcut,
        },
        child: Focus(
          child: Scaffold(
      appBar: AppBar(
        title: const Text('タスクの編集'),
        actions: [
          IconButton(
            tooltip: '削除',
            icon: const Icon(Icons.delete_outline),
            onPressed: _confirmDelete,
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= 600;
            return SingleChildScrollView(
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
                    ),
                    minLines: 1,
                    maxLines: 2,
                    textInputAction: TextInputAction.done,
                    inputFormatters: [
                      // タイトルは改行を許可しない（見た目は折り返しで2行表示）
                      FilteringTextInputFormatter.deny(RegExp(r'[\n\r]')),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (isWide)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: InputDecorator(
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
                              onProjectChanged: (projectId) {
                                setState(() {
                                  _selectedProjectId = projectId;
                                  _subProjectController.text = '';
                                  _selectedSubProjectId = null;
                                });
                              },
                              withBackground: false,
                              useOutlineBorder: false,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: InputDecorator(
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
                                });
                              },
                              withBackground: false,
                              useOutlineBorder: false,
                            ),
                          ),
                        ),
                      ],
                    )
                  else
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
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
                            onProjectChanged: (projectId) {
                              setState(() {
                                _selectedProjectId = projectId;
                                _subProjectController.text = '';
                                _selectedSubProjectId = null;
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
                              });
                            },
                            withBackground: false,
                            useOutlineBorder: false,
                          ),
                        ),
                      ],
                    ),
                  const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: InputDecorator(
                      decoration: InputDecoration(
                        labelText: '重要',
                        border: const OutlineInputBorder(),
                        floatingLabelBehavior: FloatingLabelBehavior.always,
                        filled: true,
                        fillColor:
                            Theme.of(context).inputDecorationTheme.fillColor ??
                                Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                      ),
                      child: SizedBox(
                        height: 44,
                        child: Row(
                          children: [
                            Tooltip(
                              message: '開始時刻のある重要タスクを通知対象にします',
                              child: Icon(
                                Icons.info_outline,
                                size: 18,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                            ),
                            const Spacer(),
                            Switch.adaptive(
                              value: _isImportant,
                              onChanged: (v) =>
                                  setState(() => _isImportant = v),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: InputDecorator(
                      decoration: InputDecoration(
                        labelText: 'いつか',
                        border: const OutlineInputBorder(),
                        floatingLabelBehavior: FloatingLabelBehavior.always,
                        filled: true,
                        fillColor:
                            Theme.of(context).inputDecorationTheme.fillColor ??
                                Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                      ),
                      child: SizedBox(
                        height: 44,
                        child: Row(
                          children: [
                            Tooltip(
                              message: 'インボックスの通常表示・割当から除外します',
                              child: Icon(
                                Icons.info_outline,
                                size: 18,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                            ),
                            const Spacer(),
                            Switch.adaptive(
                              value: _isSomeday,
                              onChanged: (v) {
                                setState(() {
                                  _isSomeday = v;
                                  if (v) {
                                    _selectedBlockId = null;
                                    _selectedStartHour = null;
                                    _selectedStartMinute = null;
                                  }
                                });
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: InputDecorator(
                      decoration: InputDecoration(
                        labelText: '集計外',
                        border: const OutlineInputBorder(),
                        floatingLabelBehavior: FloatingLabelBehavior.always,
                        filled: true,
                        fillColor:
                            Theme.of(context).inputDecorationTheme.fillColor ??
                                Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                      ),
                      child: SizedBox(
                        height: 44,
                        child: Row(
                          children: [
                            Tooltip(
                              message: 'レポート（集計）に含めません',
                              child: Icon(
                                Icons.info_outline,
                                size: 18,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                            ),
                            const Spacer(),
                            Switch.adaptive(
                              value: _excludeFromReport,
                              onChanged: (v) =>
                                  setState(() => _excludeFromReport = v),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: InputDecorator(
                      decoration: InputDecoration(
                        labelText: 'モード',
                        border: const OutlineInputBorder(),
                        floatingLabelBehavior: FloatingLabelBehavior.always,
                        filled: true,
                        fillColor:
                            Theme.of(context).inputDecorationTheme.fillColor ??
                                Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                      ),
                      isEmpty: _modeController.text.isEmpty,
                      child: ModeInputField(
                        controller: _modeController,
                        height: 44,
                        fontSize: unifiedFontSize,
                        onModeChanged: (modeId) {
                          setState(() {
                            _selectedModeId = (modeId == null || modeId.isEmpty)
                                ? null
                                : modeId;
                          });
                        },
                        withBackground: false,
                        useOutlineBorder: false,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String?>(
                      decoration: const InputDecoration(
                        labelText: 'ブロック',
                        border: OutlineInputBorder(),
                        floatingLabelBehavior: FloatingLabelBehavior.always,
                      ),
                      value: _isSomeday ? null : _selectedBlockId,
                      items: [
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('なし'),
                        ),
                        ..._blockCandidates.map(
                          (b) => DropdownMenuItem<String?>(
                            value: b.id,
                            child: Text(_formatBlockLabel(b)),
                          ),
                        ),
                      ],
                      onChanged: _isSomeday
                          ? null
                          : (v) => setState(() {
                                _selectedBlockId = v;
                                if (v != null && v.isNotEmpty) {
                                  _isSomeday = false;
                                }
                              }),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: TextEditingController(
                        text: _selectedDueDate != null
                            ? '${_selectedDueDate!.year}-${_selectedDueDate!.month.toString().padLeft(2, '0')}-${_selectedDueDate!.day.toString().padLeft(2, '0')}'
                            : '',
                      ),
                      readOnly: true,
                      style: TextStyle(fontSize: unifiedFontSize),
                      decoration: const InputDecoration(
                        labelText: '期日',
                        border: OutlineInputBorder(),
                        floatingLabelBehavior: FloatingLabelBehavior.always,
                      ),
                      onTap: () async {
                        await showDialog<DateTime>(
                          context: context,
                          builder: (ctx) {
                            final base = _selectedDueDate ?? DateTime.now();
                            DateTime temp =
                                DateTime(base.year, base.month, base.day);
                            return AlertDialog(
                              title: const Text('期日を選択'),
                              content: SizedBox(
                                width: 360,
                                height: 340,
                                child: CalendarDatePicker(
                                  initialDate: temp,
                                  firstDate: DateTime(2020),
                                  lastDate: DateTime(2100),
                                  onDateChanged: (d) {
                                    setState(() => _selectedDueDate = d);
                                    Navigator.pop(ctx, d);
                                  },
                                  currentDate: DateTime.now(),
                                  initialCalendarMode: DatePickerMode.day,
                                ),
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: TextEditingController(
                        text: _selectedExecutionDate != null
                            ? '${_selectedExecutionDate!.year}-${_selectedExecutionDate!.month.toString().padLeft(2, '0')}-${_selectedExecutionDate!.day.toString().padLeft(2, '0')}'
                            : '',
                      ),
                      readOnly: true,
                      style: TextStyle(fontSize: unifiedFontSize),
                      decoration: const InputDecoration(
                        labelText: '実行日',
                        border: OutlineInputBorder(),
                        floatingLabelBehavior: FloatingLabelBehavior.always,
                      ),
                      onTap: () async {
                        await showDialog<DateTime>(
                          context: context,
                          builder: (ctx) {
                            final base =
                                _selectedExecutionDate ?? DateTime.now();
                            DateTime temp =
                                DateTime(base.year, base.month, base.day);
                            return AlertDialog(
                              title: const Text('実行日を選択'),
                              content: SizedBox(
                                width: 360,
                                height: 340,
                                child: CalendarDatePicker(
                                  initialDate: temp,
                                  firstDate: DateTime(2020),
                                  lastDate: DateTime(2100),
                                  onDateChanged: (d) {
                                    setState(() {
                                      _selectedExecutionDate = d;
                                      _blockCandidates =
                                          _getAvailableBlocksForDate(d);
                                      if (_selectedBlockId != null &&
                                          !_blockCandidates.any((b) =>
                                              b.id == _selectedBlockId)) {
                                        _selectedBlockId = null;
                                      }
                                    });
                                    Navigator.pop(ctx, d);
                                  },
                                  currentDate: DateTime.now(),
                                  initialCalendarMode: DatePickerMode.day,
                                ),
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: TextEditingController(
                        text: (_selectedStartHour != null &&
                                _selectedStartMinute != null)
                            ? '${_selectedStartHour!.toString().padLeft(2, '0')}:${_selectedStartMinute!.toString().padLeft(2, '0')}'
                            : '',
                      ),
                      readOnly: true,
                      style: TextStyle(fontSize: unifiedFontSize),
                      decoration: const InputDecoration(
                        labelText: '開始時刻',
                        border: OutlineInputBorder(),
                        floatingLabelBehavior: FloatingLabelBehavior.always,
                      ),
                      onTap: () async {
                        if (_isSomeday) {
                          return;
                        }
                        final picked = await showTimePicker(
                          context: context,
                          initialTime: TimeOfDay(
                            hour: _selectedStartHour ?? 9,
                            minute: _selectedStartMinute ?? 0,
                          ),
                        );
                        if (picked != null) {
                          setState(() {
                            _isSomeday = false;
                            _selectedStartHour = picked.hour;
                            _selectedStartMinute = picked.minute;
                          });
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: TextEditingController(
                          text: _estimatedDuration.toString()),
                      style: TextStyle(fontSize: unifiedFontSize),
                      decoration: const InputDecoration(
                        labelText: '作業時間 (分)',
                        border: OutlineInputBorder(),
                        floatingLabelBehavior: FloatingLabelBehavior.always,
                      ),
                      keyboardType: TextInputType.number,
                      onChanged: (v) {
                        final val = int.tryParse(v);
                        if (val != null && val >= 0) {
                          setState(() => _estimatedDuration = val);
                        }
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _MemoPreviewField(
                labelText: 'メモ',
                text: _memoController.text,
                fontSize: unifiedFontSize,
                onTap: _openMemoFullScreenEditor,
              ),
                ],
              ),
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _save,
        tooltip: '保存',
        child: const Icon(Icons.save),
      ),
    ),
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (_titleController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('タスク名は必須です')));
      return;
    }
    try {
      final t = widget.task;
      final updated = t.copyWith(
        title: _titleController.text.trim(),
        memo:
            _memoController.text.trim().isEmpty ? null : _memoController.text.trim(),
        projectId: _selectedProjectId,
        subProjectId: _selectedSubProjectId,
        modeId: _selectedModeId,
        isSomeday: _isSomeday,
        excludeFromReport: _excludeFromReport,
        isImportant: _isImportant,
        blockId: _isSomeday ? null : _selectedBlockId,
        dueDate: _selectedDueDate,
        executionDate: _selectedExecutionDate,
        startHour: _isSomeday ? null : _selectedStartHour,
        startMinute: _isSomeday ? null : _selectedStartMinute,
        estimatedDuration: _estimatedDuration,
        lastModified: DateTime.now(),
      );
      await context.read<TaskProvider>().updateInboxTask(updated);
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('保存に失敗しました: $e')));
    }
  }

  Future<void> _confirmDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('削除確認'),
        content: Text('「${widget.task.title}」を削除しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      try {
        await context.read<TaskProvider>().deleteInboxTask(widget.task.id);
        if (!mounted) return;
        Navigator.of(context).pop(true);
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('削除に失敗しました: $e')));
      }
    }
  }

  List<block.Block> _getAvailableBlocksForTask(inbox.InboxTask task) {
    final base = _getAvailableBlocksForDate(task.executionDate);
    if (task.blockId == null || task.blockId!.isEmpty) return base;
    final current = BlockService.getBlockById(task.blockId!);
    if (current == null) return base;
    bool sameYmd(DateTime a, DateTime b) {
      final al = a.toLocal();
      final bl = b.toLocal();
      return al.year == bl.year && al.month == bl.month && al.day == bl.day;
    }

    if (sameYmd(current.executionDate, task.executionDate) &&
        !current.isCompleted &&
        !current.isDeleted) {
      if (!base.any((b) => b.id == current.id)) {
        return [...base, current]..sort((a, b) =>
            (a.startHour * 60 + a.startMinute)
                .compareTo(b.startHour * 60 + b.startMinute));
      }
    }
    return base;
  }

  List<block.Block> _getAvailableBlocksForDate(DateTime date) {
    // インボックス画面のポリシー: 実行日が当日以前は当日扱い
    final todayLocal = DateTime.now();
    final todayYmd =
        DateTime(todayLocal.year, todayLocal.month, todayLocal.day);
    final DateTime effective = () {
      final dl = date.toLocal();
      final ymd = DateTime(dl.year, dl.month, dl.day);
      if (ymd.isBefore(todayYmd)) return todayYmd;
      return ymd;
    }();
    bool sameYmd(DateTime a, DateTime b) {
      final al = a.toLocal();
      final bl = b.toLocal();
      return al.year == bl.year && al.month == bl.month && al.day == bl.day;
    }

    final bool targetIsToday = sameYmd(effective, todayYmd);
    final DateTime now = DateTime.now();
    final allBlocks = BlockService.getAllBlocks();
    final filtered = allBlocks.where((b) {
      final isSameDay = sameYmd(b.executionDate, effective);
      final isNotCompleted = !b.isCompleted;
      final isNotDeleted = !b.isDeleted;
      final isNotLinked = b.taskId == null ||
          b.taskId!.isEmpty ||
          InboxTaskService.getInboxTask(b.taskId!) == null;
      if (!(isSameDay && isNotCompleted && isNotDeleted && isNotLinked)) {
        return false;
      }
      if (targetIsToday) {
        final blockEnd = b.endDateTime.toLocal();
        if (blockEnd.isBefore(now)) {
          return false;
        }
      }
      return true;
    }).toList();
    filtered.sort((a, b) {
      final at = a.startHour * 60 + a.startMinute;
      final bt = b.startHour * 60 + b.startMinute;
      return at.compareTo(bt);
    });
    return filtered;
  }
}

class _MemoPreviewField extends StatelessWidget {
  final String labelText;
  final String text;
  final double fontSize;
  final VoidCallback onTap;

  const _MemoPreviewField({
    required this.labelText,
    required this.text,
    required this.fontSize,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final memo = text.trim();
    final isEmpty = memo.isEmpty;
    final colorScheme = Theme.of(context).colorScheme;
    final display = memo;
    final textStyle = TextStyle(
      fontSize: fontSize,
      color: colorScheme.onSurface,
      height: 1.25,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        bool exceeds = false;
        if (!isEmpty) {
          final painter = TextPainter(
            text: TextSpan(text: memo, style: textStyle),
            maxLines: 2,
            ellipsis: '…',
            textDirection: Directionality.of(context),
          )..layout(maxWidth: constraints.maxWidth);
          exceeds = painter.didExceedMaxLines;
        }

        return InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(4),
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: labelText,
              border: const OutlineInputBorder(),
              floatingLabelBehavior: FloatingLabelBehavior.always,
            ),
            isEmpty: isEmpty,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!isEmpty)
                  Text(
                    display,
                    style: textStyle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  )
                else
                  const SizedBox(height: 20),
                if (exceeds)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '…省略中（タップして全文を編集）',
                      style: TextStyle(
                        fontSize: (fontSize - 3).clamp(11, fontSize),
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                ,
              ],
            ),
          ),
        );
      },
    );
  }
}

class _InboxMemoFullScreenEditor extends StatefulWidget {
  final String initialText;
  const _InboxMemoFullScreenEditor({required this.initialText});

  @override
  State<_InboxMemoFullScreenEditor> createState() =>
      _InboxMemoFullScreenEditorState();
}

class _InboxMemoFullScreenEditorState extends State<_InboxMemoFullScreenEditor> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _close({required bool save}) {
    final next = save ? _controller.text : widget.initialText;
    Navigator.of(context).pop(next);
  }

  bool get _isDirty => _controller.text != widget.initialText;

  Future<void> _handleCloseRequest() async {
    if (!_isDirty) {
      _close(save: false);
      return;
    }

    final decision = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('確認'),
        content: const Text('編集中です。内容を破棄しますか。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('cancel'),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('discard'),
            child: Text(
              '破棄する',
              style: TextStyle(color: Theme.of(ctx).colorScheme.error),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop('save'),
            child: const Text('保存して閉じる'),
          ),
        ],
      ),
    );

    if (!mounted) return;
    if (decision == 'discard') {
      _close(save: false);
    } else if (decision == 'save') {
      _close(save: true);
    } else {
      // stay
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) {
        if (didPop) return;
        // 戻る操作でも勝手に閉じない（未保存なら破棄確認）
        // ignore: unawaited_futures
        _handleCloseRequest();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('メモを編集'),
          actions: [
            TextButton(
              onPressed: _handleCloseRequest,
              child: const Text('キャンセル'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () => _close(save: true),
              child: const Text('完了'),
            ),
            const SizedBox(width: 12),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _controller,
              autofocus: true,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              minLines: 10,
              maxLines: null,
              decoration: const InputDecoration(
                hintText: 'メモを入力',
                border: OutlineInputBorder(),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
