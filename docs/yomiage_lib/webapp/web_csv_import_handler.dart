// ignore_for_file: library_prefixes

import 'package:flutter/material.dart';
import 'package:yomiage/services/csv_service.dart';
import 'package:yomiage/services/hive_service.dart';
import 'package:yomiage/services/firebase_service.dart';
import 'package:yomiage/services/sync_service.dart';
import 'dart:math' as Math;

class WebCsvImportHandler {
  // CSV取り込み機能を直接実行するメソッド
  static Future<void> importCsvWeb(
      BuildContext context, VoidCallback refreshCallback) async {
    try {
      final Map<String, dynamic> result =
          await CsvService.pickAndImportCsvWeb();

      final List<Map<String, dynamic>> errors = result['errors'] ?? [];
      final String message = result['message'] ?? '';
      final bool refreshNeeded = result['refreshNeeded'] ?? false;

      if (message.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            duration: const Duration(seconds: 2),
          ),
        );
      }

      if (errors.isNotEmpty) {
        _showImportErrorDialog(context, errors);
      }

      if (refreshNeeded) {
        refreshCallback();
      }
    } catch (e) {
      _showImportErrorDialog(context, [
        {'rowNumber': 'N/A', 'error': e.toString(), 'data': []}
      ]);
    }
  }

  // エラー詳細を表示するダイアログ (エラーリストを受け取るように変更)
  static void _showImportErrorDialog(
      BuildContext context, List<Map<String, dynamic>> errors) {
    // エラーメッセージを整形
    final errorDetails = errors.map((e) {
      String rowNum = e['rowNumber']?.toString() ?? 'N/A';
      String errMsg = e['error']?.toString() ?? '不明なエラー';
      // オプショナルなデッキ名も表示
      String deckNameInfo =
          e['deckName'] != null ? ' (デッキ: ${e['deckName']})' : '';
      // オプショナルなデータも表示（デバッグ用）
      // String dataInfo = e['data'] != null ? '\n  データ: ${e['data']}' : '';
      return '行 $rowNum$deckNameInfo: $errMsg'; // dataInfo は冗長なので削除
    }).join('\n');

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('CSVインポートエラー'),
        content: SingleChildScrollView(
          // 長いエラーリストに対応
          child: Text(
              'ファイルの読み込みまたは解析中にエラーが発生しました。\nファイル形式や文字コード（UTF-8推奨）を確認してください。\n\n詳細:\n$errorDetails'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  // CSVインポート後の処理
  static Future<void> handleCsvImportResult(
    BuildContext context,
    dynamic result,
    VoidCallback setStateCallback,
    VoidCallback saveSettingsCallback,
  ) async {
    if (result != null) {
      bool success = false;
      int count = 0;
      bool refreshNeeded = false;

      // 新しい形式（オブジェクト）と古い形式（bool）の両方に対応
      if (result is Map) {
        success = result['success'] == true;
        count = result['count'] ?? 0;
        refreshNeeded = result['refreshNeeded'] == true;
      } else if (result is bool) {
        success = result;
      }

      if (success) {
        // ダイアログを表示してデータ読み込み中であることを示す
        if (refreshNeeded && count > 0) {
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (BuildContext context) {
              return const AlertDialog(
                title: Text('データを読み込み中'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('インポートしたデータを読み込んでいます...\nしばらくお待ちください。'),
                  ],
                ),
              );
            },
          );
        }

        // データベースを確実に更新
        try {
          // 複数回再読み込みを試行
          for (int i = 0; i < 2; i++) {
            await HiveService.refreshDatabase();

            // デバッグ情報として現在のデッキとカードの数を表示
            HiveService.getDeckBox();
            final cardBox = HiveService.getCardBox();

            // カードが存在することを確認
            if (cardBox.length > 0) {
              // 最初の数枚のカード情報をログ出力
              final checkLimit = Math.min(5, cardBox.length);
              for (int j = 0; j < checkLimit; j++) {
                final card = cardBox.getAt(j);
                if (card != null) {
                  // print('カード #${j + 1}: " ${card.question} " -> デッキ" ${card.deckName} "');
                }
              }
              break;
            }

            // カードが見つからない場合は少し待機してから再試行
            if (i < 1) {
              await Future.delayed(const Duration(milliseconds: 500));
            }
          }
        } catch (e) {
          // print('ホーム画面: データベース再読み込み中にエラー: $e');
        } finally {
          // ダイアログを閉じる
          if (refreshNeeded && count > 0 && Navigator.canPop(context)) {
            Navigator.of(context).pop();
          }
        }

        // ログインしている場合、データベースの状態をクラウドに同期
        final userId = FirebaseService.getUserId();
        if (userId != null && count > 0) {
          try {
            await SyncService.forceCloudSync();
          } catch (e) {
            // print('同期処理中にエラー: $e');
          }
        }

        setStateCallback();
        // デッキ一覧を更新するためにこれらのフラグを更新
        saveSettingsCallback();

        if (count > 0) {
          // 成功メッセージを表示
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('$count件のカードがインポートされました。表示されない場合は画面を再読み込みしてください。'),
              duration: const Duration(seconds: 5),
              action: SnackBarAction(
                label: '再読み込み',
                onPressed: () {
                  HiveService.refreshDatabase().then((_) {
                    setStateCallback();
                  });
                },
              ),
            ),
          );
        }
      }
    }
  }
}
