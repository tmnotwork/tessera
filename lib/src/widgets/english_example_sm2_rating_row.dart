import 'package:flutter/material.dart';

/// 英語例文の SM-2 自己申告（読み上げ・四択など共通）
class EnglishExampleSm2RatingRow extends StatelessWidget {
  const EnglishExampleSm2RatingRow({
    super.key,
    required this.previewDays,
    required this.onRate,
    this.disabled = false,
    this.fontSize = 13,
    this.smallFontSize = 11,
  });

  final int Function(int quality) previewDays;
  final ValueChanged<int> onRate;
  final bool disabled;
  final double fontSize;
  final double smallFontSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final difficult = Colors.orange;
    final correct = Colors.green;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        Expanded(
          child: ElevatedButton(
            onPressed: disabled ? null : () => onRate(0),
            style: ElevatedButton.styleFrom(
              backgroundColor: theme.colorScheme.surface,
              side: BorderSide(color: theme.colorScheme.error),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              minimumSize: const Size(0, 48),
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
            ),
            child: Text(
              '当日中',
              style: TextStyle(
                color: theme.colorScheme.error,
                fontSize: fontSize,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
              maxLines: 1,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: ElevatedButton(
            onPressed: disabled ? null : () => onRate(1),
            style: ElevatedButton.styleFrom(
              backgroundColor: theme.colorScheme.surface,
              side: BorderSide(color: difficult),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              minimumSize: const Size(0, 48),
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '難しい',
                  style: TextStyle(
                    color: difficult,
                    fontSize: fontSize,
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                ),
                Text(
                  '${previewDays(1)}日後',
                  style: TextStyle(
                    color: difficult.withValues(alpha: 0.7),
                    fontSize: smallFontSize + 1,
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: ElevatedButton(
            onPressed: disabled ? null : () => onRate(3),
            style: ElevatedButton.styleFrom(
              backgroundColor: theme.colorScheme.surface,
              side: BorderSide(color: correct),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              minimumSize: const Size(0, 48),
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '正解',
                  style: TextStyle(
                    color: correct,
                    fontSize: fontSize,
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                ),
                Text(
                  '${previewDays(3)}日後',
                  style: TextStyle(
                    color: correct.withValues(alpha: 0.7),
                    fontSize: smallFontSize + 1,
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: ElevatedButton(
            onPressed: disabled ? null : () => onRate(4),
            style: ElevatedButton.styleFrom(
              backgroundColor: theme.colorScheme.surface,
              side: BorderSide(color: theme.colorScheme.primary),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              minimumSize: const Size(0, 48),
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '簡単',
                  style: TextStyle(
                    color: theme.colorScheme.primary,
                    fontSize: fontSize,
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                ),
                Text(
                  '${previewDays(4)}日後',
                  style: TextStyle(
                    color: theme.colorScheme.primary.withValues(alpha: 0.7),
                    fontSize: smallFontSize + 1,
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
