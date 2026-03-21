// ignore_for_file: avoid_print, depend_on_referenced_packages, library_prefixes

import 'package:collection/collection.dart'; // groupBy のためにインポート
import 'dart:math' as Math; // Math.min のためにインポート
import '../models/flashcard.dart';
import 'hive_service.dart';
import 'sync_service.dart'; // SyncOperationToCloud のためにインポート
import 'firebase_service.dart'; // ユーザーID取得のためにインポート

class CardService {
// HiveService のインスタンスを取得
  // final SyncService _syncService = SyncService(); // インスタンスは不要

  /// 重複カード（質問・回答・解説が同じ）を検索し、1つに統一する。
  ///
  /// 各重複グループ内で1枚のカードを残し、他を削除する。
  /// 残すカードは Firestore ID を持つものを優先し、なければ最初のものを選ぶ。
  /// 削除されたカードは削除ログに追加される。
  ///
  /// Returns:
  ///   統一（削除）された重複カードの数。
  Future<int> unifyDuplicateCards() async {
    print('--- Starting duplicate card unification ---');
    final cardBox = HiveService.getCardBox();
    final allCards = cardBox.values.toList();

    if (allCards.isEmpty) {
      print('No cards found.');
      return 0;
    }

    // カードを question|answer|explanation でグループ化
    final groupedCards = groupBy(
        allCards,
        (FlashCard card) =>
            '${card.question}|${card.answer}|${card.explanation}');

    int unifiedCount = 0;
    final List<dynamic> keysToDelete = [];
    final List<String> firestoreIdsToDelete = []; // クラウド削除用Firestore IDリスト
    final userId = FirebaseService.getUserId();

    print(
        'Grouping complete. Found ${groupedCards.length} unique content groups.');

    // 各グループをチェック
    for (final entry in groupedCards.entries) {
      final group = entry.value;
      if (group.length > 1) {
        // 重複グループが見つかった
        print(
            'Found duplicate group with ${group.length} cards for content key: ${entry.key.substring(0, Math.min(entry.key.length, 50))}...');

        FlashCard? cardToKeep;

        // 1. Firestore ID を持つカードを探す
        final cardsWithFirestoreId = group
            .where((c) => c.firestoreId != null && c.firestoreId!.isNotEmpty)
            .toList();

        if (cardsWithFirestoreId.isNotEmpty) {
          // Firestore ID を持つカードがある場合、その中で最初（または最新更新など）のものを残す
          // ここでは簡単のためリストの最初のものを選ぶ
          cardToKeep = cardsWithFirestoreId.first;
          print(
              '  Keeping card with Firestore ID: ${cardToKeep.firestoreId} (Key: ${cardToKeep.key})');
        } else {
          // Firestore ID を持つカードがない場合、グループの最初のカードを残す
          cardToKeep = group.first;
          print(
              '  No Firestore ID found in group. Keeping the first card (Key: ${cardToKeep.key})');
        }

        // 残すカード以外を削除対象に追加
        for (final card in group) {
          if (card.key != cardToKeep.key) {
            keysToDelete.add(card.key);
            // Firestore ID がある場合はクラウド削除リストに追加
            if (card.firestoreId != null && card.firestoreId!.isNotEmpty) {
              firestoreIdsToDelete.add(card.firestoreId!);
            }
            unifiedCount++;
            print(
                '    Marking card for deletion (Key: ${card.key}, Firestore ID: ${card.firestoreId ?? 'N/A'})');
          }
        }
      }
    }

    if (keysToDelete.isNotEmpty) {
      print('Deleting ${keysToDelete.length} duplicate cards from Hive...');
      await cardBox.deleteAll(keysToDelete);
      print('Hive deletion complete.');

      // 削除ログに追加 (ログインしている場合 & 削除対象のFirestore IDがある場合)
      // SyncService.syncOperationToCloud を使用する
      if (userId != null && firestoreIdsToDelete.isNotEmpty) {
        print(
            '📱➡️☁️ Requesting cloud deletion for ${firestoreIdsToDelete.length} duplicate cards...');
        try {
          // syncOperationToCloud は firestoreIds / firestoreId を受け取る
          final result = await SyncService.syncOperationToCloud(
              'delete_card', {'firestoreIds': firestoreIdsToDelete});
          if (result['success'] == true) {
            print('✅ Cloud deletion request successful.');
          } else {
            print('⚠️ Cloud deletion request failed: ${result['message']}');
            // ここでエラー処理が必要な場合がある（例：Snackbar表示など）
            // ただし、このメソッドはUI層ではないため、ここではログ出力に留める
          }
        } catch (e) {
          print('❌ Error during cloud deletion request: $e');
          // ここでもエラー処理が必要な場合がある
        }
      }
    } else {
      print('No duplicate cards found to unify.');
    }

    print(
        '--- Duplicate card unification finished. Unified count: $unifiedCount ---');
    return unifiedCount;
  }
}
