import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/block.dart' as block;
import '../../models/inbox_task.dart' as inbox;
import '../../providers/task_provider.dart';
import '../../services/block_service.dart';
import '../../services/inbox_task_service.dart';
import '../../services/mode_service.dart';
import '../../services/project_service.dart';
import '../../services/sub_project_service.dart';
import '../mode_input_field.dart';
import '../project_input_field.dart';
import '../sub_project_input_field.dart';
import 'inbox_memo_dialog.dart';
import '../../utils/ime_safe_dialog.dart';
import '../../utils/input_method_guard.dart';
import '../../utils/web_scoped_save_shortcut_barrier.dart';

/// インボックス画面と同じ項目を編集できるダイアログ。
///
/// - 期限 / 実行日 / 実行時刻 / 所要(分) / タスク名 / コメント(メモ) /
///   プロジェクト / サブプロジェクト / モード / ブロック(なし/いつか含む) / 削除
Future<bool?> showInboxTaskEditDialog(
  BuildContext context,
  inbox.InboxTask task,
) async {
  // Mode候補のため（未初期化のケースに備える）
  try {
    ModeService.initialize();
  } catch (_) {}

  String ymd(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  bool sameYmd(DateTime a, DateTime b) {
    final al = a.toLocal();
    final bl = b.toLocal();
    return al.year == bl.year && al.month == bl.month && al.day == bl.day;
  }

  // インボックス表と同等: ブロック候補（過去ブロックは除外、1:N許容）
  List<block.Block> getAvailableBlocksForDate(DateTime date) {
    final now = DateTime.now();
    final allBlocks = BlockService.getAllBlocks();
    final filtered = allBlocks.where((b) {
      final isSameDay = sameYmd(b.executionDate, date);
      final isNotDeleted = !b.isDeleted;

      bool isWithinBlockWindow() {
        try {
          final start = DateTime(
            b.executionDate.year,
            b.executionDate.month,
            b.executionDate.day,
            b.startHour,
            b.startMinute,
          );
          final end = start.add(Duration(minutes: b.estimatedDuration));
          return !now.isBefore(start) && now.isBefore(end);
        } catch (_) {
          return false;
        }
      }

      final includeByCompletion = !b.isCompleted || isWithinBlockWindow();

      bool isPastBlock() {
        try {
          final start = DateTime(
            b.executionDate.year,
            b.executionDate.month,
            b.executionDate.day,
            b.startHour,
            b.startMinute,
          );
          final end = start.add(Duration(minutes: b.estimatedDuration));
          // 「過ぎ去った予定ブロック」は end <= now
          return !now.isBefore(end);
        } catch (_) {
          return false;
        }
      }

      return isSameDay && isNotDeleted && includeByCompletion && !isPastBlock();
    }).toList()
      ..sort((a, b) {
        final at = a.startHour * 60 + a.startMinute;
        final bt = b.startHour * 60 + b.startMinute;
        return at.compareTo(bt);
      });
    return filtered;
  }

  List<block.Block> getAvailableBlocksForTask(
    inbox.InboxTask t,
    DateTime execDate,
    String? selectedBlockId,
  ) {
    final base = getAvailableBlocksForDate(execDate);
    final blockId = selectedBlockId ?? t.blockId;
    if (blockId == null || blockId.isEmpty) return base;
    final current = BlockService.getBlockById(blockId);
    if (current == null) return base;
    if (sameYmd(current.executionDate, execDate) &&
        !current.isCompleted &&
        !current.isDeleted) {
      if (!base.any((b) => b.id == current.id)) {
        final merged = [...base, current]
          ..sort((a, b) {
            final at = a.startHour * 60 + a.startMinute;
            final bt = b.startHour * 60 + b.startMinute;
            return at.compareTo(bt);
          });
        return merged;
      }
    }
    return base;
  }

  (int?, int?) parseTime(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return (null, null);
    int? hour;
    int? minute;

    if (trimmed.contains(':')) {
      final parts = trimmed.split(':');
      if (parts.length >= 2) {
        hour = int.tryParse(parts[0].trim());
        minute = int.tryParse(parts[1].trim());
      }
    }

    if (hour == null || minute == null) {
      final digits = trimmed.replaceAll(RegExp(r'[^0-9]'), '');
      if (digits.isEmpty) return (null, null);
      if (digits.length == 4) {
        hour = int.tryParse(digits.substring(0, 2));
        minute = int.tryParse(digits.substring(2, 4));
      } else if (digits.length == 3) {
        hour = int.tryParse(digits.substring(0, 1));
        minute = int.tryParse(digits.substring(1, 3));
      } else if (digits.length == 2) {
        hour = int.tryParse(digits);
        minute = 0;
      } else if (digits.length == 1) {
        hour = int.tryParse(digits);
        minute = 0;
      }
    }

    if (hour == null || minute == null) return (null, null);
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return (null, null);
    return (hour, minute);
  }

  String formatBlockLabel(block.Block b) {
    final title = (() {
      final t = b.title.trim();
      if (t.isNotEmpty) return t;
      final name = b.blockName?.trim();
      if (name != null && name.isNotEmpty) return name;
      return '（名称未設定）';
    })();
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final start = '${twoDigits(b.startHour)}:${twoDigits(b.startMinute)}';
    final endTime = b.endDateTime.toLocal();
    final end = '${twoDigits(endTime.hour)}:${twoDigits(endTime.minute)}';
    final date = '${b.executionDate.month}/${b.executionDate.day}';
    return '$title ($date $start-$end)';
  }

  final titleController = TextEditingController(text: task.title);
  final projectController = TextEditingController();
  final subProjectController = TextEditingController();
  final modeController = TextEditingController();
  final dueDateController =
      TextEditingController(text: task.dueDate != null ? ymd(task.dueDate!) : '');
  final executionDateController = TextEditingController(text: ymd(task.executionDate));
  final startTimeController = TextEditingController(
    text: (task.startHour != null && task.startMinute != null)
        ? '${task.startHour!.toString().padLeft(2, '0')}:${task.startMinute!.toString().padLeft(2, '0')}'
        : '',
  );
  final durationController =
      TextEditingController(text: task.estimatedDuration.toString());

  // close-confirm snapshot（外側タップで閉じられてデータが失われるのを防ぐ）
  final initialTitle = titleController.text;
  final initialDue = dueDateController.text;
  final initialExec = executionDateController.text;
  final initialStart = startTimeController.text;
  final initialDuration = durationController.text;
  final initialProjectId = task.projectId;
  final initialSubProjectId = task.subProjectId;
  final initialModeId = task.modeId;
  final initialBlockId = task.blockId;
  final initialSomeday = task.isSomeday == true;
  final initialExcludeFromReport = task.excludeFromReport == true;
  final initialImportant = task.isImportant == true;

  // 入力フィールドの内部状態
  String? selectedProjectId = task.projectId;
  String? selectedSubProjectId = task.subProjectId;
  String? selectedModeId = task.modeId;
  DateTime? selectedDueDate = task.dueDate;
  DateTime selectedExecutionDate = DateTime(
    task.executionDate.year,
    task.executionDate.month,
    task.executionDate.day,
  );
  String? selectedBlockId = task.blockId;
  bool isSomeday = task.isSomeday == true;
  bool excludeFromReport = task.excludeFromReport == true;
  bool isImportant = task.isImportant == true;

  // UI表示文字の初期値
  projectController.text = selectedProjectId != null
      ? (ProjectService.getProjectById(selectedProjectId)?.name ?? '')
      : '';
  subProjectController.text = selectedSubProjectId != null
      ? (SubProjectService.getSubProjectById(selectedSubProjectId)?.name ?? '')
      : '';
  modeController.text = (selectedModeId != null && selectedModeId.isNotEmpty)
      ? (ModeService.getModeById(selectedModeId)?.name ?? '')
      : '';

  const String somedayValue = '__inbox_someday__';

  try {
    return await showImeSafeDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            bool isDirty() {
              return titleController.text != initialTitle ||
                  dueDateController.text != initialDue ||
                  executionDateController.text != initialExec ||
                  startTimeController.text != initialStart ||
                  durationController.text != initialDuration ||
                  selectedProjectId != initialProjectId ||
                  selectedSubProjectId != initialSubProjectId ||
                  selectedModeId != initialModeId ||
                  selectedBlockId != initialBlockId ||
                  isSomeday != initialSomeday ||
                  excludeFromReport != initialExcludeFromReport ||
                  isImportant != initialImportant;
            }

            Future<bool> confirmDiscard() async {
              final result = await showImeSafeDialog<bool>(
                context: ctx,
                barrierDismissible: false,
                builder: (confirmCtx) => AlertDialog(
                  title: const Text('確認'),
                  content: const Text('編集中です。内容を破棄しますか。'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(confirmCtx).pop(false),
                      child: const Text('キャンセル'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.of(confirmCtx).pop(true),
                      child: const Text('破棄する'),
                    ),
                  ],
                ),
              );
              return result == true;
            }

            Future<bool> handleCloseRequest() async {
              if (!isDirty()) return true;
              return await confirmDiscard();
            }

            final provider = ctx.read<TaskProvider>();
            final blockCandidates = getAvailableBlocksForTask(
              task,
              selectedExecutionDate,
              selectedBlockId,
            );

            Future<void> pickDueDate() async {
              final picked = await showDatePicker(
                context: ctx,
                initialDate: selectedDueDate ?? DateTime.now(),
                firstDate: DateTime(2020),
                lastDate: DateTime(2100),
              );
              if (picked == null) return;
              setDialogState(() {
                selectedDueDate = DateTime(picked.year, picked.month, picked.day);
                dueDateController.text = ymd(selectedDueDate!);
              });
            }

            Future<void> pickExecutionDate() async {
              final picked = await showDatePicker(
                context: ctx,
                initialDate: selectedExecutionDate,
                firstDate: DateTime.now(),
                lastDate: DateTime(2100),
              );
              if (picked == null) return;
              setDialogState(() {
                selectedExecutionDate = DateTime(picked.year, picked.month, picked.day);
                executionDateController.text = ymd(selectedExecutionDate);
                // インボックス表と同様: 実行日変更時はブロックをクリア
                selectedBlockId = null;
                isSomeday = false;
              });
            }

            Future<void> doSave() async {
              final title = titleController.text.trim();
              if (title.isEmpty) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('タスク名は必須です')),
                );
                return;
              }

              final (h, m) = parseTime(startTimeController.text);
              final duration = int.tryParse(durationController.text.trim());

              // まず基本フィールドを更新（インボックス表の編集項目）
              final baseUpdated = task.copyWith(
                title: title,
                projectId: selectedProjectId,
                subProjectId: selectedSubProjectId,
                modeId: selectedModeId,
                dueDate: selectedDueDate,
                executionDate: selectedExecutionDate,
                startHour: h,
                startMinute: m,
                estimatedDuration: duration ?? task.estimatedDuration,
                excludeFromReport: excludeFromReport,
                isImportant: isImportant,
                lastModified: DateTime.now(),
                version: task.version + 1,
              );

              await provider.updateInboxTask(baseUpdated);

              // ブロック/いつか の挙動はインボックス表に合わせる
              if (isSomeday) {
                final refreshed = InboxTaskService.getInboxTask(task.id);
                if (refreshed != null) {
                  await provider.updateInboxTask(
                    refreshed.copyWith(
                      blockId: null,
                      startHour: null,
                      startMinute: null,
                      isSomeday: true,
                      lastModified: DateTime.now(),
                      version: refreshed.version + 1,
                    ),
                  );
                }
              } else if (selectedBlockId != null && selectedBlockId!.isNotEmpty) {
                // 仕様: 過去に置かないため、Providerのスケジューリングを使用
                await provider.assignInboxToBlockWithScheduling(
                  task.id,
                  selectedBlockId!,
                );
              } else {
                // なし: 実行時刻を未設定に戻す（未割当）
                final refreshed = InboxTaskService.getInboxTask(task.id);
                if (refreshed != null) {
                  await provider.updateInboxTask(
                    refreshed.copyWith(
                      blockId: null,
                      startHour: null,
                      startMinute: null,
                      isSomeday: false,
                      lastModified: DateTime.now(),
                      version: refreshed.version + 1,
                    ),
                  );
                }
              }

              if (dialogCtx.mounted) {
                Navigator.of(dialogCtx).pop(true);
              }
            }

            void saveFromShortcut() {
              if (isImeComposing(titleController)) return;
              // ignore: discarded_futures
              doSave();
            }

            return WebScopedSaveShortcutBarrier(
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.keyS, control: true):
                      saveFromShortcut,
                  const SingleActivator(LogicalKeyboardKey.keyS, meta: true):
                      saveFromShortcut,
                },
                child: Focus(
                autofocus: true,
                child: WillPopScope(
              onWillPop: () async {
                return await handleCloseRequest();
              },
              child: AlertDialog(
              insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
              title: const Text('タスクの編集'),
              content: SingleChildScrollView(
                child: SizedBox(
                  width: 720,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                        controller: titleController,
                        decoration: const InputDecoration(
                          labelText: 'タスク名 *',
                          border: OutlineInputBorder(),
                          floatingLabelBehavior: FloatingLabelBehavior.always,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: dueDateController,
                              readOnly: true,
                              decoration: const InputDecoration(
                                labelText: '期限',
                                border: OutlineInputBorder(),
                                floatingLabelBehavior: FloatingLabelBehavior.always,
                                suffixIcon: Icon(Icons.calendar_today),
                              ),
                              onTap: pickDueDate,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TextField(
                              controller: executionDateController,
                              readOnly: true,
                              decoration: const InputDecoration(
                                labelText: '実行日',
                                border: OutlineInputBorder(),
                                floatingLabelBehavior: FloatingLabelBehavior.always,
                                suffixIcon: Icon(Icons.calendar_month),
                              ),
                              onTap: pickExecutionDate,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: startTimeController,
                              decoration: const InputDecoration(
                                labelText: '実行時刻',
                                border: OutlineInputBorder(),
                                floatingLabelBehavior: FloatingLabelBehavior.always,
                                hintText: 'HH:MM',
                              ),
                              keyboardType: TextInputType.number,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TextField(
                              controller: durationController,
                              decoration: const InputDecoration(
                                labelText: '所要 (分)',
                                border: OutlineInputBorder(),
                                floatingLabelBehavior: FloatingLabelBehavior.always,
                              ),
                              keyboardType: TextInputType.number,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: InputDecorator(
                              decoration: const InputDecoration(
                                labelText: 'プロジェクト',
                                border: OutlineInputBorder(),
                                floatingLabelBehavior: FloatingLabelBehavior.always,
                              ),
                              child: ProjectInputField(
                                controller: projectController,
                                useOutlineBorder: false,
                                withBackground: false,
                                showAllOnTap: true,
                                includeArchived: false,
                                onProjectChanged: (pid) {
                                  setDialogState(() {
                                    selectedProjectId = pid;
                                    // インボックス表と同様: プロジェクト変更時はサブプロジェクトをクリア
                                    selectedSubProjectId = null;
                                    subProjectController.text = '';
                                  });
                                },
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: InputDecorator(
                              decoration: const InputDecoration(
                                labelText: 'サブプロジェクト',
                                border: OutlineInputBorder(),
                                floatingLabelBehavior: FloatingLabelBehavior.always,
                              ),
                              child: SubProjectInputField(
                                controller: subProjectController,
                                projectId: selectedProjectId,
                                useOutlineBorder: false,
                                withBackground: false,
                                onSubProjectChanged: (spid, spName) {
                                  setDialogState(() {
                                    selectedSubProjectId = spid;
                                  });
                                },
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: InputDecorator(
                              decoration: const InputDecoration(
                                labelText: 'モード',
                                border: OutlineInputBorder(),
                                floatingLabelBehavior:
                                    FloatingLabelBehavior.always,
                              ),
                              child: ModeInputField(
                                controller: modeController,
                                useOutlineBorder: false,
                                withBackground: false,
                                height: 40,
                                onModeChanged: (mid) {
                                  setDialogState(() => selectedModeId = mid);
                                },
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: InputDecorator(
                              decoration: const InputDecoration(
                                labelText: 'いつか',
                                border: OutlineInputBorder(),
                                floatingLabelBehavior:
                                    FloatingLabelBehavior.always,
                              ),
                              child: SizedBox(
                                height: 40,
                                child: Row(
                                  children: [
                                    const Tooltip(
                                      message: 'インボックスの通常表示・割当から除外します',
                                      child: Icon(
                                        Icons.info_outline,
                                        size: 18,
                                      ),
                                    ),
                                    const Spacer(),
                                    Switch.adaptive(
                                      value: isSomeday,
                                      onChanged: (v) {
                                        setDialogState(() {
                                          isSomeday = v;
                                          if (v) {
                                            // いつか: ブロック/時刻はクリア（インボックス表と同様）
                                            selectedBlockId = null;
                                            startTimeController.text = '';
                                          }
                                        });
                                      },
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: InputDecorator(
                              decoration: const InputDecoration(
                                labelText: '集計外',
                                border: OutlineInputBorder(),
                                floatingLabelBehavior:
                                    FloatingLabelBehavior.always,
                              ),
                              child: SizedBox(
                                height: 40,
                                child: Row(
                                  children: [
                                    const Tooltip(
                                      message: 'レポート（集計）に含めません',
                                      child: Icon(
                                        Icons.info_outline,
                                        size: 18,
                                      ),
                                    ),
                                    const Spacer(),
                                    Switch.adaptive(
                                      value: excludeFromReport,
                                      onChanged: (v) => setDialogState(
                                        () => excludeFromReport = v,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: InputDecorator(
                              decoration: const InputDecoration(
                                labelText: '重要',
                                border: OutlineInputBorder(),
                                floatingLabelBehavior:
                                    FloatingLabelBehavior.always,
                              ),
                              child: SizedBox(
                                height: 40,
                                child: Row(
                                  children: [
                                    const Tooltip(
                                      message: '開始時刻のある重要タスクを通知対象にします',
                                      child: Icon(
                                        Icons.info_outline,
                                        size: 18,
                                      ),
                                    ),
                                    const Spacer(),
                                    Switch.adaptive(
                                      value: isImportant,
                                      onChanged: (v) => setDialogState(
                                        () => isImportant = v,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String?>(
                        decoration: const InputDecoration(
                          labelText: 'ブロック',
                          border: OutlineInputBorder(),
                          floatingLabelBehavior: FloatingLabelBehavior.always,
                        ),
                        value: isSomeday
                            ? somedayValue
                            : ((selectedBlockId != null && selectedBlockId!.isNotEmpty)
                                ? selectedBlockId
                                : null),
                        // 「いつか」ONのときはブロック選択は無効化（インボックス表と同様に未割当扱い）
                        onChanged: isSomeday
                            ? null
                            : (val) {
                                setDialogState(() {
                                  if (val == somedayValue) {
                                    // 旧互換: ドロップダウンからでも「いつか」をONにできる
                                    isSomeday = true;
                                    selectedBlockId = null;
                                    startTimeController.text = '';
                                  } else {
                                    isSomeday = false;
                                    selectedBlockId = val;
                                  }
                                });
                              },
                        items: [
                          const DropdownMenuItem<String?>(
                            value: null,
                            child: Text('なし'),
                          ),
                          ...blockCandidates.map(
                            (b) => DropdownMenuItem<String?>(
                              value: b.id,
                              child: Text(formatBlockLabel(b)),
                            ),
                          ),
                          const DropdownMenuItem<String?>(
                            value: somedayValue,
                            child: Text('いつか'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: () async {
                            await showInboxMemoEditorDialog(ctx, task);
                          },
                          icon: const Icon(Icons.comment_outlined),
                          label: Text(
                            (task.memo ?? '').trim().isEmpty
                                ? 'コメントを編集'
                                : 'コメントを編集（入力あり）',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () async {
                    final ok = await handleCloseRequest();
                    if (!ok) return;
                    if (dialogCtx.mounted) {
                      Navigator.of(dialogCtx).pop(false);
                    }
                  },
                  child: const Text('キャンセル'),
                ),
                TextButton(
                  onPressed: () async {
                    final ok = await showDialog<bool>(
                      context: ctx,
                      builder: (confirmCtx) => AlertDialog(
                        title: const Text('削除確認'),
                        content: Text('「${task.title}」を削除しますか？'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(confirmCtx).pop(false),
                            child: const Text('キャンセル'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.of(confirmCtx).pop(true),
                            style: TextButton.styleFrom(
                              foregroundColor:
                                  Theme.of(confirmCtx).colorScheme.error,
                            ),
                            child: const Text('削除'),
                          ),
                        ],
                      ),
                    );
                    if (ok == true) {
                      await provider.deleteInboxTask(task.id);
                      if (dialogCtx.mounted) {
                        Navigator.of(dialogCtx).pop(true);
                      }
                    }
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(ctx).colorScheme.error,
                  ),
                  child: const Text('削除'),
                ),
                FilledButton(
                  onPressed: doSave,
                  child: const Text('保存'),
                ),
              ],
            ),
            ),
          ),
        ),
            );
          },
        );
      },
    );
  } finally {
    titleController.dispose();
    projectController.dispose();
    subProjectController.dispose();
    modeController.dispose();
    dueDateController.dispose();
    executionDateController.dispose();
    startTimeController.dispose();
    durationController.dispose();
  }
}

