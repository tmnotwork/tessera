import 'package:flutter/material.dart';
import 'package:yomiage/services/sync_service.dart';

class WebSyncHandler {
  // 同期差異解決処理
  static Future<void> resolveDiscrepanciesAndShowResult(
    BuildContext context,
    bool isResolvingDiscrepancy,
    Function(bool) setResolvingDiscrepancy,
    VoidCallback refreshDatabaseState,
  ) async {
    if (isResolvingDiscrepancy) return;

    setResolvingDiscrepancy(true);

    String snackBarMessage = '同期を開始しました...';
    Color snackBarColor = Colors.blue;

    try {
      final syncResult = await SyncService().resolveDataDiscrepancies();

      int totalChanges = 0;
      syncResult.forEach((key, value) {
        if (!['skipped', 'errors'].contains(key)) {
          totalChanges += value;
        }
      });

      if (syncResult['errors']! > 0) {
        snackBarMessage = '同期中に ${syncResult['errors']} 件のエラーが発生しました。';
        snackBarColor = Colors.red;
      } else if (totalChanges > 0) {
        snackBarMessage = '$totalChanges 件のデータを同期しました。';
        snackBarColor = Colors.green;
      } else {
        snackBarMessage = 'データは最新の状態です。';
        snackBarColor = Colors.blue;
      }
    } catch (e) {
      snackBarMessage = '同期処理中にエラーが発生しました: $e';
      snackBarColor = Colors.red;
    } finally {
      if (context.mounted) {
        setResolvingDiscrepancy(false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(snackBarMessage),
            backgroundColor: snackBarColor,
            duration: const Duration(seconds: 2),
          ),
        );
        // 同期後にホーム画面のデータをリフレッシュ
        refreshDatabaseState();
      }
    }
  }
}
