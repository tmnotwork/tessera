import 'package:flutter/material.dart';
import 'package:yomiage/services/csv_service.dart';

class WebCsvExporter {
  static Future<void> downloadCsvWeb(BuildContext context) async {
    try {
      await CsvService.exportAllCards(isWeb: true);
      
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('CSVファイルのダウンロードを開始しました')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('CSVダウンロードに失敗: $e')),
      );
    }
  }
} 