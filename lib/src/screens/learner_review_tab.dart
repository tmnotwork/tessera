import 'package:flutter/material.dart';

import '../widgets/force_sync_icon_button.dart';
import 'settings_screen.dart';

/// 復習タブ（プレースホルダ）：生徒IDを表示し、近日追加予定のメッセージを表示
class LearnerReviewTab extends StatelessWidget {
  const LearnerReviewTab({super.key, this.displayId});

  final String? displayId;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('復習'),
        actions: [
          const ForceSyncIconButton(),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '設定',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const SettingsScreen(),
                ),
              );
            },
          ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.badge_outlined, size: 16, color: scheme.onPrimaryContainer),
                    const SizedBox(width: 6),
                    Text(
                      displayId != null ? '生徒ID: $displayId' : '生徒',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: scheme.onPrimaryContainer,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 40),
              Icon(Icons.replay, size: 72, color: scheme.outline),
              const SizedBox(height: 20),
              Text(
                '復習',
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              Text(
                '復習機能は近日公開予定です',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
