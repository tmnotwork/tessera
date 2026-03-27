import 'package:flutter/foundation.dart';

/// タスク集約後の巻き戻り調査用ログ。
///
/// Android Studio / VS Code / `adb logcat` では `KANT_INBOX_TRACE` でフィルタ。
/// debug / release どちらでも [print] する（ユーザー環境で既存ログが見えない事例への対策）。
void kantInboxTrace(String phase, [String? detail]) {
  final extra = (detail != null && detail.isNotEmpty) ? ' | $detail' : '';
  final line = 'KANT_INBOX_TRACE $phase$extra';
  debugPrint(line);
  // ignore: avoid_print
  print(line);
}
