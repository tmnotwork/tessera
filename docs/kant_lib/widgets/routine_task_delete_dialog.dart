import 'package:flutter/material.dart';

class RoutineTaskDeleteDialog {
  static Future<bool> show(BuildContext context) async {
    return await showDialog<bool>(
          context: context,
          builder: (BuildContext context) {
            return AlertDialog(
              title: const Text('タスク削除'),
              content: const Text('このタスクを削除しますか？'),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.of(context).pop(false);
                  },
                  child: const Text('キャンセル'),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.of(context).pop(true);
                  },
                  child: Text('削除', style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
              ],
            );
          },
        ) ??
        false;
  }
}
