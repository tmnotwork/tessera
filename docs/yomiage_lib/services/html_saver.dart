// html_saver.dart
// Webプラットフォーム用のファイル保存実装
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use, avoid_print, prefer_const_constructors

import 'dart:html' as html;
import 'dart:typed_data';

void saveFileWeb(Uint8List data, String fileName) {
  final blob = html.Blob([data], 'text/csv;charset=utf-8');
  final url = html.Url.createObjectUrlFromBlob(blob);

  // ★★★ アンカー要素を作成してダウンロードをトリガー ★★★
  final anchor = html.document.createElement('a') as html.AnchorElement
    ..href = url
    ..style.display = 'none'
    ..download = fileName;
  html.document.body!.children.add(anchor);
  anchor.click(); // クリックしてダウンロードを開始

  // URLを解放（メモリリーク防止）
  // 少し遅延させてからURLを解放（ダウンロードが開始される時間を確保）
  Future.delayed(Duration(milliseconds: 100), () {
    html.document.body!.children.remove(anchor);
    html.Url.revokeObjectUrl(url);
  });
  print('WebでCSVファイルをダウンロード開始: $fileName');
}
