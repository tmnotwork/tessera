// ignore_for_file: use_build_context_synchronously

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/category.dart';
import '../models/project.dart';
import '../services/category_service.dart';
import '../services/project_service.dart';
import '../services/project_sync_service.dart';
import '../utils/ime_safe_dialog.dart';

class ProjectCategoryAssignmentScreen extends StatefulWidget {
  /// モーダル（ボトムシート等）で表示する場合の閉じるボタン用
  final bool inModal;
  /// メイン画面のコンテンツ領域に埋め込む場合。AppBarは親が提供する。
  final bool embedded;

  const ProjectCategoryAssignmentScreen({
    super.key,
    this.inModal = false,
    this.embedded = false,
  });

  @override
  State<ProjectCategoryAssignmentScreen> createState() =>
      _ProjectCategoryAssignmentScreenState();
}

class _ProjectCategoryAssignmentScreenState
    extends State<ProjectCategoryAssignmentScreen> {
  bool _loading = true;
  bool _includeArchived = false;
  List<Project> _projects = [];
  List<Category> _categories = [];
  final ScrollController _hScroll = ScrollController();
  final ScrollController _vScroll = ScrollController();
  static final DateFormat _dateFormat = DateFormat('yyyy/MM/dd');

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _hScroll.dispose();
    _vScroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    await CategoryService.createInitialCategories();
    await CategoryService.initialize();
    await ProjectService.initialize();

    final cats = CategoryService.getCurrentUserCategories()
      ..sort((a, b) => a.name.compareTo(b.name));
    final projs = ProjectService.getAllProjects()
        .where((p) => !p.isDeleted)
        .where((p) => _includeArchived ? true : !p.isArchived)
        .toList()
      ..sort((a, b) {
        final ao = a.sortOrder ?? 1 << 30;
        final bo = b.sortOrder ?? 1 << 30;
        if (ao != bo) return ao.compareTo(bo);
        return a.name.compareTo(b.name);
      });

    setState(() {
      _categories = cats;
      _projects = projs;
      _loading = false;
    });
  }

  List<DropdownMenuItem<String?>> _buildCategoryItems(String? current) {
    final items = <DropdownMenuItem<String?>>[
      const DropdownMenuItem<String?>(
        value: null,
        child: Text('カテゴリなし'),
      ),
    ];
    final names = _categories.map((c) => c.name).toList();
    if (current != null &&
        current.isNotEmpty &&
        !names.contains(current)) {
      items.add(
        DropdownMenuItem<String?>(
          value: current,
          child: Text('$current（削除済み）'),
        ),
      );
    }
    items.addAll(
      _categories.map(
        (c) => DropdownMenuItem<String?>(
          value: c.name,
          child: Text(c.name),
        ),
      ),
    );
    return items;
  }

  Future<void> _setProjectCategory(Project project, String? category) async {
    final before = project.category;
    setState(() {
      project.category = category;
      project.lastModified = DateTime.now();
    });
    try {
      await ProjectSyncService().updateProjectWithSync(project);
    } catch (e) {
      setState(() {
        project.category = before;
        project.lastModified = DateTime.now();
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('カテゴリの保存に失敗しました: $e')),
        );
      }
    }
  }

  Future<void> _setProjectArchived(Project project, bool isArchived) async {
    final before = project.isArchived;
    setState(() {
      project.isArchived = isArchived;
      project.lastModified = DateTime.now();
    });
    try {
      await ProjectSyncService().updateProjectWithSync(project);
      if (mounted) await _load();
    } catch (e) {
      setState(() {
        project.isArchived = before;
        project.lastModified = DateTime.now();
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('アーカイブの保存に失敗しました: $e')),
        );
      }
    }
  }

  Future<void> _setProjectName(Project project, String newName) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty) return;
    if (trimmed == project.name) return;

    final before = project.name;
    setState(() {
      project.name = trimmed;
      project.lastModified = DateTime.now();
    });
    try {
      await ProjectSyncService().updateProjectWithSync(project);
    } catch (e) {
      setState(() {
        project.name = before;
        project.lastModified = DateTime.now();
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('名前の保存に失敗しました: $e')),
        );
      }
    }
  }

  Future<void> _editProjectName(Project project) async {
    final controller = TextEditingController(text: project.name);
    final result = await showImeSafeDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('プロジェクト名を編集'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: '名前',
            hintText: 'プロジェクト名',
          ),
          autofocus: true,
          onSubmitted: (_) => Navigator.pop(context, true),
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
    if (result == true && mounted) {
      await _setProjectName(project, controller.text);
    }
  }

  Widget _buildArchiveToggle() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'アーカイブ',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        Switch(
          value: _includeArchived,
          onChanged: (v) async {
            setState(() => _includeArchived = v);
            await _load();
          },
        ),
      ],
    );
  }

  Widget _buildToolbar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          const Spacer(),
          _buildArchiveToggle(),
          IconButton(
            tooltip: '再読み込み',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final content = _loading
        ? const Center(child: CircularProgressIndicator())
        : _projects.isEmpty
            ? const Center(child: Text('プロジェクトがありません'))
            : _buildTable(context);

    if (widget.embedded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildToolbar(),
          Expanded(child: content),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        leading: widget.inModal
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              )
            : null,
        title: const Text('プロジェクト管理画面'),
        actions: [
          _buildArchiveToggle(),
          IconButton(
            tooltip: '再読み込み',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: content,
    );
  }

  Widget _buildTable(BuildContext context) {
    return Scrollbar(
      controller: _vScroll,
      thumbVisibility: true,
      child: Scrollbar(
        controller: _hScroll,
        thumbVisibility: true,
        notificationPredicate: (n) => n.depth == 1,
        child: SingleChildScrollView(
          controller: _vScroll,
          child: SingleChildScrollView(
            controller: _hScroll,
            scrollDirection: Axis.horizontal,
            child: DataTable(
              headingRowColor: WidgetStateProperty.all(
                Theme.of(context).colorScheme.surfaceContainerHighest,
              ),
              columns: const [
                DataColumn(label: Text('名前')),
                DataColumn(label: Text('カテゴリ')),
                DataColumn(label: Text('アーカイブ')),
                DataColumn(label: Text('作成日'), numeric: false),
                DataColumn(label: Text('更新日'), numeric: false),
              ],
              rows: _projects.map<DataRow>((project) {
                final current = (project.category?.isEmpty ?? true)
                    ? null
                    : project.category;
                return DataRow(
                  cells: [
                    DataCell(
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Expanded(
                            child: Text(
                              project.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.edit, size: 20),
                            tooltip: '名前を編集',
                            onPressed: () => _editProjectName(project),
                            padding: const EdgeInsets.all(4),
                            constraints: const BoxConstraints(),
                            style: IconButton.styleFrom(
                              minimumSize: const Size(32, 32),
                            ),
                          ),
                        ],
                      ),
                    ),
                    DataCell(
                      SizedBox(
                        width: 200,
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String?>(
                            value: current,
                            isExpanded: true,
                            items: _buildCategoryItems(current),
                            onChanged: (val) =>
                                _setProjectCategory(project, val),
                          ),
                        ),
                      ),
                    ),
                    DataCell(
                      Switch(
                        value: project.isArchived,
                        onChanged: (v) => _setProjectArchived(project, v),
                      ),
                    ),
                    DataCell(
                      Text(_dateFormat.format(project.createdAt)),
                    ),
                    DataCell(
                      Text(_dateFormat.format(project.lastModified)),
                    ),
                  ],
                );
              }).toList(),
            ),
          ),
        ),
      ),
    );
  }
}
