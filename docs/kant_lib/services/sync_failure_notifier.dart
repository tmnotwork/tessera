import 'dart:collection';

import 'package:flutter/material.dart';

import '../app/app_material.dart';

/// 同期（クラウド反映）失敗をユーザーへ通知するための共通ユーティリティ。
///
/// - UIの呼び出し元が BuildContext を持っていない（outbox/バックグラウンド等）ケースでも、
///   navigatorKey 経由で SnackBar を表示できるようにする。
/// - 失敗が短時間に連続する場合はスパムになりやすいので、キー単位でレート制限する。
class SyncFailureNotifier {
  static final Map<String, DateTime> _lastShownAt = <String, DateTime>{};
  static final Queue<_PendingMessage> _queue = Queue<_PendingMessage>();
  static bool _presenting = false;

  /// 既定: 同一キーは最短60秒に1回だけ表示。
  static const Duration _defaultCooldown = Duration(seconds: 60);

  static void show(
    String message, {
    String key = 'syncFailure',
    Duration cooldown = _defaultCooldown,
  }) {
    final trimmed = message.trim();
    if (trimmed.isEmpty) return;

    final now = DateTime.now();
    final last = _lastShownAt[key];
    if (last != null && now.difference(last) < cooldown) {
      return;
    }
    _lastShownAt[key] = now;

    final context = navigatorKey.currentContext;
    if (context == null) {
      // UIが存在しない場合は通知できない（ヘッドレス実行など）
      return;
    }

    _queue.add(_PendingMessage(trimmed));
    if (_presenting) return;
    _presenting = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _drain(context));
  }

  static void _drain(BuildContext context) {
    if (_queue.isEmpty) {
      _presenting = false;
      return;
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) {
      _queue.clear();
      _presenting = false;
      return;
    }

    final msg = _queue.removeFirst().message;
    messenger
        .showSnackBar(
          SnackBar(
            content: Text(msg),
            duration: const Duration(seconds: 4),
          ),
        )
        .closed
        .whenComplete(() {
      WidgetsBinding.instance.addPostFrameCallback((_) => _drain(context));
    });
  }
}

class _PendingMessage {
  final String message;
  const _PendingMessage(this.message);
}

