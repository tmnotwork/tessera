import 'package:flutter/material.dart';
import '../models/sub_project.dart';
import '../services/sub_project_service.dart';
import '../utils/text_normalizer.dart';

class SubProjectInputDialog extends StatefulWidget {
  final String? initialValue;
  final String? selectedProjectId;
  final String? selectedSubProjectId;

  const SubProjectInputDialog({
    super.key,
    this.initialValue,
    this.selectedProjectId,
    this.selectedSubProjectId,
  });

  @override
  State<SubProjectInputDialog> createState() => _SubProjectInputDialogState();
}

class _SubProjectInputDialogState extends State<SubProjectInputDialog> {
  final TextEditingController _controller = TextEditingController();
  List<SubProject> _filteredSubProjects = [];
  List<SubProject> _allSubProjects = [];
  int _selectedIndex = -1;
  bool _showDropdown = false;

  @override
  void initState() {
    super.initState();
    _controller.text = widget.initialValue ?? '';
    _loadSubProjects();
    _filterSubProjects();
  }

  void _loadSubProjects() {
    if (widget.selectedProjectId != null) {
      _allSubProjects = SubProjectService.getSubProjectsByProjectId(
        widget.selectedProjectId!,
      );
    } else {
      _allSubProjects = [];
    }
  }

  void _filterSubProjects() {
    final query = _controller.text.toLowerCase();
    if (query.isEmpty) {
      _filteredSubProjects = List.from(_allSubProjects);
    } else {
      _filteredSubProjects = _allSubProjects
          .where((subProject) =>
              matchesQuery(subProject.name, query) ||
              matchesQuery(subProject.description ?? '', query))
          .toList();
    }
    _selectedIndex = -1;
    setState(() {
      _showDropdown = _filteredSubProjects.isNotEmpty;
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
              'サブプロジェクトを選択または作成',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              decoration: const InputDecoration(
                labelText: 'サブプロジェクト名',
                hintText: 'サブプロジェクト名を入力',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) {
                _filterSubProjects();
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
                  itemCount: _filteredSubProjects.length,
                  itemBuilder: (context, index) {
                    final subProject = _filteredSubProjects[index];
                    final isSelected = index == _selectedIndex;
                    return ListTile(
                      title: Text(subProject.name),
                      subtitle: subProject.description != null
                          ? Text(subProject.description!)
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
                          'subProject': subProject,
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

    // 既存のサブプロジェクトと完全一致するかチェック
    final exactMatch = _filteredSubProjects
        .where(
          (subProject) => subProject.name.toLowerCase() == query.toLowerCase(),
        )
        .firstOrNull;

    if (exactMatch != null) {
      Navigator.pop(context, {'type': 'existing', 'subProject': exactMatch});
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
