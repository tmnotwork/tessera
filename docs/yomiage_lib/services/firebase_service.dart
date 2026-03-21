// ignore_for_file: avoid_print, unused_import, body_might_complete_normally_nullable

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'dart:math' show min;
import '../models/deck.dart';
import '../models/flashcard.dart';
import '../services/hive_service.dart';
import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb, kDebugMode;
import '../services/sync_service.dart';
import '../services/sync/sync_cursor.dart';
import '../services/sync/feature_flags.dart';

class FirebaseService {
  static final FirebaseAuth _auth = FirebaseAuth.instance;
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // Firestoreインスタンスへのアクセス用ゲッター
  static FirebaseFirestore get firestore => _firestore;

  // Firebaseの初期化
  static Future<void> initFirebase() async {
    try {
      print('Firebase初期化処理を開始します...');
      await Firebase.initializeApp();
      print('Firebase.initializeAppが完了しました');

      // 認証状態の永続化設定（Webプラットフォームのみ）
      if (kIsWeb) {
        print('Webプラットフォームでの認証永続化を設定します');
        await _auth.setPersistence(Persistence.LOCAL);
        print('認証状態の永続化設定が完了しました');
      } else {
        print('ネイティブプラットフォームのため、認証永続化設定はスキップします');
        // ネイティブプラットフォームでは永続化はデフォルトで有効
      }

      // 接続状態の確認
      final currentUser = _auth.currentUser;
      print('現在のユーザー状態: ${currentUser != null ? "ログイン済み" : "未ログイン"}');
    } catch (e, stackTrace) {
      print('Firebase初期化エラー: $e');
      print('スタックトレース: $stackTrace');
      rethrow; // 再スローして上位で処理できるようにする
    }
  }

  // 現在のユーザーを取得
  static User? getCurrentUser() {
    return _auth.currentUser;
  }

  // ユーザーIDを取得（ログインしていない場合はnull）
  static String? getUserId() {
    return _auth.currentUser?.uid;
  }

  // メールとパスワードで登録
  static Future<UserCredential> registerWithEmailAndPassword(
      String email, String password) async {
    try {
      print('ユーザー登録を試行: $email');
      final result = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
      print('ユーザー登録成功: ${result.user?.uid}');
      return result;
    } catch (e, stackTrace) {
      print('ユーザー登録エラー: $e');
      print('スタックトレース: $stackTrace');
      rethrow;
    }
  }

  // メールとパスワードでログイン
  static Future<UserCredential> signInWithEmailAndPassword(
      String email, String password) async {
    try {
      print('ログインを試行: $email');
      final result = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      print('ログイン成功: ${result.user?.uid}');
      return result;
    } catch (e, stackTrace) {
      print('ログインエラー: $e');
      print('スタックトレース: $stackTrace');
      rethrow;
    }
  }

  // ログアウト
  static Future<void> signOut() async {
    return await _auth.signOut();
  }

  // デッキのコレクションパス
  static String _decksCollection() {
    final userId = getUserId();
    if (userId == null) throw Exception('ユーザーがログインしていません');
    return 'users/$userId/decks';
  }

  // カードのコレクションパス
  static String _cardsCollection() {
    final userId = getUserId();
    if (userId == null) throw Exception('ユーザーがログインしていません');
    return 'users/$userId/cards';
  }

  // デッキの保存（トランザクションとサーバータイムスタンプを使用して更新）
  static Future<void> saveDeck(Deck deck) async {
    try {
      // ドキュメントIDとして使用するキーを取得
      // 計画書要件: Firestore docId は deckId（UUID）を優先して安定化させる
      // 互換: 旧データで id が空/未設定のケースのみ、Hive key や deckName をフォールバックに使う
      final String docId = (deck.id.isNotEmpty)
          ? deck.id
          : (deck.key != null
              ? deck.key.toString()
              : deck.deckName.replaceAll(' ', '_').toLowerCase());

      print(
          '📤 Firebase saveDeck: デッキを保存します - 名前: ${deck.deckName}, ID: $docId');

      // トランザクションを使用して保存
      await _firestore.runTransaction((transaction) async {
        final docRef = _firestore.collection(_decksCollection()).doc(docId);
        final docSnapshot = await transaction.get(docRef);

        // デッキデータの基本情報
        final deckData = {
          'deckName': deck.deckName,
          'description': deck.description,
          'questionEnglishFlag': deck.questionEnglishFlag,
          'answerEnglishFlag': deck.answerEnglishFlag,
          'isArchived': deck.isArchived, // ★ isArchived を追加
          'updatedAt': FieldValue.serverTimestamp(), // サーバータイムスタンプで更新
          // Phase 2/3: 差分同期・論理削除の前提フィールド（移行未完了でも追加は安全）
          'serverUpdatedAt': FieldValue.serverTimestamp(),
          'isDeleted': false,
        };

        if (docSnapshot.exists) {
          // 既存のドキュメントの場合（更新）
          // タイムスタンプのチェック
          final existingUpdatedAt =
              docSnapshot.data()?['updatedAt'] as Timestamp?;
          final localUpdatedAt = deck.firestoreUpdatedAt; // ローカルのタイムスタンプを取得

          // ローカルのタイムスタンプが存在し、かつサーバーのタイムスタンプも存在するかのチェック
          if (localUpdatedAt != null && existingUpdatedAt != null) {
            // 比較: ローカルの方が新しいか？ (compareTo > 0 ならローカルが新しい)
            if (localUpdatedAt.compareTo(existingUpdatedAt) > 0) {
              // ローカルの方が新しい場合：更新を実行
              print(
                  '✅ Firebase saveDeck: ローカルが新しいため、既存のデッキを更新します - 名前: ${deck.deckName}, ID: $docId');
              transaction.update(docRef, deckData);
            } else {
              // サーバーの方が新しい（または同じ）場合：更新をスキップ
              print(
                  '⏩ Firebase saveDeck: サーバーのデータが新しいため、更新をスキップします - 名前: ${deck.deckName}, ID: $docId');
              print(
                  '  ローカル更新日時: $localUpdatedAt, サーバー更新日時: $existingUpdatedAt');
              // エラーはスローせず、処理を続行（ただし更新はしない）
            }
          } else {
            // ローカルまたはサーバーのタイムスタンプがない場合（初期同期など）：通常通り更新
            print(
                '✅ Firebase saveDeck: タイムスタンプ情報がないため、既存のデッキを更新します - 名前: ${deck.deckName}, ID: $docId');
            transaction.update(docRef, deckData);
          }
        } else {
          // 新規ドキュメント（作成）
          print(
              '✅ Firebase saveDeck: 新規デッキを作成します - 名前: ${deck.deckName}, ID: $docId');
          transaction.set(docRef, deckData);
        }
      });

      print(
          '✅ Firebase saveDeck: デッキの保存が完了しました - 名前: ${deck.deckName}, ID: $docId');
    } catch (e) {
      print('❌ Firebase saveDeck エラー: $e');
      rethrow;
    }
  }

  // デッキの取得
  static Future<List<Deck>> getDecks() async {
    try {
      print('🔍 Firebase getDecks: デッキ一覧を取得します');
      final snapshot = await _firestore.collection(_decksCollection()).get();
      print('✅ Firebase getDecks: ${snapshot.docs.length}件のデッキを取得しました');

      // 既存のデッキを削除したのに再度取得されるデッキのIDを記録
      print('🔑 Firebase getDecks: 取得したデッキID一覧:');
      for (var doc in snapshot.docs) {
        print('  - ID: ${doc.id}, 名前: ${doc.data()['deckName']}');
      }

      final decks = snapshot.docs.map((doc) {
        final data = doc.data();
        final deckName = data['deckName'] as String;

        print('📄 Firebase getDecks: デッキドキュメント ${doc.id} - 名前: $deckName');

        return Deck(
          id: doc.id,
          deckName: deckName,
          questionEnglishFlag: data['questionEnglishFlag'] as bool? ?? false,
          answerEnglishFlag: data['answerEnglishFlag'] as bool? ?? false,
          description: data['description'] as String? ?? '',
          isArchived: data['isArchived'] as bool? ?? false, // ★ isArchived を追加
          isDeleted: data['isDeleted'] as bool? ?? false,
          deletedAt: data['deletedAt'] is Timestamp
              ? (data['deletedAt'] as Timestamp).toDate()
              : null,
          // 互換: 既存の競合処理が firestoreUpdatedAt を参照しているため、可能なら serverUpdatedAt を優先
          firestoreUpdatedAt: (data['serverUpdatedAt'] is Timestamp)
              ? data['serverUpdatedAt'] as Timestamp
              : (data['updatedAt'] is Timestamp ? data['updatedAt'] as Timestamp : null),
        );
      }).toList();

      return decks;
    } catch (e) {
      print('❌ Firebase getDecks エラー: $e');
      rethrow;
    }
  }

  // ★★★ 新規追加: ユーザーの全カードを取得 ★★★
  static Future<List<FlashCard>> getAllCardsForUser(String userId) async {
    try {
      print('🔍 Firebase getAllCardsForUser: ユーザー $userId の全カードを取得します');

      // 移行前互換: 物理delete＋削除ログ運用期間は、削除済みをログから除外する
      Set<String> deletedCardFirestoreIds = {};
      if (!FirebaseSyncFeatureFlags.useLogicalDelete()) {
        try {
          // 注意: SyncService の static メソッドを直接呼び出す
          deletedCardFirestoreIds = await SyncService.fetchDeletedCardKeys();
          print(
              'ℹ️ [getAllCardsForUser] 取得した削除済みカードIDリスト: ${deletedCardFirestoreIds.length}件');
        } catch (e) {
          print('⚠️ [getAllCardsForUser] 削除済みカードIDの取得に失敗: $e');
        }
      }

      final snapshot = await _firestore.collection(_cardsCollection()).get();
      print(
          '✅ Firebase getAllCardsForUser: ${snapshot.docs.length}件のカードドキュメントを取得しました');

      final cards = snapshot.docs
          .map((doc) {
            // 移行前互換: 削除ログで除外
            if (deletedCardFirestoreIds.contains(doc.id)) {
              print('🚫 [getAllCardsForUser] 削除済みカード(削除ログ)のためスキップ: ID=${doc.id}');
              return null; // nullを返すことで後でフィルタリング
            }

            final data = doc.data();
            final bool isDeleted = data['isDeleted'] as bool? ?? false;
            final DateTime? deletedAt = data['deletedAt'] is Timestamp
                ? (data['deletedAt'] as Timestamp).toDate()
                : null;
            final Timestamp? serverUpdatedAt = data['serverUpdatedAt'] is Timestamp
                ? (data['serverUpdatedAt'] as Timestamp)
                : null;

            // FirestoreのTimestampをDateTime?に変換
            DateTime? parseTimestamp(dynamic timestamp) {
              if (timestamp is Timestamp) {
                return timestamp.toDate();
              }
              return null;
            }

            // FirestoreのNumber (ミリ秒エポック) を int? に変換
            int? parseUpdatedAt(dynamic value) {
              if (value is int) {
                return value;
              } else if (value is Timestamp) {
                // 移行期間中の Timestamp 型も考慮
                return value.millisecondsSinceEpoch;
              } else if (value is double) {
                // Firestore が Number を double で返す場合も考慮
                return value.toInt();
              }
              return null;
            }

            final card = FlashCard(
              id: doc.id, // HiveObjectのidフィールドにFirestoreのドキュメントIDを設定
              question: data['question'] as String? ?? '',
              answer: data['answer'] as String? ?? '',
              explanation: data['explanation'] as String? ?? '',
              deckName: data['deckName'] as String? ?? '',
              nextReview: parseTimestamp(data['nextReview']),
              repetitions: data['repetitions'] as int? ?? 0,
              eFactor: (data['eFactor'] as num?)?.toDouble() ?? 2.5,
              intervalDays: data['intervalDays'] as int? ?? 0,
              questionEnglishFlag:
                  data['questionEnglishFlag'] as bool? ?? false,
              answerEnglishFlag: data['answerEnglishFlag'] as bool? ?? true,
              firestoreId: doc.id, // FirestoreのドキュメントIDを保持
              // firestoreUpdatedAt は Firestore のタイムスタンプを直接代入 (コンストラクタにあれば)
              // firestoreUpdatedAt: data['updatedAt'] is Timestamp ? data['updatedAt'] : null,
              updatedAt: parseUpdatedAt(data['updatedAt']), // int? 型として取得・変換
              headline: data['headline'] as String? ?? '', // ★ headline を追加
              supplement:
                  data['supplement'] as String? ?? '', // ★ supplement 追加
              chapter: data['chapter'] as String? ?? '',
              isDeleted: isDeleted,
              deletedAt: deletedAt,
              // firestoreCreatedAt は Firestore のタイムスタンプを DateTime? に変換 (コンストラクタにあれば)
              // firestoreCreatedAt: parseTimestamp(data['createdAt']),
            );
            // 互換: serverUpdatedAt を優先して firestoreUpdatedAt に入れる
            card.firestoreUpdatedAt = serverUpdatedAt ??
                (data['updatedAt'] is Timestamp ? data['updatedAt'] as Timestamp : null);

            print(
                '📄 Firebase getAllCardsForUser: カード ${doc.id} を変換しました (Question: ${card.question.substring(0, min(card.question.length, 20))}...)');
            return card;
          })
          .whereType<FlashCard>()
          .toList(); // ★★★ null を除去 ★★★

      print(
          '✅ Firebase getAllCardsForUser: 削除済みを除いた有効なカード ${cards.length} 件を返します');

      return cards;
    } catch (e, stackTrace) {
      print('❌ Firebase getAllCardsForUser エラー: $e');
      print(stackTrace);
      rethrow;
    }
  }
  // ★★★ ここまで追加 ★★★

  // デッキの削除（トランザクションを使用してタイムスタンプを検証）
  static Future<void> deleteDeck(String deckKey, {Deck? deck}) async {
    try {
      print(
          '🗑️ Firebase deleteDeck: デッキ削除開始 - キー: $deckKey (${deckKey.runtimeType})');

      // トランザクションを使用してデッキ削除
      String? deckName;
      await _firestore.runTransaction((transaction) async {
        final docRef = _firestore.collection(_decksCollection()).doc(deckKey);
        final docSnapshot = await transaction.get(docRef);

        if (!docSnapshot.exists) {
          print('⚠️ Firebase deleteDeck: デッキが見つかりません - キー: $deckKey');

          // デッキが見つからない場合、念のため全デッキを取得して同名のものがないか確認
          final allDecks =
              await _firestore.collection(_decksCollection()).get();
          print('🔍 Firebase deleteDeck: 全デッキ数: ${allDecks.docs.length}');

          // 削除対象のデッキキーに数値が含まれている場合、
          // 文字列形式のキーに変換して再検索する可能性があるため、全デッキをチェック
          for (var doc in allDecks.docs) {
            print(
                '📄 Firebase deleteDeck: デッキID: ${doc.id}, 名前: ${doc.data()['deckName']}');
          }

          // デッキが見つからなくても、ローカル削除のためにエラーにはしない
          return;
        }

        final deckData = docSnapshot.data() as Map<String, dynamic>;
        deckName = deckData['deckName'] as String;
        print('🔍 Firebase deleteDeck: デッキ名: $deckName を削除します');

        // タイムスタンプの比較が必要な場合（引数でデッキオブジェクトが渡された場合）
        if (deck != null && deck.firestoreUpdatedAt != null) {
          final existingUpdatedAt = deckData['updatedAt'] as Timestamp?;

          if (existingUpdatedAt != null &&
              deck.firestoreUpdatedAt! != existingUpdatedAt) {
            // タイムスタンプが一致しない場合は競合エラー
            print('❌ Firebase deleteDeck: タイムスタンプの不一致による競合 - キー: $deckKey');
            print(
                '  ローカル更新日時: ${deck.firestoreUpdatedAt}, サーバー更新日時: $existingUpdatedAt');

            // 競合通知ストリームにメッセージを送信
            notifySyncConflict('デッキ「$deckName」が他の端末で更新されています。削除できません。');

            throw FirebaseException(
              plugin: 'cloud_firestore',
              code: 'aborted',
              message: 'デッキ「$deckName」が他の端末で更新されています。最新のデータを取得してください。',
            );
          }
        }

        // Phase 3: 論理削除（移行完了後に使用）
        if (FirebaseSyncFeatureFlags.useLogicalDelete()) {
          transaction.set(
            docRef,
            {
              'isDeleted': true,
              'deletedAt': FieldValue.serverTimestamp(),
              'updatedAt': FieldValue.serverTimestamp(),
              'serverUpdatedAt': FieldValue.serverTimestamp(),
            },
            SetOptions(merge: true),
          );
          print('✅ Firebase deleteDeck: デッキを論理削除しました - キー: $deckKey');
        } else {
          // 従来: 物理削除
          transaction.delete(docRef);
          print('✅ Firebase deleteDeck: デッキドキュメントを削除しました - キー: $deckKey');
        }
      });

      // トランザクション成功後、デッキ名が取得できていれば関連カードを処理
      if (deckName != null) {
        // デッキに関連するカードを検索（デッキキーではなくデッキ名で検索）
        final cardsSnapshot = await _firestore
            .collection(_cardsCollection())
            .where('deckName', isEqualTo: deckName)
            .get();

        print('🔢 Firebase deleteDeck: 関連カード数: ${cardsSnapshot.docs.length}');

        if (cardsSnapshot.docs.isNotEmpty) {
          // バッチ処理で関連カードを削除/論理削除
          final batch = _firestore.batch();
          for (var doc in cardsSnapshot.docs) {
            if (FirebaseSyncFeatureFlags.useLogicalDelete()) {
              batch.set(
                doc.reference,
                {
                  'isDeleted': true,
                  'deletedAt': FieldValue.serverTimestamp(),
                  'updatedAt': FieldValue.serverTimestamp(),
                  'serverUpdatedAt': FieldValue.serverTimestamp(),
                },
                SetOptions(merge: true),
              );
              print('📝 Firebase deleteDeck: カード論理削除をバッチに追加: ${doc.id}');
            } else {
              batch.delete(doc.reference);
              print('📝 Firebase deleteDeck: カード削除をバッチに追加: ${doc.id}');
            }
          }
          await batch.commit();
          print(
              '✅ Firebase deleteDeck: 関連カードの${FirebaseSyncFeatureFlags.useLogicalDelete() ? "論理削除" : "削除"}が完了しました - ${cardsSnapshot.docs.length}件');
        }

        // キーの一致を確認するための追加確認
        final allDecks = await _firestore.collection(_decksCollection()).get();
        print(
            '🔍 Firebase deleteDeck: 削除後の確認 - 全デッキ数: ${allDecks.docs.length}');

        if (allDecks.docs.isNotEmpty) {
          print('📋 Firebase deleteDeck: 残存するデッキの一覧:');
          for (var doc in allDecks.docs) {
            print('  - ID: ${doc.id}, 名前: ${doc.data()['deckName']}');

            // 削除したはずのデッキが残っていないか確認
            if (doc.data()['deckName'] == deckName) {
              print(
                  '⚠️ Firebase deleteDeck: 削除したはずのデッキがまだ存在します！ ID: ${doc.id}');

              // 同名デッキを強制削除（バグ対策）
              try {
                await _firestore
                    .collection(_decksCollection())
                    .doc(doc.id)
                    .delete();
                print('🔥 Firebase deleteDeck: 同名デッキを強制削除しました - ID: ${doc.id}');
              } catch (deleteError) {
                print('❌ Firebase deleteDeck: 同名デッキの強制削除に失敗: $deleteError');
              }
            }
          }
        }
      }

      print(
          '✅ Firebase deleteDeck: デッキの削除処理が完了しました - $deckName (キー: $deckKey)');
    } catch (e) {
      print('❌ Firebase deleteDeck エラー: $e');
      rethrow; // エラーを再スロー
    }
  }

  // カードの保存（トランザクションとサーバータイムスタンプを使用して更新）
  static Future<void> saveCard(FlashCard card, String userId) async {
    // --- トランザクションを使用しないように変更 ---
    if (userId.isEmpty) {
      if (kDebugMode) {
        print("❌ Firebase saveCard エラー: ユーザーIDが空です");
      }
      return;
    }

    final firestore = FirebaseFirestore.instance;
    // final userDocRef = firestore.collection('users').doc(userId); // 不要
    // final cardsCollectionRef = userDocRef.collection('cards'); // 不要
    DocumentReference docRef;

    // FirestoreドキュメントIDの決定ロジックを統一
    // 優先順位: firestoreId -> id -> 新規生成
    String targetId;
    if (card.firestoreId != null && card.firestoreId!.isNotEmpty) {
      targetId = card.firestoreId!;
    } else if (card.id.isNotEmpty) {
      targetId = card.id;
      card.firestoreId = targetId; // 同期
    } else {
      // どちらもない場合のみ自動採番
      final autoRef = firestore.collection(_cardsCollection()).doc();
      targetId = autoRef.id;
      card.firestoreId = targetId;
      card.id = targetId; // ローカルIDも揃える
    }

    docRef = firestore.collection(_cardsCollection()).doc(targetId);
    if (kDebugMode) {
      if (card.id != targetId) {
        // 念のためローカルIDも合わせる
        card.id = targetId;
      }
      print(
          '📤 Firebase saveCard: 保存ターゲットを決定 - ID: $targetId, デッキ: ${card.deckName}');
    }

    try {
      final cardData = card.toFirestore();

      // 常に最新のサーバータイムスタンプで上書き
      cardData['updatedAt'] = FieldValue.serverTimestamp();
      // Phase 2/3: 差分同期・論理削除の前提フィールド（移行未完了でも追加は安全）
      cardData['serverUpdatedAt'] = FieldValue.serverTimestamp();
      cardData['isDeleted'] = false;
      cardData.remove('deletedAt');

      if (kDebugMode) {
        print("📊 [Firebase saveCard] デバッグ情報 (トランザクション外):");
        print("  カードID: ${card.firestoreId}");
        print("  デッキ名: ${cardData['deckName']}");
        print("  問題文: ${cardData['question']}");
        print("  nextReview (保存データ): ${cardData['nextReview']}");
        print("  repetitions: ${cardData['repetitions']}");
        print("  eFactor: ${cardData['eFactor']}");
        print("  intervalDays: ${cardData['intervalDays']}");
        if (cardData.containsKey('headline')) {
          print("  headline: ${cardData['headline']}");
        } else {
          print("  headline: <NOT SET>");
        }
        if (cardData.containsKey('supplement')) {
          print("  supplement: ${cardData['supplement']}");
        }
        // print("  memorizedFlag: ${cardData['memorizedFlag']}"); // フラグ未使用ならコメントアウト
        print(
            "  updatedAt (保存データ): FieldValue.serverTimestamp()"); // FieldValueなので直接値は見れない
      }

      // SetOptions(merge: true) で既存のフィールドを保持しつつ更新
      await docRef.set(cardData, SetOptions(merge: true));

      if (kDebugMode) {
        _debugPrint("✅ Firebase saveCard: カードの保存/更新が成功しました (トランザクション外)");
      }
    } catch (e, stackTrace) {
      if (kDebugMode) {
        _debugPrint("❌ Firebase saveCard エラー (トランザクション外): $e");
        _debugPrint(stackTrace.toString());
      }
      // エラーを再スローして呼び出し元に伝える
      rethrow;
    }
    // --- トランザクション処理の削除ここまで ---
  }

  // カードの取得
  static Future<List<FlashCard>> getCards({String? deckName}) async {
    Query query = _firestore.collection(_cardsCollection());

    if (deckName != null) {
      query = query.where('deckName', isEqualTo: deckName);
    }

    final snapshot = await query.get();
    return snapshot.docs.map((doc) {
      final Map<String, dynamic> data = doc.data() as Map<String, dynamic>;

      // ★★★ デバッグログと型チェックを追加 ★★★
      final dynamic nextReviewData = data['nextReview']; // dynamic型で受け取る
      print(
          'DBG: nextReview from Firestore: $nextReviewData, Type: ${nextReviewData.runtimeType}'); // ★ 値と型をログ出力

      // ★★★ updatedAt フィールドを読み込む (intとして) ★★★
      final dynamic updatedAtData = data['updatedAt'];
      if (updatedAtData is int) {
      } else if (updatedAtData is Timestamp) {}

      // ★★★ nextReview の処理を改善 ★★★
      DateTime? nextReviewDate;
      final dynamic nextReviewValue = data['nextReview'];
      print('📊 [getCards] nextReview読み込みデバッグ:');
      print('  - 生データ: $nextReviewValue');
      print('  - 型: ${nextReviewValue?.runtimeType}');

      if (nextReviewValue != null) {
        if (nextReviewValue is Timestamp) {
          nextReviewDate = nextReviewValue.toDate();
          print('  - Timestamp -> 日付変換: $nextReviewDate');
        } else {
          print('  ⚠️ 未知の型: ${nextReviewValue.runtimeType}');
        }
      }

      // updatedAtの処理
      final updatedAtValue = data['updatedAt'];
      if (updatedAtValue is Timestamp) {}

      // ★★★ updatedAt の処理を修正 ★★★
      int? updatedAtMillis; // ミリ秒(int?)で保持
      // final dynamic updatedAtValue = data['updatedAt']; // ← リンターエラーのためコメントアウト (既存の変数を使う)
      if (updatedAtValue is Timestamp) {
        // 既存の updatedAtValue を使用
        updatedAtMillis =
            updatedAtValue.millisecondsSinceEpoch; // Timestamp -> int 変換
      } else if (updatedAtValue is int) {
        // 既存の updatedAtValue を使用
        updatedAtMillis = updatedAtValue; // intならそのまま使用
      }
      // else: remains null if neither Timestamp nor int

      final card = FlashCard(
        id: doc.id,
        firestoreId: doc.id,
        question: data['question'] as String? ?? '',
        answer: data['answer'] as String? ?? '',
        explanation: data['explanation'] as String? ?? '',
        deckName: data['deckName'] as String? ?? '',
        chapter: data['chapter'] as String? ?? '',
        nextReview: nextReviewDate,
        repetitions: data['repetitions'] as int? ?? 0,
        eFactor: (data['eFactor'] as num?)?.toDouble() ?? 2.5,
        intervalDays: data['intervalDays'] as int? ?? 0,
        questionEnglishFlag: data['questionEnglishFlag'] as bool? ?? false,
        answerEnglishFlag: data['answerEnglishFlag'] as bool? ?? true,
        updatedAt: updatedAtMillis, // ← 正しい int? 型の値を設定
        headline: data['headline'] as String? ?? '', // ★ headline 追加
        supplement: data['supplement'] as String? ?? '', // ★ supplement 追加
        isDeleted: data['isDeleted'] as bool? ?? false,
        deletedAt: data['deletedAt'] is Timestamp
            ? (data['deletedAt'] as Timestamp).toDate()
            : null,
      );

      // 互換: serverUpdatedAt を優先して firestoreUpdatedAt に入れる
      if (data['serverUpdatedAt'] is Timestamp) {
        card.firestoreUpdatedAt = data['serverUpdatedAt'] as Timestamp;
      } else if (data['updatedAt'] is Timestamp) {
        card.firestoreUpdatedAt = data['updatedAt'] as Timestamp;
      }

      // HiveObjectのkeyプロパティを設定する処理はエラーの原因のため削除
      // ★★★ 注意: このままだとHiveのKeyが設定されない。 ★★★
      // SyncService側で、firestoreIdを使って既存のローカルカードを探し、
      // 見つかったらそのカードのデータを更新(keyは維持)、
      // 見つからなければ新しいカードとしてHiveに追加(新しいkeyが自動付与)する必要がある。
      print(
          '🔍 [FirebaseService.getCards] カード生成: ${card.question.substring(0, min(20, card.question.length))}..., nextReview: ${card.nextReview}'); // ★ ログ追加
      return card;
    }).toList();
  }

  // カードの削除（トランザクションを使用してタイムスタンプを検証）
  static Future<void> deleteCard(String cardKey, {FlashCard? card}) async {
    try {
      print('🗑️ Firebase deleteCard: カード削除開始 - キー: $cardKey');

      // トランザクションを使用して削除
      await _firestore.runTransaction((transaction) async {
        final docRef = _firestore.collection(_cardsCollection()).doc(cardKey);
        final docSnapshot = await transaction.get(docRef);

        if (!docSnapshot.exists) {
          // ドキュメントが存在しない場合は、既に削除されている可能性がある
          print('⚠️ Firebase deleteCard: カードが見つかりません - キー: $cardKey');
          return; // 成功として扱う（既に削除されているため）
        }

        // タイムスタンプの比較が必要な場合（引数でカードオブジェクトが渡された場合）
        if (card != null && card.firestoreUpdatedAt != null) {
          final existingUpdatedAt =
              docSnapshot.data()?['updatedAt'] as Timestamp?;

          if (existingUpdatedAt != null &&
              card.firestoreUpdatedAt! != existingUpdatedAt) {
            // タイムスタンプが一致しない場合は競合エラー
            print('❌ Firebase deleteCard: タイムスタンプの不一致による競合 - キー: $cardKey');
            print(
                '  ローカル更新日時: ${card.firestoreUpdatedAt}, サーバー更新日時: $existingUpdatedAt');

            // 競合通知ストリームにメッセージを送信
            notifySyncConflict('カードが他の端末で更新されています。削除できません。');

            throw FirebaseException(
              plugin: 'cloud_firestore',
              code: 'aborted',
              message: 'カードが他の端末で更新されています。最新のデータを取得してください。',
            );
          }
        }

        // Phase 3: 論理削除（移行完了後に使用）
        if (FirebaseSyncFeatureFlags.useLogicalDelete()) {
          transaction.set(
            docRef,
            {
              'isDeleted': true,
              'deletedAt': FieldValue.serverTimestamp(),
              'updatedAt': FieldValue.serverTimestamp(),
              'serverUpdatedAt': FieldValue.serverTimestamp(),
            },
            SetOptions(merge: true),
          );
          print('✅ Firebase deleteCard: カードを論理削除しました - キー: $cardKey');
        } else {
          // 従来: 物理削除
          transaction.delete(docRef);
          print('✅ Firebase deleteCard: カードを削除しました - キー: $cardKey');
        }
      });
    } catch (e) {
      print('❌ Firebase deleteCard エラー: $e');
      rethrow;
    }
  }

  // デッキに属するすべてのカードを削除
  static Future<void> deleteAllCardsInDeck(String deckName) async {
    try {
      print('Firebase - デッキ「$deckName」のカードをすべて削除します');

      // デッキに属するカードをクエリで取得
      final cardsQuery = _firestore
          .collection(_cardsCollection())
          .where('deckName', isEqualTo: deckName);

      final snapshot = await cardsQuery.get();

      // 削除対象のカード数をログ出力
      print('Firebase - 削除対象のカード: ${snapshot.docs.length}件');

      // バッチ処理で一括削除（最大500件）
      var batch = _firestore.batch();
      int count = 0;

      for (var doc in snapshot.docs) {
        if (FirebaseSyncFeatureFlags.useLogicalDelete()) {
          batch.set(
            doc.reference,
            {
              'isDeleted': true,
              'deletedAt': FieldValue.serverTimestamp(),
              'updatedAt': FieldValue.serverTimestamp(),
              'serverUpdatedAt': FieldValue.serverTimestamp(),
            },
            SetOptions(merge: true),
          );
        } else {
          batch.delete(doc.reference);
        }
        count++;

        // Firestoreのバッチ制限（500操作）に達したら実行
        if (count >= 499) {
          await batch.commit();
          print('Firebase - $count件のカードを削除しました');
          // 新しいバッチを作成
          batch = _firestore.batch();
          count = 0;
        }
      }

      // 残りのバッチを実行
      if (count > 0) {
        await batch.commit();
        print('Firebase - 残り$count件のカードを削除しました');
      }

      print('Firebase - デッキ「$deckName」のカード削除が完了しました');
    } catch (e) {
      print('Firebase - デッキのカード一括削除エラー: $e');
      rethrow;
    }
  }

  // データの同期（ローカルからクラウドへ）
  static Future<void> syncLocalToCloud(
      List<Deck> decks, List<FlashCard> cards) async {
    // デッキの同期
    for (var deck in decks) {
      await saveDeck(deck);
    }

    // カードの同期
    for (var card in cards) {
      await saveCard(card, getUserId()!);
    }
  }

  // データの同期（クラウドからローカルへ）
  static Future<Map<String, dynamic>> syncCloudToLocal() async {
    final decks = await getDecks();
    final cards = await getCards();

    return {
      'decks': decks,
      'cards': cards,
    };
  }

  // ---------------------------------------------------------------------------
  // Phase 2: serverUpdatedAt + docId による差分get（移行完了後に有効化する）
  // ---------------------------------------------------------------------------

  static const String _serverUpdatedAtField = 'serverUpdatedAt';

  static Timestamp? _readServerUpdatedAt(Map<String, dynamic> data) {
    final v = data[_serverUpdatedAtField];
    return v is Timestamp ? v : null;
  }

  static Future<Map<String, dynamic>> syncCloudToLocalDiff({
    int pageSize = 500,
    int maxPages = 200,
  }) async {
    // 互換・安全策: フラグがOFFの間は既存の全件同期を返す（挙動を変えない）
    if (!SyncCursorStore.isServerUpdatedAtSyncEnabled()) {
      return syncCloudToLocal();
    }

    final decks = <Deck>[];
    final cards = <FlashCard>[];

    SyncCursor? deckCursor = SyncCursorStore.loadDecksCursor();
    SyncCursor? cardCursor = SyncCursorStore.loadCardsCursor();

    // decks
    for (int i = 0; i < maxPages; i++) {
      final result = await _fetchDecksDiffPage(cursor: deckCursor, limit: pageSize);
      final List<Deck> items = result['items'] as List<Deck>;
      final SyncCursor? nextCursor = result['nextCursor'] as SyncCursor?;
      final bool hasMore = result['hasMore'] as bool;

      decks.addAll(items);
      deckCursor = nextCursor ?? deckCursor;
      if (!hasMore) break;
    }

    // cards
    for (int i = 0; i < maxPages; i++) {
      final result = await _fetchCardsDiffPage(cursor: cardCursor, limit: pageSize);
      final List<FlashCard> items = result['items'] as List<FlashCard>;
      final SyncCursor? nextCursor = result['nextCursor'] as SyncCursor?;
      final bool hasMore = result['hasMore'] as bool;

      cards.addAll(items);
      cardCursor = nextCursor ?? cardCursor;
      if (!hasMore) break;
    }

    // 注意: カーソルの永続化は「Hiveへの適用成功後」に進めるのが原則。
    // ここでは fetch-only のため保存しない。適用完了後に SyncService 側で保存する。

    return {
      'decks': decks,
      'cards': cards,
      'deckCursor': deckCursor,
      'cardCursor': cardCursor,
    };
  }

  static Future<Map<String, dynamic>> _fetchDecksDiffPage({
    required SyncCursor? cursor,
    required int limit,
  }) async {
    Query<Map<String, dynamic>> query = _firestore
        .collection(_decksCollection())
        .orderBy(_serverUpdatedAtField)
        .orderBy(FieldPath.documentId)
        .limit(limit);

    if (cursor != null) {
      query = query.startAfter([cursor.toTimestamp(), cursor.docId]);
    }

    final snapshot = await query.get();
    final docs = snapshot.docs;

    final items = docs.map((doc) {
      final data = doc.data();
      final deckName = data['deckName'] as String? ?? '';
      final serverUpdatedAt = _readServerUpdatedAt(data);
      return Deck(
        id: doc.id,
        deckName: deckName,
        questionEnglishFlag: data['questionEnglishFlag'] as bool? ?? false,
        answerEnglishFlag: data['answerEnglishFlag'] as bool? ?? false,
        description: data['description'] as String? ?? '',
        isArchived: data['isArchived'] as bool? ?? false,
        isDeleted: data['isDeleted'] as bool? ?? false,
        deletedAt: data['deletedAt'] is Timestamp
            ? (data['deletedAt'] as Timestamp).toDate()
            : null,
        // 互換: 既存の表示や競合処理が firestoreUpdatedAt を参照しているため、ここに入れる
        firestoreUpdatedAt: serverUpdatedAt,
      );
    }).toList();

    SyncCursor? nextCursor;
    if (docs.isNotEmpty) {
      final last = docs.last;
      final lastTs = _readServerUpdatedAt(last.data());
      if (lastTs != null) {
        nextCursor = SyncCursor.fromSnapshot(timestamp: lastTs, docId: last.id);
      }
    }

    return {
      'items': items,
      'nextCursor': nextCursor,
      'hasMore': docs.length == limit,
    };
  }

  static Future<Map<String, dynamic>> _fetchCardsDiffPage({
    required SyncCursor? cursor,
    required int limit,
  }) async {
    Query<Map<String, dynamic>> query = _firestore
        .collection(_cardsCollection())
        .orderBy(_serverUpdatedAtField)
        .orderBy(FieldPath.documentId)
        .limit(limit);

    if (cursor != null) {
      query = query.startAfter([cursor.toTimestamp(), cursor.docId]);
    }

    final snapshot = await query.get();
    final docs = snapshot.docs;

    final items = docs.map((doc) {
      final data = doc.data();

      DateTime? nextReviewDate;
      final dynamic nextReviewValue = data['nextReview'];
      if (nextReviewValue is Timestamp) {
        nextReviewDate = nextReviewValue.toDate();
      } else if (nextReviewValue is int) {
        nextReviewDate = DateTime.fromMillisecondsSinceEpoch(nextReviewValue);
      }

      int? updatedAtMillis;
      final dynamic updatedAtValue = data['updatedAt'];
      if (updatedAtValue is Timestamp) {
        updatedAtMillis = updatedAtValue.millisecondsSinceEpoch;
      } else if (updatedAtValue is int) {
        updatedAtMillis = updatedAtValue;
      } else if (updatedAtValue is double) {
        updatedAtMillis = updatedAtValue.toInt();
      }

      final card = FlashCard(
        id: doc.id,
        firestoreId: doc.id,
        question: data['question'] as String? ?? '',
        answer: data['answer'] as String? ?? '',
        explanation: data['explanation'] as String? ?? '',
        deckName: data['deckName'] as String? ?? '',
        chapter: data['chapter'] as String? ?? '',
        nextReview: nextReviewDate,
        repetitions: data['repetitions'] as int? ?? 0,
        eFactor: (data['eFactor'] as num?)?.toDouble() ?? 2.5,
        intervalDays: data['intervalDays'] as int? ?? 0,
        questionEnglishFlag: data['questionEnglishFlag'] as bool? ?? false,
        answerEnglishFlag: data['answerEnglishFlag'] as bool? ?? true,
        updatedAt: updatedAtMillis,
        headline: data['headline'] as String? ?? '',
        supplement: data['supplement'] as String? ?? '',
        isDeleted: data['isDeleted'] as bool? ?? false,
        deletedAt: data['deletedAt'] is Timestamp
            ? (data['deletedAt'] as Timestamp).toDate()
            : null,
      );

      // 互換: 既存の競合処理が firestoreUpdatedAt を参照している
      card.firestoreUpdatedAt = _readServerUpdatedAt(data);
      return card;
    }).toList();

    SyncCursor? nextCursor;
    if (docs.isNotEmpty) {
      final last = docs.last;
      final lastTs = _readServerUpdatedAt(last.data());
      if (lastTs != null) {
        nextCursor = SyncCursor.fromSnapshot(timestamp: lastTs, docId: last.id);
      }
    }

    return {
      'items': items,
      'nextCursor': nextCursor,
      'hasMore': docs.length == limit,
    };
  }

  // パスワードリセットメールの送信
  static Future<void> sendPasswordResetEmail(String email) async {
    await _auth.sendPasswordResetEmail(email: email);
  }

  // 認証状態の変更を監視するストリーム
  static Stream<User?> get authStateChanges => _auth.authStateChanges();

  // ユーザーを再認証する
  static Future<void> reauthenticate(String password) async {
    try {
      final user = getCurrentUser();
      if (user == null) {
        throw Exception('ユーザーがログインしていません');
      }

      if (user.email == null) {
        throw Exception('ユーザーのメールアドレスが取得できません');
      }

      // 認証情報を作成
      AuthCredential credential = EmailAuthProvider.credential(
        email: user.email!,
        password: password,
      );

      // 再認証を実行
      await user.reauthenticateWithCredential(credential);
      print('✅ Firebase reauthenticate: 再認証成功');
    } catch (e, stackTrace) {
      print('❌ Firebase reauthenticate エラー: $e');
      print('スタックトレース: $stackTrace');
      rethrow;
    }
  }

  // アカウントを削除する
  static Future<void> deleteAccount() async {
    try {
      final user = getCurrentUser();
      if (user == null) {
        throw Exception('ユーザーがログインしていません');
      }

      // ユーザーのデータを削除
      final userId = user.uid;
      print('🗑️ Firebase deleteAccount: アカウント削除を開始 - ユーザーID: $userId');

      // Rules導入後の破壊回避:
      // - クライアント物理deleteを禁止する運用に移行してもアカウント削除が壊れないよう
      //   Cloud Functions（Admin権限）に委譲する。
      try {
        final callable = FirebaseFunctions.instance.httpsCallable('deleteAccountData');
        final result = await callable();
        print('✅ Firebase deleteAccount: deleteAccountData 呼び出し結果: ${result.data}');
      } catch (e) {
        // Functions未導入/未デプロイ時の互換フォールバック（従来挙動）
        print('⚠️ Firebase deleteAccount: deleteAccountData 呼び出しに失敗（従来方式にフォールバック）: $e');

        // ユーザーのデッキを全て削除
        final decksCollection = _firestore.collection('users/$userId/decks');
        final decksSnapshot = await decksCollection.get();
        for (var doc in decksSnapshot.docs) {
          await decksCollection.doc(doc.id).delete();
          print('✅ Firebase deleteAccount: デッキを削除 - ID: ${doc.id}');
        }

        // ユーザーのカードを全て削除
        final cardsCollection = _firestore.collection('users/$userId/cards');
        final cardsSnapshot = await cardsCollection.get();
        for (var doc in cardsSnapshot.docs) {
          await cardsCollection.doc(doc.id).delete();
          print('✅ Firebase deleteAccount: カードを削除 - ID: ${doc.id}');
        }

        // ユーザードキュメント自体を削除
        await _firestore.collection('users').doc(userId).delete();
        print('✅ Firebase deleteAccount: ユーザードキュメントを削除');
      }

      // 最後にFirebaseのユーザーアカウントを削除
      await user.delete();
      print('✅ Firebase deleteAccount: アカウント削除完了');
    } catch (e, stackTrace) {
      print('❌ Firebase deleteAccount エラー: $e');
      print('スタックトレース: $stackTrace');
      rethrow;
    }
  }

  // 共有デッキのコレクションパス
  static const String _sharedDecksCollection = 'shared_decks';

  // デッキを共有する
  static Future<String> shareDeck(String deckName,
      {bool emergencyMode = true}) async {
    try {
      print('FirebaseService.shareDeck: デッキ共有開始 - $deckName');
      print('緊急モード: ${emergencyMode ? "有効" : "無効"}');

      // ユーザーIDの取得
      final userId = FirebaseAuth.instance.currentUser?.uid;
      if (userId == null) {
        throw Exception('ユーザーがログインしていません');
      }

      // ローカルデッキの取得
      final deckBox = HiveService.getDeckBox();
      final decks =
          deckBox.values.where((d) => d.deckName == deckName).toList();

      if (decks.isEmpty) {
        throw Exception('デッキが見つかりません: $deckName');
      }

      final deck = decks.first;
      print(
          'ローカルデッキ情報: ${deck.deckName}, 英語問題=${deck.questionEnglishFlag}, 英語回答=${deck.answerEnglishFlag}');

      // カードの取得
      final cardBox = HiveService.getCardBox();
      final cards =
          cardBox.values.where((card) => card.deckName == deckName).toList();

      print('ローカルカード数: ${cards.length}');

      if (cards.isEmpty) {
        throw Exception('デッキにカードがありません: $deckName');
      }

      // カードデータの詳細なログ出力と検証
      print('=== カードデータ詳細 ===');
      for (int i = 0; i < cards.length; i++) {
        final card = cards[i];
        print('カード #${i + 1}:');
        print('  question: 「${card.question}」 (${card.question.length}文字)');
        print('  answer: 「${card.answer}」 (${card.answer.length}文字)');
        print(
            '  explanation: 「${card.explanation}」 (${card.explanation.length}文字)');
        print('  nextReview: ${card.nextReview}');
        print('  repetitions: ${card.repetitions}');
        print('  eFactor: ${card.eFactor}');
        print('  intervalDays: ${card.intervalDays}');

        // より厳格なデータ検証
        if (card.question.isEmpty) {
          throw Exception('カード #${i + 1} の問題文が空です');
        }
        if (card.answer.isEmpty) {
          throw Exception('カード #${i + 1} の回答が空です');
        }

        // 特殊文字や長すぎるテキストの検証
        if (card.question.length > 1000) {
          throw Exception(
              'カード #${i + 1} の問題文が長すぎます (${card.question.length}文字)');
        }
        if (card.answer.length > 1000) {
          throw Exception('カード #${i + 1} の回答が長すぎます (${card.answer.length}文字)');
        }
        if (card.explanation.length > 2000) {
          throw Exception(
              'カード #${i + 1} の説明が長すぎます (${card.explanation.length}文字)');
        }
      }

      // 安全な変換関数
      String safeString(dynamic value) {
        if (value == null) return '';
        // 特殊文字や制御文字を除去
        String result = value.toString();
        // 非表示文字や制御文字を削除
        result = result.replaceAll(RegExp(r'[\u0000-\u001F\u007F-\u009F]'), '');
        return result;
      }

      bool safeBool(dynamic value) => value == true;

      // 共有デッキデータの作成
      print('共有デッキデータの作成を開始...');
      final List<Map<String, dynamic>> processedCards = [];

      for (int i = 0; i < cards.length; i++) {
        final card = cards[i];
        try {
          Map<String, dynamic> cardData;

          if (emergencyMode) {
            // 緊急モード：特殊文字を全て除去して最小限のデータのみを含める
            String sanitizeCompletely(String? text) {
              if (text == null) return '';
              // 英数字、ひらがな、カタカナ、漢字、基本的な記号のみを許可
              return text
                  .replaceAll(
                      RegExp(r'[^\p{L}\p{N}\p{Z}\p{P}]', unicode: true), '')
                  .trim()
                  .substring(0, text.length < 500 ? text.length : 500);
            }

            cardData = {
              'question': sanitizeCompletely(card.question),
              'answer': sanitizeCompletely(card.answer),
              // 説明は省略
              'explanation': '',
            };
          } else {
            // 通常モード
            cardData = {
              'question': safeString(card.question),
              'answer': safeString(card.answer),
              'explanation': safeString(card.explanation),
            };
          }

          processedCards.add(cardData);
          print('カード #${i + 1} の処理成功');
        } catch (e) {
          print('カード #${i + 1} の処理中にエラー: $e');
          if (emergencyMode) {
            // 緊急モードでもエラーが発生した場合は、完全に最小限のデータを使用
            processedCards.add({
              'question': 'カード #${i + 1}',
              'answer': 'データ処理エラー',
              'explanation': '',
            });
            print('カード #${i + 1} を最小データで置換しました');
          } else {
            throw Exception('カード #${i + 1} の処理中にエラーが発生しました: $e');
          }
        }
      }

      print('カードデータの処理完了。処理済みカード数: ${processedCards.length}');

      final sharedDeckData = {
        'userId': userId,
        'deckName': safeString(deck.deckName),
        'questionEnglishFlag': safeBool(deck.questionEnglishFlag),
        'answerEnglishFlag': safeBool(deck.answerEnglishFlag),
        'description': safeString(deck.description),
        'createdAt': FieldValue.serverTimestamp(),
        'cards': processedCards,
      };

      print('最終的な共有データ構造:');
      print('  userId: $userId');
      print('  deckName: ${safeString(deck.deckName)}');
      print('  questionEnglishFlag: ${safeBool(deck.questionEnglishFlag)}');
      print('  answerEnglishFlag: ${safeBool(deck.answerEnglishFlag)}');
      print('  description: ${safeString(deck.description)}');
      print('  cards: ${processedCards.length}枚');

      // Firestoreに保存 (同じユーザーが同じデッキ名を共有済みなら上書き)
      print('Firestoreへの保存を開始 (既存ドキュメントの有無を確認)...');

      final collectionRef =
          FirebaseFirestore.instance.collection(_sharedDecksCollection);

      // userId と deckName で既存を検索（複合インデックスが無い環境向けに deckName はアプリ側でフィルタ）
      final querySnapshot =
          await collectionRef.where('userId', isEqualTo: userId).get();

      DocumentReference<Map<String, dynamic>>? targetDoc;

      for (var doc in querySnapshot.docs) {
        final data = doc.data();
        if (data['deckName'] == safeString(deck.deckName)) {
          targetDoc = doc.reference;
          break;
        }
      }

      if (targetDoc != null) {
        // 既存あり → 上書き
        print('既存の共有デッキが見つかりました(ID=${targetDoc.id})。上書きします。');
        await targetDoc.set(sharedDeckData);
        print('共有デッキを上書きしました: ${targetDoc.id}');
        return targetDoc.id;
      } else {
        // 既存なし → 新規追加
        final docRef = await collectionRef.add(sharedDeckData);
        print('共有デッキを新規作成しました: ${docRef.id}');
        return docRef.id;
      }
    } catch (e, stackTrace) {
      print('デッキ共有エラー: $e');
      print('スタックトレース: $stackTrace');
      throw Exception('デッキの共有に失敗しました: $e');
    }
  }

  // 共有デッキの一覧を取得
  static Future<List<Map<String, dynamic>>> getSharedDecks() async {
    try {
      print('共有デッキ一覧の取得を開始...');

      // インデックスが作成されるまでの一時的な対応策
      // 1. orderByを使わずにデータを取得
      final snapshot = await _firestore
          .collection(_sharedDecksCollection)
          .limit(50) // 件数制限をかける
          .get();

      print('取得した共有デッキ数: ${snapshot.docs.length}');

      // 2. 結果をアプリ側でソートする
      final docs = snapshot.docs.toList()
        ..sort((a, b) {
          final aTime = a.data()['createdAt']?.toDate() ?? DateTime(1970);
          final bTime = b.data()['createdAt']?.toDate() ?? DateTime(1970);
          return bTime.compareTo(aTime); // 降順
        });

      final result = docs.map((doc) {
        final data = doc.data();
        print('デッキデータID ${doc.id} の構造: ${data.keys.toList()}');

        // データ構造をログ出力（デバッグ用）
        if (data.containsKey('deckName')) {
          print('  deckName: ${data['deckName']}');
        } else if (data.containsKey('deckInfo')) {
          print('  deckInfo.deckName: ${data['deckInfo']?['deckName']}');
        } else {
          print('  デッキ名が見つかりません。利用可能なキー: ${data.keys.toList()}');
        }

        // カード数の取得
        int cardCount = 0;
        if (data.containsKey('cards') && data['cards'] is List) {
          cardCount = (data['cards'] as List).length;
          print('  カード数: $cardCount');
        }

        // 両方の形式に対応（互換性のため）
        final deckName = data.containsKey('deckInfo')
            ? (data['deckInfo'] != null ? data['deckInfo']['deckName'] : null)
            : data['deckName'];

        if (deckName == null) {
          print('  警告: デッキ名がnullです。データ: $data');
        }

        return {
          'id': doc.id,
          'deckName': deckName ?? '名前なし',
          'description': data['description'] ?? '',
          'cardCount': cardCount,
          'createdBy': data['userId'] ?? data['createdBy'] ?? '不明',
          'createdAt': data['createdAt']?.toDate(),
          'downloadCount': data['downloadCount'] ?? 0,
        };
      }).toList();

      print('共有デッキ一覧の取得が完了しました。結果: ${result.length}件');
      return result;
    } catch (e, stackTrace) {
      print('共有デッキ一覧の取得に失敗: $e');
      print('スタックトレース: $stackTrace');
      throw Exception('共有デッキの取得に失敗しました: $e');
    }
  }

  // 共有デッキをダウンロード
  static Future<void> downloadSharedDeck(String sharedDeckId) async {
    try {
      final userId = getUserId();
      if (userId == null) throw Exception('ユーザーがログインしていません');

      print('共有デッキのダウンロードを開始: ID=$sharedDeckId');

      // 共有デッキのデータを取得
      final docSnapshot = await _firestore
          .collection(_sharedDecksCollection)
          .doc(sharedDeckId)
          .get();

      if (!docSnapshot.exists) {
        throw Exception('共有デッキが見つかりません');
      }

      final data = docSnapshot.data()!;
      print('デッキデータの構造: ${data.keys.toList()}');

      // デッキ情報の取得（両方の形式に対応）
      String deckName;
      bool questionEnglishFlag = false;
      bool answerEnglishFlag = false;
      String description = '';

      if (data.containsKey('deckInfo')) {
        // 古い形式
        final deckInfo = data['deckInfo'];
        deckName = deckInfo['deckName'];
        questionEnglishFlag = deckInfo['questionEnglishFlag'] ?? false;
        answerEnglishFlag = deckInfo['answerEnglishFlag'] ?? false;
        description = deckInfo['description'] ?? '';
      } else {
        // 新しい形式
        deckName = data['deckName'];
        questionEnglishFlag = data['questionEnglishFlag'] ?? false;
        answerEnglishFlag = data['answerEnglishFlag'] ?? false;
        description = data['description'] ?? '';
      }

      print('ダウンロードするデッキ名: $deckName');
      print('デッキの説明: $description');

      // 既存のデッキ名と重複しないようにする
      String uniqueDeckName = deckName;
      final existingDecks = await getDecks();
      int counter = 1;

      while (existingDecks.any((d) => d.deckName == uniqueDeckName)) {
        uniqueDeckName = '$deckName ($counter)';
        counter++;
      }

      print('一意のデッキ名: $uniqueDeckName');

      // 新しいデッキを作成
      final newDeck = Deck(
        id: HiveService().generateUniqueId(),
        deckName: uniqueDeckName,
        questionEnglishFlag: questionEnglishFlag,
        answerEnglishFlag: answerEnglishFlag,
        description: description,
      );

      // デッキを保存（Firestore）
      await saveDeck(newDeck);
      print('Firestoreに新しいデッキを保存しました: $uniqueDeckName');

      // ローカルにも同じデッキを保存
      final deckBox = HiveService.getDeckBox();
      await deckBox.put(newDeck.id, newDeck);
      print('ローカル(Hive)にデッキを保存しました: $uniqueDeckName (ID=${newDeck.id})');

      // カード情報の取得と保存
      final cards = data['cards'] as List;
      print('カード数: ${cards.length}');

      if (cards.isEmpty) {
        print('警告: カードが存在しません');
      }

      int savedCardCount = 0;
      int hiveCardCount = 0;
      final cardBox = HiveService.getCardBox();

      for (var cardData in cards) {
        print(
            'カードデータ処理: ${cardData.toString().substring(0, min(50, cardData.toString().length))}...');

        try {
          final newCard = FlashCard(
            id: HiveService().generateUniqueId(),
            question: cardData['question'] ?? '',
            answer: cardData['answer'] ?? '',
            explanation: cardData['explanation'] ?? '',
            deckName: uniqueDeckName,
            questionEnglishFlag: cardData['questionEnglishFlag'] ?? false,
            answerEnglishFlag: cardData['answerEnglishFlag'] ?? true,
            updatedAt: cardData['updatedAt'] is Timestamp
                ? (cardData['updatedAt'] as Timestamp).millisecondsSinceEpoch
                : (cardData['updatedAt'] is int
                    ? cardData['updatedAt'] as int
                    : null), // フォールバックとしてintも考慮
          );

          // Firestoreにカードを保存
          await saveCard(newCard, getUserId()!);
          savedCardCount++;

          // ローカル(Hive)にもカードを保存
          await cardBox.put(newCard.id, newCard);
          hiveCardCount++;

          if (savedCardCount % 10 == 0 || savedCardCount == cards.length) {
            print('進捗: $savedCardCount / ${cards.length} カードを保存しました');
          }
        } catch (e) {
          print('カード保存エラー: $e');
          print('問題のあるカードデータ: $cardData');
        }
      }

      print('Firestoreに保存したカード数: $savedCardCount');
      print('Hiveに保存したカード数: $hiveCardCount');

      // ローカルのデッキとカードの数を確認
      final localDecks = deckBox.values.toList();
      final localCards =
          cardBox.values.where((c) => c.deckName == uniqueDeckName).toList();
      print('ローカルデッキ数: ${localDecks.length}');
      print('ダウンロードしたデッキのカード数: ${localCards.length}');

      // ダウンロード数をインクリメント
      await _firestore
          .collection(_sharedDecksCollection)
          .doc(sharedDeckId)
          .update({
        'downloadCount': FieldValue.increment(1),
      });

      print('ダウンロード数を更新しました');
      print('共有デッキのダウンロードが完了しました: $uniqueDeckName');
    } catch (e, stackTrace) {
      print('共有デッキのダウンロードに失敗: $e');
      print('スタックトレース: $stackTrace');
      throw Exception('共有デッキのダウンロードに失敗しました: $e');
    }
  }

  // 自分が共有したデッキの一覧を取得
  static Future<List<Map<String, dynamic>>> getMySharedDecks() async {
    try {
      final userId = getUserId();
      if (userId == null) throw Exception('ユーザーがログインしていません');

      print('自分の共有デッキ一覧の取得を開始... ユーザーID: $userId');

      // インデックスが作成されるまでの一時的な対応策
      // 1. まずはuserIdでのフィルタリングだけを行う（orderByは使わない）
      final snapshot = await _firestore
          .collection(_sharedDecksCollection)
          .where('userId', isEqualTo: userId)
          .get();

      print('取得した自分の共有デッキ数: ${snapshot.docs.length}');

      // 2. 結果をアプリ側でソートする
      final docs = snapshot.docs.toList()
        ..sort((a, b) {
          final aTime = a.data()['createdAt']?.toDate() ?? DateTime(1970);
          final bTime = b.data()['createdAt']?.toDate() ?? DateTime(1970);
          return bTime.compareTo(aTime); // 降順
        });

      final result = docs.map((doc) {
        final data = doc.data();
        print('デッキデータID ${doc.id} の構造: ${data.keys.toList()}');

        // カード数の取得
        int cardCount = 0;
        if (data.containsKey('cards') && data['cards'] is List) {
          cardCount = (data['cards'] as List).length;
        }

        // 両方の形式に対応（互換性のため）
        final deckName = data.containsKey('deckInfo')
            ? (data['deckInfo'] != null ? data['deckInfo']['deckName'] : null)
            : data['deckName'];

        return {
          'id': doc.id,
          'deckName': deckName ?? '名前なし',
          'description': data['description'] ?? '',
          'cardCount': cardCount,
          'createdAt': data['createdAt']?.toDate(),
          'downloadCount': data['downloadCount'] ?? 0,
        };
      }).toList();

      print('自分の共有デッキ一覧の取得が完了しました。結果: ${result.length}件');
      return result;
    } catch (e, stackTrace) {
      print('自分の共有デッキ一覧の取得に失敗: $e');
      print('スタックトレース: $stackTrace');
      throw Exception('自分の共有デッキの取得に失敗しました: $e');
    }
  }

  // 共有デッキを削除
  static Future<void> deleteSharedDeck(String sharedDeckId) async {
    try {
      final userId = getUserId();
      if (userId == null) throw Exception('ユーザーがログインしていません');

      print('共有デッキの削除を開始: ID=$sharedDeckId');

      // 共有デッキの所有者を確認
      final docSnapshot = await _firestore
          .collection(_sharedDecksCollection)
          .doc(sharedDeckId)
          .get();

      if (!docSnapshot.exists) {
        throw Exception('共有デッキが見つかりません');
      }

      final data = docSnapshot.data()!;
      print('削除対象データの構造: ${data.keys.toList()}');

      // 所有者の確認（新旧両方の形式に対応）
      final ownerId = data['userId'] ?? data['createdBy'];
      if (ownerId == null) {
        print('警告: 所有者IDが見つかりません。データ: $data');
        throw Exception('共有デッキの所有者情報が不明です');
      }

      if (ownerId != userId) {
        print('権限エラー: 現在のユーザーID=$userId, 所有者ID=$ownerId');
        throw Exception('この共有デッキを削除する権限がありません');
      }

      print('削除権限を確認しました。削除を実行します...');

      // 共有デッキを削除
      await _firestore
          .collection(_sharedDecksCollection)
          .doc(sharedDeckId)
          .delete();

      print('共有デッキの削除が完了しました: ID=$sharedDeckId');
    } catch (e, stackTrace) {
      print('共有デッキの削除に失敗: $e');
      print('スタックトレース: $stackTrace');
      throw Exception('共有デッキの削除に失敗しました: $e');
    }
  }

  // Firebaseのセキュリティルールを確認するためのテストメソッド
  static Future<bool> testFirebaseAccess() async {
    try {
      // ユーザーIDの取得
      final userId = getUserId();
      if (userId == null) {
        print('テスト失敗: ユーザーがログインしていません');
        return false;
      }

      print('テスト開始: ユーザーID=$userId');

      // 共有デッキコレクションへの書き込みテスト
      final testData = {
        'testField': 'テストデータ',
        'userId': userId,
        'timestamp': FieldValue.serverTimestamp(),
      };

      // テスト用ドキュメントの作成
      final docRef =
          await _firestore.collection(_sharedDecksCollection).add(testData);
      print('テスト用ドキュメント作成成功: ID=${docRef.id}');

      // テスト用ドキュメントの読み取り
      final docSnapshot = await _firestore
          .collection(_sharedDecksCollection)
          .doc(docRef.id)
          .get();
      if (!docSnapshot.exists) {
        print('テスト失敗: ドキュメントが読み取れません');
        return false;
      }

      print('テスト用ドキュメント読み取り成功');

      // テスト用ドキュメントの削除
      await _firestore
          .collection(_sharedDecksCollection)
          .doc(docRef.id)
          .delete();
      print('テスト用ドキュメント削除成功');

      print('テスト成功: Firebaseへのアクセスは正常です');
      return true;
    } catch (e, stackTrace) {
      print('テスト失敗: Firebaseアクセスエラー: $e');
      print('スタックトレース: $stackTrace');
      return false;
    }
  }

  // 共有デッキのダウンロードをテストする（デバッグ用）
  static Future<Map<String, dynamic>> testDownloadSharedDeck(
      String sharedDeckId) async {
    try {
      print('共有デッキのダウンロードテストを開始: ID=$sharedDeckId');

      // ユーザーIDの確認
      final userId = getUserId();
      if (userId == null) {
        return {
          'success': false,
          'message': 'ユーザーがログインしていません',
          'data': null,
        };
      }

      // 共有デッキのデータを取得
      final docSnapshot = await _firestore
          .collection(_sharedDecksCollection)
          .doc(sharedDeckId)
          .get();

      if (!docSnapshot.exists) {
        return {
          'success': false,
          'message': '共有デッキが見つかりません: ID=$sharedDeckId',
          'data': null,
        };
      }

      // データの構造を確認
      final data = docSnapshot.data()!;
      final dataKeys = data.keys.toList();

      // デッキ名を取得
      String? deckName;
      Map<String, dynamic>? deckInfo;
      List? cards;

      if (data.containsKey('deckInfo')) {
        deckInfo = Map<String, dynamic>.from(data['deckInfo']);
        deckName = deckInfo['deckName'];
      } else if (data.containsKey('deckName')) {
        deckName = data['deckName'];
      }

      if (data.containsKey('cards') && data['cards'] is List) {
        cards = data['cards'] as List;
      }

      // 既存のHiveデータを確認
      final deckBox = HiveService.getDeckBox();
      final cardBox = HiveService.getCardBox();
      final existingDecks = deckBox.values.map((d) => d.deckName).toList();

      return {
        'success': true,
        'message': 'テスト成功: デッキのデータ取得完了',
        'data': {
          'deckId': sharedDeckId,
          'deckName': deckName,
          'hasCards': cards != null,
          'cardCount': cards?.length ?? 0,
          'dataKeys': dataKeys,
          'deckInfo': deckInfo,
          'existingDecks': existingDecks,
          'existingDeckCount': deckBox.length,
          'totalCardCount': cardBox.length,
        }
      };
    } catch (e, stackTrace) {
      print('共有デッキのダウンロードテストに失敗: $e');
      print('スタックトレース: $stackTrace');
      return {
        'success': false,
        'message': 'テスト失敗: $e',
        'error': e.toString(),
        'stackTrace': stackTrace.toString(),
      };
    }
  }

  // リアルタイム更新のためのStreamController
  static final StreamController<Map<String, dynamic>> _dataChangeController =
      StreamController<Map<String, dynamic>>.broadcast();

  // リアルタイムリスナーの登録状態
  static bool _isListening = false;

  // リアルタイム購読（必ず保持してcancelできるようにする）
  static StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
      _decksRealtimeSubscription;
  static StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
      _cardsRealtimeSubscription;

  // リアルタイムリスナーの登録
  static void startRealTimeSync() {
    if (_isListening) return;
    if (getUserId() == null) return;

    _isListening = true;

    // 念のため既存購読を解除（stopが呼ばれずに再startされたケースに備える）
    _decksRealtimeSubscription?.cancel();
    _decksRealtimeSubscription = null;
    _cardsRealtimeSubscription?.cancel();
    _cardsRealtimeSubscription = null;

    // デッキの変更を監視
    //
    // Phase 4: 差分購読（カーソル以降のみ）
    final SyncCursor? deckCursor =
        SyncCursorStore.isServerUpdatedAtSyncEnabled() ? SyncCursorStore.loadDecksCursor() : null;
    Query<Map<String, dynamic>> decksQuery =
        _firestore.collection(_decksCollection());
    if (SyncCursorStore.isServerUpdatedAtSyncEnabled()) {
      decksQuery = decksQuery
          .orderBy(_serverUpdatedAtField)
          .orderBy(FieldPath.documentId);
      if (deckCursor != null) {
        decksQuery = decksQuery.startAfter([deckCursor.toTimestamp(), deckCursor.docId]);
      }
    }

    _decksRealtimeSubscription =
        decksQuery.snapshots(includeMetadataChanges: true).listen((snapshot) {
      for (var change in snapshot.docChanges) {
        final deckData = change.doc.data()!;
        final Timestamp? serverUpdatedAt =
            deckData[_serverUpdatedAtField] is Timestamp ? deckData[_serverUpdatedAtField] as Timestamp : null;
        final deck = Deck(
          id: change.doc.id,
          deckName: deckData['deckName'] as String? ?? '不明なデッキ',
          questionEnglishFlag:
              deckData['questionEnglishFlag'] as bool? ?? false,
          answerEnglishFlag: deckData['answerEnglishFlag'] as bool? ?? false,
          description: deckData['description'] as String? ?? '',
          isArchived:
              deckData['isArchived'] as bool? ?? false, // ★ isArchived を追加
          isDeleted: deckData['isDeleted'] as bool? ?? false,
          deletedAt: deckData['deletedAt'] is Timestamp
              ? (deckData['deletedAt'] as Timestamp).toDate()
              : null,
          firestoreUpdatedAt: serverUpdatedAt ??
              (deckData['updatedAt'] is Timestamp ? deckData['updatedAt'] as Timestamp : null),
        );

        _dataChangeController.add({
          'type': 'deck',
          'changeType': change.type.toString(),
          'data': deck,
          // Phase 4: カーソル前進用メタ情報
          'meta': <String, dynamic>{
            'docId': change.doc.id,
            'serverUpdatedAt': serverUpdatedAt,
            'hasPendingWrites': change.doc.metadata.hasPendingWrites,
          },
        });
      }
    });

    // カードの変更を監視
    final SyncCursor? cardCursor =
        SyncCursorStore.isServerUpdatedAtSyncEnabled() ? SyncCursorStore.loadCardsCursor() : null;
    Query<Map<String, dynamic>> cardsQuery =
        _firestore.collection(_cardsCollection());
    if (SyncCursorStore.isServerUpdatedAtSyncEnabled()) {
      cardsQuery = cardsQuery
          .orderBy(_serverUpdatedAtField)
          .orderBy(FieldPath.documentId);
      if (cardCursor != null) {
        cardsQuery = cardsQuery.startAfter([cardCursor.toTimestamp(), cardCursor.docId]);
      }
    }

    _cardsRealtimeSubscription =
        cardsQuery.snapshots(includeMetadataChanges: true).listen((snapshot) {
      for (var change in snapshot.docChanges) {
        final cardData = change.doc.data()!;
        final Timestamp? serverUpdatedAt =
            cardData[_serverUpdatedAtField] is Timestamp ? cardData[_serverUpdatedAtField] as Timestamp : null;

        // ★★★ nextReview の処理を修正 (コンストラクタ呼び出しの前に移動) ★★★
        DateTime? nextReviewDate;
        final dynamic nextReviewValue = cardData['nextReview'];
        if (nextReviewValue is Timestamp) {
          nextReviewDate = nextReviewValue.toDate();
        } else if (nextReviewValue is int) {
          nextReviewDate = DateTime.fromMillisecondsSinceEpoch(nextReviewValue);
        }

        // ★★★ updatedAt の処理 (getCardsと同様のロジックだが、ここでは既に適用済みのはず) ★★★
        int? updatedAtMillis;
        final dynamic updatedAtValue = cardData['updatedAt'];
        if (updatedAtValue is Timestamp) {
          updatedAtMillis = updatedAtValue.millisecondsSinceEpoch;
        } else if (updatedAtValue is int) {
          updatedAtMillis = updatedAtValue;
        }

        final card = FlashCard(
          id: change.doc.id,
          firestoreId: change.doc.id,
          question: cardData['question'] as String? ?? '',
          answer: cardData['answer'] as String? ?? '',
          explanation: cardData['explanation'] as String? ?? '',
          deckName: cardData['deckName'] as String? ?? '',
          chapter: cardData['chapter'] as String? ?? '',
          nextReview: nextReviewDate, // <--- 事前に計算した値を使用
          repetitions: cardData['repetitions'] as int? ?? 0,
          eFactor: (cardData['eFactor'] as num?)?.toDouble() ?? 2.5,
          intervalDays: cardData['intervalDays'] as int? ?? 0,
          questionEnglishFlag:
              cardData['questionEnglishFlag'] as bool? ?? false,
          answerEnglishFlag: cardData['answerEnglishFlag'] as bool? ?? true,
          updatedAt: updatedAtMillis, // <--- 事前に計算した値を使用 (型は int?)
          headline: cardData['headline'] as String? ?? '', // ★ headline 追加
          supplement:
              cardData['supplement'] as String? ?? '', // ★ supplement 追加
          isDeleted: cardData['isDeleted'] as bool? ?? false,
          deletedAt: cardData['deletedAt'] is Timestamp
              ? (cardData['deletedAt'] as Timestamp).toDate()
              : null,
        );
        // 互換: serverUpdatedAt を優先して firestoreUpdatedAt に入れる
        card.firestoreUpdatedAt = serverUpdatedAt ??
            (cardData['updatedAt'] is Timestamp ? cardData['updatedAt'] as Timestamp : null);

        _dataChangeController.add({
          'type': 'card',
          'changeType': change.type.toString(),
          'data': card,
          // Phase 4: カーソル前進用メタ情報
          'meta': <String, dynamic>{
            'docId': change.doc.id,
            'serverUpdatedAt': serverUpdatedAt,
            'hasPendingWrites': change.doc.metadata.hasPendingWrites,
          },
        });
      }
    });
  }

  // リアルタイムリスナーの登録解除
  static void stopRealTimeSync() {
    _isListening = false;
    // StreamControllerはクローズせず、再利用できるようにしておく
    _decksRealtimeSubscription?.cancel();
    _decksRealtimeSubscription = null;
    _cardsRealtimeSubscription?.cancel();
    _cardsRealtimeSubscription = null;
  }

  // Firebaseリソースの解放
  static void dispose() {
    stopRealTimeSync();
    _dataChangeController.close();
    _syncConflictController.close();
  }

  // デッキ名からFirebase上のデッキを検索して、ドキュメントIDを返す
  static Future<String?> findDeckByName(String deckName) async {
    try {
      print('🔍 Firebase findDeckByName: デッキ名で検索: $deckName');

      final snapshot = await _firestore
          .collection(_decksCollection())
          .where('deckName', isEqualTo: deckName)
          .get();

      if (snapshot.docs.isEmpty) {
        print('ℹ️ Firebase findDeckByName: デッキが見つかりません: $deckName');
        return null;
      }

      // 最初に見つかったドキュメントのIDを返す
      final docId = snapshot.docs.first.id;
      print('✅ Firebase findDeckByName: デッキを発見: $deckName, ID: $docId');
      return docId;
    } catch (e) {
      print('❌ Firebase findDeckByName エラー: $e');
      return null;
    }
  }

  // 指定されたパス（ドキュメントID）のデッキを削除
  static Future<void> deleteDeckByPath(String docId) async {
    try {
      print('🗑️ Firebase deleteDeckByPath: デッキを削除: ID=$docId');

      // まずデッキ情報を取得して、デッキ名を確認
      final deckDoc =
          await _firestore.collection(_decksCollection()).doc(docId).get();

      if (!deckDoc.exists) {
        print('⚠️ Firebase deleteDeckByPath: デッキが見つかりません: ID=$docId');
        return;
      }

      final deckData = deckDoc.data() as Map<String, dynamic>;
      final deckName = deckData['deckName'] as String;

      // デッキドキュメントを削除/論理削除
      if (FirebaseSyncFeatureFlags.useLogicalDelete()) {
        await _firestore.collection(_decksCollection()).doc(docId).set(
          {
            'isDeleted': true,
            'deletedAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
            'serverUpdatedAt': FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true),
        );
        print('✅ Firebase deleteDeckByPath: デッキを論理削除: ID=$docId');
      } else {
        await _firestore.collection(_decksCollection()).doc(docId).delete();
        print('✅ Firebase deleteDeckByPath: デッキドキュメントを削除: ID=$docId');
      }

      // デッキに関連するカードを検索して削除
      final cardsSnapshot = await _firestore
          .collection(_cardsCollection())
          .where('deckName', isEqualTo: deckName)
          .get();

      print(
          '🔢 Firebase deleteDeckByPath: 関連カード数: ${cardsSnapshot.docs.length}');

      if (cardsSnapshot.docs.isNotEmpty) {
        // バッチ処理で関連カードを削除/論理削除
        final batch = _firestore.batch();
        for (var doc in cardsSnapshot.docs) {
          if (FirebaseSyncFeatureFlags.useLogicalDelete()) {
            batch.set(
              doc.reference,
              {
                'isDeleted': true,
                'deletedAt': FieldValue.serverTimestamp(),
                'updatedAt': FieldValue.serverTimestamp(),
                'serverUpdatedAt': FieldValue.serverTimestamp(),
              },
              SetOptions(merge: true),
            );
            print('📝 Firebase deleteDeckByPath: カード論理削除をバッチに追加: ${doc.id}');
          } else {
            batch.delete(doc.reference);
            print('📝 Firebase deleteDeckByPath: カード削除をバッチに追加: ${doc.id}');
          }
        }
        await batch.commit();
        print(
            '✅ Firebase deleteDeckByPath: 関連カードの${FirebaseSyncFeatureFlags.useLogicalDelete() ? "論理削除" : "削除"}完了: ${cardsSnapshot.docs.length}件');
      }

      print('✅ Firebase deleteDeckByPath: デッキの削除処理完了: $deckName (ID=$docId)');
    } catch (e) {
      print('❌ Firebase deleteDeckByPath エラー: $e');
      rethrow;
    }
  }

  // ★★★ ハンドルネーム取得メソッドを追加 ★★★
  static Future<String?> getHandleName() async {
    final userId = getUserId();
    if (userId == null) return null;
    try {
      final docSnapshot =
          await _firestore.collection('users').doc(userId).get();
      if (docSnapshot.exists && docSnapshot.data()!.containsKey('handleName')) {
        return docSnapshot.data()!['handleName'] as String?;
      }
    } catch (e) {
      print('ハンドルネーム取得エラー: $e');
    }
    return null; // エラー時や存在しない場合はnullを返す
  }

  // ★★★ ハンドルネーム更新メソッドを追加 ★★★
  static Future<void> updateHandleName(String newHandleName) async {
    final userId = getUserId();
    if (userId == null) throw Exception('ユーザーがログインしていません');
    try {
      await _firestore.collection('users').doc(userId).set(
        {'handleName': newHandleName},
        SetOptions(merge: true), // 既存のフィールドを保持しつつ更新
      );
      print('ハンドルネームを更新しました: $newHandleName');
    } catch (e) {
      print('ハンドルネーム更新エラー: $e');
      rethrow;
    }
  }

  // データ変更を通知するStream
  static Stream<Map<String, dynamic>> get dataChangeStream =>
      _dataChangeController.stream;

  // 競合通知用のStreamController
  static final StreamController<String> _syncConflictController =
      StreamController<String>.broadcast();

  // 競合通知を流すメソッド
  static void notifySyncConflict(String message) {
    _syncConflictController.add(message);
  }

  // 競合通知を受け取るためのストリーム
  static Stream<String> get syncConflictStream =>
      _syncConflictController.stream;

  // Firestoreから特定のカードを取得する (firestoreIdで指定)
  static Future<FlashCard?> getCard(String firestoreId) async {
    // ... (existing code) ...
  }

  // ★★★ こちらのdeleteAllUserFirestoreDataメソッドを残す ★★★
  static Future<void> deleteAllUserFirestoreData(String userId) async {
    print(
        'FirebaseService: deleteAllUserFirestoreData for userId: $userId を呼び出しました。');
    try {
      final firestore = FirebaseFirestore.instance;

      // Rules導入後に備えて Functions を優先
      try {
        final callable = FirebaseFunctions.instance.httpsCallable('deleteAccountData');
        final result = await callable();
        print('  ✅ Functions deleteAccountData 結果: ${result.data}');
        return;
      } catch (e) {
        print('  ⚠️ Functions deleteAccountData が使えないため従来方式で続行: $e');
      }

      // 1. ユーザーの全デッキを削除 (users/{userId}/decks)
      final decksCollection =
          firestore.collection('users').doc(userId).collection('decks');
      final decksSnapshot = await decksCollection.get();
      final WriteBatch deckBatch = firestore.batch();
      for (var doc in decksSnapshot.docs) {
        deckBatch.delete(doc.reference);
      }
      await deckBatch.commit();
      print(
          '  ✅ Firestoreからユーザーの全デッキ (${decksSnapshot.docs.length}件) を削除しました。');

      // 2. ユーザーの全カードを削除 (users/{userId}/cards)
      final cardsCollection =
          firestore.collection('users').doc(userId).collection('cards');
      final cardsSnapshot = await cardsCollection.get();
      final WriteBatch cardBatch = firestore.batch();
      for (var doc in cardsSnapshot.docs) {
        cardBatch.delete(doc.reference);
      }
      await cardBatch.commit();
      print(
          '  ✅ Firestoreからユーザーの全カード (${cardsSnapshot.docs.length}件) を削除しました。');

      // 3. ユーザードキュメント自体を削除 (users/{userId})
      await firestore.collection('users').doc(userId).delete();
      print('  ✅ Firestoreからユーザードキュメントを削除しました。');

      print('FirebaseService: deleteAllUserFirestoreData の処理が正常に完了しました。');
    } catch (e, stackTrace) {
      print('❌ FirebaseService: deleteAllUserFirestoreData でエラーが発生しました: $e');
      print('スタックトレース: $stackTrace');
      // ここでエラーを再スローするかどうかは、呼び出し元のエラーハンドリングによります。
      // ProfileScreen側でエラーをユーザーに表示しているので、ここでは再スローしないでおきます。
      // rethrow;
    }
  }

  /// Firestore移行（serverUpdatedAt/isDeleted）のバックフィルを Functions 経由で起動する
  static Future<Map<String, dynamic>> backfillUserDocs({int limit = 1000}) async {
    final callable = FirebaseFunctions.instance.httpsCallable('backfillUserDocs');
    final result = await callable.call({'limit': limit});
    return (result.data is Map)
        ? Map<String, dynamic>.from(result.data as Map)
        : <String, dynamic>{'ok': false, 'data': result.data};
  }

  // ログイン関連のメソッド (signIn, signUp, signOut など) はここにあると想定
  // ... (existing signIn, signUp, signOut methods etc.) ...

  // デバッグログの制御
  static const bool _enableDebugLogs = false;

  static void _debugPrint(String message) {
    if (_enableDebugLogs) {
      print(message);
    }
  }

  static Future<bool> hasSharedDeck(String deckName) async {
    try {
      final userId = getUserId();
      if (userId == null) return false;

      // まず userId でフィルタしてから deckName をクライアント側で比較（複合インデックス不要）
      final snapshot = await FirebaseFirestore.instance
          .collection(_sharedDecksCollection)
          .where('userId', isEqualTo: userId)
          .get();

      for (var doc in snapshot.docs) {
        final data = doc.data();
        if (data['deckName'] == deckName) {
          return true;
        }
      }
      return false;
    } catch (_) {
      return false; // エラー時は存在しない扱い
    }
  }
}
