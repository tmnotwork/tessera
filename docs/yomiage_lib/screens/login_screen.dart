// ignore_for_file: library_private_types_in_public_api, use_build_context_synchronously, avoid_print, deprecated_member_use, library_prefixes, prefer_const_declarations

import 'package:flutter/material.dart';
import '../services/firebase_service.dart';
import '../services/sync_service.dart';
import 'home_screen.dart';
import '../models/deck.dart';
import '../services/hive_service.dart';
import 'package:hive/hive.dart';
import '../models/flashcard.dart';
import 'package:flutter/foundation.dart';
import 'package:yomiage/webapp/web_home_screen.dart' as web_home;
import '../themes/app_theme.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({Key? key}) : super(key: key);

  @override
  _LoginScreenState createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLogin = true;
  bool _isLoading = false;
  String _errorMessage = '';

  @override
  void initState() {
    super.initState();
    print('LoginScreen: initState 呼び出し');
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    print('LoginScreen: dispose 呼び出し');
    super.dispose();
  }

  Future<void> _submitForm() async {
    if (_formKey.currentState!.validate()) {
      setState(() {
        _isLoading = true;
        _errorMessage = '';
      });

      try {
        print('ログイン/登録処理開始: ${_isLogin ? "ログイン" : "新規登録"}');
        if (_isLogin) {
          // ログイン処理
          await FirebaseService.signInWithEmailAndPassword(
            _emailController.text.trim(),
            _passwordController.text.trim(),
          );

          // Hive Boxがopenされているか確認し、必要ならopenし直す
          if (!Hive.isBoxOpen('deckBox')) {
            await Hive.openBox<Deck>('deckBox');
          }
          if (!Hive.isBoxOpen('cardBox')) {
            await Hive.openBox<FlashCard>('cardBox');
          }

          // クラウドからデータを同期（ローカルデータは保持）
          // print('クラウドからデータを同期中...');
          // await SyncService.syncFromCloud(); // ★★★ ログイン時の自動同期(syncBidirectional)と重複するため削除 ★★★
        } else {
          // 新規登録処理
          await FirebaseService.registerWithEmailAndPassword(
            _emailController.text.trim(),
            _passwordController.text.trim(),
          );

          // Hive Boxがopenされているか確認し、必要ならopenし直す
          if (!Hive.isBoxOpen('deckBox')) {
            await Hive.openBox<Deck>('deckBox');
          }
          if (!Hive.isBoxOpen('cardBox')) {
            await Hive.openBox<FlashCard>('cardBox');
          }

          // 新規登録直後にローカルにデフォルトデッキがなければ作成
          final deckBox = HiveService.getDeckBox();
          if (!deckBox.values.any((deck) => deck.deckName == 'デフォルト')) {
            final defaultId = DateTime.now().millisecondsSinceEpoch.toString();
            final newDeck = Deck(id: defaultId, deckName: 'デフォルト');
            await deckBox.put(defaultId, newDeck);
            print('新規登録時: デフォルトデッキを作成しました');
          }

          // ローカルデータをクラウドに同期
          print('ローカルデータをクラウドに同期中...');
          await SyncService.syncToCloud();
        }

        print('認証処理成功: ホーム画面へ遷移');
        // ホーム画面に遷移
        if (mounted) {
          // ★★★ プラットフォームに応じて遷移先を切り替え ★★★
          final homeScreen = kIsWeb
              ? const web_home.WebHomeScreen() // Web用ホーム画面
              : const HomeScreen(); // モバイル用ホーム画面

          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (context) => homeScreen),
          );
        }
      } catch (e) {
        print('認証エラー: $e');
        if (mounted) {
          setState(() {
            _errorMessage = _getLocalizedErrorMessage(e.toString());
          });
        }
      } finally {
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    print('LoginScreen: build 呼び出し');
    return Scaffold(
      backgroundColor: CustomColors.getBackgroundColor(Theme.of(context)),
      appBar: AppBar(
        backgroundColor: CustomColors.getBackgroundColor(Theme.of(context)),
        foregroundColor: CustomColors.getTextColor(Theme.of(context)),
        title: Text(_isLogin ? 'ログイン' : '新規登録'),
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(height: 20),
                Text(
                  'yomiage',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: CustomColors.getTextColor(Theme.of(context)),
                  ),
                ),
                const SizedBox(height: 40),
                TextFormField(
                  controller: _emailController,
                  style: TextStyle(
                      color: CustomColors.getTextColor(Theme.of(context))),
                  decoration: InputDecoration(
                    labelText: 'メールアドレス',
                    labelStyle: TextStyle(
                        color: CustomColors.getSecondaryTextColor(
                            Theme.of(context))),
                    border: const OutlineInputBorder(),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(
                          color: CustomColors.getSecondaryTextColor(
                              Theme.of(context))),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderSide: BorderSide(
                          color: CustomColors.getTextColor(Theme.of(context))),
                    ),
                    prefixIcon: Icon(Icons.email,
                        color: CustomColors.getSecondaryTextColor(
                            Theme.of(context))),
                  ),
                  keyboardType: TextInputType.emailAddress,
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'メールアドレスを入力してください';
                    }
                    if (!value.contains('@')) {
                      return '有効なメールアドレスを入力してください';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _passwordController,
                  style: TextStyle(
                      color: CustomColors.getTextColor(Theme.of(context))),
                  decoration: InputDecoration(
                    labelText: 'パスワード',
                    labelStyle: TextStyle(
                        color: CustomColors.getSecondaryTextColor(
                            Theme.of(context))),
                    border: const OutlineInputBorder(),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(
                          color: CustomColors.getSecondaryTextColor(
                              Theme.of(context))),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderSide: BorderSide(
                          color: CustomColors.getTextColor(Theme.of(context))),
                    ),
                    prefixIcon: Icon(Icons.lock,
                        color: CustomColors.getSecondaryTextColor(
                            Theme.of(context))),
                  ),
                  obscureText: true,
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'パスワードを入力してください';
                    }
                    if (value.length < 6) {
                      return 'パスワードは6文字以上にしてください';
                    }
                    return null;
                  },
                  onFieldSubmitted: (_) => _submitForm(),
                ),
                const SizedBox(height: 24),
                if (_errorMessage.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.all(8.0),
                    margin: const EdgeInsets.only(bottom: 16.0),
                    decoration: BoxDecoration(
                      color: CustomColors.error.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    width: double.infinity,
                    child: Text(
                      _errorMessage,
                      style: const TextStyle(color: CustomColors.error),
                      textAlign: TextAlign.center,
                    ),
                  ),
                _isLoading
                    ? const Column(
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 16),
                          Text(
                            '初回ログイン時は少し時間がかかることがあります',
                            style: TextStyle(color: Colors.grey),
                          ),
                        ],
                      )
                    : ElevatedButton(
                        onPressed: _submitForm,
                        style: ElevatedButton.styleFrom(
                          minimumSize: const Size.fromHeight(50),
                          backgroundColor: Colors.blue,
                          foregroundColor: Colors.white,
                        ),
                        child: Text(
                          _isLogin ? 'ログイン' : '登録',
                          style: const TextStyle(fontSize: 16),
                        ),
                      ),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () {
                    setState(() {
                      _isLogin = !_isLogin;
                      _errorMessage = '';
                    });
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white70,
                  ),
                  child: Text(
                    _isLogin ? '新規登録はこちら' : 'ログインはこちら',
                  ),
                ),
                if (_isLogin) ...[
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () {
                      _showPasswordResetDialog();
                    },
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white70,
                    ),
                    child: const Text('パスワードをお忘れですか？'),
                  ),
                ],
                // ★★★ オフラインモードで続けるボタンを削除 ★★★
                /*
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () {
                    print('オフラインモードで続行します');
                    // ★★★ ここもプラットフォーム分岐が必要だった箇所 ★★★
                    final homeScreen = kIsWeb
                        ? const WebHome.WebHomeScreen()
                        : const HomeScreen();
                    Navigator.of(context).pushReplacement(
                      MaterialPageRoute(builder: (context) => homeScreen),
                    );
                  },
                  child: const Text('オフラインモードで続ける'),
                ),
                */
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _getLocalizedErrorMessage(String errorMessage) {
    if (errorMessage.contains('user-not-found')) {
      return 'ユーザーが見つかりません。メールアドレスを確認してください。';
    } else if (errorMessage.contains('wrong-password')) {
      return 'パスワードが間違っています。';
    } else if (errorMessage.contains('email-already-in-use')) {
      return 'このメールアドレスは既に使用されています。';
    } else if (errorMessage.contains('invalid-email')) {
      return '無効なメールアドレス形式です。';
    } else if (errorMessage.contains('weak-password')) {
      return 'パスワードが弱すぎます。より強力なパスワードを設定してください。';
    } else if (errorMessage.contains('network-request-failed')) {
      return 'ネットワークエラーが発生しました。インターネット接続を確認してください。';
    } else if (errorMessage.contains('too-many-requests')) {
      return 'アクセスが集中しています。しばらく時間をおいてから再試行してください。';
    } else if (errorMessage.contains('credential')) {
      return '認証情報が間違っているか、期限切れです。再度ログインしてください。';
    } else {
      return '認証エラー: $errorMessage';
    }
  }

  // パスワードリセットダイアログを表示
  void _showPasswordResetDialog() {
    final resetEmailController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('パスワードリセット', style: TextStyle(color: Colors.white)),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '登録したメールアドレスを入力してください。パスワードリセットのリンクを送信します。',
                style: TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: resetEmailController,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'メールアドレス',
                  labelStyle: TextStyle(color: Colors.white70),
                  border: OutlineInputBorder(),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white70),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white),
                  ),
                ),
                keyboardType: TextInputType.emailAddress,
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'メールアドレスを入力してください';
                  }
                  if (!value.contains('@')) {
                    return '有効なメールアドレスを入力してください';
                  }
                  return null;
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            style: TextButton.styleFrom(
              foregroundColor: Colors.white70,
            ),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () async {
              if (formKey.currentState!.validate()) {
                try {
                  await FirebaseService.sendPasswordResetEmail(
                    resetEmailController.text.trim(),
                  );
                  Navigator.of(context).pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('パスワードリセットのメールを送信しました。メールをご確認ください。'),
                      backgroundColor: Colors.green,
                    ),
                  );
                } catch (e) {
                  Navigator.of(context).pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(_getLocalizedErrorMessage(e.toString())),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              }
            },
            style: TextButton.styleFrom(
              foregroundColor: Colors.white70,
            ),
            child: const Text('送信'),
          ),
        ],
      ),
    );
  }
}
