import 'package:flutter/material.dart';

/// 「要確認」（false）と「完成」（true）を明示的に選ぶ UI（トグルではない）
class DevCompletionSegmented extends StatelessWidget {
  const DevCompletionSegmented({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final bool value;
  final ValueChanged<bool> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '完成状態',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(
          'AI 生成などの内容を、レビュー状況に応じて分類します。',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        Opacity(
          opacity: enabled ? 1 : 0.5,
          child: SegmentedButton<bool>(
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            segments: const [
              ButtonSegment<bool>(
                value: false,
                label: Text('要確認'),
                tooltip: '内容の確認・修正がまだ必要',
              ),
              ButtonSegment<bool>(
                value: true,
                label: Text('完成'),
                tooltip: '開発者が内容確認済み',
              ),
            ],
            selected: {value},
            emptySelectionAllowed: false,
            onSelectionChanged: (Set<bool> next) {
              if (!enabled || next.isEmpty) return;
              onChanged(next.first);
            },
          ),
        ),
      ],
    );
  }
}
