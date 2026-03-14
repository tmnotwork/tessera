import 'package:flutter/material.dart';

/// 教材管理画面へ遷移するコールバックを保持。
/// main の RootScaffold が build 時に set し、QuestionSolveScreen の編集ボタン等が呼び出す。
final openManageNotifier = _OpenManageNotifier();

class _OpenManageNotifier {
  void Function(BuildContext context)? openManage;
}

/// ダークモード（テーマ）の設定を保持し、変更を通知する。
/// RootApp が listen し、設定画面から setThemeMode を呼ぶ。
final appThemeNotifier = AppThemeNotifier();

class AppThemeNotifier {
  ThemeMode _mode = ThemeMode.system;
  void Function(ThemeMode)? _listener;

  ThemeMode get mode => _mode;

  void setThemeMode(ThemeMode value) {
    if (_mode == value) return;
    _mode = value;
    _listener?.call(value);
  }

  /// 起動時のみ。保存済みのテーマを反映する。
  void initThemeMode(ThemeMode value) {
    _mode = value;
  }

  void listen(void Function(ThemeMode) fn) {
    _listener = fn;
  }

  void dispose() {
    _listener = null;
  }
}
