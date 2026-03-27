import 'package:flutter/material.dart';
import '../models/sub_project.dart';
import '../services/sub_project_service.dart';
import '../widgets/app_bottom_navigation_bar.dart';
import '../ui_android/main_screen.dart';
import '../app/theme/app_color_tokens.dart';

class SubProjectEditScreen extends StatefulWidget {
  final SubProject subProject;

  const SubProjectEditScreen({super.key, required this.subProject});

  @override
  State<SubProjectEditScreen> createState() => _SubProjectEditScreenState();
}

class _SubProjectEditScreenState extends State<SubProjectEditScreen> {
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _nameController.text = widget.subProject.name;
    _descriptionController.text = widget.subProject.description ?? '';
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('サブプロジェクト編集'),
        actions: [
          TextButton(
            onPressed: _isLoading ? null : _saveSubProject,
            child: _isLoading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('保存'),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'サブプロジェクト名',
                border: OutlineInputBorder(),
                hintText: 'サブプロジェクト名を入力',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _descriptionController,
              decoration: const InputDecoration(
                labelText: '説明（任意）',
                border: OutlineInputBorder(),
                hintText: 'サブプロジェクトの説明を入力',
              ),
              maxLines: 3,
            ),
            const SizedBox(height: 24),
            if (widget.subProject.isArchived)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColorTokens.of(context).warningTint,
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.archive,
                      color: AppColorTokens.of(context).warning,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'このサブプロジェクトはアーカイブされています',
                      style:
                          TextStyle(color: AppColorTokens.of(context).warning),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      bottomNavigationBar: AppBottomNavigationBar(
        currentIndex: 4, // プロジェクトタブ
        onTap: (index) {
          // ナビゲーション処理
          if (index != 4) {
            // MainScreenに直接遷移して指定したタブを開く
            Navigator.of(context).pushAndRemoveUntil(
              MaterialPageRoute(
                builder: (context) => MainScreen(initialIndex: index),
              ),
              (route) => false,
            );
          }
        },
      ),
    );
  }

  Future<void> _saveSubProject() async {
    if (_nameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('サブプロジェクト名を入力してください')));
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      final updatedSubProject = widget.subProject.copyWith(
        name: _nameController.text.trim(),
        description: _descriptionController.text.trim().isEmpty
            ? null
            : _descriptionController.text.trim(),
        lastModified: DateTime.now(),
      );

      await SubProjectService.updateSubProject(updatedSubProject);

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('サブプロジェクトを更新しました')));
        Navigator.of(context).pop(true); // 更新完了を通知
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('エラーが発生しました: $e')));
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
