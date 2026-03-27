// ignore_for_file: use_build_context_synchronously

import 'dart:async';

import 'package:flutter/material.dart';
import '../services/auth_service.dart';

/// ログイン画面用: ミニマル・白ベース・黒強調色のテーマ
ThemeData _authScreenTheme() {
  const black = Color(0xFF000000);
  const white = Color(0xFFFFFFFF);
  const surface = Color(0xFFFFFFFF);
  const onSurface = Color(0xFF212121);
  const outline = Color(0xFFE0E0E0);

  final scheme = ColorScheme.light(
    primary: black,
    onPrimary: white,
    surface: surface,
    onSurface: onSurface,
    surfaceContainerHighest: const Color(0xFFF5F5F5),
    outline: outline,
    error: const Color(0xFFB00020),
    onError: white,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: white,
    appBarTheme: AppBarTheme(
      backgroundColor: white,
      foregroundColor: black,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: const TextStyle(
        color: black,
        fontSize: 20,
        fontWeight: FontWeight.w600,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: black,
        foregroundColor: white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: black),
    ),
    inputDecorationTheme: InputDecorationTheme(
      fillColor: white,
      filled: true,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: black, width: 2),
      ),
    ),
  );
}

class AuthScreen extends StatefulWidget {
  /// Web 未ログイン時: ログイン・登録押下時にのみ実行。Firebase + Auth の最小初期化。
  final Future<void> Function()? ensureAuthReady;
  /// Web 未ログイン時: ログイン・登録成功後に実行。Hive 初期化と本編への切り替え。
  final Future<void> Function()? onLoginSuccess;

  const AuthScreen({
    super.key,
    this.ensureAuthReady,
    this.onLoginSuccess,
  });

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  // FocusNode for proper tab navigation
  final _emailFocusNode = FocusNode();
  final _passwordFocusNode = FocusNode();
  final _confirmPasswordFocusNode = FocusNode();

  bool _isLogin = true;
  bool _isLoading = false;
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;

  @override
  void initState() {
    super.initState();
    // ログイン・登録押下前に Firebase+Auth 初期化を先行開始し、押下時の待ち時間を短縮する
    if (widget.ensureAuthReady != null) {
      unawaited(widget.ensureAuthReady!());
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _emailFocusNode.dispose();
    _passwordFocusNode.dispose();
    _confirmPasswordFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: _authScreenTheme(),
      child: Builder(
        builder: (context) {
          final scheme = Theme.of(context).colorScheme;
          return Scaffold(
            backgroundColor: scheme.surface,
            appBar: AppBar(
              title: const Text(''),
            ),
            body: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16.0),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                // padding(16 * 2) を考慮して、スクロール時でも中央寄せが効くようにする
                minHeight: (constraints.maxHeight - 32).clamp(0, double.infinity),
              ),
              child: Center(
                child: ConstrainedBox(
                  // Web/デスクトップで入力欄が横に伸びすぎないよう最大幅を制限
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        // アプリロゴ・タイトル（黒強調）
                        Icon(Icons.task_alt, size: 80, color: scheme.primary),
                        const SizedBox(height: 16),
                        Text(
                          'Kant Routine',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: scheme.primary,
                          ),
                        ),
                        const SizedBox(height: 32),

                        // メールアドレス入力
                        TextFormField(
                          controller: _emailController,
                          focusNode: _emailFocusNode,
                          keyboardType: TextInputType.emailAddress,
                          onFieldSubmitted: (_) =>
                              _passwordFocusNode.requestFocus(),
                          decoration: const InputDecoration(
                            labelText: 'メールアドレス',
                            prefixIcon: Icon(Icons.email),
                            border: OutlineInputBorder(),
                          ),
                          validator: (value) {
                            if (value == null || value.isEmpty) {
                              return 'メールアドレスを入力してください';
                            }
                            if (!RegExp(
                              r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$',
                            ).hasMatch(value)) {
                              return '有効なメールアドレスを入力してください';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 16),

                        // パスワード入力
                        TextFormField(
                          controller: _passwordController,
                          focusNode: _passwordFocusNode,
                          obscureText: _obscurePassword,
                          onFieldSubmitted: (_) => _isLogin
                              ? _handleSubmit()
                              : _confirmPasswordFocusNode.requestFocus(),
                          decoration: InputDecoration(
                            labelText: 'パスワード',
                            prefixIcon: const Icon(Icons.lock),
                            suffixIcon: IconButton(
                              icon: Icon(
                                _obscurePassword
                                    ? Icons.visibility
                                    : Icons.visibility_off,
                              ),
                              onPressed: () {
                                setState(() {
                                  _obscurePassword = !_obscurePassword;
                                });
                              },
                              focusNode: FocusNode(skipTraversal: true),
                            ),
                            border: const OutlineInputBorder(),
                          ),
                          validator: (value) {
                            if (value == null || value.isEmpty) {
                              return 'パスワードを入力してください';
                            }
                            if (value.length < 6) {
                              return 'パスワードは6文字以上で入力してください';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 16),

                        // パスワード確認（登録時のみ表示）
                        if (!_isLogin) ...[
                          TextFormField(
                            controller: _confirmPasswordController,
                            focusNode: _confirmPasswordFocusNode,
                            obscureText: _obscureConfirmPassword,
                            onFieldSubmitted: (_) => _handleSubmit(),
                            decoration: InputDecoration(
                              labelText: 'パスワード確認',
                              prefixIcon: const Icon(Icons.lock),
                              suffixIcon: IconButton(
                                icon: Icon(
                                  _obscureConfirmPassword
                                      ? Icons.visibility
                                      : Icons.visibility_off,
                                ),
                                onPressed: () {
                                  setState(() {
                                    _obscureConfirmPassword =
                                        !_obscureConfirmPassword;
                                  });
                                },
                                focusNode: FocusNode(skipTraversal: true),
                              ),
                              border: const OutlineInputBorder(),
                            ),
                            validator: (value) {
                              if (value == null || value.isEmpty) {
                                return 'パスワード確認を入力してください';
                              }
                              if (value != _passwordController.text) {
                                return 'パスワードが一致しません';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 16),
                        ],

                        // ログイン・登録ボタン（テーマの黒ボタン）
                        SizedBox(
                          width: double.infinity,
                          height: 50,
                          child: ElevatedButton(
                            onPressed: _isLoading ? null : _handleSubmit,
                            child: _isLoading
                                ? CircularProgressIndicator(
                                    color: scheme.onPrimary,
                                  )
                                : Text(
                                    _isLogin ? 'ログイン' : 'ユーザー登録',
                                    style: const TextStyle(fontSize: 16),
                                  ),
                          ),
                        ),
                        const SizedBox(height: 16),

                        // モード切り替えボタン
                        TextButton(
                          onPressed: _isLoading
                              ? null
                              : () {
                                  setState(() {
                                    _isLogin = !_isLogin;
                                    _emailController.clear();
                                    _passwordController.clear();
                                    _confirmPasswordController.clear();
                                  });
                                },
                          child: Text(
                            _isLogin
                                ? 'アカウントをお持ちでない方はこちら'
                                : '既にアカウントをお持ちの方はこちら',
                          ),
                        ),

                        // パスワードリセット（ログイン時のみ表示）
                        if (_isLogin) ...[
                          const SizedBox(height: 16),
                          TextButton(
                            onPressed:
                                _isLoading ? null : _showPasswordResetDialog,
                            child: const Text('パスワードを忘れた方はこちら'),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
      },
    ),
    );
  }

  // フォーム送信処理
  Future<void> _handleSubmit() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      // Web 未ログイン時: ログイン・登録押下時にのみ Firebase+Auth を初期化
      if (widget.ensureAuthReady != null) {
        await widget.ensureAuthReady!();
        if (!mounted) return;
      }

      final email = _emailController.text.trim();
      final password = _passwordController.text;

      if (_isLogin) {
        // ログイン処理
        final user = await AuthService.signInWithEmailAndPassword(
          email,
          password,
        );

        if (user != null) {
          if (mounted && widget.onLoginSuccess != null) {
            await widget.onLoginSuccess!();
          }
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text(
                    'ログインに失敗しました。メールアドレスとパスワードを確認してください。'),
                backgroundColor: Theme.of(context).colorScheme.error,
              ),
            );
          }
        }
      } else {
        // 登録処理
        final user = await AuthService.signUpWithEmailAndPassword(
          email,
          password,
        );

        if (user != null) {
          if (mounted && widget.onLoginSuccess != null) {
            await widget.onLoginSuccess!();
          }
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('ユーザー登録が完了しました')),
            );
          }
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text(
                    'ユーザー登録に失敗しました。既に登録されているメールアドレスかもしれません。'),
                backgroundColor: Theme.of(context).colorScheme.error,
              ),
            );
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('エラーが発生しました: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  // パスワードリセットダイアログ
  void _showPasswordResetDialog() {
    final emailController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('パスワードリセット'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('メールアドレスを入力してください。パスワードリセット用のメールを送信します。'),
            const SizedBox(height: 16),
            TextField(
              controller: emailController,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: 'メールアドレス',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () async {
              final email = emailController.text.trim();
              if (email.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('メールアドレスを入力してください')),
                );
                return;
              }

              try {
                if (widget.ensureAuthReady != null) {
                  await widget.ensureAuthReady!();
                  if (!mounted) return;
                }
                await AuthService.sendPasswordResetEmail(email);
                if (mounted) {
                  Navigator.of(context).pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('パスワードリセット用のメールを送信しました')),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('エラーが発生しました: $e'),
                      backgroundColor: Theme.of(context).colorScheme.error,
                    ),
                  );
                }
              }
            },
            child: const Text('送信'),
          ),
        ],
      ),
    );
  }
}
