/// 教師の「新規登録」可否（アプリからの self-signup 用）。
///
/// 本番などで制限したい場合はビルド時に
/// `--dart-define=TEACHER_SIGNUP_ALLOWED_DOMAINS=example.com,another.org`
/// を渡す。未設定または空のときは制限なし（ローカル開発向け）。
library;

/// 許可リスト外で教師新規登録しようとしたとき。
class TeacherSignupBlocked implements Exception {
  TeacherSignupBlocked(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract final class TeacherSignupGate {
  static const String _rawDomains = String.fromEnvironment(
    'TEACHER_SIGNUP_ALLOWED_DOMAINS',
    defaultValue: '',
  );

  /// ドメイン制限が有効か（空でない define が渡されている）。
  static bool get isRestricted {
    return _parsedDomains.isNotEmpty;
  }

  /// 設定されている許可ドメイン（表示用・小文字・空要素なし）。
  static List<String> get allowedDomains =>
      List.unmodifiable(_parsedDomains);

  static List<String> get _parsedDomains {
    return _rawDomains
        .split(',')
        .map((s) => s.trim().toLowerCase())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  /// メールが教師の新規登録に使えるか。制限なしなら常に true。
  static bool isEmailAllowed(String email) {
    return rejectionMessageIfAny(email) == null;
  }

  /// 不可のときユーザー向け短文、可なら null。
  static String? rejectionMessageIfAny(String email) {
    if (!isRestricted) return null;
    final t = email.trim().toLowerCase();
    final at = t.lastIndexOf('@');
    if (at <= 0 || at == t.length - 1) {
      return '有効なメールアドレスを入力してください。';
    }
    final domain = t.substring(at + 1);
    final ok = _parsedDomains.any(
      (d) => domain == d || domain.endsWith('.$d'),
    );
    if (ok) return null;
    final listed = _parsedDomains.join(', @');
    return '新規の教師登録は次のメールドメインのみです: @${listed.isEmpty ? '(未設定)' : listed}';
  }
}
