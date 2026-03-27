import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/task_provider.dart';

/// タスク再生用の全画面カウントダウンタイマー（所要時間が0分より大きい場合に表示）。
/// ポモドーロと同様の円環進捗＋残り時間表示。一時停止・完了・閉じる。
class TaskTimerScreen extends StatefulWidget {
  /// 所要時間（分）
  final int durationMinutes;
  /// 表示用タスク名
  final String? title;

  const TaskTimerScreen({
    super.key,
    required this.durationMinutes,
    this.title,
  });

  @override
  State<TaskTimerScreen> createState() => _TaskTimerScreenState();
}

class _TaskTimerScreenState extends State<TaskTimerScreen> {
  late int _remainingSeconds;
  late int _totalSeconds;
  bool _isRunning = true;
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    _totalSeconds = widget.durationMinutes * 60;
    _remainingSeconds = _totalSeconds;
    _startTicker();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startTicker() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _remainingSeconds--;
        if (_remainingSeconds <= 0) {
          _timer?.cancel();
          _onTimerEnd();
        }
      });
    });
  }

  void _onTimerEnd() {
    _timer?.cancel();
    final provider = context.read<TaskProvider>();
    final running = provider.runningActualTasks.isNotEmpty
        ? provider.runningActualTasks.first
        : null;
    if (running != null) {
      provider.completeActualTask(running.id);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('タイマー終了・タスクを完了しました')),
      );
      Navigator.of(context).pop();
    }
  }

  void _pause() {
    if (!_isRunning) return;
    setState(() => _isRunning = false);
    _timer?.cancel();
    final provider = context.read<TaskProvider>();
    final running = provider.runningActualTasks.isNotEmpty
        ? provider.runningActualTasks.first
        : null;
    if (running != null) {
      provider.pauseActualTask(running.id);
    }
    if (mounted) Navigator.of(context).pop();
  }

  void _complete() {
    _timer?.cancel();
    final provider = context.read<TaskProvider>();
    final running = provider.runningActualTasks.isNotEmpty
        ? provider.runningActualTasks.first
        : null;
    if (running != null) {
      provider.completeActualTask(running.id);
    }
    if (mounted) Navigator.of(context).pop();
  }

  /// 中断して閉じる（実績は完了として確定。再開時は別実績になる）
  void _interrupt() {
    _complete();
  }

  String _formatDuration(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 残り割合（1=満円→0=空）。円が満タンから短く減っていく表示
    final progress = _totalSeconds > 0
        ? (_remainingSeconds / _totalSeconds)
        : 0.0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('タイマー'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: _interrupt,
          tooltip: '中断して閉じる',
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(height: 24),
              if (widget.title != null && widget.title!.trim().isNotEmpty)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      widget.title!.trim(),
                      style: theme.textTheme.titleLarge?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 2,
                    ),
                  ),
                ),
              if (widget.title != null && widget.title!.trim().isNotEmpty)
                const SizedBox(height: 24),
              Center(
                child: SizedBox(
                  width: 280,
                  height: 280,
                  child: CustomPaint(
                    painter: _TaskTimerCirclePainter(
                      progress: progress,
                      color: theme.colorScheme.primary,
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
                              '${widget.durationMinutes}分',
                              style: theme.textTheme.bodySmall,
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 48),
              if (_isRunning)
                IconButton.filled(
                  iconSize: 56,
                  icon: const Icon(Icons.pause),
                  onPressed: _pause,
                  tooltip: '一時停止して閉じる',
                ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextButton.icon(
                    onPressed: _complete,
                    icon: const Icon(Icons.check_circle_outline),
                    label: const Text('完了して閉じる'),
                  ),
                  const SizedBox(width: 16),
                  TextButton.icon(
                    onPressed: _interrupt,
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('中断'),
                  ),
                ],
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

/// 円形進捗（ポモドーロと同じ太め円環で残り分が強調色・減っていく）
class _TaskTimerCirclePainter extends CustomPainter {
  /// 残り割合 1=開始（満円） 0=終了（空）
  final double progress;
  final Color color;
  final Color backgroundColor;

  _TaskTimerCirclePainter({
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
    const startAngle = -math.pi / 2;

    final trackPaint = Paint()
      ..color = backgroundColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = _strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, radius, trackPaint);

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
  bool shouldRepaint(covariant _TaskTimerCirclePainter old) {
    return old.progress != progress || old.color != color;
  }
}
