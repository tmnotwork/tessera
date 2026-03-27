import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/block.dart' as block;
import '../models/actual_task.dart' as actual;
import '../providers/task_provider.dart';
import '../services/project_service.dart';
import '../services/mode_service.dart';
import '../services/sub_project_service.dart';
import '../widgets/project_input_field.dart';
import '../widgets/sub_project_input_field.dart';
import '../widgets/timeline/timeline_helpers.dart';

class MobileTaskEditScreen extends StatefulWidget {
  final dynamic task;

  const MobileTaskEditScreen({super.key, required this.task});

  @override
  State<MobileTaskEditScreen> createState() => _MobileTaskEditScreenState();
}

class _MobileTaskEditScreenState extends State<MobileTaskEditScreen> {
  late TextEditingController _blockNameController;
  late TextEditingController _titleController;
  late TextEditingController _memoController;
  late TextEditingController _locationController;
  late TextEditingController _projectController;
  late TextEditingController _subProjectController;
  late TextEditingController _modeController;
  late TextEditingController _startController;
  late TextEditingController _endController;
  late TextEditingController _durationController;

  // 実績タスク編集: 予定ブロック編集（BlockEditor）と同様に「開始日/終了日 + 時刻」を扱う
  DateTime? _actualStartDate; // date-only (local)
  DateTime? _actualEndDate; // date-only (local)

  String? _selectedProjectId;
  String? _selectedSubProjectId;
  String? _selectedSubProjectName;
  String? _selectedModeId;
  bool _excludeFromReport = false;

  DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  @override
  void initState() {
    super.initState();
    final t = widget.task;
    _blockNameController = TextEditingController(text: _getBlockName(t));
    _titleController = TextEditingController(text: _getTitle(t));
    _memoController = TextEditingController(text: _getMemo(t));
    _locationController = TextEditingController(text: _getLocation(t));
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
      _excludeFromReport = t.excludeFromReport == true;
      _startController =
          TextEditingController(text: _hhmm(t.startHour, t.startMinute));
      final end = DateTime(t.executionDate.year, t.executionDate.month,
              t.executionDate.day, t.startHour, t.startMinute)
          .add(Duration(minutes: t.estimatedDuration));
      _endController = TextEditingController(text: _hhmm(end.hour, end.minute));
      _durationController =
          TextEditingController(text: t.estimatedDuration.toString());
    } else {
      // ActualTask 用の初期値
      final at = t as actual.ActualTask;
      _excludeFromReport = at.excludeFromReport == true;
      _actualStartDate = _dateOnly(at.startTime.toLocal());
      _actualEndDate =
          _dateOnly((at.endTime ?? at.startTime).toLocal()); // 未設定なら開始日に揃える
      _startController = TextEditingController(
          text: TimelineHelpers.formatTimeForInput(at.startTime.toLocal()));
      _endController = TextEditingController(
          text: at.endTime != null
              ? TimelineHelpers.formatTimeForInput(at.endTime!.toLocal())
              : '');
      _durationController =
          TextEditingController(text: at.actualDuration.toString());
    }
  }

  @override
  void dispose() {
    _blockNameController.dispose();
    _titleController.dispose();
    _memoController.dispose();
    _locationController.dispose();
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
    final bool isMobileWidth = MediaQuery.of(context).size.width < 800;
    // Project/SubProject の独自入力欄はデフォルト fontSize=12 のため、
    // 画面内の通常 TextField（テーマ準拠）と文字サイズがズレる。
    final double unifiedFontSize =
        Theme.of(context).textTheme.titleMedium?.fontSize ?? 16.0;

    final taskProvider = Provider.of<TaskProvider>(context, listen: false);
    return CallbackShortcuts(
      bindings: {
        SingleActivator(LogicalKeyboardKey.keyS, control: true): () {
          _save(taskProvider);
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        title: Text(isBlock ? '予定の編集' : '実績の編集'),
        actions: [
          IconButton(
            tooltip: '削除',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _confirmAndDelete(
              Provider.of<TaskProvider>(context, listen: false),
            ),
          ),
          IconButton(
            tooltip: '保存',
            icon: const Icon(Icons.save_outlined),
            onPressed: () => _save(
              Provider.of<TaskProvider>(context, listen: false),
            ),
          )
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final bottomInset = MediaQuery.of(context).viewInsets.bottom;
            return SingleChildScrollView(
              padding: EdgeInsets.only(
                  left: 16, right: 16, top: 12, bottom: bottomInset + 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // トグル類は1行にまとめる
                  Row(
                    children: [
                      Expanded(
                        child: InputDecorator(
                          decoration: const InputDecoration(
                            labelText: '集計外',
                            border: OutlineInputBorder(),
                            floatingLabelBehavior: FloatingLabelBehavior.always,
                          ),
                          child: SizedBox(
                            height: 44,
                            child: Row(
                              children: [
                                const Tooltip(
                                  message: 'レポート（集計）に含めません',
                                  child: Icon(Icons.info_outline, size: 18),
                                ),
                                const Spacer(),
                                Switch.adaptive(
                                  value: _excludeFromReport,
                                  onChanged: (v) => setState(
                                    () => _excludeFromReport = v,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // ブロック名は予定・実績の両方で編集可能にする
                  TextField(
                    controller: _blockNameController,
                    decoration: const InputDecoration(
                      labelText: 'ブロック名',
                      border: OutlineInputBorder(),
                      floatingLabelBehavior: FloatingLabelBehavior.always,
                    ),
                  ),
                  const SizedBox(height: 12),
                  // 実績: 「開始日～実績時間」をブロック名直下へ移動
                  if (isActual) ...[
                    // 実績: 予定ブロック編集（BlockEditor）と同様に「開始日/終了日 + 時刻」
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            key: ValueKey(_fmtYmd(_actualStartDate)),
                            initialValue: _fmtYmd(_actualStartDate),
                            readOnly: true,
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: unifiedFontSize),
                            decoration: const InputDecoration(
                              labelText: '開始日',
                              border: OutlineInputBorder(),
                              floatingLabelBehavior:
                                  FloatingLabelBehavior.always,
                            ),
                            onTap: () async {
                              FocusScope.of(context).unfocus();
                              final initial =
                                  _actualStartDate ?? _dateOnly(DateTime.now());
                              final picked = await showDatePicker(
                                context: context,
                                initialDate: initial,
                                firstDate: DateTime(2020),
                                lastDate: DateTime(2100),
                              );
                              if (picked == null) return;
                              setState(() {
                                _actualStartDate = DateTime(
                                  picked.year,
                                  picked.month,
                                  picked.day,
                                );
                                // 終了日は開始日以上に揃える
                                if (_actualEndDate != null &&
                                    _actualEndDate!
                                        .isBefore(_actualStartDate!)) {
                                  _actualEndDate = _actualStartDate;
                                } else if (_actualEndDate == null) {
                                  _actualEndDate = _actualStartDate;
                                }
                                _recomputeDurationFromInputs();
                              });
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: _startController,
                            readOnly: isMobileWidth,
                            keyboardType: isMobileWidth
                                ? TextInputType.none
                                : TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: '開始時刻',
                              border: OutlineInputBorder(),
                              floatingLabelBehavior:
                                  FloatingLabelBehavior.always,
                            ),
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: unifiedFontSize),
                            onTap: isMobileWidth
                                ? () => _pickTime(_startController)
                                : null,
                            onChanged: isMobileWidth
                                ? null
                                : (_) => _recomputeDurationFromInputs(),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            key: ValueKey(
                                _fmtYmd(_effectiveActualEndDateForDisplay())),
                            initialValue:
                                _fmtYmd(_effectiveActualEndDateForDisplay()),
                            readOnly: true,
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: unifiedFontSize),
                            decoration: const InputDecoration(
                              labelText: '終了日',
                              border: OutlineInputBorder(),
                              floatingLabelBehavior:
                                  FloatingLabelBehavior.always,
                            ),
                            onTap: () async {
                              FocusScope.of(context).unfocus();
                              final start =
                                  _actualStartDate ?? _dateOnly(DateTime.now());
                              final initial = _actualEndDate ?? start;
                              final picked = await showDatePicker(
                                context: context,
                                initialDate: initial,
                                firstDate: DateTime(2020),
                                lastDate: DateTime(2100),
                              );
                              if (picked == null) return;
                              setState(() {
                                final normalized = DateTime(
                                  picked.year,
                                  picked.month,
                                  picked.day,
                                );
                                // endDate が startDate より前は許容しない
                                _actualEndDate =
                                    normalized.isBefore(start) ? start : normalized;
                                _recomputeDurationFromInputs();
                              });
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: _endController,
                            readOnly: isMobileWidth,
                            keyboardType: isMobileWidth
                                ? TextInputType.none
                                : TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: '終了時刻',
                              border: OutlineInputBorder(),
                              floatingLabelBehavior:
                                  FloatingLabelBehavior.always,
                            ),
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: unifiedFontSize),
                            onTap:
                                isMobileWidth ? () => _pickTime(_endController) : null,
                            onChanged: isMobileWidth
                                ? null
                                : (_) => _recomputeDurationFromInputs(),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _durationController,
                      decoration: const InputDecoration(
                        labelText: '実績時間(分)',
                        border: OutlineInputBorder(),
                        floatingLabelBehavior: FloatingLabelBehavior.always,
                      ),
                      keyboardType: TextInputType.number,
                    ),
                    const SizedBox(height: 12),
                  ],
                  TextField(
                    controller: _titleController,
                    decoration: const InputDecoration(
                      labelText: 'タスク名',
                      border: OutlineInputBorder(),
                      floatingLabelBehavior: FloatingLabelBehavior.always,
                    ),
                  ),
                  const SizedBox(height: 12),
                  ProjectInputField(
                    controller: _projectController,
                    // 「実績の編集」画面では、他の TextField と同じ InputDecoration を使い
                    // ラベル込みの高さを揃える（文字サイズは変更しない）。
                    labelText: 'プロジェクト',
                    floatingLabelBehavior: FloatingLabelBehavior.always,
                    allowIntrinsicHeight: true,
                    fontSize: unifiedFontSize,
                    useThemeDecoration: true,
                    onProjectChanged: (projectId) {
                      setState(() {
                        _selectedProjectId = projectId;
                      });
                    },
                    onAutoSave: () {},
                    withBackground: true,
                    useOutlineBorder: true,
                  ),
                  const SizedBox(height: 12),
                  SubProjectInputField(
                    controller: _subProjectController,
                    projectId: _selectedProjectId,
                    labelText: 'サブプロジェクト',
                    floatingLabelBehavior: FloatingLabelBehavior.always,
                    allowIntrinsicHeight: true,
                    fontSize: unifiedFontSize,
                    useThemeDecoration: true,
                    onSubProjectChanged: (subProjectId, subProjectName) {
                      setState(() {
                        _selectedSubProjectId = subProjectId;
                        _selectedSubProjectName = subProjectName;
                      });
                    },
                    onAutoSave: () {},
                    withBackground: true,
                    useOutlineBorder: true,
                  ),
                  const SizedBox(height: 12),
                  // モード・場所は1行で表示
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
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
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _locationController,
                          decoration: const InputDecoration(
                            labelText: '場所',
                            border: OutlineInputBorder(),
                            floatingLabelBehavior: FloatingLabelBehavior.always,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (isBlock) ...[
                    // 予定ブロック（この画面では従来通り、時刻のみ）
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _startController,
                            readOnly: isMobileWidth,
                            keyboardType: isMobileWidth
                                ? TextInputType.none
                                : TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: '開始時刻',
                              border: OutlineInputBorder(),
                              floatingLabelBehavior:
                                  FloatingLabelBehavior.always,
                            ),
                            onTap: isMobileWidth
                                ? () => _pickTime(_startController)
                                : null,
                            onChanged: isMobileWidth
                                ? null
                                : (_) => _recomputeDurationFromInputs(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: _endController,
                            readOnly: isMobileWidth,
                            keyboardType: isMobileWidth
                                ? TextInputType.none
                                : TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: '終了時刻',
                              border: OutlineInputBorder(),
                              floatingLabelBehavior:
                                  FloatingLabelBehavior.always,
                            ),
                            onTap: isMobileWidth
                                ? () => _pickTime(_endController)
                                : null,
                            onChanged: isMobileWidth
                                ? null
                                : (_) => _recomputeDurationFromInputs(),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _durationController,
                      decoration: const InputDecoration(
                        labelText: '予定時間(分)',
                        border: OutlineInputBorder(),
                        floatingLabelBehavior: FloatingLabelBehavior.always,
                      ),
                      keyboardType: TextInputType.number,
                    ),
                    const SizedBox(height: 12),
                  ],
                  // メモは一番下に移動
                  TextField(
                    controller: _memoController,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'メモ',
                      border: OutlineInputBorder(),
                      floatingLabelBehavior: FloatingLabelBehavior.always,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
        ),
      ),
    );
  }

  Future<void> _save(TaskProvider provider) async {
    try {
      final t = widget.task;
      // サブプロジェクトの最終確定: テキスト入力のみでオーバーレイ選択が走らなかった場合に備え
      // 現在のテキストと projectId から既存サブプロジェクトを解決し、なければクリアする
      if (_selectedProjectId != null) {
        final input = _subProjectController.text.trim();
        if (input.isEmpty) {
          _selectedSubProjectId = null;
          _selectedSubProjectName = null;
        } else {
          final all =
              SubProjectService.getSubProjectsByProjectId(_selectedProjectId!);
          final existing = all.firstWhere(
            (p) => p.name.trim().toLowerCase() == input.toLowerCase(),
            orElse: () =>
                SubProjectService.getSubProjectById('__not_found__') ??
                (throw Exception('__not_found__')),
          );
          if ((existing as dynamic).id == '__not_found__') {
            // テキストはあるが既存に一致しない場合、名称のみ保持しIDはクリア
            _selectedSubProjectId = null;
            _selectedSubProjectName = input;
          } else {
            _selectedSubProjectId = (existing as dynamic).id;
            _selectedSubProjectName = (existing as dynamic).name;
          }
        }
      }
      if (t is block.Block) {
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
          location: _locationController.text.trim().isEmpty
              ? null
              : _locationController.text.trim(),
          memo:
              _memoController.text.trim().isEmpty ? null : _memoController.text.trim(),
          excludeFromReport: _excludeFromReport,
          startHour: start.hour,
          startMinute: start.minute,
          estimatedDuration: duration,
          lastModified: DateTime.now(),
          version: t.version + 1,
        );
        await provider.updateBlock(updated);
      } else if (t is actual.ActualTask) {
        // 実績: 予定ブロック編集（BlockEditor）と同様に「開始日/終了日 + 時刻」で更新する
        final startPicked = _parseTimeInput(_startController.text);
        final endPicked = _parseTimeInput(_endController.text);
        DateTime newStart = t.startTime;
        DateTime? newEnd = t.endTime;
        final startDate = _actualStartDate ??
            DateTime(t.startTime.year, t.startTime.month, t.startTime.day);
        if (startPicked != null) {
          newStart = DateTime(
            startDate.year,
            startDate.month,
            startDate.day,
            startPicked.hour,
            startPicked.minute,
          );
        }
        if (endPicked != null) {
          final endDate = _actualEndDate ?? startDate;
          var computedEnd = DateTime(
            endDate.year,
            endDate.month,
            endDate.day,
            endPicked.hour,
            endPicked.minute,
          );
          // 予定ブロック編集と同様:
          // endDate==startDate かつ end < start の場合は翌日扱い
          if (_dateOnly(endDate) == _dateOnly(startDate) &&
              computedEnd.isBefore(newStart)) {
            computedEnd = computedEnd.add(const Duration(days: 1));
          }
          newEnd = computedEnd;
        } else {
          newEnd = null; // 空欄なら未設定
        }

        int newDuration =
            int.tryParse(_durationController.text.trim()) ?? t.actualDuration;
        if (newEnd != null) {
          final d = newEnd.difference(newStart).inMinutes;
          if (d > 0) {
            newDuration = d;
          }
        }

        final updated = t.copyWith(
          title: _titleController.text.trim().isEmpty
              ? t.title
              : _titleController.text.trim(),
          projectId: _selectedProjectId,
          subProjectId: _selectedSubProjectId,
          subProject: _selectedSubProjectName,
          modeId: _selectedModeId,
          blockName: _blockNameController.text.trim(),
          location: _locationController.text.trim().isEmpty
              ? null
              : _locationController.text.trim(),
          memo:
              _memoController.text.trim().isEmpty ? null : _memoController.text.trim(),
          excludeFromReport: _excludeFromReport,
          startTime: newStart,
          endTime: newEnd,
          // 正規形も同時に更新（UTC）
          startAt: newStart.toUtc(),
          endAtExclusive: newEnd?.toUtc(),
          // dayKeys/monthKeys は再生成させる（Phase 3 の toFirestoreWriteMap が ??= のため）
          dayKeys: null,
          monthKeys: null,
          actualDuration: newDuration,
          lastModified: DateTime.now(),
          version: t.version + 1,
        );
        await provider.updateActualTask(updated);
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('保存に失敗しました: $e')));
      }
    }
  }

  Future<void> _confirmAndDelete(TaskProvider provider) async {
    final t = widget.task;
    final title = (t is block.Block)
        ? (t.title.isEmpty ? '予定' : t.title)
        : (t is actual.ActualTask ? (t.title.isEmpty ? '実績' : t.title) : 'タスク');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('削除確認'),
        content: Text('「$title」を削除しますか？'),
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
    if (confirmed != true) return;

    try {
      if (t is block.Block) {
        await provider.deleteBlock(t.id);
      } else if (t is actual.ActualTask) {
        await provider.deleteActualTask(t.id);
      }
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('削除しました')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('削除に失敗しました: $e')));
    }
  }

  String _getBlockName(dynamic t) => (t is block.Block)
      ? (t.blockName ?? '')
      : (t is actual.ActualTask ? (t.blockName ?? '') : '');
  String _getTitle(dynamic t) =>
      (t is block.Block) ? t.title : (t is actual.ActualTask ? t.title : '');
  String _getMemo(dynamic t) =>
      (t is block.Block) ? (t.memo ?? '') : (t is actual.ActualTask ? (t.memo ?? '') : '');
  String _getLocation(dynamic t) =>
      (t is block.Block) ? (t.location ?? '') : (t is actual.ActualTask ? (t.location ?? '') : '');
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
    final parsed = _parseTimeInput(ctrl.text);
    final initial = parsed ?? TimeOfDay.now();
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked != null) {
      ctrl.text = _hhmm(picked.hour, picked.minute);
      // start/end を変更したら、duration を必ず追随させる（実績/予定とも）
      try {
        final startPicked = _parseTimeInput(_startController.text);
        final endPicked = _parseTimeInput(_endController.text);
        if (startPicked != null && endPicked != null) {
          // 日付は元タスクの startTime（日付）または executionDate を維持する
          final t = widget.task;
          DateTime startBaseDate;
          DateTime endBaseDate;
          if (t is actual.ActualTask) {
            // 実績は「開始日/終了日 + 時刻」なので、選択値を優先する
            startBaseDate = _actualStartDate ??
                DateTime(t.startTime.year, t.startTime.month, t.startTime.day);
            endBaseDate = _actualEndDate ??
                (t.endTime != null
                    ? DateTime(t.endTime!.year, t.endTime!.month, t.endTime!.day)
                    : startBaseDate);
          } else if (t is block.Block) {
            final base = DateTime(
                t.executionDate.year, t.executionDate.month, t.executionDate.day);
            startBaseDate = base;
            endBaseDate = base;
          } else {
            final base = DateTime.now();
            startBaseDate = DateTime(base.year, base.month, base.day);
            endBaseDate = DateTime(base.year, base.month, base.day);
          }
          final startDt = DateTime(startBaseDate.year, startBaseDate.month,
              startBaseDate.day, startPicked.hour, startPicked.minute);
          var endDt = DateTime(endBaseDate.year, endBaseDate.month,
              endBaseDate.day, endPicked.hour, endPicked.minute);
          // 予定ブロック編集と同様: 同日で end < start の場合は翌日扱い
          if (_dateOnly(endBaseDate) == _dateOnly(startBaseDate) &&
              endDt.isBefore(startDt)) {
            endDt = endDt.add(const Duration(days: 1));
          }
          final d = endDt.difference(startDt).inMinutes;
          if (d > 0) {
            _durationController.text = d.toString();
          }
        }
      } catch (_) {}
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
                    ? Icon(Icons.check,
                        size: 16,
                        color: Theme.of(context).colorScheme.secondary)
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

  // "HH:mm" / "HH:mm:ss" / "930" 等を許容（BlockEditorと同じパーサを使用）
  TimeOfDay? _parseTimeInput(String text) {
    final parsed = TimelineHelpers.parseTimeInput(text);
    if (parsed == null) return null;
    return TimeOfDay(hour: parsed.hour, minute: parsed.minute);
  }

  void _recomputeDurationFromInputs() {
    try {
      final startPicked = _parseTimeInput(_startController.text);
      final endPicked = _parseTimeInput(_endController.text);
      if (startPicked == null || endPicked == null) return;
      final t = widget.task;
      DateTime startBaseDate;
      DateTime endBaseDate;
      if (t is actual.ActualTask) {
        startBaseDate = _actualStartDate ??
            DateTime(t.startTime.year, t.startTime.month, t.startTime.day);
        endBaseDate = _actualEndDate ?? startBaseDate;
      } else if (t is block.Block) {
        final base =
            DateTime(t.executionDate.year, t.executionDate.month, t.executionDate.day);
        startBaseDate = base;
        endBaseDate = base;
      } else {
        final base = DateTime.now();
        startBaseDate = DateTime(base.year, base.month, base.day);
        endBaseDate = startBaseDate;
      }
      final startDt = DateTime(
        startBaseDate.year,
        startBaseDate.month,
        startBaseDate.day,
        startPicked.hour,
        startPicked.minute,
      );
      var endDt = DateTime(
        endBaseDate.year,
        endBaseDate.month,
        endBaseDate.day,
        endPicked.hour,
        endPicked.minute,
      );
      if (_dateOnly(endBaseDate) == _dateOnly(startBaseDate) &&
          endDt.isBefore(startDt)) {
        endDt = endDt.add(const Duration(days: 1));
      }
      final d = endDt.difference(startDt).inMinutes;
      if (d > 0) {
        _durationController.text = d.toString();
      }
    } catch (_) {}
  }

  DateTime _effectiveActualEndDateForDisplay() {
    // BlockEditorForm と同様: 同日で end < start の場合は「翌日」表示に寄せる
    final startDate = _actualStartDate ?? _dateOnly(DateTime.now());
    final endDate = _actualEndDate ?? startDate;
    final startT = _parseTimeInput(_startController.text);
    final endT = _parseTimeInput(_endController.text);
    if (startT == null || endT == null) return endDate;
    final startDt = DateTime(
      startDate.year,
      startDate.month,
      startDate.day,
      startT.hour,
      startT.minute,
    );
    var endDt = DateTime(
      endDate.year,
      endDate.month,
      endDate.day,
      endT.hour,
      endT.minute,
    );
    if (_dateOnly(endDate) == _dateOnly(startDate) && endDt.isBefore(startDt)) {
      endDt = endDt.add(const Duration(days: 1));
    }
    return DateTime(endDt.year, endDt.month, endDt.day);
  }

  String _fmtYmd(DateTime? d) {
    final x = d ?? _dateOnly(DateTime.now());
    return '${x.year}/${x.month.toString().padLeft(2, '0')}/${x.day.toString().padLeft(2, '0')}';
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
