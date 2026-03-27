import 'package:flutter/material.dart';
import '../../models/actual_task.dart' as actual;
import '../../models/inbox_task.dart' as inbox;
import '../../models/block.dart' as block;
import '../../providers/task_provider.dart';
import '../../services/project_service.dart';
import '../../services/sub_project_service.dart';
import '../../services/mode_service.dart';
import '../../services/inbox_task_service.dart';
import '../../widgets/mode_input_field.dart';
import '../project_input_field.dart';
import '../sub_project_input_field.dart';
import 'timeline_helpers.dart';
import 'inbox_link_input_field.dart';

class TaskCard extends StatefulWidget {
  final dynamic task;
  final TaskProvider taskProvider;
  final VoidCallback? onLongPress;
  final VoidCallback? onShowDetails;
  final VoidCallback? onStart;
  final VoidCallback? onRestart;
  final VoidCallback? onDelete;

  const TaskCard({
    super.key,
    required this.task,
    required this.taskProvider,
    this.onLongPress,
    this.onShowDetails,
    this.onStart,
    this.onRestart,
    this.onDelete,
  });

  @override
  State<TaskCard> createState() => _TaskCardState();
}

class _TaskCardState extends State<TaskCard> {
  // FocusNodeを追加
  final FocusNode _blockNameFocusNode = FocusNode();
  final FocusNode _taskNameFocusNode = FocusNode();
  final FocusNode _startTimeFocusNode = FocusNode();
  final FocusNode _endTimeFocusNode = FocusNode();
  final FocusNode _modeFocusNode = FocusNode();

  // 前回の値を記録（変更検出用）
  String _lastBlockNameValue = '';
  String _lastTaskNameValue = '';
  String _lastStartTimeValue = '';
  String _lastEndTimeValue = '';

  // 🔧 行のセル高さ（1行目のブロック名に合わせる）
  static const double _cellHeight = 36.0;

  // TextEditingControllers
  late TextEditingController _blockNameController;
  late TextEditingController _taskNameController;
  late TextEditingController _projectController;
  late TextEditingController _subProjectController;
  late TextEditingController _startTimeController;
  late TextEditingController _endTimeController;
  late TextEditingController _modeController;

  // Safety: if this State is ever reused for another task (due to missing/changed Keys),
  // force-unfocus and refresh controllers to avoid "writing to the wrong task".
  late String _taskIdentity;

  // Debug: layout measurement keys
  final GlobalKey _blockNameKey = GlobalKey();
  final GlobalKey _subProjectKey = GlobalKey();
  double? _lastBlockRight;
  double? _lastProjRight;
  double? _lastBlockWidth;
  double? _lastProjWidth;

  @override
  void initState() {
    super.initState();
    _taskIdentity = _identityOf(widget.task);
    _initializeControllers();
    _setupFocusListeners();
  }

  String _identityOf(dynamic task) {
    if (task is actual.ActualTask) return 'actual:${task.id}';
    if (task is inbox.InboxTask) return 'inbox:${task.id}';
    if (task is block.Block) return 'block:${task.id}';
    return 'unknown:${task.runtimeType}:${task.hashCode}';
  }

  Future<void> _pickInboxTaskAndLink() async {
    if (widget.task is! block.Block) return;
    final blk = widget.task as block.Block;
    if ((blk.taskId ?? '').isNotEmpty) return;
    FocusScope.of(context).unfocus();
    final all = InboxTaskService.getAllInboxTasks();
    final unlinked = all.where((t) =>
        t.blockId == null || t.blockId!.isEmpty).toList();
    final List<inbox.InboxTask> candidates;
    if (blk.projectId != null && blk.projectId!.isNotEmpty) {
      candidates = unlinked
          .where((t) => t.projectId == blk.projectId)
          .where((t) =>
              blk.subProjectId == null ||
              blk.subProjectId!.isEmpty ||
              t.subProjectId == blk.subProjectId)
          .toList();
    } else {
      final sameDate = (inbox.InboxTask t) =>
          t.executionDate.year == blk.executionDate.year &&
          t.executionDate.month == blk.executionDate.month &&
          t.executionDate.day == blk.executionDate.day;
      candidates = unlinked.where(sameDate).toList();
    }
    candidates.sort((a, b) => a.title.compareTo(b.title));
    if (candidates.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未割り当てのインボックスタスクがありません')),
        );
      }
      return;
    }
    final selectedIds = await showDialog<List<String>>(
      context: context,
      builder: (ctx) {
        final selected = <String>{};
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('インボックスタスクをリンク'),
            content: SizedBox(
              width: 420,
              height: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Expanded(
                    child: ListView.builder(
                      itemCount: candidates.length,
                      itemBuilder: (c, i) {
                        final t = candidates[i];
                        final checked = selected.contains(t.id);
                        return CheckboxListTile(
                          value: checked,
                          onChanged: (_) {
                            setDialogState(() {
                              if (checked) {
                                selected.remove(t.id);
                              } else {
                                selected.add(t.id);
                              }
                            });
                          },
                          secondary: const Icon(Icons.inbox),
                          title: Text(t.title,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                              '${t.executionDate.month}/${t.executionDate.day}  ${t.estimatedDuration}分'),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: selected.isEmpty
                          ? null
                          : () => Navigator.of(ctx).pop(selected.toList()),
                      child: Text(selected.isEmpty
                          ? 'タスクを選択してからリンク'
                          : '選択した${selected.length}件をリンク'),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('キャンセル')),
            ],
          ),
        );
      },
    );
    if (selectedIds == null || selectedIds.isEmpty) return;
    for (final id in selectedIds) {
      final chosen = InboxTaskService.getInboxTask(id);
      if (chosen == null) continue;
      final updated = chosen.copyWith(
        blockId: (blk.cloudId != null && blk.cloudId!.isNotEmpty)
            ? blk.cloudId!
            : blk.id,
      );
      await widget.taskProvider.updateInboxTask(updated);
    }
  }

  @override
  void didUpdateWidget(covariant TaskCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newIdentity = _identityOf(widget.task);
    if (newIdentity != _taskIdentity) {
      _taskIdentity = newIdentity;
      // Prevent "commit on blur" from applying to a new task instance.
      _blockNameFocusNode.unfocus();
      _taskNameFocusNode.unfocus();
      _startTimeFocusNode.unfocus();
      _endTimeFocusNode.unfocus();
      _modeFocusNode.unfocus();

      final newBlockName = _getBlockName();
      final newTaskName = _getTaskName();
      final newStartText = _getStartTimeText();
      final newEndText = _getEndTimeText();
      final newModeName = _getModeName() ?? '';

      _blockNameController.text = newBlockName;
      _taskNameController.text = newTaskName;
      _startTimeController.text = newStartText;
      _endTimeController.text = newEndText;
      _modeController.text = newModeName;
      _projectController.text = _getProjectName();
      _subProjectController.text = _getSubProjectName();

      _lastBlockNameValue = newBlockName;
      _lastTaskNameValue = newTaskName;
      _lastStartTimeValue = newStartText;
      _lastEndTimeValue = newEndText;
    }
    // タスクの主要フィールドが変わったら表示値を更新（編集中は上書きしない）
    final newBlockName = _getBlockName();
    final newTaskName = _getTaskName();
    final newStartText = _getStartTimeText();
    final newEndText = _getEndTimeText();

    if (!_blockNameFocusNode.hasFocus &&
        _blockNameController.text != newBlockName) {
      _blockNameController.text = newBlockName;
      _lastBlockNameValue = newBlockName;
    }
    if (!_taskNameFocusNode.hasFocus &&
        _taskNameController.text != newTaskName) {
      _taskNameController.text = newTaskName;
      _lastTaskNameValue = newTaskName;
    }
    if (!_startTimeFocusNode.hasFocus &&
        _startTimeController.text != newStartText) {
      _startTimeController.text = newStartText;
      _lastStartTimeValue = newStartText;
    }
    if (!_endTimeFocusNode.hasFocus && _endTimeController.text != newEndText) {
      _endTimeController.text = newEndText;
      _lastEndTimeValue = newEndText;
    }
    final newModeName = _getModeName() ?? '';
    if (!_modeFocusNode.hasFocus && _modeController.text != newModeName) {
      _modeController.text = newModeName;
    }
    // サブプロジェクト名は編集中は上書きしない
    final newSubProjectName = _getSubProjectName();
    if (!_subProjectController.selection.isValid &&
        _subProjectController.text != newSubProjectName) {
      _subProjectController.text = newSubProjectName;
    }
  }

  void _initializeControllers() {
    _blockNameController = TextEditingController(text: _getBlockName());
    _taskNameController = TextEditingController(text: _getTaskName());
    _projectController = TextEditingController(text: _getProjectName());
    _subProjectController = TextEditingController(text: _getSubProjectName());
    _startTimeController = TextEditingController(text: _getStartTimeText());
    _endTimeController = TextEditingController(text: _getEndTimeText());
    _modeController = TextEditingController(text: _getModeName() ?? '');

    // 初期値を記録
    _lastBlockNameValue = _blockNameController.text;
    _lastTaskNameValue = _taskNameController.text;
    _lastStartTimeValue = _startTimeController.text;
    _lastEndTimeValue = _endTimeController.text;
  }

  void _setupFocusListeners() {
    // ブロック名のフォーカスリスナー
    _blockNameFocusNode.addListener(() {
      if (!_blockNameFocusNode.hasFocus) {
        final currentValue = _blockNameController.text;
        if (currentValue != _lastBlockNameValue) {
          _updateBlockName(currentValue);
          _lastBlockNameValue = currentValue;
        }
      } else {
        _lastBlockNameValue = _blockNameController.text;
      }
    });

    // タスク名のフォーカスリスナー
    _taskNameFocusNode.addListener(() {
      if (!_taskNameFocusNode.hasFocus) {
        final currentValue = _taskNameController.text;
        if (currentValue != _lastTaskNameValue) {
          _updateTaskName(currentValue);
          _lastTaskNameValue = currentValue;
        }
      } else {
        _lastTaskNameValue = _taskNameController.text;
        // フォーカス時（=タップ）に未割当インボックスタスク候補を表示（予定ブロックのみ）
        _pickInboxTaskAndLink();
      }
    });

    // 開始時刻のフォーカスリスナー
    _startTimeFocusNode.addListener(() {
      if (!_startTimeFocusNode.hasFocus) {
        final currentValue = _startTimeController.text;
        if (currentValue != _lastStartTimeValue) {
          _updateStartTime(currentValue);
          _lastStartTimeValue = currentValue;
        }
      } else {
        _lastStartTimeValue = _startTimeController.text;
      }
    });

    // 終了時刻のフォーカスリスナー
    _endTimeFocusNode.addListener(() {
      if (!_endTimeFocusNode.hasFocus) {
        final currentValue = _endTimeController.text;
        if (currentValue != _lastEndTimeValue) {
          _updateEndTime(currentValue);
          _lastEndTimeValue = currentValue;
        }
      } else {
        _lastEndTimeValue = _endTimeController.text;
      }
    });
  }

  @override
  void dispose() {
    _blockNameFocusNode.dispose();
    _taskNameFocusNode.dispose();
    _startTimeFocusNode.dispose();
    _endTimeFocusNode.dispose();
    _modeFocusNode.dispose();
    _blockNameController.dispose();
    _taskNameController.dispose();
    _projectController.dispose();
    _subProjectController.dispose();
    _startTimeController.dispose();
    _endTimeController.dispose();
    _modeController.dispose();
    super.dispose();
  }

  String _getBlockName() {
    if (widget.task is actual.ActualTask) {
      return (widget.task as actual.ActualTask).blockName ?? '';
    } else if (widget.task is block.Block) {
      // 🔧 Block用のブロック名取得を追加
      return (widget.task as block.Block).blockName ?? '';
    }
    return '';
  }

  String _getTaskName() {
    if (widget.task is actual.ActualTask) {
      return (widget.task as actual.ActualTask).title;
    } else if (widget.task is inbox.InboxTask) {
      return (widget.task as inbox.InboxTask).title;
    } else if (widget.task is block.Block) {
      // 🔧 Block用のタスク名取得を追加
      return (widget.task as block.Block).title;
    }
    return '';
  }

  String _getProjectName() {
    final projectId = widget.task.projectId;
    if (projectId == null) return '';
    final project = ProjectService.getProjectById(projectId);
    return project?.name ?? '';
  }

  String _getSubProjectName() {
    if (widget.task is actual.ActualTask) {
      return (widget.task as actual.ActualTask).subProject ?? '';
    } else if (widget.task is inbox.InboxTask) {
      // InboxTaskの場合、subProjectIdから名前を取得
      final subProjectId = (widget.task as inbox.InboxTask).subProjectId;
      if (subProjectId != null) {
        final subProject = SubProjectService.getSubProjectById(subProjectId);
        return subProject?.name ?? '';
      }
    } else if (widget.task is block.Block) {
      final blockTask = widget.task as block.Block;
      // まずsubProject名を確認、なければsubProjectIdから取得
      if (blockTask.subProject != null && blockTask.subProject!.isNotEmpty) {
        return blockTask.subProject!;
      } else if (blockTask.subProjectId != null) {
        final subProject = SubProjectService.getSubProjectById(
          blockTask.subProjectId!,
        );
        return subProject?.name ?? '';
      }
    }
    return '';
  }

  String _getLocationText() {
    if (widget.task is actual.ActualTask) {
      return (widget.task as actual.ActualTask).location ?? '';
    }
    if (widget.task is block.Block) {
      return (widget.task as block.Block).location ?? '';
    }
    return '';
  }

  String? _getModeName() {
    String? modeId;
    if (widget.task is actual.ActualTask) {
      modeId = (widget.task as actual.ActualTask).modeId;
    } else if (widget.task is block.Block) {
      modeId = (widget.task as block.Block).modeId;
    }
    if (modeId == null || modeId.isEmpty) return null;
    final mode = ModeService.getModeById(modeId);
    return mode?.name;
  }

  String _getStartTimeText() {
    if (widget.task is actual.ActualTask) {
      final startTime = (widget.task as actual.ActualTask).startTime;
      return TimelineHelpers.formatTimeForInput(startTime);
    } else if (widget.task is inbox.InboxTask) {
      final task = widget.task as inbox.InboxTask;
      if (task.startHour != null && task.startMinute != null) {
        final startTime = DateTime(
          task.executionDate.year,
          task.executionDate.month,
          task.executionDate.day,
          task.startHour!,
          task.startMinute!,
        );
        return TimelineHelpers.formatTimeForInput(startTime);
      }
    } else if (widget.task is block.Block) {
      final task = widget.task as block.Block;
      final startTime = DateTime(
        task.executionDate.year,
        task.executionDate.month,
        task.executionDate.day,
        task.startHour,
        task.startMinute,
      );
      return TimelineHelpers.formatTimeForInput(startTime);
    }
    return '';
  }

  String _getEndTimeText() {
    if (widget.task is actual.ActualTask) {
      final task = widget.task as actual.ActualTask;

      if (task.isRunning) {
        // 実行中の場合は「実行中」と表示
        return '実行中';
      } else if (task.endTime != null) {
        // 完了・一時停止で終了時刻がある場合
        return TimelineHelpers.formatTimeForInput(task.endTime!);
      } else {
        // 終了時刻がない場合（通常ありえないが安全のため）
        return '未設定';
      }
    } else if (widget.task is inbox.InboxTask) {
      final task = widget.task as inbox.InboxTask;
      if (task.startHour != null && task.startMinute != null) {
        final startTime = DateTime(
          task.executionDate.year,
          task.executionDate.month,
          task.executionDate.day,
          task.startHour!,
          task.startMinute!,
        );
        final endTime =
            startTime.add(Duration(minutes: task.estimatedDuration));
        return TimelineHelpers.formatTimeForInput(endTime);
      }
    } else if (widget.task is block.Block) {
      final task = widget.task as block.Block;
      final endTime = task.endDateTime; // Blockモデルのゲッターを使用
      return TimelineHelpers.formatTimeForInput(endTime);
    }
    return '';
  }

  bool _isTaskCompleted() {
    return widget.task is actual.ActualTask &&
        (widget.task as actual.ActualTask).isCompleted;
  }

  bool _isTaskPaused() {
    return widget.task is actual.ActualTask &&
        (widget.task as actual.ActualTask).isPaused;
  }

  bool _isTaskRunning() {
    return widget.task is actual.ActualTask &&
        (widget.task as actual.ActualTask).isRunning;
  }

  Color _getTextColor() {
    final scheme = Theme.of(context).colorScheme;
    if (_isTaskCompleted() || _isTaskPaused()) {
      return Theme.of(context).textTheme.bodySmall?.color ??
          scheme.onSurfaceVariant;
    }
    return Theme.of(context).textTheme.bodyLarge?.color ?? scheme.onSurface;
  }

  String _getWorkTimeText() {
    if (widget.task is actual.ActualTask) {
      final task = widget.task as actual.ActualTask;

      if (task.endTime != null) {
        final duration = task.endTime!.difference(task.startTime);
        final hours = duration.inHours;
        final minutes = duration.inMinutes % 60;
        final seconds = duration.inSeconds % 60;

        return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
      } else if (task.isRunning) {
        final duration = DateTime.now().difference(task.startTime);
        final hours = duration.inHours;
        final minutes = duration.inMinutes % 60;
        final seconds = duration.inSeconds % 60;

        return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
      } else {
        return '00:00:00';
      }
    } else if (widget.task is inbox.InboxTask) {
      final task = widget.task as inbox.InboxTask;
      final hours = task.estimatedDuration ~/ 60;
      final minutes = task.estimatedDuration % 60;
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:00';
    } else if (widget.task is block.Block) {
      final task = widget.task as block.Block;
      final hours = task.estimatedDuration ~/ 60;
      final minutes = task.estimatedDuration % 60;
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:00';
    }
    return '00:00:00';
  }

  // ステータスアイコンの取得
  IconData _getStatusIcon() {
    if (widget.task is actual.ActualTask) {
      final actualTask = widget.task as actual.ActualTask;
      if (actualTask.isPaused) {
        return Icons.pause; // 中断は縦棒二つ
      }
      if (actualTask.isCompleted) {
        return Icons.check_circle; // 完了はチェック
      }
      if (actualTask.isRunning) {
        return Icons.stop_circle; // 実行中は停止マーク
      }
      return Icons.check_circle; // デフォルト（安全側）
    } else {
      // 予定ブロック
      if (widget.task is block.Block) {
        final b = widget.task as block.Block;
        if (b.isEvent == true) {
          try {
            final end = b.endDateTime; // Blockモデルのゲッター
            final ended = DateTime.now().isAfter(end);
            return ended ? Icons.check_circle : Icons.event;
          } catch (_) {
            return Icons.event;
          }
        }
      }
      return Icons.play_circle;
    }
  }

  // 中断時は塗りつぶしの円バッジに白い一時停止マークで表示
  Widget _buildStatusIconWidget() {
    final scheme = Theme.of(context).colorScheme;
    // イベントブロックも表示（時間経過後はチェック、未経過はイベント）
    if (widget.task is actual.ActualTask && _isTaskPaused()) {
      return Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          // 実績（paused）は「残タスク」より目立たせない
          color: scheme.onSurfaceVariant.withOpacity(0.25),
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Icon(Icons.pause,
            size: 16, color: scheme.onSurfaceVariant.withOpacity(0.9)),
      );
    }
    return Icon(
      _getStatusIcon(),
      size: 28,
      color: _statusIconColor(context),
    );
  }

  Color _statusIconColor(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (widget.task is actual.ActualTask) {
      final t = widget.task as actual.ActualTask;
      // 実績は「やった/記録済み」なので抑えめ（残タスクの再生を最優先で目立たせる）
      if (t.isRunning) return scheme.onSurfaceVariant.withOpacity(0.85);
      if (t.isPaused) return scheme.onSurfaceVariant.withOpacity(0.70);
      if (t.isCompleted) return scheme.onSurfaceVariant.withOpacity(0.60);
      return scheme.onSurfaceVariant.withOpacity(0.60);
    }

    // 予定ブロック（イベント）
    if (widget.task is block.Block) {
      final b = widget.task as block.Block;
      if (b.isEvent == true) {
        try {
          final ended = DateTime.now().isAfter(b.endDateTime);
          return ended
              ? scheme.onSurfaceVariant.withOpacity(0.60)
              : scheme.tertiary.withOpacity(0.95);
        } catch (_) {
          return scheme.tertiary.withOpacity(0.95);
        }
      }
    }

    // 残タスク（予定/Inbox）は最優先
    return scheme.primary;
  }

  // ステータスアイコンのアクション
  VoidCallback? _getStatusIconAction() {
    if (widget.task is actual.ActualTask) {
      // 実績タスクの場合
      if (_isTaskCompleted()) {
        // 完了済みは、予定ブロックを追加せず、そのまま実績記録を再開
        return widget.onRestart; // onRestart を再開（プランなし）に差し替え先で実装
      } else if (_isTaskPaused()) {
        return widget.onRestart; // 一時停止は再開
      } else if (_isTaskRunning()) {
        return null; // 実行中は何もしない
      } else {
        return null;
      }
    } else {
      return widget.onStart;
    }
  }

  // ステータスアイコンのツールチップ
  String _getStatusIconTooltip() {
    if (widget.task is actual.ActualTask) {
      if (_isTaskCompleted()) {
        return '予定を作らず、そのまま実績の記録を再開する。';
      } else if (_isTaskPaused()) {
        return '中断（再開可能）';
      } else if (_isTaskRunning()) {
        return '実行中';
      } else {
        return '実績タスク';
      }
    } else {
      if (widget.task is block.Block &&
          (widget.task as block.Block).isEvent == true) {
        return '開始（イベント）';
      }
      return '開始';
    }
  }

  @override
  Widget build(BuildContext context) {
    // Debugログ抑止: レイアウトログは無効化
    WidgetsBinding.instance.addPostFrameCallback((_) => _logLayoutIfChanged());
    // 入力欄とカード背景を必ず同一色にする（タイムラインの色バグ防止）
    final cardBackgroundColor = Theme.of(context).colorScheme.surface;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor, width: 1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // 左側：ステータス（再生/チェック）ボタン（縦中央）
            SizedBox(
              width: 48,
              child: Center(
                child: IconButton(
                  icon: _buildStatusIconWidget(),
                  onPressed: _getStatusIconAction() ?? () {},
                  tooltip: _getStatusIconTooltip(),
                  padding: EdgeInsets.zero,
                ),
              ),
            ),
            const SizedBox(width: 8),
            // 中央：メイン内容
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final double centralWidth = constraints.maxWidth;
                  const double gap = 4.0;
                  final double leftWidth =
                      ((centralWidth - gap) * 7 / 15).floorToDouble();
                  final double rightWidth = centralWidth - leftWidth - gap;
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 左カラム（ブロック名 と プロジェクト+サブプロジェクト）
                      SizedBox(
                        width: leftWidth,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // ブロック名セル（左はプロジェクトの左、右はサブプロジェクトの右に揃えるため、左カラム全幅を使用）
                            SizedBox(
                              width: double.infinity,
                              child: Container(
                                key: _blockNameKey,
                                child: SizedBox(
                                  width: double.infinity,
                                  height: _cellHeight,
                                  child: TextField(
                                    controller: _blockNameController,
                                    focusNode: _blockNameFocusNode,
                                    style: const TextStyle(
                                        fontSize: 12, height: 1.0),
                                    textAlign: TextAlign.left,
                                    textAlignVertical: TextAlignVertical.center,
                                    decoration: InputDecoration(
                                      hintText: 'ブロック名',
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(4),
                                        borderSide: BorderSide(
                                            color:
                                                Theme.of(context).dividerColor),
                                      ),
                                      enabledBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(4),
                                        borderSide: BorderSide(
                                            color:
                                                Theme.of(context).dividerColor),
                                      ),
                                      focusedBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(4),
                                        borderSide: BorderSide(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .primary,
                                            width: 1.5),
                                      ),
                                      isCollapsed: true,
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                        horizontal: 10.0,
                                        vertical: 16.0,
                                      ),
                                      filled: true,
                                      fillColor: cardBackgroundColor,
                                      constraints: const BoxConstraints(
                                        minHeight: 36,
                                        maxHeight: 36,
                                      ),
                                    ),
                                    textInputAction: TextInputAction.next,
                                    onSubmitted: (value) {
                                      _taskNameFocusNode.requestFocus();
                                    },
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 4),
                            // プロジェクト+サブプロジェクト（同じ左カラム幅を共有）
                            SizedBox(
                              width: double.infinity,
                              child: Row(
                                children: [
                                  Expanded(
                                    flex: 3,
                                    child: SizedBox(
                                      height: _cellHeight,
                                      child: ProjectInputField(
                                        controller: _projectController,
                                        onProjectChanged: (projectId) =>
                                            _updateProject(projectId),
                                        onAutoSave: () {},
                                        hintText:
                                            (_projectController.text.isEmpty)
                                                ? 'プロジェクト'
                                                : null,
                                        fillColor: cardBackgroundColor,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    flex: 4,
                                    child: Container(
                                      key: _subProjectKey,
                                      child: SizedBox(
                                        height: _cellHeight,
                                        child: SubProjectInputField(
                                          controller: _subProjectController,
                                          projectId: widget.task.projectId,
                                          onSubProjectChanged: (subProjectId,
                                                  subProjectName) =>
                                              _updateSubProject(
                                                  subProjectId, subProjectName),
                                          onAutoSave: () {},
                                          hintText: (_subProjectController
                                                  .text.isEmpty)
                                              ? 'サブプロジェクト'
                                              : null,
                                          fillColor: cardBackgroundColor,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 4),
                            // 場所（あれば）
                            Builder(builder: (context) {
                              final loc = _getLocationText();
                              if (loc.isEmpty) return const SizedBox.shrink();
                              return Row(
                                children: [
                                  Icon(Icons.place,
                                      size: 14,
                                      color: Theme.of(context)
                                          .iconTheme
                                          .color
                                          ?.withOpacity( 0.6)),
                                  const SizedBox(width: 4),
                                  Flexible(
                                    child: Text(
                                      loc,
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.color),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              );
                            }),
                            const SizedBox(height: 4),
                          ],
                        ),
                      ),
                      const SizedBox(width: gap),
                      // 右カラム（タスク名 と モード+時間）
                      SizedBox(
                        width: rightWidth,
                        child: Column(
                          children: [
                            // タスク名セル（ブロック未リンク時は候補オーバーレイで割当、その他はテキスト編集）
                            SizedBox(
                              height: _cellHeight,
                              child: Builder(
                                builder: (context) {
                                  if (widget.task is block.Block) {
                                    final blk = widget.task as block.Block;
                                    // 常に候補入力欄を表示（既に同ブロックに割当済みも候補に含める）
                                    return InboxLinkInputField(
                                      controller: _taskNameController,
                                      blockId: blk.id,
                                      executionDate: blk.executionDate,
                                      projectId: blk.projectId,
                                      subProjectId: blk.subProjectId,
                                      hintText: 'タスク名',
                                      onSubmitText: (v) => _updateTaskName(v),
                                      onLink: (List<inbox.InboxTask> list) async {
                                        for (final selected in list) {
                                          final updated = selected.copyWith(
                                            blockId: (blk.cloudId != null &&
                                                    blk.cloudId!.isNotEmpty)
                                                ? blk.cloudId!
                                                : blk.id,
                                            executionDate: blk.executionDate,
                                            startHour: blk.startHour,
                                            startMinute: blk.startMinute,
                                            projectId:
                                                blk.projectId ?? const Object(),
                                            subProjectId: blk.subProjectId ??
                                                const Object(),
                                            lastModified: DateTime.now(),
                                            version: selected.version + 1,
                                          );
                                          await widget.taskProvider
                                              .updateInboxTask(updated);
                                        }
                                        if (mounted && list.isNotEmpty) {
                                          setState(() {
                                            _taskNameController.text =
                                                list.length == 1
                                                    ? list.first.title
                                                    : '${list.length}件をリンク';
                                          });
                                        }
                                      },
                                    );
                                  }
                                  return TextField(
                                    controller: _taskNameController,
                                    focusNode: _taskNameFocusNode,
                                    style: const TextStyle(
                                        fontSize: 12, height: 1.0),
                                    textAlign: TextAlign.left,
                                    textAlignVertical: TextAlignVertical.center,
                                    decoration: InputDecoration(
                                      hintText: 'タスク名',
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(4),
                                        borderSide: BorderSide(
                                            color:
                                                Theme.of(context).dividerColor),
                                      ),
                                      enabledBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(4),
                                        borderSide: BorderSide(
                                            color:
                                                Theme.of(context).dividerColor),
                                      ),
                                      focusedBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(4),
                                        borderSide: BorderSide(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .primary,
                                            width: 1.5),
                                      ),
                                      isCollapsed: true,
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                        horizontal: 10.0,
                                        vertical: 16.0,
                                      ),
                                      filled: true,
                                      fillColor: cardBackgroundColor,
                                      constraints: const BoxConstraints(
                                        minHeight: 36,
                                        maxHeight: 36,
                                      ),
                                      // 右端のリンクアイコンは廃止
                                    ),
                                    textInputAction: TextInputAction.next,
                                    onSubmitted: (value) {
                                      FocusScope.of(context)
                                          .nextFocus(); // プロジェクトへ
                                    },
                                  );
                                },
                              ),
                            ),
                            const SizedBox(height: 4),
                            // モード・時間群
                            Row(
                              children: [
                                // モード（プルダウン）
                                Expanded(
                                  flex: 2,
                                  child: SizedBox(
                                    height: _cellHeight,
                                    child: ModeInputField(
                                      controller: _modeController,
                                      onModeChanged: (modeId) =>
                                          _updateMode(modeId),
                                      onAutoSave: () {},
                                      hintText: 'モード',
                                      fillColor: cardBackgroundColor,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                // 開始時刻
                                Expanded(
                                  flex: 2,
                                  child: SizedBox(
                                    height: _cellHeight,
                                    child: TextField(
                                      controller: _startTimeController,
                                      focusNode: _startTimeFocusNode,
                                      style: const TextStyle(
                                          fontSize: 12, height: 1.0),
                                      textAlign: TextAlign.center,
                                      textAlignVertical:
                                          TextAlignVertical.center,
                                      decoration: InputDecoration(
                                        hintText: '開始時刻',
                                        border: OutlineInputBorder(
                                          borderRadius:
                                              BorderRadius.circular(4),
                                          borderSide: BorderSide(
                                              color: Theme.of(context)
                                                  .dividerColor),
                                        ),
                                        enabledBorder: OutlineInputBorder(
                                          borderRadius:
                                              BorderRadius.circular(4),
                                          borderSide: BorderSide(
                                              color: Theme.of(context)
                                                  .dividerColor),
                                        ),
                                        focusedBorder: OutlineInputBorder(
                                          borderRadius:
                                              BorderRadius.circular(4),
                                          borderSide: BorderSide(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .primary,
                                              width: 1.5),
                                        ),
                                        isCollapsed: true,
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                          horizontal: 10.0,
                                          vertical: 16.0,
                                        ),
                                        filled: true,
                                        fillColor: cardBackgroundColor,
                                        constraints: const BoxConstraints(
                                          minHeight: 36,
                                          maxHeight: 36,
                                        ),
                                      ),
                                      textInputAction: TextInputAction.next,
                                      onSubmitted: (value) {
                                        _updateStartTime(value);
                                        _endTimeFocusNode.requestFocus();
                                      },
                                    ),
                                  ),
                                ),
                                // 矢印アイコン
                                SizedBox(
                                  width: 20,
                                  height: _cellHeight,
                                  child: Center(
                                    child: Icon(
                                      Icons.arrow_forward,
                                      size: 14,
                                      color: _getTextColor(),
                                    ),
                                  ),
                                ),
                                // 終了時刻
                                Expanded(
                                  flex: 2,
                                  child: _isTaskRunning()
                                      ? SizedBox(
                                          height: _cellHeight,
                                          child: Container(
                                            decoration: BoxDecoration(
                                              color: cardBackgroundColor,
                                              borderRadius:
                                                  BorderRadius.circular(2),
                                            ),
                                            alignment: Alignment.center,
                                            child: Text(
                                              '実行中',
                                              style: TextStyle(
                                                  fontSize: 12,
                                                  color: Theme.of(context)
                                                      .textTheme
                                                      .bodySmall
                                                      ?.color),
                                              textAlign: TextAlign.center,
                                            ),
                                          ),
                                        )
                                      : SizedBox(
                                          height: _cellHeight,
                                          child: TextField(
                                            controller: _endTimeController,
                                            focusNode: _endTimeFocusNode,
                                            style: const TextStyle(
                                                fontSize: 12, height: 1.0),
                                            textAlign: TextAlign.center,
                                            textAlignVertical:
                                                TextAlignVertical.center,
                                            decoration: InputDecoration(
                                              hintText: '終了時刻',
                                              border: OutlineInputBorder(
                                                borderRadius:
                                                    BorderRadius.circular(4),
                                                borderSide: BorderSide(
                                                    color: Theme.of(context)
                                                        .dividerColor),
                                              ),
                                              enabledBorder: OutlineInputBorder(
                                                borderRadius:
                                                    BorderRadius.circular(4),
                                                borderSide: BorderSide(
                                                    color: Theme.of(context)
                                                        .dividerColor),
                                              ),
                                              focusedBorder: OutlineInputBorder(
                                                borderRadius:
                                                    BorderRadius.circular(4),
                                                borderSide: BorderSide(
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .primary,
                                                    width: 1.5),
                                              ),
                                              isCollapsed: true,
                                              contentPadding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 10.0,
                                                vertical: 16.0,
                                              ),
                                              filled: true,
                                              fillColor: cardBackgroundColor,
                                              constraints: const BoxConstraints(
                                                minHeight: 36,
                                                maxHeight: 36,
                                              ),
                                            ),
                                            textInputAction:
                                                TextInputAction.next,
                                            onSubmitted: (value) {
                                              _updateEndTime(value);
                                              // 作業時間の再計算は _updateEndTime 内で反映される
                                              FocusScope.of(context).unfocus();
                                            },
                                          ),
                                        ),
                                ),
                                const SizedBox(width: 4),
                                // 作業時間
                                Expanded(
                                  flex: 2,
                                  child: SizedBox(
                                    height: _cellHeight,
                                    child: TextField(
                                      controller: TextEditingController(
                                        text: _getWorkTimeText(),
                                      ),
                                      readOnly: true,
                                      style: const TextStyle(
                                          fontSize: 12, height: 1.0),
                                      textAlign: TextAlign.center,
                                      textAlignVertical:
                                          TextAlignVertical.center,
                                      decoration: InputDecoration(
                                        hintText: '作業時間',
                                        border: OutlineInputBorder(
                                          borderRadius:
                                              BorderRadius.circular(4),
                                          borderSide: BorderSide(
                                              color: Theme.of(context)
                                                  .dividerColor),
                                        ),
                                        enabledBorder: OutlineInputBorder(
                                          borderRadius:
                                              BorderRadius.circular(4),
                                          borderSide: BorderSide(
                                              color: Theme.of(context)
                                                  .dividerColor),
                                        ),
                                        focusedBorder: OutlineInputBorder(
                                          borderRadius:
                                              BorderRadius.circular(4),
                                          borderSide: BorderSide(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .primary,
                                              width: 1.5),
                                        ),
                                        isCollapsed: true,
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                          horizontal: 10.0,
                                          vertical: 16.0,
                                        ),
                                        filled: true,
                                        fillColor: cardBackgroundColor,
                                        constraints: const BoxConstraints(
                                          minHeight: 36,
                                          maxHeight: 36,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(width: 8),
            // 右側：縦ボタン（削除の下に詳細ボタン）
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // PC版: 行右端のメニューアイコンから操作メニューを開く
                IconButton(
                  icon: const Icon(
                    Icons.more_vert,
                    size: 18,
                  ),
                  onPressed: widget.onLongPress,
                  tooltip: 'メニュー',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 24),
                ),
                const SizedBox(height: 4),
                IconButton(
                  icon: const Icon(
                    Icons.delete_outline,
                    size: 18,
                  ),
                  onPressed: widget.onDelete,
                  tooltip: '削除',
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 24), // Added constraint
                ),
                const SizedBox(height: 4),
                IconButton(
                  icon: const Icon(
                    Icons.info_outline,
                    size: 18,
                  ),
                  onPressed: widget.onShowDetails,
                  tooltip: '詳細',
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 24), // Added constraint
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _logLayoutIfChanged() {
    try {
      final rbBlock =
          _blockNameKey.currentContext?.findRenderObject() as RenderBox?;
      final rbSub =
          _subProjectKey.currentContext?.findRenderObject() as RenderBox?;
      if (rbBlock == null || rbSub == null) return;

      final blockSize = rbBlock.size;
      final projSize = rbSub.size;
      final blockPos = rbBlock.localToGlobal(Offset.zero);
      final projPos = rbSub.localToGlobal(Offset.zero);

      final blockRight = blockPos.dx + blockSize.width;
      final projRight = projPos.dx + projSize.width;

      final changed = _lastBlockRight != blockRight ||
          _lastProjRight != projRight ||
          _lastBlockWidth != blockSize.width ||
          _lastProjWidth != projSize.width;
      if (!changed) return;

      _lastBlockRight = blockRight;
      _lastProjRight = projRight;
      _lastBlockWidth = blockSize.width;
      _lastProjWidth = projSize.width;

      // ここで取得していたtaskId/taskTypeはログ専用だったため削除
    } catch (e) {
      // ignore
    }
  }

  // 更新メソッド群
  void _updateBlockName(String value) {
    if (widget.task is actual.ActualTask) {
      final task = widget.task as actual.ActualTask;
      task.blockName = value;
      widget.taskProvider.updateActualTask(task);
    } else if (widget.task is block.Block) {
      final task = widget.task as block.Block;

      // copyWithを使用して新しいBlockオブジェクトを作成
      final updatedTask = task.copyWith(
        blockName: value,
        lastModified: DateTime.now(),
        version: task.version + 1,
      );

      widget.taskProvider.updateBlock(updatedTask);
    }
  }

  void _updateTaskName(String value) {
    if (widget.task is actual.ActualTask) {
      final task = widget.task as actual.ActualTask;
      task.title = value;
      widget.taskProvider.updateActualTask(task);
    } else if (widget.task is inbox.InboxTask) {
      final task = widget.task as inbox.InboxTask;
      task.title = value;
      widget.taskProvider.updateInboxTask(task);
    } else if (widget.task is block.Block) {
      final task = widget.task as block.Block;

      // copyWithを使用して新しいBlockオブジェクトを作成
      final updatedTask = task.copyWith(
        title: value,
        lastModified: DateTime.now(),
        version: task.version + 1,
      );

      widget.taskProvider.updateBlock(updatedTask);
    }
  }

  void _updateProject(String? projectId) {
    if (widget.task is actual.ActualTask) {
      final t = widget.task as actual.ActualTask;
      final prev = t.projectId;
      // 実際にprojectIdが変わった時のみサブプロジェクトをクリア
      final changed = prev != projectId;
      t.projectId = projectId;
      if (changed) {
        t.subProjectId = null;
        t.subProject = null;
      }
      widget.taskProvider.updateActualTask(t);
    } else if (widget.task is inbox.InboxTask) {
      widget.task.projectId = projectId;
      // プロジェクト変更時はサブプロジェクトをクリア
      widget.task.subProjectId = null;
      widget.taskProvider.updateInboxTask(widget.task);
    } else if (widget.task is block.Block) {
      final task = widget.task as block.Block;
      final changed = task.projectId != projectId;
      final updatedTask = task.copyWith(
        projectId: projectId,
        subProjectId: changed ? null : task.subProjectId,
        subProject: changed ? null : task.subProject,
        lastModified: DateTime.now(),
        version: task.version + 1,
      );
      widget.taskProvider.updateBlock(updatedTask);
    }
  }

  void _updateSubProject(String? subProjectId, String? subProjectName) {
    if (widget.task is actual.ActualTask) {
      final task = widget.task as actual.ActualTask;
      task.subProjectId = subProjectId;
      task.subProject = subProjectName;
      widget.taskProvider.updateActualTask(task);
    } else if (widget.task is inbox.InboxTask) {
      final task = widget.task as inbox.InboxTask;
      task.subProjectId = subProjectId;
      widget.taskProvider.updateInboxTask(task);
    } else if (widget.task is block.Block) {
      final task = widget.task as block.Block;
      final updatedTask = task.copyWith(
        subProjectId: subProjectId,
        subProject: subProjectName,
        lastModified: DateTime.now(),
        version: task.version + 1,
      );
      widget.taskProvider.updateBlock(updatedTask);
    }
  }

  void _updateStartTime(String value) {
    final s = value.trim();
    // 空欄は無視（開始時刻は必須のため）
    if (s.isEmpty) return;
    final parts = TimelineHelpers.parseTimeInput(s);
    if (parts == null) {
      return;
    }
    if (widget.task is actual.ActualTask) {
      final task = widget.task as actual.ActualTask;
      // 日付は元の startTime を保持し、時刻だけ差し替える
      final base = task.startTime;
      task.startTime =
          DateTime(base.year, base.month, base.day, parts.hour, parts.minute, parts.second);
      widget.taskProvider.updateActualTask(task);
      return;
    }
    if (widget.task is inbox.InboxTask) {
      final task = widget.task as inbox.InboxTask;
      task.startHour = parts.hour;
      task.startMinute = parts.minute;
      widget.taskProvider.updateInboxTask(task);
      return;
    }
    if (widget.task is block.Block) {
      final task = widget.task as block.Block;
      final updatedTask = task.copyWith(
        startHour: parts.hour,
        startMinute: parts.minute,
        lastModified: DateTime.now(),
        version: task.version + 1,
      );
      widget.taskProvider.updateBlock(updatedTask);
      return;
    }
  }

  void _updateEndTime(String value) {
    final s = value.trim();
    // 実績: 空欄なら終了時刻をクリア（＝未完了/継続扱い）
    if (widget.task is actual.ActualTask && s.isEmpty) {
      final task = widget.task as actual.ActualTask;
      task.endTime = null;
      task.actualDuration = 0; // stale を残さない
      widget.taskProvider.updateActualTask(task);
      return;
    }
    final parts = TimelineHelpers.parseTimeInput(s);
    if (parts == null) {
      return;
    }
    if (widget.task is actual.ActualTask) {
      final task = widget.task as actual.ActualTask;
      // 日付は startTime の日付を基準にし、時刻だけ差し替える
      final base = task.startTime;
      task.endTime =
          DateTime(base.year, base.month, base.day, parts.hour, parts.minute, parts.second);
      widget.taskProvider.updateActualTask(task);
      return;
    }
    if (widget.task is inbox.InboxTask) {
      // InboxTask は終了時刻を持たないため何もしない（仕様）
      widget.taskProvider.updateInboxTask(widget.task as inbox.InboxTask);
      return;
    }
    if (widget.task is block.Block) {
      final task = widget.task as block.Block;
      // 終了時刻から予定実行時間を計算（同日）
      final startDateTime = DateTime(
        task.executionDate.year,
        task.executionDate.month,
        task.executionDate.day,
        task.startHour,
        task.startMinute,
      );
      final endDateTime = DateTime(
        task.executionDate.year,
        task.executionDate.month,
        task.executionDate.day,
        parts.hour,
        parts.minute,
      );
      final newDuration = endDateTime.difference(startDateTime).inMinutes;
      if (newDuration > 0) {
        final updatedTask = task.copyWith(
          estimatedDuration: newDuration,
          lastModified: DateTime.now(),
          version: task.version + 1,
        );
        widget.taskProvider.updateBlock(updatedTask);
      }
      return;
    }
  }

  void _updateMode(String? modeId) {
    if (widget.task is actual.ActualTask) {
      final task = widget.task as actual.ActualTask;
      task.modeId = modeId;
      widget.taskProvider.updateActualTask(task);
      _modeController.text = _getModeName() ?? '';
    } else if (widget.task is block.Block) {
      final task = widget.task as block.Block;
      final updated = task.copyWith(
        modeId: modeId,
        // lastModified は Service 層で更新
        version: task.version + 1,
      );
      widget.taskProvider.updateBlock(updated);
      _modeController.text = _getModeName() ?? '';
    }
  }
}
