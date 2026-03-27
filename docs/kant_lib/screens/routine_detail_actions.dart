import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/routine_template_v2.dart';
import '../providers/task_provider.dart';
import '../services/routine_mutation_facade.dart';
import '../widgets/app_notifications.dart';
import 'routine_detail_dialogs.dart';
import '../utils/ime_safe_dialog.dart';

class RoutineDetailActions {
  static void editRoutine(
    BuildContext context,
    RoutineTemplateV2 routine,
    Function setState,
  ) {
    final titleController = TextEditingController(text: routine.title);
    final memoController = TextEditingController(text: routine.memo);
    String selectedApplyDayType = routine.applyDayType;

    showImeSafeDialog(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final screenWidth = MediaQuery.of(ctx).size.width;
          final available = (screenWidth - 48).clamp(0.0, double.infinity);
          double targetWidth = screenWidth >= 1200 ? 720 : 600;
          if (targetWidth > available) targetWidth = available;
          if (targetWidth < 420) targetWidth = 420;

          Future<void> doSave() async {
            if (titleController.text.isEmpty) return;
            routine
              ..title = titleController.text
              ..memo = memoController.text
              ..applyDayType = selectedApplyDayType;
            await RoutineMutationFacade.instance.updateTemplate(routine);
            if (!ctx.mounted) return;
            Navigator.pop(ctx);
            context.read<TaskProvider>().refreshTasks();
            RoutineSelectedNotification(routine).dispatch(context);
            setState(() {});
          }

          return CallbackShortcuts(
            bindings: {
              SingleActivator(LogicalKeyboardKey.keyS, control: true): () => doSave(),
            },
            child: Focus(
              autofocus: true,
              child: AlertDialog(
            title: const Text('ルーティンを編集'),
            content: SizedBox(
              width: targetWidth,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: titleController,
                      decoration: const InputDecoration(
                        labelText: 'ルーティン名',
                        border: OutlineInputBorder(),
                        floatingLabelBehavior: FloatingLabelBehavior.always,
                      ),
                    ),
                    const SizedBox(height: 16),
                    ListTile(
                      leading: const Icon(Icons.calendar_today),
                      title: const Text('適用日'),
                      subtitle: Text(
                        RoutineDetailDialogs.getApplyDayTypeText(
                          selectedApplyDayType,
                        ),
                      ),
                      trailing: const Icon(Icons.arrow_forward_ios),
                      onTap: () =>
                          RoutineDetailDialogs.showApplyDayTypeSelectionDialog(
                        ctx,
                        selectedApplyDayType,
                        (applyDayType) => setDialogState(
                            () => selectedApplyDayType = applyDayType),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: memoController,
                      keyboardType: TextInputType.multiline,
                      textAlignVertical: TextAlignVertical.top,
                      minLines: 6,
                      maxLines: 12,
                      decoration: const InputDecoration(
                        labelText: 'メモ',
                        border: OutlineInputBorder(),
                        floatingLabelBehavior: FloatingLabelBehavior.always,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('キャンセル'),
              ),
              TextButton(
                onPressed: doSave,
                child: const Text('保存'),
              ),
            ],
              ),
            ),
          );
        },
      ),
    ).then((_) {
      titleController.dispose();
      memoController.dispose();
    });
  }

}
