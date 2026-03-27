// ignore_for_file: use_build_context_synchronously

import 'package:flutter/material.dart';
import '../models/mode.dart';
import '../services/mode_service.dart';
import '../services/mode_sync_service.dart';
import '../services/auth_service.dart';
import '../utils/ime_safe_dialog.dart';

class ModeEditScreen extends StatefulWidget {
  const ModeEditScreen({super.key});

  @override
  State<ModeEditScreen> createState() => _ModeEditScreenState();
}

class _ModeEditScreenState extends State<ModeEditScreen> {
  List<Mode> _modes = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadModes();
  }

  Future<void> _loadModes() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final modes = ModeService.getAllModes();
      setState(() {
        _modes = modes;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('モードの読み込みに失敗しました: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'モード編集',
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
        toolbarHeight: 48,
      ),
      body:
          _isLoading
              ? const Center(child: CircularProgressIndicator())
              : Column(
                children: [
                  // 説明
                  Container(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'タスクのモードを管理します。モードはタスクの種類や状況を分類するために使用されます。',
                      style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
                    ),
                  ),
                  // モードリスト
                  Expanded(
                    child:
                        _modes.isEmpty
                            ? Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.category,
                                    size: 64,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    'モードがありません',
                                    style: TextStyle(
                                      fontSize: 18,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                  Text(
                                    '新しいモードを追加してください',
                                    style: TextStyle(color: scheme.onSurfaceVariant),
                                  ),
                                ],
                              ),
                            )
                            : ListView.builder(
                              itemCount: _modes.length,
                              itemBuilder: (context, index) {
                                final mode = _modes[index];
                                return _buildModeCard(mode);
                              },
                            ),
                  ),
                ],
              ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddModeDialog,
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Theme.of(context).colorScheme.onPrimary,
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildModeCard(Mode mode) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: ListTile(
        title: Text(
          mode.name,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle:
            mode.description != null
                ? Text(mode.description!)
                : const Text('説明なし'),
        trailing: PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          onSelected: (value) {
            switch (value) {
              case 'edit':
                _showEditModeDialog(mode);
                break;
              case 'delete':
                _showDeleteModeDialog(mode);
                break;
            }
          },
          itemBuilder:
              (context) => [
                const PopupMenuItem(
                  value: 'edit',
                  child: Row(
                    children: [
                      Icon(Icons.edit),
                      SizedBox(width: 8),
                      Text('編集'),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: Row(
                    children: [
                      Icon(
                        Icons.delete,
                        color: Theme.of(context).colorScheme.error,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '削除',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
        ),
      ),
    );
  }

  void _showAddModeDialog() {
    final nameController = TextEditingController();
    final descriptionController = TextEditingController();

    showImeSafeDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('モードを追加'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: 'モード名',
                    hintText: '例: 仕事、プライベート、学習',
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: descriptionController,
                  decoration: const InputDecoration(
                    labelText: '説明（任意）',
                    hintText: 'モードの説明を入力してください',
                  ),
                  maxLines: 3,
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
                  final name = nameController.text.trim();
                  if (name.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('モード名を入力してください')),
                    );
                    return;
                  }

                  try {
                    final currentUser = AuthService.getCurrentUser();
                    if (currentUser == null) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('ユーザー情報が取得できません')),
                      );
                      return;
                    }

                    // 同期対応で新規モードを作成
                    await ModeSyncService().createModeWithSync(
                      name: name,
                      description: descriptionController.text.trim().isEmpty
                          ? null
                          : descriptionController.text.trim(),
                    );
                    Navigator.of(context).pop();
                    _loadModes();

                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('モードを追加しました')));
                  } catch (e) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('モードの追加に失敗しました: $e')),
                    );
                  }
                },
                child: const Text('追加'),
              ),
            ],
          ),
    );
  }

  void _showEditModeDialog(Mode mode) {
    final nameController = TextEditingController(text: mode.name);
    final descriptionController = TextEditingController(
      text: mode.description ?? '',
    );

    showImeSafeDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('モードを編集'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: 'モード名',
                    hintText: '例: 仕事、プライベート、学習',
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: descriptionController,
                  decoration: const InputDecoration(
                    labelText: '説明（任意）',
                    hintText: 'モードの説明を入力してください',
                  ),
                  maxLines: 3,
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
                  final name = nameController.text.trim();
                  if (name.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('モード名を入力してください')),
                    );
                    return;
                  }

                  try {
                    final updatedMode = mode.copyWith(
                      name: name,
                      description:
                          descriptionController.text.trim().isEmpty
                              ? null
                              : descriptionController.text.trim(),
                    );

                    await ModeSyncService().updateModeWithSync(updatedMode);
                    Navigator.of(context).pop();
                    _loadModes();

                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('モードを更新しました')));
                  } catch (e) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('モードの更新に失敗しました: $e')),
                    );
                  }
                },
                child: const Text('更新'),
              ),
            ],
          ),
    );
  }

  void _showDeleteModeDialog(Mode mode) {
    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('モードを削除'),
            content: Text(
              '「${mode.name}」を削除しますか？\n\nこのモードを使用しているタスクは影響を受けません。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('キャンセル'),
              ),
              ElevatedButton(
                onPressed: () async {
                  try {
                    await ModeSyncService().deleteModeWithSync(mode.id);
                    Navigator.of(context).pop();
                    _loadModes();

                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('モードを削除しました')));
                  } catch (e) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('モードの削除に失敗しました: $e')),
                    );
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                ),
                child: const Text('削除'),
              ),
            ],
          ),
    );
  }
}
