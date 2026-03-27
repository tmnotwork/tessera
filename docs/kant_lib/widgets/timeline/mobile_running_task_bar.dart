import 'package:flutter/material.dart';
import 'dart:async';
import 'package:provider/provider.dart';
import '../../models/inbox_task.dart' as inbox;
import '../../models/actual_task.dart' as actual;
import '../../providers/task_provider.dart';

/// スマホ版専用の実行中タスクバー（コンパクトレイアウト）
class MobileRunningTaskBar extends StatefulWidget {
  final dynamic runningTask; // InboxTaskまたはActualTaskを受け取る
  final VoidCallback onPause;
  final VoidCallback onComplete;

  const MobileRunningTaskBar({
    super.key,
    required this.runningTask,
    required this.onPause,
    required this.onComplete,
  });

  @override
  State<MobileRunningTaskBar> createState() => _MobileRunningTaskBarState();
}

class _MobileRunningTaskBarState extends State<MobileRunningTaskBar> {
  Timer? _timer;
  Duration _elapsedTime = Duration.zero;
  final TextEditingController _titleController = TextEditingController();
  final FocusNode _titleFocusNode = FocusNode();
  bool _isEditingTitle = false;
  bool _titleDirty = false;
  String _titleBaseline = '';
  String? _titleTaskId;

  Color _barBackgroundColor(ThemeData theme) {
    final scheme = theme.colorScheme;
    final base = theme.scaffoldBackgroundColor;

    if (theme.brightness == Brightness.light) {
      return Color.alphaBlend(scheme.onSurface.withOpacity(0.03), base);
    }

    return Color.alphaBlend(scheme.onSurface.withOpacity(0.08), base);
  }

  @override
  void initState() {
    super.initState();
    _startTimer();
    _syncTitleController(force: true);
    _titleFocusNode.addListener(_handleTitleFocusChange);
  }

  @override
  void didUpdateWidget(covariant MobileRunningTaskBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTitleController();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _titleFocusNode.removeListener(_handleTitleFocusChange);
    _titleFocusNode.dispose();
    _titleController.dispose();
    super.dispose();
  }

  void _handleTitleFocusChange() {
    if (_titleFocusNode.hasFocus) {
      _isEditingTitle = true;
      _titleBaseline = _titleController.text;
      _titleDirty = false;
      if (mounted) setState(() {});
      return;
    }
    if (_isEditingTitle) {
      _isEditingTitle = false;
      _commitTitle();
    }
    if (mounted) setState(() {});
  }

  void _syncTitleController({bool force = false}) {
    // 編集用には実際の task.title のみ同期（空のときは ''）。「実行中のタスク」は hint 表示のみで保存しない
    final nextTitle = widget.runningTask is actual.ActualTask
        ? (widget.runningTask as actual.ActualTask).title
        : _getTaskTitle();
    final taskId = widget.runningTask is actual.ActualTask
        ? (widget.runningTask as actual.ActualTask).id
        : null;
    final taskChanged = taskId != _titleTaskId;
    if (force || taskChanged) {
      _titleController.text = nextTitle;
      _titleBaseline = nextTitle;
      _titleDirty = false;
      _titleTaskId = taskId;
      return;
    }
    if (!_isEditingTitle && nextTitle != _titleBaseline) {
      _titleController.text = nextTitle;
      _titleBaseline = nextTitle;
      _titleDirty = false;
    }
  }

  Future<void> _commitTitle() async {
    if (!_titleDirty || widget.runningTask is! actual.ActualTask) {
      return;
    }
    final task = widget.runningTask as actual.ActualTask;
    final trimmed = _titleController.text.trim();
    if (trimmed == _titleBaseline) {
      _titleDirty = false;
      return;
    }
    if (trimmed == task.title) {
      _titleDirty = false;
      _titleBaseline = _titleController.text;
      return;
    }
    task.title = trimmed;
    _titleDirty = false;
    _titleBaseline = trimmed;
    await context.read<TaskProvider>().updateActualTask(task);
  }

  void _startTimer() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _updateElapsedTime();
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      _updateElapsedTime();
      if (mounted) setState(() {}); // 現在時刻表示も更新
    });
  }

  void _updateElapsedTime() {
    if (!mounted) return;
    final startTime = _getStartTime();
    if (startTime != null) {
      setState(() {
        _elapsedTime = DateTime.now().difference(startTime);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final foregroundColor = scheme.onSurface;
    final now = DateTime.now();
    final taskTitle = _getTaskTitle();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: _barBackgroundColor(theme),
        border: Border(
          top: BorderSide(
            color: theme.dividerColor,
            width: 1,
          ),
        ),
      ),
      child: DefaultTextStyle(
        style: theme.textTheme.bodyMedium?.copyWith(
              color: foregroundColor,
            ) ??
            TextStyle(color: foregroundColor),
        child: IconTheme(
          data: theme.iconTheme.copyWith(color: foregroundColor),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
          // 1行目: タスク名（編集可能）
          _buildTitleEditor(taskTitle, scheme),
          const SizedBox(height: 8),
          // 1.5行目: 時刻表示（中央）
          Builder(builder: (context) {
            final startTime = _getStartTime();
            return Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (startTime != null) ...[
                  Icon(Icons.stop, size: 14, color: foregroundColor),
                  const SizedBox(width: 4),
                  Text(
                    '開始: ${_hhmmss(startTime)}',
                    style: TextStyle(
                        fontSize: 12, color: foregroundColor),
                  ),
                  const SizedBox(width: 12),
                ],
                Icon(Icons.schedule, size: 14, color: foregroundColor),
                const SizedBox(width: 4),
                Text(
                  '現在: ${_hhmmss(now)}',
                  style: TextStyle(fontSize: 12, color: foregroundColor),
                ),
                const SizedBox(width: 12),
                Icon(Icons.timer, size: 14, color: foregroundColor),
                const SizedBox(width: 4),
                Text(
                  '経過: ${_formatDuration(_elapsedTime)}',
                  style: TextStyle(fontSize: 12, color: foregroundColor),
                ),
              ],
            );
          }),
          // 2行目: ボタン（横並び、コンパクト）
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: widget.onPause,
                  icon: const Icon(Icons.pause, size: 16),
                  label: const Text('中断', style: TextStyle(fontSize: 12)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.tertiary,
                    foregroundColor: Theme.of(context).colorScheme.onTertiary,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    minimumSize: const Size(0, 32),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: widget.onComplete,
                  icon: const Icon(Icons.check, size: 16),
                  label: const Text('完了', style: TextStyle(fontSize: 12)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.secondary,
                    foregroundColor: Theme.of(context).colorScheme.onSecondary,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    minimumSize: const Size(0, 32),
                  ),
                ),
              ),
            ],
          ),
          // 3行目: プログレスバー（あれば表示）
          if (_getStartTime() != null) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: (_getDurationInMinutes() / 60).clamp(0.0, 1.0),
              backgroundColor: theme.dividerColor,
              valueColor: AlwaysStoppedAnimation<Color>(
                  scheme.primary),
            ),
          ],
            ],
          ),
        ),
      ),
    );
  }

  // タスクの種類に応じてstartTimeを取得
  DateTime? _getStartTime() {
    if (widget.runningTask is actual.ActualTask) {
      return (widget.runningTask as actual.ActualTask).startTime;
    } else if (widget.runningTask is inbox.InboxTask) {
      final t = widget.runningTask as inbox.InboxTask;
      if (t.startHour != null && t.startMinute != null) {
        return DateTime(
          t.executionDate.year,
          t.executionDate.month,
          t.executionDate.day,
          t.startHour!,
          t.startMinute!,
        );
      }
      return null;
    }
    return null;
  }

  // タスクの種類に応じて継続時間を取得
  int _getDurationInMinutes() {
    if (widget.runningTask is actual.ActualTask) {
      final task = widget.runningTask as actual.ActualTask;
      final startTime = task.startTime;
      final endTime = task.endTime ?? DateTime.now();
      return endTime.difference(startTime).inMinutes;
    } else if (widget.runningTask is inbox.InboxTask) {
      final t = widget.runningTask as inbox.InboxTask;
      return t.estimatedDuration;
    }
    return 0;
  }

  String _getTaskTitle() {
    const fallback = '実行中のタスク';
    if (widget.runningTask is actual.ActualTask) {
      final task = widget.runningTask as actual.ActualTask;
      final title = task.title.trim();
      if (title.isNotEmpty) return title;
      final blockName = task.blockName?.trim();
      if (blockName != null && blockName.isNotEmpty) return blockName;
      final memo = task.memo?.trim();
      if (memo != null && memo.isNotEmpty) return memo;
    } else if (widget.runningTask is inbox.InboxTask) {
      final task = widget.runningTask as inbox.InboxTask;
      final title = task.title.trim();
      if (title.isNotEmpty) return title;
      final memo = task.memo?.trim();
      if (memo != null && memo.isNotEmpty) return memo;
    }
    return fallback;
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return '${hours}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    } else {
      return '${minutes}:${seconds.toString().padLeft(2, '0')}';
    }
  }

  String _hhmmss(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
  }

  Widget _buildTitleEditor(String fallbackTitle, ColorScheme scheme) {
    final foregroundColor = scheme.onSurface;
    final titleStyle = TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.bold,
      color: foregroundColor,
    );

    if (widget.runningTask is! actual.ActualTask) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.stop_circle, color: scheme.primary, size: 20),
          const SizedBox(width: 8),
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
              child: Text(
                fallbackTitle,
                textAlign: TextAlign.center,
                style: titleStyle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      );
    }

    final bool isEditing = _titleFocusNode.hasFocus;

    return Row(
      children: [
        Icon(Icons.stop_circle, color: scheme.primary, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: GestureDetector(
            onTap: () => _titleFocusNode.requestFocus(),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
              decoration: BoxDecoration(
                color: isEditing
                    ? scheme.surface.withOpacity(0.3)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: isEditing
                      ? scheme.primary.withOpacity(0.5)
                      : foregroundColor.withOpacity(0.15),
                  width: 1,
                ),
              ),
              child: TextField(
                controller: _titleController,
                focusNode: _titleFocusNode,
                maxLines: 1,
                textAlign: TextAlign.center,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  isCollapsed: true,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  errorBorder: InputBorder.none,
                  focusedErrorBorder: InputBorder.none,
                  filled: false,
                  contentPadding: EdgeInsets.zero,
                  hintText: '実行中のタスク',
                  hintStyle: titleStyle.copyWith(
                    fontWeight: FontWeight.w500,
                    color: titleStyle.color?.withOpacity(0.6),
                  ),
                ),
                style: titleStyle,
                onChanged: (value) {
                  if (!_isEditingTitle) return;
                  _titleDirty = value != _titleBaseline;
                },
                onSubmitted: (_) {
                  _commitTitle();
                  _titleFocusNode.unfocus();
                },
                onEditingComplete: _commitTitle,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
