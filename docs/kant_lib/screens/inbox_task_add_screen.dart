import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/block.dart' as block;
import '../providers/task_provider.dart';
import '../services/app_settings_service.dart';
import '../services/block_service.dart';
import '../services/inbox_task_service.dart';
import '../services/mode_service.dart';
import '../utils/input_method_guard.dart';
import '../utils/web_scoped_save_shortcut_barrier.dart';
import '../widgets/mode_input_field.dart';
import '../widgets/project_input_field.dart';
import '../widgets/sub_project_input_field.dart';

class InboxTaskAddScreen extends StatefulWidget {
  final DateTime? initialDate;
  // タイムラインから開いた場合など、開始時刻を事前入力したいケース向け。
  // インボックス側の通常追加では null のまま（= ブランク表示）。
  final TimeOfDay? initialStartTime;
  // タイムラインの予定ブロックに紐づけて追加したい場合に指定する。
  final String? initialBlockId;
  const InboxTaskAddScreen({
    super.key,
    this.initialDate,
    this.initialStartTime,
    this.initialBlockId,
  });

  @override
  State<InboxTaskAddScreen> createState() => _InboxTaskAddScreenState();
}

class _InboxTaskAddScreenState extends State<InboxTaskAddScreen> {
  final _titleController = TextEditingController();
  final _memoController = TextEditingController();
  final _projectController = TextEditingController();
  final _subProjectController = TextEditingController();
  final _modeController = TextEditingController();
  final _titleFocusNode = FocusNode(debugLabel: 'inbox_task_add_title');

  String? _selectedProjectId;
  String? _selectedSubProjectId;
  String? _selectedModeId;
  String? _selectedBlockId;
  bool _isSomeday = false;
  bool _isImportant = false;
  DateTime? _selectedDueDate;
  late DateTime _selectedExecutionDate;
  int? _selectedStartHour;
  int? _selectedStartMinute;
  int _estimatedDuration = 0;
  List<block.Block> _blockCandidates = <block.Block>[];

  @override
  void initState() {
    super.initState();
    // Mode候補（未初期化のケースに備える）
    try {
      ModeService.initialize();
    } catch (_) {}

    _estimatedDuration = AppSettingsService.getInt(
      AppSettingsService.keyTaskDefaultEstimatedMinutes,
      defaultValue: 0,
    );
    _selectedExecutionDate = widget.initialDate == null
        ? DateTime.now()
        : DateTime(
            widget.initialDate!.year,
            widget.initialDate!.month,
            widget.initialDate!.day,
          );
    _selectedBlockId = widget.initialBlockId;
    _blockCandidates = _getAvailableBlocksForDate(_selectedExecutionDate);
    if (_selectedBlockId != null && _selectedBlockId!.isNotEmpty) {
      final current = BlockService.getBlockById(_selectedBlockId!);
      if (current != null && !current.isCompleted && !current.isDeleted) {
        if (!_blockCandidates.any((b) => b.id == current.id)) {
          _blockCandidates = [..._blockCandidates, current]
            ..sort((a, b) => (a.startHour * 60 + a.startMinute)
                .compareTo(b.startHour * 60 + b.startMinute));
        }
      } else {
        _selectedBlockId = null;
      }
    }

    final st = widget.initialStartTime;
    if (st != null) {
      _selectedStartHour = st.hour;
      _selectedStartMinute = st.minute;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      FocusScope.of(context).requestFocus(_titleFocusNode);
    });
  }

  void _onSaveShortcut() {
    if (isImeComposing(_titleController) || isImeComposing(_memoController)) {
      return;
    }
    // ignore: discarded_futures
    _save();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _memoController.dispose();
    _projectController.dispose();
    _subProjectController.dispose();
    _modeController.dispose();
    _titleFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
        title: const Text('タスクの追加'),
        leading: IconButton(
          tooltip: '閉じる',
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          IconButton(
            tooltip: '保存',
            icon: const Icon(Icons.save),
            onPressed: _save,
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // NOTE: InputDecorator+内側TextFieldの組み合わせだと、
              // ラベルの描画が詰まり「タスク名」の下側が欠けることがあるため、
              // 通常のTextField（単一のOutline）に戻す。
              TextField(
                controller: _titleController,
                focusNode: _titleFocusNode,
                decoration: InputDecoration(
                  labelText: 'タスク名 *',
                  border: const OutlineInputBorder(),
                  floatingLabelBehavior: FloatingLabelBehavior.always,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 14,
                  ),
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
              InputDecorator(
                decoration: InputDecoration(
                  labelText: 'プロジェクト',
                  border: const OutlineInputBorder(),
                  floatingLabelBehavior: FloatingLabelBehavior.always,
                  filled: true,
                  fillColor:
                      Theme.of(context).inputDecorationTheme.fillColor ??
                      Theme.of(context).colorScheme.surfaceContainerHighest,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
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
                  fillColor:
                      Theme.of(context).inputDecorationTheme.fillColor ??
                      Theme.of(context).colorScheme.surfaceContainerHighest,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
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
                              onChanged: (v) {
                                setState(() => _isImportant = v);
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
                    child: InputDecorator(
                      decoration: InputDecoration(
                        labelText: 'ブロック',
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
                      isEmpty: _selectedBlockId == null,
                      child: SizedBox(
                        height: 44,
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String?>(
                            isDense: true,
                            isExpanded: true,
                            value: _isSomeday ? null : _selectedBlockId,
                            onChanged: _isSomeday
                                ? null
                                : (v) => setState(() {
                                      _selectedBlockId = v;
                                      if (v != null && v.isNotEmpty) {
                                        _isSomeday = false;
                                      }
                                    }),
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
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _memoController,
                decoration: const InputDecoration(
                  labelText: 'メモ',
                  border: OutlineInputBorder(),
                  floatingLabelBehavior: FloatingLabelBehavior.always,
                ),
                maxLines: 3,
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
                      decoration: const InputDecoration(
                        labelText: '期日',
                        border: OutlineInputBorder(),
                        floatingLabelBehavior: FloatingLabelBehavior.always,
                      ),
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: _selectedDueDate ?? DateTime.now(),
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2100),
                        );
                        if (picked != null) {
                          setState(() => _selectedDueDate = picked);
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: TextEditingController(
                        text:
                            '${_selectedExecutionDate.year}-${_selectedExecutionDate.month.toString().padLeft(2, '0')}-${_selectedExecutionDate.day.toString().padLeft(2, '0')}',
                      ),
                      readOnly: true,
                      decoration: const InputDecoration(
                        labelText: '実行日',
                        border: OutlineInputBorder(),
                        floatingLabelBehavior: FloatingLabelBehavior.always,
                      ),
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: _selectedExecutionDate,
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2100),
                        );
                        if (picked != null) {
                          setState(
                            () {
                              _selectedExecutionDate = DateTime(
                                picked.year,
                                picked.month,
                                picked.day,
                              );
                              _blockCandidates =
                                  _getAvailableBlocksForDate(picked);
                              if (_selectedBlockId != null &&
                                  !_blockCandidates
                                      .any((b) => b.id == _selectedBlockId)) {
                                _selectedBlockId = null;
                              }
                            },
                          );
                        }
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
                        text:
                            (_selectedStartHour != null &&
                                _selectedStartMinute != null)
                            ? '${_selectedStartHour!.toString().padLeft(2, '0')}:${_selectedStartMinute!.toString().padLeft(2, '0')}'
                            : '',
                      ),
                      readOnly: true,
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
                        text: _estimatedDuration.toString(),
                      ),
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
            ],
          ),
        ),
      ),
    ),
    ),
    ),
    );
  }

  Future<void> _save() async {
    if (_titleController.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('タスク名は必須です')));
      return;
    }
    try {
      await context.read<TaskProvider>().createTaskForInbox(
        title: _titleController.text.trim(),
        memo: _memoController.text.trim().isEmpty
            ? null
            : _memoController.text.trim(),
        projectId: _selectedProjectId,
        subProjectId: _selectedSubProjectId,
        dueDate: _selectedDueDate,
        executionDate: _selectedExecutionDate,
        startHour: _isSomeday ? null : _selectedStartHour,
        startMinute: _isSomeday ? null : _selectedStartMinute,
        estimatedDuration: _estimatedDuration,
        blockId: _isSomeday ? null : _selectedBlockId,
        modeId: _selectedModeId,
        isSomeday: _isSomeday,
        isImportant: _isImportant,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('保存に失敗しました: $e')));
    }
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
