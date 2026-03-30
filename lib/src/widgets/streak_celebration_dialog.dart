import 'package:flutter/material.dart';

/// マイルストーン到達時のお祝いダイアログ。
class StreakCelebrationDialog extends StatelessWidget {
  const StreakCelebrationDialog({super.key, required this.milestone});

  final int milestone;

  static String messageFor(int milestone) {
    switch (milestone) {
      case 3:
        return '3日連続！いいスタートです 🎉';
      case 7:
        return '1週間連続！習慣になってきた 🔥';
      case 14:
        return '2週間連続！素晴らしい継続力 ✨';
      case 30:
        return '30日連続！本物の習慣です 🏆';
      case 60:
        return '60日連続！圧倒的な努力 💪';
      case 100:
        return '100日連続！すごい記録です 🌟';
      default:
        return '$milestone 日連続達成！';
    }
  }

  static Future<void> show(BuildContext context, int milestone) {
    return showDialog<void>(
      context: context,
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
