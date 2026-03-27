// ignore_for_file: use_build_context_synchronously

import 'package:flutter/material.dart';
import '../models/category.dart';
import '../services/category_service.dart';
import '../services/auth_service.dart';
import '../utils/ime_safe_dialog.dart';
import 'project_category_assignment_screen.dart';

class CategoryManagementScreen extends StatefulWidget {
  const CategoryManagementScreen({super.key});

  @override
  State<CategoryManagementScreen> createState() =>
      _CategoryManagementScreenState();
}

class _CategoryManagementScreenState extends State<CategoryManagementScreen> {
  List<Category> _categories = [];
  bool _showProjectManagement = false;

  @override
  void initState() {
    super.initState();
    _loadCategories();
  }

  Future<void> _loadCategories() async {
    final categories = CategoryService.getCurrentUserCategories();
    setState(() {
      _categories = categories;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        leading: _showProjectManagement
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() => _showProjectManagement = false),
              )
            : null,
        title: Text(_showProjectManagement ? 'プロジェクト管理画面' : 'カテゴリ管理'),
        actions: _showProjectManagement
            ? null
            : [
                IconButton(
                  tooltip: 'プロジェクト管理画面',
                  icon: const Icon(Icons.folder),
                  onPressed: () =>
                      setState(() => _showProjectManagement = true),
                ),
              ],
      ),
      body: _showProjectManagement
          ? const ProjectCategoryAssignmentScreen(embedded: true)
          : (_categories.isEmpty
          ? ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              children: [
                _buildAssignmentLink(context),
                const SizedBox(height: 24),
                Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.category,
                          size: 64, color: scheme.onSurfaceVariant),
                      const SizedBox(height: 16),
                      Text(
                        'カテゴリがありません',
                        style: TextStyle(
                            fontSize: 18, color: scheme.onSurfaceVariant),
                      ),
                      Text(
                        'カテゴリを追加してください',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: _buildAssignmentLink(context),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.vertical,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: DataTable(
                          headingRowColor: WidgetStateProperty.all(
                            scheme.surfaceContainerHighest,
                          ),
                          columns: const [
                            DataColumn(label: Text('カテゴリ名')),
                            DataColumn(label: Text('作成日')),
                            DataColumn(label: Text('操作')),
                          ],
                          rows: _categories.map((category) {
                            final created =
                                category.createdAt.toString().split(' ')[0];
                            return DataRow(
                              cells: [
                                DataCell(
                                  Text(category.name),
                                  onTap: () => _editCategory(category),
                                ),
                                DataCell(Text(created)),
                                DataCell(
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        icon: const Icon(Icons.edit),
                                        tooltip: '編集',
                                        onPressed: () =>
                                            _editCategory(category),
                                      ),
                                      IconButton(
                                        icon: Icon(Icons.delete,
                                            color: scheme.error),
                                        tooltip: '削除',
                                        onPressed: () =>
                                            _deleteCategory(category),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            )),
      floatingActionButton: _showProjectManagement
          ? null
          : FloatingActionButton(
        onPressed: _addCategory,
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Theme.of(context).colorScheme.onPrimary,
        child: const Icon(Icons.add),
      ),
    );
  }

  Future<void> _addCategory() async {
    String name = '';
    final result = await showImeSafeDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('カテゴリ追加'),
        content: TextField(
          decoration: const InputDecoration(labelText: 'カテゴリ名'),
          onChanged: (v) => name = v,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('追加'),
          ),
        ],
      ),
    );

    if (result == true && name.trim().isNotEmpty) {
      final userId = AuthService.getCurrentUserId();
      if (userId == null) return;

      final category = Category(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: name.trim(),
        userId: userId,
        createdAt: DateTime.now(),
        lastModified: DateTime.now(),
      );
      await CategoryService.addCategory(category);
      await _loadCategories();
    }
  }

  Widget _buildAssignmentLink(BuildContext context) {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.folder),
        title: const Text('プロジェクト管理画面'),
        subtitle: const Text('プロジェクト名・カテゴリを表形式で確認・編集できます'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => setState(() => _showProjectManagement = true),
      ),
    );
  }

  void _handleCategoryAction(String action, Category category) async {
    switch (action) {
      case 'edit':
        _editCategory(category);
        break;
      case 'delete':
        _deleteCategory(category);
        break;
    }
  }

  Future<void> _editCategory(Category category) async {
    String name = category.name;
    final result = await showImeSafeDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('カテゴリ編集'),
        content: TextField(
          decoration: const InputDecoration(labelText: 'カテゴリ名'),
          controller: TextEditingController(text: name),
          onChanged: (v) => name = v,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result == true && name.trim().isNotEmpty) {
      final updated = category.copyWith(
        name: name.trim(),
        lastModified: DateTime.now(),
        version: category.version + 1,
      );
      await CategoryService.updateCategory(updated);
      await _loadCategories();
    }
  }

  Future<void> _deleteCategory(Category category) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('カテゴリ削除'),
        content: Text('「${category.name}」を削除しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('削除'),
          ),
        ],
      ),
    );

    if (result == true) {
      await CategoryService.deleteCategory(category.id);
      await _loadCategories();
    }
  }
}
