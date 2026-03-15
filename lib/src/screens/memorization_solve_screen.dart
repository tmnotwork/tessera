import 'package:flutter/material.dart';

import '../models/memorization_card.dart';

/// 暗記カードを出題する画面。表表示 → 裏表示 → 正解/不正解の自己申告
class MemorizationSolveScreen extends StatefulWidget {
  const MemorizationSolveScreen({
    super.key,
    required this.cards,
    this.subjectName,
  });

  final List<MemorizationCard> cards;
  final String? subjectName;

  @override
  State<MemorizationSolveScreen> createState() => _MemorizationSolveScreenState();
}

class _MemorizationSolveScreenState extends State<MemorizationSolveScreen> {
  int _index = 0;
  bool _showBack = false;

  MemorizationCard get _currentCard => widget.cards[_index];
  bool get _hasNext => _index + 1 < widget.cards.length;
  bool get _hasBack => _currentCard.backContent != null && _currentCard.backContent!.isNotEmpty;

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
    if (widget.cards.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.subjectName ?? '暗記カード')),
        body: const Center(child: Text('出題するカードがありません')),
      );
    }

    final theme = Theme.of(context);
    final card = _currentCard;

    return Scaffold(
      appBar: AppBar(
        title: widget.cards.length > 1
            ? Text('${widget.subjectName ?? '暗記カード'}（${_index + 1} / ${widget.cards.length}）')
            : Text(widget.subjectName ?? '暗記カード'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 表（表側の内容）
            Text(
              '表',
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
                  card.frontContent.isEmpty ? '（表が未設定）' : card.frontContent,
                  style: theme.textTheme.titleMedium,
                ),
              ),
            ),
            const SizedBox(height: 24),

            if (!_showBack) ...[
              if (_hasBack)
                FilledButton.icon(
                  onPressed: _onRevealBack,
                  icon: const Icon(Icons.visibility),
                  label: const Text('裏を見る'),
                )
              else
                Text(
                  '裏の内容がありません',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ] else ...[
              Text(
                '裏',
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
                    card.backContent ?? '',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                '正解でしたか？',
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
                      child: const Text('不正解'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => _onSelfReport(true),
                      child: const Text('正解'),
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
