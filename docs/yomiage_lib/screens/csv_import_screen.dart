// ignore_for_file: avoid_print, use_build_context_synchronously, prefer_adjacent_string_concatenation, unused_element, await_only_futures, unnecessary_brace_in_string_interps, prefer_const_constructors, deprecated_member_use, prefer_const_declarations

import 'package:flutter/material.dart';
import 'package:intl/intl.dart'; // DateFormat を使うためにインポート
import 'package:shared_preferences/shared_preferences.dart'; // SharedPreferences を使うためにインポート
import '../services/csv_service.dart'; // CsvService をインポート
import 'package:flutter_riverpod/flutter_riverpod.dart'; // Riverpod をインポート
import '../providers/settings_provider.dart'; // settingsServiceProvider をインポート
// import '../models/settings.dart'; // Settings モデルは使用しないため削除

// ConsumerStatefulWidget を使用するために変更
class CsvImportScreen extends ConsumerStatefulWidget {
  const CsvImportScreen({super.key});

  @override
  CsvImportScreenState createState() => CsvImportScreenState();
}

// ConsumerState を継承するように変更
class CsvImportScreenState extends ConsumerState<CsvImportScreen> {
  // CsvService のインスタンスを Riverpod 経由で取得
  // final CsvService _csvService = CsvService(); // 直接インスタンス化しない
  String _message = ''; // インポート結果メッセージ
  bool _isLoading = false; // ローディング状態
  String? _lastImportTime; // 最終インポート日時 (null許容)

  @override
  void initState() {
    super.initState();
    _loadLastImportTime(); // 初期化時に最終インポート日時を読み込む
  }

  // 最終インポート日時を読み込むメソッド
  Future<void> _loadLastImportTime() async {
    // settingsServiceProvider を ref 経由で読み込む
    ref.read(settingsServiceProvider);
    final prefs = await SharedPreferences.getInstance(); // getInstance() を使用
    // SettingsService のメソッドを使って最終インポート時間を取得する想定
    // (例: final time = await settingsService.getLastImportTime();)
    // 以下は SharedPreferences を直接使う場合の仮実装
    final lastImportMillis = prefs.getInt('lastCsvImportTime');
    if (lastImportMillis != null) {
      final lastImportDate =
          DateTime.fromMillisecondsSinceEpoch(lastImportMillis);
      setState(() {
        _lastImportTime = DateFormat('yyyy/MM/dd HH:mm').format(lastImportDate);
      });
    }
  }

  // CSVファイルをインポートする関数
  Future<void> _importCsv() async {
    setState(() {
      _isLoading = true;
      _message = 'CSVファイルをインポート中...';
    });

    try {
      // ★★★ CsvService の static メソッドを直接呼び出すように変更 ★★★
      final Map<String, dynamic> result = await CsvService.pickAndImportCsv();
      // final result = await ref.read(csvServiceProvider).pickAndImportCsv(); // 変更前

      // エラーがあるかどうかで処理を分岐
      if (result['errors'] != null && (result['errors'] as List).isNotEmpty) {
        // as List を追加して型安全に
        // エラーがある場合はダイアログを表示
        _showErrorDialog(
            result['errors'] as List<Map<String, dynamic>>); // as List<Map> を追加
        setState(() {
          // エラーがあった場合でも、一部成功している可能性があるのでメッセージを更新
          final successCount = result['successCount'] ?? 0;
          final updatedCount = result['updatedCount'] ?? 0; // updatedCount も考慮
          final errorCount = (result['errors'] as List).length;
          _message =
              "${successCount}件新規, ${updatedCount}件更新, ${errorCount}件エラー。詳細はダイアログを確認してください。";
          // _loadLastImportTime(); // 最終インポート日時を更新 (finally に移動)
        });
      } else if ((result['successCount'] ?? 0) > 0 ||
          (result['updatedCount'] ?? 0) > 0) {
        // エラーがなく、成功件数または更新件数がある場合は成功メッセージを表示
        final successCount = result['successCount'] ?? 0;
        final updatedCount = result['updatedCount'] ?? 0;
        setState(() {
          _message = '${successCount} 件のカードを新規追加、${updatedCount} 件を更新しました。';
          // _loadLastImportTime(); // 最終インポート日時を更新 (finally に移動)
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_message)),
          );
        }
      } else {
        // 成功もエラーもない場合（ファイルが選択されなかった、データがなかった等）
        setState(() {
          _message = result['message'] ??
              'インポートするデータが見つかりませんでした。'; // CsvServiceからのメッセージを使用
        });
      }

      // 処理が成功したかどうかにかかわらず、最終インポート日時を更新する
      // (ファイル選択をキャンセルした場合を除くなどの考慮は別途必要)
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
          'lastCsvImportTime', DateTime.now().millisecondsSinceEpoch);
      await _loadLastImportTime(); // 表示を更新
    } catch (e) {
      // 予期せぬエラーが発生した場合
      setState(() {
        _message = 'CSVインポート中に予期せぬエラーが発生しました: $e';
      });
      if (!mounted) return;
      // エラーダイアログを表示 (予期せぬエラー用)
      _showErrorDialog([
        {'rowNumber': 'N/A', 'error': e.toString(), 'data': []}
      ]);
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  // エラー詳細を表示するダイアログ
  void _showErrorDialog(List<Map<String, dynamic>> errors) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('CSVインポートエラー詳細'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: errors.length,
              itemBuilder: (context, index) {
                final error = errors[index];
                // エラー情報から詳細を取得 (キーは CsvService の実装に合わせる)
                final rowNum = error['rowNumber'] ?? '不明';
                final errorMsg = error['error'] ?? '不明なエラー';
                final deckName = error['deckName'] ?? '不明'; // デッキ名も表示する場合
                final data =
                    error['data']?.join(', ') ?? 'データなし'; // 元データも表示する場合

                return ListTile(
                  title: Text('行 $rowNum: $errorMsg'),
                  subtitle: Text('デッキ: $deckName\nデータ: $data'),
                );
              },
            ),
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('閉じる'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('CSVインポート'),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              if (_isLoading)
                const CircularProgressIndicator() // ローディングインジケータを表示
              else
                ElevatedButton.icon(
                  icon: const Icon(Icons.upload_file),
                  label: const Text('CSVファイルを選択してインポート'),
                  onPressed: _importCsv, // ボタンが押されたらインポート処理を実行
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 30, vertical: 15),
                    textStyle: const TextStyle(fontSize: 16),
                  ),
                ),
              const SizedBox(height: 20),
              if (_lastImportTime != null)
                Text(
                  '最終インポート日時: $_lastImportTime',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              const SizedBox(height: 20),
              // if (_message.isNotEmpty) // メッセージ表示は SnackBar と Dialog に任せる
              //   Text(
              //     _message,
              //     style: TextStyle(
              //       color: _message.contains('エラー') ? Colors.red : Colors.green,
              //       fontWeight: FontWeight.bold,
              //     ),
              //     textAlign: TextAlign.center,
              //   ),
            ],
          ),
        ),
      ),
    );
  }
}
