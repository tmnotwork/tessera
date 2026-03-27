import 'package:flutter/material.dart';
import 'routine_task_delete_dialog.dart';

class RoutineTaskDeleteButton extends StatelessWidget {
  final void Function() onDelete;

  const RoutineTaskDeleteButton({super.key, required this.onDelete});

  Future<void> _handleDelete(BuildContext context) async {
    print('🗑️ DEBUG: Delete button clicked');
    final shouldDelete = await RoutineTaskDeleteDialog.show(context);
    print('🗑️ DEBUG: Delete dialog result: $shouldDelete');
    if (shouldDelete) {
      print('🗑️ DEBUG: Calling onDelete callback');
      onDelete();
      print('🗑️ DEBUG: onDelete callback completed');
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 60,
      height: 36, // 明示的に36pxに設定
      child: Container(
        alignment: Alignment.center,
        decoration: const BoxDecoration(),
        color: Theme.of(context).inputDecorationTheme.fillColor ?? Theme.of(context).colorScheme.surface,
        child: IconButton(
          onPressed: () => _handleDelete(context),
          icon: Icon(Icons.delete, size: 20, color: Theme.of(context).colorScheme.error),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
        ),
      ),
    );
  }
}
