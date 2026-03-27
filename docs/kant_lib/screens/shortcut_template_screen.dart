import 'dart:async';

import 'package:hive/hive.dart';
import 'package:flutter/foundation.dart' show FlutterExceptionHandler;
import 'package:flutter/material.dart';

import '../models/routine_block_v2.dart';
import '../models/routine_shortcut_task_row.dart';
import '../models/routine_task_v2.dart' as v2task;
import '../models/work_type.dart';
import '../models/routine_template_v2.dart';
import '../services/auth_service.dart';
import '../services/device_info_service.dart';
import '../services/project_service.dart';
import '../services/routine_block_v2_service.dart';
import '../services/routine_block_v2_sync_service.dart';
import '../services/routine_lamport_clock_service.dart';
import '../services/routine_mutation_facade.dart';
import '../services/routine_task_v2_service.dart';
import '../services/routine_task_v2_sync_service.dart';
import '../services/routine_template_v2_service.dart';
import '../services/routine_template_v2_sync_service.dart';
import '../services/sub_project_service.dart';
import '../services/routine_v2_backfill_service.dart';
import '../services/app_settings_service.dart';
import '../widgets/routine_header_row.dart';
import '../widgets/routine_task_row.dart';
import '../widgets/routine_table_columns.dart';
import '../widgets/project_input_field.dart';
import '../widgets/sub_project_input_field.dart';
import '../widgets/mode_input_field.dart';
import 'shortcut_task_edit_screen.dart';
import '../app/theme/domain_colors.dart';
import '../utils/unified_screen_dialog.dart';

/// ショートカット（非定型ショートカット）編集画面。
///
/// 計画書 15.4.1 に従い、ショートカットは V2 の
/// routine_templates_v2 / routine_blocks_v2 / routine_tasks_v2 に統合する。
///
/// 一覧の行は [RoutineShortcutTaskRow]（V2 由来の表示用 DTO）。
class ShortcutTemplateScreen extends StatefulWidget {
  final RoutineTemplateV2 routine;
  final bool embedded;

  const ShortcutTemplateScreen({
    super.key,
    required this.routine,
    this.embedded = false,
  });

  @override
  State<ShortcutTemplateScreen> createState() => _ShortcutTemplateScreenState();
}

class _ShortcutTemplateScreenState extends State<ShortcutTemplateScreen> {
  static const String _shortcutTemplateId = 'shortcut';
  static const String _shortcutBlockId = 'v2blk_shortcut_0';

  final RoutineMutationFacade _mutationFacade = RoutineMutationFacade.instance;

  RoutineTemplateV2? _template;
  RoutineBlockV2? _block;
  bool _isLoading = true;

  // row editing
  final Map<String, TextEditingController> _blockNameControllers = {};
  final Map<String, TextEditingController> _taskNameControllers = {};
  final Map<String, TextEditingController> _projectNameControllers = {};
  final Map<String, TextEditingController> _subProjectNameControllers = {};
  final Map<String, TextEditingController> _locationControllers = {};
  final Map<String, Timer> _taskNameSaveTimers = {};
  FlutterExceptionHandler? _previousFlutterErrorHandler;

  @override
  void initState() {
    super.initState();
    _installRenderErrorProbe();
    _bootstrap();
  }

  @override
  void didUpdateWidget(covariant ShortcutTemplateScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.routine.id != widget.routine.id ||
        oldWidget.embedded != widget.embedded) {
      _bootstrap();
    }
  }

  @override
  void dispose() {
    _restoreRenderErrorProbe();
    for (final t in _taskNameSaveTimers.values) {
      t.cancel();
    }
    for (final c in _blockNameControllers.values) {
      c.dispose();
    }
    for (final c in _taskNameControllers.values) {
      c.dispose();
    }
    for (final c in _locationControllers.values) {
      c.dispose();
    }
    for (final c in _projectNameControllers.values) {
      c.dispose();
    }
    for (final c in _subProjectNameControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _installRenderErrorProbe() {
    _previousFlutterErrorHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      final message = details.exceptionAsString();
      if (message.contains('Cannot provide both a color and a decoration')) {
        debugPrint('[ShortcutTableDiag] container-color-decoration-assert');
        debugPrint(message);
        if (details.stack != null) {
          debugPrint(details.stack.toString());
        }
      }
      final prev = _previousFlutterErrorHandler;
      if (prev != null) {
        prev(details);
      } else {
        FlutterError.presentError(details);
      }
    };
  }

  void _restoreRenderErrorProbe() {
    FlutterError.onError = _previousFlutterErrorHandler;
  }

  Future<void> _bootstrap() async {
    _trace('bootstrap.start',
        extra: 'routineId=${widget.routine.id} embedded=${widget.embedded}');
    setState(() {
      _isLoading = true;
    });

    final templateId = _effectiveTemplateId;

    try {
      await RoutineTaskV2Service.ensureOpen();
      _trace('bootstrap.afterEnsureOpen');
      await _ensureShortcutTemplateExists(templateId);
      _trace('bootstrap.afterEnsureTemplate');
      await _ensureShortcutBlockExists(templateId);
      _trace('bootstrap.afterEnsureBlock');

      // Self-heal: migrate legacy-id shortcut tasks into canonical IDs so the UI can display them.
      try {
        await RoutineV2BackfillService.ensureShortcutBundleBackfilledIfEmpty();
        _trace('bootstrap.afterBackfill');
      } catch (_) {}

      // テンプレ単位で pull（ローカルに行があっても実行する）。
      // 理由: タイムラインのショートカットダイアログは「一覧が空のときだけ」pull するため、
      // ローカルに古い行だけがある状態で編集アイコンから遷移すると同期が一度も走らず
      // 他端末の更新が反映されない。編集画面オープン時は常に最新を取りにいく。
      _trace('bootstrap.beforeSync', tasks: _loadShortcutTasks());
      _trace('bootstrap.sync.start');
      await _syncShortcutBundleFromCloud(templateId);
      _trace('bootstrap.sync.done', tasks: _loadShortcutTasks());

    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
      _trace('bootstrap.done', extra: 'isLoading=$_isLoading');
    }
  }

  /// 本画面は非定型ショートカット専用。タスク・FAB・同期のSSOTは常に予約ID [shortcut] のみ。
  /// 渡された [widget.routine] の id に依存しない（新規ユーザー以降、表示ズレを原理的に起こさない）。
  String get _effectiveTemplateId => _shortcutTemplateId;

  Future<void> _ensureShortcutTemplateExists(String templateId) async {
    final existing = RoutineTemplateV2Service.getById(templateId);
    if (existing != null) {
      _template = existing;
      return;
    }

    final deviceId = await DeviceInfoService.getDeviceId();
    final ver = await RoutineLamportClockService.next();
    final now = DateTime.now().toUtc();
    final uid = AuthService.getCurrentUserId() ?? '';

    final tpl = RoutineTemplateV2(
      id: templateId,
      title: '非定型ショートカット',
      memo: '',
      workType: WorkType.free,
      color: DomainColors.defaultHex,
      applyDayType: 'both',
      isActive: true,
      isDeleted: false,
      version: ver,
      deviceId: deviceId,
      userId: uid,
      createdAt: now,
      lastModified: now,
      isShortcut: true,
    )..cloudId = templateId;

    await RoutineTemplateV2Service.add(tpl);
    try {
      await RoutineTemplateV2SyncService().uploadToFirebase(tpl);
      await RoutineTemplateV2Service.update(tpl);
    } catch (_) {}

    _template = tpl;
  }

  Future<void> _ensureShortcutBlockExists(String templateId) async {
    final existing = RoutineBlockV2Service.getById(_shortcutBlockId);
    if (existing != null) {
      _block = existing;
      return;
    }

    final deviceId = await DeviceInfoService.getDeviceId();
    final ver = await RoutineLamportClockService.next();
    final now = DateTime.now().toUtc();
    final uid = AuthService.getCurrentUserId() ?? '';

    final block = RoutineBlockV2(
      id: _shortcutBlockId,
      routineTemplateId: templateId,
      blockName: 'ショートカット',
      startTime: const TimeOfDay(hour: 0, minute: 0),
      endTime: const TimeOfDay(hour: 23, minute: 59),
      workingMinutes: 24 * 60 - 1,
      colorValue: null,
      order: 0,
      location: null,
      createdAt: now,
      lastModified: now,
      userId: uid,
      cloudId: _shortcutBlockId,
      lastSynced: null,
      isDeleted: false,
      deviceId: deviceId,
      version: ver,
    );

    await RoutineBlockV2Service.add(block);
    try {
      await RoutineBlockV2SyncService().uploadToFirebase(block);
      await RoutineBlockV2Service.update(block);
    } catch (_) {}

    _block = block;
  }

  Future<void> _syncShortcutBundleFromCloud(String templateId) async {
    try {
      await RoutineTemplateV2SyncService()
          .syncById(templateId)
          .timeout(const Duration(seconds: 8));
    } catch (_) {}
    try {
      await RoutineBlockV2SyncService()
          .syncForTemplate(templateId)
          .timeout(const Duration(seconds: 8));
    } catch (_) {}
    try {
      await RoutineTaskV2SyncService()
          .syncForTemplate(templateId)
          .timeout(const Duration(seconds: 8));
    } catch (_) {}
    try {
      await RoutineV2BackfillService.ensureShortcutBundleBackfilledIfEmpty();
    } catch (_) {}
  }

  List<v2task.RoutineTaskV2> _loadShortcutTasks() {
    return RoutineTaskV2Service.getCanonicalShortcutTasksForCurrentUser();
  }

  void _trace(
    String phase, {
    List<v2task.RoutineTaskV2>? tasks,
    String? extra,
  }) {}

  RoutineShortcutTaskRow _toDisplayRow(v2task.RoutineTaskV2 t) {
    // showTimeColumns=false のため start/end はダミーで良い。
    return RoutineShortcutTaskRow.fromV2(
      t,
      startTime: const TimeOfDay(hour: 0, minute: 0),
      endTime: const TimeOfDay(hour: 0, minute: 0),
    );
  }

  void _syncControllers(List<RoutineShortcutTaskRow> tasks) {
    final ids = tasks.map((t) => t.id).toSet();

    for (final task in tasks) {
      _blockNameControllers.putIfAbsent(
        task.id,
        () => TextEditingController(text: task.blockName ?? ''),
      );
      _taskNameControllers.putIfAbsent(
        task.id,
        () => TextEditingController(text: task.name),
      );
      _locationControllers.putIfAbsent(
        task.id,
        () => TextEditingController(text: task.location ?? ''),
      );
      _projectNameControllers.putIfAbsent(
        task.id,
        () => TextEditingController(text: _sanitizeDisplayName(_getProjectName(task.projectId))),
      );
      _subProjectNameControllers.putIfAbsent(
        task.id,
        () => TextEditingController(text: _sanitizeDisplayName(_getSubProjectName(task.subProjectId))),
      );

      final blockController = _blockNameControllers[task.id]!;
      final taskController = _taskNameControllers[task.id]!;
      final locationController = _locationControllers[task.id]!;
      final projectController = _projectNameControllers[task.id]!;
      final subProjectController = _subProjectNameControllers[task.id]!;

      if (blockController.text != (task.blockName ?? '')) {
        blockController.text = task.blockName ?? '';
      }
      if (taskController.text != task.name) {
        taskController.text = task.name;
      }
      final desiredLocation = task.location ?? '';
      if (locationController.text != desiredLocation) {
        locationController.text = desiredLocation;
      }
      final desiredProject = _sanitizeDisplayName(_getProjectName(task.projectId));
      if (projectController.text != desiredProject) {
        projectController.text = desiredProject;
      }
      final desiredSubProject = _sanitizeDisplayName(_getSubProjectName(task.subProjectId));
      if (subProjectController.text != desiredSubProject) {
        subProjectController.text = desiredSubProject;
      }
    }

    void disposeMissing(Map<String, TextEditingController> source) {
      final removeKeys = source.keys.where((id) => !ids.contains(id)).toList();
      for (final key in removeKeys) {
        source.remove(key)?.dispose();
      }
    }

    disposeMissing(_blockNameControllers);
    disposeMissing(_taskNameControllers);
    disposeMissing(_locationControllers);
    disposeMissing(_projectNameControllers);
    disposeMissing(_subProjectNameControllers);

    // timers
    final removeTimers = _taskNameSaveTimers.keys
        .where((id) => !ids.contains(id))
        .toList();
    for (final k in removeTimers) {
      _taskNameSaveTimers.remove(k)?.cancel();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading || _template == null || _block == null) {
      _trace('build.loadingGate', extra: 'isLoading=$_isLoading');
      const loading = Center(child: CircularProgressIndicator());
      if (widget.embedded) return loading;
      return Scaffold(
        appBar: AppBar(title: const Text('ショートカット')),
        body: loading,
      );
    }

    final content = StreamBuilder<BoxEvent>(
      stream: RoutineTaskV2Service.watchAll(),
      builder: (context, _) {
        final visibleTasks = _loadShortcutTasks().map(_toDisplayRow).toList();
        _trace('build.stream', tasks: _loadShortcutTasks(), extra: 'visible=${visibleTasks.length}');
        _syncControllers(visibleTasks);
        return Column(
          children: [
            Expanded(
              child: _ShortcutEditableTableV2(
                tasks: visibleTasks,
                blockNameControllers: _blockNameControllers,
                taskNameControllers: _taskNameControllers,
                projectNameControllers: _projectNameControllers,
                subProjectNameControllers: _subProjectNameControllers,
                locationControllers: _locationControllers,
                onBlockNameSubmitted: _updateBlockName,
                onTaskNameChanged: _handleTaskNameChanged,
                onTaskNameSubmitted: _updateTaskName,
                onLocationSubmitted: _updateLocation,
                onProjectChanged: _updateProject,
                onSubProjectChanged: _updateSubProject,
                onModeChanged: _updateMode,
                onDelete: _deleteTask,
                onReorder: _onReorder,
                getProjectName: _getProjectName,
                getSubProjectName: _getSubProjectName,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Align(
                alignment: Alignment.centerRight,
                child: ElevatedButton.icon(
                  onPressed: _addShortcutTask,
                  icon: const Icon(Icons.add),
                  label: const Text('タスクを追加'),
                ),
              ),
            ),
          ],
        );
      },
    );

    if (widget.embedded) return content;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'ショートカット一覧',
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: content,
    );
  }

  Future<void> _addShortcutTask() async {
    final templateId = _effectiveTemplateId;
    try {
      final existing = RoutineTaskV2Service
          .getByBlock(_shortcutBlockId)
          .where((t) => t.routineTemplateId == templateId)
          .toList();
      final nextOrder = existing.isEmpty
          ? 0
          : (existing.map((t) => t.order).reduce((a, b) => a > b ? a : b) + 1);

      final now = DateTime.now().toUtc();
      final uid = AuthService.getCurrentUserId() ?? '';
      final id = _generateTaskId(now);

      final task = v2task.RoutineTaskV2(
        id: id,
        routineTemplateId: templateId,
        routineBlockId: _shortcutBlockId,
        name: '',
        estimatedDuration: AppSettingsService.getInt(
          AppSettingsService.keyTaskDefaultEstimatedMinutes,
          defaultValue: 0,
        ),
        projectId: null,
        subProjectId: null,
        subProject: null,
        modeId: null,
        details: null,
        memo: null,
        location: null,
        blockName: null,
        order: nextOrder,
        createdAt: now,
        lastModified: now,
        userId: uid,
      );
      await _mutationFacade.addTask(task);
      if (!mounted) return;
      final displayTask = _toDisplayRow(task);
      // 埋め込み時はルートの Navigator 上に出す（そうしないとダイアログが前面に出ないことがある）
      final nav = Navigator.of(context, rootNavigator: true);
      if (!nav.mounted) return;
      await showUnifiedScreenDialog<void>(
        context: nav.context,
        builder: (_) => ShortcutTaskEditScreen(
          templateId: templateId,
          displayTask: displayTask,
        ),
      );
    } catch (e) {
      _showError('タスクの追加に失敗しました: $e');
    }
  }

  String _generateTaskId(DateTime nowUtc) {
    final ms = nowUtc.millisecondsSinceEpoch;
    final micro = nowUtc.microsecond;
    final rand = (ms ^ micro).toRadixString(36);
    return 'rtask_${ms}_${micro}_$rand';
  }

  v2task.RoutineTaskV2? _findV2(String taskId) {
    try {
      return RoutineTaskV2Service.getById(taskId);
    } catch (_) {
      return null;
    }
  }

  /// 表示順を並び替え（oldIndex の項目を newIndex へ移動）。V2 の order を更新して保存する。
  Future<void> _onReorder(int oldIndex, int newIndex) async {
    final current = _loadShortcutTasks().map(_toDisplayRow).toList();
    if (oldIndex < 0 || newIndex < 0 ||
        oldIndex >= current.length ||
        newIndex >= current.length ||
        oldIndex == newIndex) return;
    final reordered = List<RoutineShortcutTaskRow>.from(current);
    final item = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, item);
    try {
      for (int i = 0; i < reordered.length; i++) {
        final v2 = _findV2(reordered[i].id);
        if (v2 != null && v2.order != i) {
          await _mutationFacade.updateTask(v2.copyWith(order: i));
        }
      }
    } catch (e) {
      _showError('並び替えの保存に失敗しました: $e');
    }
  }

  void _handleTaskNameChanged(String taskId, String value) {
    _taskNameSaveTimers[taskId]?.cancel();
    _taskNameSaveTimers[taskId] = Timer(
      const Duration(milliseconds: 600),
      () => _commitTaskName(taskId, value),
    );
  }

  Future<void> _commitTaskName(String taskId, String value) async {
    _taskNameSaveTimers[taskId]?.cancel();
    final task = _findV2(taskId);
    if (task == null) return;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return;
    if (trimmed == task.name) return;
    await _mutationFacade.updateTask(task.copyWith(name: trimmed));
  }

  Future<void> _updateTaskName(String taskId, String value) async {
    _taskNameSaveTimers[taskId]?.cancel();
    await _commitTaskName(taskId, value);
  }

  Future<void> _updateBlockName(String taskId, String value) async {
    final task = _findV2(taskId);
    if (task == null) return;
    final trimmed = value.trim();
    await _mutationFacade.updateTask(
      task.copyWith(blockName: trimmed.isEmpty ? null : trimmed),
    );
  }

  Future<void> _updateLocation(String taskId, String value) async {
    final task = _findV2(taskId);
    if (task == null) return;
    final trimmed = value.trim();
    await _mutationFacade.updateTask(
      task.copyWith(location: trimmed.isEmpty ? null : trimmed),
    );
  }

  Future<void> _updateProject(String taskId, String? projectId) async {
    final task = _findV2(taskId);
    if (task == null) return;
    final normalized =
        (projectId == null || projectId.isEmpty) ? null : projectId;

    final bool projectChanged = normalized != task.projectId;

    await _mutationFacade.updateTask(
      task.copyWith(
        projectId: normalized,
        subProjectId: projectChanged ? null : task.subProjectId,
        subProject: projectChanged ? null : task.subProject,
      ),
    );
  }

  Future<void> _updateSubProject(
    String taskId,
    String? subProjectId,
    String? subProjectName,
  ) async {
    final task = _findV2(taskId);
    if (task == null) return;
    await _mutationFacade.updateTask(
      task.copyWith(
        subProjectId: subProjectId,
        subProject: subProjectName,
      ),
    );
  }

  Future<void> _updateMode(String taskId, String? modeId) async {
    final task = _findV2(taskId);
    if (task == null) return;
    await _mutationFacade.updateTask(task.copyWith(modeId: modeId));
  }

  Future<void> _deleteTask(String taskId) async {
    final templateId = _effectiveTemplateId;
    try {
      await _mutationFacade.deleteTask(taskId, templateId);
    } catch (e) {
      _showError('タスクの削除に失敗しました: $e');
    }
  }

  String _getProjectName(String? projectId) {
    if (projectId == null || projectId.isEmpty) {
      return '未設定';
    }
    try {
      return ProjectService.getProjectById(projectId)?.name ?? '未設定';
    } catch (_) {
      return '未設定';
    }
  }

  String _sanitizeDisplayName(String? value) {
    final v = (value ?? '').trim();
    return v == '未設定' ? '' : v;
  }

  String _getSubProjectName(String? subProjectId) {
    if (subProjectId == null || subProjectId.isEmpty) {
      return '未設定';
    }
    try {
      return SubProjectService.getSubProjectById(subProjectId)?.name ?? '未設定';
    } catch (_) {
      return '未設定';
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Theme.of(context).colorScheme.error,
      ),
    );
  }
}

class _ShortcutEditableTableV2 extends StatelessWidget {
  static const bool _showDiagMarkerColumn = false;
  static const bool _forceSimpleRowForDiagnosis = false;
  final List<RoutineShortcutTaskRow> tasks;
  final Map<String, TextEditingController> blockNameControllers;
  final Map<String, TextEditingController> taskNameControllers;
  final Map<String, TextEditingController> projectNameControllers;
  final Map<String, TextEditingController> subProjectNameControllers;
  final Map<String, TextEditingController> locationControllers;

  final Future<void> Function(String taskId, String value) onBlockNameSubmitted;
  final void Function(String taskId, String value) onTaskNameChanged;
  final Future<void> Function(String taskId, String value) onTaskNameSubmitted;
  final Future<void> Function(String taskId, String value) onLocationSubmitted;
  final Future<void> Function(String taskId, String? projectId) onProjectChanged;
  final Future<void> Function(
    String taskId,
    String? subProjectId,
    String? subProjectName,
  ) onSubProjectChanged;
  final Future<void> Function(String taskId, String? modeId) onModeChanged;
  final Future<void> Function(String taskId) onDelete;
  final void Function(int oldIndex, int newIndex)? onReorder;

  final String Function(String?) getProjectName;
  final String Function(String?) getSubProjectName;

  const _ShortcutEditableTableV2({
    required this.tasks,
    required this.blockNameControllers,
    required this.taskNameControllers,
    required this.projectNameControllers,
    required this.subProjectNameControllers,
    required this.locationControllers,
    required this.onBlockNameSubmitted,
    required this.onTaskNameChanged,
    required this.onTaskNameSubmitted,
    required this.onLocationSubmitted,
    required this.onProjectChanged,
    required this.onSubProjectChanged,
    required this.onModeChanged,
    required this.onDelete,
    this.onReorder,
    required this.getProjectName,
    required this.getSubProjectName,
  });

  bool _shouldUseMobileTaskCards(BuildContext context) {
    // ルーティン編集画面に合わせ、スマホ幅ではテーブル表示を避けてカード表示に切り替える。
    final media = MediaQuery.of(context);
    final size = media.size;
    // 仕様: 「幅が狭いとき」は端末種別に関係なくカードにする（タブレット縦持ち等も含む）
    return size.width < 800;
  }

  void _debugTableBuild({
    required bool useMobileCards,
    required int taskCount,
    required Size screenSize,
  }) {}

  @override
  Widget build(BuildContext context) {
    final useMobileCards = _shouldUseMobileTaskCards(context);
    _debugTableBuild(
      useMobileCards: useMobileCards,
      taskCount: tasks.length,
      screenSize: MediaQuery.of(context).size,
    );
    if (useMobileCards) {
      if (tasks.isEmpty) {
        return ListView(
          padding: const EdgeInsets.all(12),
          children: const [
            SizedBox(height: 8),
            Text('ショートカットタスクが登録されていません'),
          ],
        );
      }

      if (onReorder != null) {
        final reorderCb = onReorder!;
        return ReorderableListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
          buildDefaultDragHandles: true,
          onReorder: reorderCb,
          children: [
            for (int index = 0; index < tasks.length; index++)
              _ShortcutTaskInboxLikeCard(
                key: ValueKey(tasks[index].id),
                task: tasks[index],
                getProjectName: getProjectName,
                getSubProjectName: getSubProjectName,
                onTap: () async {
                  final task = tasks[index];
                  final nav = Navigator.of(context, rootNavigator: true);
                  if (!nav.mounted) return;
                  await showUnifiedScreenDialog<void>(
                    context: nav.context,
                    builder: (_) => ShortcutTaskEditScreen(
                      templateId: task.routineTemplateId,
                      displayTask: task,
                    ),
                  );
                },
                onLongPress: () {
                  final task = tasks[index];
                  showModalBottomSheet(
                    context: context,
                    showDragHandle: true,
                    builder: (ctx) {
                      return SafeArea(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ListTile(
                              leading: const Icon(Icons.delete_outline),
                              title: const Text('削除'),
                              onTap: () async {
                                Navigator.of(ctx).pop();
                                await onDelete(task.id);
                              },
                            ),
                            const SizedBox(height: 8),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
          ],
        );
      }

      return ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
        itemCount: tasks.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          final task = tasks[index];
          final key = ValueKey('shortcut_task_card_${task.id}');
          return _ShortcutTaskInboxLikeCard(
            key: key,
            task: task,
            getProjectName: getProjectName,
            getSubProjectName: getSubProjectName,
            onTap: () async {
              final nav = Navigator.of(context, rootNavigator: true);
              if (!nav.mounted) return;
              await showUnifiedScreenDialog<void>(
                context: nav.context,
                builder: (_) => ShortcutTaskEditScreen(
                  templateId: task.routineTemplateId, // 呼び出し元の表示ID（通常は shortcut）
                  displayTask: task,
                ),
              );
            },
            onLongPress: () {
              showModalBottomSheet(
                context: context,
                showDragHandle: true,
                builder: (ctx) {
                  return SafeArea(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ListTile(
                          leading: const Icon(Icons.delete_outline),
                          title: const Text('削除'),
                          onTap: () async {
                            Navigator.of(ctx).pop();
                            await onDelete(task.id);
                          },
                        ),
                        const SizedBox(height: 8),
                      ],
                    ),
                  );
                },
              );
            },
          );
        },
      );
    }

    const double orderColumnWidth = 48;

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 1180.0),
              child: Column(
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: RoutineHeaderRow(
                          timeZoneName: 'ショートカット',
                          startTime: const TimeOfDay(hour: 0, minute: 0),
                          endTime: const TimeOfDay(hour: 23, minute: 59),
                          calculateDuration: (_, __) => '',
                          showTimeColumns: false,
                          showDurationColumn: false,
                          columns: RoutineTableLayout.shortcutEditColumns,
                        ),
                      ),
                      if (onReorder != null)
                        SizedBox(
                          width: orderColumnWidth,
                          child: Container(
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              border: Border(
                                left: BorderSide(
                                    color: Theme.of(context).dividerColor),
                              ),
                            ),
                            child: Container(
                              width: 28,
                              height: 24,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: Theme.of(context)
                                    .colorScheme
                                    .surfaceVariant
                                    .withOpacity(0.5),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Icon(
                                Icons.drag_indicator,
                                size: 20,
                                color: Theme.of(context).colorScheme.onSurface,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (tasks.isEmpty)
                    Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        border: Border.all(color: Theme.of(context).dividerColor),
                      ),
                      padding: const EdgeInsets.all(24),
                      child: const Text('ショートカットタスクが登録されていません'),
                    )
                  else
                    Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        border: Border.all(color: Theme.of(context).dividerColor),
                      ),
                      child: onReorder != null
                          ? ReorderableListView(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              buildDefaultDragHandles: false,
                              onReorder: onReorder!,
                              children: [
                                for (int i = 0; i < tasks.length; i++)
                                  Builder(
                                    key: ValueKey(tasks[i].id),
                                    builder: (context) {
                                      try {
                                        return Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Row(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.center,
                                              children: [
                                                Expanded(
                                                  child: _buildRow(
                                                      context, tasks[i]),
                                                ),
                                                ReorderableDragStartListener(
                                                  index: i,
                                                  child:
                                                      _buildOrderCell(context, i),
                                                ),
                                              ],
                                            ),
                                            if (i != tasks.length - 1)
                                              Divider(
                                                height: 1,
                                                thickness: 1,
                                                color: Theme.of(context)
                                                    .dividerColor,
                                              ),
                                          ],
                                        );
                                      } catch (e, st) {
                                        debugPrint(
                                          '[ShortcutTableDiag] row-build-error '
                                          'index=$i taskId=${tasks[i].id} '
                                          'name=${tasks[i].name} error=$e\n$st',
                                        );
                                        return Container(
                                          color: Colors.red.withOpacity(0.06),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 6,
                                          ),
                                          child: Text(
                                            'row-build-error: ${tasks[i].name} (${tasks[i].id})',
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall,
                                          ),
                                        );
                                      }
                                    },
                                  ),
                              ],
                            )
                          : Column(
                              children: [
                                for (int i = 0; i < tasks.length; i++) ...[
                                  Builder(
                                    builder: (context) {
                                      try {
                                        return Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.center,
                                          children: [
                                            Expanded(
                                              child: _buildRow(context, tasks[i]),
                                            ),
                                            _buildOrderCell(context, i),
                                          ],
                                        );
                                      } catch (e, st) {
                                        debugPrint(
                                          '[ShortcutTableDiag] row-build-error '
                                          'index=$i taskId=${tasks[i].id} '
                                          'name=${tasks[i].name} error=$e\n$st',
                                        );
                                        return Container(
                                          color: Colors.red.withOpacity(0.06),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 6,
                                          ),
                                          child: Text(
                                            'row-build-error: ${tasks[i].name} (${tasks[i].id})',
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall,
                                          ),
                                        );
                                      }
                                    },
                                  ),
                                  if (i != tasks.length - 1)
                                    Divider(
                                      height: 1,
                                      thickness: 1,
                                      color: Theme.of(context).dividerColor,
                                    ),
                                ],
                              ],
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

  Widget _buildOrderCell(BuildContext context, int index) {
    const double w = 48;
    return SizedBox(
      width: w,
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: Theme.of(context).dividerColor),
          ),
        ),
        alignment: Alignment.center,
        child: Container(
          width: 28,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Theme.of(context)
                .colorScheme
                .surfaceVariant
                .withOpacity(0.5),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(
            Icons.drag_indicator,
            size: 20,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
      ),
    );
  }

  Widget _buildRow(BuildContext context, RoutineShortcutTaskRow task) {
    if (_forceSimpleRowForDiagnosis) {
      debugPrint(
        '[ShortcutTableDiag] simple-row-render taskId=${task.id} name=${task.name}',
      );
      return Container(
        height: 36,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Text(
          task.name.trim().isEmpty ? '(無題) ${task.id}' : task.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
    }

    final row = RoutineTaskRow(
      key: ValueKey(task.id),
      task: task,
      blockNameController: blockNameControllers[task.id],
      taskNameController: taskNameControllers[task.id],
      projectController: projectNameControllers[task.id],
      subProjectController: subProjectNameControllers[task.id],
      onBlockNameSubmitted: (value) => onBlockNameSubmitted(task.id, value),
      onTaskNameChanged: (value) => onTaskNameChanged(task.id, value),
      onTaskNameSubmitted: (value) => onTaskNameSubmitted(task.id, value),
      locationController: locationControllers[task.id],
      onLocationSubmitted: (value) => onLocationSubmitted(task.id, value),
      onProjectChanged: (projectId) => onProjectChanged(task.id, projectId),
      onSubProjectChanged: (subProjectId, subProjectName) =>
          onSubProjectChanged(task.id, subProjectId, subProjectName),
      onDelete: () => onDelete(task.id),
      onTimeChanged: () {},
      onModeChanged: () => onModeChanged(task.id, task.modeId),
      getProjectName: getProjectName,
      getSubProjectName: getSubProjectName,
      calculateDuration: (_, __) => '',
      showTimeColumns: false,
      showDurationColumn: false,
      columns: RoutineTableLayout.shortcutEditColumns,
    );
    if (!_showDiagMarkerColumn) return row;
    return Row(
      children: [
        Container(
          width: 180,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          decoration: BoxDecoration(
            border: Border(
              right: BorderSide(color: Theme.of(context).dividerColor),
            ),
            color: Colors.amber.withOpacity(0.12),
          ),
          child: Text(
            '${task.id.substring(0, task.id.length > 10 ? 10 : task.id.length)}: ${task.name.isEmpty ? "(empty)" : task.name}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        Expanded(child: row),
      ],
    );
  }
}

class _ShortcutTaskInboxLikeCard extends StatelessWidget {
  final RoutineShortcutTaskRow task;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final String Function(String?) getProjectName;
  final String Function(String?) getSubProjectName;

  const _ShortcutTaskInboxLikeCard({
    super.key,
    required this.task,
    required this.onTap,
    this.onLongPress,
    required this.getProjectName,
    required this.getSubProjectName,
  });

  String _sanitizePlaceholder(String? value) {
    if (value == null) return '';
    final trimmed = value.trim();
    return trimmed == '未設定' ? '' : trimmed;
  }

  @override
  Widget build(BuildContext context) {
    final title = task.name.trim().isNotEmpty ? task.name.trim() : '(無題)';
    final project = _sanitizePlaceholder(getProjectName(task.projectId));
    final subProject = _sanitizePlaceholder(getSubProjectName(task.subProjectId));
    final location = _sanitizePlaceholder(task.location);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        // Card全体をタップ領域にする（選択ハイライトを全面に出す）
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        if (project.isNotEmpty) ...[
                          Icon(
                            Icons.folder,
                            size: 14,
                            color: Theme.of(context)
                                .iconTheme
                                .color
                                ?.withOpacity(0.6),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              project,
                              style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.color,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                        if (project.isNotEmpty && subProject.isNotEmpty)
                          const SizedBox(width: 8),
                        if (subProject.isNotEmpty) ...[
                          Icon(
                            Icons.folder_open,
                            size: 14,
                            color: Theme.of(context)
                                .iconTheme
                                .color
                                ?.withOpacity(0.6),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              subProject,
                              style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.color,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                        if (project.isEmpty && subProject.isEmpty)
                          Text(
                            'プロジェクト未設定',
                            style: TextStyle(
                              fontSize: 12,
                              color:
                                  Theme.of(context).textTheme.bodySmall?.color,
                            ),
                          ),
                      ],
                    ),
                    if (location.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Icon(
                            Icons.place,
                            size: 14,
                            color: Theme.of(context)
                                .iconTheme
                                .color
                                ?.withOpacity(0.6),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              location,
                              style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.color,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: Theme.of(context).iconTheme.color?.withOpacity(0.7),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
