import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/task_provider.dart';
import 'shortcut_template_screen.dart';
import '../widgets/timeline/add_task_dialog.dart';
import '../services/project_service.dart';
import '../services/actual_task_sync_service.dart';
import '../services/auth_service.dart';
import '../services/device_info_service.dart';
import '../services/routine_block_v2_service.dart';
import '../services/routine_block_v2_sync_service.dart';
import '../services/routine_lamport_clock_service.dart';
import '../services/routine_task_v2_service.dart';
import '../services/routine_template_v2_service.dart';
import '../services/routine_template_v2_sync_service.dart';
import '../services/routine_task_v2_sync_service.dart';
import '../services/routine_v2_backfill_service.dart';
import '../models/routine_block_v2.dart';
import '../models/routine_task_v2.dart' as v2task;
import '../models/work_type.dart';
import '../models/routine_template_v2.dart';
import '../utils/ime_safe_dialog.dart';
import '../app/theme/domain_colors.dart';

/// タイムライン画面のタスク追加ダイアログを、新旧問わず利用できるよう
/// グローバル関数として提供する。
Future<void> showTimelineAddTaskDialog(
  BuildContext context,
  DateTime selectedDate,
) async {
  final taskProvider = Provider.of<TaskProvider>(context, listen: false);
  await showImeSafeDialog(
    context: context,
    barrierDismissible: false,
    builder: (context) => AddTaskDialog(
      selectedDate: selectedDate,
      taskProvider: taskProvider,
    ),
  );
}

/// タイムラインのショートカット選択ダイアログ（トップレベル）
Future<void> showTimelineShortcutDialog(BuildContext context) async {
  const String shortcutTemplateId = 'shortcut';
  const String shortcutBlockId = 'v2blk_shortcut_0';

  // V2へ統一。cutover前でも、ショートカットはV2へ収束させる。
  RoutineTemplateV2? tpl = RoutineTemplateV2Service.getById(shortcutTemplateId);
  RoutineBlockV2? block = RoutineBlockV2Service.getById(shortcutBlockId);

  if (tpl == null || block == null) {
    final deviceId = await DeviceInfoService.getDeviceId();
    final uid = AuthService.getCurrentUserId() ?? '';
    final now = DateTime.now().toUtc();

    if (tpl == null) {
      final ver = await RoutineLamportClockService.next();
      tpl = RoutineTemplateV2(
        id: shortcutTemplateId,
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
      )..cloudId = shortcutTemplateId;
      await RoutineTemplateV2Service.add(tpl);
      try {
        await RoutineTemplateV2SyncService().uploadToFirebase(tpl);
        await RoutineTemplateV2Service.update(tpl);
      } catch (e, st) {
        try {
          print('⚠️ Shortcut V2 template upload failed: $e');
          print(st);
        } catch (_) {}
      }
    }

    if (block == null) {
      final ver = await RoutineLamportClockService.next();
      block = RoutineBlockV2(
        id: shortcutBlockId,
        routineTemplateId: shortcutTemplateId,
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
        cloudId: shortcutBlockId,
        lastSynced: null,
        isDeleted: false,
        deviceId: deviceId,
        version: ver,
      );
      await RoutineBlockV2Service.add(block);
      try {
        await RoutineBlockV2SyncService().uploadToFirebase(block);
        await RoutineBlockV2Service.update(block);
      } catch (e, st) {
        try {
          print('⚠️ Shortcut V2 block upload failed: $e');
          print(st);
        } catch (_) {}
      }
    }
  }

  // Self-heal: if shortcut tasks were left under legacy IDs, backfill/normalize
  // them so the timeline shortcut picker can display them.
  try {
    await RoutineV2BackfillService.ensureShortcutBundleBackfilledIfEmpty();
  } catch (_) {}

  List<v2task.RoutineTaskV2> loadShortcutTasks() {
    // Read from V2 block (includes userId filtering), then ensure templateId matches.
    return RoutineTaskV2Service.getByBlock(shortcutBlockId)
        .where((t) => t.routineTemplateId == shortcutTemplateId && !t.isDeleted)
        .toList()
      ..sort((a, b) => a.order.compareTo(b.order));
  }

  // If empty, try pulling V2 from Firestore once (V2 is the source of truth).
  // NOTE: ダイアログ自体はHive更新に追従して常に最新のHiveスナップショットを描画する。
  final initialTasks = loadShortcutTasks();
  if (initialTasks.isEmpty) {
    try {
      // read削減（計画書P1-2 / P0-5）:
      // ショートカット用は「テンプレ単位pull」を第一級にし、全件GET/forceFullSync は手動復旧に限定する。
      await RoutineTemplateV2SyncService()
          .syncById(shortcutTemplateId)
          .timeout(const Duration(seconds: 8));
    } catch (_) {}
    try {
      await RoutineBlockV2SyncService()
          .syncForTemplate(shortcutTemplateId)
          .timeout(const Duration(seconds: 8));
    } catch (_) {}
    try {
      await RoutineTaskV2SyncService()
          .syncForTemplate(shortcutTemplateId)
          .timeout(const Duration(seconds: 8));
    } catch (_) {}
    // Re-run self-heal after pull (may populate canonical IDs).
    try {
      await RoutineV2BackfillService.ensureShortcutBundleBackfilledIfEmpty();
    } catch (_) {}
  }

  await showDialog(
    context: context,
    builder: (ctx) => StreamBuilder<void>(
      stream: RoutineTaskV2Service.updateStream,
      builder: (ctx, _) {
        final tasks = loadShortcutTasks();
        return AlertDialog(
          title: Row(
            children: [
              // 画面幅が狭い端末でもタイトル文言を省略せず表示するため、
              // FittedBox で必要に応じて縮小して収める。
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'ショートカット実行',
                    maxLines: 1,
                    softWrap: false,
                  ),
                ),
              ),
              IconButton(
                tooltip: '編集',
                icon: const Icon(Icons.edit),
                onPressed: () {
                  final template = tpl;
                  if (template == null) return;
                  Navigator.pop(ctx);
                  // pop 完了後に編集画面を開く（同フレームで push すると表示されないため）
                  // 表が正しくレイアウトされるよう、Dialog ではなく通常ルートで全画面表示する
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!context.mounted) return;
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => ShortcutTemplateScreen(
                          routine: template,
                        ),
                        fullscreenDialog: true,
                      ),
                    );
                  });
                },
              ),
            ],
          ),
          content: SizedBox(
            width: 400,
            child: tasks.isEmpty
                ? const Text('ショートカットがありません')
                : ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 420),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: tasks.length,
                      itemBuilder: (ctx, i) {
                        final t = tasks[i];
                        final project = t.projectId != null
                            ? ProjectService.getProjectById(t.projectId!)
                            : null;
                        final taskLabel =
                            t.name.trim().isNotEmpty ? t.name.trim() : '名称未設定';
                        final projectLabel = project?.name ?? '未指定';
                        return Card(
                          margin: const EdgeInsets.symmetric(vertical: 6),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: () async {
                              Navigator.pop(ctx);
                              await ActualTaskSyncService().startFromShortcut(
                                title: t.name,
                                projectId: t.projectId,
                                subProjectId: t.subProjectId,
                                subProject: t.subProject,
                                memo: t.memo,
                                modeId: t.modeId,
                                blockName: t.blockName,
                              );
                              final provider = Provider.of<TaskProvider>(
                                context,
                                listen: false,
                              );
                              await provider.refreshTasks();
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          taskLabel,
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
                                                projectLabel,
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
                                    ),
                                  ),
                                  Icon(
                                    Icons.play_arrow,
                                    color: Theme.of(context).colorScheme.primary,
                                    size: 24,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('閉じる'),
            ),
          ],
        );
      },
    ),
  );
}
