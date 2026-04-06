import 'package:flutter/material.dart';

import '../models/question_dev_review_status.dart';

/// 四択問題のレビュー状態（ブランク／要確認／完了）。プルダウンで3択を明示的に選ぶ（トグルではない）。
class QuestionDevReviewSegmented extends StatelessWidget {
  const QuestionDevReviewSegmented({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final QuestionDevReviewStatus value;
  final ValueChanged<QuestionDevReviewStatus> onChanged;
  final bool enabled;

  static const _items = <(QuestionDevReviewStatus, String)>[
    (QuestionDevReviewStatus.blank, 'ブランク（未着手・枠のみ）'),
    (QuestionDevReviewStatus.pending, '要確認（内容の確認・修正が必要）'),
    (QuestionDevReviewStatus.completed, '完了（開発者が内容確認済み）'),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'レビュー状態',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(
          '執筆・確認の進捗を3段階から選びます（オン／オフのスイッチではありません）。',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<QuestionDevReviewStatus>(
          value: value,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          ),
          isExpanded: true,
          onChanged: enabled
              ? (v) {
                  if (v != null) onChanged(v);
                }
              : null,
          items: [
            for (final e in _items)
              DropdownMenuItem<QuestionDevReviewStatus>(
                value: e.$1,
                child: Text(e.$2),
              ),
          ],
        ),
      ],
    );
  }
}
