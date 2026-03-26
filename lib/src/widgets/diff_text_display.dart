import 'package:flutter/material.dart';

import '../utils/word_diff.dart';

/// diff 結果を RichText で表示（英作文用）
class DiffTextDisplay {
  DiffTextDisplay._();

  static TextStyle _baseStyle(TextTheme textTheme, Color color) {
    return textTheme.bodyLarge?.copyWith(color: color) ??
        TextStyle(fontSize: 16, color: color);
  }

  /// ユーザー回答: matched → [matchedColor], added → [addedColor]
  static Widget buildUserAnswerText(
    BuildContext context,
    List<DiffWord> diff, {
    Color? matchedColor,
    Color? addedColor,
  }) {
    final theme = Theme.of(context);
    final onSurface = matchedColor ?? theme.colorScheme.onSurface;
    final wrong = addedColor ?? theme.colorScheme.error;
    final base = _baseStyle(theme.textTheme, onSurface);

    final spans = <InlineSpan>[];
    for (var i = 0; i < diff.length; i++) {
      if (i > 0) {
        spans.add(TextSpan(text: ' ', style: base));
      }
      final d = diff[i];
      final c = d.status == DiffStatus.matched ? onSurface : wrong;
      spans.add(
        TextSpan(
          text: d.word,
          style: base.copyWith(
            color: c,
            fontWeight: d.status == DiffStatus.added ? FontWeight.w600 : null,
          ),
        ),
      );
    }
    return SelectableText.rich(TextSpan(children: spans));
  }

  /// 模範解答: matched → [matchedColor], missing → [missingColor]
  static Widget buildCorrectAnswerText(
    BuildContext context,
    List<DiffWord> diff, {
    Color? matchedColor,
    Color? missingColor,
  }) {
    final theme = Theme.of(context);
    final onSurface = matchedColor ?? theme.colorScheme.onSurface;
    final hint = missingColor ?? theme.colorScheme.primary;
    final base = _baseStyle(theme.textTheme, onSurface);

    final spans = <InlineSpan>[];
    for (var i = 0; i < diff.length; i++) {
      if (i > 0) {
        spans.add(TextSpan(text: ' ', style: base));
      }
      final d = diff[i];
      final c = d.status == DiffStatus.matched ? onSurface : hint;
      spans.add(
        TextSpan(
          text: d.word,
          style: base.copyWith(
            color: c,
            fontWeight: d.status == DiffStatus.missing ? FontWeight.w600 : null,
          ),
        ),
      );
    }
    return SelectableText.rich(TextSpan(children: spans));
  }
}
