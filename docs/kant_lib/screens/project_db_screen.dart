import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/project.dart';
import '../services/project_service.dart';
import '../services/project_sync_service.dart';
import '../services/sync_manager.dart';

class ProjectDbScreen extends StatefulWidget {
  const ProjectDbScreen({super.key});

  @override
  State<ProjectDbScreen> createState() => _ProjectDbScreenState();
}

class _ProjectDbScreenState extends State<ProjectDbScreen> {
  bool _isLoading = false;
  String? _errorMessage;
  List<Project> _projects = [];
  final Set<String> _deletingIds = {};
  bool _syncing = false;
  DateTime? _lastSyncedAt;

  @override
  void initState() {
    super.initState();
    _loadProjects();
  }

  Future<void> _loadProjects({bool runSync = true}) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    await Future<void>.delayed(const Duration(milliseconds: 50));
    try {
      if (runSync) {
        await _ensureProjectFreshness(forceHeavy: false);
      }
      await ProjectService.initialize();
      final projects = ProjectService.getProjectsForList();
      
      if (projects.isEmpty) {
        print('⚠️ ProjectDbScreen: No projects found');
      }
      
      projects.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      setState(() {
        _projects = projects;
      });
    } catch (e, stackTrace) {
      print('❌ ProjectDbScreen._loadProjects() error: $e');
      print('Stack trace: $stackTrace');
      if (mounted) {
        setState(() {
          _errorMessage = '読み込みに失敗しました: $e';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  List<Project> get _visibleProjects =>
      List<Project>.from(_projects)..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  Future<void> _ensureProjectFreshness({required bool forceHeavy}) async {
    try {
      setState(() => _syncing = true);
      if (forceHeavy) {
        await SyncManager.syncDataFor(
          {DataSyncTarget.projects},
          forceHeavy: true,
        );
        _lastSyncedAt = DateTime.now();
      } else {
        final results = await SyncManager.syncIfStale(
          {DataSyncTarget.projects},
        );
        final success = results.values
            .where((result) => result != null)
            .any((result) => result!.success);
        if (success) {
          _lastSyncedAt = DateTime.now();
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('差分同期に失敗しました: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _syncing = false);
      }
    }
  }

  String _syncStatusLabel() {
    if (_syncing) return '同期中...';
    if (_lastSyncedAt == null) {
      return 'ローカルキャッシュを表示中';
    }
    final diff = DateTime.now().difference(_lastSyncedAt!);
    if (diff.inMinutes < 1) return '直前に同期済み';
    return '最終同期: ${DateFormat('MM/dd HH:mm').format(_lastSyncedAt!)}';
  }

  Future<void> _confirmDelete(Project project) async {
    if (ProjectService.isNonDeletableProject(project.id)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('このプロジェクトは削除できません')),
        );
      }
      return;
    }
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('プロジェクトを削除'),
        content: Text(
          project.name.trim().isEmpty
              ? '名称のないプロジェクト（ID: ${project.id}）を削除しますか？'
              : '「${project.name}」(ID: ${project.id}) を削除しますか？\nこの操作は取り消せません。',
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
    if (confirm != true) return;

    setState(() => _deletingIds.add(project.id));
    try {
      await ProjectSyncService().deleteProjectWithSync(project.id);
      if (!mounted) return;
      setState(() {
        _projects.removeWhere((p) => p.id == project.id);
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('削除しました: ${project.id}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('削除に失敗しました: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _deletingIds.remove(project.id));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
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
                      'プロジェクト一覧（${_projects.length}件）',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '全プロジェクトを表示中',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text(
                _syncStatusLabel(),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              IconButton(
                tooltip: '再読み込み',
                onPressed: _isLoading ? null : () => _loadProjects(runSync: true),
                icon: const Icon(Icons.refresh),
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
            onRefresh: _loadProjects,
            child: _visibleProjects.isEmpty
                ? ListView(
                    children: const [
                      SizedBox(height: 120),
                      Center(child: Text('プロジェクトが存在しません')),
                    ],
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _visibleProjects.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final project = _visibleProjects[index];
                      final name =
                          project.name.trim().isEmpty ? '（名称なし）' : project.name;
                      final subtitle = <String>[
                        'ID: ${project.id}',
                        if (project.category?.isNotEmpty ?? false)
                          'カテゴリ: ${project.category}',
                        '作成: ${project.createdAt}',
                      ].join(' / ');
                      final deleting = _deletingIds.contains(project.id);
                      return ListTile(
                        leading: Icon(
                          project.name.trim().isEmpty
                              ? Icons.warning_amber
                              : Icons.folder,
                          color: project.name.trim().isEmpty
                              ? Theme.of(context).colorScheme.error
                              : Theme.of(context).iconTheme.color,
                        ),
                        title: Text(name),
                        subtitle: Text(subtitle),
                        trailing: deleting
                            ? const SizedBox(
                                width: 24,
                                height: 24,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : IconButton(
                                icon: const Icon(Icons.delete_outline),
                                color: Theme.of(context).colorScheme.error,
                                tooltip: '削除する',
                                onPressed: () => _confirmDelete(project),
                              ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}
