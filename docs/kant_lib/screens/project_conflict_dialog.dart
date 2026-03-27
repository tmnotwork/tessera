import 'package:flutter/material.dart';
import '../models/project.dart';

class ProjectConflictDialog extends StatelessWidget {
  final Project local;
  final Project remote;

  const ProjectConflictDialog(
      {super.key, required this.local, required this.remote});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('競合の解決'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildFieldDiff(context, '名前', local.name, remote.name),
            const SizedBox(height: 8),
            _buildFieldDiff(context, '説明', local.description ?? '',
                remote.description ?? ''),
            const SizedBox(height: 8),
            _buildFieldDiff(
                context, 'カテゴリ', local.category ?? '', remote.category ?? ''),
            const SizedBox(height: 12),
            Text('どちらを採用しますか？', style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop('local'),
          child: const Text('ローカルを採用'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop('remote'),
          child: const Text('リモートを採用'),
        ),
      ],
    );
  }

  Widget _buildFieldDiff(
      BuildContext context, String label, String localVal, String remoteVal) {
    final same = (localVal == remoteVal);
    final scheme = Theme.of(context).colorScheme;
    final colorLocal =
        same ? Theme.of(context).textTheme.bodyMedium?.color : scheme.primary;
    final colorRemote =
        same ? Theme.of(context).textTheme.bodyMedium?.color : scheme.secondary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 4),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('ローカル', style: Theme.of(context).textTheme.bodySmall),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      border: Border.all(color: Theme.of(context).dividerColor),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(localVal, style: TextStyle(color: colorLocal)),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('リモート', style: Theme.of(context).textTheme.bodySmall),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      border: Border.all(color: Theme.of(context).dividerColor),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child:
                        Text(remoteVal, style: TextStyle(color: colorRemote)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}
