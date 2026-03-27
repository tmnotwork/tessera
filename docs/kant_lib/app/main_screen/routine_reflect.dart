import 'package:flutter/material.dart';

import '../../models/routine_template_v2.dart';
import '../../services/calendar_service.dart';
import '../../services/block_sync_service.dart';
import '../../services/block_routine_manager.dart';
import '../../services/block_service.dart';
import '../../models/block.dart';
import '../../models/routine_block_v2.dart' as rbv2;
import '../../models/routine_task_v2.dart' as rtv2;
import '../../services/auth_service.dart';
import '../../services/routine_block_v2_service.dart';
import '../../services/routine_database_service.dart';
import '../../services/routine_task_v2_service.dart';
import '../../repositories/routine_editor_repository.dart';
import '../../services/app_settings_service.dart';
import '../../services/block_crud_operations.dart';
import '../../services/network_manager.dart';

class RoutineReflectUI {
  static String? _combineMemo(String? memo, String? details) {
    final m = memo?.trim();
    final d = details?.trim();
    final parts = <String>[];
    if (m != null && m.isNotEmpty) parts.add(m);
    if (d != null && d.isNotEmpty) parts.add(d);
    if (parts.isEmpty) return null;
    return parts.join('\n');
  }

  static Future<void> showConfirmAndReflect(
    BuildContext context,
    RoutineTemplateV2 routine,
  ) async {
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ルーティンを反映しますか？'),
        content: Text('「${routine.title}」の反映を実行します。開始日を選択後に1週間分を作成します。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              await reflectDirect(context, routine);
            },
            child: const Text('確認'),
          ),
        ],
      ),
    );
  }

  static Future<void> reflectDirect(
      BuildContext context, RoutineTemplateV2 routine) async {
    final stopwatch = Stopwatch()..start();
    try {
      final String _runId = DateTime.now().millisecondsSinceEpoch.toString();
      try {
        print('🧭 [REFLECT][RUN=$_runId] reflectDirect start templateId=${routine.id} title="${routine.title}"');
      } catch (_) {}
      final today = DateTime.now();
      final today0 = DateTime(today.year, today.month, today.day);
      final chosenStart = await showDatePicker(
        context: context,
        initialDate: today0,
        firstDate: today0,
        lastDate: DateTime(today.year + 2, 12, 31),
      );
      if (chosenStart == null) return;
      try {
        print('🧭 [REFLECT][RUN=$_runId] chosenStart=${chosenStart.toIso8601String().substring(0, 10)}');
      } catch (_) {}

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => const AlertDialog(
          content: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 3)),
              SizedBox(width: 16),
              Expanded(child: Text('ルーティン反映中...')),
            ],
          ),
        ),
      );

      // 今回反映する実日付を確定（休日情報は1回だけ取得して再利用）
      final List<DateTime> datesToReflect = [];
      final Map<String, bool> holidayByDateKey = {};
      final start0 =
          DateTime(chosenStart.year, chosenStart.month, chosenStart.day);
      // 1週間 = 開始日を含む 7 日分（従来は +7 日かつループが +1 日で 8 日になっていた）
      final weekLastDay = start0.add(const Duration(days: 6));
      final t0Holiday = stopwatch.elapsedMilliseconds;
      // 1回のFirestoreクエリで全日分のカレンダーエントリを取得してキャッシュ
      await CalendarService.getCalendarEntriesForPeriod(start0, weekLastDay);
      for (DateTime d = start0;
          !d.isAfter(weekLastDay);
          d = d.add(const Duration(days: 1))) {
        final isHoliday = CalendarService.isHolidayCached(d);
        final key = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
        holidayByDateKey[key] = isHoliday;
        bool apply = switch (routine.applyDayType) {
          'weekday' => !isHoliday,
          'holiday' => isHoliday,
          _ => true,
        };
        if (apply) datesToReflect.add(DateTime(d.year, d.month, d.day));
      }
      try {
        print('🧭 [REFLECT][RUN=$_runId] holidayCheck done datesToReflect=${datesToReflect.length} elapsedMs=${stopwatch.elapsedMilliseconds - t0Holiday}');
      } catch (_) {}

      // バッチ削除（1件ずつではなく一括）
      final normalizedDates = datesToReflect
          .map((d) => Block.normalizeExecutionDateToUtcMidnight(d))
          .toList();
      final t0Delete = stopwatch.elapsedMilliseconds;
      await BlockSyncService()
          .deleteRoutineBlocksByDatesWithSyncBatch(normalizedDates);
      try {
        print('🧭 [REFLECT][RUN=$_runId] deleteBatch done elapsedMs=${stopwatch.elapsedMilliseconds - t0Delete}');
      } catch (_) {}

      final startDate =
          DateTime(chosenStart.year, chosenStart.month, chosenStart.day);
      final reflectLastDay = startDate.add(const Duration(days: 6));
      final t0Bootstrap = stopwatch.elapsedMilliseconds;
      final v2Bundles =
          await _prepareV2Bundles(routine, logPrefix: '[RUN=$_runId]');
      try {
        print('🧭 [REFLECT][RUN=$_runId] bootstrap+bundles done blocks=${v2Bundles.length} elapsedMs=${stopwatch.elapsedMilliseconds - t0Bootstrap}');
      } catch (_) {}
      if (v2Bundles.isEmpty) {
        if (context.mounted) {
          Navigator.of(context, rootNavigator: true).pop();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('ルーティンタスクがありません')),
          );
        }
        return;
      }
      final totalTasks =
          v2Bundles.fold<int>(0, (sum, bundle) => sum + bundle.tasks.length);
      try {
        print('🧭 [REFLECT][RUN=$_runId] V2 ready: blocks=${v2Bundles.length} tasks=$totalTasks');
      } catch (_) {}

      int created = 0;
      int failed = 0;
      if (NetworkManager.isOnline) {
        // オンライン: 全 payload をメモリ上で組み立て → 一括ローカル保存 → Firebase バッチアップロード
        final List<Block> blocksToUpload = [];
        for (DateTime date = startDate;
            !date.isAfter(reflectLastDay);
            date = date.add(const Duration(days: 1))) {
          final key = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
          final isHoliday = holidayByDateKey[key] ?? false;
          bool shouldApply = switch (routine.applyDayType) {
            'weekday' => !isHoliday,
            'holiday' => isHoliday,
            _ => true,
          };
          if (!shouldApply) {
            print('🧭 [REFLECT][RUN=$_runId] SKIP date=$key applyDayType=${routine.applyDayType} isHoliday=$isHoliday');
            continue;
          }

          final payloads = _generateV2PayloadsForDate(date, v2Bundles, routine);
          print('🧭 [REFLECT][RUN=$_runId] date=$key payloads=${payloads.length}');
          for (final payload in payloads) {
            try {
              final durationMinutes =
                  payload.end.difference(payload.start).inMinutes;
              final combinedMemo = _combineMemo(payload.memo, payload.details);
              final block = await BlockCRUDOperations.createBlockLocalOnly(
                title: payload.name,
                creationMethod: TaskCreationMethod.routine,
                executionDate: Block.normalizeExecutionDateToUtcMidnight(date),
                startHour: payload.start.hour,
                startMinute: payload.start.minute,
                estimatedDuration: durationMinutes,
                workingMinutes: payload.workingMinutes ?? durationMinutes,
                memo: combinedMemo,
                projectId: payload.projectId,
                subProjectId: payload.subProjectId,
                subProject: payload.subProject,
                modeId: payload.modeId,
                blockName: payload.blockName,
                location: payload.location,
                taskId: payload.taskId,
                excludeFromReport: payload.excludeFromReport,
                isEvent: payload.isEvent,
                saveLocally: false,
              );
              // ループ内で一括作成すると createBlockLocalOnly の id が同一になり Hive で上書きされるため、一意 id を付与
              block.id = 'block_${_runId}_${blocksToUpload.length}_${payload.start.hour}_${payload.start.minute}';
              blocksToUpload.add(block);
            } catch (e, st) {
              print('🔴 [REFLECT][RUN=$_runId] createBlockLocalOnly FAILED: $e\n$st');
              failed++;
            }
          }
        }
        print('🧭 [REFLECT][RUN=$_runId] blocksToUpload=${blocksToUpload.length} failed=$failed');
        // 全ブロックを1回のflushでローカル保存（通知も1回）
        if (blocksToUpload.isNotEmpty) {
          await BlockService.batchPutBlocks(toAdd: blocksToUpload, toUpdate: []);
          print('🧭 [REFLECT][RUN=$_runId] batchPutBlocks done count=${blocksToUpload.length}');
        }
        final t0Upload = stopwatch.elapsedMilliseconds;
        if (blocksToUpload.isNotEmpty) {
          try {
            await BlockSyncService().uploadRoutineBlocksToFirebaseBatch(blocksToUpload);
            print('🧭 [REFLECT][RUN=$_runId] uploadBatch done count=${blocksToUpload.length}');
          } catch (e) {
            print('🔴 [REFLECT][RUN=$_runId] uploadBatch FAILED: $e');
          }
          created = blocksToUpload.length;
        }
        try {
          print('🧭 [REFLECT][RUN=$_runId] createLocal+uploadBatch done created=$created failed=$failed elapsedMs=${stopwatch.elapsedMilliseconds - t0Upload}');
        } catch (_) {}
      } else {
        // オフライン: 1件ずつ作成（Outboxに積む）。60ms遅延は廃止。
        for (DateTime date = startDate;
            !date.isAfter(reflectLastDay);
            date = date.add(const Duration(days: 1))) {
          final key = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
          final isHoliday = holidayByDateKey[key] ?? false;
          bool shouldApply = switch (routine.applyDayType) {
            'weekday' => !isHoliday,
            'holiday' => isHoliday,
            _ => true,
          };
          if (!shouldApply) continue;

          final payloads = _generateV2PayloadsForDate(date, v2Bundles, routine);
          for (final payload in payloads) {
            try {
              final durationMinutes =
                  payload.end.difference(payload.start).inMinutes;
              final combinedMemo = _combineMemo(payload.memo, payload.details);
              await BlockSyncService().createBlockWithSync(
                title: payload.name,
                creationMethod: TaskCreationMethod.routine,
                executionDate: Block.normalizeExecutionDateToUtcMidnight(date),
                startHour: payload.start.hour,
                startMinute: payload.start.minute,
                estimatedDuration: durationMinutes,
                workingMinutes: payload.workingMinutes ?? durationMinutes,
                memo: combinedMemo,
                projectId: payload.projectId,
                subProjectId: payload.subProjectId,
                subProject: payload.subProject,
                modeId: payload.modeId,
                blockName: payload.blockName,
                location: payload.location,
                taskId: payload.taskId,
                excludeFromReport: payload.excludeFromReport,
                isEvent: payload.isEvent,
              );
              created++;
            } catch (_) {
              failed++;
            }
          }
        }
        try {
          print('🧭 [REFLECT][RUN=$_runId] createWithSync(offline) done created=$created failed=$failed');
        } catch (_) {}
      }

      try {
        print('🧭 [REFLECT][RUN=$_runId] reflectDirect totalElapsedMs=${stopwatch.elapsedMilliseconds} created=$created failed=$failed');
      } catch (_) {}

      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(failed == 0
                  ? 'ルーティンを反映しました（$created 件作成）'
                  : 'ルーティンを部分的に反映しました（$created 件作成、$failed 件失敗）')),
        );
      }
    } catch (e) {
      try {
        print('🧭 [REFLECT] reflectDirect error after ${stopwatch.elapsedMilliseconds}ms: $e');
      } catch (_) {}
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('反映に失敗しました: $e')),
        );
      }
    }
  }

  static Future<void> showPickDatesAndReflect(
    BuildContext context,
    RoutineTemplateV2 routine,
  ) async {
    final Set<DateTime> selected = {};
    DateTime today0 =
        DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);
    final List<DateTime> next30 =
        List.generate(30, (i) => today0.add(Duration(days: i)));
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('反映する日付を選択'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: 280,
                  child: ListView.builder(
                    itemCount: next30.length,
                    itemBuilder: (c, i) {
                      final d = next30[i];
                      final label =
                          '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';
                      final checked = selected.contains(d);
                      return CheckboxListTile(
                        value: checked,
                        onChanged: (v) {
                          setState(() {
                            if (v == true) {
                              selected.add(d);
                            } else {
                              selected.remove(d);
                            }
                          });
                        },
                        dense: true,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text(label),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.date_range),
                    label: const Text('日付を追加'),
                    onPressed: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: today0,
                        firstDate: DateTime(today0.year - 1, 1, 1),
                        lastDate: DateTime(today0.year + 2, 12, 31),
                      );
                      if (picked != null) {
                        final d0 =
                            DateTime(picked.year, picked.month, picked.day);
                        setState(() => selected.add(d0));
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('キャンセル')),
            ElevatedButton(
              onPressed: selected.isEmpty
                  ? null
                  : () async {
                      Navigator.pop(ctx);
                      await reflectForSpecificDates(
                          context, routine, selected.toList());
                    },
              child: const Text('反映'),
            ),
          ],
        ),
      ),
    );
  }

  static Future<void> reflectForSpecificDates(
    BuildContext context,
    RoutineTemplateV2 routine,
    List<DateTime> dates,
  ) async {
    try {
      final String _runId = DateTime.now().millisecondsSinceEpoch.toString();
      try {
        final labels = dates.map((d) {
          final d0 = DateTime(d.year, d.month, d.day);
          return d0.year.toString().padLeft(4, '0') +
              '-' +
              d0.month.toString().padLeft(2, '0') +
              '-' +
              d0.day.toString().padLeft(2, '0');
        }).join(',');
        print('🧭 [REFLECT][RUN=' +
            _runId +
            '] reflectForSpecificDates start templateId=' +
            routine.id +
            ' title="' +
            routine.title +
            '" dates=[' +
            labels +
            ']');
      } catch (_) {}
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => const AlertDialog(
          content: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 3)),
              SizedBox(width: 16),
              Expanded(child: Text('ルーティン反映中...')),
            ],
          ),
        ),
      );

      // 先に対象日を正規化（UTCの深夜として統一）
      final List<DateTime> normalizedDates = dates
          .map((d) => Block.normalizeExecutionDateToUtcMidnight(d))
          .toList();
      // 対象日の routine 由来をバッチ削除（指定日反映の高速化）
      await BlockSyncService()
          .deleteRoutineBlocksByDatesWithSyncBatch(normalizedDates);

      final v2Bundles =
          await _prepareV2Bundles(routine, logPrefix: '[RUN=$_runId][SPEC]');
      if (v2Bundles.isEmpty) {
        if (context.mounted) {
          Navigator.of(context, rootNavigator: true).pop();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('ルーティンタスクがありません')),
          );
        }
        return;
      }
      final totalTasks =
          v2Bundles.fold<int>(0, (sum, bundle) => sum + bundle.tasks.length);
      try {
        print(
            '🧭 [REFLECT][RUN=${_runId}][SPEC] V2 ready: blocks=${v2Bundles.length} tasks=$totalTasks');
      } catch (_) {}
      int created = 0;
      int failed = 0;

      print('🧭 [REFLECT][RUN=$_runId][SPEC] isOnline=${NetworkManager.isOnline} normalizedDates=${normalizedDates.length} v2Bundles=${v2Bundles.length}');
      if (NetworkManager.isOnline) {
        // オンライン時: 全 payload をメモリ上で組み立て → 一括ローカル保存 → Firebase バッチアップロード
        final List<Block> blocksToUpload = [];
        for (final date in normalizedDates) {
          final dateLabel = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
          final payloads = _generateV2PayloadsForDate(date, v2Bundles, routine);
          print('🧭 [REFLECT][RUN=$_runId][SPEC] date=$dateLabel payloads=${payloads.length}');
          for (final payload in payloads) {
            try {
              final durationMinutes =
                  payload.end.difference(payload.start).inMinutes;
              final combinedMemo = _combineMemo(payload.memo, payload.details);
              final block = await BlockCRUDOperations.createBlockLocalOnly(
                title: payload.name,
                creationMethod: TaskCreationMethod.routine,
                executionDate: Block.normalizeExecutionDateToUtcMidnight(date),
                startHour: payload.start.hour,
                startMinute: payload.start.minute,
                estimatedDuration: durationMinutes,
                workingMinutes: payload.workingMinutes ?? durationMinutes,
                memo: combinedMemo,
                projectId: payload.projectId,
                subProjectId: payload.subProjectId,
                subProject: payload.subProject,
                modeId: payload.modeId,
                blockName: payload.blockName,
                location: payload.location,
                taskId: payload.taskId,
                excludeFromReport: payload.excludeFromReport,
                isEvent: payload.isEvent,
                saveLocally: false,
              );
              // ループ内で一括作成すると createBlockLocalOnly の id が同一になり Hive で上書きされるため、一意 id を付与
              block.id = 'block_${_runId}_${blocksToUpload.length}_${payload.start.hour}_${payload.start.minute}';
              blocksToUpload.add(block);
            } catch (e, st) {
              print('🔴 [REFLECT][RUN=$_runId][SPEC] createBlockLocalOnly FAILED: $e\n$st');
              failed++;
            }
          }
        }
        print('🧭 [REFLECT][RUN=$_runId][SPEC] blocksToUpload=${blocksToUpload.length} failed=$failed');
        // 全ブロックを1回のflushでローカル保存（通知も1回）
        if (blocksToUpload.isNotEmpty) {
          await BlockService.batchPutBlocks(toAdd: blocksToUpload, toUpdate: []);
          print('🧭 [REFLECT][RUN=$_runId][SPEC] batchPutBlocks done count=${blocksToUpload.length}');
        }
        if (blocksToUpload.isNotEmpty) {
          try {
            await BlockSyncService().uploadRoutineBlocksToFirebaseBatch(blocksToUpload);
            print('🧭 [REFLECT][RUN=$_runId][SPEC] uploadBatch done count=${blocksToUpload.length}');
          } catch (e) {
            print('🔴 [REFLECT][RUN=$_runId][SPEC] uploadBatch FAILED: $e');
          }
          created = blocksToUpload.length;
        }
      } else {
        // オフライン時: 1件ずつ作成（Outbox に積む）
        for (final date in normalizedDates) {
          final payloads = _generateV2PayloadsForDate(date, v2Bundles, routine);
          for (final payload in payloads) {
            try {
              final durationMinutes =
                  payload.end.difference(payload.start).inMinutes;
              final combinedMemo = _combineMemo(payload.memo, payload.details);
              await BlockSyncService().createBlockWithSync(
                title: payload.name,
                creationMethod: TaskCreationMethod.routine,
                executionDate: Block.normalizeExecutionDateToUtcMidnight(date),
                startHour: payload.start.hour,
                startMinute: payload.start.minute,
                estimatedDuration: durationMinutes,
                workingMinutes: payload.workingMinutes ?? durationMinutes,
                memo: combinedMemo,
                projectId: payload.projectId,
                subProjectId: payload.subProjectId,
                subProject: payload.subProject,
                modeId: payload.modeId,
                blockName: payload.blockName,
                location: payload.location,
                taskId: payload.taskId,
                excludeFromReport: payload.excludeFromReport,
                isEvent: payload.isEvent,
              );
              created++;
            } catch (_) {
              failed++;
            }
          }
        }
      }

      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(failed == 0
                  ? 'ルーティンを反映しました（$created 件作成）'
                  : 'ルーティンを部分的に反映しました（$created 件作成、$failed 件失敗）')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('反映に失敗しました: $e')),
        );
      }
    }
  }

  static Future<List<_V2BlockBundle>> _prepareV2Bundles(
    RoutineTemplateV2 routine, {
    String logPrefix = '',
  }) async {
    final prefix = logPrefix.isEmpty ? '' : '$logPrefix ';
    try {
      print('🧭 [REFLECT]${prefix}prepareV2 start template=${routine.id}');
    } catch (_) {}
    // V2を正として bootstrap（必要なら移行期間の自己回復も含む）
    try {
      await RoutineEditorRepository.instance.bootstrapTemplateV2(
        routine,
        maxAttempts: 2,
        retryDelay: const Duration(milliseconds: 250),
      );
    } catch (_) {}
    final blocks = RoutineDatabaseService.getBlocksForTemplate(routine.id);
    final filteredTemplateTasks =
        RoutineTaskV2Service.getByTemplate(routine.id);
    final rawBlocks = RoutineBlockV2Service.debugGetAllRaw()
        .where(
          (b) => !b.isDeleted && b.routineTemplateId == routine.id,
        )
        .toList();
    final rawTemplateTasks = RoutineTaskV2Service.debugGetAllRaw()
        .where(
          (t) => !t.isDeleted && t.routineTemplateId == routine.id,
        )
        .toList();
    final currentUid = AuthService.getCurrentUserId();
    try {
      final rawSample = rawTemplateTasks
          .take(5)
          .map(
            (t) =>
                '${t.id}(blk=${t.routineBlockId},uid=${t.userId},order=${t.order})',
          )
          .join(', ');
      print(
        '🧭 [REFLECT]${prefix}V2 diagnostics blocksFiltered=${blocks.length} blocksRaw=${rawBlocks.length} tasksFiltered=${filteredTemplateTasks.length} tasksRaw=${rawTemplateTasks.length} currentUid=${currentUid ?? '(null)'} templateUserId=${routine.userId}',
      );
      if (rawTemplateTasks.isNotEmpty) {
        print('🧭 [REFLECT]${prefix}V2 raw task sample: $rawSample');
      }
    } catch (_) {}
    final Map<String, List<rtv2.RoutineTaskV2>> rawTasksByBlock = {};
    for (final task in rawTemplateTasks) {
      rawTasksByBlock.putIfAbsent(task.routineBlockId, () => []).add(task);
    }
    final List<_V2BlockBundle> bundles = [];
    for (final block in blocks) {
      final filteredTasks = RoutineDatabaseService.getTasksForBlock(block.id);
      List<rtv2.RoutineTaskV2> selectedTasks = filteredTasks;
      if (filteredTasks.isNotEmpty) {
        try {
          print(
            '🧭 [REFLECT]${prefix}block=${block.id} tasksFiltered=${filteredTasks.length} blockUser=${block.userId}',
          );
        } catch (_) {}
      } else {
        final rawForBlock = (rawTasksByBlock[block.id] ?? [])
            .where((t) => !t.isDeleted)
            .toList()
          ..sort((a, b) => a.order.compareTo(b.order));
        if (rawForBlock.isNotEmpty) {
          selectedTasks = rawForBlock;
          try {
            final rawUserIds =
                rawForBlock.map((t) => t.userId).toSet().join(',');
            final rawSample = rawForBlock.take(3).map((t) => t.id).join(',');
            print(
              '🧭 [REFLECT]${prefix}block=${block.id} tasksFiltered=0 tasksRaw=${rawForBlock.length} blockUser=${block.userId} rawUsers=[$rawUserIds] rawSample=[$rawSample]',
            );
          } catch (_) {}
        } else {
          try {
            print(
              '🧭 [REFLECT]${prefix}block=${block.id} tasksFiltered=0 tasksRaw=0 blockUser=${block.userId} -> using block-level fallback',
            );
          } catch (_) {}
          selectedTasks = const <rtv2.RoutineTaskV2>[];
        }
      }
      bundles.add(_V2BlockBundle(block: block, tasks: selectedTasks));
    }
    if (bundles.isEmpty) {
      try {
        print('🧭 [REFLECT]${prefix}V2 bundles empty');
      } catch (_) {}
    }
    return bundles;
  }

  static List<_V2ReflectPayload> _generateV2PayloadsForDate(
    DateTime date,
    List<_V2BlockBundle> bundles,
    RoutineTemplateV2 routine,
  ) {
    final List<_V2ReflectPayload> payloads = [];
    final dateLabel =
        '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    try {
      print(
          '🧭 [REFLECT][V2] payload generation start date=$dateLabel bundles=${bundles.length}');
    } catch (_) {}
    for (final bundle in bundles) {
      final block = bundle.block;
      DateTime blockStart = DateTime(
        date.year,
        date.month,
        date.day,
        block.startTime.hour,
        block.startTime.minute,
      );
      DateTime blockEnd = DateTime(
        date.year,
        date.month,
        date.day,
        block.endTime.hour,
        block.endTime.minute,
      );
      if (!blockEnd.isAfter(blockStart)) {
        blockEnd = blockEnd.add(const Duration(days: 1));
      }
      print('🧭 [REFLECT][V2] block=${block.id} blockStart=${blockStart.toIso8601String()} blockEnd=${blockEnd.toIso8601String()} tasks=${bundle.tasks.length}');
      var cursor = blockStart;
      if (bundle.tasks.isEmpty) {
        final blockLabel = (block.blockName?.isNotEmpty ?? false)
            ? block.blockName!
            : routine.title;
        try {
          print(
            '🧭 [REFLECT][V2] block-level fallback block=${block.id} name="$blockLabel" start=${blockStart.toIso8601String()} end=${blockEnd.toIso8601String()}',
          );
        } catch (_) {}
        payloads.add(
          _V2ReflectPayload(
            name: blockLabel,
            start: blockStart,
            end: blockEnd,
            details: null,
            memo: null,
            projectId: block.projectId,
            subProjectId: block.subProjectId,
            subProject: block.subProject,
            modeId: block.modeId,
            location: block.location,
            blockName: block.blockName,
            taskId: 'block:${block.id}',
            isBlockLevel: true,
            workingMinutes: block.workingMinutes,
            excludeFromReport: block.excludeFromReport,
            isEvent: block.isEvent,
          ),
        );
        continue;
      }
      for (final task in bundle.tasks) {
        final fallback = AppSettingsService.getInt(
          AppSettingsService.keyTaskDefaultEstimatedMinutes,
          defaultValue: 5,
        );
        final minutes =
            task.estimatedDuration > 0 ? task.estimatedDuration : (fallback > 0 ? fallback : 5);
        var taskEnd = cursor.add(Duration(minutes: minutes));
        if (taskEnd.isAfter(blockEnd)) {
          taskEnd = blockEnd;
        }
        if (!taskEnd.isAfter(cursor)) {
          print('🔴 [REFLECT][V2] SKIP task="${task.name}" id=${task.id} cursor=${cursor.toIso8601String()} taskEnd=${taskEnd.toIso8601String()} minutes=$minutes');
          continue;
        }
        print('🧭 [REFLECT][V2] ADD task="${task.name}" start=${cursor.toIso8601String()} end=${taskEnd.toIso8601String()} minutes=$minutes');
        payloads.add(
          _V2ReflectPayload(
            name: task.name,
            start: cursor,
            end: taskEnd,
            details: task.details,
            memo: task.memo,
            projectId: task.projectId ?? bundle.block.projectId,
            subProjectId: task.subProjectId ?? bundle.block.subProjectId,
            subProject: task.subProject ?? bundle.block.subProject,
            modeId: task.modeId ?? bundle.block.modeId,
            location: (task.location?.isNotEmpty == true)
                ? task.location
                : bundle.block.location,
            blockName: (task.blockName?.isNotEmpty == true)
                ? task.blockName
                : bundle.block.blockName,
            taskId: task.id,
            excludeFromReport: bundle.block.excludeFromReport,
            isEvent: task.isEvent,
          ),
        );
        cursor = taskEnd;
        if (!cursor.isBefore(blockEnd)) {
          break;
        }
      }
    }
    try {
      print(
          '🧭 [REFLECT][V2] payload generation done date=$dateLabel count=${payloads.length}');
    } catch (_) {}
    return payloads;
  }
}

class _V2BlockBundle {
  final rbv2.RoutineBlockV2 block;
  final List<rtv2.RoutineTaskV2> tasks;

  const _V2BlockBundle({
    required this.block,
    required this.tasks,
  });
}

class _V2ReflectPayload {
  final String name;
  final DateTime start;
  final DateTime end;
  final String? details;
  final String? memo;
  final String? projectId;
  final String? subProjectId;
  final String? subProject;
  final String? modeId;
  final String? location;
  final String? blockName;
  final String taskId;
  final bool isBlockLevel;
  final int? workingMinutes;
  final bool excludeFromReport;
  final bool isEvent;

  const _V2ReflectPayload({
    required this.name,
    required this.start,
    required this.end,
    required this.details,
    required this.memo,
    required this.projectId,
    required this.subProjectId,
    required this.subProject,
    required this.modeId,
    required this.location,
    required this.blockName,
    required this.taskId,
    this.isBlockLevel = false,
    this.workingMinutes,
    this.excludeFromReport = false,
    this.isEvent = false,
  });
}
