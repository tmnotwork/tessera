// conditional_saver.dart
// dart.library.html が利用可能（Web環境）であれば html_saver.dart を、
// そうでなければ io_saver.dart をエクスポートする。
export 'io_saver.dart' if (dart.library.html) 'html_saver.dart';
