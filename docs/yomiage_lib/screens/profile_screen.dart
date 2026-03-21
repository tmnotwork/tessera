// ignore_for_file: library_private_types_in_public_api, use_build_context_synchronously, prefer_final_fields, unused_field, unreachable_switch_default, prefer_const_constructors, avoid_print, unused_local_variable, curly_braces_in_flow_control_structures, prefer_adjacent_string_concatenation, body_might_complete_normally_nullable

import 'package:flutter/material.dart';
import '../services/firebase_service.dart';
import '../services/sync_service.dart';
import '../services/sync/notification_service.dart';
import '../services/hive_service.dart';
import '../services/card_service.dart';
import '../services/theme_service.dart';
import '../providers/theme_provider.dart';
import 'login_screen.dart';
import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
// min を使うために追加
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:cloud_functions/cloud_functions.dart';
import 'dart:convert' show jsonEncode;

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({Key? key}) : super(key: key);

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  StreamSubscription? _syncStatusSubscription;
  SyncStatus _syncStatus = SyncStatus.idle;
  bool _isUserLoggedIn = FirebaseService.getUserId() != null;
  String? _handleName;
  bool _isLoading = true;
  bool _isEditingHandleName = false;
  final TextEditingController _handleNameController = TextEditingController();
  bool _isCheckingDiscrepancy = false; // 差異チェック中フラグ
  bool _isBackfilling = false;

  @override
  void initState() {
    super.initState();

    // 同期状態の変更を監視
    final syncService = SyncService();
    _syncStatusSubscription = syncService.syncStatusStream.listen((status) {
      if (mounted) {
        setState(() {
          _syncStatus = status;
        });
      }
    });

    _loadUserData();
  }

  @override
  void dispose() {
    _syncStatusSubscription?.cancel();
    _handleNameController.dispose();
    super.dispose();
  }

  Future<void> _loadUserData() async {
    setState(() => _isLoading = true);
    if (FirebaseService.getCurrentUser() != null) {
      _handleName = await FirebaseService.getHandleName();
      _handleNameController.text =
          (_handleName?.isEmpty ?? true) ? '' : _handleName!;
    } else {
      _handleName = null;
      _handleNameController.text = '';
    }
    if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _saveHandleName() async {
    final newName = _handleNameController.text.trim();
    if (newName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('ハンドルネームを入力してください'), backgroundColor: Colors.orange));
      return;
    }
    if (newName == _handleName) {
      setState(() => _isEditingHandleName = false);
      return;
    }

    setState(() => _isLoading = true);
    try {
      await FirebaseService.updateHandleName(newName);
      setState(() {
        _handleName = newName;
        _isEditingHandleName = false;
        _isLoading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('ハンドルネームを更新しました'), backgroundColor: Colors.green));
    } catch (e) {
      print('ハンドルネーム更新エラー: $e');
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('更新に失敗しました: $e'), backgroundColor: Colors.red));
      }
    }
  }

  // 同期状態を示すウィジェット

  @override
  Widget build(BuildContext context) {
    final user = FirebaseService.getCurrentUser();
    final isLoggedIn = user != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('アカウント設定'),
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: Theme.of(context).colorScheme.primary))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'アカウント情報',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 16),
                          if (isLoggedIn) ...[
                            ListTile(
                              leading: const Icon(Icons.person_outline),
                              title: const Text('ハンドルネーム'),
                              subtitle: !_isEditingHandleName
                                  ? Text((_handleName?.isEmpty ?? true)
                                      ? '未設定'
                                      : _handleName!)
                                  : TextField(
                                      controller: _handleNameController,
                                      style: const TextStyle(fontSize: 14),
                                      decoration: InputDecoration(
                                        hintText: 'ハンドルネームを入力',
                                        isDense: true,
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                                vertical: 8),
                                      ),
                                      autofocus: true,
                                      onSubmitted: (_) => _saveHandleName(),
                                    ),
                              trailing: !_isEditingHandleName
                                  ? IconButton(
                                      icon: const Icon(Icons.edit, size: 20),
                                      tooltip: '編集',
                                      onPressed: () {
                                        setState(() {
                                          _isEditingHandleName = true;
                                        });
                                      },
                                    )
                                  : Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                          icon: const Icon(Icons.cancel,
                                              color: Colors.grey, size: 20),
                                          tooltip: 'キャンセル',
                                          onPressed: () {
                                            setState(() {
                                              _handleNameController.text =
                                                  (_handleName?.isEmpty ?? true)
                                                      ? ''
                                                      : _handleName!;
                                              _isEditingHandleName = false;
                                            });
                                          },
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.save,
                                              color: Colors.green, size: 20),
                                          tooltip: '保存',
                                          onPressed: _saveHandleName,
                                        ),
                                      ],
                                    ),
                            ),
                            ListTile(
                              leading: const Icon(Icons.email),
                              title: const Text('メールアドレス'),
                              subtitle: Text(user.email ?? ''),
                            ),
                          ] else ...[
                            const Text('ログインしていません'),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  // テーマ設定セクション
                  _buildThemeSettingsSection(),
                  const SizedBox(height: 16),
                  if (isLoggedIn) ...[
                    _buildDataManagementSection(context),
                    const SizedBox(height: 16),
                  ],
                  if (isLoggedIn) ...[
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'アカウント管理',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 16),
                            ListTile(
                              leading:
                                  const Icon(Icons.logout, color: Colors.red),
                              title: const Text('ログアウト'),
                              onTap: _logout,
                            ),
                            ListTile(
                              leading: const Icon(Icons.delete_forever,
                                  color: Colors.red),
                              title: const Text('アカウント削除'),
                              onTap: _deleteAccount,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                ],
              ),
            ),
    );
  }

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('ログアウト'),
        content: const Text('本当にログアウトしますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('ログアウト'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await FirebaseService.signOut();
        await HiveService.clearAllData(); // ローカルデータ全クリア
        // ログイン画面に遷移
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (context) => const LoginScreen()),
          (Route<dynamic> route) => false,
        );
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('ログアウトエラー: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _deleteAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('アカウント削除の確認'),
        content: const Text(
          '本当にアカウントを削除しますか？\nこの操作は取り消せません。\nすべてのデータがサーバーとローカルから削除されます。',
          style: TextStyle(color: Colors.redAccent),
        ),
        actions: [
          TextButton(
            child: const Text('キャンセル'),
            onPressed: () => Navigator.pop(context, false),
          ),
          TextButton(
            child: const Text('削除する', style: TextStyle(color: Colors.red)),
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      print(
          "_deleteAccount: 最初の確認ダイアログでキャンセルまたは予期せぬ値。confirmed: $confirmed"); // デバッグログ追加
      return;
    }

    print("_deleteAccount: 最初の確認ダイアログ通過。パスワード入力に進みます。"); // デバッグログ追加

    // パスワード再認証
    final password = await _showPasswordDialog();
    if (password == null) {
      print("_deleteAccount: パスワード入力がキャンセルされました。"); // デバッグログ追加
      return;
    }

    // ローディングインジケータを表示
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    try {
      print('アカウント削除処理開始');
      final userId = FirebaseService.getUserId(); // 最初にuserIdを取得

      // 1. Firebase Authの再認証
      await FirebaseService.reauthenticate(password);
      print('Firebase Auth 再認証成功');

      // 2. Firestore上のユーザーデータをすべて削除 (FirebaseServiceに実装が必要)
      if (userId != null) {
        await FirebaseService.deleteAllUserFirestoreData(userId);
        print('Firestore上のユーザー関連データ削除処理を呼び出しました。');
      } else {
        print('ユーザーIDが取得できなかったため、Firestoreデータ削除をスキップしました。');
      }

      // 3. Firebase Authからユーザーを削除
      await FirebaseService.deleteAccount();
      print('Firebase Authからユーザーを削除成功');

      // 4. ローカルデータをすべてクリア
      await HiveService.clearAllData();
      print('ローカルデータ全クリア成功');

      Navigator.pop(context); // ローディングインジケータを閉じる

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('アカウントを完全に削除しました。'), backgroundColor: Colors.green),
      );
      // ログイン画面に遷移
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (context) => const LoginScreen()),
        (Route<dynamic> route) => false,
      );
    } catch (e) {
      Navigator.pop(context); // ローディングインジケータを閉じる
      print('アカウント削除中にエラー: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('アカウント削除中にエラーが発生しました: $e'),
            backgroundColor: Colors.red),
      );
    }
  }

  Future<String?> _showPasswordDialog() async {
    final TextEditingController passwordController = TextEditingController();
    bool obscureText = true;

    print("[DEBUG] _showPasswordDialog: メソッド開始"); // ★デバッグログ

    final String? password = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        print("[DEBUG] _showPasswordDialog: showDialog builder開始"); // ★デバッグログ
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('パスワード再入力'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('アカウントを削除するには、セキュリティのためパスワードを再入力してください。'),
                  const SizedBox(height: 16),
                  TextField(
                    controller: passwordController,
                    obscureText: obscureText,
                    decoration: InputDecoration(
                      labelText: 'パスワード',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(
                          obscureText ? Icons.visibility_off : Icons.visibility,
                        ),
                        onPressed: () {
                          setState(() {
                            obscureText = !obscureText;
                          });
                        },
                      ),
                    ),
                  ),
                ],
              ),
              actions: <Widget>[
                TextButton(
                  child: const Text('キャンセル'),
                  onPressed: () {
                    print(
                        "[DEBUG] _showPasswordDialog: キャンセルボタンクリック"); // ★デバッグログ
                    Navigator.of(context).pop();
                  },
                ),
                TextButton(
                  child: const Text('OK'),
                  onPressed: () {
                    final enteredPassword = passwordController.text;
                    print(
                        "[DEBUG] _showPasswordDialog: OKボタンクリック, password: $enteredPassword"); // ★デバッグログ
                    if (enteredPassword.isNotEmpty) {
                      Navigator.of(context).pop(enteredPassword);
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text('パスワードを入力してください。'),
                            backgroundColor: Colors.red),
                      );
                    }
                  },
                ),
              ],
            );
          },
        );
      },
    );
    print(
        "[DEBUG] _showPasswordDialog: showDialogから返された値: $password"); // ★デバッグログ
    return password;
  }

  /// テーマ設定セクションを構築
  Widget _buildThemeSettingsSection() {
    final currentThemeMode = ref.watch(currentThemeModeProvider);
    
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '表示設定',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'テーマモード',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            // テーマモード選択のラジオボタン
            ...ThemeService.availableThemeModes.map((mode) {
              return RadioListTile<AppThemeMode>(
                title: Text(ThemeService.getThemeModeDisplayName(mode)),
                subtitle: _getThemeModeDescription(mode),
                value: mode,
                groupValue: currentThemeMode,
                onChanged: (AppThemeMode? value) async {
                  if (value != null) {
                    await ref.read(themeProvider.notifier).setThemeMode(value);
                  }
                },
                contentPadding: EdgeInsets.zero,
              );
            }).toList(),
          ],
        ),
      ),
    );
  }

  /// テーマモードの説明文を取得
  Widget? _getThemeModeDescription(AppThemeMode mode) {
    switch (mode) {
      case AppThemeMode.light:
        return const Text('常にライトモードで表示します', style: TextStyle(fontSize: 12));
      case AppThemeMode.dark:
        return const Text('常にダークモードで表示します', style: TextStyle(fontSize: 12));
      case AppThemeMode.system:
        return const Text('端末のシステム設定に従います', style: TextStyle(fontSize: 12));
    }
  }

  Widget _buildDataManagementSection(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: const Text(
                'データ整理',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.sync_problem),
              title: const Text('データの同期と差異チェック'),
              subtitle: const Text(
                'ローカルとクラウドのデータの差異を確認・解決します。',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              trailing: _isCheckingDiscrepancy
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.chevron_right),
              onTap: _isCheckingDiscrepancy ? null : _resolveDiscrepancies,
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.cleaning_services_outlined),
              title: const Text('重複データを統一する'),
              subtitle: const Text(
                '重複カードと同名デッキをまとめて整理します。',
                style: TextStyle(fontSize: 12),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: _isLoading
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.chevron_right),
              onTap: _isLoading
                  ? null
                  : () => _confirmAndCleanupDuplicates(context),
            ),
            const Divider(height: 1),
            if (kIsWeb) ...[
              ListTile(
                leading: const Icon(Icons.storage_outlined),
                title: const Text('ブラウザキャッシュをクリア'),
                subtitle: const Text(
                  'Web版で問題がある場合に試してください。再ログインが必要です。',
                  style: TextStyle(fontSize: 12),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: _isLoading ? null : _clearBrowserCache,
              ),
            ],
            if (kDebugMode) ...[
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.build_outlined),
                title: const Text('（管理/デバッグ）バックフィルを実行'),
                subtitle: const Text(
                  'serverUpdatedAt/isDeleted を既存データに付与します（1000件ずつ）。\n'
                  '更新件数が1000に近い場合は複数回実行してください。',
                  style: TextStyle(fontSize: 12),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: _isBackfilling
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow),
                onTap: _isBackfilling ? null : _runBackfill,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _runBackfill() async {
    if (_isBackfilling) return;
    if (FirebaseService.getUserId() == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('バックフィルするにはログインしてください')),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('バックフィル実行（デバッグ）'),
        content: const Text(
          '既存の cards/decks に serverUpdatedAt / isDeleted を付与します。\n\n'
          '1000件ずつ処理します。更新件数が1000に近い場合は、もう一度実行してください。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('実行'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _isBackfilling = true);
    try {
      final result = await FirebaseService.backfillUserDocs(limit: 1000);
      final updated = (result['updated'] as int?) ?? 0;

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('バックフィル完了: updated=$updated'),
          duration: const Duration(seconds: 6),
          action: (updated >= 900)
              ? SnackBarAction(
                  label: '続き',
                  onPressed: () {
                    if (!_isBackfilling) {
                      _runBackfill();
                    }
                  },
                )
              : null,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      String message = 'バックフィル失敗: $e';
      if (e is FirebaseFunctionsException) {
        String detailsString;
        final details = e.details;
        if (details == null) {
          detailsString = '<null>';
        } else {
          // Map/List ならJSON化して読みやすくする
          try {
            detailsString =
                (details is Map || details is List) ? jsonEncode(details) : details.toString();
          } catch (_) {
            detailsString = details.toString();
          }
        }

        message = [
          'バックフィル失敗',
          'code=${e.code}',
          'message=${e.message ?? '<null>'}',
          'detailsType=${details?.runtimeType ?? '<null>'}',
          'details=$detailsString',
          '※ Firebase Console の Functions ログで "backfillUserDocs failed" を検索してください',
        ].join('\n');
        // 端末ログにも残す（Web/デバッグ時に特に有効）
        print('[backfill] FirebaseFunctionsException: $message');
      } else {
        print('[backfill] error: $e');
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 12),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isBackfilling = false);
      }
    }
  }

  Future<void> _clearBrowserCache() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('キャッシュをクリア'),
        content: const Text(
            'ブラウザのローカルキャッシュをクリアしますか？\n\nこの操作を行うと、ブラウザに保存されたデータが初期化され、自動的にログアウトします。クラウド上のデータは影響を受けません。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Colors.orange,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('クリアする'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final result = await HiveService.clearBrowserCache();
      if (mounted && Navigator.of(context).canPop())
        Navigator.of(context).pop();

      if (result) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('キャッシュをクリアしました。ログアウトします...'),
              backgroundColor: Colors.green,
              duration: Duration(seconds: 2),
            ),
          );
          await Future.delayed(const Duration(milliseconds: 500));
          await FirebaseService.signOut();
          if (mounted) {
            Navigator.of(context).pushAndRemoveUntil(
              MaterialPageRoute(builder: (context) => const LoginScreen()),
              (Route<dynamic> route) => false,
            );
          }
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('キャッシュのクリアに失敗しました'), backgroundColor: Colors.red),
          );
        }
      }
    } catch (e) {
      if (mounted && Navigator.of(context).canPop())
        Navigator.of(context).pop();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('キャッシュクリアでエラーが発生しました: $e'),
              backgroundColor: Colors.red),
        );
      }
      print('キャッシュクリアエラー: $e');
    } finally {}
  }

  Future<void> _resolveDiscrepancies() async {
    if (_isCheckingDiscrepancy) return;
    setState(() {
      _isCheckingDiscrepancy = true;
    });

    String resultMessage = '同期処理が完了しました。';
    bool success = false;

    try {
      final syncResult = await SyncService().resolveDataDiscrepancies();
      success = true;

      int totalChanges = 0;
      syncResult.forEach((key, value) {
        if (!['skipped', 'errors'].contains(key)) {
          totalChanges += value;
        }
      });

      if (syncResult['errors']! > 0) {
        resultMessage =
            '同期中に ${syncResult['errors']} 件のエラーが発生しました。詳細はログを確認してください。';
        success = false;
      } else if (totalChanges > 0) {
        resultMessage = '$totalChanges 件のデータが同期されました。\n'
            'ローカル追加: ${syncResult['localDecksAdded']! + syncResult['localCardsAdded']!} 件\n'
            'ローカル更新: ${syncResult['localDecksUpdated']! + syncResult['localCardsUpdated']!} 件\n'
            'ローカル削除: ${syncResult['localDecksDeleted']! + syncResult['localCardsDeleted']!} 件\n'
            'クラウド追加: ${syncResult['cloudDecksAdded']! + syncResult['cloudCardsAdded']!} 件\n'
            'クラウド削除扱い: ${syncResult['cloudDecksDeleted']! + syncResult['cloudCardsDeleted']!} 件';
      } else {
        resultMessage = 'データは最新の状態です。同期の必要はありませんでした。';
      }

      if (mounted) {
        _showSyncResultDialog(resultMessage, success);
      }
    } catch (e) {
      success = false;
      resultMessage = '同期処理中に予期せぬエラーが発生しました: $e';
      if (mounted) {
        _showSyncResultDialog(resultMessage, success);
      }
    } finally {
      if (mounted) {
        setState(() {
          _isCheckingDiscrepancy = false;
        });
      }
    }
  }

  void _showSyncResultDialog(String message, bool success) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(success ? '同期完了' : '同期エラー'),
          content: SingleChildScrollView(
            child: Text(message),
          ),
          actions: <Widget>[
            TextButton(
              child: Text('閉じる'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _confirmAndCleanupDuplicates(BuildContext context) async {
    final shouldCleanup = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('重複データの統一'),
          content: const Text(
            '重複カードと同名デッキをまとめて整理します。\n' +
                '重複データ内のカードは、保持されるデータに移動されます。\n' +
                '意図しないデータが保持される可能性もあります。\n' +
                'この操作は元に戻せません。実行しますか？',
            style: TextStyle(fontSize: 14),
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('キャンセル'),
              onPressed: () => Navigator.of(context).pop(false),
            ),
            TextButton(
              child: const Text('実行する', style: TextStyle(color: Colors.red)),
              onPressed: () => Navigator.of(context).pop(true),
            ),
          ],
        );
      },
    );

    if (shouldCleanup == true) {
      if (mounted) {
        setState(() => _isLoading = true);
      }

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const Center(
            child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('重複データを処理中...', style: TextStyle(color: Colors.white)),
          ],
        )),
      );

      try {
        // 重複カード -> 重複デッキ の順で処理
        final cardService = CardService();
        await cardService.unifyDuplicateCards();
        await HiveService.cleanupDuplicateDecks();

        if (mounted) Navigator.of(context).pop();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('重複データの統一処理が完了しました。'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } catch (e) {
        if (mounted) Navigator.of(context).pop();

        print('重複データの統一処理中にエラー: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('処理中にエラーが発生しました: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      } finally {
        if (mounted) {
          setState(() => _isLoading = false);
        }
      }
    }
  }
}
