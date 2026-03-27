import 'dart:async';

/// 単純な非同期ミューテックス実装。
/// [protect] で囲んだ処理が逐次実行されることを保証する。
class AsyncMutex {
  Completer<void>? _completer;

  /// ミューテックスを取得する。
  Future<void> acquire() async {
    while (true) {
      if (_completer == null) {
        _completer = Completer<void>();
        return;
      }
      try {
        await _completer!.future;
      } catch (_) {
        // ignore: empty_catches
      }
    }
  }

  /// ミューテックスを解放する。
  void release() {
    final completer = _completer;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
    _completer = null;
  }

  /// ミューテックスを利用して処理を逐次実行するユーティリティ。
  Future<T> protect<T>(Future<T> Function() action) async {
    await acquire();
    try {
      return await action();
    } finally {
      release();
    }
  }
}
