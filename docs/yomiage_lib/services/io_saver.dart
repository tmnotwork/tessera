// io_saver.dart
// 非Webプラットフォーム用のスタブ実装
// ignore_for_file: avoid_print

import 'dart:typed_data';

void saveFileWeb(Uint8List data, String fileName) {
  // isWeb=true でこの関数が呼ばれることは想定しない
  print('Error: Attempted to call web save function on non-web platform.');
  throw UnimplementedError(
      'File saving via web API is not available on this platform.');
}
