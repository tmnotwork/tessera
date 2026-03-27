import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// IME の未確定文字（composing）状態を検出する。
bool isImeComposing(TextEditingController controller) {
  final TextEditingValue value = controller.value;
  return value.isComposingRangeValid && !value.composing.isCollapsed;
}

/// IME composing 中にショートカット処理を実行しないためのガード。
bool shouldHandleImeShortcut(
  KeyEvent event,
  TextEditingController controller,
) {
  if (isImeComposing(controller)) {
    return false;
  }
  return event is KeyDownEvent || event is KeyRepeatEvent;
}
