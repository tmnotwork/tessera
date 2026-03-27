import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'web_save_shortcut_interceptor_stub.dart'
    if (dart.library.html) 'web_save_shortcut_interceptor_web.dart' as barrier_impl;

/// Web でダイアログ／画面が表示されている間だけ、Ctrl/Cmd+S のブラウザ既定を抑止する。
class WebScopedSaveShortcutBarrier extends StatefulWidget {
  const WebScopedSaveShortcutBarrier({super.key, required this.child});

  final Widget child;

  @override
  State<WebScopedSaveShortcutBarrier> createState() =>
      _WebScopedSaveShortcutBarrierState();
}

class _WebScopedSaveShortcutBarrierState
    extends State<WebScopedSaveShortcutBarrier> {
  Object? _handle;

  @override
  void initState() {
    super.initState();
    if (kIsWeb) {
      _handle = barrier_impl.attachWebPageSaveShortcutBarrier();
    }
  }

  @override
  void dispose() {
    barrier_impl.detachWebPageSaveShortcutBarrier(_handle);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
