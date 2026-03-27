// ignore_for_file: use_build_context_synchronously

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/project.dart';
import '../providers/task_provider.dart';
import '../models/category.dart';
import '../models/inbox_task.dart' as inbox;
import '../services/auth_service.dart';
import '../services/project_service.dart';
import '../services/project_sync_service.dart';

import '../services/category_service.dart';
import '../services/inbox_task_service.dart';
import 'inbox_task_edit_screen.dart';
import '../services/app_settings_service.dart';
import '../services/selection_frequency_service.dart';
import '../utils/unified_screen_dialog.dart';

import 'sub_project_management_screen.dart';
import '../widgets/app_notifications.dart';

class ProjectListScreen extends StatefulWidget {
  final ValueNotifier<bool>? twoColumnModeNotifier;
  final ValueNotifier<bool>? filterBarVisibleNotifier;
  final ValueNotifier<bool>? hideEmptyProjectsNotifier;

  const ProjectListScreen(
      {super.key,
      this.twoColumnModeNotifier,
      this.filterBarVisibleNotifier,
      this.hideEmptyProjectsNotifier});

  @override
  State<ProjectListScreen> createState() => _ProjectListScreenState();
}

class _ProjectListScreenState extends State<ProjectListScreen> {
  List<Project> _projects = [];
  List<Project> _filteredProjects = [];
  String _selectedCategory = 'すべて';
  final bool _showArchived = false;
  List<String> _categories = ['すべて'];
  List<Category> _availableCategories = [];
  bool _showIncompleteUnderProject = true; // 設定「プロジェクトのみを表示」により切替
  bool _showFilterBar = false; // フィルター行の表示/非表示（デフォルト非表示）
  bool _twoColumnMode = false; // 2列レイアウト切替
  bool _hideEmptyProjects = true; // 未実施が無いプロジェクトを非表示（デフォルトON）
  late final VoidCallback _projectOnlyListener;
  /// 初回プロジェクト同期がまだ終わっていない間は「読み込み中」を表示する。
  bool _isLoadingProjects = true;
  void _onInitialProjectSyncSettled() {
    if (!mounted) return;
    AuthService.initialProjectSyncSettled.removeListener(_onInitialProjectSyncSettled);
    _loadProjects(afterInitialSync: true);
  }

  /// 初回プロジェクトDLが未実行のまま（オフライン/uid遅延等）の場合、遅延リトライで確実に実行する
  void _scheduleInitialSyncRetries() {
    const delays = [
      Duration(milliseconds: 500),
      Duration(seconds: 2),
      Duration(seconds: 5),
    ];
    for (final delay in delays) {
      Future.delayed(delay, () async {
        if (!mounted) return;
        if (AuthService.initialProjectSyncSettled.value) return;
        await AuthService.ensureInitialProjectsDownloaded();
        if (!mounted) return;
        await _loadProjects(afterInitialSync: true);
      });
    }
  }

  @override
  void initState() {
    super.initState();
    // Notifier の初期値を反映（再起動復元や親からの初期設定を即時反映するため）
    _showFilterBar = widget.filterBarVisibleNotifier?.value ?? _showFilterBar;
    _twoColumnMode = widget.twoColumnModeNotifier?.value ?? _twoColumnMode;
    _hideEmptyProjects =
        widget.hideEmptyProjectsNotifier?.value ?? _hideEmptyProjects;

    // 「プロジェクトのみを表示」設定に追従（ONなら未了タスクは展開しない）
    _showIncompleteUnderProject =
        !AppSettingsService.projectShowProjectsOnlyNotifier.value;
    _projectOnlyListener = () {
      final projectsOnly = AppSettingsService.projectShowProjectsOnlyNotifier.value;
      if (mounted) {
        setState(() {
          _showIncompleteUnderProject = !projectsOnly;
        });
      }
    };
    AppSettingsService.projectShowProjectsOnlyNotifier
        .addListener(_projectOnlyListener);

    _initializeCategories();
    _loadProjects();
    // 初回プロジェクト同期がまだのときは、完了時に再読み込みする（Web で同期待ちの根本対応）
    if (!AuthService.initialProjectSyncSettled.value) {
      AuthService.initialProjectSyncSettled.addListener(_onInitialProjectSyncSettled);
      _scheduleInitialSyncRetries();
    }
    // 外部トグルと連動
    widget.filterBarVisibleNotifier?.addListener(() {
      final v = widget.filterBarVisibleNotifier!.value;
      if (mounted) setState(() => _showFilterBar = v);
    });
    widget.twoColumnModeNotifier?.addListener(() {
      final v = widget.twoColumnModeNotifier!.value;
      if (mounted) setState(() => _twoColumnMode = v);
    });
    widget.hideEmptyProjectsNotifier?.addListener(() {
      final v = widget.hideEmptyProjectsNotifier!.value;
      if (mounted)
        setState(() {
          _hideEmptyProjects = v;
          _filterProjects();
        });
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 画面が表示されるたびにプロジェクトを再読み込み
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadProjects();
    });
  }

  Future<void> _initializeCategories() async {
    // 初期カテゴリを作成
    await CategoryService.createInitialCategories();

    // 利用可能なカテゴリを取得
    final categories = CategoryService.getCurrentUserCategories();
    setState(() {
      _availableCategories = categories;
    });
  }

  Future<void> _loadProjects({bool isRetry = false, bool afterInitialSync = false}) async {
    if (!mounted) return;
    if (_projects.isEmpty) {
      setState(() => _isLoadingProjects = true);
    }
    try {
      await ProjectService.initialize();
      await InboxTaskService.initialize();

      final uid = AuthService.getCurrentUserId();
      final projects = ProjectService.getProjectsForList();

      if (mounted) {
        setState(() {
          _projects = projects;
          _updateFilters();
          _isLoadingProjects = false;
        });
        // 初回同期直後のリフレッシュで、プロジェクトはあるがフィルタで全て非表示のときは
        // 「すべてのプロジェクトを表示」にして一覧を出し、UIを確実に更新する
        if (afterInitialSync && projects.isNotEmpty && _filteredProjects.isEmpty) {
          setState(() {
            _hideEmptyProjects = false;
            _filterProjects();
          });
          widget.hideEmptyProjectsNotifier?.value = false;
        }
      }
      // ログイン直後など uid がまだ確定していない場合、1回だけ短い遅延後に再取得
      if (!isRetry && projects.isEmpty && (uid == null || uid.isEmpty) && AuthService.isLoggedIn()) {
        await Future.delayed(const Duration(milliseconds: 400));
        if (mounted) await _loadProjects(isRetry: true);
        return;
      }
      // Web: 同期済みなのに0件のとき、uid/Box のタイミングで取りこぼした可能性があるので1回だけ再取得
      if (!isRetry && projects.isEmpty && AuthService.initialProjectSyncSettled.value && AuthService.isLoggedIn()) {
        await Future.delayed(const Duration(milliseconds: 300));
        if (mounted) {
          final again = ProjectService.getProjectsForList();
          if (again.isNotEmpty) {
            setState(() {
              _projects = again;
              _updateFilters();
              _isLoadingProjects = false;
            });
            if (afterInitialSync && _filteredProjects.isEmpty) {
              setState(() {
                _hideEmptyProjects = false;
                _filterProjects();
              });
              widget.hideEmptyProjectsNotifier?.value = false;
            }
          }
        }
      }
    } catch (e, stackTrace) {
      if (mounted) setState(() => _isLoadingProjects = false);
      // エラーハンドリング
      print('❌ ProjectListScreen._loadProjects() error: $e');
      print('Stack trace: $stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(
          content: Text('プロジェクトの読み込みに失敗しました: $e'),
          duration: const Duration(seconds: 5),
        ));
      }
    }
  }

  void _updateFilters() {
    // カテゴリのリストを更新
    final categories = <String>{'すべて'};

    for (final project in _projects) {
      if (project.category != null && project.category!.isNotEmpty) {
        categories.add(project.category!);
      }
    }

    _categories = categories.toList()..sort();

    _filterProjects();
  }

  void _filterProjects() {
    _filteredProjects = _projects.where((project) {
      // アーカイブ状態でフィルタ
      if (!_showArchived && project.isArchived) return false;
      if (_showArchived && !project.isArchived) return false;

      // カテゴリでフィルタ
      if (_selectedCategory != 'すべて' && project.category != _selectedCategory) {
        return false;
      }

      return true;
    }).toList();

    // 未実施タスクが無いプロジェクトを非表示（設定ONのとき）
    if (_hideEmptyProjects) {
      _filteredProjects = _filteredProjects.where((p) {
        final tasks = InboxTaskService.getInboxTasksByProjectId(p.id)
            .where((t) => !t.isCompleted && !t.isDeleted && t.isSomeday != true)
            .toList();
        return tasks.isNotEmpty;
      }).toList();
    }

    // 並び順: ProjectInputField と同じ（直近90日実績のよく使う順 → 名前）
    _filteredProjects.sort((a, b) {
      final fa = SelectionFrequencyService.getProjectCount(a.id);
      final fb = SelectionFrequencyService.getProjectCount(b.id);
      if (fb != fa) return fb.compareTo(fa);
      return a.name.compareTo(b.name);
    });
  }

  @override
  void dispose() {
    try {
      AuthService.initialProjectSyncSettled.removeListener(_onInitialProjectSyncSettled);
    } catch (_) {}
    try {
      AppSettingsService.projectShowProjectsOnlyNotifier
          .removeListener(_projectOnlyListener);
    } catch (_) {}
    super.dispose();
  }

  /// 2列グリッドを許可するか。
  /// 短辺でスマホ（横向き含む）を除外する。幅の下限は「実パネル幅」基準（NewUIScreen が
  /// 左ナビ付きで MediaQuery.size をパネルに合わせる）でも 800 未満になりがちなため、
  /// 2 列カードが成立する程度に下げる。
  bool _allowTwoColumnLayout(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    const minWidthForTwoColumns = 560.0;
    return _twoColumnMode &&
        size.width >= minWidthForTwoColumns &&
        size.shortestSide >= 600;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // フィルター部分（AppBarのボタンで出し入れ）
        AnimatedCrossFade(
          firstChild: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context)
                  .colorScheme
                  .surfaceContainerHighest
                  .withOpacity(Theme.of(context).brightness == Brightness.light
                          ? 1
                          : 0.2),
              border: Border(
                  bottom: BorderSide(color: Theme.of(context).dividerColor)),
            ),
            child: Row(
              children: [
                const Text(
                  'カテゴリ: ',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButton<String>(
                    value: _selectedCategory,
                    isExpanded: true,
                    items: _categories
                        .map((category) => DropdownMenuItem(
                              value: category,
                              child: Text(category),
                            ))
                        .toList(),
                    onChanged: (value) {
                      setState(() {
                        _selectedCategory = value!;
                        _filterProjects();
                      });
                    },
                  ),
                ),
                const SizedBox(width: 16),
                // 上部アクションは共通AppBarへ移設済み（未了タスク表示は設定画面へ移設）
              ],
            ),
          ),
          secondChild: const SizedBox.shrink(),
          crossFadeState: _showFilterBar
              ? CrossFadeState.showFirst
              : CrossFadeState.showSecond,
          duration: const Duration(milliseconds: 180),
        ),
        // プロジェクトリスト
        Expanded(
          child: _filteredProjects.isEmpty
              ? Center(
                  child: _isLoadingProjects
                      ? const Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(),
                            SizedBox(height: 16),
                            Text('プロジェクトを読み込み中…'),
                          ],
                        )
                      : _buildEmptyState(),
                )
              : (_allowTwoColumnLayout(context)
                  ? _buildTwoColumnGrid()
                  : ListView.builder(
                      itemCount: _filteredProjects.length,
                      itemBuilder: (context, index) {
                        final project = _filteredProjects[index];
                        return _buildProjectCard(
                          project,
                          margin: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 4,
                          ),
                        );
                      },
                    )),
        ),
      ],
    );
  }

  /// 空状態: 本当に0件か、フィルタで0件かを分けて表示
  Widget _buildEmptyState() {
    if (_projects.isNotEmpty) {
      // プロジェクトはあるがフィルタで全て非表示（例: 未実施のないプロジェクトを非表示）
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('表示するプロジェクトがありません'),
              const SizedBox(height: 8),
              Text(
                '未実施タスクがあるプロジェクトのみ表示しています。',
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
              if (_hideEmptyProjects) ...[
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () {
                    setState(() {
                      _hideEmptyProjects = false;
                      _filterProjects();
                    });
                    widget.hideEmptyProjectsNotifier?.value = false;
                  },
                  child: const Text('すべてのプロジェクトを表示'),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return const Center(child: Text('プロジェクトが見つかりません'));
  }

  Widget _buildIncompleteTasksSection(Project project) {
    final tasks = InboxTaskService.getInboxTasksByProjectId(project.id)
        .where((t) => !t.isCompleted && !t.isDeleted && t.isSomeday != true)
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    if (tasks.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Divider(color: Theme.of(context).dividerColor),
          ...tasks.map((t) {
            return InkWell(
              onTap: () async {
                final updated = await _showEditInboxTaskDialog(t);
                if (updated == true && mounted) setState(() {});
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: () async {
                        await context
                            .read<TaskProvider>()
                            .completeInboxTaskWithZeroActual(t.id);
                        if (mounted) setState(() {});
                      },
                      child: Icon(
                        Icons.check_box_outline_blank,
                        size: 22,
                        color: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.color
                            ?.withOpacity(0.7),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        t.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Theme.of(context).textTheme.bodyMedium?.color,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  Future<bool?> _showEditInboxTaskDialog(inbox.InboxTask task) async {
    return showUnifiedScreenDialog<bool>(
      context: context,
      builder: (_) => InboxTaskEditScreen(task: task),
    );
  }

  // 共通のプロジェクトカード
  Widget _buildProjectCard(Project project, {EdgeInsetsGeometry? margin}) {
    return Card(
      margin: margin,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              title: Text(
                project.name,
                style: TextStyle(
                  decoration:
                      project.isArchived ? TextDecoration.lineThrough : null,
                  color: project.isArchived
                      ? Theme.of(context).textTheme.bodySmall?.color
                      : null,
                ),
              ),
              subtitle:
                  project.description != null && project.description!.isNotEmpty
                      ? Text(
                          project.description!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        )
                      : null,
              trailing: PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert),
                onSelected: (value) => _handleProjectAction(value, project),
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'edit',
                    child: Text('編集'),
                  ),
                  const PopupMenuItem(
                    value: 'subprojects',
                    child: Text('サブプロジェクト管理'),
                  ),
                  PopupMenuItem(
                    value: project.isArchived ? 'unarchive' : 'archive',
                    child: Text(
                      project.isArchived ? 'アーカイブ解除' : 'アーカイブ',
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'delete',
                    child: Text('削除'),
                  ),
                ],
              ),
              onTap: () {
                ProjectSelectedNotification(project).dispatch(context);
              },
            ),
            if (_showIncompleteUnderProject)
              _buildIncompleteTasksSection(project),
          ],
        ),
      ),
    );
  }

  // 2列レイアウト（各列を独立して上方向に詰めて表示）
  Widget _buildTwoColumnGrid() {
    final items = _filteredProjects;
    final List<Project> leftItems = <Project>[];
    final List<Project> rightItems = <Project>[];
    double leftHeight = 0;
    double rightHeight = 0;

    // 概算高さで貪欲割当（背の高いカードは短い列へ）
    for (final p in items) {
      final h = _estimateProjectCardHeight(p);
      if (leftHeight <= rightHeight) {
        leftItems.add(p);
        leftHeight += h;
      } else {
        rightItems.add(p);
        rightHeight += h;
      }
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              children: leftItems
                  .map((p) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: _buildProjectCard(p, margin: EdgeInsets.zero),
                      ))
                  .toList(),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              children: rightItems
                  .map((p) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: _buildProjectCard(p, margin: EdgeInsets.zero),
                      ))
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }

  // プロジェクトカードの概算高さ（px）を算出
  // ベース + 未了タスク数に応じた増分で近似し、2列のバランスを改善
  double _estimateProjectCardHeight(Project project) {
    // ベース（タイトル/説明/余白など）
    double base = 96; // 約: ListTile + 余白
    // 「プロジェクトのみ」なら未了タスクを表示しないため、増分を付けない
    if (!_showIncompleteUnderProject) return base + 8;
    // 未了タスク数
    final todos = InboxTaskService.getInboxTasksByProjectId(project.id)
        .where((t) => !t.isCompleted && !t.isDeleted && t.isSomeday != true)
        .length;
    // 1タスクあたりの行高の近似
    double perTask = 24;
    // 極端な影響を抑えるため上限
    final capped = todos > 20 ? 20 : todos;
    return base + perTask * capped + 8; // 下マージン近似
  }

  void _handleProjectAction(String action, Project project) {
    switch (action) {
      case 'edit':
        _editProject(project);
        break;
      case 'subprojects':
        _manageSubProjects(project);
        break;
      case 'archive':
        _archiveProject(project);
        break;
      case 'unarchive':
        _unarchiveProject(project);
        break;
      case 'delete':
        _deleteProject(project);
        break;
    }
  }

  // void _addProject() {
  //   _showProjectDialog();
  // }

  void _editProject(Project project) {
    _showProjectDialog(project: project);
  }

  void _showProjectDialog({Project? project}) {
    final nameController = TextEditingController(text: project?.name ?? '');
    final descriptionController = TextEditingController(
      text: project?.description ?? '',
    );
    String? selectedCategory = project?.category;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(project == null ? 'プロジェクトを追加' : 'プロジェクトを編集'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: 'プロジェクト名 *',
                    hintText: 'プロジェクト名を入力',
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: descriptionController,
                  decoration: const InputDecoration(
                    labelText: '説明',
                    hintText: 'プロジェクトの説明を入力',
                  ),
                  maxLines: 3,
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String?>(
                  value: selectedCategory,
                  decoration: const InputDecoration(
                    labelText: 'カテゴリ',
                    hintText: 'カテゴリを選択',
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('カテゴリなし'),
                    ),
                    ..._availableCategories.map(
                      (category) => DropdownMenuItem<String?>(
                        value: category.name,
                        child: Text(category.name),
                      ),
                    ),
                  ],
                  onChanged: (value) {
                    setDialogState(() {
                      selectedCategory = value;
                    });
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル'),
            ),
            TextButton(
              onPressed: () async {
                if (nameController.text.trim().isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('プロジェクト名は必須です')),
                  );
                  return;
                }
                // 重複チェック（既存は警告せず再利用・UI整合のためスナックバーは出さない）
                ProjectService.getAllProjects();
                if (project == null) {
                  final name = nameController.text.trim();
                  final description = descriptionController.text.trim().isEmpty
                      ? null
                      : descriptionController.text.trim();
                  await ProjectSyncService().createProjectWithSync(
                    name,
                    description: description,
                    category: selectedCategory,
                  );
                } else {
                  // 編集
                  project.name = nameController.text.trim();
                  project.description =
                      descriptionController.text.trim().isEmpty
                          ? null
                          : descriptionController.text.trim();
                  project.category = selectedCategory;
                  project.lastModified = DateTime.now();
                  await ProjectService.updateProject(project);
                }
                Navigator.pop(context);
                // 画面を更新
                await _loadProjects();
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  void _archiveProject(Project project) async {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('プロジェクトをアーカイブ'),
        content: Text('「${project.name}」をアーカイブしますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () async {
              project.archive();
              await ProjectService.updateProject(project);
              Navigator.pop(context);
              await _loadProjects();
            },
            child: const Text('アーカイブ'),
          ),
        ],
      ),
    );
  }

  void _unarchiveProject(Project project) async {
    project.unarchive();
    await ProjectService.updateProject(project);
    await _loadProjects();
  }

  void _deleteProject(Project project) async {
    if (ProjectService.isNonDeletableProject(project.id)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('このプロジェクトは削除できません')),
        );
      }
      return;
    }
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('プロジェクトを削除'),
        content: Text('「${project.name}」を削除しますか？\nこの操作は取り消せません。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () async {
              await ProjectSyncService().deleteProjectWithSync(project.id);
              Navigator.pop(context);
              await _loadProjects();
            },
            style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error),
            child: const Text('削除'),
          ),
        ],
      ),
    );
  }

  void _manageSubProjects(Project project) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: SizedBox(
          width: 980,
          height: 640,
          child: SubProjectManagementScreen(project: project, embedded: true),
        ),
      ),
    );
  }
}
