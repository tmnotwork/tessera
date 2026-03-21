import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:yomiage/services/csv_service.dart';
import 'package:yomiage/services/hive_service.dart';
import 'package:yomiage/services/firebase_service.dart';
import 'package:yomiage/services/sync_service.dart';
import 'dart:math' as math;

// デバッグログの制御
const bool _enableDebugLogs = false;

void _debugPrint(String message) {
  if (_enableDebugLogs) {
    debugPrint(message);
  }
}

class CsvHandler {
  /// CSVを生成して共有する関数 (Android向け)
  static Future<void> exportAndShareCsvFromHome(BuildContext context) async {
    _debugPrint('--- exportAndShareCsvFromHome: Start ---');
    // Webでは実行しない
    if (kIsWeb) {
      _debugPrint("CSV Export is not supported on Web from Home screen.");
      return;
    }

    try {
      _debugPrint(
          '--- exportAndShareCsvFromHome: Calling CsvService.exportAllCards... ---');
      await CsvService.exportAllCards(isWeb: false);

      _debugPrint(
          '--- exportAndShareCsvFromHome: CSV export completed successfully ---');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('CSVファイルを共有しました'), backgroundColor: Colors.green),
        );
      }
    } catch (e, stacktrace) {
      _debugPrint("--- exportAndShareCsvFromHome: Error during CSV sharing: $e ---");
      _debugPrint("Stacktrace: $stacktrace");
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('CSVエクスポート中にエラーが発生しました: $e'),
              backgroundColor: Colors.red),
        );
      }
    } finally {
      _debugPrint('--- exportAndShareCsvFromHome: End ---');
    }
  }

  /// CSVインポート後の処理
  static Future<void> handleCsvImportResult(
      BuildContext context, dynamic result) async {
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
      _debugPrint('CSVインポートが成功しました: $count 件のカードをインポート');
      _debugPrint('データ再読み込みフラグ: $refreshNeeded');

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
          _debugPrint('ホーム画面: データベースを再読み込みしました (${i + 1}回目)');

          // デバッグ情報として現在のデッキとカードの数を表示
          final deckBox = HiveService.getDeckBox();
          final cardBox = HiveService.getCardBox();
          _debugPrint('現在のデッキ数: ${deckBox.length}');
          _debugPrint('現在のカード数: ${cardBox.length}');

          // カードが存在することを確認
          if (cardBox.length > 0) {
            _debugPrint('少なくとも1枚のカードが存在します');
            // 最初の数枚のカード情報をログ出力
            final checkLimit = math.min(5, cardBox.length);
            for (int j = 0; j < checkLimit; j++) {
              final card = cardBox.getAt(j);
              if (card != null) {
                _debugPrint(
                    'カード #${j + 1}: 「${card.question}」 -> デッキ「${card.deckName}」');
              }
            }
            break;
          }

          // カードが見つからない場合は少し待機してから再試行
          if (i < 1) {
            _debugPrint('カードが見つかりません。少し待機してから再試行します...');
            await Future.delayed(const Duration(milliseconds: 500));
          }
        }
      } catch (e) {
        _debugPrint('ホーム画面: データベース再読み込み中にエラー: $e');
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
          _debugPrint('クラウド同期状態を確認中...');
          // SyncServiceの既存メソッドを使用
          await SyncService.forceCloudSync();
        } catch (e) {
          _debugPrint('同期処理中にエラー: $e');
        }
      }

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
                  if (context.mounted) {
                    // 画面の再描画を促す
                    Navigator.of(context).pop(); // 現在の画面を閉じて再読み込み
                  }
                });
              },
            ),
          ),
        );
      }
    }
  }
}
