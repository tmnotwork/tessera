import 'package:flutter/material.dart';
import '../models/project.dart';
import '../services/project_service.dart';
import '../utils/text_normalizer.dart';

class ProjectInputDialog extends StatefulWidget {
  final String? initialValue;
  final String? selectedProjectId;

  const ProjectInputDialog({
    super.key,
    this.initialValue,
    this.selectedProjectId,
  });

  @override
  State<ProjectInputDialog> createState() => _ProjectInputDialogState();
}

class _ProjectInputDialogState extends State<ProjectInputDialog> {
  final TextEditingController _controller = TextEditingController();
  List<Project> _filteredProjects = [];
  List<Project> _allProjects = [];
  int _selectedIndex = -1;
  bool _showDropdown = false;

  @override
  void initState() {
    super.initState();
    _controller.text = widget.initialValue ?? '';
    _loadProjects();
    _filterProjects();
  }

  void _loadProjects() {
    _allProjects = ProjectService.getActiveProjects();
  }

  void _filterProjects() {
    final query = _controller.text.toLowerCase();
    if (query.isEmpty) {
      _filteredProjects = List.from(_allProjects);
    } else {
      _filteredProjects = _allProjects
          .where((project) =>
              matchesQuery(project.name, query) ||
              matchesQuery(project.description ?? '', query))
          .toList();
    }
    _selectedIndex = -1;
    setState(() {
      _showDropdown = _filteredProjects.isNotEmpty;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Container(
        width: 400,
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'プロジェクトを選択または作成',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              decoration: const InputDecoration(
                labelText: 'プロジェクト名',
                hintText: 'プロジェクト名を入力',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) {
                _filterProjects();
              },
              onSubmitted: (value) {
                _handleSubmit();
              },
            ),
            if (_showDropdown) ...[
              const SizedBox(height: 8),
              Container(
                constraints: const BoxConstraints(maxHeight: 200),
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).dividerColor),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _filteredProjects.length,
                  itemBuilder: (context, index) {
                    final project = _filteredProjects[index];
                    final isSelected = index == _selectedIndex;
                    return ListTile(
                      title: Text(project.name),
                      subtitle: project.description != null
                          ? Text(project.description!)
                          : null,
                      tileColor: isSelected
                          ? Theme.of(context)
                              .colorScheme
                              .primary
                              .withOpacity( 0.12)
                          : null,
                      onTap: () {
                        Navigator.pop(context, {
                          'type': 'existing',
                          'project': project,
                        });
                      },
                    );
                  },
                ),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('キャンセル'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _handleSubmit,
                  child: const Text('確定'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _handleSubmit() {
    final query = _controller.text.trim();
    if (query.isEmpty) {
      return;
    }

    // 既存のプロジェクトと完全一致するかチェック
    final exactMatch = _filteredProjects
        .where(
          (project) => project.name.toLowerCase() == query.toLowerCase(),
        )
        .firstOrNull;

    if (exactMatch != null) {
      Navigator.pop(context, {'type': 'existing', 'project': exactMatch});
    } else {
      // 新規作成
      Navigator.pop(context, {'type': 'new', 'name': query});
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
