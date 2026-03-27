import 'package:flutter/material.dart';
import 'dart:async';
import 'package:provider/provider.dart';
import '../../models/inbox_task.dart' as inbox;
import '../../models/actual_task.dart' as actual;
import '../../models/project.dart';
import '../../models/sub_project.dart';
import '../../providers/task_provider.dart';
import '../../services/project_service.dart';
import '../../services/project_sync_service.dart';
import '../../services/selection_frequency_service.dart';
import '../../services/sub_project_service.dart';
import '../../utils/text_normalizer.dart';

class RunningTaskBar extends StatefulWidget {
  final dynamic runningTask; // InboxTaskまたはActualTaskを受け取る
  final VoidCallback onPause;
  final VoidCallback onComplete;

  const RunningTaskBar({
    super.key,
    required this.runningTask,
    required this.onPause,
    required this.onComplete,
  });

  @override
  State<RunningTaskBar> createState() => _RunningTaskBarState();
}

class _RunningTaskBarState extends State<RunningTaskBar> {
  Timer? _timer;
  final TextEditingController _titleController = TextEditingController();
  final FocusNode _titleFocusNode = FocusNode();
  bool _isEditingTitle = false;
  bool _titleDirty = false;
  String _titleBaseline = '';
  String? _titleTaskId;
  final LayerLink _projectPickerLink = LayerLink();
  OverlayEntry? _projectPickerOverlay;
  TextEditingController? _projectPickerController;
  final LayerLink _subProjectPickerLink = LayerLink();
  OverlayEntry? _subProjectPickerOverlay;

  Color _barBackgroundColor(ThemeData theme) {
    final scheme = theme.colorScheme;
    final base = theme.scaffoldBackgroundColor;

    if (theme.brightness == Brightness.light) {
      // ライト系は背景色にごく薄い中立色を重ね、テーマ固有の色相を抑える。
      return Color.alphaBlend(scheme.onSurface.withOpacity(0.03), base);
    }

    // ダーク系も同様に中立寄りへ。
    return Color.alphaBlend(scheme.onSurface.withOpacity(0.08), base);
  }

  @override
  void initState() {
    super.initState();
    _startTimer();
    _syncTitleController(force: true);
    _titleFocusNode.addListener(_handleTitleFocusChange);
  }

  @override
  void didUpdateWidget(covariant RunningTaskBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTitleController();
    if (oldWidget.runningTask != widget.runningTask) {
      _removeProjectPicker();
      _removeSubProjectPicker();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _titleFocusNode.removeListener(_handleTitleFocusChange);
    _titleFocusNode.dispose();
    _titleController.dispose();
    _removeProjectPicker();
    _removeSubProjectPicker();
    super.dispose();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {}); // 毎秒再描画して現在時刻/経過時間を更新
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final startTime = _getStartTime();
    final now = DateTime.now();
    final elapsed =
        startTime != null ? now.difference(startTime) : Duration.zero;
    final taskTitle = _getTaskTitle();
    final projectId = _getProjectId();
    final projectName = _getProjectName();
    final subProjectName = _getSubProjectName();
    final bool canEditProject = widget.runningTask is actual.ActualTask;
    final bool hasProject = projectId != null && projectId.isNotEmpty;
    final bool hasSubProject =
        (widget.runningTask is actual.ActualTask) &&
        ((widget.runningTask as actual.ActualTask).subProjectId != null) &&
        ((widget.runningTask as actual.ActualTask).subProjectId!.isNotEmpty);
    final foregroundColor = scheme.onSurface;
    Color folderPickerIconColor(bool hasSelection) => hasSelection
        ? scheme.primary
        : foregroundColor.withOpacity(0.45);
    final projectIconColor = folderPickerIconColor(hasProject);
    final subProjectIconColor = folderPickerIconColor(hasSubProject);
    final titleStyle = TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.bold,
      color: foregroundColor,
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: _barBackgroundColor(theme),
      child: DefaultTextStyle(
        style: theme.textTheme.bodyMedium?.copyWith(
              color: foregroundColor,
            ) ??
            TextStyle(color: foregroundColor),
        child: IconTheme(
          data: theme.iconTheme.copyWith(color: foregroundColor),
          child: Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Icon(
                      Icons.stop_circle,
                      color: scheme.primary,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildTitleEditor(taskTitle, titleStyle),
                    ),
                    const SizedBox(width: 8),
                    CompositedTransformTarget(
                      link: _projectPickerLink,
                      child: IconButton(
                        tooltip: hasProject
                            ? 'プロジェクト: ${projectName ?? '不明'}'
                            : 'プロジェクトを選択',
                        onPressed: canEditProject ? _toggleProjectPicker : null,
                        icon: const Icon(Icons.folder),
                        iconSize: 20,
                        color: projectIconColor,
                        disabledColor: projectIconColor,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 36),
                      ),
                    ),
                    if (canEditProject && hasProject) ...[
                      const SizedBox(width: 2),
                      CompositedTransformTarget(
                        link: _subProjectPickerLink,
                        child: IconButton(
                          tooltip: hasSubProject
                              ? 'サブプロジェクト: ${subProjectName ?? '不明'}'
                              : 'サブプロジェクトを選択',
                          onPressed: _toggleSubProjectPicker,
                          icon: const Icon(Icons.folder_open),
                          iconSize: 20,
                          color: subProjectIconColor,
                          disabledColor: subProjectIconColor,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 36),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Row(
                children: [
                  Icon(Icons.timer, size: 16, color: foregroundColor),
                  const SizedBox(width: 6),
                  Text(
                    _formatDuration(elapsed),
                    style: TextStyle(
                      fontSize: 14,
                      color: foregroundColor,
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 16),
              ElevatedButton.icon(
                onPressed: widget.onPause,
                icon: const Icon(Icons.pause, size: 18),
                label: const Text('中断'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.tertiary,
                  foregroundColor: Theme.of(context).colorScheme.onTertiary,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  minimumSize: const Size(0, 36),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: widget.onComplete,
                icon: const Icon(Icons.check, size: 18),
                label: const Text('完了'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.secondary,
                  foregroundColor: Theme.of(context).colorScheme.onSecondary,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  minimumSize: const Size(0, 36),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // (未使用) タイトル取得ヘルパーは現状未使用のため削除

  // タスクの種類に応じてstartTimeを取得
  DateTime? _getStartTime() {
    if (widget.runningTask is actual.ActualTask) {
      return (widget.runningTask as actual.ActualTask).startTime;
    } else if (widget.runningTask is inbox.InboxTask) {
      final t = widget.runningTask as inbox.InboxTask;
      if (t.startHour != null && t.startMinute != null) {
        final d = t.executionDate;
        return DateTime(d.year, d.month, d.day, t.startHour!, t.startMinute!);
      }
      return null;
    }
    return null;
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  Widget _buildTitleEditor(String fallbackTitle, TextStyle style) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final foregroundColor = scheme.onSurface;

    if (widget.runningTask is! actual.ActualTask) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
        child: Text(
          fallbackTitle,
          style: style,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      );
    }

    final bool isEditing = _titleFocusNode.hasFocus;

    // 背景と同化し、線1本の枠だけで区切る（タイムライン実績表示に合わせたスタイル）
    return GestureDetector(
      onTap: () {
        _titleFocusNode.requestFocus();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: isEditing
                ? scheme.primary.withOpacity(0.5)
                : foregroundColor.withOpacity(0.2),
            width: 1,
          ),
        ),
        child: TextField(
          controller: _titleController,
          focusNode: _titleFocusNode,
          maxLines: 1,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            isCollapsed: true,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            errorBorder: InputBorder.none,
            disabledBorder: InputBorder.none,
            filled: false,
            contentPadding: EdgeInsets.zero,
            hintText: '実行中のタスク',
            hintStyle: style.copyWith(
              fontWeight: FontWeight.w500,
              color: style.color?.withOpacity(0.6),
            ),
          ),
          style: style,
          onChanged: (value) {
            if (!_isEditingTitle) return;
            _titleDirty = value != _titleBaseline;
          },
          onSubmitted: (_) {
            _commitTitle();
            _titleFocusNode.unfocus();
          },
          onEditingComplete: _commitTitle,
        ),
      ),
    );
  }

  void _handleTitleFocusChange() {
    if (_titleFocusNode.hasFocus) {
      _isEditingTitle = true;
      _titleBaseline = _titleController.text;
      _titleDirty = false;
      if (mounted) setState(() {});
      return;
    }
    if (_isEditingTitle) {
      _isEditingTitle = false;
      _commitTitle();
    }
    if (mounted) setState(() {});
  }

  void _syncTitleController({bool force = false}) {
    // 編集用には実際の task.title のみ同期（空のときは ''）。「実行中のタスク」は hint 表示のみで保存しない
    final nextTitle = widget.runningTask is actual.ActualTask
        ? (widget.runningTask as actual.ActualTask).title
        : _getTaskTitle();
    final taskId = widget.runningTask is actual.ActualTask
        ? (widget.runningTask as actual.ActualTask).id
        : null;
    final taskChanged = taskId != _titleTaskId;
    if (force || taskChanged) {
      _titleController.text = nextTitle;
      _titleBaseline = nextTitle;
      _titleDirty = false;
      _titleTaskId = taskId;
      return;
    }
    if (!_isEditingTitle && nextTitle != _titleBaseline) {
      _titleController.text = nextTitle;
      _titleBaseline = nextTitle;
      _titleDirty = false;
    }
  }

  Future<void> _commitTitle() async {
    if (!_titleDirty || widget.runningTask is! actual.ActualTask) {
      return;
    }
    final task = widget.runningTask as actual.ActualTask;
    final trimmed = _titleController.text.trim();
    if (trimmed == _titleBaseline) {
      _titleDirty = false;
      return;
    }
    if (trimmed == task.title) {
      _titleDirty = false;
      _titleBaseline = _titleController.text;
      return;
    }
    task.title = trimmed;
    _titleDirty = false;
    _titleBaseline = trimmed;
    await context.read<TaskProvider>().updateActualTask(task);
  }

  void _toggleProjectPicker() {
    if (_projectPickerOverlay != null) {
      _removeProjectPicker();
      return;
    }
    _showProjectPicker();
  }

  void _showProjectPicker() {
    if (widget.runningTask is! actual.ActualTask) return;
    _removeProjectPicker();
    final controller = TextEditingController(text: _getProjectName() ?? '');
    _projectPickerController = controller;
    final overlay = Overlay.of(context);
    _projectPickerOverlay = OverlayEntry(
      builder: (context) {
        return _ProjectPickerOverlay(
          link: _projectPickerLink,
          controller: controller,
          onClose: _removeProjectPicker,
          onSelectProject: (projectId) async {
            _removeProjectPicker();
            await _applyProjectSelection(projectId);
          },
          onCreateProject: (name) async {
            _removeProjectPicker();
            final created = await _createProject(name);
            if (created != null) {
              await _applyProjectSelection(created.id);
            }
          },
          selectedProjectName: _getProjectName(),
          onClearProject: () {
            // クリア後もピッカーを開いたままにし、別プロジェクトを続けて選べるようにする
            Future<void>(() async {
              await _applyProjectSelection(null);
              if (!mounted) return;
              _projectPickerController?.clear();
              _projectPickerOverlay?.markNeedsBuild();
            });
          },
        );
      },
    );
    overlay.insert(_projectPickerOverlay!);
  }

  void _removeProjectPicker() {
    _projectPickerOverlay?.remove();
    _projectPickerOverlay = null;
    _projectPickerController?.dispose();
    _projectPickerController = null;
  }

  Future<void> _applyProjectSelection(String? projectId) async {
    if (widget.runningTask is! actual.ActualTask) return;
    _removeSubProjectPicker();
    final task = widget.runningTask as actual.ActualTask;
    final normalized = (projectId == null || projectId.isEmpty)
        ? null
        : projectId;
    if (normalized == task.projectId) return;
    task.projectId = normalized;
    task.subProjectId = null;
    task.subProject = null;
    await context.read<TaskProvider>().updateActualTask(task);
  }

  Future<Project?> _createProject(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    try {
      return await ProjectSyncService().createProjectWithSync(trimmed);
    } catch (_) {
      return null;
    }
  }

  String? _getProjectId() {
    if (widget.runningTask is! actual.ActualTask) return null;
    return (widget.runningTask as actual.ActualTask).projectId;
  }

  String? _getProjectName() {
    final projectId = _getProjectId();
    if (projectId == null || projectId.isEmpty) return null;
    return ProjectService.getProjectById(projectId)?.name;
  }

  String? _getSubProjectName() {
    if (widget.runningTask is! actual.ActualTask) return null;
    final task = widget.runningTask as actual.ActualTask;
    final id = task.subProjectId;
    if (id == null || id.isEmpty) return task.subProject; // 表示名が残っている場合
    return SubProjectService.getSubProjectById(id)?.name ?? task.subProject;
  }

  void _toggleSubProjectPicker() {
    if (_subProjectPickerOverlay != null) {
      _removeSubProjectPicker();
      return;
    }
    _showSubProjectPicker();
  }

  void _showSubProjectPicker() {
    if (widget.runningTask is! actual.ActualTask) return;
    final projectId = _getProjectId();
    if (projectId == null || projectId.isEmpty) return;
    _removeSubProjectPicker();
    final overlay = Overlay.of(context);
    _subProjectPickerOverlay = OverlayEntry(
      builder: (context) {
        return _SubProjectPickerOverlay(
          link: _subProjectPickerLink,
          projectId: projectId,
          onClose: _removeSubProjectPicker,
          onSelectSubProject: (subProjectId, subProjectName) async {
            _removeSubProjectPicker();
            await _applySubProjectSelection(subProjectId, subProjectName);
          },
          selectedSubProjectName: _getSubProjectName(),
          onClearSubProject: () {
            _removeSubProjectPicker();
            _applySubProjectSelection(null, null);
          },
        );
      },
    );
    overlay.insert(_subProjectPickerOverlay!);
  }

  void _removeSubProjectPicker() {
    _subProjectPickerOverlay?.remove();
    _subProjectPickerOverlay = null;
  }

  Future<void> _applySubProjectSelection(
      String? subProjectId, String? subProjectName) async {
    if (widget.runningTask is! actual.ActualTask) return;
    final task = widget.runningTask as actual.ActualTask;
    final normalizedId = (subProjectId == null || subProjectId.isEmpty)
        ? null
        : subProjectId;
    final normalizedName = (subProjectName == null || subProjectName.isEmpty)
        ? null
        : subProjectName.trim();
    if (normalizedId == task.subProjectId && normalizedName == task.subProject) {
      return;
    }
    task.subProjectId = normalizedId;
    task.subProject = normalizedName;
    await context.read<TaskProvider>().updateActualTask(task);
  }

  String _getTaskTitle() {
    const fallback = '実行中のタスク';
    if (widget.runningTask is actual.ActualTask) {
      final task = widget.runningTask as actual.ActualTask;
      final title = task.title.trim();
      if (title.isNotEmpty) return title;
      final blockName = task.blockName?.trim();
      if (blockName != null && blockName.isNotEmpty) return blockName;
      if (task.memo != null && task.memo!.trim().isNotEmpty) {
        return task.memo!.trim();
      }
    } else if (widget.runningTask is inbox.InboxTask) {
      final task = widget.runningTask as inbox.InboxTask;
      final title = task.title.trim();
      if (title.isNotEmpty) return title;
      if (task.memo != null && task.memo!.trim().isNotEmpty) {
        return task.memo!.trim();
      }
    }
    return fallback;
  }
}

class _ProjectPickerOverlay extends StatefulWidget {
  final LayerLink link;
  final TextEditingController controller;
  final VoidCallback onClose;
  final ValueChanged<String?> onSelectProject;
  final ValueChanged<String> onCreateProject;
  final String? selectedProjectName;
  final VoidCallback? onClearProject;

  const _ProjectPickerOverlay({
    required this.link,
    required this.controller,
    required this.onClose,
    required this.onSelectProject,
    required this.onCreateProject,
    this.selectedProjectName,
    this.onClearProject,
  });

  @override
  State<_ProjectPickerOverlay> createState() => _ProjectPickerOverlayState();
}

class _ProjectPickerOverlayState extends State<_ProjectPickerOverlay> {
  late List<Project> _allProjects;

  @override
  void initState() {
    super.initState();
    _allProjects = ProjectService.getAllProjects()
        .where((p) => p.isDeleted != true)
        .toList();
    widget.controller.addListener(_handleQueryChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleQueryChanged);
    super.dispose();
  }

  void _handleQueryChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screenWidth = MediaQuery.of(context).size.width;
    final double pickerWidth = screenWidth < 380
        ? (screenWidth - 24).clamp(220.0, 360.0).toDouble()
        : 360.0;
    final query = widget.controller.text.trim();
    final queryLower = query.toLowerCase();
    final active = _allProjects.where((p) => !p.isArchived).toList();
    List<Project> filter(List<Project> list) {
      if (query.isEmpty) return list;
      return list.where((p) => matchesQuery(p.name, queryLower)).toList();
    }

    final activeFiltered = filter(active);
    void sortProjectsByFrequency(List<Project> list) {
      list.sort((a, b) {
        final fa = SelectionFrequencyService.getProjectCount(a.id);
        final fb = SelectionFrequencyService.getProjectCount(b.id);
        if (fb != fa) return fb.compareTo(fa);
        return a.name.compareTo(b.name);
      });
    }

    sortProjectsByFrequency(activeFiltered);
    final hasExact =
        active.any((p) => p.name.trim().toLowerCase() == queryLower && query.isNotEmpty);

    // アーカイブ済みは表示しない（選択候補はアクティブのみ）
    final options = <_ProjectOption>[
      if (!hasExact && query.isNotEmpty)
        _ProjectOption.create(label: '$query を登録する', rawInput: query),
      ...activeFiltered.map(_ProjectOption.project),
    ];

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: widget.onClose,
          ),
        ),
        CompositedTransformFollower(
          link: widget.link,
          showWhenUnlinked: false,
          targetAnchor: Alignment.topRight,
          followerAnchor: Alignment.bottomRight,
          offset: const Offset(0, -8),
          child: Material(
            color: Colors.transparent,
            elevation: 8,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              width: pickerWidth,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.cardColor,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: theme.dividerColor),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'プロジェクトを選択',
                    style: theme.textTheme.labelLarge,
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: widget.controller,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: '検索',
                      suffixIcon: (widget.selectedProjectName != null &&
                              widget.selectedProjectName!.isNotEmpty)
                          ? IconButton(
                              icon: Icon(
                                Icons.cancel,
                                size: 20,
                                color: theme.colorScheme.outline,
                              ),
                              tooltip: 'プロジェクトをクリア',
                              onPressed: () {
                                widget.onClearProject?.call();
                              },
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 36,
                                minHeight: 36,
                              ),
                            )
                          : null,
                    ),
                    textInputAction: TextInputAction.search,
                  ),
                  const SizedBox(height: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 240),
                    child: options.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Text(
                              '候補がありません',
                              style: theme.textTheme.bodySmall,
                            ),
                          )
                        : ListView.separated(
                            shrinkWrap: true,
                            itemCount: options.length,
                            separatorBuilder: (_, __) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final option = options[index];
                              if (option.isCreate) {
                                return ListTile(
                                  dense: true,
                                  leading: Icon(
                                    Icons.add,
                                    color: theme.colorScheme.secondary,
                                  ),
                                  title: Text(option.label),
                                  onTap: () =>
                                      widget.onCreateProject(option.rawInput!),
                                );
                              }
                              final project = option.project!;
                              final textColor = project.isArchived
                                  ? theme.textTheme.bodyMedium?.color
                                      ?.withOpacity(0.6)
                                  : theme.textTheme.bodyMedium?.color;
                              return ListTile(
                                dense: true,
                                leading: Icon(
                                  Icons.folder,
                                  color: project.isArchived
                                      ? theme.colorScheme.outline
                                      : theme.colorScheme.primary,
                                ),
                                title: Text(
                                  project.name,
                                  style: TextStyle(color: textColor),
                                ),
                                subtitle: project.isArchived
                                    ? const Text('アーカイブ')
                                    : null,
                                onTap: () =>
                                    widget.onSelectProject(project.id),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SubProjectPickerOverlay extends StatelessWidget {
  final LayerLink link;
  final String projectId;
  final VoidCallback onClose;
  final void Function(String? subProjectId, String? subProjectName)
      onSelectSubProject;
  final String? selectedSubProjectName;
  final VoidCallback? onClearSubProject;

  const _SubProjectPickerOverlay({
    required this.link,
    required this.projectId,
    required this.onClose,
    required this.onSelectSubProject,
    this.selectedSubProjectName,
    this.onClearSubProject,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screenWidth = MediaQuery.of(context).size.width;
    final double pickerWidth = screenWidth < 380
        ? (screenWidth - 24).clamp(220.0, 360.0).toDouble()
        : 320.0;
    final subProjects = SubProjectService.getSubProjectsByProjectId(projectId)
        .where((s) => !s.isArchived)
        .toList();
    subProjects.sort((a, b) {
      final fa = SelectionFrequencyService.getSubProjectCount(a.id);
      final fb = SelectionFrequencyService.getSubProjectCount(b.id);
      if (fb != fa) return fb.compareTo(fa);
      return a.name.compareTo(b.name);
    });

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: onClose,
          ),
        ),
        CompositedTransformFollower(
          link: link,
          showWhenUnlinked: false,
          targetAnchor: Alignment.topRight,
          followerAnchor: Alignment.bottomRight,
          offset: const Offset(0, -8),
          child: Material(
            color: Colors.transparent,
            elevation: 8,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              width: pickerWidth,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.cardColor,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: theme.dividerColor),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (selectedSubProjectName != null &&
                      selectedSubProjectName!.isNotEmpty) ...[
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            selectedSubProjectName!,
                            style: theme.textTheme.bodyMedium,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          icon: Icon(
                            Icons.cancel,
                            size: 20,
                            color: theme.colorScheme.outline,
                          ),
                          tooltip: 'サブプロジェクトをクリア',
                          onPressed: () {
                            onClearSubProject?.call();
                          },
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 36,
                            minHeight: 36,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                  ],
                  Text(
                    'サブプロジェクトを選択',
                    style: theme.textTheme.labelLarge,
                  ),
                  const SizedBox(height: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 240),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: subProjects.length + 1,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        if (index == 0) {
                          return ListTile(
                            dense: true,
                            leading: Icon(
                              Icons.clear,
                              color: theme.colorScheme.outline,
                            ),
                            title: const Text('なし'),
                            onTap: () =>
                                onSelectSubProject(null, null),
                          );
                        }
                        final sub = subProjects[index - 1];
                        return ListTile(
                          dense: true,
                          leading: Icon(
                            Icons.folder_open,
                            color: theme.colorScheme.primary,
                          ),
                          title: Text(sub.name),
                          onTap: () =>
                              onSelectSubProject(sub.id, sub.name),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ProjectOption {
  final Project? project;
  final String label;
  final bool isCreate;
  final String? rawInput;

  const _ProjectOption._({
    required this.project,
    required this.label,
    required this.isCreate,
    required this.rawInput,
  });

  factory _ProjectOption.project(Project project) {
    return _ProjectOption._(
      project: project,
      label: project.name,
      isCreate: false,
      rawInput: null,
    );
  }

  factory _ProjectOption.create({
    required String label,
    required String rawInput,
  }) {
    return _ProjectOption._(
      project: null,
      label: label,
      isCreate: true,
      rawInput: rawInput,
    );
  }
}
