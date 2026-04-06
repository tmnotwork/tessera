import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../sync/sync_engine.dart';
import '../sync/sync_notifier.dart';

/// ローカル SQLite と Supabase の Pull→Push を実行する（設定画面のボタンなどからも利用）。
///
/// Web または [SyncEngine] 未初期化時は SnackBar のみ表示して終了する。
Future<void> runForceDatabaseSync(BuildContext context) async {
  if (kIsWeb || !SyncEngine.isInitialized) {
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('この環境ではローカル同期（強制同期）は利用できません。')),
    );
    return;
  }
  await SyncEngine.instance.sync();
  if (!context.mounted) return;
  final failed = SyncNotifier.instance.state == SyncState.error;
  final err = SyncNotifier.instance.lastError;
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(
      content: Text(
        failed && err != null
            ? '同期に失敗しました: $err'
            : '同期が完了しました（Pull → Push）',
      ),
      backgroundColor: failed ? Theme.of(context).colorScheme.errorContainer : null,
    ),
  );
}

/// ローカル DB と Supabase の Pull→Push を手動で実行する（非 Web のみ表示）。
class ForceSyncIconButton extends StatefulWidget {
  const ForceSyncIconButton({super.key});

  @override
  State<ForceSyncIconButton> createState() => _ForceSyncIconButtonState();
}

class _ForceSyncIconButtonState extends State<ForceSyncIconButton> {
  bool _busy = false;

  Future<void> _run() async {
    setState(() => _busy = true);
    try {
      await runForceDatabaseSync(context);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || !SyncEngine.isInitialized) {
      return const SizedBox.shrink();
    }
    return IconButton(
      icon: _busy
          ? SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            )
          : const Icon(Icons.sync),
      tooltip: '強制同期（サーバーとローカルを Pull→Push）',
      onPressed: _busy ? null : _run,
    );
  }
}
