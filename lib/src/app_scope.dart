import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'teacher_signup_gate.dart';

/// 教材管理画面へ遷移するコールバックを保持。
/// main の RootScaffold が build 時に set し、教師の学習タブ・特権学習者 ID・QuestionSolveScreen の編集等が呼び出す。
final openManageNotifier = _OpenManageNotifier();

/// 学習者のショートログインID（profiles.user_id）がこの値のとき、学習メニューから教材管理タブへ遷移できる。
const kLearnerShortIdWithManageShortcut = '教師';

bool learnerProfileUserIdShowsManageShortcut(String? profileUserId) =>
    profileUserId != null && profileUserId == kLearnerShortIdWithManageShortcut;

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
  bool _profileUserIdLoaded = false;
  String? _profileUserId;
  StreamSubscription<AuthState>? _sub;
  void Function()? _listener;

  void init() {
    _sub = Supabase.instance.client.auth.onAuthStateChange.listen((_) {
      _cachedRole = null;
      _profileUserIdLoaded = false;
      _profileUserId = null;
      _listener?.call();
    });
  }

  /// profiles テーブルからロールを取得する（結果はキャッシュ）。
  /// 行が無い場合は ensure_my_profile() で自動作成してから再取得する。
  /// 既存ユーザーに教師権限を付けるのはこの RPC であり、「再読み込み」は単にこの処理を再度実行するだけ。
  Future<String?> fetchRole() async {
    if (!isLoggedIn) return null;
    if (_cachedRole != null) return _cachedRole;
    try {
      var row = await Supabase.instance.client
          .from('profiles')
          .select('role')
          .eq('id', currentUser!.id)
          .maybeSingle();
      if (row == null) {
        await Supabase.instance.client.rpc('ensure_my_profile');
        row = await Supabase.instance.client
            .from('profiles')
            .select('role')
            .eq('id', currentUser!.id)
            .maybeSingle();
      }
      _cachedRole = row?['role'] as String?;
    } catch (e, st) {
      assert(() {
        // 開発時のみ: ensure_my_profile 未デプロイ等で RPC が失敗すると role が null のままになる
        debugPrint('fetchRole/ensure_my_profile failed: $e\n$st');
        return true;
      }());
    }
    return _cachedRole;
  }

  /// profiles.user_id（学習者のショートログインID）。教師は通常 null。
  Future<String?> fetchProfileUserId() async {
    if (!isLoggedIn) return null;
    if (_profileUserIdLoaded) return _profileUserId;
    _profileUserIdLoaded = true;
    try {
      var row = await Supabase.instance.client
          .from('profiles')
          .select('user_id')
          .eq('id', currentUser!.id)
          .maybeSingle();
      if (row == null) {
        await Supabase.instance.client.rpc('ensure_my_profile');
        row = await Supabase.instance.client
            .from('profiles')
            .select('user_id')
            .eq('id', currentUser!.id)
            .maybeSingle();
      }
      final raw = row?['user_id']?.toString().trim();
      _profileUserId = (raw != null && raw.isNotEmpty) ? raw : null;
    } catch (e, st) {
      _profileUserId = null;
      assert(() {
        debugPrint('fetchProfileUserId failed: $e\n$st');
        return true;
      }());
    }
    return _profileUserId;
  }

  /// 教師：メールアドレスで新規登録（DB トリガーが role=teacher を付与）。
  /// 戻り値の user.identities が空の場合は既に登録済み。
  ///
  /// [TeacherSignupBlocked] … `TEACHER_SIGNUP_ALLOWED_DOMAINS` 指定時に許可外メール。
  Future<AuthResponse> signUpTeacher(String email, String password) async {
    final blocked = TeacherSignupGate.rejectionMessageIfAny(email);
    if (blocked != null) throw TeacherSignupBlocked(blocked);
    return Supabase.instance.client.auth.signUp(email: email, password: password);
  }

  /// 確認メールを再送（未確認の登録メールアドレス向け）
  Future<void> resendConfirmationEmail(String email) async {
    await Supabase.instance.client.auth.resend(
      type: OtpType.signup,
      email: email.trim(),
    );
  }

  /// 教師：パスワードリセット用メールを送信
  Future<void> resetPasswordForEmail(String email) async {
    await Supabase.instance.client.auth.resetPasswordForEmail(email.trim());
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

  /// ロールキャッシュをクリア（再読み込み時に呼ぶ）
  void clearRoleCache() {
    _cachedRole = null;
    _profileUserIdLoaded = false;
    _profileUserId = null;
  }

  void listen(void Function() fn) => _listener = fn;

  void dispose() {
    _sub?.cancel();
    _listener = null;
  }
}

/// 学習タブ内の画面で「教材管理」や四択の編集ショートカットを出すか。
///
/// - **教師**（`profiles.role == teacher`）でログインしている
/// - または学習者で [kLearnerShortIdWithManageShortcut] のショート ID
Future<bool> shouldShowLearnerFlowManageShortcut() async {
  final role = await appAuthNotifier.fetchRole();
  if (role == 'teacher') return true;
  final uid = await appAuthNotifier.fetchProfileUserId();
  return learnerProfileUserIdShowsManageShortcut(uid);
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
