// ignore_for_file: use_build_context_synchronously, avoid_web_libraries_in_flutter, avoid_print, non_constant_identifier_names

// dart:io を条件付きインポートに変更、または削除して kIsWeb で分岐
// import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;

import 'package:flutter/material.dart';
// file_selector はWebでは不要になる可能性
// import 'package:file_selector/file_selector.dart';
import 'package:yomiage/services/csv_service.dart';
import 'package:yomiage/services/hive_service.dart';
import 'package:hive/hive.dart';
import 'package:yomiage/models/flashcard.dart';

class CsvExportScreen extends StatefulWidget {
  const CsvExportScreen({super.key});

  @override
  State<CsvExportScreen> createState() => _CsvExportScreenState();
}

class _CsvExportScreenState extends State<CsvExportScreen> {
  late Box<FlashCard> cardBox;

  @override
  void initState() {
    super.initState();
    cardBox = HiveService.getCardBox();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('CSVエクスポート', style: TextStyle(color: Colors.white)),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Webの場合はダウンロードボタンを表示
            if (kIsWeb)
              ElevatedButton(
                onPressed: _downloadCsvWeb,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue[800],
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                ),
                child: const Text('CSVファイルをダウンロード',
                    style: TextStyle(fontSize: 20, color: Colors.white)),
              )
            // Webでない場合 (モバイルなど) は従来の共有ボタン
            else
              ElevatedButton(
                onPressed: _exportAndShareMobile,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue[800],
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                ),
                child: const Text('CSVファイルを作成して共有',
                    style: TextStyle(fontSize: 20, color: Colors.white)),
              ),
          ],
        ),
      ),
    );
  }

  // --- Web用 CSVダウンロード処理 ---
  Future<void> _downloadCsvWeb() async {
    try {
      await CsvService.exportAllCards(isWeb: true);
      
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('CSVファイルのダウンロードを開始しました')),
      );
      // ダウンロード後、必要なら画面を閉じる
      // Navigator.of(context).pop();
    } catch (e) {
      print("CSV download error (Web): $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('CSVダウンロードに失敗: $e')),
      );
    }
  }

  // --- モバイル用 CSV共有処理 ---
  Future<void> _exportAndShareMobile() async {
    // kIsWeb でガードされているため、ここがWebで呼ばれることはないはずだが念のため
    if (kIsWeb) return;

    try {
      await CsvService.exportAllCards(isWeb: false);
      
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('CSVファイルを共有しました')),
      );
      Navigator.of(context).pop();
    } catch (e) {
      print("CSV share error (Mobile): $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('CSV共有に失敗: $e')),
      );
    }
  }
}
