// ignore_for_file: unused_local_variable, empty_catches

import 'package:cloud_firestore/cloud_firestore.dart';
import '../firebase_service.dart';
import '../../models/deck.dart';

/// 削除ログの管理を担当するサービス
///
/// 責任: 削除ログの管理
/// 独立性: FirebaseServiceのみに依存
/// 影響範囲: 削除ログ関連の処理のみ
class DeletionLogService {
  /// 削除済みカードのFirestore IDを取得する
  ///
  /// 戻り値: 削除済みカードのFirestore IDのセット
  static Future<Set<String>> fetchDeletedCardKeys() async {
    final deletedCardFirestoreIds = <String>{}; // Firestore IDを格納
    final userId = FirebaseService.getUserId();

    if (userId == null) return deletedCardFirestoreIds;

    try {
      final firestore = FirebaseService.firestore;
      // 'card_operations' コレクションを検索
      final cardOpsSnapshot = await firestore
          .collection('users')
          .doc(userId)
          .collection('card_operations') // 対象コレクション
          .where('operation', isEqualTo: 'deleted_card') // 操作タイプ
          .get();

      for (final doc in cardOpsSnapshot.docs) {
        final data = doc.data();
        // 'firestoreId' フィールドを取得
        if (data['firestoreId'] != null) {
          deletedCardFirestoreIds.add(data['firestoreId'].toString());
        } else {}
      }
    } catch (e) {}

    return deletedCardFirestoreIds;
  }

  /// 削除済みデッキ名を取得する
  ///
  /// 戻り値: 削除済みデッキ名のセット
  static Future<Set<String>> fetchDeletedDeckNames() async {
    final deletedDeckNames = <String>{};
    final userId = FirebaseService.getUserId();

    if (userId == null) return deletedDeckNames;

    try {
      final firestore = FirebaseService.firestore;
      final deckOpsSnapshot = await firestore
          .collection('users')
          .doc(userId)
          .collection('deck_operations')
          .where('operation',
              isEqualTo: 'deleted_deck') // 'cleared_cards'ではなく'deleted_deck'を検索
          .get();

      for (final doc in deckOpsSnapshot.docs) {
        final data = doc.data();
        if (data['deckName'] != null) {
          deletedDeckNames.add(data['deckName'].toString());
        }
      }
    } catch (e) {}

    return deletedDeckNames;
  }

  /// クリア済みデッキ名を取得する
  ///
  /// 戻り値: クリア済みデッキ名のセット
  static Future<Set<String>> fetchClearedDeckNames() async {
    final clearedDeckNames = <String>{};
    final userId = FirebaseService.getUserId();

    if (userId == null) return clearedDeckNames;

    try {
      final firestore = FirebaseService.firestore;
      final deckOpsSnapshot = await firestore
          .collection('users')
          .doc(userId)
          .collection('deck_operations')
          .where('operation', isEqualTo: 'cleared_cards')
          .get();

      for (final doc in deckOpsSnapshot.docs) {
        final data = doc.data();
        if (data['deckName'] != null) {
          clearedDeckNames.add(data['deckName'].toString());
        }
      }
    } catch (e) {}

    return clearedDeckNames;
  }

  /// Firestoreにカード操作のログを記録する
  ///
  /// [userId] ユーザーID
  /// [operationType] 操作タイプ
  /// [firestoreId] Firestore ID（オプション）
  /// [deckName] デッキ名（オプション）
  static Future<void> logCardOperation(String userId, String operationType,
      {String? firestoreId, String? deckName}) async {
    if (userId.isEmpty) return;

    final logData = <String, dynamic>{
      'operation': operationType,
      'timestamp': FieldValue.serverTimestamp(),
    };

    if (firestoreId != null) {
      logData['firestoreId'] = firestoreId;
    }
    if (deckName != null) {
      logData['deckName'] = deckName;
    }

    try {
      final firestore = FirebaseService.firestore;
      await firestore
          .collection('users')
          .doc(userId)
          .collection('card_operations')
          .add(logData);
    } catch (e) {
      // ログ記録のエラーは同期処理全体を妨げないようにする
    }
  }

  /// Firestoreにデッキ操作のログを記録する
  ///
  /// [userId] ユーザーID
  /// [operationType] 操作タイプ
  /// [deckName] デッキ名（オプション）
  static Future<void> logDeckOperation(String userId, String operationType,
      {String? deckName}) async {
    if (userId.isEmpty) return;

    final logData = <String, dynamic>{
      'operation': operationType,
      'timestamp': FieldValue.serverTimestamp(),
    };

    if (deckName != null) {
      logData['deckName'] = deckName;
    }

    try {
      final firestore = FirebaseService.firestore;
      await firestore
          .collection('users')
          .doc(userId)
          .collection('deck_operations')
          .add(logData);
    } catch (e) {}
  }

  /// 指定されたデッキ名の削除ログをクリーンアップする
  ///
  /// [userId] ユーザーID
  /// [deckName] クリーンアップ対象のデッキ名
  static Future<void> cleanupDeckDeletionLog(
      String userId, String deckName) async {
    if (userId.isEmpty || deckName.isEmpty) {
      return;
    }

    try {
      final firestore = FirebaseService.firestore;
      final deckOpsRef = firestore
          .collection('users')
          .doc(userId)
          .collection('deck_operations');

      // 削除対象のログを検索
      final querySnapshot = await deckOpsRef
          .where('operation', isEqualTo: 'deleted_deck')
          .where('deckName', isEqualTo: deckName)
          .get();

      if (querySnapshot.docs.isEmpty) {
        return;
      }

      // 見つかったログを削除
      int deletedCount = 0;
      final batch = firestore.batch();
      for (final doc in querySnapshot.docs) {
        batch.delete(doc.reference);
        deletedCount++;
      }
      await batch.commit();
    } catch (e) {
      // エラーが発生しても処理は続行する（ログ削除の失敗はデッキ作成をブロックしない）
    }
  }

  /// 指定されたデッキ名の削除ログをクリーンアップし、可能であればFirebase上のデッキデータも削除する
  ///
  /// [userId] ユーザーID
  /// [deckName] クリーンアップ対象のデッキ名
  static Future<void> cleanupDeckDeletionLogAndData(
      String userId, String deckName) async {
    if (userId.isEmpty || deckName.isEmpty) {
      return;
    }

    final firestore = FirebaseService.firestore;
    bool logDeleted = false;
    bool deckDocDeleted = false;

    try {
      // 1. deck_operations から該当ログを削除
      final logQuery = firestore
          .collection('users')
          .doc(userId)
          .collection('deck_operations')
          .where('deckName', isEqualTo: deckName)
          .where('operation', isEqualTo: 'deleted_deck'); // 念のため操作タイプも指定

      final logSnapshot = await logQuery.get();
      if (logSnapshot.docs.isNotEmpty) {
        final batch = firestore.batch();
        for (final doc in logSnapshot.docs) {
          batch.delete(doc.reference);
        }
        await batch.commit();
        logDeleted = true;
      } else {
        logDeleted = true; // ログがない場合も成功とみなす
      }

      // 2. Firebase 上のデッキドキュメントを削除 (デッキ名で検索)
      try {
        final decks = await FirebaseService.getDecks(); // 全デッキを取得
        final deckToDelete = decks.firstWhere(
          (d) => d.deckName == deckName,
          orElse: () => Deck(id: '', deckName: ''), // 見つからない場合はダミーを返す
        );

        if (deckToDelete.id.isNotEmpty) {
          await FirebaseService.deleteDeck(deckToDelete.id); // IDで削除
          deckDocDeleted = true;
        } else {
          deckDocDeleted = true; // デッキがない場合も成功とみなす
        }
      } catch (e) {
        // デッキドキュメント削除のエラーはログ削除には影響させない
      }
    } catch (e) {
      // エラーが発生しても、できる限りの処理は完了している可能性がある
    } finally {}
  }
}
