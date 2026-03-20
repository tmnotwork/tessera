import 'package:flutter/material.dart';

import '../models/english_example.dart';

/// 英語例文の出題。表=日本語 → 裏=英語 → 解説・補足 → 自己申告
class EnglishExampleSolveScreen extends StatefulWidget {
  const EnglishExampleSolveScreen({
    super.key,
    required this.examples,
    this.subjectName,
  });

  final List<EnglishExample> examples;
  final String? subjectName;

  @override
  State<EnglishExampleSolveScreen> createState() => _EnglishExampleSolveScreenState();
}

class _EnglishExampleSolveScreenState extends State<EnglishExampleSolveScreen> {
  int _index = 0;
  bool _showBack = false;

  EnglishExample get _current => widget.examples[_index];
  bool get _hasNext => _index + 1 < widget.examples.length;
  bool get _hasEn => _current.backEn.trim().isNotEmpty;

  void _onRevealBack() {
    setState(() => _showBack = true);
  }

  void _onSelfReport(bool correct) {
    if (_hasNext) {
      setState(() {
        _index += 1;
        _showBack = false;
      });
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.examples.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.subjectName ?? '英語例文')),
        body: const Center(child: Text('出題する例文がありません')),
      );
    }

    final theme = Theme.of(context);
    final ex = _current;
    final exp = ex.explanation?.trim();
    final sup = ex.supplement?.trim();

    return Scaffold(
      appBar: AppBar(
        title: widget.examples.length > 1
            ? Text('${widget.subjectName ?? '英語例文'}（${_index + 1} / ${widget.examples.length}）')
            : Text(widget.subjectName ?? '英語例文'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '日本語（表）',
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SelectableText(
                  ex.frontJa.isEmpty ? '（未設定）' : ex.frontJa,
                  style: theme.textTheme.titleMedium,
                ),
              ),
            ),
            const SizedBox(height: 24),
            if (!_showBack) ...[
              if (_hasEn)
                FilledButton.icon(
                  onPressed: _onRevealBack,
                  icon: const Icon(Icons.translate),
                  label: const Text('英語（裏）を見る'),
                )
              else
                Text(
                  '英語の本文がありません',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ] else ...[
              Text(
                '英語（裏）',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Card(
                margin: EdgeInsets.zero,
                color: theme.colorScheme.surfaceContainerHighest,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(
                    ex.backEn,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ),
              if (exp != null && exp.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text(
                  '解説',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: SelectableText(exp, style: theme.textTheme.bodyLarge),
                  ),
                ),
              ],
              if (sup != null && sup.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  '補足',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: SelectableText(sup, style: theme.textTheme.bodyMedium),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              Text(
                '英訳は合っていましたか？',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonal(
                      onPressed: () => _onSelfReport(false),
                      style: FilledButton.styleFrom(
                        backgroundColor: theme.colorScheme.errorContainer,
                        foregroundColor: theme.colorScheme.onErrorContainer,
                      ),
                      child: const Text('違う'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => _onSelfReport(true),
                      child: const Text('合っている'),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
