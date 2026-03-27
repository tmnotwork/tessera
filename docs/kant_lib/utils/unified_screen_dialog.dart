import 'package:flutter/material.dart';

import 'ime_safe_dialog.dart';

/// 画面（Scaffold/BlockEditorPage 等）を「ダイアログ表示」に統一するためのヘルパ。
///
/// - **スマホ幅**: `Dialog.fullscreen` で“ほぼフル画面”表示（= 体感は全画面に近い）
/// - **それ以外**: 大きめの `Dialog` に収める（既存の全画面混在を解消）
///
/// NOTE:
/// - Web の IME 問題を避けるため、内部は `showImeSafeDialog` を使う。
/// - `builder` が返す Widget は通常 `Scaffold` を想定（AlertDialog などはこの関数では包まない）。
Future<T?> showUnifiedScreenDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = false,
  bool useRootNavigator = true,
}) {
  return showImeSafeDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    useRootNavigator: useRootNavigator,
    builder: (dialogCtx) {
      final mq = MediaQuery.of(dialogCtx);
      final size = mq.size;
      final bool isPhoneLike = size.shortestSide < 600;

      final child = builder(dialogCtx);

      if (isPhoneLike) {
        // “ダイアログ表示に統一”しつつ、スマホではほぼ全画面に寄せる。
        // （閉じる導線は child 側の AppBar/ボタンで担保）
        return Dialog.fullscreen(child: child);
      }

      // Tablet/Web/Desktop: 大きめのウィンドウとして表示
      final double targetW = (size.width * 0.92).clamp(560.0, 980.0);
      final double targetH = (size.height * 0.92).clamp(560.0, 920.0);

      return Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: SizedBox(
          width: targetW,
          height: targetH,
          child: child,
        ),
      );
    },
  );
}

