import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// 教材管理画面へ遷移するコールバックを保持。
/// main の RootScaffold が build 時に set し、QuestionSolveScreen の編集ボタン等が呼び出す。
final openManageNotifier = _OpenManageNotifier();

class _OpenManageNotifier {
  void Function(BuildContext context)? openManage;
}

/// 認証状態（ログイン・ログアウト・ロール）を管理する。
/// main() で init() を呼び、RootScaffold が listen() で変更を受け取る。
final appAuthNotifier = AppAuthNotifier();

class AppAuthNotifier {
  User? get currentUser => Supabase.instance.client.auth.currentUser;
  bool get isLoggedIn => currentUser != null;

  String? _cachedRole;
  StreamSubscription<AuthState>? _sub;
  void Function()? _listener;

  void init() {
    _sub = Supabase.instance.client.auth.onAuthStateChange.listen((_) {
      _cachedRole = null;
      _listener?.call();
    });
  }

  /// profiles テーブルからロールを取得する（結果はキャッシュ）。
  Future<String?> fetchRole() async {
    if (!isLoggedIn) return null;
    if (_cachedRole != null) return _cachedRole;
    try {
      final row = await Supabase.instance.client
          .from('profiles')
          .select('role')
          .eq('id', currentUser!.id)
          .maybeSingle();
      _cachedRole = row?['role'] as String?;
    } catch (_) {}
    return _cachedRole;
  }

  /// 教師：メールアドレスで新規登録（DB トリガーが role=teacher を付与）
  Future<void> signUpTeacher(String email, String password) async {
    await Supabase.instance.client.auth.signUp(email: email, password: password);
  }

  /// 教師：メールアドレスでログイン
  Future<void> loginTeacher(String email, String password) async {
    await Supabase.instance.client.auth.signInWithPassword(
        email: email, password: password);
  }

  /// 学習者：user_id を email に変換してログイン
  Future<void> loginLearner(String userId, String password) async {
    await Supabase.instance.client.auth.signInWithPassword(
        email: '$userId@tessera.local', password: password);
  }

  Future<void> logout() async {
    await Supabase.instance.client.auth.signOut();
  }

  void listen(void Function() fn) => _listener = fn;

  void dispose() {
    _sub?.cancel();
    _listener = null;
  }
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
