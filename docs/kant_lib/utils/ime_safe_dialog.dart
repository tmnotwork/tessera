import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Web の IME 変換候補ウィンドウが、showDialog のデフォルト遷移（Scale/Transform）
/// の影響で入力文字と重なって見えるケースがある。
///
/// Web の場合は showGeneralDialog + Fade のみで表示し、Transform を避ける。
/// それ以外のプラットフォームでは通常の showDialog を使う。
Future<T?> showImeSafeDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  bool useRootNavigator = true,
  Color barrierColor = Colors.black54,
  Duration transitionDuration = const Duration(milliseconds: 150),
}) {
  if (!kIsWeb) {
    return showDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      useRootNavigator: useRootNavigator,
      builder: builder,
    );
  }

  final barrierLabel =
      MaterialLocalizations.of(context).modalBarrierDismissLabel;

  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: barrierLabel,
    barrierColor: barrierColor,
    transitionDuration: transitionDuration,
    pageBuilder: (dialogCtx, __, ___) {
      // showDialog と同様に Theme 等を引き継ぎつつ中央へ配置し、
      // SafeArea で端切れを防ぐ。
      final themedChild = InheritedTheme.captureAll(
        context,
        Builder(builder: builder),
      );
      return SafeArea(
        child: Center(
          child: themedChild,
        ),
      );
    },
    transitionBuilder: (ctx, animation, secondaryAnimation, child) {
      return FadeTransition(opacity: animation, child: child);
    },
  );
}

