// ignore_for_file: use_build_context_synchronously

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:provider/provider.dart';
import '../models/work_type.dart';
import '../models/routine_block_v2.dart';
import '../models/routine_template_v2.dart';
import '../models/project.dart';
import '../services/routine_template_v2_sync_service.dart';
import '../services/routine_template_v2_service.dart';

import '../services/project_service.dart';
import '../services/project_sync_service.dart';
import '../services/mode_service.dart'; // 追加
import '../services/auth_service.dart';
import '../providers/task_provider.dart';

import '../services/routine_block_v2_sync_service.dart';
import '../services/routine_task_v2_sync_service.dart';
import '../services/device_info_service.dart';
import '../services/routine_mutation_facade.dart';
import '../services/routine_block_v2_service.dart';
import '../services/routine_task_v2_service.dart';
import '../services/routine_lamport_clock_service.dart';
import '../services/routine_sleep_block_service.dart';
import '../services/routine_database_service.dart';

import '../widgets/app_notifications.dart';
import '../utils/ime_safe_dialog.dart';
import '../app/theme/app_color_tokens.dart';
import '../app/theme/domain_colors.dart';
import 'routine_day_review_screen.dart';

class _DraftTimeBlock {
  _DraftTimeBlock({
    required this.id,
    required this.name,
    required this.startTime,
    required this.endTime,
  });

  final String id;
  String name;
  TimeOfDay startTime;
  TimeOfDay endTime;

  String get timeRangeText {
    String fmt(TimeOfDay t) =>
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    return '${fmt(startTime)} - ${fmt(endTime)}';
  }
}

class RoutineScreen extends StatefulWidget {
  RoutineScreen({Key? key}) : super(key: key ?? globalKey);

  static final GlobalKey<RoutineScreenState> globalKey =
      GlobalKey<RoutineScreenState>();
  static final ValueNotifier<bool> syncInProgressNotifier = ValueNotifier<bool>(
    false,
  );

  @override
  State<RoutineScreen> createState() => RoutineScreenState();
}

class RoutineScreenState extends State<RoutineScreen> {
  bool _isSyncing = false; // バックグラウンド同期用のフラグ
  bool _isCopying = false; // コピー処理中フラグ

  @override
  void initState() {
    super.initState();
    // 画面表示時に即座にデータを表示し、その後バックグラウンドで同期
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _performManualSync();
    });
  }

  @override
  void dispose() {
    RoutineScreen.syncInProgressNotifier.value = false;
    super.dispose();
  }

  bool get isSyncing => _isSyncing;

  Future<void> manualSync({bool forceFullSync = false}) =>
      _performManualSync(forceFullSync: forceFullSync);

  Future<void> _performManualSync({bool forceFullSync = false}) async {
    if (_isSyncing) return;

    RoutineScreen.syncInProgressNotifier.value = true;
    setState(() => _isSyncing = true);

    try {
      final templateV2Sync = RoutineTemplateV2SyncService();
      final blockV2Sync = RoutineBlockV2SyncService();
      final taskV2Sync = RoutineTaskV2SyncService();

      final futures = <Future>[
        templateV2Sync.performSync(forceFullSync: forceFullSync),
        blockV2Sync.performSync(forceFullSync: forceFullSync),
        taskV2Sync.performSync(forceFullSync: forceFullSync),
      ];

      await Future.wait(futures).timeout(
        const Duration(seconds: 120),
        onTimeout: () {
          throw TimeoutException('Manual sync timed out');
        },
      );

      if (mounted) {
        setState(() => _isSyncing = false);
      }
      RoutineScreen.syncInProgressNotifier.value = false;
    } catch (e) {
      RoutineScreen.syncInProgressNotifier.value = false;
      // Handle IndexedDB/Hive specific errors more gracefully
      String errorMessage = '同期中にエラーが発生しました';
      if (e.toString().contains('minified:') ||
          e.toString().contains('IndexedDB') ||
          e.toString().contains('Instance of') ||
          e.toString().contains('deleteFromDisk') ||
          e.toString().contains('HiveError')) {
        errorMessage = 'データベースアクセスエラーが発生しました。ページを再読み込みしてください。';
      } else if (e is TimeoutException) {
        errorMessage = '同期がタイムアウトしました。再試行してください。';
      }

      if (mounted) {
        setState(() {
          _isSyncing = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMessage),
            backgroundColor: Theme.of(context).colorScheme.error,
            duration: const Duration(seconds: 4),
            action: SnackBarAction(
              label: '再試行',
              textColor: Theme.of(context).colorScheme.onError,
              onPressed: () => _performManualSync(),
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          RefreshIndicator(
            onRefresh: () => _performManualSync(),
            child: _buildRoutineList(),
          ),
          if (_isCopying)
            Container(
              color: Colors.black26,
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 12),
                    Text(
                      'コピー中...',
                      style: TextStyle(color: Colors.white, fontSize: 14),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'routine_screen_fab',
        onPressed: () => _showAddRoutineDialog(),
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Theme.of(context).colorScheme.onPrimary,
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildRoutineList() {
    final routines = RoutineTemplateV2Service.getAll(includeDeleted: false);
    bool isShortcutLike(RoutineTemplateV2 r) {
      if (r.id == 'shortcut' || r.isShortcut) return true;
      if (r.cloudId == 'shortcut') return true;
      return r.id.startsWith('shortcut');
    }

    // legacy由来で「ショートカット相当」が複数行あると、誤った行を開いて空表示に見える。
    // 一覧表示は常に1行（正規ID優先）へ正規化する。
    final canonicalShortcut = routines.firstWhere(
      (r) => r.id == 'shortcut' || r.cloudId == 'shortcut',
      orElse: () => routines.firstWhere(
        isShortcutLike,
        orElse: () => RoutineTemplateV2(
          id: '__none__',
          title: '',
          color: '',
          createdAt: DateTime.now().toUtc(),
          lastModified: DateTime.now().toUtc(),
        ),
      ),
    );
    final hasShortcut = canonicalShortcut.id != '__none__';
    final nonShortcutRoutines = routines.where((r) => !isShortcutLike(r)).toList();
    final normalizedList = <RoutineTemplateV2>[
      ...nonShortcutRoutines,
      if (hasShortcut) canonicalShortcut,
    ];

    // ルーティンを指定した順番でソート（平日→休日）。ショートカットは常に最後。
    final sortedRoutines = List<RoutineTemplateV2>.from(normalizedList);
    sortedRoutines.sort((a, b) {
      // ショートカットは常に末尾（削除不可のため「一番上の行を削除」が正しく動作するように）
      final aIsShortcut = isShortcutLike(a);
      final bIsShortcut = isShortcutLike(b);
      if (aIsShortcut && !bIsShortcut) return 1;
      if (!aIsShortcut && bIsShortcut) return -1;
      if (aIsShortcut && bIsShortcut) return 0;

      // デフォルトルーティンの順番を定義（平日を0、休日を1にして平日を先に表示）
      final order = {'平日ルーティン': 0, '休日ルーティン': 1, '例外': 2};

      // タイトルまたはapplyDayTypeで判定
      int aOrder = order[a.title] ?? 999;
      int bOrder = order[b.title] ?? 999;

      // タイトルでマッチしない場合はapplyDayTypeで判定
      if (aOrder == 999) {
        if (a.applyDayType == 'weekday') {
          aOrder = 0;
        } else if (a.applyDayType == 'holiday') {
          aOrder = 1;
        }
      }
      if (bOrder == 999) {
        if (b.applyDayType == 'weekday') {
          bOrder = 0;
        } else if (b.applyDayType == 'holiday') {
          bOrder = 1;
        }
      }

      return aOrder.compareTo(bOrder);
    });

    if (normalizedList.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.schedule,
              size: 64,
              color: Theme.of(context).iconTheme.color?.withOpacity( 0.6),
            ),
            const SizedBox(height: 16),
            Text(
              'ルーティンがありません',
              style: TextStyle(
                fontSize: 18,
                color: Theme.of(context).textTheme.bodySmall?.color,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '右下の「+」ボタンをタップして',
              style: TextStyle(
                color: Theme.of(context).textTheme.bodySmall?.color,
              ),
            ),
            Text(
              '新しいルーティンを作成してください',
              style: TextStyle(
                color: Theme.of(context).textTheme.bodySmall?.color,
              ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      itemCount: sortedRoutines.length,
      itemBuilder: (context, index) {
        final routine = sortedRoutines[index];
        final isShortcut = isShortcutLike(routine);
        final normalizedRoutine = routine;
        // Dark/WineDark では Card の既定色が背景と同化して見えることがあるため、
        // タイムラインと同様に「背景より少し明るい面色」を明示する。
        final cardBg = Theme.of(context).colorScheme.surfaceContainerHighest;
        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          color: cardBg,
          child: ListTile(
            title: Text(
              normalizedRoutine.title,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            selected: false,
            onTap: () {
              // ショートカットは Hive 上の正規レコード（id=shortcut）へ寄せる（別行・フラグ欠落での空表示防止）
              var routineToOpen = normalizedRoutine;
              if (isShortcut) {
                final canonical =
                    RoutineTemplateV2Service.getById('shortcut');
                if (canonical != null) routineToOpen = canonical;
              }
              RoutineSelectedNotification(routineToOpen).dispatch(context);
            },
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (normalizedRoutine.memo.isNotEmpty)
                  Text(normalizedRoutine.memo),
                // 「平日」「休日」等の適用日バッジは非表示にする
              ],
            ),
            trailing: PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert),
                  onSelected: (value) {
                    switch (value) {
                      case 'copy':
                        if (!isShortcut) _copyRoutine(normalizedRoutine);
                        break;
                      case 'delete':
                        if (!isShortcut) _deleteRoutine(normalizedRoutine);
                        break;
                      case 'rename':
                        _showEditRoutineTitleDialog(normalizedRoutine);
                        break;
                      case 'change_apply':
                        _showApplyDayTypeSelectionDialog(
                          context,
                          normalizedRoutine.applyDayType,
                          (newApplyDayType) async {
                            normalizedRoutine.applyDayType = newApplyDayType;
                            await _saveTemplateV2WithSync(normalizedRoutine);
                            if (!mounted) return;
                            setState(() {});
                          },
                        );
                        break;
                    }
                  },
                  itemBuilder: (context) => [
                    // ルーティン名を編集
                    const PopupMenuItem(value: 'rename', child: Text('名前を編集')),
                    // 適用日の変更
                    const PopupMenuItem(
                      value: 'change_apply',
                      child: Text('適用日を変更'),
                    ),
                    if (!isShortcut)
                      const PopupMenuItem(value: 'copy', child: Text('コピー')),
                    if (!isShortcut)
                      PopupMenuItem(
                        value: 'delete',
                        child: Text(
                          '削除',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                  ],
                ),
            ),
        );
      },
    );
  }

  Future<void> _saveTemplateV2WithSync(RoutineTemplateV2 template) async {
    await RoutineMutationFacade.instance.updateTemplate(template);
  }

  String _generateTemplateId(DateTime nowUtc) {
    final ms = nowUtc.millisecondsSinceEpoch;
    final micro = nowUtc.microsecond;
    final rand = (ms ^ micro).toRadixString(36);
    return 'rtpl_${ms}_${micro}_$rand';
  }

  String _generateBlockId(String templateId, DateTime nowUtc) {
    final ms = nowUtc.millisecondsSinceEpoch;
    final micro = nowUtc.microsecond;
    final rand = (ms ^ micro ^ templateId.hashCode).toRadixString(36);
    final blockKey = 'blk_${ms}_${micro}_$rand';
    return 'v2blk_${templateId}_$blockKey';
  }

  String _generateTaskId(DateTime nowUtc) {
    final ms = nowUtc.millisecondsSinceEpoch;
    final micro = nowUtc.microsecond;
    final rand = (ms ^ micro).toRadixString(36);
    return 'rtask_${ms}_${micro}_$rand';
  }

  Future<void> _copyRoutine(RoutineTemplateV2 routine) async {
    setState(() => _isCopying = true);
    try {
      final now = DateTime.now().toUtc();
      final deviceId = await DeviceInfoService.getDeviceId();
      final uid = AuthService.getCurrentUserId() ?? routine.userId;

      final newTemplateId = _generateTemplateId(now);
      final ver = await RoutineLamportClockService.next();

      final copied = RoutineTemplateV2(
        id: newTemplateId,
        title: '${routine.title} のコピー',
        memo: routine.memo,
        workType: routine.workType,
        color: routine.color,
        applyDayType: routine.applyDayType,
        isActive: routine.isActive,
        isDeleted: false,
        version: ver,
        deviceId: deviceId,
        userId: uid,
        createdAt: now,
        lastModified: now,
        isShortcut: false,
      )..cloudId = newTemplateId;

      // 一式即時で反映するため、ローカルにだけ書き込んで通知を1回にまとめ、Firebase 同期は後から行う
      RoutineTemplateV2Service.deferNotifications(true);
      RoutineBlockV2Service.deferNotifications(true);
      RoutineTaskV2Service.deferNotifications(true);
      try {
        await RoutineMutationFacade.instance.addTemplateLocal(copied);

        final oldBlocks = RoutineDatabaseService.getBlocksForTemplate(routine.id);
        final oldTasks = RoutineDatabaseService.getTasksForTemplate(routine.id);
        final Map<String, String> blockIdMap = {};
        var blockSalt = 0;
        for (final b in oldBlocks) {
          blockSalt += 1;
          // 睡眠ブロックはコピー先でも正規ID（newTemplateId_sleep）にしておく。ensureSleepBlockForTemplate が二重で追加するのを防ぐ。
          final bool isSleepBlock = RoutineSleepBlockService.isSleepBlock(b) ||
              (b.blockName?.trim() == RoutineSleepBlockService.sleepBlockName);
          final newBlockId = isSleepBlock
              ? '$newTemplateId${RoutineSleepBlockService.sleepBlockIdSuffix}'
              : _generateBlockId(
                  newTemplateId,
                  now.add(Duration(microseconds: blockSalt)),
                );
          blockIdMap[b.id] = newBlockId;
          await RoutineMutationFacade.instance.addBlockLocal(
            b.copyWith(
              id: newBlockId,
              routineTemplateId: newTemplateId,
              createdAt: now,
              lastModified: now,
              userId: uid,
              cloudId: newBlockId,
              lastSynced: null,
              isDeleted: false,
              deviceId: deviceId,
              version: 1,
            ),
          );
        }

        var taskSalt = 0;
        for (final t in oldTasks) {
          final mappedBlockId = blockIdMap[t.routineBlockId];
          if (mappedBlockId == null) continue;
          taskSalt += 1;
          final newTaskId = _generateTaskId(
            now.add(Duration(microseconds: 1000 + taskSalt)),
          );
          await RoutineMutationFacade.instance.addTaskLocal(
            t.copyWith(
              id: newTaskId,
              routineTemplateId: newTemplateId,
              routineBlockId: mappedBlockId,
              createdAt: now,
              lastModified: now,
              userId: uid,
              cloudId: newTaskId,
              lastSynced: null,
              isDeleted: false,
              deviceId: deviceId,
              version: 1,
            ),
          );
        }
      } finally {
        RoutineTemplateV2Service.deferNotifications(false);
        RoutineBlockV2Service.deferNotifications(false);
        RoutineTaskV2Service.deferNotifications(false);
      }

      if (!mounted) return;
      setState(() => _isCopying = false);

      // Firebase 同期はバックグラウンドで実行（待たずにコピー完了とする）
      unawaited(
        RoutineMutationFacade.instance
            .syncTemplateWithBlocksAndTasksToFirebase(newTemplateId),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isCopying = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('コピーに失敗しました: $e')),
      );
    }
  }

  void _showAddRoutineDialog() {
    final titleController = TextEditingController();
    final memoController = TextEditingController();
    WorkType selectedWorkType = WorkType.free;
    Color selectedColor = Theme.of(context).colorScheme.primary;
    List<_DraftTimeBlock> blocks = [];
    String selectedApplyDayType = 'weekday'; // デフォルトで平日

    showImeSafeDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleController,
                  decoration: const InputDecoration(
                    labelText: 'ルーティン名',
                    hintText: '例: 朝ルーティン',
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: memoController,
                  decoration: const InputDecoration(
                    labelText: 'メモ',
                    hintText: 'ルーティンの説明を入力',
                  ),
                  maxLines: 2,
                ),
                const SizedBox(height: 16),
                // 適用日選択
                ListTile(
                  leading: const Icon(Icons.calendar_today),
                  title: const Text('適用日'),
                  subtitle: Text(_getApplyDayTypeText(selectedApplyDayType)),
                  trailing: const Icon(Icons.arrow_forward_ios),
                  onTap: () => _showApplyDayTypeSelectionDialog(
                    context,
                    selectedApplyDayType,
                    (applyDayType) => setDialogState(
                      () => selectedApplyDayType = applyDayType,
                    ),
                  ),
                ),
                // 勤務タイプ選択
                ListTile(
                  leading: const Icon(Icons.work),
                  title: const Text('勤務タイプ'),
                  subtitle: Text(_getWorkTypeText(selectedWorkType)),
                  trailing: const Icon(Icons.arrow_forward_ios),
                  onTap: () => _showWorkTypeSelectionDialog(
                    context,
                    selectedWorkType,
                    (workType) =>
                        setDialogState(() => selectedWorkType = workType),
                  ),
                ),
                // 色選択
                ListTile(
                  leading: const Icon(Icons.palette),
                  title: const Text('色'),
                  trailing: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: selectedColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  onTap: () => _showColorSelectionDialog(
                    context,
                    selectedColor,
                    (color) => setDialogState(() => selectedColor = color),
                  ),
                ),
                // タイムゾーン管理
                ListTile(
                  leading: const Icon(Icons.schedule),
                  title: const Text('タイムゾーン'),
                  subtitle: Text(
                    blocks.isEmpty
                        ? 'タイムゾーンを追加'
                        : '${blocks.length}個のタイムゾーン',
                  ),
                  trailing: const Icon(Icons.arrow_forward_ios),
                  onTap: () => _showTimeZoneListDialog(
                    context,
                    blocks,
                    (newBlocks) => setDialogState(() => blocks = newBlocks),
                  ),
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
                final title = titleController.text.trim();
                if (title.isEmpty) return;

                try {
                  final diagId =
                      'routine_create_${DateTime.now().toUtc().toIso8601String()}';
                  // 1) まずローカル保存（Hive）だけを確実に完了させ、UXを止めない
                  final nowUtc = DateTime.now().toUtc();
                  final templateId = _generateTemplateId(nowUtc);
                  final deviceId = await DeviceInfoService.getDeviceId();
                  final userId = AuthService.getCurrentUserId() ?? '';
                  final ver = await RoutineLamportClockService.next();

                  try {
                    print(
                      '🧩 ROUTINE_CREATE start diagId=$diagId templateId=$templateId userId=$userId deviceId=$deviceId title="$title" applyDayType=$selectedApplyDayType timeZoneCount=${blocks.length}',
                    );
                  } catch (_) {}

                  final tpl = RoutineTemplateV2(
                    id: templateId,
                    title: title,
                    memo: memoController.text,
                    workType: selectedWorkType,
                    color:
                        '#${selectedColor.value.toRadixString(16).padLeft(8, '0')}',
                    applyDayType: selectedApplyDayType,
                    isActive: true,
                    isDeleted: false,
                    version: ver,
                    deviceId: deviceId,
                    userId: userId,
                    createdAt: nowUtc,
                    lastModified: nowUtc,
                    isShortcut: false,
                  )..cloudId = templateId;

                  await RoutineTemplateV2Service.add(tpl);

                  // ブロック（タイムゾーン）もローカルへ作成（ネットワークは待たない）
                  final createdBlocks = <RoutineBlockV2>[];
                  for (int i = 0; i < blocks.length; i++) {
                    final b = blocks[i];
                    final blockId = _generateBlockId(
                      templateId,
                      nowUtc.add(Duration(microseconds: i + 1)),
                    );
                    final start = b.startTime;
                    final end = b.endTime;
                    int calcMinutes(TimeOfDay s, TimeOfDay e) {
                      final sm = s.hour * 60 + s.minute;
                      var em = e.hour * 60 + e.minute;
                      if (em <= sm) em += 24 * 60;
                      final diff = em - sm;
                      return diff > 0 ? diff : 30;
                    }

                    final bVer = await RoutineLamportClockService.next();
                    final block = RoutineBlockV2(
                      id: blockId,
                      routineTemplateId: templateId,
                      blockName: (b.name.isEmpty || b.name == '未分類')
                          ? null
                          : b.name,
                      startTime: start,
                      endTime: end,
                      workingMinutes: calcMinutes(start, end),
                      colorValue: null,
                      order: i,
                      location: null,
                      createdAt: nowUtc,
                      lastModified: nowUtc,
                      userId: userId,
                      cloudId: blockId,
                      isDeleted: false,
                      deviceId: deviceId,
                      version: bVer,
                    );
                    await RoutineBlockV2Service.add(block);
                    createdBlocks.add(block);
                  }

                  await RoutineSleepBlockService.ensureSleepBlockForTemplate(templateId);

                  // 2) 画面を先に進める（同期は裏で走らせる）
                  if (mounted) {
                    Navigator.pop(context);
                    setState(() {});
                  }
                  try {
                    await context.read<TaskProvider>().refreshTasks();
                  } catch (_) {
                    // refreshTasks失敗時は無視
                  }

                  // 3) Firestore送信（バックグラウンド、タイムアウト付き）
                  () async {
                    try {
                      await RoutineTemplateV2SyncService()
                          .uploadToFirebase(tpl)
                          .timeout(const Duration(seconds: 8));
                      await RoutineTemplateV2Service.update(tpl);
                    } catch (_) {
                      // アップロード失敗時はローカルのみで続行
                    }
                    for (final b in createdBlocks) {
                      try {
                        await RoutineBlockV2SyncService()
                            .uploadToFirebase(b)
                            .timeout(const Duration(seconds: 8));
                        await RoutineBlockV2Service.update(b);
                      } catch (_) {
                        // アップロード失敗時はローカルのみで続行
                      }
                    }
                    }();
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('ルーティンの追加に失敗しました: $e'),
                      backgroundColor: Theme.of(context).colorScheme.error,
                    ),
                  );
                }
              },
              child: const Text('追加'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteRoutine(RoutineTemplateV2 routine) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ルーティン削除'),
        content: Text('「${routine.title}」を削除しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      // template tombstone
      routine.isDeleted = true;
      routine.isActive = false;
      await _saveTemplateV2WithSync(routine);

      // blocks/tasks tombstone（復活・巻き戻り防止）
      final blocks = RoutineBlockV2Service.debugGetAllRaw()
          .where((b) => b.routineTemplateId == routine.id)
          .toList();
      for (final b in blocks) {
        await RoutineMutationFacade.instance.deleteBlock(b.id, routine.id);
      }
      if (mounted) {
        try {
          await context.read<TaskProvider>().refreshTasks();
        } catch (_) {}
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('削除に失敗しました: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() {});
    }
  }

  void _showWorkTypeSelectionDialog(
    BuildContext context,
    WorkType selectedWorkType,
    Function(WorkType) onChanged,
  ) {
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setStateDialog) {
          WorkType currentWorkType = selectedWorkType;
          return AlertDialog(
            title: const Text('勤務タイプを選択'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RadioListTile<WorkType>(
                  title: const Text('勤務'),
                  subtitle: const Text('仕事や業務の時間'),
                  value: WorkType.work,
                  groupValue: currentWorkType,
                  onChanged: (value) {
                    setStateDialog(() {
                      currentWorkType = value!;
                    });
                  },
                ),
                RadioListTile<WorkType>(
                  title: const Text('自由'),
                  subtitle: const Text('自由な時間'),
                  value: WorkType.free,
                  groupValue: currentWorkType,
                  onChanged: (value) {
                    setStateDialog(() {
                      currentWorkType = value!;
                    });
                  },
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('キャンセル'),
              ),
              ElevatedButton(
                onPressed: () {
                  onChanged(currentWorkType);
                  Navigator.pop(context);
                },
                child: const Text('OK'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showColorSelectionDialog(
    BuildContext context,
    Color selectedColor,
    Function(Color) onChanged,
  ) {
    const List<Color> colors = DomainColors.routineChoices;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('色を選択'),
        content: SizedBox(
          width: 300,
          child: GridView.builder(
            shrinkWrap: true,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 6,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            itemCount: colors.length,
            itemBuilder: (context, index) {
              final color = colors[index];
              return GestureDetector(
                onTap: () {
                  onChanged(color);
                  Navigator.pop(context);
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: selectedColor == color
                        ? Border.all(
                            color: AppColorTokens.of(context).selectionBorder,
                            width: 3,
                          )
                        : null,
                  ),
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('キャンセル'),
          ),
        ],
      ),
    );
  }

  void _showTimeZoneListDialog(
    BuildContext context,
    List<_DraftTimeBlock> blocks,
    Function(List<_DraftTimeBlock>) onChanged,
  ) {
    final tempBlocks = blocks
        .map(
          (b) => _DraftTimeBlock(
            id: b.id,
            name: b.name,
            startTime: b.startTime,
            endTime: b.endTime,
          ),
        )
        .toList();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('タイムゾーンを管理'),
        content: StatefulBuilder(
          builder: (context, setState) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 300,
                child: ListView.builder(
                  itemCount: tempBlocks.length,
                  itemBuilder: (context, index) {
                    final block = tempBlocks[index];
                    return Card(
                      child: ListTile(
                        title: Text(block.name),
                        subtitle: Text(block.timeRangeText),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit),
                              onPressed: () => _showEditTimeZoneDialog(
                                context,
                                block,
                                (editedBlock) {
                                  setState(() {
                                    tempBlocks[index] = editedBlock;
                                  });
                                },
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete),
                              onPressed: () {
                                setState(() {
                                  tempBlocks.removeAt(index);
                                });
                              },
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: ElevatedButton.icon(
                  onPressed: () =>
                      _showAddTimeZoneDialog(context, (newTimeZone) {
                        setState(() {
                          tempBlocks.add(newTimeZone);
                        });
                      }),
                  icon: const Icon(Icons.add),
                  label: const Text('タイムゾーンを追加'),
                ),
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
            onPressed: () {
              onChanged(tempBlocks);
              Navigator.pop(context);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  void _showAddTimeZoneDialog(
    BuildContext context,
    Function(_DraftTimeBlock) onAdded,
  ) {
    final nameController = TextEditingController();
    TimeOfDay startTime = const TimeOfDay(hour: 9, minute: 0);
    TimeOfDay endTime = const TimeOfDay(hour: 10, minute: 0);

    showImeSafeDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('タイムゾーンを追加'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'タイムゾーン名',
                  hintText: '例: 朝',
                ),
              ),
              const SizedBox(height: 16),
              ListTile(
                leading: const Icon(Icons.access_time),
                title: const Text('開始時刻'),
                subtitle: Text(
                  '${startTime.hour.toString().padLeft(2, '0')}:${startTime.minute.toString().padLeft(2, '0')}',
                ),
                trailing: const Icon(Icons.arrow_forward_ios),
                onTap: () async {
                  final time = await showTimePicker(
                    context: context,
                    initialTime: startTime,
                  );
                  if (time != null) {
                    setState(() => startTime = time);
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.access_time),
                title: const Text('終了時刻'),
                subtitle: Text(
                  '${endTime.hour.toString().padLeft(2, '0')}:${endTime.minute.toString().padLeft(2, '0')}',
                ),
                trailing: const Icon(Icons.arrow_forward_ios),
                onTap: () async {
                  final time = await showTimePicker(
                    context: context,
                    initialTime: endTime,
                  );
                  if (time != null) {
                    setState(() => endTime = time);
                  }
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル'),
            ),
            TextButton(
              onPressed: () {
                if (nameController.text.isNotEmpty) {
                  final block = _DraftTimeBlock(
                    id: DateTime.now().millisecondsSinceEpoch.toString(),
                    name: nameController.text,
                    startTime: startTime,
                    endTime: endTime,
                  );
                  onAdded(block);
                  Navigator.pop(context);
                }
              },
              child: const Text('追加'),
            ),
          ],
        ),
      ),
    );
  }

  void _showEditTimeZoneDialog(
    BuildContext context,
    _DraftTimeBlock block,
    Function(_DraftTimeBlock) onEdited,
  ) {
    final nameController = TextEditingController(text: block.name);
    TimeOfDay startTime = block.startTime;
    TimeOfDay endTime = block.endTime;

    showImeSafeDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('タイムゾーンを編集'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: 'タイムゾーン名'),
              ),
              const SizedBox(height: 16),
              ListTile(
                leading: const Icon(Icons.access_time),
                title: const Text('開始時刻'),
                subtitle: Text(
                  '${startTime.hour.toString().padLeft(2, '0')}:${startTime.minute.toString().padLeft(2, '0')}',
                ),
                trailing: const Icon(Icons.arrow_forward_ios),
                onTap: () async {
                  final time = await showTimePicker(
                    context: context,
                    initialTime: startTime,
                  );
                  if (time != null) {
                    setState(() => startTime = time);
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.access_time),
                title: const Text('終了時刻'),
                subtitle: Text(
                  '${endTime.hour.toString().padLeft(2, '0')}:${endTime.minute.toString().padLeft(2, '0')}',
                ),
                trailing: const Icon(Icons.arrow_forward_ios),
                onTap: () async {
                  final time = await showTimePicker(
                    context: context,
                    initialTime: endTime,
                  );
                  if (time != null) {
                    setState(() => endTime = time);
                  }
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル'),
            ),
            TextButton(
              onPressed: () {
                if (nameController.text.isNotEmpty) {
                  final edited = _DraftTimeBlock(
                    id: block.id,
                    name: nameController.text,
                    startTime: startTime,
                    endTime: endTime,
                  );
                  onEdited(edited);
                  Navigator.pop(context);
                }
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }


  String _getWorkTypeText(WorkType workType) {
    switch (workType) {
      case WorkType.work:
        return '勤務';
      case WorkType.free:
        return '自由';
    }
  }

  String _getApplyDayTypeText(String applyDayType) {
    switch (applyDayType) {
      case 'weekday':
        return '平日（カレンダー設定を参照）';
      case 'holiday':
        return '休日（カレンダー設定を参照）';
      case 'both':
        return '平日・休日';
      default:
        if (applyDayType.startsWith('dow:')) {
          final part = applyDayType.substring(4);
          final days = part
              .split(',')
              .where((e) => e.isNotEmpty)
              .map((e) => int.tryParse(e) ?? 0)
              .toList();
          final labels = ['月', '火', '水', '木', '金', '土', '日'];
          final text = days
              .where((d) => d >= 1 && d <= 7)
              .map((d) => labels[d - 1])
              .join('・');
          return text.isEmpty ? '曜日指定' : '曜日指定（$text）';
        }
        return '平日（カレンダー設定を参照）';
    }
  }

  void _showApplyDayTypeSelectionDialog(
    BuildContext context,
    String currentApplyDayType,
    Function(String) onApplyDayTypeSelected,
  ) {
    final selectedDows = <int>{};
    if (currentApplyDayType.startsWith('dow:')) {
      final part = currentApplyDayType.substring(4);
      for (final s in part.split(',')) {
        final v = int.tryParse(s);
        if (v != null && v >= 1 && v <= 7) selectedDows.add(v);
      }
    }
    // ダイアログ内の選択を保持し、タップでラジオが切り替わるようにする
    String currentSelection = currentApplyDayType;
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('適用日を選択'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RadioListTile<String>(
                  title: const Text('平日'),
                  subtitle: const Text('カレンダー設定の平日を参照（土日祝日以外）'),
                  value: 'weekday',
                  groupValue: currentSelection.startsWith('dow:')
                      ? 'dow'
                      : currentSelection,
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() => currentSelection = value);
                    onApplyDayTypeSelected(value);
                    Navigator.pop(context);
                  },
                ),
                RadioListTile<String>(
                  title: const Text('休日'),
                  subtitle: const Text('カレンダー設定の休日を参照（土日祝日）'),
                  value: 'holiday',
                  groupValue: currentSelection.startsWith('dow:')
                      ? 'dow'
                      : currentSelection,
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() => currentSelection = value);
                    onApplyDayTypeSelected(value);
                    Navigator.pop(context);
                  },
                ),
                RadioListTile<String>(
                  title: const Text('平日・休日'),
                  subtitle: const Text('毎日'),
                  value: 'both',
                  groupValue: currentSelection.startsWith('dow:')
                      ? 'dow'
                      : currentSelection,
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() => currentSelection = value);
                    onApplyDayTypeSelected(value);
                    Navigator.pop(context);
                  },
                ),
                const Divider(),
                RadioListTile<String>(
                  title: const Text('曜日指定'),
                  value: 'dow',
                  groupValue: currentSelection.startsWith('dow:')
                      ? 'dow'
                      : currentSelection,
                  onChanged: (value) {
                    setState(() => currentSelection = 'dow');
                  },
                ),
                if (true) ...[
                  // 1..7: 月(1)〜日(7)
                  for (int d = 1; d <= 7; d++)
                    CheckboxListTile(
                      title: Text(['月', '火', '水', '木', '金', '土', '日'][d - 1]),
                      value: selectedDows.contains(d),
                      onChanged: (val) {
                        setState(() {
                          if (val == true) {
                            selectedDows.add(d);
                          } else {
                            selectedDows.remove(d);
                          }
                        });
                      },
                    ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル'),
            ),
            ElevatedButton(
              onPressed: () {
                if (currentSelection == 'weekday' ||
                    currentSelection == 'holiday' ||
                    currentSelection == 'both') {
                  Navigator.pop(context);
                  return;
                }
                final sorted = selectedDows.toList()..sort();
                final result = 'dow:${sorted.join(',')}';
                onApplyDayTypeSelected(result);
                Navigator.pop(context);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }


  void _showEditRoutineTitleDialog(RoutineTemplateV2 routine) {
    final titleController = TextEditingController(text: routine.title);
    showImeSafeDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('ルーティン名を編集'),
        content: TextField(
          controller: titleController,
          decoration: const InputDecoration(
            labelText: 'ルーティン名',
            hintText: '例: 朝ルーティン',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () async {
              if (titleController.text.isNotEmpty) {
                routine.title = titleController.text;
                await _saveTemplateV2WithSync(routine);
                if (!mounted) return;
                Navigator.pop(context);
                setState(() {});
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
}
