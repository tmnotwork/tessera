import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/block.dart';
import '../providers/task_provider.dart';
import '../utils/unified_screen_dialog.dart';
import '../services/actual_task_sync_service.dart';
import '../services/mode_service.dart';
import '../services/project_service.dart';
import '../services/sub_project_service.dart';
import '../widgets/project_input_field.dart';
import '../widgets/sub_project_input_field.dart';

/// ポモドーロタイマー画面（全画面表示）。
/// 作業時間 → 休憩 を「繰り返し」回行い、中断可能。
/// [initialBlock] を渡すと、そのブロックのタスク名・プロジェクト・サブプロジェクト・場所を初期値にする。
class PomodoroScreen extends StatefulWidget {
  final Block? initialBlock;

  const PomodoroScreen({super.key, this.initialBlock});

  @override
  State<PomodoroScreen> createState() => _PomodoroScreenState();
}

class _PomodoroScreenState extends State<PomodoroScreen> {
  static const int defaultWorkMinutes = 25;
  static const int defaultBreakMinutes = 5;
  static const int defaultRepetitions = 4;

  int _workMinutes = defaultWorkMinutes;
  int _breakMinutes = defaultBreakMinutes;
  int _repetitions = defaultRepetitions;

  int _currentRound = 1; // 1-based
  bool _isWorkPhase = true;
  int _remainingSeconds = defaultWorkMinutes * 60;
  bool _isRunning = false;
  Timer? _timer;
  /// 作業フェーズの開始時刻（一時停止・終了・中断時に実績記録に使用）
  DateTime? _workPhaseStartedAt;

  final TextEditingController _taskTitleController =
      TextEditingController();
  final TextEditingController _projectController = TextEditingController();
  final TextEditingController _subProjectController = TextEditingController();
  final TextEditingController _locationController = TextEditingController();
  String? _projectId;
  String? _subProjectId;
  String? _subProjectName;
  /// モード「集中」のID（未取得時は null）
  String? _focusModeId;
  int get _totalSecondsForCurrentPhase =>
      _isWorkPhase ? _workMinutes * 60 : _breakMinutes * 60;

  @override
  void initState() {
    super.initState();
    _remainingSeconds = _workMinutes * 60;
    _resolveFocusModeId();
    if (widget.initialBlock != null) {
      _applyBlock(widget.initialBlock!);
    }
  }

  void _applyBlock(Block block) {
    _taskTitleController.text = block.title.trim();
    _projectId = block.projectId;
    _subProjectId = block.subProjectId;
    _subProjectName = block.subProject;
    _projectController.text = block.projectId != null
        ? (ProjectService.getProjectById(block.projectId!)?.name ?? '')
        : '';
    _subProjectController.text = block.subProjectId != null
        ? (SubProjectService.getSubProjectById(block.subProjectId!)?.name ?? block.subProject ?? '')
        : (block.subProject ?? '');
    _locationController.text = block.location ?? '';
  }

  void _resolveFocusModeId() {
    try {
      final modes = ModeService.getAllModes();
      for (final m in modes) {
        if (m.name == '集中') {
          if (mounted) setState(() => _focusModeId = m.id);
          break;
        }
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _timer?.cancel();
    _taskTitleController.dispose();
    _projectController.dispose();
    _subProjectController.dispose();
    _locationController.dispose();
    super.dispose();
  }

  void _startTimer() {
    if (_isRunning) return;
    if (_isWorkPhase) _workPhaseStartedAt = DateTime.now();
    setState(() => _isRunning = true);
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _remainingSeconds--;
        if (_remainingSeconds <= 0) _onPhaseEnd();
      });
    });
  }

  /// 指定した区間を実績として1件記録する
  Future<void> _recordWorkSegment(DateTime start, DateTime end) async {
    if (!mounted) return;
    if (!end.isAfter(start)) return;
    final title = _taskTitleController.text.trim().isEmpty
        ? '作業'
        : _taskTitleController.text.trim();
    final location = _locationController.text.trim();
    try {
      await ActualTaskSyncService().createCompletedTaskWithSync(
        startTime: start,
        endTime: end,
        title: title,
        blockName: 'ポモドーロ',
        projectId: _projectId,
        subProjectId: _subProjectId,
        subProject: _subProjectName,
        modeId: _focusModeId,
        location: location.isEmpty ? null : location,
      );
      if (mounted) {
        await Provider.of<TaskProvider>(context, listen: false).refreshTasks();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('実績の記録に失敗しました: $e')),
        );
      }
    }
  }

  Future<void> _recordWorkSegmentIfAny() async {
    if (!_isWorkPhase || _workPhaseStartedAt == null || !mounted) return;
    final start = _workPhaseStartedAt!;
    final end = DateTime.now();
    _workPhaseStartedAt = null;
    await _recordWorkSegment(start, end);
  }

  Future<void> _pauseTimer() async {
    if (!_isRunning) return;
    _timer?.cancel();
    _timer = null;
    await _recordWorkSegmentIfAny();
    if (mounted) setState(() => _isRunning = false);
  }

  void _onPhaseEnd() {
    _timer?.cancel();
    _timer = null;
    setState(() => _isRunning = false);

    if (_isWorkPhase) {
      // 作業フェーズ終了時に実績を1件記録してから休憩へ
      final start = _workPhaseStartedAt;
      final end = DateTime.now();
      _workPhaseStartedAt = null;
      if (start != null) {
        Future.microtask(() => _recordWorkSegment(start, end));
      }
      _showTimeUp();
      // 休憩へ（_recordWorkSegmentIfAny 内で _workPhaseStartedAt をクリア）
      setState(() {
        _isWorkPhase = false;
        _remainingSeconds = _breakMinutes * 60;
      });
      _startTimer(); // 休憩を自動開始
    } else {
      if (_currentRound >= _repetitions) {
        _showAllDone();
        return;
      }
      setState(() {
        _currentRound++;
        _isWorkPhase = true;
        _remainingSeconds = _workMinutes * 60;
      });
      _startTimer(); // 次の作業を自動開始
    }
  }

  void _showTimeUp() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('タイムアップ！休憩に入ります。'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showAllDone() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('お疲れさまです！$_repetitions セット完了しました。'),
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _cancel() async {
    _timer?.cancel();
    _timer = null;
    await _recordWorkSegmentIfAny();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _showSettings() async {
    int work = _workMinutes;
    int breakM = _breakMinutes;
    int reps = _repetitions;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialog) {
            return AlertDialog(
              title: const Text('ポモドーロ設定'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('作業時間（分）', style: Theme.of(context).textTheme.titleSmall),
                    Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.remove_circle_outline),
                          onPressed: work > 1 ? () => setDialog(() => work--) : null,
                        ),
                        Text('$work', style: const TextStyle(fontSize: 20)),
                        IconButton(
                          icon: const Icon(Icons.add_circle_outline),
                          onPressed: work < 120 ? () => setDialog(() => work++) : null,
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text('休憩時間（分）', style: Theme.of(context).textTheme.titleSmall),
                    Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.remove_circle_outline),
                          onPressed: breakM > 1 ? () => setDialog(() => breakM--) : null,
                        ),
                        Text('$breakM', style: const TextStyle(fontSize: 20)),
                        IconButton(
                          icon: const Icon(Icons.add_circle_outline),
                          onPressed: breakM < 60 ? () => setDialog(() => breakM++) : null,
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text('繰り返し（回）', style: Theme.of(context).textTheme.titleSmall),
                    Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.remove_circle_outline),
                          onPressed: reps > 1 ? () => setDialog(() => reps--) : null,
                        ),
                        Text('$reps', style: const TextStyle(fontSize: 20)),
                        IconButton(
                          icon: const Icon(Icons.add_circle_outline),
                          onPressed: reps < 20 ? () => setDialog(() => reps++) : null,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('キャンセル'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('適用'),
                ),
              ],
            );
          },
        );
      },
    );
    if (confirmed == true && mounted) {
      setState(() {
        _workMinutes = work;
        _breakMinutes = breakM;
        _repetitions = reps;
        if (!_isRunning) {
          _remainingSeconds = _isWorkPhase ? _workMinutes * 60 : _breakMinutes * 60;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = _totalSecondsForCurrentPhase;
    // 残り割合（1=満円→0=空）。円が満タンから短く減っていく表示
    final progress = total > 0 ? (_remainingSeconds / total) : 0.0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('ポモドーロ'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: _cancel,
          tooltip: '閉じる（中断）',
        ),
        actions: [
          if (!_isRunning)
            IconButton(
              icon: const Icon(Icons.settings),
              onPressed: _showSettings,
              tooltip: '設定',
            ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                const SizedBox(height: 16),
                // ブロック名・休憩・セット表示を時計と同じ幅で中央揃え（12時と重なるように）
                Center(
                  child: SizedBox(
                    width: 280,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_isWorkPhase)
                          SizedBox(
                            height: 52,
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                Center(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 48),
                                    child: Text(
                                      _taskTitleController.text.trim().isEmpty
                                          ? 'タスク名を設定'
                                          : _taskTitleController.text.trim(),
                                      style: theme.textTheme.titleLarge?.copyWith(
                                        color: theme.colorScheme.primary,
                                      ),
                                      textAlign: TextAlign.center,
                                      overflow: TextOverflow.ellipsis,
                                      maxLines: 2,
                                    ),
                                  ),
                                ),
                                Positioned(
                                  right: 0,
                                  top: 0,
                                  bottom: 0,
                                  child: IconButton(
                                    icon: const Icon(Icons.edit_outlined),
                                    onPressed: _showBlockEditSheet,
                                    tooltip: '編集',
                                  ),
                                ),
                              ],
                            ),
                          )
                        else
                          Text(
                            '休憩',
                            style: theme.textTheme.titleLarge?.copyWith(
                              color: theme.colorScheme.tertiary,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        const SizedBox(height: 8),
                        Text(
                          '$_currentRound / $_repetitions セット',
                          style: theme.textTheme.bodyMedium,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 32),
                      ],
                    ),
                    ),
                ),
                    Center(
                      child: SizedBox(
                        width: 280,
                        height: 280,
                        child: CustomPaint(
                        painter: _PomodoroCirclePainter(
                          progress: progress,
                          color: _isWorkPhase
                              ? theme.colorScheme.primary
                              : theme.colorScheme.tertiary,
                          backgroundColor: theme.colorScheme.surfaceContainerHighest,
                        ),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _formatDuration(_remainingSeconds),
                                style: theme.textTheme.headlineLarge?.copyWith(
                                  fontWeight: FontWeight.w300,
                                  fontFeatures: const [FontFeature.tabularFigures()],
                                ),
                              ),
                              if (!_isRunning)
                                Text(
                                  '${_isWorkPhase ? _workMinutes : _breakMinutes}分',
                                  style: theme.textTheme.bodySmall,
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    ),
                    const SizedBox(height: 48),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (_isRunning)
                          IconButton.filled(
                            iconSize: 56,
                            icon: const Icon(Icons.pause),
                            onPressed: _pauseTimer,
                            tooltip: '一時停止',
                          )
                        else
                          IconButton.filled(
                            iconSize: 56,
                            icon: const Icon(Icons.play_arrow),
                            onPressed: _startTimer,
                            tooltip: '開始',
                          ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    TextButton.icon(
                      onPressed: _cancel,
                      icon: const Icon(Icons.stop_circle_outlined),
                      label: const Text('中断して閉じる'),
                    ),
                    const SizedBox(height: 24),
                ],
              ),
            ),
      ),
    );
  }

  void _showBlockEditSheet() {
    final theme = Theme.of(context);
    final unifiedFontSize =
        theme.textTheme.titleMedium?.fontSize ?? 16.0;

    showUnifiedScreenDialog<bool>(
      context: context,
      builder: (ctx) => _PomodoroBlockEditSheet(
        taskTitle: _taskTitleController.text,
        projectId: _projectId,
        projectName: _projectController.text,
        subProjectId: _subProjectId,
        subProjectName: _subProjectController.text,
        location: _locationController.text,
        unifiedFontSize: unifiedFontSize,
        onSave: (
          taskTitle,
          projectId,
          projectName,
          subProjectId,
          subProjectName,
          location,
        ) {
          setState(() {
            _taskTitleController.text = taskTitle;
            _projectId = projectId;
            _projectController.text = projectName;
            _subProjectId = subProjectId;
            _subProjectName = subProjectName;
            _subProjectController.text = subProjectName;
            _locationController.text = location;
          });
        },
      ),
    );
  }

  static String _formatDuration(int totalSeconds) {
    final m = totalSeconds ~/ 60;
    final s = totalSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}

/// ポモドーロのブロック（実績）編集シート。スマホの実績編集画面に近いUI。
class _PomodoroBlockEditSheet extends StatefulWidget {
  final String taskTitle;
  final String? projectId;
  final String projectName;
  final String? subProjectId;
  final String subProjectName;
  final String location;
  final double unifiedFontSize;
  final void Function(
    String taskTitle,
    String? projectId,
    String projectName,
    String? subProjectId,
    String subProjectName,
    String location,
  ) onSave;

  const _PomodoroBlockEditSheet({
    required this.taskTitle,
    required this.projectId,
    required this.projectName,
    required this.subProjectId,
    required this.subProjectName,
    required this.location,
    required this.unifiedFontSize,
    required this.onSave,
  });

  @override
  State<_PomodoroBlockEditSheet> createState() => _PomodoroBlockEditSheetState();
}

class _PomodoroBlockEditSheetState extends State<_PomodoroBlockEditSheet> {
  late TextEditingController _taskTitleController;
  late TextEditingController _projectController;
  late TextEditingController _subProjectController;
  late TextEditingController _locationController;
  String? _projectId;
  String? _subProjectId;

  @override
  void initState() {
    super.initState();
    _taskTitleController = TextEditingController(text: widget.taskTitle);
    _projectController = TextEditingController(text: widget.projectName);
    _subProjectController = TextEditingController(text: widget.subProjectName);
    _locationController = TextEditingController(text: widget.location);
    _projectId = widget.projectId;
    _subProjectId = widget.subProjectId;
  }

  @override
  void dispose() {
    _taskTitleController.dispose();
    _projectController.dispose();
    _subProjectController.dispose();
    _locationController.dispose();
    super.dispose();
  }

  void _save() {
    widget.onSave(
      _taskTitleController.text.trim(),
      _projectId,
      _projectController.text.trim(),
      _subProjectId,
      _subProjectController.text.trim(),
      _locationController.text.trim(),
    );
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('タスク'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
          tooltip: 'キャンセル',
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.save_outlined),
            onPressed: _save,
            tooltip: '保存',
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _taskTitleController,
                style: TextStyle(fontSize: widget.unifiedFontSize),
                decoration: const InputDecoration(
                  labelText: 'ブロック名',
                  border: OutlineInputBorder(),
                  floatingLabelBehavior: FloatingLabelBehavior.always,
                ),
              ),
              const SizedBox(height: 12),
              InputDecorator(
                decoration: InputDecoration(
                  labelText: 'プロジェクト',
                  border: const OutlineInputBorder(),
                  floatingLabelBehavior: FloatingLabelBehavior.always,
                  filled: true,
                  fillColor: theme.inputDecorationTheme.fillColor ??
                      scheme.surfaceContainerHighest,
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                ),
                isEmpty: _projectController.text.isEmpty,
                child: ProjectInputField(
                  controller: _projectController,
                  height: 44,
                  fontSize: widget.unifiedFontSize,
                  onProjectChanged: (projectId) {
                    setState(() {
                      _projectId = projectId;
                      _subProjectController.text = '';
                      _subProjectId = null;
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
                  fillColor: theme.inputDecorationTheme.fillColor ??
                      scheme.surfaceContainerHighest,
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                ),
                isEmpty: _subProjectController.text.isEmpty,
                child: SubProjectInputField(
                  controller: _subProjectController,
                  projectId: _projectId,
                  currentSubProjectId: _subProjectId,
                  height: 44,
                  fontSize: widget.unifiedFontSize,
                  onSubProjectChanged: (subProjectId, subProjectName) {
                    setState(() {
                      _subProjectId = subProjectId;
                    });
                  },
                  withBackground: false,
                  useOutlineBorder: false,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _locationController,
                style: TextStyle(fontSize: widget.unifiedFontSize),
                decoration: const InputDecoration(
                  labelText: '場所',
                  border: OutlineInputBorder(),
                  floatingLabelBehavior: FloatingLabelBehavior.always,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 円形の進捗。太めの円環のうち、残り時間分が強調色で塗られ、減っていく表示。
class _PomodoroCirclePainter extends CustomPainter {
  /// 残り割合 1=開始（満円） 0=終了（空）。12時から時計回りに円環が短くなっていく。
  final double progress;
  final Color color;
  final Color backgroundColor;

  _PomodoroCirclePainter({
    required this.progress,
    required this.color,
    required this.backgroundColor,
  });

  static const double _strokeWidth = 24;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width / 2) * 0.9 - _strokeWidth / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);
    const startAngle = -math.pi / 2; // 12時

    // 円周トラック（太めの円環・背景色）
    final trackPaint = Paint()
      ..color = backgroundColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = _strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, radius, trackPaint);

    // 残り分：12時から時計回りに強調色で円弧を描画（残りが減ると弧が短くなる）
    final p = progress.clamp(0.0, 1.0);
    if (p > 0) {
      final sweepAngle = 2 * math.pi * p;
      final progressPaint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = _strokeWidth
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(rect, startAngle, sweepAngle, false, progressPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _PomodoroCirclePainter old) {
    return old.progress != progress || old.color != color;
  }
}
