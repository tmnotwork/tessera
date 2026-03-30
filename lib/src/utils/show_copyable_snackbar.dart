import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 長文・デバッグ向け: 全文を選択できるようにし、[SnackBarAction] でクリップボードへコピーできる。
void showCopyableSnackBar(
  BuildContext context, {
  required String message,
  Duration duration = const Duration(seconds: 12),
}) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(
    SnackBar(
      duration: duration,
      content: SelectableText(message),
      action: SnackBarAction(
        label: 'コピー',
        onPressed: () {
          Clipboard.setData(ClipboardData(text: message));
          messenger.hideCurrentSnackBar();
          messenger.showSnackBar(
            const SnackBar(
              content: Text('クリップボードにコピーしました'),
              duration: Duration(seconds: 2),
            ),
          );
        },
      ),
    ),
  );
}
