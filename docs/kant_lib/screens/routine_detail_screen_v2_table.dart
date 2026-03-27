// ignore_for_file: use_build_context_synchronously, deprecated_member_use

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/routine_template_v2.dart';
import '../services/calendar_service.dart';
import '../services/inbox_task_service.dart';
import '../services/project_service.dart';
import '../services/sub_project_service.dart';
import '../services/block_service.dart';
import '../providers/task_provider.dart';
import '../services/mode_service.dart';
import '../services/app_settings_service.dart';
import '../utils/ime_safe_dialog.dart';

import '../models/block.dart';
import '../services/block_sync_service.dart';
import '../widgets/project_input_field.dart';
import '../widgets/sub_project_input_field.dart';
import '../widgets/mode_input_field.dart';

import 'routine_detail_actions.dart';
import 'routine_detail_helpers.dart';
import '../widgets/inbox/excel_like_title_cell.dart';
import '../app/theme/app_color_tokens.dart';
import '../services/auth_service.dart';
import '../models/routine_block_v2.dart' as rbv2;
import '../models/routine_task_v2.dart' as rtv2;
import '../repositories/routine_editor_repository.dart';
import '../screens/routine_day_review_screen.dart';
import '../services/routine_mutation_facade.dart';
import '../services/routine_block_v2_service.dart';
import '../services/routine_task_v2_service.dart';
import '../services/routine_database_service.dart';
import '../services/routine_sleep_block_service.dart';
import '../app/main_screen/routine_reflect.dart';
import 'routine_block_task_assignment_table_screen.dart';

/// 睡眠ブロックをテーブルで2行表示するときの行種別（1行目＝起床、最終行＝就寝）
enum _SleepRowType { wake, bed }

class RoutineDetailScreenV2Table extends StatefulWidget {
  final RoutineTemplateV2 routine;
  final bool embedded;

  const RoutineDetailScreenV2Table(
      {super.key, required this.routine, this.embedded = false});

  @override
  State<RoutineDetailScreenV2Table> createState() =>
      _RoutineDetailScreenV2TableState();
}

class _ScheduledTask {
  final rtv2.RoutineTaskV2 task;
  final TimeOfDay start;
  final TimeOfDay end;

  /// `DateTime(0,1,1,00:00)` を 0 分として、翌日以降は +1440 分した絶対分。
  ///
  /// 例:
  /// - 23:00 => 1380
  /// - 翌01:00 => 1500
  final int startAbsoluteMinutes;
  final int endAbsoluteMinutes;
  final int durationMinutes;

  const _ScheduledTask({
    required this.task,
    required this.start,
    required this.end,
    required this.startAbsoluteMinutes,
    required this.endAbsoluteMinutes,
    required this.durationMinutes,
  });
}

class _RoutineDetailScreenV2TableState
    extends State<RoutineDetailScreenV2Table> {
  bool _isBootstrapping = true;
  bool _isBootstrappingInProgress = false;
  bool _initializationCompleted = false;

  final Map<String, TextEditingController> _taskNameControllersV2 = {};
  final Map<String, TextEditingController> _durationControllersV2 = {};
  final Map<String, TextEditingController> _projectControllersV2 = {};
  final Map<String, TextEditingController> _subProjectControllersV2 = {};
  final Map<String, TextEditingController> _modeControllersV2 = {};
  final Map<String, TextEditingController> _locationControllersV2 = {};
  final Map<String, TextEditingController> _detailsControllersV2 = {};
  final Map<String, TextEditingController> _startTimeControllersV2 = {};
  final Map<String, TextEditingController> _endTimeControllersV2 = {};
  final Map<String, TextEditingController> _representativeNameControllers = {};
  final Map<String, TextEditingController> _representativeProjectControllers =
      {};
  final Map<String, TextEditingController>
      _representativeSubProjectControllers = {};
  final Map<String, TextEditingController> _representativeModeControllers = {};
  final Map<String, TextEditingController> _representativeLocationControllers =
      {};

  /// 場所をクリアした直後、スナップショットが追いつく前にコントローラを上書きしないためのマップ
  final Map<String, String> _pendingLocationCommitByBlockId = {};
  final Map<String, String> _pendingLocationCommitByTaskId = {};

  /// プロジェクト変更でサブプロジェクトをクリアした直後、スナップショットが追いつくまで上書きしない
  final Set<String> _pendingSubProjectClearByBlockId = {};
  final Set<String> _pendingSubProjectClearByTaskId = {};
  /// プロジェクトをクリアした直後、スナップショットが追いつくまで代表テキストで上書きしない
  final Set<String> _pendingProjectClearByBlockId = {};
  final Set<String> _pendingProjectClearByTaskId = {};

  /// タスク名をコミットした直後、スナップショットが追いつくまでコントローラを上書きしない
  final Map<String, String> _pendingNameCommitByTaskId = {};
  final Map<String, TextEditingController> _blockStartTimeControllers = {};
  final Map<String, TextEditingController> _blockEndTimeControllers = {};
  final Map<String, TextEditingController> _blockWorkingControllers = {};
  final Map<String, TextEditingController> _blockBreakControllers = {};

  // Inbox の「タスク名」入力と同じく、入力中はデバウンスして自動保存する。
  final Map<String, Timer> _taskNameSaveTimersV2 = {};
  final Map<String, Timer> _representativeNameSaveTimers = {};

  static const double _timeColumnWidth = 64;
  static const int _durationColumnFlex = 10;
  static const int _nameColumnFlex = 28;
  static const int _projectColumnFlex = 20;
  static const int _subProjectColumnFlex = 20;
  static const int _modeColumnFlex = 16;
  static const int _locationColumnFlex = 18;
  static const int _detailsColumnFlex = 18;
  static const double _separatorColumnWidth = 12;
  static const double _actionColumnWidth = 44;
  static const double _cellBorderStrokeWidth = 1.0;
  static const double _blockTimeColumnWidth = 48; // HH:mm 入力欄ギリギリ
  static const double _blockMetricColumnWidth = 44; // 作業/休憩: 3桁(999分)を折り返しなしで表示
  // 「集計外」3字＋ヘッダ左右パディング(8×2)を収める。行内は Checkbox のみ。
  static const double _blockExcludeColumnWidth = 60;
  static const int _blockActionColumnFlex = 4;
  static const int _blockNameColumnFlex = 20;
  static const int _blockProjectColumnFlex = 12;
  static const int _blockSubProjectColumnFlex = 12;
  static const int _blockModeColumnFlex = 9;
  static const int _blockLocationColumnFlex = 10;

  static Color? _parseHexColor(String? raw) {
    if (raw == null) return null;
    var s = raw.trim();
    if (s.isEmpty) return null;
    if (s.startsWith('#')) s = s.substring(1);
    if (s.length == 6) s = 'FF$s';
    if (s.length != 8) return null;
    final v = int.tryParse(s, radix: 16);
    if (v == null) return null;
    return Color(v);
  }

  late final RoutineEditorRepository _editorRepository;
  late Stream<RoutineEditorSnapshot> _templateStream;
  RoutineEditorSnapshot? _initialSnapshot;
  final RoutineMutationFacade _mutationFacade = RoutineMutationFacade.instance;
  final Set<String> _expandedBlockIdsV2 = <String>{};
  bool _hasInitializedExpansionState = false;

  String _resolveUserId() {
    final authId = AuthService.getCurrentUserId();
    if (authId != null && authId.isNotEmpty) {
      return authId;
    }
    return widget.routine.userId;
  }

  Future<void> _repairOrphanRoutineData() async {
    final resolvedUserId = _resolveUserId();
    if (resolvedUserId.isEmpty) return;

    final List<Future<void>> pendingUpdates = [];

    final orphanBlocks =
        RoutineBlockV2Service.getAllByTemplate(widget.routine.id)
            .where((block) => block.userId.isEmpty)
            .toList();
    for (final block in orphanBlocks) {
      pendingUpdates.add(
        _mutationFacade.updateBlock(
          block.copyWith(
            userId: resolvedUserId,
            version: block.version + 1,
          ),
        ),
      );
    }

    final orphanTasks = RoutineTaskV2Service.getByTemplate(widget.routine.id)
        .where((task) => task.userId.isEmpty)
        .toList();
    for (final task in orphanTasks) {
      pendingUpdates.add(
        _mutationFacade.updateTask(
          task.copyWith(
            userId: resolvedUserId,
            version: task.version + 1,
          ),
        ),
      );
    }

    if (pendingUpdates.isEmpty) return;

    try {
      await Future.wait(pendingUpdates);
      if (mounted) {
        setState(() {});
      }
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    _editorRepository = RoutineEditorRepository.instance;
    _templateStream = _editorRepository.watchTemplate(widget.routine.id);
    _initialSnapshot = _editorRepository.snapshotTemplate(widget.routine.id);
    _initializationCompleted = _initialSnapshot?.hasBlocks ?? false;
    if (_initializationCompleted) {
      _isBootstrapping = false;
      Future.microtask(() => _repairOrphanRoutineData());
    } else {
      _bootstrapTemplateIfNeeded();
    }
    // テンプレートにデフォルトで睡眠ブロックを備え付ける（無ければ作成）
    Future.microtask(() async {
      try {
        await RoutineSleepBlockService.ensureSleepBlockForTemplate(
            widget.routine.id);
      } catch (_) {}
    });
  }

  Future<void> _bootstrapTemplateIfNeeded({bool showSpinner = true}) async {
    if (_isBootstrappingInProgress || _initializationCompleted) {
      return;
    }

    _isBootstrappingInProgress = true;
    if (showSpinner) {
      if (mounted) {
        setState(() => _isBootstrapping = true);
      } else {
        _isBootstrapping = true;
      }
    }
    try {
      final result =
          await _editorRepository.bootstrapTemplateV2(widget.routine);
      final hasBlocks =
          RoutineBlockV2Service.getAllByTemplate(widget.routine.id).isNotEmpty;
      if (result.success && hasBlocks) {
        _initializationCompleted = true;
        _initialSnapshot =
            _editorRepository.snapshotTemplate(widget.routine.id);
        await _repairOrphanRoutineData();
      }
    } finally {
      _isBootstrappingInProgress = false;
      if (showSpinner) {
        if (mounted) {
          setState(() => _isBootstrapping = false);
        } else {
          _isBootstrapping = false;
        }
      }
    }
  }

  @override
  void didUpdateWidget(covariant RoutineDetailScreenV2Table oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.routine.id != widget.routine.id) {
      _templateStream = _editorRepository.watchTemplate(widget.routine.id);
      _initialSnapshot = _editorRepository.snapshotTemplate(widget.routine.id);
      _initializationCompleted = _initialSnapshot?.hasBlocks ?? false;
      _isBootstrapping = !_initializationCompleted;
      _isBootstrappingInProgress = false;
      _expandedBlockIdsV2.clear();
      _hasInitializedExpansionState = false;
      if (_initializationCompleted) {
        Future.microtask(() => _repairOrphanRoutineData());
      } else {
        _bootstrapTemplateIfNeeded();
      }
    }
  }

  @override
  void dispose() {
    for (final t in _taskNameSaveTimersV2.values) {
      t.cancel();
    }
    for (final t in _representativeNameSaveTimers.values) {
      t.cancel();
    }
    for (final c in _taskNameControllersV2.values) {
      c.dispose();
    }
    for (final c in _durationControllersV2.values) {
      c.dispose();
    }
    for (final c in _projectControllersV2.values) {
      c.dispose();
    }
    for (final c in _subProjectControllersV2.values) {
      c.dispose();
    }
    for (final c in _modeControllersV2.values) {
      c.dispose();
    }
    for (final c in _locationControllersV2.values) {
      c.dispose();
    }
    for (final c in _detailsControllersV2.values) {
      c.dispose();
    }
    for (final c in _startTimeControllersV2.values) {
      c.dispose();
    }
    for (final c in _endTimeControllersV2.values) {
      c.dispose();
    }
    for (final c in _representativeNameControllers.values) {
      c.dispose();
    }
    for (final c in _representativeProjectControllers.values) {
      c.dispose();
    }
    for (final c in _representativeSubProjectControllers.values) {
      c.dispose();
    }
    for (final c in _representativeModeControllers.values) {
      c.dispose();
    }
    for (final c in _representativeLocationControllers.values) {
      c.dispose();
    }
    for (final c in _blockStartTimeControllers.values) {
      c.dispose();
    }
    for (final c in _blockEndTimeControllers.values) {
      c.dispose();
    }
    for (final c in _blockWorkingControllers.values) {
      c.dispose();
    }
    for (final c in _blockBreakControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _debounceSave(
    Map<String, Timer> timers,
    String key,
    VoidCallback action, {
    Duration delay = const Duration(milliseconds: 700),
  }) {
    timers[key]?.cancel();
    timers[key] = Timer(delay, action);
  }

  @override
  Widget build(BuildContext context) {
    final content = Stack(children: [
      StreamBuilder<RoutineEditorSnapshot>(
        stream: _templateStream,
        initialData: _initialSnapshot,
        builder: (context, snapshot) {
          final data = snapshot.data ?? _initialSnapshot;
          if (data == null) {
            return const Center(child: CircularProgressIndicator());
          }
          final blocks = data.blocks;

          if (!_initializationCompleted && blocks.isNotEmpty) {
            _initializationCompleted = true;
            if (_isBootstrapping) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) {
                  setState(() => _isBootstrapping = false);
                } else {
                  _isBootstrapping = false;
                }
              });
            }
          }

          if (blocks.isEmpty) {
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _buildEmptyState(context),
                const SizedBox(height: 24),
                _buildAddBlockButton(context),
              ],
            );
          }

          final useMobileCards = _shouldUseMobileTaskCards(context);
          if (useMobileCards && !_hasInitializedExpansionState) {
            _expandedBlockIdsV2.addAll(blocks.map((b) => b.id));
            _hasInitializedExpansionState = true;
          }

          final taskControllerIds = <String>{};
          final blockIds = blocks.map((b) => b.id).toSet();
          final blockWidgets = <Widget>[
            if (useMobileCards)
              for (final b in blocks)
                _buildBlockCard(
                  context,
                  b,
                  data.tasksForBlock(b.id),
                  taskControllerIds,
                )
            else ...[
              _buildBlockTable(
                context,
                data,
                taskControllerIds,
              ),
            ],
            const SizedBox(height: 12),
            _buildAddBlockButton(context),
          ];

          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              _purgeUnusedControllers(taskControllerIds);
              _purgeUnusedBlockControllers(blockIds);
            }
          });

          return ListView(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            children: blockWidgets,
          );
        },
      ),
      if (_isBootstrapping) _buildBootstrappingOverlay(context),
    ]);

    if (widget.embedded) {
      return content;
    }

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: Navigator.of(context).canPop()
            ? BackButton(
                onPressed: () => Navigator.of(context).maybePop(),
              )
            : null,
        title: Text(
          widget.routine.title,
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
        backgroundColor: _parseHexColor(widget.routine.color) ??
            Theme.of(context).colorScheme.primary,
        foregroundColor: Theme.of(context).colorScheme.onPrimary,
        toolbarHeight: 48,
        actions: [
          IconButton(
            tooltip: '1日のルーティンをレビュー',
            icon: const Icon(Icons.visibility),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => RoutineDayReviewScreen(
                    routineTemplateId: widget.routine.id,
                    routineTitle: widget.routine.title,
                    routineColorHex: widget.routine.color,
                  ),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.schedule),
            tooltip: 'ルーティンを反映',
            onPressed: () => RoutineReflectUI.showConfirmAndReflect(
                  context,
                  widget.routine,
                ),
          ),
          IconButton(
            icon: const Icon(Icons.edit),
            onPressed: () => RoutineDetailActions.editRoutine(
              context,
              widget.routine,
              setState,
            ),
          ),
        ],
      ),
      body: content,
    );
  }

  Widget _buildAddBlockButton(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: FilledButton.icon(
          onPressed: _isBootstrapping ? null : _addBlockInlineRow,
          icon: const Icon(Icons.add_circle_outline),
          label: const Text('\u30d6\u30ed\u30c3\u30af\u3092\u8ffd\u52a0'),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
            textStyle: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w600),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
        ),
      ),
    );
  }

  Future<void> _addBlockInlineRow() async {
    try {
      final now = DateTime.now();
      final existingBlocks =
          RoutineDatabaseService.getBlocksForTemplate(widget.routine.id);

      int nextOrder = 0;
      for (final blk in existingBlocks) {
        if (blk.order >= nextOrder) {
          nextOrder = blk.order + 1;
        }
      }

      // スキマ優先: 最初に60分が収まるスキマがあればそこに挿入、なければ末尾に追加
      const durationMinutes = 60;
      final gap = RoutineDetailHelpers.findFirstFittingGap(
        existingBlocks,
        maxBlockMinutes: durationMinutes,
      );
      final TimeOfDay start;
      final TimeOfDay end;
      if (gap != null) {
        start = gap.start;
        end = gap.end;
      } else {
        final latestByEndTime = existingBlocks.isEmpty
            ? null
            : existingBlocks.reduce((a, b) =>
                _timeOfDayToMinutes(b.endTime) > _timeOfDayToMinutes(a.endTime)
                    ? b
                    : a);
        start = latestByEndTime?.endTime ?? const TimeOfDay(hour: 9, minute: 0);
        end = _minutesToTimeOfDay(_timeOfDayToMinutes(start) + durationMinutes);
      }

      // 「集中」モードのIDをデフォルトで使用
      String? focusModeId;
      try {
        final modes = ModeService.getAllModes();
        focusModeId = modes.firstWhere((m) => m.name == '集中').id;
      } catch (_) {}

      final block = rbv2.RoutineBlockV2(
        id: '${now.microsecondsSinceEpoch}_blk',
        routineTemplateId: widget.routine.id,
        blockName: null,
        startTime: start,
        endTime: end,
        workingMinutes: _blockDurationMinutes(start, end),
        colorValue: null,
        order: nextOrder,
        location: null,
        projectId: null,
        subProjectId: null,
        subProject: null,
        modeId: focusModeId,
        excludeFromReport: false,
        createdAt: now,
        lastModified: now,
        userId: _resolveUserId(),
      );

      await _mutationFacade.addBlock(block);
      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('ブロック追加に失敗しました: $e')),
        );
      }
    }
  }

  Widget _buildEmptyState(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(Icons.view_week_outlined,
            size: 72, color: Theme.of(context).colorScheme.outlineVariant),
        const SizedBox(height: 12),
        Text(
          '\u307e\u3060\u30d6\u30ed\u30c3\u30af\u304c\u3042\u308a\u307e\u305b\u3093',
          style: Theme.of(context).textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          '\u30d6\u30ed\u30c3\u30af\u3092\u8ffd\u52a0\u3057\u3066\u3001\u30bf\u30b9\u30af\u3092\u767b\u9332\u3057\u3066\u304f\u3060\u3055\u3044',
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(color: Theme.of(context).colorScheme.outline),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildBlockTable(
    BuildContext context,
    RoutineEditorSnapshot snapshot,
    Set<String> taskControllerIds,
  ) {
    final blocks = snapshot.blocks;
    rbv2.RoutineBlockV2? sleepBlock;
    final otherBlocks = <rbv2.RoutineBlockV2>[];
    for (final b in blocks) {
      if (RoutineSleepBlockService.isSleepBlock(b)) {
        sleepBlock = b;
      } else {
        otherBlocks.add(b);
      }
    }
    final ordered =
        <({rbv2.RoutineBlockV2 block, _SleepRowType? sleepRowType})>[];
    if (sleepBlock != null) {
      ordered.add((block: sleepBlock, sleepRowType: _SleepRowType.wake));
    }
    for (final b in otherBlocks) {
      ordered.add((block: b, sleepRowType: null));
    }
    if (sleepBlock != null) {
      ordered.add((block: sleepBlock, sleepRowType: _SleepRowType.bed));
    }
    return Column(
      children: [
        _buildBlockTableHeader(context),
        for (final e in ordered)
          _buildBlockTableEntry(context, e.block, sleepRowType: e.sleepRowType),
      ],
    );
  }

  Widget _buildBlockTableHeader(BuildContext context) {
    final theme = Theme.of(context);
    final borderColor = theme.dividerColor;
    final headerTextStyle = theme.textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.bold,
          color: theme.textTheme.bodySmall?.color,
        ) ??
        const TextStyle(fontSize: 12, fontWeight: FontWeight.bold);
    final headerBackground = theme.colorScheme.surfaceContainerHighest
        .withOpacity(theme.brightness == Brightness.light ? 1 : 0.2);

    Widget headerCell({
      double? width,
      int? flex,
      required String label,
      bool addRightBorder = true,
      Alignment alignment = Alignment.centerLeft,
      EdgeInsetsGeometry? padding,
      TextStyle? labelStyle,
    }) {
      final decorated = Container(
        height: 36,
        alignment: alignment,
        padding: padding ?? const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: headerBackground,
          border: Border(
            right: addRightBorder
                ? BorderSide(color: borderColor)
                : BorderSide.none,
          ),
        ),
        child: Text(
          label,
          style: labelStyle ?? headerTextStyle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          softWrap: false,
        ),
      );
      if (flex != null) {
        return Expanded(flex: flex, child: decorated);
      }
      if (width != null) {
        return SizedBox(width: width, child: decorated);
      }
      return decorated;
    }

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: borderColor),
      ),
      child: Row(
        children: [
          headerCell(
            width: _blockTimeColumnWidth,
            label: '開始',
            alignment: Alignment.center,
          ),
          headerCell(
            width: _blockTimeColumnWidth,
            label: '終了',
            alignment: Alignment.center,
          ),
          headerCell(flex: _blockNameColumnFlex, label: '予定ブロック'),
          headerCell(
            width: _blockMetricColumnWidth,
            label: '作業',
            alignment: Alignment.center,
          ),
          headerCell(
            width: _blockMetricColumnWidth,
            label: '休憩',
            alignment: Alignment.center,
          ),
          headerCell(
            width: _blockExcludeColumnWidth,
            label: '集計外',
            alignment: Alignment.center,
          ),
          headerCell(flex: _blockProjectColumnFlex, label: 'プロジェクト'),
          headerCell(flex: _blockSubProjectColumnFlex, label: 'サブプロジェクト'),
          headerCell(flex: _blockModeColumnFlex, label: 'モード'),
          headerCell(flex: _blockLocationColumnFlex, label: '場所'),
          headerCell(
            flex: _blockActionColumnFlex,
            label: '＋',
            alignment: Alignment.center,
          ),
          headerCell(
            flex: _blockActionColumnFlex,
            label: '編集',
            alignment: Alignment.center,
          ),
          headerCell(
            flex: _blockActionColumnFlex,
            label: '削除',
            alignment: Alignment.center,
          ),
        ],
      ),
    );
  }

  Widget _buildBlockTableEntry(
    BuildContext context,
    rbv2.RoutineBlockV2 block, {
    _SleepRowType? sleepRowType,
  }) {
    return _buildBlockTableRow(
      context,
      block,
      showBottomBorder: true,
      sleepRowType: sleepRowType,
    );
  }

  Widget _buildBlockTableRow(
    BuildContext context,
    rbv2.RoutineBlockV2 block, {
    required bool showBottomBorder,
    _SleepRowType? sleepRowType,
  }) {
    final theme = Theme.of(context);
    final borderColor = theme.dividerColor;
    final rowBackground = theme.colorScheme.surface;
    const rowHeight = 36.0;
    final isWakeRow = sleepRowType == _SleepRowType.wake;
    final isBedRow = sleepRowType == _SleepRowType.bed;

    Widget cell({
      double? width,
      int? flex,
      required Widget child,
      bool addRightBorder = true,
      Alignment alignment = Alignment.centerLeft,
      EdgeInsetsGeometry padding = const EdgeInsets.symmetric(horizontal: 8),
    }) {
      final decorated = Container(
        height: rowHeight,
        alignment: alignment,
        padding: padding,
        decoration: BoxDecoration(
          color: rowBackground,
          border: Border(
            right: addRightBorder
                ? BorderSide(color: borderColor)
                : BorderSide.none,
          ),
        ),
        child: child,
      );
      if (flex != null) {
        return Expanded(
          flex: flex,
          child: SizedBox(height: rowHeight, child: decorated),
        );
      }
      if (width != null) {
        return SizedBox(width: width, height: rowHeight, child: decorated);
      }
      return SizedBox(height: rowHeight, child: decorated);
    }

    Widget iconCell({
      required IconData icon,
      required String tooltip,
      required VoidCallback onPressed,
      bool addRightBorder = true,
      Color? color,
      int? flex,
    }) {
      return cell(
        flex: flex ?? _blockActionColumnFlex,
        addRightBorder: addRightBorder,
        alignment: Alignment.center,
        padding: EdgeInsets.zero,
        child: IconButton(
          iconSize: 18,
          splashRadius: 18,
          tooltip: tooltip,
          onPressed: onPressed,
          icon: Icon(
            icon,
            color: color ?? theme.iconTheme.color,
          ),
        ),
      );
    }

    final projectName = _displayText(_getProjectName(block.projectId));
    final subProjectRaw =
        (block.subProject != null && block.subProject!.isNotEmpty)
            ? block.subProject
            : _getSubProjectName(block.subProjectId);
    final subProjectName = _displayText(subProjectRaw);
    final modeName = _displayText(_getModeName(block.modeId));
    final locationName = block.location ?? '';
    final hasProject = (block.projectId ?? '').isNotEmpty;
    final totalMinutes = _blockDurationMinutes(block.startTime, block.endTime);

    final nameController = _ensureRepresentativeNameController(block);
    final projectController =
        _ensureRepresentativeProjectController(block, projectName);
    final subProjectController =
        _ensureRepresentativeSubProjectController(block, subProjectName);
    final modeController = _ensureRepresentativeModeController(block, modeName);
    final locationController =
        _ensureRepresentativeLocationController(block, locationName);
    final blockStartController = _ensureBlockStartTimeController(block);
    final blockEndController = _ensureBlockEndTimeController(block);
    final blockWorkingController =
        _ensureBlockWorkingController(block, totalMinutes);
    final blockBreakController =
        _ensureBlockBreakController(block, totalMinutes);

    Widget subProjectInput = SubProjectInputField(
      controller: subProjectController,
      projectId: block.projectId ?? '',
      currentSubProjectId: block.subProjectId,
      useOutlineBorder: false,
      withBackground: false,
      height: 32,
      onSubProjectChanged: (subProjectId, subProjectLabel) async {
        await _applyRepresentativeSubProjectChange(
          block,
          subProjectId,
          subProjectLabel,
        );
      },
    );
    if (!hasProject) {
      subProjectInput = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('先にプロジェクトを設定してください'),
            ),
          );
        },
        child: AbsorbPointer(child: subProjectInput),
      );
    }

    return Container(
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: borderColor, width: _cellBorderStrokeWidth),
          right: BorderSide(color: borderColor, width: _cellBorderStrokeWidth),
          bottom: showBottomBorder
              ? BorderSide(color: borderColor, width: _cellBorderStrokeWidth)
              : BorderSide.none,
        ),
        color: rowBackground,
      ),
      child: Row(
        children: [
          cell(
            width: _blockTimeColumnWidth,
            alignment: Alignment.center,
            padding: EdgeInsets.zero,
            child: isWakeRow
                ? const Center(child: Text('—', style: TextStyle(fontSize: 12)))
                : SizedBox.expand(
                    child: Focus(
                      onFocusChange: (hasFocus) {
                        if (!hasFocus) {
                          _commitBlockStartTimeInput(
                              block, blockStartController.text);
                        }
                      },
                      child: TextField(
                        controller: blockStartController,
                        textAlign: TextAlign.center,
                        textAlignVertical: TextAlignVertical.center,
                        keyboardType: TextInputType.datetime,
                        style: theme.textTheme.bodySmall,
                        decoration: InputDecoration(
                          border: InputBorder.none,
                          isCollapsed: true,
                          filled: true,
                          fillColor: rowBackground,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 2.0,
                            vertical: 16.0,
                          ),
                          constraints: const BoxConstraints(
                            minHeight: rowHeight,
                            maxHeight: rowHeight,
                          ),
                          hintText: 'HH:mm',
                          hintStyle: const TextStyle(fontSize: 12),
                        ),
                        onSubmitted: (_) => _commitBlockStartTimeInput(
                          block,
                          blockStartController.text,
                        ),
                      ),
                    ),
                  ),
          ),
          cell(
            width: _blockTimeColumnWidth,
            alignment: Alignment.center,
            padding: EdgeInsets.zero,
            child: isBedRow
                ? const Center(child: Text('—', style: TextStyle(fontSize: 12)))
                : SizedBox.expand(
                    child: Focus(
                      onFocusChange: (hasFocus) {
                        if (!hasFocus) {
                          _commitBlockEndTimeInput(
                              block, blockEndController.text);
                        }
                      },
                      child: TextField(
                        controller: blockEndController,
                        textAlign: TextAlign.center,
                        textAlignVertical: TextAlignVertical.center,
                        keyboardType: TextInputType.datetime,
                        style: theme.textTheme.bodySmall,
                        decoration: InputDecoration(
                          border: InputBorder.none,
                          isCollapsed: true,
                          filled: true,
                          fillColor: rowBackground,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 2.0,
                            vertical: 16.0,
                          ),
                          constraints: const BoxConstraints(
                            minHeight: rowHeight,
                            maxHeight: rowHeight,
                          ),
                          hintText: 'HH:mm',
                          hintStyle: const TextStyle(fontSize: 12),
                        ),
                        onSubmitted: (_) => _commitBlockEndTimeInput(
                          block,
                          blockEndController.text,
                        ),
                      ),
                    ),
                  ),
          ),
          cell(
            flex: _blockNameColumnFlex,
            padding: EdgeInsets.zero,
            child: isWakeRow
                ? Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '起床',
                        style: theme.textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                : isBedRow
                    ? Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 6),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '就寝',
                            style: theme.textTheme.bodySmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                    : ExcelLikeTitleCell(
                        controller: nameController,
                        rowHeight: rowHeight,
                        borderColor: const Color(0x00000000),
                        placeholder: '名称未設定',
                        onChanged: (_) {
                          _debounceSave(
                            _representativeNameSaveTimers,
                            block.id,
                            () => _commitRepresentativeNameChange(
                              block,
                              nameController.text,
                            ),
                          );
                        },
                        onCommit: () {
                          _representativeNameSaveTimers[block.id]?.cancel();
                          _commitRepresentativeNameChange(
                              block, nameController.text);
                        },
                      ),
          ),
          if (isWakeRow) ...[
            cell(
                width: _blockMetricColumnWidth, child: const SizedBox.shrink()),
            cell(
                width: _blockMetricColumnWidth, child: const SizedBox.shrink()),
            cell(
                width: _blockExcludeColumnWidth,
                child: const SizedBox.shrink()),
            cell(flex: _blockProjectColumnFlex, child: const SizedBox.shrink()),
            cell(
                flex: _blockSubProjectColumnFlex,
                child: const SizedBox.shrink()),
            cell(flex: _blockModeColumnFlex, child: const SizedBox.shrink()),
            cell(
                flex: _blockLocationColumnFlex, child: const SizedBox.shrink()),
            cell(flex: _blockActionColumnFlex, child: const SizedBox.shrink()),
            cell(flex: _blockActionColumnFlex, child: const SizedBox.shrink()),
            cell(flex: _blockActionColumnFlex, child: const SizedBox.shrink()),
          ] else ...[
            cell(
              width: _blockMetricColumnWidth,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Focus(
                onFocusChange: (hasFocus) {
                  if (!hasFocus) {
                    _commitBlockWorkingMinutesChange(
                      block,
                      totalMinutes,
                      blockWorkingController.text,
                    );
                  }
                },
                child: TextField(
                  controller: blockWorkingController,
                  textAlign: TextAlign.center,
                  textAlignVertical: TextAlignVertical.center,
                  keyboardType: TextInputType.number,
                  style: theme.textTheme.bodySmall,
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    isCollapsed: true,
                    filled: true,
                    fillColor: rowBackground,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 2.0,
                      vertical: 10.0,
                    ),
                    hintText: '0',
                    hintStyle: const TextStyle(fontSize: 12),
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                  ],
                  onSubmitted: (_) => _commitBlockWorkingMinutesChange(
                    block,
                    totalMinutes,
                    blockWorkingController.text,
                  ),
                ),
              ),
            ),
            cell(
              width: _blockMetricColumnWidth,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Focus(
                onFocusChange: (hasFocus) {
                  if (!hasFocus) {
                    _commitBlockBreakMinutesChange(
                      block,
                      totalMinutes,
                      blockBreakController.text,
                    );
                  }
                },
                child: TextField(
                  controller: blockBreakController,
                  textAlign: TextAlign.center,
                  textAlignVertical: TextAlignVertical.center,
                  keyboardType: TextInputType.number,
                  style: theme.textTheme.bodySmall,
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    isCollapsed: true,
                    filled: true,
                    fillColor: rowBackground,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 2.0,
                      vertical: 10.0,
                    ),
                    hintText: '0',
                    hintStyle: const TextStyle(fontSize: 12),
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                  ],
                  onSubmitted: (_) => _commitBlockBreakMinutesChange(
                    block,
                    totalMinutes,
                    blockBreakController.text,
                  ),
                ),
              ),
            ),
            cell(
              width: _blockExcludeColumnWidth,
              alignment: Alignment.center,
              padding: EdgeInsets.zero,
              child: Checkbox(
                value: block.excludeFromReport == true,
                onChanged: (v) => _commitBlockExcludeFromReportChange(
                  block,
                  v == true,
                ),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
            cell(
              flex: _blockProjectColumnFlex,
              child: ProjectInputField(
                controller: projectController,
                useOutlineBorder: false,
                withBackground: false,
                includeArchived: true,
                showAllOnTap: true,
                height: 32,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 6.0, vertical: 10.0),
                onProjectChanged: (projectId) async {
                  await _applyRepresentativeProjectChange(block, projectId);
                },
                onAutoSave: () {},
              ),
            ),
            cell(
              flex: _blockSubProjectColumnFlex,
              child: subProjectInput,
            ),
            cell(
              flex: _blockModeColumnFlex,
              child: ModeInputField(
                controller: modeController,
                useOutlineBorder: false,
                withBackground: false,
                hintText: 'モード',
                onModeChanged: (modeId) async {
                  await _applyRepresentativeModeChange(block, modeId);
                },
                onAutoSave: () {},
              ),
            ),
            cell(
              flex: _blockLocationColumnFlex,
              padding: EdgeInsets.zero,
              child: ExcelLikeTitleCell(
                controller: locationController,
                rowHeight: rowHeight,
                borderColor: const Color(0x00000000),
                placeholder: '未設定',
                onChanged: (_) {},
                onCommit: () => _commitRepresentativeLocationChange(
                  block,
                  locationController.text,
                ),
              ),
            ),
            iconCell(
              icon: Icons.playlist_add,
              tooltip: 'タスク追加',
              onPressed: () => _addTaskToBlock(block),
            ),
            iconCell(
              icon: Icons.edit_outlined,
              tooltip: 'ブロック編集',
              onPressed: () => _editBlock(block),
            ),
            iconCell(
              icon: Icons.delete_outline,
              tooltip: 'ブロック削除',
              color: theme.colorScheme.error,
              onPressed: () => _deleteBlock(block),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildExpandedBlockTaskSection(
    BuildContext context,
    rbv2.RoutineBlockV2 block,
    List<_ScheduledTask> scheduledTasks,
    Set<String> taskControllerIds, {
    required bool showBottomBorder,
  }) {
    final theme = Theme.of(context);
    final borderColor = theme.dividerColor;

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          left: BorderSide(color: borderColor, width: _cellBorderStrokeWidth),
          right: BorderSide(color: borderColor, width: _cellBorderStrokeWidth),
          bottom: showBottomBorder
              ? BorderSide(color: borderColor, width: _cellBorderStrokeWidth)
              : BorderSide.none,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (scheduledTasks.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(
                  'タスクがありません。＋から追加できます。',
                  style: theme.textTheme.bodySmall,
                ),
              )
            else ...[
              _buildTaskTableHeader(context),
              for (int i = 0; i < scheduledTasks.length; i++)
                _buildTaskCard(
                  context,
                  block,
                  scheduledTasks,
                  i,
                  taskControllerIds,
                ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _commitBlockStartTimeInput(
    rbv2.RoutineBlockV2 block,
    String rawValue,
  ) async {
    final parsed = _parseTimeText(rawValue);
    if (parsed == null) {
      _showInvalidTimeSnack('開始時刻は HH:mm か 4桁(例: 0930) で入力してください');
      _blockStartTimeControllers[block.id]?.text =
          _formatTimeOfDay(block.startTime);
      return;
    }
    final normalized = _formatTimeOfDay(parsed);
    _blockStartTimeControllers[block.id]?.text = normalized;
    if (_timeOfDayToMinutes(parsed) == _timeOfDayToMinutes(block.startTime)) {
      return;
    }
    final updated = block.copyWith(
      startTime: parsed,
      lastModified: DateTime.now(),
      version: block.version + 1,
    );
    await _mutationFacade.updateBlock(updated);
    if (mounted) {
      final fresh = _findBlockV2InTemplate(block.id);
      if (fresh != null) _syncBlockWorkBreakControllersFromBlock(fresh);
      setState(() {});
    }
  }

  Future<void> _commitBlockEndTimeInput(
    rbv2.RoutineBlockV2 block,
    String rawValue,
  ) async {
    final parsed = _parseTimeText(rawValue);
    if (parsed == null) {
      _showInvalidTimeSnack('終了時刻は HH:mm か 4桁(例: 1830) で入力してください');
      _blockEndTimeControllers[block.id]?.text =
          _formatTimeOfDay(block.endTime);
      return;
    }
    final normalized = _formatTimeOfDay(parsed);
    _blockEndTimeControllers[block.id]?.text = normalized;
    if (_timeOfDayToMinutes(parsed) == _timeOfDayToMinutes(block.endTime)) {
      return;
    }
    final updated = block.copyWith(
      endTime: parsed,
      lastModified: DateTime.now(),
      version: block.version + 1,
    );
    await _mutationFacade.updateBlock(updated);

    // 次のブロックの開始時刻を、変更した終了時刻に合わせる
    await _alignNextBlockStartToPreviousEnd(block.id, parsed);

    if (mounted) {
      final fresh = _findBlockV2InTemplate(block.id);
      if (fresh != null) _syncBlockWorkBreakControllersFromBlock(fresh);
      setState(() {});
    }
  }

  /// 指定ブロックの次のブロックの開始時刻を、前ブロックの終了時刻に合わせる
  Future<void> _alignNextBlockStartToPreviousEnd(
    String previousBlockId,
    TimeOfDay newEndTime,
  ) async {
    final blocks =
        RoutineDatabaseService.getBlocksForTemplate(widget.routine.id);
    final idx = blocks.indexWhere((b) => b.id == previousBlockId);
    if (idx < 0 || idx + 1 >= blocks.length) return;
    final nextBlock = blocks[idx + 1];
    if (_timeOfDayToMinutes(nextBlock.startTime) ==
        _timeOfDayToMinutes(newEndTime)) {
      return;
    }
    final duration =
        _blockDurationMinutes(nextBlock.startTime, nextBlock.endTime);
    final newEndMinutes = _timeOfDayToMinutes(newEndTime) + duration;
    final newNextEnd = _minutesToTimeOfDay(newEndMinutes);
    final updatedNext = nextBlock.copyWith(
      startTime: newEndTime,
      endTime: newNextEnd,
      lastModified: DateTime.now(),
      version: nextBlock.version + 1,
    );
    await _mutationFacade.updateBlock(updatedNext);
    _blockStartTimeControllers[nextBlock.id]?.text =
        _formatTimeOfDay(newEndTime);
    _blockEndTimeControllers[nextBlock.id]?.text = _formatTimeOfDay(newNextEnd);
    if (mounted) {
      final freshNext = _findBlockV2InTemplate(nextBlock.id);
      if (freshNext != null) {
        _syncBlockWorkBreakControllersFromBlock(freshNext);
      }
    }
  }

  Future<void> _openBlockTaskAssignmentScreen(rbv2.RoutineBlockV2 block) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RoutineBlockTaskAssignmentTableScreen(
          routine: widget.routine,
          blockId: block.id,
        ),
      ),
    );
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _pickBlockTime(
    rbv2.RoutineBlockV2 block, {
    required bool isStart,
  }) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: isStart ? block.startTime : block.endTime,
    );
    if (picked == null) return;
    final current = isStart ? block.startTime : block.endTime;
    if (picked.hour == current.hour && picked.minute == current.minute) {
      return;
    }
    final updated = block.copyWith(
      startTime: isStart ? picked : block.startTime,
      endTime: isStart ? block.endTime : picked,
      lastModified: DateTime.now(),
      version: block.version + 1,
    );
    await _mutationFacade.updateBlock(updated);

    if (isStart) {
      _blockStartTimeControllers[block.id]?.text = _formatTimeOfDay(picked);
    } else {
      _blockEndTimeControllers[block.id]?.text = _formatTimeOfDay(picked);
      await _alignNextBlockStartToPreviousEnd(block.id, picked);
    }

    if (mounted) {
      final fresh = _findBlockV2InTemplate(block.id);
      if (fresh != null) _syncBlockWorkBreakControllersFromBlock(fresh);
      setState(() {});
    }
  }

  String _formatTimeOfDay(TimeOfDay time) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }

  Widget _buildBlockCard(
    BuildContext context,
    rbv2.RoutineBlockV2 block,
    List<rtv2.RoutineTaskV2> blockTasks,
    Set<String> taskControllerIds,
  ) {
    final theme = Theme.of(context);
    final useMobileCards = _shouldUseMobileTaskCards(context);
    final isExcluded = block.excludeFromReport == true;
    final hasTasks = blockTasks.isNotEmpty;
    final isExpanded =
        (!useMobileCards || hasTasks) && _expandedBlockIdsV2.contains(block.id);
    final scheduledTasks = _buildScheduledTasks(block, blockTasks);
    final blockTitle = _blockDisplayName(block);
    final blockRange = _formatTimeRange(block.startTime, block.endTime);
    final isLight = theme.brightness == Brightness.light;

    return Container(
      margin: useMobileCards
          ? const EdgeInsets.symmetric(vertical: 8)
          : const EdgeInsets.only(bottom: 16),
      decoration: useMobileCards
          ? BoxDecoration(
              // 集計外ブロックは少し暗めのトーンにする
              color: isExcluded
                  ? theme.colorScheme.surfaceContainerHighest
                  : theme.cardColor,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isExcluded
                    ? theme.colorScheme.outlineVariant
                    : theme.dividerColor,
              ),
              boxShadow: [
                BoxShadow(
                  color: theme.colorScheme.shadow.withOpacity(
                    theme.brightness == Brightness.light
                        ? (isExcluded ? 0.04 : 0.08)
                        : (isExcluded ? 0.18 : 0.30),
                  ),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            )
          : BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: theme.dividerColor.withOpacity(isLight ? 0.6 : 0.3),
              ),
              boxShadow: [
                if (isLight)
                  BoxShadow(
                    color: theme.colorScheme.shadow.withOpacity(0.08),
                    blurRadius: 18,
                    offset: const Offset(0, 10),
                  ),
              ],
            ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _buildBlockCardHeader(
            context,
            block,
            blockTitle,
            blockRange,
            isExpanded,
            hasTasks,
          ),
          if (useMobileCards && isExpanded) const Divider(height: 1),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            transitionBuilder: (child, animation) =>
                SizeTransition(sizeFactor: animation, child: child),
            child: isExpanded
                ? _buildBlockCardBody(
                    context,
                    block,
                    scheduledTasks,
                    taskControllerIds,
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _buildBlockCardHeader(
    BuildContext context,
    rbv2.RoutineBlockV2 block,
    String blockTitle,
    String blockRange,
    bool isExpanded,
    bool canExpandMobile,
  ) {
    final theme = Theme.of(context);
    final iconButtonTheme = IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: theme.colorScheme.onSurfaceVariant,
      ),
    );
    final useMobileCards = _shouldUseMobileTaskCards(context);
    final durationText = _formatWorkBreakText(
      block,
      // スマホカードの2行目は括弧なし
      wrapInParens: !useMobileCards,
      // 集計外ONのときは作業/休憩を 0 表示
      zeroWhenExcluded: true,
    );

    void toggle() {
      if (useMobileCards && !canExpandMobile) return;
      setState(() {
        if (isExpanded) {
          _expandedBlockIdsV2.remove(block.id);
        } else {
          _expandedBlockIdsV2.add(block.id);
        }
      });
    }

    if (useMobileCards) {
      return ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        onTap: canExpandMobile ? toggle : null,
        title: Text(
          blockTitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleSmall,
        ),
        subtitle: Text(
          // スマホ（カード表示）では「時間帯」と「(稼働/休憩…)」を2行に固定する
          // （最初から改行して表示する）
          durationText.isEmpty ? blockRange : '$blockRange\n$durationText',
          style: theme.textTheme.bodySmall,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: IconButtonTheme(
          data: iconButtonTheme,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'タスク追加',
                icon: const Icon(Icons.playlist_add, size: 20),
                onPressed: () => _addTaskToBlock(block),
              ),
              IconButton(
                tooltip: 'ブロック編集',
                icon: const Icon(Icons.edit_outlined, size: 20),
                onPressed: () => _editBlock(block),
              ),
              IconButton(
                tooltip: 'ブロック削除',
                icon: const Icon(Icons.delete_outline, size: 20),
                onPressed: () => _deleteBlock(block),
              ),
              if (canExpandMobile)
                IconButton(
                  tooltip: isExpanded ? '折りたたむ' : '展開',
                  icon: Icon(
                    isExpanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 20,
                  ),
                  onPressed: toggle,
                ),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: toggle,
                  child: Row(
                    children: [
                      Text(
                        blockRange,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (durationText.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Text(
                          durationText,
                          // ブロック行の表示（時間帯/ブロック名）と見た目を揃える
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          blockTitle,
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              IconButtonTheme(
                data: iconButtonTheme,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: '\u30bf\u30b9\u30af\u8ffd\u52a0',
                      icon: const Icon(Icons.playlist_add),
                      onPressed: () => _addTaskToBlock(block),
                    ),
                    IconButton(
                      tooltip: '\u30d6\u30ed\u30c3\u30af\u7de8\u96c6',
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () => _editBlock(block),
                    ),
                    IconButton(
                      tooltip: '\u30d6\u30ed\u30c3\u30af\u524a\u9664',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _deleteBlock(block),
                    ),
                    IconButton(
                      tooltip: isExpanded
                          ? '\u6298\u308a\u305f\u305f\u3080'
                          : '\u5c55\u958b',
                      icon: Icon(
                        isExpanded ? Icons.expand_less : Icons.expand_more,
                      ),
                      onPressed: toggle,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBlockCardBody(
    BuildContext context,
    rbv2.RoutineBlockV2 block,
    List<_ScheduledTask> scheduledTasks,
    Set<String> taskControllerIds,
  ) {
    final useMobileCards = _shouldUseMobileTaskCards(context);
    return Padding(
      padding: useMobileCards
          ? const EdgeInsets.fromLTRB(0, 0, 0, 12)
          : const EdgeInsets.fromLTRB(16, 0, 16, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!useMobileCards) ...[
            _buildTaskTableHeader(context),
            _buildRepresentativeTaskRow(context, block),
            for (int i = 0; i < scheduledTasks.length; i++) ...[
              _buildTaskCard(
                context,
                block,
                scheduledTasks,
                i,
                taskControllerIds,
              ),
            ],
          ] else ...[
            // スマホ版では「代表タスク」の表示は不要
            for (int i = 0; i < scheduledTasks.length; i++) ...[
              _buildMobileScheduledTaskCard(
                context,
                block,
                scheduledTasks,
                i,
                taskControllerIds,
              ),
              if (i != scheduledTasks.length - 1) const SizedBox(height: 10),
            ],
          ],
        ],
      ),
    );
  }

  bool _shouldUseMobileTaskCards(BuildContext context) {
    // 表は横に列が多く、実表示幅が狭いと破綻するのでカード縦積みに切り替える。
    // Web の左ナビ付き UI ではウィンドウ幅だけ見ると誤判定になるため、上位（NewUIScreen）で
    // MediaQuery.size をパネル幅に寄せたうえで、ここでは幅のみで判定する。
    return MediaQuery.sizeOf(context).width < 800;
  }

  Set<String> _collectExpandableBlockIds(
    RoutineEditorSnapshot snapshot, {
    required bool useMobileCards,
  }) {
    if (!useMobileCards) {
      return snapshot.blocks.map((b) => b.id).toSet();
    }
    final ids = <String>{};
    for (final block in snapshot.blocks) {
      if (snapshot.tasksForBlock(block.id).isNotEmpty) {
        ids.add(block.id);
      }
    }
    return ids;
  }

  bool _areAllBlocksExpanded(
    RoutineEditorSnapshot snapshot, {
    required bool useMobileCards,
  }) {
    final ids =
        _collectExpandableBlockIds(snapshot, useMobileCards: useMobileCards);
    if (ids.isEmpty) return false;
    return ids.every(_expandedBlockIdsV2.contains);
  }

  void _toggleAllBlocksExpansion(
    RoutineEditorSnapshot snapshot, {
    required bool useMobileCards,
  }) {
    final ids =
        _collectExpandableBlockIds(snapshot, useMobileCards: useMobileCards);
    if (ids.isEmpty) return;
    setState(() {
      final allExpanded = ids.every(_expandedBlockIdsV2.contains);
      if (allExpanded) {
        _expandedBlockIdsV2.removeAll(ids);
      } else {
        _expandedBlockIdsV2.addAll(ids);
      }
    });
  }

  Widget _buildMobileRepresentativeCard(
    BuildContext context,
    rbv2.RoutineBlockV2 block,
  ) {
    final theme = Theme.of(context);
    final blockName = _blockDisplayName(block);
    final projectName = _displayText(_getProjectName(block.projectId));
    final subProjectRaw =
        (block.subProject != null && block.subProject!.isNotEmpty)
            ? block.subProject
            : _getSubProjectName(block.subProjectId);
    final subProjectName = _displayText(subProjectRaw);
    final modeName = _displayText(_getModeName(block.modeId));

    Widget lineWithIcon(IconData icon, String text) {
      if (text.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(
          children: [
            Icon(
              icon,
              size: 14,
              color: theme.iconTheme.color?.withOpacity(0.6),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      );
    }

    final subtitleParts = <String>[
      if (projectName.isNotEmpty) projectName,
      if (subProjectName.isNotEmpty) subProjectName,
    ];
    final subtitle = subtitleParts.join(' / ');

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: theme.colorScheme.shadow.withOpacity(
              theme.brightness == Brightness.light ? 0.08 : 0.30,
            ),
            blurRadius: 4,
            offset: const Offset(0, 2),
          )
        ],
        border: Border.all(color: theme.dividerColor),
      ),
      child: InkWell(
        // 一覧は「表示カード」にして、編集はタップで開く（タイムライン方式）
        onTap: () => _editBlock(block),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const SizedBox(
                    width: 40,
                    child: Center(
                      child: Icon(Icons.push_pin, size: 20),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      blockName,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: '編集',
                    icon: const Icon(Icons.edit_outlined, size: 20),
                    onPressed: () => _editBlock(block),
                  ),
                ],
              ),
              if (subtitle.isNotEmpty) lineWithIcon(Icons.folder, subtitle),
              if (modeName.isNotEmpty) lineWithIcon(Icons.psychology, modeName),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMobileScheduledTaskCard(
    BuildContext context,
    rbv2.RoutineBlockV2 block,
    List<_ScheduledTask> scheduledTasks,
    int index,
    Set<String> taskControllerIds,
  ) {
    final theme = Theme.of(context);
    final scheduledTask = scheduledTasks[index];
    final task = scheduledTask.task;

    taskControllerIds.add(task.id);

    final title = (task.name.trim().isNotEmpty) ? task.name.trim() : '(無題)';
    final startText =
        _formatScheduleTimeAbsoluteMinutes(scheduledTask.startAbsoluteMinutes);
    final endText =
        _formatScheduleTimeAbsoluteMinutes(scheduledTask.endAbsoluteMinutes);
    final rangeText = '$startText–$endText';

    final projectName = _displayText(_getProjectName(task.projectId));
    final subProjectName = _displayText(_getSubProjectName(task.subProjectId));
    final modeName = _displayText(_getModeName(task.modeId));
    final durationText = (scheduledTask.durationMinutes > 0)
        ? '${scheduledTask.durationMinutes}分'
        : '';

    Widget lineWithIcon(IconData icon, String text) {
      if (text.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(
          children: [
            Icon(
              icon,
              size: 14,
              color: theme.iconTheme.color?.withOpacity(0.6),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      );
    }

    final subtitleParts = <String>[
      if (projectName.isNotEmpty) projectName,
      if (subProjectName.isNotEmpty) subProjectName,
    ];
    final subtitle = subtitleParts.join(' / ');

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: theme.colorScheme.shadow.withOpacity(
              theme.brightness == Brightness.light ? 0.08 : 0.30,
            ),
            blurRadius: 4,
            offset: const Offset(0, 2),
          )
        ],
        border: Border.all(color: theme.dividerColor),
      ),
      child: InkWell(
        onTap: () => _editTask(task),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 40,
                child: Center(
                  child: Text(
                    startText,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ),
              const SizedBox(width: 8),
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
                    lineWithIcon(Icons.schedule,
                        '$rangeText${durationText.isEmpty ? '' : ' / $durationText'}'),
                    if (subtitle.isNotEmpty)
                      lineWithIcon(Icons.folder, subtitle),
                    if (modeName.isNotEmpty)
                      lineWithIcon(Icons.psychology, modeName),
                  ],
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '編集',
                    icon: const Icon(Icons.edit_outlined, size: 20),
                    onPressed: () => _editTask(task),
                  ),
                  IconButton(
                    tooltip: '全項目を編集',
                    icon: const Icon(Icons.tune, size: 20),
                    onPressed: () => _editTaskFull(task),
                  ),
                  IconButton(
                    tooltip: '削除',
                    icon: Icon(
                      Icons.delete_outline,
                      size: 20,
                      color: theme.colorScheme.error,
                    ),
                    onPressed: () => _deleteTask(task),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTaskTableHeader(BuildContext context) {
    final theme = Theme.of(context);
    final borderColor = theme.dividerColor;
    final headerStyle = theme.textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.bold,
          color: theme.textTheme.bodySmall?.color,
        ) ??
        const TextStyle(fontSize: 12, fontWeight: FontWeight.bold);
    const double headerHeight = 36;

    Widget headerCell({
      int? flex,
      double? width,
      required Widget child,
      bool addRightBorder = true,
      Alignment alignment = Alignment.centerLeft,
      EdgeInsetsGeometry padding =
          const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
    }) {
      final decorated = Container(
        height: headerHeight,
        alignment: alignment,
        padding: padding,
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest
              .withOpacity(theme.brightness == Brightness.light ? 1 : 0.2),
          border: Border(
            right: addRightBorder
                ? BorderSide(color: borderColor)
                : BorderSide.none,
          ),
        ),
        child: child,
      );
      if (flex != null) {
        return Expanded(flex: flex, child: decorated);
      }
      if (width != null) {
        return SizedBox(width: width, child: decorated);
      }
      return decorated;
    }

    final headerCells = <Widget>[
      headerCell(
        width: _timeColumnWidth,
        alignment: Alignment.center,
        child: Text('\u958b\u59cb', style: headerStyle),
        addRightBorder: false,
      ),
      headerCell(
        width: _separatorColumnWidth,
        alignment: Alignment.center,
        child: Text('-', style: headerStyle),
        padding: EdgeInsets.zero,
        addRightBorder: false,
      ),
      headerCell(
        width: _timeColumnWidth,
        alignment: Alignment.center,
        child: Text('\u7d42\u4e86', style: headerStyle),
      ),
      headerCell(
        flex: _durationColumnFlex,
        alignment: Alignment.center,
        child: Text('\u6240\u8981', style: headerStyle),
      ),
      headerCell(
        flex: _nameColumnFlex,
        child: Text('\u30bf\u30b9\u30af\u540d', style: headerStyle),
      ),
      headerCell(
        flex: _projectColumnFlex,
        child: Text('\u30d7\u30ed\u30b8\u30a7\u30af\u30c8', style: headerStyle),
      ),
      headerCell(
        flex: _subProjectColumnFlex,
        child: Text('\u30b5\u30d6\u30d7\u30ed\u30b8\u30a7\u30af\u30c8',
            style: headerStyle),
      ),
      headerCell(
        flex: _modeColumnFlex,
        child: Text('\u30e2\u30fc\u30c9', style: headerStyle),
      ),
      headerCell(
        flex: _locationColumnFlex,
        child: Text('\u5834\u6240', style: headerStyle),
      ),
      headerCell(
        flex: _detailsColumnFlex,
        child: Text('\u8a73\u7d30', style: headerStyle),
      ),
      headerCell(
        width: _actionColumnWidth,
        alignment: Alignment.center,
        child: Text('\u901a\u77e5', style: headerStyle),
      ),
      headerCell(
        width: _actionColumnWidth,
        alignment: Alignment.center,
        child: Text('\u7de8\u96c6', style: headerStyle),
      ),
      headerCell(
        width: _actionColumnWidth,
        alignment: Alignment.center,
        child: Text('\u5168\u9805\u76ee', style: headerStyle),
      ),
      headerCell(
        width: _actionColumnWidth,
        alignment: Alignment.center,
        addRightBorder: false,
        child: Text('\u524a\u9664', style: headerStyle),
      ),
    ];

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: borderColor),
      ),
      child: Row(children: headerCells),
    );
  }

  Widget _buildRepresentativeTaskRow(
    BuildContext context,
    rbv2.RoutineBlockV2 block,
  ) {
    final theme = Theme.of(context);
    const double cellHeight = 36;
    final borderColor = theme.dividerColor;

    Widget buildCell({
      int? flex,
      double? width,
      bool addRightBorder = true,
      Alignment alignment = Alignment.centerLeft,
      EdgeInsetsGeometry padding = const EdgeInsets.symmetric(horizontal: 8),
      required Widget child,
    }) {
      final decorated = Container(
        height: cellHeight,
        alignment: alignment,
        padding: padding,
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(
            right: addRightBorder
                ? BorderSide(
                    color: borderColor,
                    width: _cellBorderStrokeWidth,
                  )
                : BorderSide.none,
          ),
        ),
        child: child,
      );
      if (flex != null) {
        return Expanded(
          flex: flex,
          child: SizedBox(height: cellHeight, child: decorated),
        );
      }
      if (width != null) {
        return SizedBox(width: width, height: cellHeight, child: decorated);
      }
      return SizedBox(height: cellHeight, child: decorated);
    }

    Widget buildTextFieldCell({
      int? flex,
      double? width,
      required TextEditingController controller,
      String? hintText,
      TextStyle? style,
      EdgeInsetsGeometry contentPadding =
          const EdgeInsets.symmetric(horizontal: 8, vertical: 16),
      ValueChanged<String>? onSubmitted,
      VoidCallback? onFocusLost,
    }) {
      return buildCell(
        flex: flex,
        width: width,
        child: Focus(
          onFocusChange: (hasFocus) {
            if (!hasFocus) {
              onFocusLost?.call();
            }
          },
          child: TextField(
            controller: controller,
            textAlignVertical: TextAlignVertical.center,
            style: style ?? const TextStyle(fontSize: 12, height: 1.0),
            decoration: InputDecoration(
              border: InputBorder.none,
              isCollapsed: true,
              contentPadding: contentPadding,
              hintText: hintText,
              hintStyle: const TextStyle(fontSize: 12),
            ),
            onSubmitted: (value) {
              onSubmitted?.call(value);
            },
          ),
        ),
      );
    }

    Widget buildIconCell({
      required IconData icon,
      required String tooltip,
      required VoidCallback onPressed,
      bool addRightBorder = true,
      Color? color,
    }) {
      return buildCell(
        width: _actionColumnWidth,
        addRightBorder: addRightBorder,
        alignment: Alignment.center,
        padding: EdgeInsets.zero,
        child: IconButton(
          icon: Icon(icon, size: 18, color: color ?? theme.iconTheme.color),
          tooltip: tooltip,
          splashRadius: 18,
          onPressed: onPressed,
        ),
      );
    }

    final nameController = _ensureRepresentativeNameController(block);

    final projectName = _displayText(_getProjectName(block.projectId));
    final projectController =
        _ensureRepresentativeProjectController(block, projectName);

    final subProjectRaw =
        (block.subProject != null && block.subProject!.isNotEmpty)
            ? block.subProject
            : _getSubProjectName(block.subProjectId);
    final subProjectName = _displayText(subProjectRaw);
    final subProjectController =
        _ensureRepresentativeSubProjectController(block, subProjectName);

    final modeName = _displayText(_getModeName(block.modeId));
    final modeController = _ensureRepresentativeModeController(block, modeName);

    final locationName = block.location ?? '';
    final locationController =
        _ensureRepresentativeLocationController(block, locationName);

    final hasProject = (block.projectId ?? '').isNotEmpty;

    const combinedTimeWidth =
        _timeColumnWidth + _separatorColumnWidth + _timeColumnWidth;

    final startCell = buildCell(
      width: combinedTimeWidth,
      addRightBorder: true,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        '\u4ee3\u8868\u30bf\u30b9\u30af',
        style: theme.textTheme.bodySmall?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
    );

    final separatorCell = buildCell(
      width: 0,
      addRightBorder: false,
      padding: EdgeInsets.zero,
      alignment: Alignment.center,
      child: const SizedBox.shrink(),
    );

    final endCell = buildCell(
      width: 0,
      addRightBorder: false,
      alignment: Alignment.center,
      padding: EdgeInsets.zero,
      child: const SizedBox.shrink(),
    );

    final durationCell = buildCell(
      flex: _durationColumnFlex,
      alignment: Alignment.center,
      child: Text(
        '\u2015',
        style: theme.textTheme.bodySmall,
      ),
    );

    final nameCell = buildCell(
      flex: _nameColumnFlex,
      padding: EdgeInsets.zero,
      child: RoutineSleepBlockService.isSleepBlock(block)
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  RoutineSleepBlockService.sleepBlockDisplayLabel,
                  style: theme.textTheme.bodyMedium,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            )
          : ExcelLikeTitleCell(
              controller: nameController,
              rowHeight: cellHeight,
              borderColor: borderColor,
              placeholder: '名称未設定',
              onChanged: (_) {
                _debounceSave(
                  _representativeNameSaveTimers,
                  block.id,
                  () => _commitRepresentativeNameChange(
                      block, nameController.text),
                );
              },
              onCommit: () {
                _representativeNameSaveTimers[block.id]?.cancel();
                _commitRepresentativeNameChange(block, nameController.text);
              },
            ),
    );

    final projectCell = buildCell(
      flex: _projectColumnFlex,
      child: ProjectInputField(
        controller: projectController,
        useOutlineBorder: false,
        withBackground: false,
        includeArchived: true,
        showAllOnTap: true,
        height: 32,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 6.0, vertical: 10.0),
        onProjectChanged: (projectId) async {
          await _applyRepresentativeProjectChange(block, projectId);
        },
        onAutoSave: () {},
      ),
    );

    Widget subProjectInput = SubProjectInputField(
      controller: subProjectController,
      projectId: block.projectId ?? '',
      currentSubProjectId: block.subProjectId,
      useOutlineBorder: false,
      withBackground: false,
      height: 32,
      onSubProjectChanged: (subProjectId, subProjectLabel) async {
        await _applyRepresentativeSubProjectChange(
          block,
          subProjectId,
          subProjectLabel,
        );
      },
    );

    if (!hasProject) {
      subProjectInput = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                  '\u5148\u306b\u30d7\u30ed\u30b8\u30a7\u30af\u30c8\u3092\u8a2d\u5b9a\u3057\u3066\u304f\u3060\u3055\u3044'),
            ),
          );
        },
        child: AbsorbPointer(child: subProjectInput),
      );
    }

    final subProjectCell = buildCell(
      flex: _subProjectColumnFlex,
      child: subProjectInput,
    );

    final modeCell = buildCell(
      flex: _modeColumnFlex,
      child: ModeInputField(
        controller: modeController,
        useOutlineBorder: false,
        withBackground: false,
        hintText: '\u30e2\u30fc\u30c9',
        onModeChanged: (modeId) async {
          await _applyRepresentativeModeChange(block, modeId);
        },
        onAutoSave: () {},
      ),
    );

    final locationCell = buildCell(
      flex: _locationColumnFlex,
      padding: EdgeInsets.zero,
      child: ExcelLikeTitleCell(
        controller: locationController,
        rowHeight: cellHeight,
        borderColor: const Color(0x00000000),
        placeholder: '未設定',
        onChanged: (_) {},
        onCommit: () =>
            _commitRepresentativeLocationChange(block, locationController.text),
      ),
    );

    // ヘッダーと同じ列数に揃える（通知・編集・全項目・削除）。代表行は通知・全項目は空、編集=ブロック編集、削除=ブロック削除
    final rowCells = <Widget>[
      startCell,
      separatorCell,
      endCell,
      durationCell,
      nameCell,
      projectCell,
      subProjectCell,
      modeCell,
      locationCell,
      buildCell(
        flex: _detailsColumnFlex,
        alignment: Alignment.center,
        child: const SizedBox.shrink(),
      ), // 詳細（代表行では未使用）
      buildCell(
        width: _actionColumnWidth,
        alignment: Alignment.center,
        child: const SizedBox.shrink(),
      ), // 通知（代表行では未使用）
      buildIconCell(
        icon: Icons.edit_outlined,
        tooltip: '\u30d6\u30ed\u30c3\u30af\u3092\u7de8\u96c6',
        onPressed: () => _editBlock(block),
      ),
      buildCell(
        width: _actionColumnWidth,
        alignment: Alignment.center,
        child: const SizedBox.shrink(),
      ), // 全項目（代表行では未使用）
      buildIconCell(
        icon: Icons.delete_outline,
        tooltip: '\u30d6\u30ed\u30c3\u30af\u3092\u524a\u9664',
        onPressed: () => _deleteBlock(block),
        addRightBorder: false,
      ),
    ];

    final rowBorder = Border(
      top: BorderSide.none,
      bottom: BorderSide(color: borderColor, width: _cellBorderStrokeWidth),
      left: BorderSide(color: borderColor, width: _cellBorderStrokeWidth),
      right: BorderSide(color: borderColor, width: _cellBorderStrokeWidth),
    );

    return Container(
      decoration: BoxDecoration(
        border: rowBorder,
        color: theme.colorScheme.surface,
      ),
      child: Row(children: rowCells),
    );
  }

  Widget _buildTaskCard(
    BuildContext context,
    rbv2.RoutineBlockV2 block,
    List<_ScheduledTask> scheduledTasks,
    int index,
    Set<String> taskControllerIds,
  ) {
    final theme = Theme.of(context);
    final scheduledTask = scheduledTasks[index];
    final task = scheduledTask.task;

    final projectName = _displayText(_getProjectName(task.projectId));
    final subProjectName = _displayText(_getSubProjectName(task.subProjectId));
    final modeName = _displayText(_getModeName(task.modeId));
    final locationSource = task.location?.isNotEmpty == true
        ? task.location
        : (block.location?.isNotEmpty == true ? block.location : null);
    final location = _displayText(locationSource);
    final hasProject = (task.projectId ?? '').isNotEmpty;

    taskControllerIds.add(task.id);

    final nameController = _ensureNameControllerV2(task);
    final durationController = _ensureDurationControllerV2(task);
    final projectController = _ensureProjectControllerV2(task, projectName);
    final subProjectController =
        _ensureSubProjectControllerV2(task, subProjectName);
    final modeController = _ensureModeControllerV2(task, modeName);
    final locationController = _ensureLocationControllerV2(task, location);

    final bool blockCrossesMidnight = _timeOfDayToMinutes(block.endTime) <=
        _timeOfDayToMinutes(block.startTime);
    final bool lockTimeEdit = blockCrossesMidnight;

    final startTimeText =
        _formatScheduleTimeAbsoluteMinutes(scheduledTask.startAbsoluteMinutes);
    final endTimeText =
        _formatScheduleTimeAbsoluteMinutes(scheduledTask.endAbsoluteMinutes);
    final startTimeController =
        _ensureStartTimeControllerV2(task, startTimeText);
    final endTimeController = _ensureEndTimeControllerV2(task, endTimeText);

    const double cellHeight = 36;
    final borderColor = theme.dividerColor;

    Widget buildCell({
      int? flex,
      double? width,
      bool addRightBorder = true,
      Alignment alignment = Alignment.centerLeft,
      EdgeInsetsGeometry padding = const EdgeInsets.symmetric(horizontal: 8),
      required Widget child,
    }) {
      final decorated = Container(
        height: cellHeight,
        alignment: alignment,
        padding: padding,
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(
            right: addRightBorder
                ? BorderSide(color: borderColor)
                : BorderSide.none,
          ),
        ),
        child: child,
      );
      if (flex != null) {
        return Expanded(
          flex: flex,
          child: SizedBox(height: cellHeight, child: decorated),
        );
      }
      if (width != null) {
        return SizedBox(width: width, height: cellHeight, child: decorated);
      }
      return SizedBox(height: cellHeight, child: decorated);
    }

    Widget buildTextFieldCell({
      int? flex,
      double? width,
      required TextEditingController controller,
      String? hintText,
      TextAlign textAlign = TextAlign.left,
      TextStyle? style,
      TextInputType keyboardType = TextInputType.text,
      List<TextInputFormatter>? inputFormatters,
      EdgeInsetsGeometry contentPadding =
          const EdgeInsets.symmetric(horizontal: 8, vertical: 16),
      ValueChanged<String>? onSubmitted,
      VoidCallback? onFocusLost,
      VoidCallback? onEditingComplete,
      VoidCallback? onTapOutside,
      bool readOnly = false,
      bool addRightBorder = true,
    }) {
      return buildCell(
        flex: flex,
        width: width,
        alignment: textAlign == TextAlign.center
            ? Alignment.center
            : Alignment.centerLeft,
        addRightBorder: addRightBorder,
        child: Focus(
          onFocusChange: (hasFocus) {
            if (!hasFocus) {
              onFocusLost?.call();
            }
          },
          child: TextField(
            controller: controller,
            readOnly: readOnly,
            textAlign: textAlign,
            textAlignVertical: TextAlignVertical.center,
            style: style ?? const TextStyle(fontSize: 12, height: 1.0),
            decoration: InputDecoration(
              border: InputBorder.none,
              isCollapsed: true,
              contentPadding: contentPadding,
              hintText: hintText,
              hintStyle: const TextStyle(fontSize: 12),
            ),
            keyboardType: keyboardType,
            inputFormatters: inputFormatters,
            onSubmitted: (value) {
              if (onSubmitted != null) {
                onSubmitted(value);
              }
              onEditingComplete?.call();
            },
            onEditingComplete: onEditingComplete,
            onTapOutside: onTapOutside == null
                ? null
                : (event) {
                    onTapOutside();
                  },
          ),
        ),
      );
    }

    Widget buildIconCell({
      required IconData icon,
      required String tooltip,
      required VoidCallback onPressed,
      Color? color,
      bool addRightBorder = true,
    }) {
      return buildCell(
        width: _actionColumnWidth,
        addRightBorder: addRightBorder,
        alignment: Alignment.center,
        padding: EdgeInsets.zero,
        child: IconButton(
          icon: Icon(icon, size: 18, color: color ?? theme.iconTheme.color),
          tooltip: tooltip,
          splashRadius: 18,
          onPressed: onPressed,
        ),
      );
    }

    final startTimeCell = buildTextFieldCell(
      width: _timeColumnWidth,
      controller: startTimeController,
      hintText: lockTimeEdit ? null : 'HH:MM',
      textAlign: TextAlign.center,
      keyboardType: lockTimeEdit ? TextInputType.text : TextInputType.number,
      inputFormatters: lockTimeEdit
          ? null
          : [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9:]+')),
            ],
      onSubmitted: lockTimeEdit
          ? null
          : (value) => _commitStartTimeChange(
                block,
                scheduledTasks,
                index,
                value,
              ),
      onFocusLost: lockTimeEdit
          ? null
          : () => _commitStartTimeChange(
                block,
                scheduledTasks,
                index,
                startTimeController.text,
              ),
      readOnly: lockTimeEdit,
      style: theme.textTheme.bodySmall,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 0.0, vertical: 10.0),
      addRightBorder: false,
    );

    final endTimeCell = buildTextFieldCell(
      width: _timeColumnWidth,
      controller: endTimeController,
      hintText: lockTimeEdit ? null : 'HH:MM',
      textAlign: TextAlign.center,
      keyboardType: lockTimeEdit ? TextInputType.text : TextInputType.number,
      inputFormatters: lockTimeEdit
          ? null
          : [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9:]+')),
            ],
      onSubmitted: lockTimeEdit
          ? null
          : (value) => _commitEndTimeChange(
                block,
                scheduledTasks,
                index,
                value,
              ),
      onFocusLost: lockTimeEdit
          ? null
          : () => _commitEndTimeChange(
                block,
                scheduledTasks,
                index,
                endTimeController.text,
              ),
      readOnly: lockTimeEdit,
      style: theme.textTheme.bodySmall,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 0.0, vertical: 10.0),
    );

    final durationCell = buildTextFieldCell(
      flex: _durationColumnFlex,
      controller: durationController,
      hintText: '\u6240\u8981(\u5206)',
      textAlign: TextAlign.center,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      onSubmitted: (value) => _commitDurationChange(task, value),
      onFocusLost: () => _commitDurationChange(task, durationController.text),
      style: theme.textTheme.bodySmall,
      // NOTE: cellHeight(36) に対して contentPadding の縦が大きいと
      // 値が表示領域外に押し出され、所要時間が「表示されない」状態になる。
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 0.0, vertical: 10.0),
    );

    final nameCell = buildCell(
      flex: _nameColumnFlex,
      padding: EdgeInsets.zero,
      child: ExcelLikeTitleCell(
        controller: nameController,
        rowHeight: cellHeight,
        borderColor: borderColor,
        placeholder: '(無題)',
        onChanged: (_) {
          _debounceSave(
            _taskNameSaveTimersV2,
            task.id,
            () => _commitNameChange(task, nameController.text),
          );
        },
        onCommit: () {
          _taskNameSaveTimersV2[task.id]?.cancel();
          _commitNameChange(task, nameController.text);
        },
      ),
    );

    final projectCell = buildCell(
      flex: _projectColumnFlex,
      child: ProjectInputField(
        controller: projectController,
        useOutlineBorder: false,
        withBackground: false,
        includeArchived: true,
        showAllOnTap: true,
        height: 32,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 6.0,
          vertical: 10.0,
        ),
        onProjectChanged: (projectId) async {
          await _applyProjectChange(task, projectId);
        },
        onAutoSave: () {},
      ),
    );

    Widget subProjectInput = SubProjectInputField(
      controller: subProjectController,
      projectId: task.projectId ?? '',
      currentSubProjectId: task.subProjectId,
      useOutlineBorder: false,
      withBackground: false,
      height: 32,
      onSubProjectChanged: (subProjectId, subProjectLabel) async {
        await _applySubProjectChange(task, subProjectId, subProjectLabel);
      },
    );

    if (!hasProject) {
      subProjectInput = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                  '\u5148\u306b\u30d7\u30ed\u30b8\u30a7\u30af\u30c8\u3092\u8a2d\u5b9a\u3057\u3066\u304f\u3060\u3055\u3044'),
            ),
          );
        },
        child: AbsorbPointer(child: subProjectInput),
      );
    }

    final subProjectCell = buildCell(
      flex: _subProjectColumnFlex,
      child: subProjectInput,
    );

    final modeCell = buildCell(
      flex: _modeColumnFlex,
      child: ModeInputField(
        controller: modeController,
        useOutlineBorder: false,
        withBackground: false,
        hintText: '\u30e2\u30fc\u30c9',
        onModeChanged: (modeId) async {
          await _applyModeChange(task, modeId);
        },
        onAutoSave: () {},
      ),
    );

    final locationCell = buildCell(
      flex: _locationColumnFlex,
      padding: EdgeInsets.zero,
      child: ExcelLikeTitleCell(
        controller: locationController,
        rowHeight: cellHeight,
        borderColor: const Color(0x00000000),
        placeholder: '未設定',
        onChanged: (_) {},
        onCommit: () => _commitLocationChange(task, locationController.text),
      ),
    );

    final detailsController = _ensureDetailsControllerV2(task);
    final detailsCell = buildCell(
      flex: _detailsColumnFlex,
      padding: EdgeInsets.zero,
      child: ExcelLikeTitleCell(
        controller: detailsController,
        rowHeight: cellHeight,
        borderColor: const Color(0x00000000),
        placeholder: '詳細',
        onChanged: (_) {},
        onCommit: () => _commitDetailsChange(task, detailsController.text),
      ),
    );

    final notificationCell = buildCell(
      width: _actionColumnWidth,
      alignment: Alignment.center,
      padding: EdgeInsets.zero,
      child: Switch(
        value: task.isEvent,
        onChanged: (value) => _commitIsEventChange(task, value),
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );

    final rowCells = <Widget>[
      startTimeCell,
      buildCell(
        width: _separatorColumnWidth,
        addRightBorder: false,
        alignment: Alignment.center,
        child: Text('-', style: theme.textTheme.bodySmall),
        padding: EdgeInsets.zero,
      ),
      endTimeCell,
      durationCell,
      nameCell,
      projectCell,
      subProjectCell,
      modeCell,
      locationCell,
      detailsCell,
      notificationCell,
      buildIconCell(
        icon: Icons.edit_outlined,
        tooltip: '\u7de8\u96c6',
        onPressed: () => _editTask(task),
      ),
      buildIconCell(
        icon: Icons.tune,
        tooltip: '\u5168\u9805\u76ee\u3092\u7de8\u96c6',
        onPressed: () => _editTaskFull(task),
      ),
      buildIconCell(
        icon: Icons.delete_outline,
        tooltip: '\u524a\u9664',
        color: theme.colorScheme.error,
        onPressed: () => _deleteTask(task),
        addRightBorder: false,
      ),
    ];

    final rowBorder = Border(
      top: BorderSide.none,
      bottom: BorderSide(color: borderColor),
      left: BorderSide(color: borderColor),
      right: BorderSide(color: borderColor),
    );

    final row = Container(
      decoration: BoxDecoration(
        border: rowBorder,
        color: theme.colorScheme.surface,
      ),
      child: Row(children: rowCells),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        row,
        if (task.details != null && task.details!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 8, right: 8),
            child: Text(
              task.details!,
              style: theme.textTheme.bodySmall,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }

  List<_ScheduledTask> _buildScheduledTasks(
      rbv2.RoutineBlockV2 block, List<rtv2.RoutineTaskV2> tasks) {
    if (tasks.isEmpty) return const <_ScheduledTask>[];

    DateTime asDate(TimeOfDay t) => DateTime(0, 1, 1, t.hour, t.minute);
    final base = DateTime(0, 1, 1);
    int absMinutes(DateTime dt) => dt.difference(base).inMinutes;

    final blockStart = asDate(block.startTime);
    var blockEnd = asDate(block.endTime);
    if (!blockEnd.isAfter(blockStart)) {
      blockEnd = blockEnd.add(const Duration(days: 1));
    }

    var cursor = blockStart;
    final scheduled = <_ScheduledTask>[];

    for (final task in tasks) {
      final fallbackMinutes = AppSettingsService.getInt(
        AppSettingsService.keyTaskDefaultEstimatedMinutes,
        defaultValue: 0,
      );
      final durationMinutes =
          task.estimatedDuration > 0 ? task.estimatedDuration : fallbackMinutes;
      final scheduledStart = cursor;
      var scheduledEnd = cursor.add(Duration(minutes: durationMinutes));
      if (scheduledEnd.isAfter(blockEnd)) {
        scheduledEnd = blockEnd;
      }

      scheduled.add(
        _ScheduledTask(
          task: task,
          start: TimeOfDay(
              hour: scheduledStart.hour, minute: scheduledStart.minute),
          end: TimeOfDay(hour: scheduledEnd.hour, minute: scheduledEnd.minute),
          startAbsoluteMinutes: absMinutes(scheduledStart),
          endAbsoluteMinutes: absMinutes(scheduledEnd),
          durationMinutes: scheduledEnd.difference(scheduledStart).inMinutes,
        ),
      );

      cursor = scheduledEnd;
    }

    return scheduled;
  }

  String _formatScheduleTimeAbsoluteMinutes(int absoluteMinutes) {
    final dayOffset = absoluteMinutes ~/ (24 * 60);
    final inDay = absoluteMinutes % (24 * 60);
    final h = inDay ~/ 60;
    final m = inDay % 60;
    final hhmm =
        '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
    if (dayOffset <= 0) return hhmm;
    if (dayOffset == 1) return '翌$hhmm';
    return '${dayOffset}日後$hhmm';
  }

  String _displayText(String? value) {
    final normalized = value?.trim();
    if (normalized == null ||
        normalized.isEmpty ||
        normalized == '\u672a\u8a2d\u5b9a') {
      return '';
    }
    return normalized;
  }

  TextEditingController _ensureNameControllerV2(rtv2.RoutineTaskV2 task) {
    final committed = _pendingNameCommitByTaskId[task.id];
    if (committed != null) {
      if (task.name == committed) {
        _pendingNameCommitByTaskId.remove(task.id);
      } else {
        // タスク名コミット直後、スナップショットがまだ古い → 上書きしない
        return _taskNameControllersV2.putIfAbsent(
            task.id, () => TextEditingController(text: committed));
      }
    }
    final controller = _taskNameControllersV2.putIfAbsent(
        task.id, () => TextEditingController(text: task.name));
    if (controller.text != task.name) {
      controller.text = task.name;
    }
    return controller;
  }

  TextEditingController _ensureDurationControllerV2(rtv2.RoutineTaskV2 task) {
    final expected = task.estimatedDuration.toString();
    final controller = _durationControllersV2.putIfAbsent(
        task.id, () => TextEditingController(text: expected));
    if (controller.text != expected) {
      controller.text = expected;
    }
    return controller;
  }

  TextEditingController _ensureProjectControllerV2(
    rtv2.RoutineTaskV2 task,
    String projectName,
  ) {
    if (_pendingProjectClearByTaskId.contains(task.id)) {
      if ((task.projectId ?? '').isEmpty) {
        _pendingProjectClearByTaskId.remove(task.id);
      } else {
        return _projectControllersV2.putIfAbsent(
            task.id, () => TextEditingController(text: projectName));
      }
    }
    final controller = _projectControllersV2.putIfAbsent(
        task.id, () => TextEditingController(text: projectName));
    if (controller.text != projectName) {
      controller.text = projectName;
    }
    return controller;
  }

  TextEditingController _ensureSubProjectControllerV2(
    rtv2.RoutineTaskV2 task,
    String subProjectName,
  ) {
    if (_pendingSubProjectClearByTaskId.contains(task.id)) {
      if ((task.subProjectId ?? '').isEmpty &&
          (task.subProject ?? '').isEmpty) {
        _pendingSubProjectClearByTaskId.remove(task.id);
      } else {
        // プロジェクト変更でサブプロジェクトをクリアした直後、スナップショットがまだ古い → 上書きしない
        final controller = _subProjectControllersV2.putIfAbsent(
            task.id, () => TextEditingController(text: ''));
        if (controller.text.isNotEmpty) controller.text = '';
        return controller;
      }
    }
    final controller = _subProjectControllersV2.putIfAbsent(
        task.id, () => TextEditingController(text: subProjectName));
    if (controller.text != subProjectName) {
      controller.text = subProjectName;
    }
    return controller;
  }

  TextEditingController _ensureModeControllerV2(
    rtv2.RoutineTaskV2 task,
    String modeName,
  ) {
    final controller = _modeControllersV2.putIfAbsent(
        task.id, () => TextEditingController(text: modeName));
    if (controller.text != modeName) {
      controller.text = modeName;
    }
    return controller;
  }

  TextEditingController _ensureLocationControllerV2(
    rtv2.RoutineTaskV2 task,
    String location,
  ) {
    final committed = _pendingLocationCommitByTaskId[task.id];
    if (committed != null) {
      if ((task.location ?? '') == committed) {
        _pendingLocationCommitByTaskId.remove(task.id);
      } else if (location != committed) {
        // コミット直後でスナップショットがまだ古い → コントローラを上書きしない
        return _locationControllersV2.putIfAbsent(
            task.id, () => TextEditingController(text: committed));
      }
    }
    final controller = _locationControllersV2.putIfAbsent(
        task.id, () => TextEditingController(text: location));
    if (controller.text != location) {
      controller.text = location;
    }
    return controller;
  }

  TextEditingController _ensureDetailsControllerV2(rtv2.RoutineTaskV2 task) {
    final details = task.details ?? '';
    final controller = _detailsControllersV2.putIfAbsent(
        task.id, () => TextEditingController(text: details));
    if (controller.text != details) {
      controller.text = details;
    }
    return controller;
  }

  TextEditingController _ensureStartTimeControllerV2(
    rtv2.RoutineTaskV2 task,
    String startText,
  ) {
    final controller = _startTimeControllersV2.putIfAbsent(
        task.id, () => TextEditingController(text: startText));
    if (controller.text != startText) {
      controller.text = startText;
    }
    return controller;
  }

  TextEditingController _ensureEndTimeControllerV2(
    rtv2.RoutineTaskV2 task,
    String endText,
  ) {
    final controller = _endTimeControllersV2.putIfAbsent(
        task.id, () => TextEditingController(text: endText));
    if (controller.text != endText) {
      controller.text = endText;
    }
    return controller;
  }

  TextEditingController _ensureRepresentativeNameController(
      rbv2.RoutineBlockV2 block) {
    final initial = block.blockName ?? '';
    final controller = _representativeNameControllers.putIfAbsent(
        block.id, () => TextEditingController(text: initial));
    // 編集中の上書きを防ぐため、既存 controller の text は更新しない。
    // 初回のみ putIfAbsent のコールバックで initial が設定される。
    return controller;
  }

  TextEditingController _ensureRepresentativeProjectController(
    rbv2.RoutineBlockV2 block,
    String projectName,
  ) {
    if (_pendingProjectClearByBlockId.contains(block.id)) {
      if ((block.projectId ?? '').isEmpty) {
        _pendingProjectClearByBlockId.remove(block.id);
      } else {
        return _representativeProjectControllers.putIfAbsent(
            block.id, () => TextEditingController(text: projectName));
      }
    }
    final controller = _representativeProjectControllers.putIfAbsent(
        block.id, () => TextEditingController(text: projectName));
    if (controller.text != projectName) {
      controller.text = projectName;
    }
    return controller;
  }

  TextEditingController _ensureRepresentativeSubProjectController(
    rbv2.RoutineBlockV2 block,
    String subProjectName,
  ) {
    if (_pendingSubProjectClearByBlockId.contains(block.id)) {
      if ((block.subProjectId ?? '').isEmpty &&
          (block.subProject ?? '').isEmpty) {
        _pendingSubProjectClearByBlockId.remove(block.id);
      } else {
        // プロジェクト変更でサブプロジェクトをクリアした直後、スナップショットがまだ古い → 上書きしない
        final controller = _representativeSubProjectControllers.putIfAbsent(
            block.id, () => TextEditingController(text: ''));
        if (controller.text.isNotEmpty) controller.text = '';
        return controller;
      }
    }
    final controller = _representativeSubProjectControllers.putIfAbsent(
        block.id, () => TextEditingController(text: subProjectName));
    if (controller.text != subProjectName) {
      controller.text = subProjectName;
    }
    return controller;
  }

  TextEditingController _ensureRepresentativeModeController(
    rbv2.RoutineBlockV2 block,
    String modeName,
  ) {
    final controller = _representativeModeControllers.putIfAbsent(
        block.id, () => TextEditingController(text: modeName));
    if (controller.text != modeName) {
      controller.text = modeName;
    }
    return controller;
  }

  TextEditingController _ensureRepresentativeLocationController(
    rbv2.RoutineBlockV2 block,
    String locationName,
  ) {
    final committed = _pendingLocationCommitByBlockId[block.id];
    if (committed != null) {
      if ((block.location ?? '') == committed) {
        _pendingLocationCommitByBlockId.remove(block.id);
      } else if (locationName != committed) {
        // コミット直後でスナップショットがまだ古い → コントローラを上書きしない
        return _representativeLocationControllers.putIfAbsent(
            block.id, () => TextEditingController(text: committed));
      }
    }
    final controller = _representativeLocationControllers.putIfAbsent(
        block.id, () => TextEditingController(text: locationName));
    if (controller.text != locationName) {
      controller.text = locationName;
    }
    return controller;
  }

  TextEditingController _ensureBlockStartTimeController(
    rbv2.RoutineBlockV2 block,
  ) {
    final text = _formatTimeOfDay(block.startTime);
    final controller = _blockStartTimeControllers.putIfAbsent(
      block.id,
      () => TextEditingController(text: text),
    );
    // 編集中の上書きを防ぐ（ストリーム再ビルドで未確定入力が消えるのを防ぐ）。
    // 確定・タイムピッカー・連動更新は _commit* / _pickBlockTime / _alignNext* で反映。
    return controller;
  }

  TextEditingController _ensureBlockEndTimeController(
    rbv2.RoutineBlockV2 block,
  ) {
    final text = _formatTimeOfDay(block.endTime);
    final controller = _blockEndTimeControllers.putIfAbsent(
      block.id,
      () => TextEditingController(text: text),
    );
    // 上記と同様（終了時刻欄）
    return controller;
  }

  TextEditingController _ensureBlockWorkingController(
    rbv2.RoutineBlockV2 block,
    int totalMinutes,
  ) {
    final working = block.workingMinutes < 0
        ? 0
        : (block.workingMinutes > totalMinutes
            ? totalMinutes
            : block.workingMinutes);
    final text = working.toString();
    final controller = _blockWorkingControllers.putIfAbsent(
      block.id,
      () => TextEditingController(text: text),
    );
    // 編集中の上書きを防ぐ（再ビルドで未確定入力が消えるのを防ぐ）。
    // 開始・終了時刻やタスク列からの再計算後は _syncBlockWorkBreakControllersFromBlock で整合。
    return controller;
  }

  TextEditingController _ensureBlockBreakController(
    rbv2.RoutineBlockV2 block,
    int totalMinutes,
  ) {
    final working = block.workingMinutes < 0
        ? 0
        : (block.workingMinutes > totalMinutes
            ? totalMinutes
            : block.workingMinutes);
    final breakVal = totalMinutes - working;
    final text = breakVal.toString();
    final controller = _blockBreakControllers.putIfAbsent(
      block.id,
      () => TextEditingController(text: text),
    );
    // 上記と同様（休憩分）
    return controller;
  }

  rbv2.RoutineBlockV2? _findBlockV2InTemplate(String blockId) {
    for (final b
        in RoutineDatabaseService.getBlocksForTemplate(widget.routine.id)) {
      if (b.id == blockId) return b;
    }
    return null;
  }

  void _syncBlockWorkBreakControllersFromBlock(rbv2.RoutineBlockV2 block) {
    final wCtrl = _blockWorkingControllers[block.id];
    final bCtrl = _blockBreakControllers[block.id];
    if (wCtrl == null || bCtrl == null) return;
    final total = _blockDurationMinutes(block.startTime, block.endTime);
    final working = block.workingMinutes < 0
        ? 0
        : (block.workingMinutes > total ? total : block.workingMinutes);
    final breakVal = total - working;
    final wText = working.toString();
    final bText = breakVal.toString();
    if (wCtrl.text != wText) wCtrl.text = wText;
    if (bCtrl.text != bText) bCtrl.text = bText;
  }

  Future<void> _commitBlockWorkingMinutesChange(
    rbv2.RoutineBlockV2 block,
    int totalMinutes,
    String rawValue,
  ) async {
    final trimmed = rawValue.trim();
    // 空欄は「0分」として確定（削除だけしてフォーカスアウトした場合に旧値へ戻さない）
    final parsed = trimmed.isEmpty ? 0 : int.tryParse(trimmed);
    if (parsed == null || parsed < 0) {
      if (mounted) {
        final w = block.workingMinutes < 0
            ? 0
            : (block.workingMinutes > totalMinutes
                ? totalMinutes
                : block.workingMinutes);
        _blockWorkingControllers[block.id]?.text = w.toString();
        _blockBreakControllers[block.id]?.text =
            (totalMinutes - w).toString();
      }
      return;
    }
    final working = parsed > totalMinutes ? totalMinutes : parsed;
    if (working == block.workingMinutes) {
      if (mounted) {
        _blockWorkingControllers[block.id]?.text = working.toString();
        _blockBreakControllers[block.id]?.text =
            (totalMinutes - working).toString();
        setState(() {});
      }
      return;
    }
    final updated = block.copyWith(
      workingMinutes: working,
      lastModified: DateTime.now(),
      version: block.version + 1,
    );
    await _mutationFacade.updateBlock(updated);
    if (mounted) {
      _blockWorkingControllers[block.id]?.text = working.toString();
      _blockBreakControllers[block.id]?.text =
          (totalMinutes - working).toString();
      setState(() {});
    }
  }

  Future<void> _commitBlockBreakMinutesChange(
    rbv2.RoutineBlockV2 block,
    int totalMinutes,
    String rawValue,
  ) async {
    final trimmed = rawValue.trim();
    final parsed = trimmed.isEmpty ? 0 : int.tryParse(trimmed);
    if (parsed == null || parsed < 0) {
      if (mounted) {
        final working = block.workingMinutes < 0
            ? 0
            : (block.workingMinutes > totalMinutes
                ? totalMinutes
                : block.workingMinutes);
        _blockWorkingControllers[block.id]?.text = working.toString();
        _blockBreakControllers[block.id]?.text =
            (totalMinutes - working).toString();
      }
      return;
    }
    final breakVal = parsed > totalMinutes ? totalMinutes : parsed;
    final working = totalMinutes - breakVal;
    if (working == block.workingMinutes) {
      if (mounted) {
        _blockWorkingControllers[block.id]?.text = working.toString();
        _blockBreakControllers[block.id]?.text = breakVal.toString();
        setState(() {});
      }
      return;
    }
    final updated = block.copyWith(
      workingMinutes: working,
      lastModified: DateTime.now(),
      version: block.version + 1,
    );
    await _mutationFacade.updateBlock(updated);
    if (mounted) {
      _blockWorkingControllers[block.id]?.text = working.toString();
      _blockBreakControllers[block.id]?.text = breakVal.toString();
      setState(() {});
    }
  }

  Future<void> _commitBlockExcludeFromReportChange(
    rbv2.RoutineBlockV2 block,
    bool excludeFromReport,
  ) async {
    if (block.excludeFromReport == excludeFromReport) return;
    final updated = block.copyWith(
      excludeFromReport: excludeFromReport,
      lastModified: DateTime.now(),
      version: block.version + 1,
    );
    await _mutationFacade.updateBlock(updated);
    if (mounted) setState(() {});
  }

  Widget _buildBootstrappingOverlay(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.scrim.withOpacity(0.35),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(
              valueColor: AlwaysStoppedAnimation<Color>(
                  Theme.of(context).colorScheme.primary),
            ),
            const SizedBox(height: 12),
            Text(
              '\u30eb\u30fc\u30c6\u30a3\u30f3\u3092\u6e96\u5099\u4e2d...',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
        ),
      ),
    );
  }

  void _purgeUnusedControllers(Set<String> activeTaskIds) {
    void purge(Map<String, TextEditingController> map, Set<String> active) {
      final stale = map.keys.where((id) => !active.contains(id)).toList();
      for (final id in stale) {
        map[id]?.dispose();
        map.remove(id);
      }
    }

    // 入力中デバウンスタイマーも掃除
    final staleNameTimers =
        _taskNameSaveTimersV2.keys.where((id) => !activeTaskIds.contains(id));
    for (final id in staleNameTimers.toList()) {
      _taskNameSaveTimersV2.remove(id)?.cancel();
    }

    purge(_taskNameControllersV2, activeTaskIds);
    purge(_durationControllersV2, activeTaskIds);
    purge(_projectControllersV2, activeTaskIds);
    purge(_subProjectControllersV2, activeTaskIds);
    purge(_modeControllersV2, activeTaskIds);
    purge(_locationControllersV2, activeTaskIds);
    purge(_detailsControllersV2, activeTaskIds);
    purge(_startTimeControllersV2, activeTaskIds);
    purge(_endTimeControllersV2, activeTaskIds);
    _pendingSubProjectClearByTaskId
        .removeWhere((id) => !activeTaskIds.contains(id));
    _pendingProjectClearByTaskId
        .removeWhere((id) => !activeTaskIds.contains(id));
    _pendingLocationCommitByTaskId
        .removeWhere((id, _) => !activeTaskIds.contains(id));
    _pendingNameCommitByTaskId
        .removeWhere((id, _) => !activeTaskIds.contains(id));
  }

  void _purgeUnusedBlockControllers(Set<String> activeBlockIds) {
    void purge(Map<String, TextEditingController> map) {
      final stale =
          map.keys.where((id) => !activeBlockIds.contains(id)).toList();
      for (final id in stale) {
        map[id]?.dispose();
        map.remove(id);
      }
    }

    final staleRepTimers = _representativeNameSaveTimers.keys
        .where((id) => !activeBlockIds.contains(id));
    for (final id in staleRepTimers.toList()) {
      _representativeNameSaveTimers.remove(id)?.cancel();
    }

    purge(_representativeNameControllers);
    purge(_representativeProjectControllers);
    purge(_representativeSubProjectControllers);
    purge(_representativeModeControllers);
    purge(_representativeLocationControllers);
    purge(_blockStartTimeControllers);
    purge(_blockEndTimeControllers);
    purge(_blockWorkingControllers);
    purge(_blockBreakControllers);
    _pendingSubProjectClearByBlockId
        .removeWhere((id) => !activeBlockIds.contains(id));
    _pendingProjectClearByBlockId
        .removeWhere((id) => !activeBlockIds.contains(id));
    _pendingLocationCommitByBlockId
        .removeWhere((id, _) => !activeBlockIds.contains(id));
  }

  TimeOfDay? _parseTimeText(String raw) {
    try {
      var value = raw.trim();
      if (value.isEmpty) return null;
      value = value.replaceAll('：', ':');

      // HH:mm / H:mm
      if (value.contains(':')) {
        final parts = value.split(':');
        if (parts.length < 2) return null;
        final hour = int.tryParse(parts[0]) ?? -1;
        final minute = int.tryParse(parts[1]) ?? -1;
        if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
        return TimeOfDay(hour: hour, minute: minute);
      }

      // 数字のみ: 930(=09:30) / 0930 / 1230
      final digits = value.replaceAll(RegExp(r'[^0-9]'), '');
      if (digits.isEmpty) return null;
      var four = digits;
      if (four.length == 3) {
        four = '0$four';
      }
      if (four.length != 4) return null;
      final hour = int.tryParse(four.substring(0, 2)) ?? -1;
      final minute = int.tryParse(four.substring(2, 4)) ?? -1;
      if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
      return TimeOfDay(hour: hour, minute: minute);
    } catch (_) {
      return null;
    }
  }

  int _timeOfDayToMinutes(TimeOfDay t) => t.hour * 60 + t.minute;

  TimeOfDay _minutesToTimeOfDay(int totalMinutes) {
    final normalized = ((totalMinutes % (24 * 60)) + (24 * 60)) % (24 * 60);
    return TimeOfDay(hour: normalized ~/ 60, minute: normalized % 60);
  }

  int _blockDurationMinutes(TimeOfDay start, TimeOfDay end) {
    final startMinutes = _timeOfDayToMinutes(start);
    final endMinutes = _timeOfDayToMinutes(end);
    var diff = endMinutes - startMinutes;
    if (diff <= 0) diff += 24 * 60;
    return diff;
  }

  Future<void> _recalculateBlockTimes(
    rbv2.RoutineBlockV2 block, {
    TimeOfDay? startOverride,
  }) async {
    final tasks = RoutineTaskV2Service.getByBlock(block.id);
    final effectiveStart = startOverride ?? block.startTime;
    final totalMinutes =
        tasks.fold<int>(0, (sum, t) => sum + t.estimatedDuration);
    final recalculatedEnd = _minutesToTimeOfDay(
      _timeOfDayToMinutes(effectiveStart) + totalMinutes,
    );

    final updated = block.copyWith(
      startTime: effectiveStart,
      endTime: recalculatedEnd,
      version: block.version + 1,
      lastModified: DateTime.now(),
    );

    await _mutationFacade.updateBlock(updated);
    if (mounted) {
      final fresh = _findBlockV2InTemplate(block.id);
      if (fresh != null) _syncBlockWorkBreakControllersFromBlock(fresh);
    }
  }

  void _showInvalidTimeSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _commitStartTimeChange(
    rbv2.RoutineBlockV2 block,
    List<_ScheduledTask> scheduledTasks,
    int index,
    String rawValue,
  ) async {
    final parsed = _parseTimeText(rawValue);
    if (parsed == null) {
      _showInvalidTimeSnack(
          '\u6642\u523b\u306fHH:MM\u5f62\u5f0f\u3067\u5165\u529b\u3057\u3066\u304f\u3060\u3055\u3044');
      return;
    }

    final scheduled = scheduledTasks[index];
    final currentStart = scheduled.start;
    if (parsed == currentStart) {
      return;
    }

    final parsedMinutes = _timeOfDayToMinutes(parsed);

    if (index == 0) {
      final tasks = RoutineTaskV2Service.getByBlock(block.id);
      final totalMinutes =
          tasks.fold<int>(0, (sum, t) => sum + t.estimatedDuration);
      final recalculatedEnd = _minutesToTimeOfDay(parsedMinutes + totalMinutes);
      final updatedBlock = block.copyWith(
        startTime: parsed,
        endTime: recalculatedEnd,
        version: block.version + 1,
        lastModified: DateTime.now(),
      );
      await _mutationFacade.updateBlock(updatedBlock);
      if (mounted) {
        final fresh = _findBlockV2InTemplate(block.id);
        if (fresh != null) _syncBlockWorkBreakControllersFromBlock(fresh);
      }
    } else {
      final previous = scheduledTasks[index - 1];
      final previousStartMinutes = _timeOfDayToMinutes(previous.start);
      final newDuration = parsedMinutes - previousStartMinutes;
      if (newDuration <= 0) {
        _showInvalidTimeSnack(
            '\u958b\u59cb\u6642\u523b\u306f\u524d\u306e\u30bf\u30b9\u30af\u3088\u308a\u5f8c\u306b\u8a2d\u5b9a\u3057\u3066\u304f\u3060\u3055\u3044');
        return;
      }

      final previousTask = previous.task;
      final updatedPrevious = previousTask.copyWith(
        estimatedDuration: newDuration,
        version: previousTask.version + 1,
        lastModified: DateTime.now(),
      );
      await _mutationFacade.updateTask(updatedPrevious);
      await _recalculateBlockTimes(block);
    }

    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _commitEndTimeChange(
    rbv2.RoutineBlockV2 block,
    List<_ScheduledTask> scheduledTasks,
    int index,
    String rawValue,
  ) async {
    final parsed = _parseTimeText(rawValue);
    if (parsed == null) {
      _showInvalidTimeSnack(
          '\u6642\u523b\u306fHH:MM\u5f62\u5f0f\u3067\u5165\u529b\u3057\u3066\u304f\u3060\u3055\u3044');
      return;
    }

    final scheduled = scheduledTasks[index];
    final start = scheduled.start;
    final currentEnd = scheduled.end;
    if (parsed == currentEnd) {
      return;
    }

    final startMinutes = _timeOfDayToMinutes(start);
    final parsedMinutes = _timeOfDayToMinutes(parsed);
    if (parsedMinutes <= startMinutes) {
      _showInvalidTimeSnack(
          '\u7d42\u4e86\u6642\u523b\u306f\u958b\u59cb\u6642\u523b\u3088\u308a\u5f8c\u306b\u8a2d\u5b9a\u3057\u3066\u304f\u3060\u3055\u3044');
      return;
    }

    final newDuration = parsedMinutes - startMinutes;
    final task = scheduled.task;
    final updatedTask = task.copyWith(
      estimatedDuration: newDuration,
      version: task.version + 1,
      lastModified: DateTime.now(),
    );
    await _mutationFacade.updateTask(updatedTask);

    if (index == scheduledTasks.length - 1) {
      final updatedBlock = block.copyWith(
        endTime: parsed,
        version: block.version + 1,
        lastModified: DateTime.now(),
      );
      await _mutationFacade.updateBlock(updatedBlock);
      if (mounted) {
        final fresh = _findBlockV2InTemplate(block.id);
        if (fresh != null) _syncBlockWorkBreakControllersFromBlock(fresh);
      }
    } else {
      await _recalculateBlockTimes(block);
    }

    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _commitNameChange(
      rtv2.RoutineTaskV2 task, String rawValue) async {
    final trimmed = rawValue.trim();
    final newName = trimmed.isEmpty ? task.name : trimmed;
    if (newName == task.name) {
      setState(() {
        _taskNameControllersV2[task.id]?.text = newName;
      });
      return;
    }

    _pendingNameCommitByTaskId[task.id] = newName;
    final updated = task.copyWith(
      name: newName,
      lastModified: DateTime.now(),
      version: task.version + 1,
    );
    await _mutationFacade.updateTask(updated);
    if (mounted) {
      setState(() {
        _taskNameControllersV2[task.id]?.text = newName;
      });
    }
  }

  Future<void> _commitDurationChange(
      rtv2.RoutineTaskV2 task, String rawValue) async {
    final parsed = int.tryParse(rawValue.trim());
    if (parsed == null || parsed <= 0) {
      setState(() {
        _durationControllersV2[task.id]?.text =
            task.estimatedDuration.toString();
      });
      return;
    }

    if (parsed == task.estimatedDuration) {
      setState(() {
        _durationControllersV2[task.id]?.text = parsed.toString();
      });
      return;
    }

    final updated = task.copyWith(
      estimatedDuration: parsed,
      lastModified: DateTime.now(),
      version: task.version + 1,
    );
    await _mutationFacade.updateTask(updated);
    if (mounted) {
      setState(() {
        _durationControllersV2[task.id]?.text = parsed.toString();
      });
    }
  }

  Future<void> _commitIsEventChange(rtv2.RoutineTaskV2 task, bool value) async {
    if (task.isEvent == value) return;
    final updated = task.copyWith(
      isEvent: value,
      lastModified: DateTime.now(),
      version: task.version + 1,
    );
    await _mutationFacade.updateTask(updated);
    if (mounted) setState(() {});
  }

  Future<void> _applyProjectChange(
      rtv2.RoutineTaskV2 task, String? projectId) async {
    final newProjectId =
        (projectId == null || projectId == '__clear__' || projectId.isEmpty)
            ? null
            : projectId;
    if ((task.projectId ?? '') == (newProjectId ?? '')) {
      return;
    }
    if (newProjectId == null && (task.projectId ?? '').isNotEmpty) {
      _pendingProjectClearByTaskId.add(task.id);
    }
    final projectChanged = (task.projectId ?? '') != (newProjectId ?? '');
    if (projectChanged) {
      _pendingSubProjectClearByTaskId.add(task.id);
    }

    final updated = task.copyWith(
      projectId: newProjectId,
      subProjectId: projectChanged ? null : task.subProjectId,
      subProject: projectChanged ? null : task.subProject,
      lastModified: DateTime.now(),
      version: task.version + 1,
    );

    await _mutationFacade.updateTask(updated);

    if (mounted) {
      setState(() {
        _projectControllersV2[task.id]?.text =
            newProjectId == null ? '' : _getProjectName(newProjectId);
        if (projectChanged) {
          _subProjectControllersV2[task.id]?.text = '';
        }
      });
    }
  }

  Future<void> _applySubProjectChange(rtv2.RoutineTaskV2 task,
      String? subProjectId, String? subProjectName) async {
    final newSubProjectId = (subProjectId == null ||
            subProjectId == '__clear__' ||
            subProjectId.isEmpty)
        ? null
        : subProjectId;
    final newSubProjectName = newSubProjectId == null ? null : subProjectName;

    if ((task.subProjectId ?? '') == (newSubProjectId ?? '') &&
        (task.subProject ?? '') == (newSubProjectName ?? '')) {
      setState(() {
        _subProjectControllersV2[task.id]?.text = newSubProjectName ?? '';
      });
      return;
    }

    final updated = task.copyWith(
      subProjectId: newSubProjectId,
      subProject: newSubProjectName,
      lastModified: DateTime.now(),
      version: task.version + 1,
    );

    await _mutationFacade.updateTask(updated);

    if (mounted) {
      setState(() {
        _subProjectControllersV2[task.id]?.text = newSubProjectName ?? '';
      });
    }
  }

  Future<void> _applyModeChange(rtv2.RoutineTaskV2 task, String? modeId) async {
    final newModeId =
        (modeId == null || modeId == '__clear__' || modeId.isEmpty)
            ? null
            : modeId;

    if ((task.modeId ?? '') == (newModeId ?? '')) {
      setState(() {
        _modeControllersV2[task.id]?.text =
            newModeId == null ? '' : _getModeName(newModeId);
      });
      return;
    }

    final updated = task.copyWith(
      modeId: newModeId,
      lastModified: DateTime.now(),
      version: task.version + 1,
    );

    await _mutationFacade.updateTask(updated);

    if (mounted) {
      setState(() {
        _modeControllersV2[task.id]?.text =
            newModeId == null ? '' : _getModeName(newModeId);
      });
    }
  }

  Future<void> _commitLocationChange(
      rtv2.RoutineTaskV2 task, String rawValue) async {
    final trimmed = rawValue.trim();
    final newLocation = trimmed.isEmpty ? null : trimmed;

    if ((task.location ?? '') == (newLocation ?? '')) {
      setState(() {
        _locationControllersV2[task.id]?.text = newLocation ?? '';
      });
      return;
    }

    final newLocationStr = newLocation ?? '';
    _pendingLocationCommitByTaskId[task.id] = newLocationStr;

    final updated = task.copyWith(
      location: newLocation,
      lastModified: DateTime.now(),
      version: task.version + 1,
    );

    await _mutationFacade.updateTask(updated);

    if (mounted) {
      setState(() {
        _locationControllersV2[task.id]?.text = newLocationStr;
      });
    }
  }

  Future<void> _commitDetailsChange(
      rtv2.RoutineTaskV2 task, String rawValue) async {
    final trimmed = rawValue.trim();
    final newDetails = trimmed.isEmpty ? null : trimmed;

    if ((task.details ?? '') == (newDetails ?? '')) {
      setState(() {
        _detailsControllersV2[task.id]?.text = newDetails ?? '';
      });
      return;
    }

    final updated = task.copyWith(
      details: newDetails,
      lastModified: DateTime.now(),
      version: task.version + 1,
    );

    await _mutationFacade.updateTask(updated);

    if (mounted) {
      setState(() {
        _detailsControllersV2[task.id]?.text = newDetails ?? '';
      });
    }
  }

  // --- Helpers for task updates ---

  Future<void> _selectProjectForTask(rtv2.RoutineTaskV2 task) async {
    final projects = ProjectService.getActiveProjects()
      ..sort((a, b) => a.name.compareTo(b.name));

    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text(
            '\u30d7\u30ed\u30b8\u30a7\u30af\u30c8\u3092\u9078\u629e'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop('__clear__'),
            child:
                const Text('\u672a\u8a2d\u5b9a\uff08\u30af\u30ea\u30a2\uff09'),
          ),
          for (final project in projects)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(project.id),
              child: Text(project.name),
            ),
        ],
      ),
    );

    if (selected == null) return;

    await _applyProjectChange(task, selected);
  }

  Future<void> _selectSubProjectForTask(
      rtv2.RoutineTaskV2 task, bool hasProject) async {
    if (!hasProject || task.projectId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                '\u5148\u306b\u30d7\u30ed\u30b8\u30a7\u30af\u30c8\u3092\u8a2d\u5b9a\u3057\u3066\u304f\u3060\u3055\u3044')),
      );
      return;
    }

    final subProjects =
        SubProjectService.getSubProjectsByProjectId(task.projectId!)
          ..sort((a, b) => a.name.compareTo(b.name));
    final subProjectMap = {for (final sp in subProjects) sp.id: sp.name};

    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text(
            '\u30b5\u30d6\u30d7\u30ed\u30b8\u30a7\u30af\u30c8\u3092\u9078\u629e'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop('__clear__'),
            child: const Text('\u672a\u8a2d\u5b9a'),
          ),
          for (final sp in subProjects)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(sp.id),
              child: Text(sp.name),
            ),
        ],
      ),
    );

    if (selected == null) return;

    await _applySubProjectChange(task, selected, subProjectMap[selected]);
  }

  Future<void> _selectModeForTask(rtv2.RoutineTaskV2 task) async {
    final modes = ModeService.getAllModes()
      ..sort((a, b) => a.name.compareTo(b.name));

    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('\u30e2\u30fc\u30c9\u3092\u9078\u629e'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop('__clear__'),
            child: const Text('\u672a\u8a2d\u5b9a'),
          ),
          for (final mode in modes)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(mode.id),
              child: Text(mode.name),
            ),
        ],
      ),
    );

    if (selected == null) return;

    await _applyModeChange(task, selected);
  }

  Future<void> _editLocationForTask(
      rtv2.RoutineTaskV2 task, String initialLocation) async {
    final controller = TextEditingController(text: initialLocation);
    final saved = await showImeSafeDialog<bool>(
      context: context,
      builder: (ctx) {
        final double dialogWidth =
            (MediaQuery.of(ctx).size.width - 48).clamp(0.0, 420.0).toDouble();
        return AlertDialog(
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          title: const Text('\u5834\u6240\u3092\u7de8\u96c6'),
          content: SizedBox(
            width: dialogWidth,
            child: TextField(
              controller: controller,
              decoration: const InputDecoration(hintText: '\u5834\u6240'),
              autofocus: true,
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('\u30ad\u30e3\u30f3\u30bb\u30eb')),
            ElevatedButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('\u4fdd\u5b58')),
          ],
        );
      },
    );

    if (saved != true) return;

    await _commitLocationChange(task, controller.text);
  }

  String _getProjectName(String? projectId) {
    if (projectId == null || projectId.isEmpty) return '';
    try {
      final p = ProjectService.getProjectById(projectId);
      return p?.name ?? '';
    } catch (_) {
      return '';
    }
  }

  String _getSubProjectName(String? subProjectId) {
    if (subProjectId == null || subProjectId.isEmpty) return '';
    try {
      final sp = SubProjectService.getSubProjectById(subProjectId);
      return sp?.name ?? '';
    } catch (_) {
      return '';
    }
  }

  String _getModeName(String? modeId) {
    if (modeId == null || modeId.isEmpty) return '';
    try {
      final mode = ModeService.getModeById(modeId);
      return mode?.name ?? '';
    } catch (_) {
      return '';
    }
  }


  Future<void> _commitRepresentativeNameChange(
      rbv2.RoutineBlockV2 block, String rawValue) async {
    final trimmed = rawValue.trim();
    final newName = trimmed.isEmpty ? null : trimmed;

    if ((block.blockName ?? '') == (newName ?? '')) {
      if (mounted) {
        setState(() {
          _representativeNameControllers[block.id]?.text = newName ?? '';
        });
      }
      return;
    }

    final updated = block.copyWith(
      blockName: newName,
      lastModified: DateTime.now(),
      version: block.version + 1,
    );

    await _mutationFacade.updateBlock(updated);

    if (mounted) {
      setState(() {
        _representativeNameControllers[block.id]?.text = newName ?? '';
      });
    }
  }

  Future<void> _applyRepresentativeProjectChange(
      rbv2.RoutineBlockV2 block, String? projectId) async {
    final newProjectId =
        (projectId == null || projectId.isEmpty || projectId == '__clear__')
            ? null
            : projectId;

    if ((block.projectId ?? '') == (newProjectId ?? '')) {
      if (mounted) {
        setState(() {
          _representativeProjectControllers[block.id]?.text =
              newProjectId == null
                  ? _displayText(null)
                  : _displayText(_getProjectName(newProjectId));
        });
      }
      return;
    }

    if (newProjectId == null && (block.projectId ?? '').isNotEmpty) {
      _pendingProjectClearByBlockId.add(block.id);
    }
    _pendingSubProjectClearByBlockId.add(block.id);

    final updatedBlock = block.copyWith(
      projectId: newProjectId,
      subProjectId: null,
      subProject: null,
      lastModified: DateTime.now(),
      version: block.version + 1,
    );

    await _mutationFacade.updateBlock(updatedBlock);

    if (mounted) {
      setState(() {
        _representativeProjectControllers[block.id]?.text = newProjectId == null
            ? _displayText(null)
            : _displayText(_getProjectName(newProjectId));
        _representativeSubProjectControllers[block.id]?.text =
            _displayText(null);
      });
    }
  }

  Future<void> _applyRepresentativeSubProjectChange(rbv2.RoutineBlockV2 block,
      String? subProjectId, String? subProjectLabel) async {
    final newSubProjectId = (subProjectId == null ||
            subProjectId.isEmpty ||
            subProjectId == '__clear__')
        ? null
        : subProjectId;
    final trimmedLabel = (subProjectLabel == null ||
            subProjectLabel.trim().isEmpty ||
            newSubProjectId == null)
        ? null
        : subProjectLabel.trim();

    if ((block.subProjectId ?? '') == (newSubProjectId ?? '') &&
        (block.subProject ?? '') == (trimmedLabel ?? '')) {
      if (mounted) {
        setState(() {
          _representativeSubProjectControllers[block.id]?.text =
              _displayText(trimmedLabel);
        });
      }
      return;
    }

    final updatedBlock = block.copyWith(
      subProjectId: newSubProjectId,
      subProject: trimmedLabel,
      lastModified: DateTime.now(),
      version: block.version + 1,
    );

    await _mutationFacade.updateBlock(updatedBlock);

    if (mounted) {
      setState(() {
        _representativeSubProjectControllers[block.id]?.text =
            _displayText(trimmedLabel);
      });
    }
  }

  Future<void> _applyRepresentativeModeChange(
      rbv2.RoutineBlockV2 block, String? modeId) async {
    final newModeId =
        (modeId == null || modeId.isEmpty || modeId == '__clear__')
            ? null
            : modeId;

    if ((block.modeId ?? '') == (newModeId ?? '')) {
      if (mounted) {
        setState(() {
          _representativeModeControllers[block.id]?.text = newModeId == null
              ? _displayText(null)
              : _displayText(_getModeName(newModeId));
        });
      }
      return;
    }

    final updatedBlock = block.copyWith(
      modeId: newModeId,
      lastModified: DateTime.now(),
      version: block.version + 1,
    );

    await _mutationFacade.updateBlock(updatedBlock);

    if (mounted) {
      setState(() {
        _representativeModeControllers[block.id]?.text = newModeId == null
            ? _displayText(null)
            : _displayText(_getModeName(newModeId));
      });
    }
  }

  Future<void> _commitRepresentativeLocationChange(
      rbv2.RoutineBlockV2 block, String rawValue) async {
    final trimmed = rawValue.trim();
    final newLocation = trimmed.isEmpty ? null : trimmed;

    if ((block.location ?? '') == (newLocation ?? '')) {
      if (mounted) {
        setState(() {
          _representativeLocationControllers[block.id]?.text =
              newLocation ?? '';
        });
      }
      return;
    }

    final newLocationStr = newLocation ?? '';
    _pendingLocationCommitByBlockId[block.id] = newLocationStr;

    final updatedBlock = block.copyWith(
      location: newLocation,
      lastModified: DateTime.now(),
      version: block.version + 1,
    );

    await _mutationFacade.updateBlock(updatedBlock);

    if (mounted) {
      setState(() {
        _representativeLocationControllers[block.id]?.text = newLocationStr;
      });
    }
  }

  String _getApplyDayTypeText(String applyDayType) {
    switch (applyDayType) {
      case 'weekday':
        return '\u5e73\u65e5\u306e\u307f';
      case 'holiday':
        return '\u4f11\u65e5\u306e\u307f';
      case 'both':
        return '\u4e21\u65e5';
      default:
        return '\u5bfe\u8c61\u5916';
    }
  }

  /// ブロック表示名。睡眠ブロックは「就寝\n起床」の2行表示用ラベルを返す。
  String _blockDisplayName(rbv2.RoutineBlockV2 block) {
    if (RoutineSleepBlockService.isSleepBlock(block)) {
      return RoutineSleepBlockService.sleepBlockDisplayLabel;
    }
    return (block.blockName == null || block.blockName!.trim().isEmpty)
        ? '名称未設定'
        : block.blockName!.trim();
  }

  String _formatTimeRange(TimeOfDay start, TimeOfDay end) {
    String fmt(TimeOfDay t) =>
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    final crossesMidnight =
        _timeOfDayToMinutes(end) <= _timeOfDayToMinutes(start);
    final endText = crossesMidnight ? '翌${fmt(end)}' : fmt(end);
    return '${fmt(start)} \u301c $endText';
  }

  String _formatWorkBreakText(
    rbv2.RoutineBlockV2 block, {
    bool wrapInParens = true,
    bool zeroWhenExcluded = false,
  }) {
    final isExcluded = block.excludeFromReport == true;
    if (zeroWhenExcluded && isExcluded) {
      final core = '作業：0分 休憩：0分';
      return wrapInParens ? '（$core）' : core;
    }

    final total = _blockDurationMinutes(block.startTime, block.endTime);
    final working = block.workingMinutes < 0
        ? 0
        : (block.workingMinutes > total ? total : block.workingMinutes);
    final breakMinutes = total - working;
    final core = '作業：${working}分 休憩：${breakMinutes}分';
    return wrapInParens ? '（$core）' : core;
  }

  // ===== V2 helpers =====
  Future<void> _showAddBlockDialog() async {
    // 「集中」モードをデフォルトで選択
    String? focusModeId;
    String focusModeName = '';
    try {
      final modes = ModeService.getAllModes();
      final focusMode = modes.firstWhere((m) => m.name == '集中');
      focusModeId = focusMode.id;
      focusModeName = focusMode.name;
    } catch (_) {}

    final nameCtrl = TextEditingController();
    final projectCtrl = TextEditingController();
    final subProjectCtrl = TextEditingController();
    final modeCtrl = TextEditingController(text: focusModeName);
    final locationCtrl = TextEditingController();
    final breakCtrl = TextEditingController(text: '0');
    final workingCtrl = TextEditingController(text: '0');
    String? selectedProjectId;
    String? selectedSubProjectId;
    String? selectedSubProjectName;
    String? selectedModeId = focusModeId;
    bool excludeFromReport = false;

    // 前詰め: スキマを優先して埋める。スキマがなければ末尾に追加
    const durationMinutes = 60;
    final existingBlocks =
        RoutineDatabaseService.getBlocksForTemplate(widget.routine.id);
    final gap = RoutineDetailHelpers.findFirstFittingGap(
      existingBlocks,
      maxBlockMinutes: durationMinutes,
    );
    final TimeOfDay initialStart;
    final TimeOfDay initialEnd;
    if (gap != null) {
      initialStart = gap.start;
      initialEnd = gap.end;
    } else {
      final latestByEndTime = existingBlocks.isEmpty
          ? null
          : existingBlocks.reduce((a, b) =>
              _timeOfDayToMinutes(b.endTime) > _timeOfDayToMinutes(a.endTime)
                  ? b
                  : a);
      initialStart =
          latestByEndTime?.endTime ?? const TimeOfDay(hour: 9, minute: 0);
      initialEnd = _minutesToTimeOfDay(
          _timeOfDayToMinutes(initialStart) + durationMinutes);
    }

    TimeOfDay start = initialStart;
    TimeOfDay end = initialEnd;
    int currentDuration() => _blockDurationMinutes(start, end);
    bool updatingWorkBreak = false;
    bool lastEditedWorking = true;

    int _parseNonNegInt(String s) => int.tryParse(s.trim()) ?? 0;
    void _setCtrlInt(TextEditingController ctrl, int value) {
      final next = value.toString();
      if (ctrl.text == next) return;
      ctrl.text = next;
    }

    int currentBreak(int duration) {
      final value = int.tryParse(breakCtrl.text.trim()) ?? 0;
      if (value < 0) return 0;
      if (value > duration) return duration;
      return value;
    }

    int currentWorking(int duration) {
      final value = _parseNonNegInt(workingCtrl.text);
      if (value < 0) return 0;
      if (value > duration) return duration;
      return value;
    }

    void _syncFromBreak() {
      if (updatingWorkBreak) return;
      updatingWorkBreak = true;
      try {
        final duration = currentDuration();
        final b = currentBreak(duration);
        final w = (duration - b).clamp(0, duration);
        _setCtrlInt(breakCtrl, b);
        _setCtrlInt(workingCtrl, w);
      } finally {
        updatingWorkBreak = false;
      }
    }

    void _syncFromWorking() {
      if (updatingWorkBreak) return;
      updatingWorkBreak = true;
      try {
        final duration = currentDuration();
        final w = currentWorking(duration);
        final b = (duration - w).clamp(0, duration);
        _setCtrlInt(workingCtrl, w);
        _setCtrlInt(breakCtrl, b);
      } finally {
        updatingWorkBreak = false;
      }
    }

    // 初期整合（所要時間に対して休憩/稼働が矛盾しないように）
    _syncFromBreak();

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
        final theme = Theme.of(ctx);
        final fillColor = theme.inputDecorationTheme.fillColor ??
            theme.colorScheme.surfaceVariant
                .withOpacity(theme.brightness == Brightness.dark ? 0.35 : 0.12);
        const labelStyle = TextStyle(fontSize: 12, fontWeight: FontWeight.w600);

        OutlineInputBorder buildBorder(Color color) => OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: color, width: 1.2),
            );

        InputDecoration buildDecoration(String label, {String? hintText}) {
          return InputDecoration(
            labelText: label,
            hintText: hintText,
            labelStyle: labelStyle.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            floatingLabelBehavior: FloatingLabelBehavior.always,
            filled: true,
            fillColor: fillColor,
            border: buildBorder(theme.colorScheme.outlineVariant),
            enabledBorder:
                buildBorder(theme.colorScheme.outlineVariant.withOpacity(0.6)),
            focusedBorder: buildBorder(theme.colorScheme.primary),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          );
        }

        Future<void> pickStart() async {
          final picked = await showTimePicker(context: ctx, initialTime: start);
          if (picked != null) {
            setLocal(() {
              start = picked;
            });
            setLocal(() {
              if (lastEditedWorking) {
                _syncFromWorking();
              } else {
                _syncFromBreak();
              }
            });
          }
        }

        Future<void> pickEnd() async {
          final picked = await showTimePicker(context: ctx, initialTime: end);
          if (picked != null) {
            setLocal(() {
              final startMinutes = start.hour * 60 + start.minute;
              final pickedMinutes = picked.hour * 60 + picked.minute;
              // 日跨ぎを許可:
              // - picked < start は「翌日扱い」としてそのまま許可
              // - picked == start は 0分（=24h扱いになり得る）なので、最小30分を自動で入れる
              if (pickedMinutes == startMinutes) {
                final adjusted = startMinutes + 30;
                end = TimeOfDay(
                  hour: (adjusted ~/ 60) % 24,
                  minute: adjusted % 60,
                );
              } else {
                end = picked;
              }
            });
            setLocal(() {
              if (lastEditedWorking) {
                _syncFromWorking();
              } else {
                _syncFromBreak();
              }
            });
          }
        }

        Widget subProjectField() {
          final decorator = InputDecorator(
            decoration: buildDecoration(
              '\u30b5\u30d6\u30d7\u30ed\u30b8\u30a7\u30af\u30c8',
              hintText: selectedProjectId == null || selectedProjectId!.isEmpty
                  ? '\u5148\u306b\u30d7\u30ed\u30b8\u30a7\u30af\u30c8\u3092\u9078\u629e'
                  : '\u672a\u8a2d\u5b9a',
            ),
            child: SubProjectInputField(
              controller: subProjectCtrl,
              projectId: selectedProjectId ?? '',
              currentSubProjectId: selectedSubProjectId,
              onSubProjectChanged: (subProjectId, subProjectName) async {
                setLocal(() {
                  if (subProjectId == null ||
                      subProjectId.isEmpty ||
                      subProjectId == '__clear__') {
                    selectedSubProjectId = null;
                    selectedSubProjectName = null;
                    subProjectCtrl.text = '';
                  } else {
                    selectedSubProjectId = subProjectId;
                    selectedSubProjectName = subProjectName;
                    subProjectCtrl.text = subProjectName ?? '';
                  }
                });
              },
              onAutoSave: () {},
              withBackground: false,
              useOutlineBorder: false,
              height: 42,
            ),
          );
          if (selectedProjectId == null || selectedProjectId!.isEmpty) {
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                        '\u5148\u306b\u30d7\u30ed\u30b8\u30a7\u30af\u30c8\u3092\u8a2d\u5b9a\u3057\u3066\u304f\u3060\u3055\u3044'),
                  ),
                );
              },
              child: AbsorbPointer(child: decorator),
            );
          }
          return decorator;
        }

        Widget buildTimeField({
          required String label,
          required TimeOfDay value,
          required Future<void> Function() onTap,
        }) {
          return Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () {
                FocusScope.of(ctx).unfocus();
                onTap();
              },
              child: InputDecorator(
                decoration: buildDecoration(label),
                child: Text(
                  '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ),
          );
        }

        return AlertDialog(
          title: Row(
            children: [
              const Expanded(
                child: Text(
                  '\u30d6\u30ed\u30c3\u30af\u3092\u8ffd\u52a0',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '集計外',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).brightness == Brightness.dark
                      ? const Color(0xFF9E9E9E)
                      : const Color(0xFF525252),
                ),
              ),
              Switch.adaptive(
                value: excludeFromReport,
                onChanged: (v) => setLocal(() => excludeFromReport = v),
              ),
            ],
          ),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // スマホで先頭フィールドのラベルがタイトルと干渉するのを防ぐ
                  const SizedBox(height: 8),
                  TextField(
                    controller: nameCtrl,
                    decoration: buildDecoration(
                        '\u30d6\u30ed\u30c3\u30af\u540d',
                        hintText: '\u4efb\u610f'),
                    autofocus: true,
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: buildTimeField(
                          label: '\u958b\u59cb\u6642\u523b',
                          value: start,
                          onTap: pickStart,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: buildTimeField(
                          label: '\u7d42\u4e86\u6642\u523b',
                          value: end,
                          onTap: pickEnd,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: breakCtrl,
                          decoration: buildDecoration(
                              '\u4f11\u6182\u6642\u9593( \u5206 )',
                              hintText: '0'),
                          keyboardType: TextInputType.number,
                          onChanged: (_) {
                            if (updatingWorkBreak) return;
                            lastEditedWorking = false;
                            setLocal(() {});
                            _syncFromBreak();
                            setLocal(() {});
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: workingCtrl,
                          decoration: buildDecoration(
                              '\u7a3c\u50cd\u6642\u9593( \u5206 )',
                              hintText: '0'),
                          keyboardType: TextInputType.number,
                          onChanged: (_) {
                            if (updatingWorkBreak) return;
                            lastEditedWorking = true;
                            setLocal(() {});
                            _syncFromWorking();
                            setLocal(() {});
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  InputDecorator(
                    decoration: buildDecoration(
                        '\u30d7\u30ed\u30b8\u30a7\u30af\u30c8',
                        hintText: '\u672a\u8a2d\u5b9a'),
                    child: ProjectInputField(
                      controller: projectCtrl,
                      onProjectChanged: (projectId) async {
                        setLocal(() {
                          if (projectId == null ||
                              projectId.isEmpty ||
                              projectId == '__clear__') {
                            selectedProjectId = null;
                            projectCtrl.text = '';
                            selectedSubProjectId = null;
                            selectedSubProjectName = null;
                            subProjectCtrl.text = '';
                          } else {
                            selectedProjectId = projectId;
                            projectCtrl.text = _getProjectName(projectId);
                            selectedSubProjectId = null;
                            selectedSubProjectName = null;
                            subProjectCtrl.text = '';
                          }
                        });
                      },
                      onAutoSave: () {},
                      hintText: '\u30d7\u30ed\u30b8\u30a7\u30af\u30c8',
                      useOutlineBorder: false,
                      withBackground: false,
                      includeArchived: true,
                      showAllOnTap: true,
                      height: 42,
                    ),
                  ),
                  const SizedBox(height: 16),
                  subProjectField(),
                  const SizedBox(height: 16),
                  InputDecorator(
                    decoration: buildDecoration('\u30e2\u30fc\u30c9',
                        hintText: '\u672a\u8a2d\u5b9a'),
                    child: ModeInputField(
                      controller: modeCtrl,
                      onModeChanged: (modeId) async {
                        setLocal(() {
                          if (modeId == null ||
                              modeId.isEmpty ||
                              modeId == '__clear__') {
                            selectedModeId = null;
                            modeCtrl.text = '';
                          } else {
                            selectedModeId = modeId;
                            modeCtrl.text = _getModeName(modeId);
                          }
                        });
                      },
                      onAutoSave: () {},
                      hintText: '\u30e2\u30fc\u30c9',
                      useOutlineBorder: false,
                      withBackground: false,
                      height: 42,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: locationCtrl,
                    decoration: buildDecoration('\u5834\u6240',
                        hintText:
                            '\u4f8b: \u81ea\u5b85\u30fb\u30aa\u30d5\u30a3\u30b9'),
                    textInputAction: TextInputAction.done,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('\u30ad\u30e3\u30f3\u30bb\u30eb')),
            FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('\u8ffd\u52a0')),
          ],
        );
      }),
    );
    if (saved == true) {
      final now = DateTime.now();
      final existingBlocks =
          RoutineDatabaseService.getBlocksForTemplate(widget.routine.id);
      int nextOrder = 0;
      for (final blk in existingBlocks) {
        if (blk.order >= nextOrder) {
          nextOrder = blk.order + 1;
        }
      }
      final trimmedLocation = locationCtrl.text.trim();
      final normalizedProjectId =
          (selectedProjectId == null || selectedProjectId!.isEmpty)
              ? null
              : selectedProjectId;
      final normalizedSubProjectId =
          (selectedSubProjectId == null || selectedSubProjectId!.isEmpty)
              ? null
              : selectedSubProjectId;
      final normalizedSubProjectName = (selectedSubProjectName == null ||
              selectedSubProjectName!.trim().isEmpty)
          ? null
          : selectedSubProjectName!.trim();
      final normalizedModeId =
          (selectedModeId == null || selectedModeId!.isEmpty)
              ? null
              : selectedModeId;
      final totalMinutes = _blockDurationMinutes(start, end);
      final rawWorking = _parseNonNegInt(workingCtrl.text);
      final workingMinutes = rawWorking < 0
          ? 0
          : (rawWorking > totalMinutes ? totalMinutes : rawWorking);
      final b = rbv2.RoutineBlockV2(
        id: now.millisecondsSinceEpoch.toString(),
        routineTemplateId: widget.routine.id,
        blockName: nameCtrl.text.trim().isEmpty ? null : nameCtrl.text.trim(),
        startTime: start,
        endTime: end,
        workingMinutes: workingMinutes,
        colorValue: null,
        order: nextOrder,
        location: trimmedLocation.isEmpty ? null : trimmedLocation,
        projectId: normalizedProjectId,
        subProjectId: normalizedSubProjectId,
        subProject: normalizedSubProjectName,
        modeId: normalizedModeId,
        excludeFromReport: excludeFromReport,
        createdAt: now,
        lastModified: now,
        userId: _resolveUserId(),
      );
      await _mutationFacade.addBlock(b);
      if (mounted) {
        setState(() {
          _expandedBlockIdsV2.add(b.id);
        });
      }
    }
    nameCtrl.dispose();
    projectCtrl.dispose();
    subProjectCtrl.dispose();
    modeCtrl.dispose();
    locationCtrl.dispose();
    breakCtrl.dispose();
    workingCtrl.dispose();
  }

  Future<void> _editBlock(rbv2.RoutineBlockV2 b) async {
    final nameCtrl = TextEditingController(text: b.blockName ?? '');
    final projectCtrl =
        TextEditingController(text: _getProjectName(b.projectId));
    final subProjectCtrl = TextEditingController(
        text: b.subProject ?? _getSubProjectName(b.subProjectId));
    final modeCtrl = TextEditingController(text: _getModeName(b.modeId));
    final locationCtrl = TextEditingController(text: b.location ?? '');
    final totalInitialMinutes = _blockDurationMinutes(b.startTime, b.endTime);
    final initialBreak = totalInitialMinutes - b.workingMinutes;
    final normalizedBreak = initialBreak <= 0 ? 0 : initialBreak;
    final breakCtrl = TextEditingController(text: normalizedBreak.toString());
    final initialWorking = b.workingMinutes < 0
        ? 0
        : (b.workingMinutes > totalInitialMinutes
            ? totalInitialMinutes
            : b.workingMinutes);
    final workingCtrl = TextEditingController(text: initialWorking.toString());
    String? selectedProjectId = b.projectId;
    String? selectedSubProjectId = b.subProjectId;
    String? selectedSubProjectName =
        b.subProject ?? _getSubProjectName(b.subProjectId);
    String? selectedModeId = b.modeId;
    bool excludeFromReport = b.excludeFromReport == true;
    bool blockIsEvent = b.isEvent;
    TimeOfDay start = b.startTime;
    TimeOfDay end = b.endTime;
    int currentDuration() => _blockDurationMinutes(start, end);
    bool updatingWorkBreak = false;
    bool lastEditedWorking = true;

    int _parseNonNegInt(String s) => int.tryParse(s.trim()) ?? 0;
    void _setCtrlInt(TextEditingController ctrl, int value) {
      final next = value.toString();
      if (ctrl.text == next) return;
      ctrl.text = next;
    }

    int currentBreak(int duration) {
      final value = int.tryParse(breakCtrl.text.trim()) ?? 0;
      if (value < 0) return 0;
      if (value > duration) return duration;
      return value;
    }

    int currentWorking(int duration) {
      final value = _parseNonNegInt(workingCtrl.text);
      if (value < 0) return 0;
      if (value > duration) return duration;
      return value;
    }

    void _syncFromBreak() {
      if (updatingWorkBreak) return;
      updatingWorkBreak = true;
      try {
        final duration = currentDuration();
        final b = currentBreak(duration);
        final w = (duration - b).clamp(0, duration);
        _setCtrlInt(breakCtrl, b);
        _setCtrlInt(workingCtrl, w);
      } finally {
        updatingWorkBreak = false;
      }
    }

    void _syncFromWorking() {
      if (updatingWorkBreak) return;
      updatingWorkBreak = true;
      try {
        final duration = currentDuration();
        final w = currentWorking(duration);
        final b = (duration - w).clamp(0, duration);
        _setCtrlInt(workingCtrl, w);
        _setCtrlInt(breakCtrl, b);
      } finally {
        updatingWorkBreak = false;
      }
    }

    // 初期整合（保存時のズレ防止）
    _syncFromWorking();
    final saved = await showImeSafeDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
        Future<void> pickStart() async {
          final picked = await showTimePicker(context: ctx, initialTime: start);
          if (picked != null) {
            setLocal(() {
              start = picked;
            });
            setLocal(() {
              if (lastEditedWorking) {
                _syncFromWorking();
              } else {
                _syncFromBreak();
              }
            });
          }
        }

        Future<void> pickEnd() async {
          final picked = await showTimePicker(context: ctx, initialTime: end);
          if (picked != null) {
            setLocal(() {
              final startMinutes = start.hour * 60 + start.minute;
              final pickedMinutes = picked.hour * 60 + picked.minute;
              // 日跨ぎを許可:
              // - picked < start は「翌日扱い」としてそのまま許可
              // - picked == start は 0分（=24h扱いになり得る）なので、最小30分を自動で入れる
              if (pickedMinutes == startMinutes) {
                final adjusted = startMinutes + 30;
                end = TimeOfDay(
                  hour: (adjusted ~/ 60) % 24,
                  minute: adjusted % 60,
                );
              } else {
                end = picked;
              }
            });
            setLocal(() {
              if (lastEditedWorking) {
                _syncFromWorking();
              } else {
                _syncFromBreak();
              }
            });
          }
        }

        String fmt(TimeOfDay t) =>
            '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
        const labelStyle = TextStyle(fontSize: 12);
        final inputBorder = OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
        );

        InputDecoration buildDecoration(String label) {
          return InputDecoration(
            labelText: label,
            labelStyle: labelStyle,
            border: inputBorder,
            floatingLabelBehavior: FloatingLabelBehavior.always,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          );
        }

        Widget buildProjectField() {
          return InputDecorator(
            decoration: buildDecoration('\u30d7\u30ed\u30b8\u30a7\u30af\u30c8'),
            child: ProjectInputField(
              controller: projectCtrl,
              onProjectChanged: (projectId) async {
                setLocal(() {
                  if (projectId == null ||
                      projectId.isEmpty ||
                      projectId == '__clear__') {
                    selectedProjectId = null;
                    projectCtrl.text = '';
                    selectedSubProjectId = null;
                    selectedSubProjectName = null;
                    subProjectCtrl.text = '';
                  } else {
                    selectedProjectId = projectId;
                    projectCtrl.text = _getProjectName(projectId);
                    selectedSubProjectId = null;
                    selectedSubProjectName = null;
                    subProjectCtrl.text = '';
                  }
                });
              },
              onAutoSave: () {},
              withBackground: false,
              useOutlineBorder: false,
              includeArchived: true,
              showAllOnTap: true,
              height: 40,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            ),
          );
        }

        Widget buildSubProjectField() {
          final field = InputDecorator(
            decoration: buildDecoration(
                '\u30b5\u30d6\u30d7\u30ed\u30b8\u30a7\u30af\u30c8'),
            child: SubProjectInputField(
              controller: subProjectCtrl,
              projectId: selectedProjectId ?? '',
              currentSubProjectId: selectedSubProjectId,
              onSubProjectChanged: (subProjectId, subProjectName) async {
                setLocal(() {
                  if (subProjectId == null ||
                      subProjectId.isEmpty ||
                      subProjectId == '__clear__') {
                    selectedSubProjectId = null;
                    selectedSubProjectName = null;
                    subProjectCtrl.text = '';
                  } else {
                    selectedSubProjectId = subProjectId;
                    selectedSubProjectName = subProjectName;
                    subProjectCtrl.text = subProjectName ?? '';
                  }
                });
              },
              onAutoSave: () {},
              withBackground: false,
              useOutlineBorder: false,
              height: 40,
            ),
          );

          if (selectedProjectId == null || selectedProjectId!.isEmpty) {
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                      content: Text(
                          '\u5148\u306b\u30d7\u30ed\u30b8\u30a7\u30af\u30c8\u3092\u8a2d\u5b9a\u3057\u3066\u304f\u3060\u3055\u3044')),
                );
              },
              child: AbsorbPointer(child: field),
            );
          }
          return field;
        }

        Widget buildModeField() {
          return InputDecorator(
            decoration: buildDecoration('\u30e2\u30fc\u30c9'),
            child: ModeInputField(
              controller: modeCtrl,
              onModeChanged: (modeId) async {
                setLocal(() {
                  if (modeId == null ||
                      modeId.isEmpty ||
                      modeId == '__clear__') {
                    selectedModeId = null;
                    modeCtrl.text = '';
                  } else {
                    selectedModeId = modeId;
                    modeCtrl.text = _getModeName(modeId);
                  }
                });
              },
              onAutoSave: () {},
              hintText: '\u30e2\u30fc\u30c9',
              withBackground: false,
              useOutlineBorder: false,
              height: 40,
            ),
          );
        }

        Widget buildTimeField(
            String label, TimeOfDay time, VoidCallback onTap) {
          return InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: InputDecorator(
              decoration: buildDecoration(label),
              child: Text(
                fmt(time),
                style:
                    const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ),
          );
        }

        final mq = MediaQuery.of(ctx);
        final isPhoneLike = mq.size.shortestSide < 600;
        final double dialogWidth = (mq.size.width - (isPhoneLike ? 16 : 48))
            .clamp(0.0, isPhoneLike ? 560.0 : 480.0)
            .toDouble();

        return AlertDialog(
          // スマホでは「ダイアログだがほぼフル画面」に寄せる（余白最小）
          insetPadding: isPhoneLike
              ? const EdgeInsets.symmetric(horizontal: 8, vertical: 8)
              : const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  '\u30d6\u30ed\u30c3\u30af\u3092\u7de8\u96c6',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '集計外',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).brightness == Brightness.dark
                      ? const Color(0xFF9E9E9E)
                      : const Color(0xFF525252),
                ),
              ),
              Switch.adaptive(
                value: excludeFromReport,
                onChanged: (v) => setLocal(() => excludeFromReport = v),
              ),
            ],
          ),
          content: SizedBox(
            width: dialogWidth,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: buildTimeField(
                            '\u958b\u59cb\u6642\u523b', start, pickStart),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: buildTimeField(
                            '\u7d42\u4e86\u6642\u523b', end, pickEnd),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: breakCtrl,
                          decoration: buildDecoration(
                              '\u4f11\u6182\u6642\u9593(\u5206)'),
                          keyboardType: TextInputType.number,
                          onChanged: (_) {
                            if (updatingWorkBreak) return;
                            lastEditedWorking = false;
                            setLocal(() {});
                            _syncFromBreak();
                            setLocal(() {});
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: workingCtrl,
                          decoration: buildDecoration(
                              '\u7a3c\u50cd\u6642\u9593(\u5206)'),
                          keyboardType: TextInputType.number,
                          onChanged: (_) {
                            if (updatingWorkBreak) return;
                            lastEditedWorking = true;
                            setLocal(() {});
                            _syncFromWorking();
                            setLocal(() {});
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: nameCtrl,
                    decoration:
                        buildDecoration('\u30d6\u30ed\u30c3\u30af\u540d'),
                    style: const TextStyle(fontSize: 14),
                  ),
                  const SizedBox(height: 12),
                  buildProjectField(),
                  const SizedBox(height: 12),
                  buildSubProjectField(),
                  const SizedBox(height: 12),
                  // 仕様: モードと場所は同じ行に統一する
                  Row(
                    children: [
                      Expanded(child: buildModeField()),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: locationCtrl,
                          decoration: buildDecoration('\u5834\u6240'),
                          style: const TextStyle(fontSize: 14),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    title: const Text('通知（イベント）'),
                    subtitle: const Text(
                      '反映した予定をイベント扱いにして通知を出します',
                      style: TextStyle(fontSize: 12),
                    ),
                    value: blockIsEvent,
                    onChanged: (v) =>
                        setLocal(() => blockIsEvent = v ?? false),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('\u30ad\u30e3\u30f3\u30bb\u30eb')),
            ElevatedButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('\u4fdd\u5b58')),
          ],
        );
      }),
    );
    if (saved == true) {
      final trimmedLocation = locationCtrl.text.trim();
      final normalizedProjectId =
          (selectedProjectId == null || selectedProjectId!.isEmpty)
              ? null
              : selectedProjectId;
      final normalizedSubProjectId =
          (selectedSubProjectId == null || selectedSubProjectId!.isEmpty)
              ? null
              : selectedSubProjectId;
      final normalizedSubProjectName = (selectedSubProjectName == null ||
              selectedSubProjectName!.trim().isEmpty)
          ? null
          : selectedSubProjectName!.trim();
      final normalizedModeId =
          (selectedModeId == null || selectedModeId!.isEmpty)
              ? null
              : selectedModeId;
      final totalMinutes = _blockDurationMinutes(start, end);
      final rawWorking = _parseNonNegInt(workingCtrl.text);
      final workingMinutes = rawWorking < 0
          ? 0
          : (rawWorking > totalMinutes ? totalMinutes : rawWorking);
      final updated = b.copyWith(
        blockName: nameCtrl.text.trim().isEmpty ? null : nameCtrl.text.trim(),
        startTime: start,
        endTime: end,
        workingMinutes: workingMinutes,
        projectId: normalizedProjectId,
        subProjectId: normalizedSubProjectId,
        subProject: normalizedSubProjectName,
        modeId: normalizedModeId,
        location: trimmedLocation.isEmpty ? null : trimmedLocation,
        excludeFromReport: excludeFromReport,
        isEvent: blockIsEvent,
        lastModified: DateTime.now(),
        version: b.version + 1,
      );
      await _mutationFacade.updateBlock(updated);
      if (mounted) {
        setState(() {});
      }
    }
    nameCtrl.dispose();
    projectCtrl.dispose();
    subProjectCtrl.dispose();
    modeCtrl.dispose();
    locationCtrl.dispose();
    breakCtrl.dispose();
    workingCtrl.dispose();
  }

  Future<void> _deleteBlock(rbv2.RoutineBlockV2 b) async {
    final tasks = RoutineDatabaseService.getTasksForBlock(b.id);
    final taskCount = tasks.length;
    final blockName = b.blockName ?? 'ブロック';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ブロックを削除'),
        content: Text(
          taskCount > 0
              ? '$blockNameを削除しますか？\nこのブロックに紐づく${taskCount}個のタスクも一緒に削除されます。'
              : '$blockNameを削除しますか？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            child: const Text('削除'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await _mutationFacade.deleteBlock(b.id, widget.routine.id);
        if (mounted) {
          setState(() {});
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('$blockNameを削除しました'),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('ブロックの削除に失敗しました: $e'),
              backgroundColor: Theme.of(context).colorScheme.error,
              duration: const Duration(seconds: 3),
            ),
          );
        }
      }
    }
  }

  Future<void> _addTaskToBlock(rbv2.RoutineBlockV2 b) async {
    // 「タスク追加」は、全画面の表（割り当て画面）を開いて操作する。
    await _openBlockTaskAssignmentScreen(b);
  }

  /// タスクの全項目をダイアログで表示・編集する
  Future<void> _editTaskFull(rtv2.RoutineTaskV2 t) async {
    final nameCtrl = TextEditingController(text: t.name);
    final durationCtrl =
        TextEditingController(text: t.estimatedDuration.toString());
    final detailsCtrl = TextEditingController(text: t.details ?? '');
    final memoCtrl = TextEditingController(text: t.memo ?? '');
    final locationCtrl = TextEditingController(text: t.location ?? '');
    final blockNameCtrl = TextEditingController(text: t.blockName ?? '');
    final orderCtrl = TextEditingController(text: t.order.toString());

    String? dialogProjectId = t.projectId;
    String? dialogSubProjectId = t.subProjectId;
    String? dialogSubProjectName = t.subProject;
    String? dialogModeId = t.modeId;
    bool dialogIsEvent = t.isEvent;

    bool? saved = await showImeSafeDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            final mq = MediaQuery.of(ctx);
            final isPhoneLike = mq.size.shortestSide < 600;
            final double dialogWidth = (mq.size.width - (isPhoneLike ? 16 : 48))
                .clamp(0.0, isPhoneLike ? 560.0 : 520.0)
                .toDouble();

            Future<void> pickProject() async {
              final projects = ProjectService.getActiveProjects()
                ..sort((a, b) => a.name.compareTo(b.name));
              final selected = await showDialog<String>(
                context: ctx,
                builder: (dialogCtx) => SimpleDialog(
                  title: const Text('プロジェクトを選択'),
                  children: [
                    SimpleDialogOption(
                      onPressed: () => Navigator.of(dialogCtx).pop('__clear__'),
                      child: const Text('未設定（クリア）'),
                    ),
                    for (final project in projects)
                      SimpleDialogOption(
                        onPressed: () =>
                            Navigator.of(dialogCtx).pop(project.id),
                        child: Text(project.name),
                      ),
                  ],
                ),
              );
              if (selected != null) {
                setLocal(() {
                  dialogProjectId =
                      (selected == '__clear__' || selected.isEmpty)
                          ? null
                          : selected;
                  if (dialogProjectId == null) {
                    dialogSubProjectId = null;
                    dialogSubProjectName = null;
                  }
                });
              }
            }

            Future<void> pickSubProject() async {
              if (dialogProjectId == null || dialogProjectId!.isEmpty) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('先にプロジェクトを設定してください')),
                );
                return;
              }
              final subProjects =
                  SubProjectService.getSubProjectsByProjectId(dialogProjectId!)
                    ..sort((a, b) => a.name.compareTo(b.name));
              final selected = await showDialog<String>(
                context: ctx,
                builder: (dialogCtx) => SimpleDialog(
                  title: const Text('サブプロジェクトを選択'),
                  children: [
                    SimpleDialogOption(
                      onPressed: () => Navigator.of(dialogCtx).pop('__clear__'),
                      child: const Text('未設定'),
                    ),
                    for (final sp in subProjects)
                      SimpleDialogOption(
                        onPressed: () => Navigator.of(dialogCtx).pop(sp.id),
                        child: Text(sp.name),
                      ),
                  ],
                ),
              );
              if (selected != null) {
                setLocal(() {
                  dialogSubProjectId =
                      (selected == '__clear__' || selected.isEmpty)
                          ? null
                          : selected;
                  dialogSubProjectName =
                      (selected == '__clear__' || selected.isEmpty)
                          ? null
                          : _getSubProjectName(selected);
                });
              }
            }

            Future<void> pickMode() async {
              final modes = ModeService.getAllModes()
                ..sort((a, b) => a.name.compareTo(b.name));
              final selected = await showDialog<String>(
                context: ctx,
                builder: (dialogCtx) => SimpleDialog(
                  title: const Text('モードを選択'),
                  children: [
                    SimpleDialogOption(
                      onPressed: () => Navigator.of(dialogCtx).pop('__clear__'),
                      child: const Text('未設定'),
                    ),
                    for (final mode in modes)
                      SimpleDialogOption(
                        onPressed: () => Navigator.of(dialogCtx).pop(mode.id),
                        child: Text(mode.name),
                      ),
                  ],
                ),
              );
              if (selected != null) {
                setLocal(() {
                  dialogModeId = (selected == '__clear__' || selected.isEmpty)
                      ? null
                      : selected;
                });
              }
            }

            return AlertDialog(
              insetPadding: isPhoneLike
                  ? const EdgeInsets.symmetric(horizontal: 8, vertical: 8)
                  : const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
              title: const Text('タスクの全項目を編集'),
              content: SizedBox(
                width: dialogWidth,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: nameCtrl,
                        decoration: const InputDecoration(
                          labelText: 'タスク名',
                          border: OutlineInputBorder(),
                          floatingLabelBehavior: FloatingLabelBehavior.always,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: durationCtrl,
                        decoration: const InputDecoration(
                          labelText: '作業時間 (分)',
                          border: OutlineInputBorder(),
                          floatingLabelBehavior: FloatingLabelBehavior.always,
                        ),
                        keyboardType: TextInputType.number,
                      ),
                      const SizedBox(height: 12),
                      ListTile(
                        title: Text(
                          dialogProjectId == null || dialogProjectId!.isEmpty
                              ? '未設定'
                              : _getProjectName(dialogProjectId),
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: pickProject,
                      ),
                      const SizedBox(height: 4),
                      ListTile(
                        title: Text(
                          dialogSubProjectId == null ||
                                  dialogSubProjectId!.isEmpty
                              ? '未設定'
                              : (dialogSubProjectName ??
                                  _getSubProjectName(dialogSubProjectId)),
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: pickSubProject,
                      ),
                      const SizedBox(height: 4),
                      ListTile(
                        title: Text(
                          dialogModeId == null || dialogModeId!.isEmpty
                              ? '未設定'
                              : _getModeName(dialogModeId),
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: pickMode,
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: detailsCtrl,
                        decoration: const InputDecoration(
                          labelText: '詳細',
                          border: OutlineInputBorder(),
                          floatingLabelBehavior: FloatingLabelBehavior.always,
                        ),
                        maxLines: 2,
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: memoCtrl,
                        decoration: const InputDecoration(
                          labelText: 'メモ',
                          border: OutlineInputBorder(),
                          floatingLabelBehavior: FloatingLabelBehavior.always,
                        ),
                        maxLines: 2,
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: locationCtrl,
                        decoration: const InputDecoration(
                          labelText: '場所',
                          border: OutlineInputBorder(),
                          floatingLabelBehavior: FloatingLabelBehavior.always,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: blockNameCtrl,
                        decoration: const InputDecoration(
                          labelText: 'ブロック名（行ラベル）',
                          border: OutlineInputBorder(),
                          floatingLabelBehavior: FloatingLabelBehavior.always,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: orderCtrl,
                        decoration: const InputDecoration(
                          labelText: '並び順',
                          border: OutlineInputBorder(),
                          floatingLabelBehavior: FloatingLabelBehavior.always,
                        ),
                        keyboardType: TextInputType.number,
                      ),
                      const SizedBox(height: 8),
                      CheckboxListTile(
                        title: const Text('通知（イベント）'),
                        value: dialogIsEvent,
                        onChanged: (value) {
                          setLocal(() => dialogIsEvent = value ?? false);
                        },
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('キャンセル'),
                ),
                ElevatedButton(
                  onPressed: () {
                    final minutes = int.tryParse(durationCtrl.text.trim());
                    if (minutes == null || minutes < 0) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        const SnackBar(
                          content: Text('作業時間(分)は0以上の数値で入力してください'),
                        ),
                      );
                      return;
                    }
                    final order = int.tryParse(orderCtrl.text.trim());
                    if (order == null || order < 0) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        const SnackBar(
                          content: Text('並び順は0以上の数値で入力してください'),
                        ),
                      );
                      return;
                    }
                    Navigator.of(ctx).pop(true);
                  },
                  child: const Text('保存'),
                ),
              ],
            );
          },
        );
      },
    );

    if (saved != true) {
      nameCtrl.dispose();
      durationCtrl.dispose();
      detailsCtrl.dispose();
      memoCtrl.dispose();
      locationCtrl.dispose();
      blockNameCtrl.dispose();
      orderCtrl.dispose();
      return;
    }

    final minutes = int.tryParse(durationCtrl.text.trim());
    final order = int.tryParse(orderCtrl.text.trim());
    final updated = t.copyWith(
      name: nameCtrl.text.trim().isEmpty ? t.name : nameCtrl.text.trim(),
      estimatedDuration:
          (minutes != null && minutes >= 0) ? minutes : t.estimatedDuration,
      projectId: dialogProjectId,
      subProjectId: dialogSubProjectId,
      subProject: dialogSubProjectName ??
          (dialogSubProjectId != null
              ? _getSubProjectName(dialogSubProjectId)
              : null),
      modeId: dialogModeId,
      details: detailsCtrl.text.trim().isEmpty ? null : detailsCtrl.text.trim(),
      memo: memoCtrl.text.trim().isEmpty ? null : memoCtrl.text.trim(),
      location:
          locationCtrl.text.trim().isEmpty ? null : locationCtrl.text.trim(),
      blockName:
          blockNameCtrl.text.trim().isEmpty ? null : blockNameCtrl.text.trim(),
      isEvent: dialogIsEvent,
      order: (order != null && order >= 0) ? order : t.order,
      lastModified: DateTime.now(),
      version: t.version + 1,
    );

    nameCtrl.dispose();
    durationCtrl.dispose();
    detailsCtrl.dispose();
    memoCtrl.dispose();
    locationCtrl.dispose();
    blockNameCtrl.dispose();
    orderCtrl.dispose();

    await _mutationFacade.updateTask(updated);
    if (mounted) setState(() {});
  }

  Future<void> _editTask(rtv2.RoutineTaskV2 t) async {
    final titleCtrl = TextEditingController(text: t.name);
    final durationCtrl =
        TextEditingController(text: t.estimatedDuration.toString());
    bool? saved;
    int nextMinutes = t.estimatedDuration;
    String nextName = t.name;
    saved = await showImeSafeDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
        final mq = MediaQuery.of(ctx);
        final isPhoneLike = mq.size.shortestSide < 600;
        final double dialogWidth = (mq.size.width - (isPhoneLike ? 16 : 48))
            .clamp(0.0, isPhoneLike ? 560.0 : 480.0)
            .toDouble();
        return AlertDialog(
          // スマホでは「ダイアログだがほぼフル画面」に寄せる（余白最小）
          insetPadding: isPhoneLike
              ? const EdgeInsets.symmetric(horizontal: 8, vertical: 8)
              : const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          title: const Text('タスクを編集'),
          content: SizedBox(
            width: dialogWidth,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleCtrl,
                  decoration: const InputDecoration(
                    labelText: 'タスク名',
                    border: OutlineInputBorder(),
                    floatingLabelBehavior: FloatingLabelBehavior.always,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: durationCtrl,
                  decoration: const InputDecoration(
                    labelText: '作業時間 (分)',
                    border: OutlineInputBorder(),
                    floatingLabelBehavior: FloatingLabelBehavior.always,
                  ),
                  keyboardType: TextInputType.number,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('キャンセル'),
            ),
            ElevatedButton(
              onPressed: () {
                final minutes = int.tryParse(durationCtrl.text.trim());
                if (minutes == null || minutes < 0) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    const SnackBar(
                      content: Text('作業時間(分)は0以上の数値で入力してください'),
                    ),
                  );
                  return;
                }
                nextMinutes = minutes;
                final trimmed = titleCtrl.text.trim();
                nextName = trimmed.isEmpty ? t.name : trimmed;
                Navigator.of(ctx).pop(true);
              },
              child: const Text('保存'),
            ),
          ],
        );
      }),
    );
    if (saved == true) {
      final updated = t.copyWith(
        name: nextName,
        estimatedDuration: nextMinutes,
        lastModified: DateTime.now(),
        version: t.version + 1,
      );
      await _mutationFacade.updateTask(updated);
      if (mounted) setState(() {});
    }
    titleCtrl.dispose();
    durationCtrl.dispose();
  }

  Future<void> _deleteTask(rtv2.RoutineTaskV2 task) async {
    await _mutationFacade.deleteTask(task.id, task.routineTemplateId);
    if (mounted) setState(() {});
  }
}

class _DiagonalSlashPainter extends CustomPainter {
  final Color color;
  final double strokeWidth;

  const _DiagonalSlashPainter({
    required this.color,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.butt;

    final double inset = strokeWidth / 2;
    canvas.drawLine(
      Offset(inset, size.height - inset),
      Offset(size.width - inset, inset),
      paint,
    );
  }

  @override
  bool shouldRepaint(_DiagonalSlashPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.strokeWidth != strokeWidth;
}
