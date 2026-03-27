// ignore_for_file: use_build_context_synchronously

import 'dart:async';
import 'package:flutter/material.dart';
import '../models/project.dart';
import '../models/sub_project.dart';
import '../models/inbox_task.dart';
import '../services/sub_project_service.dart';
import '../services/sub_project_sync_service.dart';
import '../services/inbox_task_sync_service.dart';
import '../services/actual_task_sync_service.dart';
import '../models/actual_task.dart';
import '../services/inbox_task_service.dart';
import '../services/device_info_service.dart';
import '../services/auth_service.dart';
import '../services/app_settings_service.dart';
import '../services/category_service.dart';
import '../services/task_sync_manager.dart';
import '../widgets/app_bottom_navigation_bar.dart';
import '../ui_android/main_screen.dart';
import '../services/project_sync_service.dart';
import '../widgets/app_notifications.dart';
import 'inbox_task_edit_screen.dart';
import '../utils/ime_safe_dialog.dart';
import '../utils/unified_screen_dialog.dart';

class SubProjectManagementScreen extends StatefulWidget {
  final Project project;
  final bool embedded;
  /// 埋め込み時に親（AppBar）から渡す場合のみ指定。null のときは画面内の [_showArchived] を使う。
  final bool? parentShowArchived;
  final ValueChanged<bool>? onParentShowArchivedChanged;

  const SubProjectManagementScreen({
    super.key,
    required this.project,
    this.embedded = false,
    this.parentShowArchived,
    this.onParentShowArchivedChanged,
  });

  @override
  State<SubProjectManagementScreen> createState() =>
      SubProjectManagementScreenState();
}

class SubProjectManagementScreenState extends State<SubProjectManagementScreen> {
  List<SubProject> _subProjects = [];
  List<InboxTask> _inboxTasks = [];
  List<InboxTask> _somedayTasks = [];
  bool _showArchived = false;
  bool _isLoading = true;
  bool _isSomedayExpanded = true;

  bool get _effectiveShowArchived =>
      widget.parentShowArchived ?? _showArchived;

  void _setShowArchived(bool value) {
    if (widget.onParentShowArchivedChanged != null) {
      widget.onParentShowArchivedChanged!(value);
    } else {
      setState(() => _showArchived = value);
    }
  }

  /// 親の AppBar などから呼び出し（GlobalKey 用）
  void openProjectEdit() => _showProjectEditDialog();

  Future<void> reloadData() => _loadData();

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
    });

    try {
      await _loadSubProjects();
      await _loadInboxTasks();
    } catch (e) {
      // エラーハンドリング
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _loadSubProjects() async {
    final subProjects = SubProjectService.getSubProjectsByProjectId(
      widget.project.id,
    );
    setState(() {
      _subProjects = subProjects;
    });
  }

  Future<void> _loadInboxTasks() async {
    final projectTasks =
        InboxTaskService.getInboxTasksByProjectId(widget.project.id);
    final filtered = projectTasks.where(_shouldDisplayInProjectView).toList();
    final somedayTasks = projectTasks
        .where((task) =>
            task.isSomeday == true &&
            task.isDeleted != true &&
            task.isCompleted != true)
        .toList();
    setState(() {
      _inboxTasks = filtered;
      _somedayTasks = somedayTasks;
    });
  }

  @override
  Widget build(BuildContext context) {
    // アーカイブ表示切り替えに応じてサブプロジェクトをフィルタ
    final filteredSubProjects = _subProjects
        .where((sp) => _effectiveShowArchived ? true : !sp.isArchived)
        .toList();
    final content = _isLoading
        ? const Center(child: CircularProgressIndicator())
        : Column(
            children: [
              // 親が AppBar 等で制御する場合は非表示。ダイアログ埋め込み等では従来の操作行を出す。
              if (widget.embedded && widget.parentShowArchived == null)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('アーカイブ表示',
                              style: TextStyle(fontSize: 12)),
                          const SizedBox(width: 6),
                          Switch(
                            value: _showArchived,
                            onChanged: (value) {
                              setState(() {
                                _showArchived = value;
                              });
                            },
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                        ],
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton.icon(
                        onPressed: _showProjectEditDialog,
                        icon: const Icon(Icons.edit, size: 16),
                        label:
                            const Text('編集', style: TextStyle(fontSize: 12)),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 6,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    // プロジェクト直属のタスクを常に最初に表示
                    _buildProjectDirectTasksCard(),

                      // サブプロジェクト（タスクが無いものも表示し、編集メニューに届くようにする）
                        ...filteredSubProjects.map((subProject) {
                          final subProjectTasks = _sortTasksByDueDate(
                            _inboxTasks
                                .where((task) =>
                                    task.subProjectId == subProject.id &&
                                    task.isSomeday != true &&
                                    !task.isDeleted &&
                                    !task.isCompleted)
                                .toList(),
                          );
                          return Card(
                          margin: const EdgeInsets.only(bottom: 16),
                          child: ExpansionTile(
                            initiallyExpanded: true,
                            title: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        subProject.name,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      if (subProject.description != null &&
                                          subProject.description!.isNotEmpty)
                                        Text(
                                          subProject.description!,
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: Theme.of(context)
                                                .textTheme
                                                .bodySmall
                                                ?.color,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.add_task, size: 20),
                                  tooltip: 'このセクションにタスクを追加',
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                    minWidth: 40,
                                    minHeight: 40,
                                  ),
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () => _showAddTaskDialog(
                                    initialSubProjectId: subProject.id,
                                  ),
                                ),
                                // サブプロジェクト操作メニュー
                                PopupMenuButton<String>(
                                  tooltip: MaterialLocalizations.of(context)
                                      .showMenuTooltip,
                                  icon: const Icon(Icons.more_vert, size: 18),
                                  onSelected: (value) =>
                                      _handleSubProjectAction(value, subProject),
                                  itemBuilder: (context) => [
                                    const PopupMenuItem(
                                        value: 'edit', child: Text('編集')),
                                    PopupMenuItem(
                                      value: subProject.isArchived
                                          ? 'unarchive'
                                          : 'archive',
                                      child: Text(subProject.isArchived
                                          ? 'アーカイブ解除'
                                          : 'アーカイブ'),
                                    ),
                                    PopupMenuItem(
                                      value: 'delete',
                                      child: Text('削除',
                                          style: TextStyle(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .error)),
                                    ),
                                  ],
                                ),
                                if (subProject.isArchived)
                                  Icon(
                                    Icons.archive,
                                    size: 16,
                                    color: Theme.of(context).dividerColor,
                                  ),
                              ],
                            ),
                              children: [
                                Padding(
                                  padding:
                                      const EdgeInsets.fromLTRB(16, 8, 16, 16),
                                  child: Column(
                                    children: subProjectTasks.isEmpty
                                        ? [
                                            Padding(
                                              padding: const EdgeInsets.symmetric(
                                                  vertical: 8),
                                              child: Text(
                                                'タスクがありません',
                                                style: TextStyle(
                                                  fontSize: 13,
                                                  color: Theme.of(context)
                                                      .textTheme
                                                      .bodySmall
                                                      ?.color,
                                                ),
                                              ),
                                            ),
                                          ]
                                        : subProjectTasks
                                            .map(_buildInboxTaskItem)
                                            .toList(),
                                  ),
                                ),
                              ],
                            ),
                          );
                        }),

                    const SizedBox(height: 8),
                    // いつかセクション（画面の下部に配置）
                    _buildSomedaySection(),
                    const SizedBox(height: 80),
                  ],
                ),
              ),
            ],
          );

    if (widget.embedded) {
      return Stack(
        children: [
          content,
          Positioned(
            right: 16,
            bottom: 16,
            child: FloatingActionButton(
              onPressed: _showAddChooser,
              tooltip: '追加',
              child: const Icon(Icons.add),
            ),
          ),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.project.name,
            overflow: TextOverflow.ellipsis, maxLines: 1),
        actions: [
          IconButton(
            tooltip: _effectiveShowArchived
                ? 'アーカイブ済みを表示中（タップで隠す）'
                : 'アーカイブ済みを表示',
            onPressed: () =>
                _setShowArchived(!_effectiveShowArchived),
            icon: Icon(
              _effectiveShowArchived ? Icons.archive : Icons.archive_outlined,
            ),
          ),
          IconButton(
            tooltip: 'プロジェクトを編集',
            onPressed: _showProjectEditDialog,
            icon: const Icon(Icons.edit),
          ),
          IconButton(
            tooltip: '再読込',
            onPressed: _loadData,
            icon: const Icon(Icons.refresh),
          ),
        ],
        toolbarHeight: 48,
      ),
      body: content,
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddChooser,
        tooltip: '追加',
        child: const Icon(Icons.add),
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

  void _showAddTaskDialog({String? initialSubProjectId}) {
    final titleController = TextEditingController();
    final detailsController = TextEditingController();
    final memoController = TextEditingController();
    DateTime? selectedDueDate;
    String? selectedSubProjectId = initialSubProjectId;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('タスク追加'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: titleController,
                      decoration: const InputDecoration(
                        labelText: 'タスク名',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: detailsController,
                      decoration: const InputDecoration(
                        labelText: '詳細（任意）',
                        border: OutlineInputBorder(),
                      ),
                      maxLines: 2,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: memoController,
                      decoration: const InputDecoration(
                        labelText: 'メモ（任意）',
                        border: OutlineInputBorder(),
                      ),
                      maxLines: 2,
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.event),
                            label: Text(
                              selectedDueDate == null
                                  ? '期限日を選択（任意）'
                                  : '${selectedDueDate!.year}/${selectedDueDate!.month.toString().padLeft(2, '0')}/${selectedDueDate!.day.toString().padLeft(2, '0')}',
                            ),
                            onPressed: () async {
                              final now = DateTime.now();
                              final picked = await showDatePicker(
                                context: context,
                                initialDate: selectedDueDate ?? now,
                                firstDate: DateTime(2000),
                                lastDate: DateTime(2100),
                              );
                              if (picked != null) {
                                setState(() => selectedDueDate = picked);
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String?>(
                      value: selectedSubProjectId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'サブプロジェクト（任意）',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('未指定'),
                        ),
                        ..._subProjects
                            .where(
                                (sp) => !_showArchived ? !sp.isArchived : true)
                            .map(
                              (sp) => DropdownMenuItem<String?>(
                                value: sp.id,
                                child: Text(sp.name),
                              ),
                            ),
                      ],
                      onChanged: (val) =>
                          setState(() => selectedSubProjectId = val),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('キャンセル'),
                ),
                ElevatedButton(
                  onPressed: titleController.text.trim().isEmpty
                      ? null
                      : () async {
                          try {
                            await InboxTaskSyncService().createTaskWithSync(
                              title: titleController.text.trim(),
                              memo: memoController.text.trim().isEmpty
                                  ? null
                                  : memoController.text.trim(),
                              projectId: widget.project.id,
                              subProjectId: selectedSubProjectId,
                              dueDate: selectedDueDate,
                              executionDate: DateTime.now(),
                              startHour: null,
                              startMinute: null,
                              estimatedDuration: AppSettingsService.getInt(
                                AppSettingsService.keyTaskDefaultEstimatedMinutes,
                                defaultValue: 0,
                              ),
                              blockId: null,
                            );
                            await _loadData();
                            if (mounted) Navigator.of(context).pop();
                          } catch (e) {
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('タスク追加に失敗しました: $e'),
                                  backgroundColor:
                                      Theme.of(context).colorScheme.error,
                                ),
                              );
                            }
                          }
                        },
                  child: const Text('追加'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showAddChooser() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.checklist),
                title: const Text('タスクを追加'),
                onTap: () {
                  Navigator.of(context).pop();
                  _showAddTaskDialog();
                },
              ),
              ListTile(
                leading: const Icon(Icons.create_new_folder),
                title: const Text('サブプロジェクトを追加'),
                onTap: () {
                  Navigator.of(context).pop();
                  _showAddSubProjectDialog();
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Widget _buildInboxTaskItem(InboxTask task) {
    final theme = Theme.of(context);
    final titleStyle = TextStyle(
      fontSize: 14,
      decoration: task.isCompleted ? TextDecoration.lineThrough : null,
      fontWeight: task.isCompleted ? FontWeight.normal : FontWeight.w500,
      color: theme.textTheme.bodyMedium?.color,
    );
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: theme.dividerColor, width: 1),
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () async {
            final updated = await showUnifiedScreenDialog<bool>(
              context: context,
              builder: (_) => InboxTaskEditScreen(task: task),
            );
            if (updated == true) {
              await _loadInboxTasks();
            }
          },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                GestureDetector(
                  onTap: () async {
                    if (!task.isCompleted) {
                      await _completeTaskWithZeroActual(task);
                    }
                  },
                  behavior: HitTestBehavior.opaque,
                  child: SizedBox(
                    width: 28,
                    height: 28,
                    child: Center(
                      child: Icon(
                        task.isCompleted
                            ? Icons.check_box
                            : Icons.check_box_outline_blank,
                        color: task.isCompleted
                            ? theme.colorScheme.secondary
                            : theme.textTheme.bodySmall?.color,
                        size: 22,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      _buildPlannedDateBadge(context, task),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          task.title,
                          style: titleStyle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert, size: 18),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                  onSelected: (value) => _handleInboxTaskAction(value, task),
                  itemBuilder: (context) => [
                    const PopupMenuItem(value: 'edit', child: Text('編集')),
                    const PopupMenuItem(value: 'done', child: Text('実施済にする')),
                    const PopupMenuItem(value: 'delete', child: Text('削除')),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPlannedDateBadge(BuildContext context, InboxTask task) {
    final theme = Theme.of(context);
    final DateTime? scheduled = _plannedDateTime(task);
    final bool isSomeday = task.isSomeday == true;
    final bool isUnset = scheduled == null;
    final bool isOverdue =
        scheduled != null && scheduled.isBefore(DateTime.now());
    final label = isSomeday
        ? 'いつか'
        : isUnset
            ? '未定'
            : _formatPlannedLabel(task, scheduled);

    final Color bgColor = isUnset
        ? theme.colorScheme.surfaceVariant
        : theme.colorScheme.surfaceContainerHigh;
    final Color borderColor = isOverdue
        ? theme.colorScheme.error
        : theme.dividerColor.withOpacity( 0.6);
    final Color textColor = isOverdue
        ? theme.colorScheme.error
        : theme.textTheme.bodySmall?.color ??
            theme.colorScheme.onSurfaceVariant;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: textColor,
        ),
      ),
    );
  }

  void _handleInboxTaskAction(String action, InboxTask task) {
    switch (action) {
      case 'edit':
        _showEditInboxTaskDialog(task);
        break;
      case 'done':
        _completeTaskWithZeroActual(task);
        break;
      case 'delete':
        _showDeleteInboxTaskDialog(task);
        break;
    }
  }

  Future<void> _completeTaskWithZeroActual(InboxTask task) async {
    try {
      // 0分の実績タスクを作成（start=end=now, completed）
      final svc = ActualTaskSyncService();
      final created = await svc.createTaskWithSync(
        title: task.title,
        projectId: widget.project.id,
        memo: task.memo,
        subProjectId: task.subProjectId,
        subProject: null,
        modeId: null,
        blockName: null,
      );
      final zeroEnd = created.startTime;
      final completed = created.copyWith(
        status: ActualTaskStatus.completed,
        endTime: zeroEnd,
        actualDuration: 0,
        lastModified: DateTime.now(),
        version: created.version + 1,
      );
      await svc.updateTaskWithSync(completed);

      // インボックスタスクを完了
      final now = DateTime.now();
      final completedInbox = task.copyWith(
        isCompleted: true,
        endTime: now,
      );
      try {
        completedInbox.markAsModified(await DeviceInfoService.getDeviceId());
      } catch (_) {}
      await InboxTaskService.updateInboxTask(completedInbox);
      unawaited(
          TaskSyncManager.syncInboxTaskImmediately(completedInbox, 'update'));

      await _loadInboxTasks();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('実施済みにしました（0分の実績を作成）')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('実施済み処理に失敗しました: $e')),
        );
      }
    }
  }

  void _handleSubProjectAction(String action, SubProject subProject) {
    switch (action) {
      case 'edit':
        _showEditSubProjectDialog(subProject);
        break;
      case 'archive':
        _archiveSubProject(subProject, true);
        break;
      case 'unarchive':
        _archiveSubProject(subProject, false);
        break;
      case 'delete':
        _showDeleteSubProjectDialog(subProject);
        break;
    }
  }

  void _showAddSubProjectDialog() {
    final nameController = TextEditingController();
    final descriptionController = TextEditingController();

    showImeSafeDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('サブプロジェクト追加'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: '名前',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: descriptionController,
              decoration: const InputDecoration(
                labelText: '説明（任意）',
                border: OutlineInputBorder(),
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
          TextButton(
            onPressed: () async {
              if (nameController.text.trim().isNotEmpty) {
                final now = DateTime.now();
                final newSubProject = SubProject(
                  id: now.millisecondsSinceEpoch.toString(),
                  name: nameController.text.trim(),
                  description: descriptionController.text.trim().isEmpty
                      ? null
                      : descriptionController.text.trim(),
                  projectId: widget.project.id,
                  createdAt: now,
                  lastModified: now,
                  userId: AuthService.getCurrentUserId() ?? '',
                  isArchived: false,
                );
                await SubProjectService.addSubProject(newSubProject);
                await _loadSubProjects();
                Navigator.of(context).pop();
              }
            },
            child: const Text('追加'),
          ),
        ],
      ),
    );
  }

  Future<void> _showEditInboxTaskDialog(InboxTask task) async {
    final updated = await showUnifiedScreenDialog<bool>(
      context: context,
      builder: (_) => InboxTaskEditScreen(task: task),
    );
    if (updated == true) {
      await _loadInboxTasks();
    }
  }

  void _showDeleteInboxTaskDialog(InboxTask task) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('タスク削除'),
        content: Text('「${task.title}」を削除しますか？\nこの操作は取り消せません。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () async {
              await InboxTaskSyncService().deleteTaskWithSync(task.id);
              await _loadInboxTasks();
              Navigator.of(context).pop();
            },
            style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error),
            child: const Text('削除'),
          ),
        ],
      ),
    );
  }

  void _showEditSubProjectDialog(SubProject subProject) {
    final nameController = TextEditingController(text: subProject.name);
    final descriptionController =
        TextEditingController(text: subProject.description ?? '');

    showImeSafeDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('サブプロジェクト編集'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: '名前',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: descriptionController,
              decoration: const InputDecoration(
                labelText: '説明（任意）',
                border: OutlineInputBorder(),
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
          TextButton(
            onPressed: () async {
              if (nameController.text.trim().isNotEmpty) {
                final updatedSubProject = subProject.copyWith(
                  name: nameController.text.trim(),
                  description: descriptionController.text.trim().isEmpty
                      ? null
                      : descriptionController.text.trim(),
                  lastModified: DateTime.now(),
                );
                await SubProjectService.updateSubProject(updatedSubProject);
                await _loadSubProjects();
                Navigator.of(context).pop();
              }
            },
            child: const Text('更新'),
          ),
        ],
      ),
    );
  }

  Future<void> _archiveSubProject(
      SubProject subProject, bool isArchived) async {
    final updatedSubProject = subProject.copyWith(
      isArchived: isArchived,
      lastModified: DateTime.now(),
    );
    await SubProjectService.updateSubProject(updatedSubProject);
    await _loadSubProjects();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content:
            Text(isArchived ? 'サブプロジェクトをアーカイブしました' : 'サブプロジェクトのアーカイブを解除しました'),
      ),
    );
  }

  void _showDeleteSubProjectDialog(SubProject subProject) {
    // このサブプロジェクトに関連するタスク数を確認
    final relatedTasks = _inboxTasks
        .where((task) => task.subProjectId == subProject.id)
        .toList();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('サブプロジェクト削除'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('「${subProject.name}」を削除しますか？'),
            const SizedBox(height: 8),
            if (relatedTasks.isNotEmpty) ...[
              Text(
                '⚠️ このサブプロジェクトには${relatedTasks.length}個のタスクが含まれています。',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.tertiary,
                    fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text('削除すると、関連するすべてのタスクも削除されます。'),
              const SizedBox(height: 8),
            ],
            Text('この操作は取り消せません。',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontWeight: FontWeight.bold)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () async {
              // 関連するタスクをすべて削除
              for (final task in relatedTasks) {
                await InboxTaskSyncService().deleteTaskWithSync(task.id);
              }

              // サブプロジェクトを削除（Firebaseへも反映）
              await SubProjectSyncService()
                  .deleteSubProjectWithSync(subProject.id);

              await _loadSubProjects();
              await _loadInboxTasks();

              Navigator.of(context).pop();

              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('サブプロジェクト「${subProject.name}」を削除しました'),
                ),
              );
            },
            style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error),
            child: const Text('削除'),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.year}/${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')}';
  }

  String _formatShortDate(DateTime date) {
    return '${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')}';
  }

  String _formatPlannedLabel(
      InboxTask task, DateTime plannedDateTime) {
    final dateText = _formatShortDate(plannedDateTime);
    final hasStart = task.startHour != null && task.startMinute != null;
    if (!hasStart) return dateText;
    final hh = plannedDateTime.hour.toString().padLeft(2, '0');
    final mm = plannedDateTime.minute.toString().padLeft(2, '0');
    return '$dateText $hh:$mm';
  }

  DateTime? _plannedDateTime(InboxTask task) {
    if (task.startHour != null && task.startMinute != null) {
      return DateTime(
        task.executionDate.year,
        task.executionDate.month,
        task.executionDate.day,
        task.startHour!,
        task.startMinute!,
      );
    }
    if (task.dueDate != null) {
      return DateTime(
        task.dueDate!.year,
        task.dueDate!.month,
        task.dueDate!.day,
        23,
        59,
      );
    }
    return null;
  }

  List<InboxTask> _sortTasksByDueDate(List<InboxTask> tasks) {
    final sorted = [...tasks];
    sorted.sort(_compareTasksByDueDate);
    return sorted;
  }

  int _compareTasksByDueDate(InboxTask a, InboxTask b) {
    final DateTime? aDate = a.dueDate;
    final DateTime? bDate = b.dueDate;
    if (aDate == null && bDate == null) {
      final execCompare = a.executionDate.compareTo(b.executionDate);
      if (execCompare != 0) return execCompare;
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    }
    if (aDate == null) return -1;
    if (bDate == null) return 1;
    final cmp = aDate.compareTo(bDate);
    if (cmp != 0) return cmp;
    final execCompare = a.executionDate.compareTo(b.executionDate);
    if (execCompare != 0) return execCompare;
    return a.title.toLowerCase().compareTo(b.title.toLowerCase());
  }

  bool _shouldDisplayInProjectView(InboxTask task) {
    if (task.isDeleted == true) return false;
    if (task.isCompleted == true) return false;
    if (task.isSomeday == true) return false;
    return true;
  }

  void _showProjectEditDialog() {
    final nameController = TextEditingController(text: widget.project.name);
    String? selectedCategory = widget.project.category;
    final categories = CategoryService.getCurrentUserCategories();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('プロジェクト編集'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                  labelText: 'プロジェクト名', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String?>(
              value: selectedCategory,
              decoration: const InputDecoration(
                  labelText: 'カテゴリ', border: OutlineInputBorder()),
              items: [
                const DropdownMenuItem<String?>(
                    value: null, child: Text('カテゴリなし')),
                ...categories.map((c) => DropdownMenuItem<String?>(
                    value: c.name, child: Text(c.name))),
              ],
              onChanged: (val) => selectedCategory = val,
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル')),
          TextButton(
            onPressed: () async {
              final newName = nameController.text.trim();
              if (newName.isNotEmpty) {
                widget.project.name = newName;
                widget.project.category = selectedCategory;
                widget.project.lastModified = DateTime.now();
                await ProjectSyncService()
                    .updateProjectWithSync(widget.project);
                if (mounted) {
                  setState(() {});
                  // AppBarタイトルなど即時反映のため通知
                  ProjectUpdatedNotification(widget.project).dispatch(context);
                }
                Navigator.pop(context);
              }
            },
            child: const Text('保存'),
          )
        ],
      ),
    );
  }

  Widget _buildProjectDirectTasksCard() {
    // プロジェクトに直接属するタスク（subProjectIdがnullまたは空）を取得
    final projectDirectTasks = _sortTasksByDueDate(
      _inboxTasks
          .where((task) =>
              (task.subProjectId == null ||
                  (task.subProjectId != null && task.subProjectId!.isEmpty)) &&
              task.isSomeday != true &&
              !task.isDeleted &&
              !task.isCompleted)
          .toList(),
    );

    if (projectDirectTasks.isEmpty) {
      return const SizedBox.shrink();
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: ExpansionTile(
        initiallyExpanded: true,
        title: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${widget.project.name} （プロジェクト全般）',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.add_task, size: 20),
              tooltip: 'このセクションにタスクを追加',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(
                minWidth: 40,
                minHeight: 40,
              ),
              visualDensity: VisualDensity.compact,
              onPressed: () => _showAddTaskDialog(initialSubProjectId: null),
            ),
          ],
        ),
        children: [
          Container(
            margin: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context)
                  .colorScheme
                  .surfaceContainerHighest
                  .withOpacity(Theme.of(context).brightness == Brightness.light
                          ? 1
                          : 0.2),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: Theme.of(context).dividerColor,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                children: projectDirectTasks
                    .map(
                      (task) => _buildInboxTaskItem(task),
                    )
                    .toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSomedaySection() {
    final somedayTasks = _sortTasksByDueDate(_somedayTasks);
    if (somedayTasks.isEmpty) return const SizedBox.shrink();

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: ExpansionTile(
        key: const PageStorageKey('someday-section'),
        initiallyExpanded: _isSomedayExpanded,
        maintainState: true,
        onExpansionChanged: (expanded) {
          setState(() => _isSomedayExpanded = expanded);
        },
        trailing: AnimatedRotation(
          turns: _isSomedayExpanded ? 0.5 : 0.0,
          duration: const Duration(milliseconds: 200),
          child: const Icon(Icons.expand_more),
        ),
        title: const Text(
          'いつか',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        children: [
          Container(
            margin: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(Theme.of(context).brightness == Brightness.light ? 1 : 0.2),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Theme.of(context).dividerColor),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                children: somedayTasks.map(_buildInboxTaskItem).toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
