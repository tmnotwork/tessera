import 'package:flutter/material.dart';
import '../services/sync_service.dart';
import '../services/sync/notification_service.dart';

class SyncStatusWidget extends StatelessWidget {
  final SyncService syncService;

  const SyncStatusWidget({Key? key, required this.syncService})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<SyncStatus>(
      stream: syncService.syncStatusStream,
      initialData: syncService.status,
      builder: (context, snapshot) {
        final status = snapshot.data ?? SyncStatus.idle;

        IconData icon;
        Color color;
        String tooltip;

        switch (status) {
          case SyncStatus.syncing:
            icon = Icons.sync;
            color = Colors.amber;
            tooltip = '同期中...';
            break;
          case SyncStatus.synced:
            icon = Icons.cloud_done;
            color = Colors.green;
            tooltip = '同期完了';
            break;
          case SyncStatus.error:
            icon = Icons.cloud_off;
            color = Colors.red;
            tooltip = '同期エラー';
            break;
          case SyncStatus.idle:
            icon = Icons.cloud_queue;
            color = Colors.grey;
            tooltip = '同期待機中';
            break;
        }

        // 同期中はアイコンを回転させる
        if (status == SyncStatus.syncing) {
          return Tooltip(
            message: tooltip,
            child: AnimatedRotation(
              duration: const Duration(seconds: 1),
              turns: 1.0,
              child: Icon(
                icon,
                color: color,
              ),
            ),
          );
        }

        // 通常表示
        return Tooltip(
          message: tooltip,
          child: Icon(
            icon,
            color: color,
          ),
        );
      },
    );
  }
}

// 同期ボタンウィジェット
class SyncButton extends StatelessWidget {
  final SyncService syncService;
  final VoidCallback onPressed;

  const SyncButton({
    Key? key,
    required this.syncService,
    required this.onPressed,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<SyncStatus>(
      stream: syncService.syncStatusStream,
      initialData: syncService.status,
      builder: (context, snapshot) {
        final status = snapshot.data ?? SyncStatus.idle;
        final bool isSyncing = status == SyncStatus.syncing;

        return ElevatedButton.icon(
          onPressed: isSyncing ? null : onPressed,
          icon: isSyncing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.sync),
          label: Text(isSyncing ? '同期中...' : '今すぐ同期'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.primary,
            foregroundColor: Colors.white,
            disabledBackgroundColor: Colors.grey.shade700,
            disabledForegroundColor: Colors.grey.shade300,
          ),
        );
      },
    );
  }
}
