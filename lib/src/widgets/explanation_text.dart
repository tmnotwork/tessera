import 'package:flutter/material.dart';

/// 改行・引用（> ）・太字（**）を表示するウィジェット
class ExplanationText extends StatelessWidget {
  final String text;

  const ExplanationText({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = text.split('\n');
    final widgets = <Widget>[];

    List<String> blockquoteLines = [];

    void flushBlockquote() {
      if (blockquoteLines.isNotEmpty) {
        widgets.add(
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: blockquoteLines
                  .map((line) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: BoldText(text: line, style: theme.textTheme.bodyLarge!),
                      ))
                  .toList(),
            ),
          ),
        );
        blockquoteLines = [];
      }
    }

    for (var line in lines) {
      if (line.startsWith('> ')) {
        blockquoteLines.add(line.substring(2).trim());
      } else if (line == '>') {
        blockquoteLines.add('');
      } else {
        flushBlockquote();
        if (line.trim().isEmpty) {
          widgets.add(const SizedBox(height: 12));
        } else {
          widgets.add(
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: BoldText(text: line, style: theme.textTheme.bodyLarge!),
            ),
          );
        }
      }
    }
    flushBlockquote();

    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: widgets,
      ),
    );
  }
}

/// **太字** を反映するテキスト
class BoldText extends StatelessWidget {
  final String text;
  final TextStyle style;

  const BoldText({super.key, required this.text, required this.style});

  @override
  Widget build(BuildContext context) {
    final parts = <InlineSpan>[];
    var i = 0;
    while (i < text.length) {
      final boldStart = text.indexOf('**', i);
      if (boldStart == -1) {
        parts.add(TextSpan(text: text.substring(i), style: style));
        break;
      }
      parts.add(TextSpan(text: text.substring(i, boldStart), style: style));
      final boldEnd = text.indexOf('**', boldStart + 2);
      if (boldEnd == -1) {
        parts.add(TextSpan(text: text.substring(boldStart), style: style));
        break;
      }
      parts.add(TextSpan(
        text: text.substring(boldStart + 2, boldEnd),
        style: style.copyWith(fontWeight: FontWeight.bold),
      ));
      i = boldEnd + 2;
    }
    return RichText(text: TextSpan(children: parts));
  }
}
