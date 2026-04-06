import 'package:flutter/material.dart';

/// マイルストーン到達時のお祝いダイアログ。
class StreakCelebrationDialog extends StatelessWidget {
  const StreakCelebrationDialog({super.key, required this.milestone});

  final int milestone;

  static String _exactPeriodLabel(int days) {
    if (days <= 0) return '';
    if (days % 365 == 0) {
      final years = days ~/ 365;
      return years == 1 ? '（1年）' : '（$years年）';
    }
    if (days % 30 == 0) {
      final months = days ~/ 30;
      return months == 1 ? '（1か月）' : '（$monthsか月）';
    }
    if (days % 7 == 0) {
      final weeks = days ~/ 7;
      return weeks == 1 ? '（1週間）' : '（$weeks週間）';
    }
    return '';
  }

  static String messageFor(int milestone) {
    final period = _exactPeriodLabel(milestone);
    switch (milestone) {
      case 3:
        return '3日連続達成！いいスタートです 🎉';
      case 7:
        return '7日連続達成！習慣になってきた 🔥';
      case 14:
        return '14日連続$period達成！素晴らしい継続力 ✨';
      case 30:
        return '30日連続$period達成！本物の習慣です 🏆';
      case 60:
        return '60日連続$period達成！圧倒的な努力 💪';
      case 100:
        return '100日連続達成！すごい記録です 🌟';
      default:
        return '$milestone日連続$period達成！';
    }
  }

  static Future<void> show(BuildContext context, int milestone) {
    return showDialog<void>(
      context: context,
      useRootNavigator: true,
      barrierDismissible: false,
      builder: (ctx) => StreakCelebrationDialog(milestone: milestone),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.celebration, color: Colors.amber.shade700, size: 28),
          const SizedBox(width: 8),
          const Expanded(child: Text('連続学習')),
        ],
      ),
      content: Text(messageFor(milestone)),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('続ける'),
        ),
      ],
    );
  }
}

/// 当日初回の連続日数案内（必ずモーダルダイアログ。SnackBar では表示しない）。
///
/// 連続1日以上のときは **「〇日連続！」** を大きく表示し、今日の日付も併記する。
class StreakDailyGreetingDialog extends StatelessWidget {
  const StreakDailyGreetingDialog({super.key, required this.currentStreak});

  final int currentStreak;

  static Future<void> show(
    BuildContext context, {
    required int currentStreak,
  }) {
    return showDialog<void>(
      context: context,
      useRootNavigator: true,
      barrierDismissible: false,
      builder: (ctx) =>
          StreakDailyGreetingDialog(currentStreak: currentStreak),
    );
  }

  /// 端末ローカル日付（`initializeDateFormatting` 不要に手組み）。
  static String _todayLabelJa() {
    final now = DateTime.now();
    const weekdays = ['月', '火', '水', '木', '金', '土', '日'];
    final w = weekdays[now.weekday - 1];
    return '${now.year}年${now.month}月${now.day}日（$w）';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dateLine = _todayLabelJa();

    final Widget body;
    if (currentStreak > 0) {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '$currentStreak日連続！',
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            dateLine,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '学習を継続できています。この調子で続けましょう。',
            style: theme.textTheme.bodyMedium,
          ),
        ],
      );
    } else {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            dateLine,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '今日の学習を記録すると、連続日数が積み上がります。',
            style: theme.textTheme.bodyMedium,
          ),
        ],
      );
    }

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.local_fire_department, color: Colors.deepOrange.shade600, size: 28),
          const SizedBox(width: 8),
          const Expanded(child: Text('連続学習')),
        ],
      ),
      content: body,
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('続ける'),
        ),
      ],
    );
  }
}
