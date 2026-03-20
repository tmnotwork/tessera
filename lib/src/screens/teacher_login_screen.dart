import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app_scope.dart';
import '../teacher_signup_gate.dart';

class TeacherLoginScreen extends StatefulWidget {
  const TeacherLoginScreen({super.key});

  @override
  State<TeacherLoginScreen> createState() => _TeacherLoginScreenState();
}

class _TeacherLoginScreenState extends State<TeacherLoginScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _loading = false;
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    // タブ切り替え時にフォームをリセット
    _tabController.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  static const int _minPasswordLength = 8;

  bool _isValidEmail(String email) {
    final t = email.trim();
    if (t.isEmpty) return false;
    final i = t.indexOf('@');
    return i > 0 && i < t.length - 1;
  }

  bool _isEmailNotConfirmed(Object e) {
    final msg = e.toString().toLowerCase();
    return msg.contains('email_not_confirmed') || msg.contains('email not confirmed');
  }

  String _loginErrorMessage(Object e) {
    final msg = e.toString().toLowerCase();
    if (_isEmailNotConfirmed(e)) {
      return 'メールアドレスがまだ確認されていません。\n'
          '登録時に送信されたメールのリンクから確認を完了してください。\n'
          '届かない場合は「確認メールを再送」を押してください。';
    }
    if (msg.contains('invalid_login_credentials') || msg.contains('invalid')) {
      return 'メールアドレスまたはパスワードが正しくありません。';
    }
    return 'ログインに失敗しました。接続を確認するか、しばらく経ってからお試しください。';
  }

  Future<void> _showForgotPasswordDialog() async {
    final email = _emailController.text.trim();
    final controller = TextEditingController(text: email);
    if (!mounted) return;
    final submitted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('パスワードを忘れた'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '登録したメールアドレスを入力してください。パスワードリセット用のリンクを送信します。',
              style: TextStyle(height: 1.4),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'メールアドレス',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.emailAddress,
              autofocus: email.isEmpty,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('送信'),
          ),
        ],
      ),
    );
    final targetEmail = controller.text.trim();
    controller.dispose();
    if (submitted != true || !mounted) return;
    if (targetEmail.isEmpty) {
      return;
    }

    setState(() => _loading = true);
    try {
      await appAuthNotifier.resetPasswordForEmail(targetEmail);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'パスワードリセット用のメールを送信しました。メールのリンクから新しいパスワードを設定してください。',
            ),
            duration: Duration(seconds: 6),
          ),
        );
      }
    } on AuthException catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('送信に失敗しました。メールアドレスを確認してください。'),
            duration: Duration(seconds: 4),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('送信に失敗しました。接続を確認するか、しばらく経ってからお試しください。'),
            duration: Duration(seconds: 4),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _resendConfirmation() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) return;

    setState(() => _loading = true);
    try {
      await appAuthNotifier.resendConfirmationEmail(email);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('確認メールを再送しました。届くまで少々お待ちください。迷惑メールもご確認ください。'),
            duration: Duration(seconds: 5),
          ),
        );
      }
    } on AuthException catch (e) {
      if (mounted) {
        final msg = e.message.toLowerCase();
        final alreadyConfirmed = msg.contains('already') ||
            msg.contains('confirmed') ||
            msg.contains('verified');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              alreadyConfirmed
                  ? 'このメールはすでに確認済みです。ログインをお試しください。'
                  : '再送に失敗しました。メールアドレスを確認するか、しばらく経ってからお試しください。',
            ),
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('再送に失敗しました。接続を確認するか、しばらく経ってからお試しください。'),
            duration: Duration(seconds: 5),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _login() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (email.isEmpty || password.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('メールアドレスとパスワードを入力してください。')),
        );
      }
      return;
    }
    if (!_isValidEmail(email)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('有効なメールアドレスを入力してください。')),
        );
      }
      return;
    }

    setState(() => _loading = true);
    try {
      await appAuthNotifier.loginTeacher(email, password);
    } catch (e) {
      if (mounted) {
        final isUnconfirmed = _isEmailNotConfirmed(e);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_loginErrorMessage(e)),
            duration: const Duration(seconds: 6),
            action: SnackBarAction(
              label: isUnconfirmed ? '確認メールを再送' : 'OK',
              onPressed: () {
                if (isUnconfirmed) _resendConfirmation();
              },
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _signUp() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (email.isEmpty || password.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('メールアドレスとパスワードを入力してください。')),
        );
      }
      return;
    }
    if (!_isValidEmail(email)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('有効なメールアドレスを入力してください。')),
        );
      }
      return;
    }
    if (password.length < _minPasswordLength) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('パスワードは$_minPasswordLength文字以上で入力してください。'),
            duration: const Duration(seconds: 4),
          ),
        );
      }
      return;
    }

    setState(() => _loading = true);
    try {
      final response = await appAuthNotifier.signUpTeacher(email, password);
      if (!mounted) return;
      final identities = response.user?.identities;
      final alreadyRegistered = identities == null || identities.isEmpty;
      if (alreadyRegistered) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'このメールアドレスはすでに登録されています。\nログインタブからログインしてください。',
            ),
            duration: Duration(seconds: 5),
          ),
        );
        _tabController.animateTo(0);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              '登録しました。確認メールを送信しました。\n'
              'メールのリンクをクリックして確認を完了してから、ログインしてください。',
            ),
            duration: Duration(seconds: 8),
          ),
        );
        _tabController.animateTo(0);
      }
    } on TeacherSignupBlocked catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.message),
            duration: const Duration(seconds: 6),
          ),
        );
      }
    } on AuthException catch (e) {
      if (mounted) {
        final msg = e.message.toLowerCase();
        final alreadyExists = msg.contains('already') ||
            msg.contains('registered') ||
            msg.contains('exists') ||
            msg.contains('重複');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              alreadyExists
                  ? 'このメールアドレスはすでに登録されています。ログインタブからログインしてください。'
                  : '登録に失敗しました: ${e.message}',
            ),
            duration: const Duration(seconds: 5),
          ),
        );
        if (alreadyExists) _tabController.animateTo(0);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('登録に失敗しました。接続を確認するか、しばらく経ってからお試しください。'),
            duration: Duration(seconds: 5),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Widget _buildForm(bool isLogin) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              if (!isLogin && TeacherSignupGate.isRestricted) ...[
                Text(
                  '新規の教師アカウントは次のメールドメインのみ登録できます: '
                  '${TeacherSignupGate.allowedDomains.map((d) => '@$d').join(', ')}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        height: 1.35,
                      ),
                ),
                const SizedBox(height: 16),
              ],
              TextField(
                controller: _emailController,
                decoration: const InputDecoration(
                  labelText: 'メールアドレス',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.email_outlined),
                ),
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.email],
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _passwordController,
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: 'パスワード',
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) {
                  if (!_loading) (isLogin ? _login : _signUp)();
                },
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _loading ? null : (isLogin ? _login : _signUp),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: _loading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : Text(isLogin ? 'ログイン' : '新規登録'),
              ),
              if (isLogin) ...[
                const SizedBox(height: 12),
                TextButton(
                  onPressed: _loading ? null : _showForgotPasswordDialog,
                  child: const Text('パスワードを忘れた'),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: _loading ? null : _resendConfirmation,
                  icon: const Icon(Icons.email_outlined, size: 18),
                  label: const Text('メールが届いていませんか？ 確認メールを再送'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('教材管理'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'ログイン'),
            Tab(text: '新規登録'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildForm(true),
          _buildForm(false),
        ],
      ),
    );
  }
}
