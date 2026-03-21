import 'package:flutter/material.dart';
import 'package:yomiage/models/flashcard.dart';
import 'package:yomiage/services/hive_service.dart';
import 'package:yomiage/services/firebase_service.dart';

class WebCardDeleter {
  // 削除確認ダイアログを表示
  static void showDeleteConfirmDialog(BuildContext context, FlashCard card, VoidCallback onDelete) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('カード削除確認',
            style: Theme.of(context).dialogTheme.titleTextStyle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('以下のカードを削除しますか？',
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 16),
            Text('質問: ${card.question}',
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            Text('回答: ${card.answer}',
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            Text('この操作は取り消せません。',
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(context).pop();
              onDelete();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            child: const Text('削除'),
          ),
        ],
      ),
    );
  }

  // カード削除処理
  static Future<void> deleteCard(FlashCard card, VoidCallback onSuccess) async {
    try {
      // Hiveからカードを削除
      await HiveService.getCardBox().delete(card.key);

      // Firebaseからも削除（ユーザーがログインしている場合）
      final userId = FirebaseService.getUserId();
      if (userId != null && card.id.isNotEmpty) {
        try {
          await FirebaseService.deleteCard(card.id, card: card);
        } catch (e) {
          // Firebase削除に失敗してもローカル削除は成功しているので続行
        }
      }

      onSuccess();
    } catch (e) {
      throw Exception('カードの削除に失敗しました: $e');
    }
  }
} 