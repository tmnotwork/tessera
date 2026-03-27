// ignore_for_file: use_build_context_synchronously

import 'package:flutter/material.dart';

import '../models/category.dart';
import '../services/auth_service.dart';
import '../services/category_service.dart';
import '../services/category_sync_service.dart';
import '../utils/ime_safe_dialog.dart';

enum _CategorySort {
  createdAtAsc,
  nameAsc,
}

class CategoryDbScreen extends StatefulWidget {
  const CategoryDbScreen({super.key});

  @override
  State<CategoryDbScreen> createState() => _CategoryDbScreenState();
}

class _CategoryDbScreenState extends State<CategoryDbScreen> {
  bool _isLoading = false;
  bool _syncing = false;
  String? _errorMessage;
  DateTime? _lastSyncedAt;
  final Set<String> _deletingIds = {};
  List<Category> _categories = [];
  _CategorySort _sort = _CategorySort.createdAtAsc;

  @override
  void initState() {
    super.initState();
    _loadCategories(runSync: true);
  }

  String _sortLabel(_CategorySort value) {
    switch (value) {
      case _CategorySort.createdAtAsc:
        return '作成日順';
      case _CategorySort.nameAsc:
        return '名前順';
    }
  }

  List<Category> get _visibleCategories {
    final list = List<Category>.from(_categories);
    list.sort((a, b) {
      switch (_sort) {
        case _CategorySort.createdAtAsc:
          final diff = a.createdAt.compareTo(b.createdAt);
          if (diff != 0) return diff;
          return a.id.compareTo(b.id);
        case _CategorySort.nameAsc:
          final an = a.name.trim().toLowerCase();
          final bn = b.name.trim().toLowerCase();
          final diff = an.compareTo(bn);
          if (diff != 0) return diff;
          // 同名のときは作成日→IDで安定化
          final createdDiff = a.createdAt.compareTo(b.createdAt);
          if (createdDiff != 0) return createdDiff;
          return a.id.compareTo(b.id);
      }
    });
    return list;
  }

  Future<void> _loadCategories({required bool runSync}) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      if (runSync) {
        await _syncCategories(forceHeavy: false);
      }
      await CategoryService.initialize();
      final categories = CategoryService.getAllCategories();
      setState(() => _categories = categories);
    } catch (e) {
      setState(() => _errorMessage = '読み込みに失敗しました: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _syncCategories({required bool forceHeavy}) async {
    if (_syncing) return;
    setState(() => _syncing = true);
    try {
      // カテゴリは DataSyncTarget に入っていないため、同期サービスを直接叩く。
      final result = await CategorySyncService.syncAllCategories();
      if (result.success) {
        _lastSyncedAt = DateTime.now();
      } else {
        _showSnack('同期に失敗しました: ${result.error ?? 'unknown'}');
      }
    } catch (e) {
      _showSnack('同期に失敗しました: $e');
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  String _syncStatusLabel() {
    if (_syncing) return '同期中...';
    if (_lastSyncedAt == null) return 'ローカルキャッシュを表示中';
    final diff = DateTime.now().difference(_lastSyncedAt!);
    if (diff.inMinutes < 1) return '直前に同期済み';
    return '最終同期: ${_lastSyncedAt!.toString().split(".").first}';
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _addCategory() async {
    String name = '';
    final ok = await showImeSafeDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('カテゴリ追加'),
        content: TextField(
          autofocus: true,
          decoration: const InputDecoration(labelText: 'カテゴリ名'),
          onChanged: (v) => name = v,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('追加'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;

    final userId = AuthService.getCurrentUserId();
    if (userId == null || userId.isEmpty) {
      _showSnack('ユーザーIDが取得できません');
      return;
    }

    try {
      final created = await CategorySyncService().createCategoryWithSync(
        name: trimmed,
      );
      if (!mounted) return;
      setState(() => _categories.add(created));
      _showSnack('追加しました: ${created.id}');
    } catch (e) {
      _showSnack('追加に失敗しました: $e');
    }
  }

  Future<void> _editCategory(Category category) async {
    final controller = TextEditingController(text: category.name);
    final ok = await showImeSafeDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('カテゴリ編集'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'カテゴリ名'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final trimmed = controller.text.trim();
    if (trimmed.isEmpty || trimmed == category.name) return;

    final updated = category.copyWith(
      name: trimmed,
      lastModified: DateTime.now(),
      version: category.version + 1,
    );
    try {
      await CategorySyncService().updateCategoryWithSync(updated);
      if (!mounted) return;
      setState(() {
        final idx = _categories.indexWhere((c) => c.id == category.id);
        if (idx >= 0) _categories[idx] = updated;
      });
      _showSnack('保存しました: ${category.id}');
    } catch (e) {
      _showSnack('保存に失敗しました: $e');
    } finally {
      controller.dispose();
    }
  }

  Future<void> _confirmDelete(Category category) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('カテゴリ削除'),
        content: Text(
          '「${category.name}」(ID: ${category.id}) を削除しますか？\nこの操作は取り消せません。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _deletingIds.add(category.id));
    try {
      await CategorySyncService().deleteCategoryWithSync(category.id);
      if (!mounted) return;
      setState(() => _categories.removeWhere((c) => c.id == category.id));
      _showSnack('削除しました: ${category.id}');
    } catch (e) {
      _showSnack('削除に失敗しました: $e');
    } finally {
      if (mounted) setState(() => _deletingIds.remove(category.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final categories = _visibleCategories;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'カテゴリ一覧（${categories.length}件）',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Hive: categories（ローカル）',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              DropdownButtonHideUnderline(
                child: DropdownButton<_CategorySort>(
                  value: _sort,
                  items: _CategorySort.values
                      .map(
                        (v) => DropdownMenuItem<_CategorySort>(
                          value: v,
                          child: Text('並び替え: ${_sortLabel(v)}'),
                        ),
                      )
                      .toList(),
                  onChanged: (v) {
                    if (v == null || v == _sort) return;
                    setState(() => _sort = v);
                  },
                ),
              ),
              Text(
                _syncStatusLabel(),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              IconButton(
                tooltip: '再読み込み',
                onPressed: _isLoading ? null : () => _loadCategories(runSync: true),
                icon: const Icon(Icons.refresh),
              ),
              IconButton(
                tooltip: '同期（強制）',
                onPressed: _syncing ? null : () async {
                  await _syncCategories(forceHeavy: true);
                  await _loadCategories(runSync: false);
                },
                icon: _syncing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync),
              ),
            ],
          ),
        ),
        if (_errorMessage != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              _errorMessage!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (_isLoading)
          const Padding(
            padding: EdgeInsets.all(16),
            child: LinearProgressIndicator(),
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _loadCategories(runSync: true),
            child: categories.isEmpty
                ? ListView(
                    children: const [
                      SizedBox(height: 120),
                      Center(child: Text('カテゴリが存在しません')),
                    ],
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: categories.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final c = categories[index];
                      final deleting = _deletingIds.contains(c.id);
                      final subtitle = <String>[
                        'ID: ${c.id}',
                        if ((c.cloudId ?? '').isNotEmpty) 'cloudId: ${c.cloudId}',
                        'userId: ${c.userId}',
                        'version: ${c.version}',
                        if (c.isDeleted) 'deleted',
                      ].join(' / ');
                      return ListTile(
                        title: Text(c.name),
                        subtitle: Text(subtitle),
                        onTap: () => _editCategory(c),
                        trailing: deleting
                            ? const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : PopupMenuButton<String>(
                                onSelected: (value) {
                                  switch (value) {
                                    case 'edit':
                                      _editCategory(c);
                                      break;
                                    case 'delete':
                                      _confirmDelete(c);
                                      break;
                                  }
                                },
                                itemBuilder: (ctx) => [
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
                                          color: Theme.of(ctx).colorScheme.error,
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          '削除',
                                          style: TextStyle(
                                            color:
                                                Theme.of(ctx).colorScheme.error,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                      );
                    },
                  ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Row(
            children: [
              const Spacer(),
              ElevatedButton.icon(
                onPressed: _addCategory,
                icon: const Icon(Icons.add),
                label: const Text('カテゴリ追加'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

