import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'dart:math' as math;

import '../repositories/routine_editor_repository.dart';
import '../models/routine_block_v2.dart';
import '../models/routine_task_v2.dart';
import '../models/routine_template_v2.dart';
import '../services/project_service.dart';
import '../services/sub_project_service.dart';
import '../services/mode_service.dart';
import '../services/routine_mutation_facade.dart';
import '../services/routine_sleep_block_service.dart';
import '../services/routine_template_v2_service.dart';
import '../utils/ime_safe_dialog.dart';
import '../widgets/project_input_field.dart';
import '../widgets/sub_project_input_field.dart';
import '../widgets/mode_input_field.dart';

// =============================================================================
// 【設計ルール】この画面の色について
// =============================================================================
// - 画面全体はアプリのテーマに追従する（ライト/ダークを上書きしない）。
// - 円グラフ・プロジェクト一覧・左側カレンダーのブロック色は、いずれもテーマの primary 色相を
//   基準にしたプロジェクト別パレット（_reviewProjectColor）で統一。
// =============================================================================

/// レビュー画面用: 表示順のインデックスで色を返す。
/// 赤・青・紫をバランスよく並べた9色で、多くのプロジェクトでも色がばらけるようにする。
Color _reviewProjectColorByIndex(int index, ColorScheme scheme) {
  const hues = [
    0.0, 220.0, 280.0,   // 赤、青、紫
    10.0, 200.0, 260.0,  // 赤寄り、青寄り、紫寄り
    350.0, 240.0, 300.0, // 赤系、青系、紫系
  ];
  const saturation = 0.65;
  const lightness = 0.52;
  return HSLColor.fromAHSL(1.0, hues[index % hues.length], saturation, lightness).toColor();
}

/// フォールバック用（projectColorByKey に含まれないキー用）
Color _reviewProjectColor(String projectKey, ColorScheme scheme) {
  if (projectKey == '__none__' || projectKey.isEmpty) {
    return scheme.outline;
  }
  final index = projectKey.hashCode.abs() % 3;
  return _reviewProjectColorByIndex(index, scheme);
}

class RoutineDayReviewScreen extends StatefulWidget {
  final String routineTemplateId;
  final String routineTitle;
  final String? routineColorHex;

  const RoutineDayReviewScreen({
    super.key,
    required this.routineTemplateId,
    required this.routineTitle,
    this.routineColorHex,
  });

  @override
  State<RoutineDayReviewScreen> createState() => _RoutineDayReviewScreenState();
}

class _RoutineDayReviewScreenState extends State<RoutineDayReviewScreen> {
  final RoutineEditorRepository _editorRepository =
      RoutineEditorRepository.instance;

  late Stream<RoutineEditorSnapshot> _stream;
  late RoutineEditorSnapshot _initialSnapshot;

  final ScrollController _scrollController = ScrollController();
  bool _initialAutoScrolled = false;
  final TextEditingController _memoController = TextEditingController();
  /// 最後にテンプレートと同期したメモ（「ルーティンを編集」側の更新を反映するため）
  String? _lastSyncedMemo;
  StreamSubscription<void>? _templateUpdateSub;

  @override
  void initState() {
    super.initState();
    _initialSnapshot = _safeInitialSnapshot();
    _stream = _editorRepository.watchTemplate(widget.routineTemplateId);
    _loadMemo();
    _templateUpdateSub = RoutineTemplateV2Service.updateStream.listen((_) {
      if (!mounted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _syncMemoFromTemplateIfNeeded();
      });
    });
  }

  void _loadMemo() {
    final t = RoutineTemplateV2Service.getById(widget.routineTemplateId);
    if (t != null && _memoController.text.isEmpty) {
      _memoController.text = t.memo;
      _lastSyncedMemo = t.memo;
    }
  }

  /// ストリームでテンプレートが更新されたとき、他画面（ルーティンを編集）での変更をメモ欄に反映する。
  void _syncMemoFromTemplateIfNeeded() {
    final t = RoutineTemplateV2Service.getById(widget.routineTemplateId);
    if (t == null) return;
    if (t.memo == _lastSyncedMemo) return;
    _lastSyncedMemo = t.memo;
    if (_memoController.text != t.memo) {
      _memoController.text = t.memo;
      if (mounted) setState(() {});
    }
  }

  void _saveMemo() {
    final t = RoutineTemplateV2Service.getById(widget.routineTemplateId);
    if (t == null) return;
    final text = _memoController.text;
    if (t.memo == text) return;
    t.memo = text;
    _lastSyncedMemo = text;
    unawaited(RoutineMutationFacade.instance.updateTemplate(t));
  }

  @override
  void dispose() {
    _templateUpdateSub?.cancel();
    _saveMemo();
    _memoController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  RoutineEditorSnapshot _safeInitialSnapshot() {
    try {
      return _editorRepository.snapshotTemplate(widget.routineTemplateId);
    } catch (_) {
      return RoutineEditorSnapshot(
        templateId: widget.routineTemplateId,
        blocks: const <RoutineBlockV2>[],
        tasksByBlockId: const <String, List<RoutineTaskV2>>{},
        generatedAt: DateTime.now(),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // アプリのテーマに追従（ライト/ダークを上書きしない）
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.routineTitle}（レビュー）'),
      ),
      body: StreamBuilder<RoutineEditorSnapshot>(
              stream: _stream,
              initialData: _initialSnapshot,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(
                    child: Text(
                      '表示に失敗しました: ${snapshot.error}',
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                      textAlign: TextAlign.center,
                    ),
                  );
                }

                if (snapshot.hasData) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _syncMemoFromTemplateIfNeeded();
                  });
                }

                final data = snapshot.data ?? _initialSnapshot;
                final blocks = data.blocks.where((b) => !b.isDeleted).toList()
                  ..sort((a, b) {
                    final aMin = a.startTime.hour * 60 + a.startTime.minute;
                    final bMin = b.startTime.hour * 60 + b.startTime.minute;
                    if (aMin != bMin) return aMin.compareTo(bMin);
                    return a.order.compareTo(b.order);
                  });
                final projectSummaries = _computeProjectSummaries(
                  blocks.where((b) => !b.excludeFromReport).toList(),
                );

                // 表示順で色を割り当て（1番目=赤、2番目=青、3番目=紫…）し、別プロジェクトでかぶらないようにする
                final projectEntriesOrder = projectSummaries.entries
                    .where((e) => e.value.workMinutes > 0)
                    .toList()
                  ..sort((a, b) {
                    final aIsUnset = a.key == '__none__' ? 1 : 0;
                    final bIsUnset = b.key == '__none__' ? 1 : 0;
                    if (aIsUnset != bIsUnset) return aIsUnset.compareTo(bIsUnset);
                    return b.value.workMinutes.compareTo(a.value.workMinutes);
                  });
                final orderedProjectIds = projectEntriesOrder.map((e) => e.key).toList();
                for (final b in blocks) {
                  final key = (b.projectId == null || b.projectId!.trim().isEmpty)
                      ? '__none__'
                      : b.projectId!.trim();
                  if (!orderedProjectIds.contains(key)) orderedProjectIds.add(key);
                }
                final scheme = Theme.of(context).colorScheme;
                final projectColorByKey = <String, Color>{};
                for (var i = 0; i < orderedProjectIds.length; i++) {
                  final key = orderedProjectIds[i];
                  projectColorByKey[key] = (key == '__none__' || key.isEmpty)
                      ? scheme.outline
                      : _reviewProjectColorByIndex(i, scheme);
                }

                return LayoutBuilder(
                  builder: (context, constraints) {
                    final isDesktop = constraints.maxWidth >= 900;
                    if (!isDesktop) {
                      return DefaultTabController(
                        length: 2,
                        child: Column(
                          children: [
                            Material(
                              color: Theme.of(context).colorScheme.surface,
                              child: TabBar(
                                tabs: const [
                                  Tab(text: '時間軸'),
                                  Tab(text: '集計'),
                                ],
                              ),
                            ),
                            Expanded(
                              child: TabBarView(
                                children: [
                                  _RoutineDayTimelinePreview(
                                    blocks: blocks,
                                    tasksByBlockId: data.tasksByBlockId,
                                    controller: _scrollController,
                                    shouldAutoScroll: !_initialAutoScrolled,
                                    onTapBlock: (b) => _showEditBlockDialog(context, b),
                                    onAutoScrolled: () {
                                      _initialAutoScrolled = true;
                                    },
                                    projectColorByKey: projectColorByKey,
                                  ),
                                  Column(
                                    children: [
                                      Expanded(
                                        child: _ProjectDurationPanel(
                                          summariesByProjectId: projectSummaries,
                                          blocks: blocks,
                                          projectColorByKey: projectColorByKey,
                                        ),
                                      ),
                                      Expanded(
                                        child: _MemoPanel(controller: _memoController),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    }

                    return Row(
                      children: [
                        Expanded(
                          child: _RoutineDayTimelinePreview(
                            blocks: blocks,
                            tasksByBlockId: data.tasksByBlockId,
                            controller: _scrollController,
                            shouldAutoScroll: !_initialAutoScrolled,
                            onTapBlock: (b) => _showEditBlockDialog(context, b),
                            onAutoScrolled: () {
                              _initialAutoScrolled = true;
                            },
                            projectColorByKey: projectColorByKey,
                          ),
                        ),
                        VerticalDivider(
                          width: 1,
                          thickness: 1,
                          color: Theme.of(context).dividerColor,
                        ),
                        Expanded(
                          child: Column(
                            children: [
                              Expanded(
                                child: _ProjectDurationPanel(
                                  summariesByProjectId: projectSummaries,
                                  blocks: blocks,
                                  projectColorByKey: projectColorByKey,
                                ),
                              ),
                              Expanded(
                                child: _MemoPanel(controller: _memoController),
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
    );
  }

  static int _minutesBetween(TimeOfDay start, TimeOfDay end) {
    final s = start.hour * 60 + start.minute;
    final e = end.hour * 60 + end.minute;
    int diff = e - s;
    if (diff <= 0) diff += 24 * 60;
    return diff;
  }

  static int _toMinuteOfDay(TimeOfDay t) => (t.hour * 60 + t.minute) % (24 * 60);

  static String _fmt2(int v) => v.toString().padLeft(2, '0');

  static String _fmtTime(TimeOfDay t) => '${_fmt2(t.hour)}:${_fmt2(t.minute)}';

  String _projectName(String? projectId) {
    final pid = projectId?.trim();
    if (pid == null || pid.isEmpty) return '';
    final p = ProjectService.getProjectById(pid);
    final name = p?.name.trim();
    if (name != null && name.isNotEmpty) return name;
    return pid;
  }

  String _subProjectName(String? subProjectId) {
    final sid = subProjectId?.trim();
    if (sid == null || sid.isEmpty) return '';
    try {
      final sp = SubProjectService.getSubProjectById(sid);
      final name = sp?.name.trim();
      if (name != null && name.isNotEmpty) return name;
    } catch (_) {}
    return sid;
  }

  String _modeName(String? modeId) {
    final mid = modeId?.trim();
    if (mid == null || mid.isEmpty) return '';
    try {
      final m = ModeService.getModeById(mid);
      final name = m?.name.trim();
      if (name != null && name.isNotEmpty) return name;
    } catch (_) {}
    return mid;
  }

  Future<void> _showEditBlockDialog(BuildContext context, RoutineBlockV2 block) async {
    // 編集ダイアログ（レビュー画面からでもテンプレのブロックを編集できるようにする）
    final nameCtrl = TextEditingController(text: block.blockName ?? '');
    final projectCtrl = TextEditingController(text: _projectName(block.projectId));
    final subProjectCtrl = TextEditingController(
      text: (block.subProject?.trim().isNotEmpty ?? false)
          ? block.subProject!.trim()
          : _subProjectName(block.subProjectId),
    );
    final modeCtrl = TextEditingController(text: _modeName(block.modeId));
    final locationCtrl = TextEditingController(text: block.location ?? '');

    String? selectedProjectId = block.projectId;
    String? selectedSubProjectId = block.subProjectId;
    String? selectedSubProjectName = (block.subProject?.trim().isNotEmpty ?? false)
        ? block.subProject!.trim()
        : null;
    String? selectedModeId = block.modeId;
    bool excludeFromReport = block.excludeFromReport == true;

    TimeOfDay start = block.startTime;
    TimeOfDay end = block.endTime;

    int durationMinutes() => _minutesBetween(start, end);

    int clampNonNegInt(String raw, {required int max}) {
      final v = int.tryParse(raw.trim()) ?? 0;
      if (v < 0) return 0;
      if (v > max) return max;
      return v;
    }

    // working/break は「片方変更で片方追随」を維持（routine_detail と同様）
    bool updatingWorkBreak = false;
    bool lastEditedWorking = true;
    final breakCtrl = TextEditingController();
    final workingCtrl = TextEditingController();

    void syncFromWorking() {
      if (updatingWorkBreak) return;
      updatingWorkBreak = true;
      try {
        final dur = durationMinutes();
        final w = clampNonNegInt(workingCtrl.text, max: dur);
        final b = (dur - w).clamp(0, dur);
        final nextW = w.toString();
        if (workingCtrl.text != nextW) workingCtrl.text = nextW;
        final nextB = b.toString();
        if (breakCtrl.text != nextB) breakCtrl.text = nextB;
      } finally {
        updatingWorkBreak = false;
      }
    }

    void syncFromBreak() {
      if (updatingWorkBreak) return;
      updatingWorkBreak = true;
      try {
        final dur = durationMinutes();
        final b = clampNonNegInt(breakCtrl.text, max: dur);
        final w = (dur - b).clamp(0, dur);
        final nextB = b.toString();
        if (breakCtrl.text != nextB) breakCtrl.text = nextB;
        final nextW = w.toString();
        if (workingCtrl.text != nextW) workingCtrl.text = nextW;
      } finally {
        updatingWorkBreak = false;
      }
    }

    // 初期値整合
    final initDur = durationMinutes();
    final initWorking = block.workingMinutes.clamp(0, initDur);
    final initBreak = (initDur - initWorking).clamp(0, initDur);
    workingCtrl.text = initWorking.toString();
    breakCtrl.text = initBreak.toString();

    Future<void> pickStart(StateSetter setLocal) async {
      final picked = await showTimePicker(context: context, initialTime: start);
      if (picked == null) return;
      setLocal(() {
        start = picked;
        // 変更後も整合維持
        if (lastEditedWorking) {
          syncFromWorking();
        } else {
          syncFromBreak();
        }
      });
    }

    Future<void> pickEnd(StateSetter setLocal) async {
      final picked = await showTimePicker(context: context, initialTime: end);
      if (picked == null) return;
      setLocal(() {
        end = picked;
        if (lastEditedWorking) {
          syncFromWorking();
        } else {
          syncFromBreak();
        }
      });
    }

    final saved = await showImeSafeDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final theme = Theme.of(ctx);
          final width = MediaQuery.of(ctx).size.width;
          final targetWidth = (width - 48).clamp(360.0, 720.0);

          // 予定ブロック編集（BlockEditorForm）と同じ装飾で統一
          InputDecoration outlinedDeco(String label, {String? hintText}) =>
              InputDecoration(
                labelText: label,
                hintText: hintText,
                border: const OutlineInputBorder(),
                floatingLabelBehavior: FloatingLabelBehavior.always,
              );
          InputDecoration denseDeco(String label) => InputDecoration(
                labelText: label,
                border: const OutlineInputBorder(),
                floatingLabelBehavior: FloatingLabelBehavior.always,
                filled: true,
                fillColor: theme.inputDecorationTheme.fillColor ??
                    theme.colorScheme.surfaceContainerHighest,
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              );

          const double unifiedFontSize = 16.0;
          const double singleLineFieldHeight = 44;

          Widget subProjectField() {
            final field = InputDecorator(
              decoration: denseDeco('サブプロジェクト'),
              isEmpty: subProjectCtrl.text.isEmpty,
              child: SubProjectInputField(
                controller: subProjectCtrl,
                projectId: selectedProjectId ?? '',
                currentSubProjectId: selectedSubProjectId,
                height: singleLineFieldHeight,
                fontSize: unifiedFontSize,
                onSubProjectChanged: (subProjectId, subProjectLabel) async {
                  setLocal(() {
                    if (subProjectId == null ||
                        subProjectId.isEmpty ||
                        subProjectId == '__clear__') {
                      selectedSubProjectId = null;
                      selectedSubProjectName = null;
                      subProjectCtrl.text = '';
                    } else {
                      selectedSubProjectId = subProjectId;
                      selectedSubProjectName = subProjectLabel;
                      subProjectCtrl.text = subProjectLabel ?? '';
                    }
                  });
                },
                onAutoSave: () {},
                withBackground: false,
                useOutlineBorder: false,
              ),
            );
            if (selectedProjectId == null || selectedProjectId!.trim().isEmpty) {
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('先にプロジェクトを設定してください')),
                  );
                },
                child: AbsorbPointer(child: field),
              );
            }
            return field;
          }

          return AlertDialog(
            title: Row(
              children: [
                const Expanded(child: Text('ブロックを編集')),
                IconButton(
                  icon: Icon(Icons.delete_outline, color: theme.colorScheme.error),
                  tooltip: '削除',
                  onPressed: () async {
                    final confirm = await showDialog<bool>(
                      context: ctx,
                      builder: (c) => AlertDialog(
                        title: const Text('ブロックを削除'),
                        content: const Text('このブロックを削除しますか？'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(c).pop(false),
                            child: const Text('キャンセル'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.of(c).pop(true),
                            style: FilledButton.styleFrom(
                              backgroundColor: theme.colorScheme.error,
                            ),
                            child: const Text('削除'),
                          ),
                        ],
                      ),
                    );
                    if (confirm != true || !ctx.mounted) return;
                    await RoutineMutationFacade.instance.deleteBlock(
                      block.id,
                      block.routineTemplateId,
                    );
                    if (!ctx.mounted) return;
                    Navigator.of(ctx).pop(false);
                  },
                ),
              ],
            ),
            content: SizedBox(
              width: targetWidth,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 1. 最上段: 集計外（濃い灰色でいじれない印象）
                    SwitchListTile(
                      title: Text(
                        '集計外',
                        style: TextStyle(
                          color: Theme.of(context).brightness == Brightness.dark
                              ? const Color(0xFF9E9E9E)
                              : const Color(0xFF525252),
                        ),
                      ),
                      value: excludeFromReport,
                      onChanged: (v) => setLocal(() => excludeFromReport = v),
                      contentPadding: EdgeInsets.zero,
                    ),
                    const SizedBox(height: 12),
                    // 2. 開始・終了時刻
                    Row(
                      children: [
                        Expanded(
                          child: InkWell(
                            onTap: () => pickStart(setLocal),
                            child: InputDecorator(
                              decoration: outlinedDeco('開始時刻'),
                              child: Text(_fmtTime(start)),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: InkWell(
                            onTap: () => pickEnd(setLocal),
                            child: InputDecorator(
                              decoration: outlinedDeco('終了時刻'),
                              child: Text(_fmtTime(end)),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // 3. 休憩(分)・稼働(分)
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: breakCtrl,
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: unifiedFontSize),
                            decoration: outlinedDeco('休憩(分)'),
                            keyboardType: TextInputType.number,
                            onChanged: (_) {
                              if (updatingWorkBreak) return;
                              lastEditedWorking = false;
                              setLocal(() {});
                              syncFromBreak();
                              setLocal(() {});
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: workingCtrl,
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: unifiedFontSize),
                            decoration: outlinedDeco('稼働(分)'),
                            keyboardType: TextInputType.number,
                            onChanged: (_) {
                              if (updatingWorkBreak) return;
                              lastEditedWorking = true;
                              setLocal(() {});
                              syncFromWorking();
                              setLocal(() {});
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // 4. ブロック名
                    TextField(
                      controller: nameCtrl,
                      style: const TextStyle(fontSize: unifiedFontSize),
                      decoration: outlinedDeco('ブロック名'),
                    ),
                    const SizedBox(height: 12),
                    // 5. プロジェクト
                    InputDecorator(
                      decoration: denseDeco('プロジェクト'),
                      isEmpty: projectCtrl.text.isEmpty,
                      child: ProjectInputField(
                        controller: projectCtrl,
                        height: singleLineFieldHeight,
                        fontSize: unifiedFontSize,
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
                              projectCtrl.text = _projectName(projectId);
                              selectedSubProjectId = null;
                              selectedSubProjectName = null;
                              subProjectCtrl.text = '';
                            }
                          });
                        },
                        onAutoSave: () {},
                        withBackground: false,
                        useOutlineBorder: false,
                      ),
                    ),
                    const SizedBox(height: 12),
                    // 6. サブプロジェクト
                    subProjectField(),
                    const SizedBox(height: 12),
                    // 7. モード・場所（1行、予定ブロック編集と同じ）
                    Row(
                      children: [
                        Expanded(
                          child: InputDecorator(
                            decoration: denseDeco('モード'),
                            isEmpty: modeCtrl.text.isEmpty,
                            child: ModeInputField(
                              controller: modeCtrl,
                              height: singleLineFieldHeight,
                              fontSize: unifiedFontSize,
                              onModeChanged: (modeId) async {
                                setLocal(() {
                                  if (modeId == null ||
                                      modeId.isEmpty ||
                                      modeId == '__clear__') {
                                    selectedModeId = null;
                                    modeCtrl.text = '';
                                  } else {
                                    selectedModeId = modeId;
                                    modeCtrl.text = _modeName(modeId);
                                  }
                                });
                              },
                              onAutoSave: () {},
                              withBackground: false,
                              useOutlineBorder: false,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: InputDecorator(
                            decoration: denseDeco('場所'),
                            child: SizedBox(
                              height: singleLineFieldHeight,
                              child: TextField(
                                controller: locationCtrl,
                                style: const TextStyle(fontSize: unifiedFontSize),
                                maxLines: 1,
                                textAlignVertical: TextAlignVertical.center,
                                decoration: const InputDecoration.collapsed(
                                    hintText: ''),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '所要: ${durationMinutes()}分（${_fmtTime(start)}〜${_fmtTime(end)}）',
                      style: theme.textTheme.bodySmall,
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
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('保存'),
              ),
            ],
          );
        },
      ),
    );

    if (saved == true) {
      final dur = durationMinutes();
      final normalizedProjectId =
          (selectedProjectId == null || selectedProjectId!.trim().isEmpty)
              ? null
              : selectedProjectId!.trim();
      final normalizedSubProjectId =
          (selectedSubProjectId == null || selectedSubProjectId!.trim().isEmpty)
              ? null
              : selectedSubProjectId!.trim();
      final normalizedSubProjectName = (selectedSubProjectName == null ||
              selectedSubProjectName!.trim().isEmpty)
          ? null
          : selectedSubProjectName!.trim();
      final normalizedModeId =
          (selectedModeId == null || selectedModeId!.trim().isEmpty)
              ? null
              : selectedModeId!.trim();
      final workingMinutes = clampNonNegInt(workingCtrl.text, max: dur);

      final updated = block.copyWith(
        blockName: nameCtrl.text.trim().isEmpty ? null : nameCtrl.text.trim(),
        startTime: start,
        endTime: end,
        workingMinutes: workingMinutes,
        projectId: normalizedProjectId,
        subProjectId: normalizedSubProjectId,
        subProject: normalizedSubProjectName,
        modeId: normalizedModeId,
        location: locationCtrl.text.trim().isEmpty ? null : locationCtrl.text.trim(),
        excludeFromReport: excludeFromReport,
      );
      await RoutineMutationFacade.instance.updateBlock(updated);
    }

    nameCtrl.dispose();
    projectCtrl.dispose();
    subProjectCtrl.dispose();
    modeCtrl.dispose();
    locationCtrl.dispose();
    breakCtrl.dispose();
    workingCtrl.dispose();
  }

  Map<String, _ProjectTimeSummary> _computeProjectSummaries(
    List<RoutineBlockV2> blocks,
  ) {
    final map = <String, _ProjectTimeSummary>{};
    for (final b in blocks) {
      final key = (b.projectId == null || b.projectId!.trim().isEmpty)
          ? '__none__'
          : b.projectId!.trim();
      final total = _minutesBetween(b.startTime, b.endTime);
      final work = b.workingMinutes.clamp(0, total);
      final rest = (total - work).clamp(0, total);
      map.update(
        key,
        (prev) => prev.add(workMinutes: work, restMinutes: rest, totalMinutes: total),
        ifAbsent: () => _ProjectTimeSummary(
          workMinutes: work,
          restMinutes: rest,
          totalMinutes: total,
        ),
      );
    }
    return map;
  }
}

class _RoutineDayTimelinePreview extends StatelessWidget {
  final List<RoutineBlockV2> blocks;
  final Map<String, List<RoutineTaskV2>> tasksByBlockId;
  final ScrollController controller;
  final bool shouldAutoScroll;
  final void Function(RoutineBlockV2 block) onTapBlock;
  final VoidCallback onAutoScrolled;
  final Map<String, Color> projectColorByKey;

  const _RoutineDayTimelinePreview({
    required this.blocks,
    required this.tasksByBlockId,
    required this.controller,
    required this.shouldAutoScroll,
    required this.onTapBlock,
    required this.onAutoScrolled,
    required this.projectColorByKey,
  });

  static const double _baseHourHeight = 44.0;
  static const double _timeColWidth = 60.0;
  static const double _minBlockHeight = 22.0;

  String _fmt2(int v) => v.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    int blockStartAbsMinutes(RoutineBlockV2 b) =>
        b.startTime.hour * 60 + b.startTime.minute;

    int blockEndAbsMinutes(RoutineBlockV2 b) {
      final startMin = blockStartAbsMinutes(b);
      var endMin = b.endTime.hour * 60 + b.endTime.minute;
      if (endMin <= startMin) endMin += 24 * 60; // 日跨ぎ
      return endMin;
    }

    // 仕様: 「最後のブロックの終了時刻」を基準に、そこから“時刻として1時間前”を起点にして
    // 常に25時間分（= 翌朝1時間後まで）を表示する。
    //
    // 例: lastEnd=翌07:00 -> start=06:00 -> 06:00〜翌07:00（25h）
    const int hoursCount = 25;
    const int maxDisplayMinutes = hoursCount * 60;
    const int defaultStartMinuteOfDay = 6 * 60; // ブロックが無い場合の既定（06:00〜翌07:00）

    final int maxEndAbs = blocks.isEmpty
        ? (defaultStartMinuteOfDay + maxDisplayMinutes)
        : blocks
            .map(blockEndAbsMinutes)
            .fold<int>(0, (m, v) => v > m ? v : m);

    // “見せたい開始時刻”は lastEnd の 1時間前（時刻として）。
    // ただし表示は常に25時間なので、絶対分では lastEnd - 25h を起点にする。
    final int windowStartAbs = maxEndAbs - maxDisplayMinutes;
    final int windowStartMinuteOfDay =
        ((maxEndAbs % (24 * 60)) - 60 + (24 * 60)) % (24 * 60);

    final hourHeights = List<double>.filled(hoursCount, _baseHourHeight);
    final prefix = List<double>.generate(hoursCount + 1, (i) => 0);
    for (int i = 1; i < hoursCount + 1; i++) {
      prefix[i] = prefix[i - 1] + hourHeights[i - 1];
    }
    final totalHeight = prefix[hoursCount];

    final segs = <_PreviewSeg>[];
    for (final b in blocks) {
      final startAbs = blockStartAbsMinutes(b);
      var endAbs = b.endTime.hour * 60 + b.endTime.minute;
      bool continuesNextDay = false;
      if (endAbs <= startAbs) {
        endAbs += 24 * 60;
        continuesNextDay = true;
      }

      final relStart = startAbs - windowStartAbs;
      final relEnd = endAbs - windowStartAbs;
      final clampedStart = relStart.clamp(0, maxDisplayMinutes);
      final clampedEnd = relEnd.clamp(0, maxDisplayMinutes);
      if (clampedStart >= maxDisplayMinutes) continue;
      if (clampedEnd <= clampedStart) continue;
      segs.add(
        _PreviewSeg(
          block: b,
          startMinute: clampedStart,
          endMinuteExclusive: clampedEnd,
          continuesNextDay: continuesNextDay && endAbs > 24 * 60,
        ),
      );
    }

    // overlap detection + 2-column assignment (same spirit as calendar day view)
    final n = segs.length;
    final startMins = List<int>.filled(n, 0);
    final endMins = List<int>.filled(n, 0);
    final tops = List<double>.filled(n, 0);
    final heights = List<double>.filled(n, 0);

    for (int i = 0; i < n; i++) {
      startMins[i] = segs[i].startMinute;
      endMins[i] = segs[i].endMinuteExclusive;
      final stHour = (segs[i].startMinute ~/ 60).clamp(0, 23);
      final stMin = (segs[i].startMinute % 60).clamp(0, 59);
      tops[i] = prefix[stHour] + hourHeights[stHour] * (stMin / 60.0);
      final dur = (segs[i].endMinuteExclusive - segs[i].startMinute).clamp(1, 24 * 60);
      heights[i] = (dur / 60.0) * _baseHourHeight;
      if (heights[i] < _minBlockHeight) heights[i] = _minBlockHeight;
    }

    final halfWidth = List<bool>.filled(n, false);
    for (int i = 0; i < n; i++) {
      for (int j = i + 1; j < n; j++) {
        if (startMins[i] < endMins[j] && endMins[i] > startMins[j]) {
          halfWidth[i] = true;
          halfWidth[j] = true;
        }
      }
    }

    final columns = List<int>.filled(n, 0);
    final order = List<int>.generate(n, (i) => i)
      ..sort((a, b) => startMins[a].compareTo(startMins[b]));
    final active = <int>[];
    final activeCol = <int, int>{};
    for (final idx in order) {
      active.removeWhere((k) => endMins[k] <= startMins[idx]);
      activeCol.removeWhere((k, _) => endMins[k] <= startMins[idx]);
      final used = <int>{};
      for (final k in active) {
        used.add(activeCol[k] ?? 0);
      }
      int col;
      if (used.contains(0) && used.contains(1)) {
        int col0End = 1 << 30;
        int col1End = 1 << 30;
        for (final k in active) {
          final c = activeCol[k] ?? 0;
          if (c == 0 && endMins[k] < col0End) col0End = endMins[k];
          if (c == 1 && endMins[k] < col1End) col1End = endMins[k];
        }
        col = col0End <= col1End ? 0 : 1;
      } else if (!used.contains(0)) {
        col = 0;
      } else {
        col = 1;
      }
      columns[idx] = col;
      active.add(idx);
      activeCol[idx] = col;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!shouldAutoScroll) return;
      if (!controller.hasClients) return;
      double target = 0.0;
      if (segs.isNotEmpty) {
        final earliest = segs
            .map((s) => s.startMinute)
            .reduce((a, b) => a < b ? a : b);
        final h = (earliest ~/ 60).clamp(0, hoursCount - 1);
        final m = (earliest % 60).clamp(0, 59);
        final y = prefix[h] + hourHeights[h] * (m / 60.0);
        target = (y - 120).clamp(0.0, (totalHeight - 1).clamp(0.0, double.infinity));
      }
      controller.jumpTo(target);
      onAutoScrolled();
    });

    // IMPORTANT:
    // - 画面全体の幅(MediaQuery)ではなく、このウィジェットに与えられた幅 constraints を基準にする。
    //   （PCの左右分割やブラウザ幅変更時に、ブロックが枠外へはみ出すバグの原因になる）
    return LayoutBuilder(
      builder: (context, layout) {
        final laneWidth =
            (layout.maxWidth - _timeColWidth).clamp(0.0, double.infinity);
        final colWidth = laneWidth; // 1列ベース（重なった場合だけ 2分割）
        final fullW = math.max(0.0, colWidth - 6.0);
        final halfW = math.max(0.0, colWidth / 2.0 - 6.0);

        return SingleChildScrollView(
                controller: controller,
                child: SizedBox(
                  height: totalHeight,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: Row(
                          children: [
                            SizedBox(
                              width: _timeColWidth,
                              child: Column(
                                children: [
                                  for (int h = 0; h < hoursCount; h++)
                                    SizedBox(
                                      height: hourHeights[h],
                                      child: Align(
                                        alignment: Alignment.topRight,
                                        child: Padding(
                                          padding: const EdgeInsets.only(right: 4.0),
                                          child: Transform.translate(
                                            offset: const Offset(0, -8),
                                            child: Text(
                                              () {
                                                final v =
                                                    windowStartMinuteOfDay + h * 60;
                                                final hour = (v ~/ 60) % 24;
                                                final isNext = v >= 24 * 60;
                                                final hh = _fmt2(hour);
                                                return isNext ? '翌$hh:00' : '$hh:00';
                                              }(),
                                              style: TextStyle(
                                                fontSize: 10,
                                                color: Theme.of(context)
                                                    .textTheme
                                                    .bodySmall
                                                    ?.color,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            Expanded(
                              child: Column(
                                children: [
                                  for (int h = 0; h < hoursCount; h++)
                                    Container(
                                      height: hourHeights[h],
                                      decoration: BoxDecoration(
                                        border: Border(
                                          top: BorderSide(
                                              color: Theme.of(context).dividerColor),
                                          right: BorderSide(
                                              color: Theme.of(context).dividerColor),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      for (int i = 0; i < segs.length; i++)
                        Positioned(
                          left: _timeColWidth + (() {
                            if (halfWidth[i] && columns[i] == 1) {
                              return colWidth / 2.0;
                            }
                            return 0.0;
                          })(),
                          width: halfWidth[i] ? halfW : fullW,
                          top: tops[i],
                          height: heights[i],
                          child: _PreviewBlockCard(
                            block: segs[i].block,
                            blockIndex: i,
                            onTap: () => onTapBlock(segs[i].block),
                            projectColorByKey: projectColorByKey,
                          ),
                        ),
                    ],
                  ),
                ),
        );
      },
    );
  }
}

class _PreviewSeg {
  final RoutineBlockV2 block;
  final int startMinute;
  final int endMinuteExclusive;
  final bool continuesNextDay;

  const _PreviewSeg({
    required this.block,
    required this.startMinute,
    required this.endMinuteExclusive,
    required this.continuesNextDay,
  });
}

class _PreviewBlockCard extends StatelessWidget {
  final RoutineBlockV2 block;
  final int blockIndex;
  final VoidCallback? onTap;
  final Map<String, Color> projectColorByKey;

  const _PreviewBlockCard({
    required this.block,
    required this.blockIndex,
    this.onTap,
    required this.projectColorByKey,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = (block.blockName == null || block.blockName!.trim().isEmpty)
        ? '名称未設定'
        : block.blockName!.trim();
    final isExcluded = block.excludeFromReport == true;

    // 右側のプロジェクト色と同じ色で表示（表示順で割り当てた色を使う）
    final projectKey = (block.projectId == null || block.projectId!.trim().isEmpty)
        ? '__none__'
        : block.projectId!.trim();
    final Color accentColor = projectColorByKey[projectKey] ?? _reviewProjectColor(projectKey, scheme);
    final Color bg;
    final Color border;
    final Color textColor;
    if (isExcluded) {
      // 集計外ブロックはモノトーン（グレー系）で表示
      bg = scheme.surfaceContainerHighest;
      border = scheme.outline;
      textColor = scheme.onSurface.withOpacity(0.7);
    } else {
      bg = accentColor.withOpacity(0.22);
      border = accentColor;
      textColor = scheme.onSurface;
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(2),
        child: Container(
          decoration: BoxDecoration(
            color: bg,
            border: Border.all(color: border.withOpacity(isExcluded ? 0.9 : 0.55)),
            borderRadius: BorderRadius.circular(2),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          alignment: Alignment.topLeft,
          child: Text(
            title,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: textColor,
            ),
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
        ),
      ),
    );
  }
}

class _ProjectDurationPanel extends StatelessWidget {
  final Map<String, _ProjectTimeSummary> summariesByProjectId;
  final List<RoutineBlockV2> blocks;
  final Map<String, Color> projectColorByKey;

  const _ProjectDurationPanel({
    required this.summariesByProjectId,
    required this.blocks,
    required this.projectColorByKey,
  });

  String _projectName(String key) {
    if (key == '__none__') return '未設定';
    final p = ProjectService.getProjectById(key);
    final name = p?.name.trim();
    if (name != null && name.isNotEmpty) return name;
    return key; // fallback
  }

  @override
  Widget build(BuildContext context) {
    // 右ペイン上半分: 円グラフのみ（下半分はメモ欄に変更済み）
    return _RoutineDayPieChart(
      blocks: blocks,
      summariesByProjectId: summariesByProjectId,
      projectNameOf: _projectName,
      projectColorByKey: projectColorByKey,
      showBorder: true,
    );
  }
}

/// 右ペイン下半分: メモ欄（タスクのメモと同じスタイルのテキストフィールド）
class _MemoPanel extends StatelessWidget {
  final TextEditingController controller;

  const _MemoPanel({required this.controller});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleStyle = theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w700,
        );
    final bgColor = theme.scaffoldBackgroundColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisAlignment: MainAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
          child: Text('メモ欄', style: titleStyle),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: TextField(
              controller: controller,
              maxLines: null,
              minLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              keyboardType: TextInputType.multiline,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurface,
              ),
              decoration: InputDecoration(
                hintText: 'メモを入力...',
                hintStyle: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurface.withOpacity(0.5),
                ),
                filled: true,
                fillColor: bgColor,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                errorBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                alignLabelWithHint: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _RoutineDayPieChart extends StatefulWidget {
  final List<RoutineBlockV2> blocks;
  final Map<String, _ProjectTimeSummary> summariesByProjectId;
  final String Function(String key) projectNameOf;
  final Map<String, Color> projectColorByKey;
  final bool showBorder;
  const _RoutineDayPieChart({
    required this.blocks,
    required this.summariesByProjectId,
    required this.projectNameOf,
    required this.projectColorByKey,
    this.showBorder = false,
  });

  @override
  State<_RoutineDayPieChart> createState() => _RoutineDayPieChartState();
}

class _RoutineDayPieChartState extends State<_RoutineDayPieChart> {
  bool _showOverlayTooltip = false;
  String _overlayTooltipText = '';
  Offset? _tooltipOffset;

  static int _minutesBetween(TimeOfDay start, TimeOfDay end) {
    final s = start.hour * 60 + start.minute;
    final e = end.hour * 60 + end.minute;
    int diff = e - s;
    if (diff <= 0) diff += 24 * 60;
    return diff;
  }

  String _formatMinutesShort(int minutes) {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (h <= 0) return '${m}分';
    if (m == 0) return '${h}時間';
    return '${h}時間${m}分';
  }

  /// 集計外の表示用（濃い灰色・いじれない印象）
  static Color _excludedGrayColor(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF757575)
        : const Color(0xFF525252);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final neutralColor = scheme.outline;
    final excludedColor = _excludedGrayColor(context);

    // 右側の集計と同じ: プロジェクト別作業時間（作業時間>0のみ）。多い順、「未設定」は最後
    final projectEntries = widget.summariesByProjectId.entries
        .where((e) => e.value.workMinutes > 0)
        .toList()
      ..sort((a, b) {
        final aIsUnset = a.key == '__none__' ? 1 : 0;
        final bIsUnset = b.key == '__none__' ? 1 : 0;
        if (aIsUnset != bIsUnset) return aIsUnset.compareTo(bIsUnset);
        return b.value.workMinutes.compareTo(a.value.workMinutes);
      });
    final totalRest = widget.summariesByProjectId.values.fold<int>(
      0, (sum, s) => sum + s.restMinutes,
    );
    final excludedBlocks = widget.blocks.where((b) => b.excludeFromReport == true).toList();
    int excludedSleepMinutes = 0;
    int excludedOtherMinutes = 0;
    for (final b in excludedBlocks) {
      final min = _minutesBetween(b.startTime, b.endTime);
      if (RoutineSleepBlockService.isSleepBlock(b)) {
        excludedSleepMinutes += min;
      } else {
        excludedOtherMinutes += min;
      }
    }

    // 円グラフ用: 右側の凡例と同じ順・同じ内訳（プロジェクトごと + 休憩 + 集計外）
    final pieEntries = <({String label, int minutes, Color color})>[];
    for (final e in projectEntries) {
      pieEntries.add((
        label: widget.projectNameOf(e.key),
        minutes: e.value.workMinutes,
        color: widget.projectColorByKey[e.key] ?? _reviewProjectColor(e.key, scheme),
      ));
    }
    if (totalRest > 0) {
      pieEntries.add((label: '休憩時間', minutes: totalRest, color: neutralColor));
    }
    // 円グラフでは睡眠（集計外）は表示しない。集計外は濃い灰色でいじれない印象
    if (excludedOtherMinutes > 0) {
      pieEntries.add((label: 'その他（集計外）', minutes: excludedOtherMinutes, color: excludedColor));
    }

    final unassignedMinutes = widget.summariesByProjectId['__none__']?.workMinutes ?? 0;

    final total = pieEntries.fold<int>(0, (sum, e) => sum + e.minutes);
    final entriesWithPositiveMinutes = pieEntries.where((e) => e.minutes > 0).toList();
    final sections = <PieChartSectionData>[];
    if (total > 0) {
      for (final e in entriesWithPositiveMinutes) {
        sections.add(
          PieChartSectionData(
            value: e.minutes.toDouble(),
            showTitle: false,
            color: e.color,
          ),
        );
      }
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: widget.showBorder
            ? Border(bottom: BorderSide(color: Theme.of(context).dividerColor))
            : null,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          const double headerH = 28.0;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: headerH,
                child: Row(
                  children: [
                    Icon(Icons.pie_chart_outline,
                        size: 18, color: scheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'プロジェクトごと',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ),
                    const Flexible(child: SizedBox.shrink()),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: LayoutBuilder(
                          builder: (context, c) {
                            final maxWidth = c.maxWidth.isFinite ? c.maxWidth : 0.0;
                            final maxHeight = c.maxHeight.isFinite
                                ? c.maxHeight
                                : (c.maxWidth.isFinite ? c.maxWidth : 0.0);
                            final squareSize = math.min(maxWidth, maxHeight);
                            if (total <= 0 || squareSize < 60) {
                              return Center(
                                child: Text(
                                  total <= 0 ? 'データなし' : '表示領域が小さすぎます',
                                  style:
                                      Theme.of(context).textTheme.bodySmall,
                                  textAlign: TextAlign.center,
                                ),
                              );
                            }
                            // fl_chart の section.radius 指定は環境によって過大描画を
                            // 誘発するため、半径はライブラリの自動フィットに任せる。
                            // これで表示領域の正方形内に常に「円グラフ全体」が収まる。
                            final centerSpace =
                                (squareSize * 0.20).clamp(12.0, 56.0).toDouble();
                            return Stack(
                              clipBehavior: Clip.none,
                              children: [
                                ClipRect(
                                  child: Center(
                                    child: SizedBox.square(
                                      dimension: squareSize,
                                      child: PieChart(
                                        PieChartData(
                                          startDegreeOffset: 270,
                                          sections: sections,
                                          sectionsSpace: 1,
                                          centerSpaceRadius: centerSpace,
                                          borderData: FlBorderData(show: false),
                                          pieTouchData: PieTouchData(
                                            enabled: true,
                                            touchCallback: (event, response) {
                                              if (!event.isInterestedForInteractions ||
                                                  response == null ||
                                                  response.touchedSection == null) {
                                                if (_showOverlayTooltip) {
                                                  setState(() {
                                                    _showOverlayTooltip = false;
                                                    _tooltipOffset = null;
                                                  });
                                                }
                                                return;
                                              }
                                              final idx = response.touchedSection!.touchedSectionIndex;
                                              if (idx < 0 || idx >= entriesWithPositiveMinutes.length) {
                                                if (_showOverlayTooltip) {
                                                  setState(() {
                                                    _showOverlayTooltip = false;
                                                    _tooltipOffset = null;
                                                  });
                                                }
                                                return;
                                              }
                                              final e = entriesWithPositiveMinutes[idx];
                                              setState(() {
                                                _overlayTooltipText =
                                                    '${e.label}: ${_formatMinutesShort(e.minutes)}';
                                                _showOverlayTooltip = true;
                                                _tooltipOffset = null;
                                              });
                                            },
                                          ),
                                        ),
                                        swapAnimationDuration: Duration.zero,
                                      ),
                                    ),
                                  ),
                                ),
                                Positioned(
                                  top: 4,
                                  left: 0,
                                  right: 0,
                                  child: IgnorePointer(
                                    child: AnimatedOpacity(
                                      duration: const Duration(milliseconds: 120),
                                      opacity: _showOverlayTooltip ? 1.0 : 0.0,
                                      child: LayoutBuilder(
                                        builder: (context, constraints) {
                                          final w = constraints.maxWidth;
                                          final dx = _tooltipOffset?.dx ?? w / 2;
                                          final alignX = (w > 0) ? ((dx / w) * 2 - 1).clamp(-1.0, 1.0) : 0.0;
                                          return Align(
                                            alignment: Alignment(alignX, -1),
                                            child: Container(
                                              decoration: BoxDecoration(
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .inverseSurface
                                                    .withOpacity(0.90),
                                                borderRadius: BorderRadius.circular(6),
                                                boxShadow: [
                                                  BoxShadow(
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .shadow
                                                        .withOpacity(0.18),
                                                    blurRadius: 6,
                                                    offset: const Offset(0, 2),
                                                  ),
                                                ],
                                                border: Border.all(
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .outlineVariant
                                                      .withOpacity(0.6),
                                                ),
                                              ),
                                              padding: const EdgeInsets.symmetric(
                                                horizontal: 10,
                                                vertical: 6,
                                              ),
                                              child: Text(
                                                _overlayTooltipText,
                                                style: TextStyle(
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .onInverseSurface,
                                                  fontWeight: FontWeight.w800,
                                                  fontSize: 13,
                                                ),
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (projectEntries.isEmpty && totalRest == 0)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: Text(
                                    'プロジェクト未設定',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(
                                          color: scheme.outline,
                                        ),
                                  ),
                                ),
                              for (final e in projectEntries)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 10,
                                        height: 10,
                                        decoration: BoxDecoration(
                                          color: widget.projectColorByKey[e.key] ?? _reviewProjectColor(e.key, scheme),
                                          borderRadius: BorderRadius.circular(2),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          widget.projectNameOf(e.key),
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall,
                                          overflow: TextOverflow.ellipsis,
                                          maxLines: 1,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        _formatMinutesShort(e.value.workMinutes),
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall,
                                      ),
                                    ],
                                  ),
                                ),
                              if (totalRest > 0)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 10,
                                        height: 10,
                                        decoration: BoxDecoration(
                                          color: neutralColor,
                                          borderRadius: BorderRadius.circular(2),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          '休憩時間',
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall,
                                          overflow: TextOverflow.ellipsis,
                                          maxLines: 1,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        _formatMinutesShort(totalRest),
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall,
                                      ),
                                    ],
                                  ),
                                ),
                              if (excludedSleepMinutes > 0)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 10,
                                        height: 10,
                                        decoration: BoxDecoration(
                                          color: neutralColor,
                                          borderRadius: BorderRadius.circular(2),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          '睡眠',
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall,
                                          overflow: TextOverflow.ellipsis,
                                          maxLines: 1,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        _formatMinutesShort(excludedSleepMinutes),
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall,
                                      ),
                                    ],
                                  ),
                                ),
                              if (excludedOtherMinutes > 0)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 10,
                                        height: 10,
                                        decoration: BoxDecoration(
                                          color: excludedColor,
                                          borderRadius: BorderRadius.circular(2),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          'その他（集計外）',
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(color: excludedColor),
                                          overflow: TextOverflow.ellipsis,
                                          maxLines: 1,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        _formatMinutesShort(excludedOtherMinutes),
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(color: excludedColor),
                                      ),
                                    ],
                                  ),
                                ),
                              if (unassignedMinutes > 0)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 10,
                                        height: 10,
                                        decoration: BoxDecoration(
                                          color: neutralColor,
                                          borderRadius: BorderRadius.circular(2),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          '未割り当て',
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall,
                                          overflow: TextOverflow.ellipsis,
                                          maxLines: 1,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        _formatMinutesShort(unassignedMinutes),
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall,
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ProjectDurationListPanel extends StatelessWidget {
  final _ProjectTimeSummary total;
  final List<MapEntry<String, _ProjectTimeSummary>> entries;
  final int excludedTotalMinutes;
  final int unassignedMinutes;
  final String Function(int minutes) formatMinutes;
  final String Function(String key) projectNameOf;

  const _ProjectDurationListPanel({
    required this.total,
    required this.entries,
    required this.excludedTotalMinutes,
    required this.unassignedMinutes,
    required this.formatMinutes,
    required this.projectNameOf,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final titleStyle = Theme.of(context).textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w700,
        );
    final rowStyle = Theme.of(context).textTheme.bodyMedium;
    final totalStyle = Theme.of(context).textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w800,
        );

    final showRest = total.restMinutes > 0;
    final showExcluded = excludedTotalMinutes > 0;
    final showUnassigned = unassignedMinutes > 0;
    final itemCount = entries.length + (showRest ? 1 : 0) + (showExcluded ? 1 : 0) + (showUnassigned ? 1 : 0);
    final neutralColor = scheme.outline;
    final excludedColor = Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF757575)
        : const Color(0xFF525252);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisAlignment: MainAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
          child: Text('プロジェクト別 作業時間', style: titleStyle),
        ),
        Expanded(
          child: entries.isEmpty && !showRest && !showExcluded && !showUnassigned
              ? Center(
                  child: Text(
                    'プロジェクトが設定されたブロックがありません',
                    style: rowStyle,
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  itemCount: itemCount,
                  itemBuilder: (context, index) {
                    if (showRest && index == entries.length) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                color: neutralColor,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '休憩時間：${formatMinutes(total.restMinutes)}',
                                style: rowStyle,
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                              ),
                            ),
                          ],
                        ),
                      );
                    }
                    if (showExcluded && index == entries.length + (showRest ? 1 : 0)) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                color: excludedColor,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '集計外：${formatMinutes(excludedTotalMinutes)}',
                                style: rowStyle?.copyWith(color: excludedColor),
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                              ),
                            ),
                          ],
                        ),
                      );
                    }
                    if (showUnassigned && index == entries.length + (showRest ? 1 : 0) + (showExcluded ? 1 : 0)) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                color: neutralColor,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '未割り当て：${formatMinutes(unassignedMinutes)}',
                                style: rowStyle,
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                              ),
                            ),
                          ],
                        ),
                      );
                    }
                    final String name = projectNameOf(entries[index].key);
                    final _ProjectTimeSummary s = entries[index].value;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: _reviewProjectColor(entries[index].key, scheme),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '$name：${formatMinutes(s.workMinutes)}',
                              style: rowStyle,
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
          child: Text(
            '合計：${formatMinutes(total.workMinutes)}',
            style: totalStyle,
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }
}

class _ProjectTimeSummary {
  final int workMinutes;
  final int restMinutes;
  final int totalMinutes;

  const _ProjectTimeSummary({
    required this.workMinutes,
    required this.restMinutes,
    required this.totalMinutes,
  });

  _ProjectTimeSummary add({
    required int workMinutes,
    required int restMinutes,
    required int totalMinutes,
  }) {
    return _ProjectTimeSummary(
      workMinutes: this.workMinutes + workMinutes,
      restMinutes: this.restMinutes + restMinutes,
      totalMinutes: this.totalMinutes + totalMinutes,
    );
  }
}

