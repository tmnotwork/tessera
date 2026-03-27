import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_material.dart';

/// ホームウィジェット関連のデバッグメッセージを SnackBar で表示するユーティリティ。
class WidgetDebugMessenger {
  static const MethodChannel _channel =
      MethodChannel('com.example.task_kant_1/widget_debug');
  static bool _initialized = false;
  static final Queue<String> _queue = Queue<String>();
  static bool _presenting = false;
  static bool _showInAppSnackBars = false;

  /// MethodChannel の購読とハンドラ登録を 1 度だけ実行。
  static void initialize({bool showInAppSnackBars = false}) {
    _showInAppSnackBars = showInAppSnackBars;
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onWidgetDebugEvent') {
        final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
        final stage = (args['stage'] as String?)?.trim();
        final detail = (args['detail'] as String?)?.trim();
        final message = detail != null && detail.isNotEmpty
            ? '$stage · $detail'
            : stage ?? 'Widget debug event';
        showDiagnostic(message);
      }
      return null;
    });
  }

  /// アプリ内（Dart側）から直接デバッグ通知を出すための API。
  static void showDiagnostic(String title, {String? detail}) {
    final message =
        detail != null && detail.isNotEmpty ? '$title · $detail' : title;
    _enqueue(message);
  }

  static void _enqueue(String message) {
    final trimmed = message.trim();
    if (trimmed.isEmpty) return;
    debugPrint('[WidgetDebug] $trimmed');
    if (!_showInAppSnackBars) {
      return;
    }
    final context = navigatorKey.currentContext;
    if (context == null) {
      // UI が存在しない場合はログのみ（ヘッドレス実行時など）
      return;
    }
    _queue.add(trimmed);
    if (_presenting) return;
    _presenting = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _drainQueue(context));
  }

  static void _drainQueue(BuildContext context) {
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
    final message = _queue.removeFirst();
    messenger
        .showSnackBar(
          SnackBar(
            content: Text(message),
            duration: const Duration(seconds: 2),
          ),
        )
        .closed
        .whenComplete(() {
      WidgetsBinding.instance.addPostFrameCallback((_) => _drainQueue(context));
    });
  }
}
