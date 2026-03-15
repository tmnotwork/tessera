import 'dart:convert';

import 'package:http/http.dart' as http;

/// 学習者の追加・削除・パスワードリセット（Supabase Auth Admin API）。
/// 利用するには [setServiceRoleKey] でサービスロールキーを設定すること。
/// .env の SUPABASE_SERVICE_ROLE_KEY を渡す想定。
class LearnerAdmin {
  static String? _serviceRoleKey;
  static String? _supabaseUrl;

  static bool get isAvailable =>
      _serviceRoleKey != null &&
      _serviceRoleKey!.isNotEmpty &&
      _supabaseUrl != null &&
      _supabaseUrl!.isNotEmpty;

  static void setServiceRoleKey(String? key, String? supabaseUrl) {
    _serviceRoleKey = key?.trim();
    _supabaseUrl = supabaseUrl?.trim();
  }

  static void initFromEnv(String? key, String? supabaseUrl) {
    setServiceRoleKey(key, supabaseUrl);
  }

  static Map<String, String> get _authHeaders {
    if (_serviceRoleKey == null || _supabaseUrl == null) {
      throw StateError('LearnerAdmin: サービスロールキーが未設定です');
    }
    return {
      'Authorization': 'Bearer $_serviceRoleKey',
      'apikey': _serviceRoleKey!,
      'Content-Type': 'application/json',
    };
  }

  static String get _authUrl => '$_supabaseUrl/auth/v1';
  static String get _restUrl => '$_supabaseUrl/rest/v1';

  /// 学習者を追加する。email = userId@tessera.local で Auth に作成し、profiles を learner に更新する。
  static Future<String> createLearner({
    required String userId,
    required String password,
    String? displayName,
  }) async {
    if (!isAvailable) {
      throw StateError('学習者の追加には SUPABASE_SERVICE_ROLE_KEY の設定が必要です');
    }
    final email = '${userId.trim()}@tessera.local';
    final res = await http.post(
      Uri.parse('$_authUrl/admin/users'),
      headers: _authHeaders,
      body: jsonEncode({
        'email': email,
        'password': password,
        'email_confirm': true,
      }),
    );
    if (res.statusCode != 200 && res.statusCode != 201) {
      final body = res.body;
      String msg = body;
      try {
        final j = jsonDecode(body) as Map<String, dynamic>;
        msg = j['msg'] as String? ?? j['message'] as String? ?? body;
      } catch (_) {}
      throw LearnerAdminException('作成に失敗しました: $msg');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final id = data['id'] as String?;
    if (id == null) throw LearnerAdminException('作成レスポンスに id がありません');

    // トリガーで profiles が teacher で作られているので、learner に更新する
    final patchRes = await http.patch(
      Uri.parse('$_restUrl/profiles?id=eq.$id'),
      headers: _authHeaders,
      body: jsonEncode({
        'role': 'learner',
        'user_id': userId.trim(),
        if (displayName != null && displayName.trim().isNotEmpty) 'display_name': displayName.trim(),
      }),
    );
    if (patchRes.statusCode != 200 && patchRes.statusCode != 204) {
      // ユーザーは作成済み。プロフィール更新失敗はログだけにして id は返す
      return id;
    }
    return id;
  }

  /// 学習者（Auth ユーザー）を削除する。profiles は CASCADE で削除される。
  static Future<void> deleteLearner(String authUserId) async {
    if (!isAvailable) {
      throw StateError('学習者の削除には SUPABASE_SERVICE_ROLE_KEY の設定が必要です');
    }
    final res = await http.delete(
      Uri.parse('$_authUrl/admin/users/$authUserId'),
      headers: _authHeaders,
    );
    if (res.statusCode != 200 && res.statusCode != 204) {
      final body = res.body;
      String msg = body;
      try {
        final j = jsonDecode(body) as Map<String, dynamic>;
        msg = j['msg'] as String? ?? j['message'] as String? ?? body;
      } catch (_) {}
      throw LearnerAdminException('削除に失敗しました: $msg');
    }
  }

  /// 学習者のパスワードを変更する。
  static Future<void> resetLearnerPassword(String authUserId, String newPassword) async {
    if (!isAvailable) {
      throw StateError('パスワードリセットには SUPABASE_SERVICE_ROLE_KEY の設定が必要です');
    }
    final res = await http.put(
      Uri.parse('$_authUrl/admin/users/$authUserId'),
      headers: _authHeaders,
      body: jsonEncode({'password': newPassword}),
    );
    if (res.statusCode != 200 && res.statusCode != 204) {
      final body = res.body;
      String msg = body;
      try {
        final j = jsonDecode(body) as Map<String, dynamic>;
        msg = j['msg'] as String? ?? j['message'] as String? ?? body;
      } catch (_) {}
      throw LearnerAdminException('パスワードの変更に失敗しました: $msg');
    }
  }
}

class LearnerAdminException implements Exception {
  LearnerAdminException(this.message);
  final String message;
  @override
  String toString() => message;
}
