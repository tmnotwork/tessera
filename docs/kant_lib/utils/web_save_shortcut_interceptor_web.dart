// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:html' as html;

/// Ctrl/Cmd+S のブラウザ既定（ページの保存）を抑止する。
/// Flutter 側の [CallbackShortcuts] がキーを受け取れるようにする。
Object? attachWebPageSaveShortcutBarrier() {
  void onKeyDown(html.Event ev) {
    if (ev is! html.KeyboardEvent) return;
    final e = ev;
    if (e.repeat == true) return;
    final k = e.key;
    if (k != 's' && k != 'S') return;
    if (e.ctrlKey != true && e.metaKey != true) return;
    if (e.shiftKey == true || e.altKey == true) return;
    // preventDefault のみ。stopPropagation するとキーが Flutter エンジンに届かず
    // CallbackShortcuts が一度も動かない（無反応になる）。
    e.preventDefault();
  }

  html.document.addEventListener('keydown', onKeyDown, true);
  return onKeyDown;
}

void detachWebPageSaveShortcutBarrier(Object? handle) {
  if (handle == null) return;
  html.document.removeEventListener(
    'keydown',
    handle as void Function(html.Event),
    true,
  );
}
