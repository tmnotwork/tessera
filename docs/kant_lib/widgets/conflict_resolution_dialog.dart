import 'package:flutter/material.dart';

class ConflictFieldDiff {
  final String label;
  final String localValue;
  final String remoteValue;
  ConflictFieldDiff(
      {required this.label,
      required this.localValue,
      required this.remoteValue});
}

class ConflictResolutionDialog extends StatelessWidget {
  final String title;
  final List<ConflictFieldDiff> fields;
  const ConflictResolutionDialog(
      {super.key, required this.title, required this.fields});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ...fields.map((f) => _buildFieldDiff(context, f)),
              const SizedBox(height: 12),
              Text('どちらを採用しますか？',
                  style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop('local'),
            child: const Text('ローカルを採用')),
        FilledButton(
            onPressed: () => Navigator.of(context).pop('remote'),
            child: const Text('リモートを採用')),
      ],
    );
  }

  Widget _buildFieldDiff(BuildContext context, ConflictFieldDiff f) {
    final same = f.localValue == f.remoteValue;
    final scheme = Theme.of(context).colorScheme;
    final colorLocal =
        same ? Theme.of(context).textTheme.bodyMedium?.color : scheme.primary;
    final colorRemote =
        same ? Theme.of(context).textTheme.bodyMedium?.color : scheme.secondary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(f.label, style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 4),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: _valueBox(context, 'ローカル', f.localValue, colorLocal)),
          const SizedBox(width: 8),
          Expanded(
              child: _valueBox(context, 'リモート', f.remoteValue, colorRemote)),
        ])
      ]),
    );
  }

  Widget _valueBox(
      BuildContext context, String label, String value, Color? color) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: Theme.of(context).textTheme.bodySmall),
      Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(value, style: TextStyle(color: color)),
      ),
    ]);
  }
}
