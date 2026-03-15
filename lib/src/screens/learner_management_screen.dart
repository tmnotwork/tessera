import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../learner_admin.dart';

/// 教師向け：学習者一覧・追加・削除・パスワードリセット
class LearnerManagementScreen extends StatefulWidget {
  const LearnerManagementScreen({super.key});

  @override
  State<LearnerManagementScreen> createState() => _LearnerManagementScreenState();
}

class _LearnerManagementScreenState extends State<LearnerManagementScreen> {
  List<Map<String, dynamic>> _learners = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetchLearners();
  }

  Future<void> _fetchLearners() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await Supabase.instance.client
          .from('profiles')
          .select('id, user_id, display_name, created_at')
          .eq('role', 'learner')
          .order('created_at', ascending: false);
      if (mounted) {
        setState(() {
          _learners = List<Map<String, dynamic>>.from(res);
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString());
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _showAddDialog() async {
    if (!LearnerAdmin.isAvailable) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              '学習者の追加には .env に SUPABASE_SERVICE_ROLE_KEY を設定してください。',
            ),
            duration: Duration(seconds: 5),
          ),
        );
      }
      return;
    }
    final userIdController = TextEditingController();
    final passwordController = TextEditingController();
    final displayNameController = TextEditingController();
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('学習者を追加'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('ログイン用のユーザーIDとパスワードを設定します。'),
              const SizedBox(height: 16),
              TextField(
                controller: userIdController,
                decoration: const InputDecoration(
                  labelText: 'ユーザーID（例: student01）',
                  border: OutlineInputBorder(),
                ),
                textInputAction: TextInputAction.next,
                autofocus: true,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: passwordController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'パスワード',
                  border: OutlineInputBorder(),
                ),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: displayNameController,
                decoration: const InputDecoration(
                  labelText: '表示名（任意）',
                  border: OutlineInputBorder(),
                ),
                textInputAction: TextInputAction.done,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('追加'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final userId = userIdController.text.trim();
    final password = passwordController.text;
    final displayName = displayNameController.text.trim();
    if (userId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ユーザーIDを入力してください。')),
      );
      return;
    }
    if (password.length < 8) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('パスワードは8文字以上で入力してください。')),
      );
      return;
    }

    setState(() => _loading = true);
    try {
      await LearnerAdmin.createLearner(
        userId: userId,
        password: password,
        displayName: displayName.isEmpty ? null : displayName,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('学習者を追加しました。')),
        );
        _fetchLearners();
      }
    } on LearnerAdminException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('追加に失敗しました: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _confirmDelete(Map<String, dynamic> learner) async {
    final id = learner['id'] as String?;
    final userId = learner['user_id'] as String? ?? id;
    if (id == null) return;
    if (!LearnerAdmin.isAvailable) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('削除には SUPABASE_SERVICE_ROLE_KEY の設定が必要です。'),
          ),
        );
      }
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('学習者を削除'),
        content: Text(
          'ユーザーID「$userId」を削除しますか？\nこの操作は取り消せません。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _loading = true);
    try {
      await LearnerAdmin.deleteLearner(id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('削除しました。')),
        );
        _fetchLearners();
      }
    } on LearnerAdminException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('削除に失敗しました: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _showResetPasswordDialog(Map<String, dynamic> learner) async {
    final id = learner['id'] as String?;
    final userId = learner['user_id'] as String? ?? id;
    if (id == null) return;
    if (!LearnerAdmin.isAvailable) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('パスワードリセットには SUPABASE_SERVICE_ROLE_KEY の設定が必要です。'),
          ),
        );
      }
      return;
    }
    final passwordController = TextEditingController();
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('パスワードをリセット'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('ユーザーID「$userId」の新しいパスワードを入力してください。'),
            const SizedBox(height: 16),
            TextField(
              controller: passwordController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '新しいパスワード',
                border: OutlineInputBorder(),
              ),
              autofocus: true,
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
            child: const Text('変更'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final newPassword = passwordController.text;
    if (newPassword.length < 8) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('パスワードは8文字以上で入力してください。')),
      );
      return;
    }

    setState(() => _loading = true);
    try {
      await LearnerAdmin.resetLearnerPassword(id, newPassword);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('パスワードを変更しました。')),
        );
      }
    } on LearnerAdminException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('変更に失敗しました: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('学習者管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '再読み込み',
            onPressed: _loading ? null : _fetchLearners,
          ),
        ],
      ),
      body: _loading && _learners.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          _error!,
                          style: Theme.of(context).textTheme.bodyMedium,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: _fetchLearners,
                          icon: const Icon(Icons.refresh),
                          label: const Text('再試行'),
                        ),
                      ],
                    ),
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!LearnerAdmin.isAvailable)
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Card(
                          color: Theme.of(context).colorScheme.surfaceContainerHighest,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(
                              '学習者の追加・削除・パスワードリセットには、.env に SUPABASE_SERVICE_ROLE_KEY を設定してください。一覧の表示のみ可能です。',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        ),
                      ),
                    if (_loading) const LinearProgressIndicator(),
                    Expanded(
                      child: _learners.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.people_outline,
                                    size: 64,
                                    color: Theme.of(context).colorScheme.outline,
                                  ),
                                  const SizedBox(height: 16),
                                  const Text('学習者がいません'),
                                  const SizedBox(height: 8),
                                  Text(
                                    '「追加」からユーザーIDとパスワードを設定して追加できます。',
                                    style: Theme.of(context).textTheme.bodySmall,
                                    textAlign: TextAlign.center,
                                  ),
                                ],
                              ),
                            )
                          : ListView.separated(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              itemCount: _learners.length,
                              separatorBuilder: (_, __) => const Divider(height: 1),
                              itemBuilder: (context, index) {
                                final l = _learners[index];
                                final userId = l['user_id']?.toString() ?? '-';
                                final displayName = l['display_name']?.toString();
                                return ListTile(
                                  title: Text(userId),
                                  subtitle: displayName != null && displayName.isNotEmpty
                                      ? Text(displayName)
                                      : null,
                                  trailing: LearnerAdmin.isAvailable
                                      ? Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            TextButton(
                                              onPressed: () => _showResetPasswordDialog(l),
                                              child: const Text('パスワード'),
                                            ),
                                            IconButton(
                                              icon: const Icon(Icons.delete_outline),
                                              tooltip: '削除',
                                              onPressed: () => _confirmDelete(l),
                                            ),
                                          ],
                                        )
                                      : null,
                                );
                              },
                            ),
                    ),
                  ],
                ),
      floatingActionButton: LearnerAdmin.isAvailable
          ? FloatingActionButton.extended(
              onPressed: _loading ? null : _showAddDialog,
              icon: const Icon(Icons.add),
              label: const Text('学習者を追加'),
            )
          : null,
    );
  }
}
