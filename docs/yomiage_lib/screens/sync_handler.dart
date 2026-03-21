import 'package:flutter/material.dart';
import 'package:yomiage/services/sync_service.dart';
import 'package:yomiage/services/hive_service.dart';

// デバッグログの制御
const bool _enableDebugLogs = false;

void _debugPrint(String message) {
  if (_enableDebugLogs) {
    debugPrint(message);
  }
}

class SyncHandler {
  /// 同期差異解決処理
  static Future<Map<String, dynamic>> resolveDiscrepanciesAndShowResult(
      BuildContext context, bool isResolvingDiscrepancy) async {
    if (isResolvingDiscrepancy) {
      return {'status': 'already_running'};
    }

    String snackBarMessage = '同期を開始しました...';
    Color snackBarColor = Colors.blue;
    int totalChanges = 0;

    try {
      final syncResult = await SyncService().resolveDataDiscrepancies();

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

      return {
        'status': 'success',
        'message': snackBarMessage,
        'color': snackBarColor,
        'totalChanges': totalChanges,
      };
    } catch (e) {
      snackBarMessage = '同期処理中にエラーが発生しました: $e';
      snackBarColor = Colors.red;
      _debugPrint('同期エラー (SyncHandler): $e');

      return {
        'status': 'error',
        'message': snackBarMessage,
        'color': snackBarColor,
        'error': e.toString(),
      };
    }
  }

  /// 同期後のデータベース更新
  static Future<void> refreshAfterSync(BuildContext context) async {
    try {
      await HiveService.refreshDatabase();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('データベースを更新しました'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      _debugPrint('同期後のデータベース更新エラー: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('データベース更新中にエラーが発生しました: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }
}
