// ignore_for_file: avoid_print, prefer_const_constructors, unnecessary_brace_in_string_interps, curly_braces_in_flow_control_structures

import 'package:hive_flutter/hive_flutter.dart';
import '../models/deck.dart';
import '../models/flashcard.dart';
import '../services/firebase_service.dart';
import '../services/sync_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
// min関数用

class HiveService {
  static const String deckBoxName = 'deckBox';
  static const String cardBoxName = 'cardBox';
  static const String settingsBoxName = 'settingsBox';

  static Future<void> initHive() async {
    await Hive.initFlutter();

    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(DeckAdapter());
    }
    if (!Hive.isAdapterRegistered(1)) {
      Hive.registerAdapter(FlashCardAdapter());
    }

    await Hive.openBox<Deck>(deckBoxName);
    await Hive.openBox<FlashCard>(cardBoxName);
    await Hive.openBox(settingsBoxName);

    // デバッグ情報：すべてのデッキとカードの数を表示
    print('Hive初期化完了、DB統計を表示:');
    printDatabaseStats();

    // 初期化完了後に不正な日付をチェックして修正
    _fixInvalidDates();
  }

  static Box<Deck> getDeckBox() => Hive.box<Deck>(deckBoxName);
  static Box<FlashCard> getCardBox() => Hive.box<FlashCard>(cardBoxName);
  static Box getSettingsBox() => Hive.box(settingsBoxName);

  /// Boxを安全に再オープンするユーティリティ
  static Future<void> _reopenBoxes() async {
    print('▶️ Boxの状態を確認し、必要なら再オープンします...');
    try {
      // Deck Boxの確認と再オープン
      if (!Hive.isBoxOpen(deckBoxName)) {
        print('   deckBoxは閉じられています。再オープンします...');
        await Hive.openBox<Deck>(deckBoxName);
        print('   ✅ deckBoxを再オープンしました。');
      } else {
        print('   deckBoxは既に開いています。');
      }

      // Card Boxの確認と再オープン
      if (!Hive.isBoxOpen(cardBoxName)) {
        print('   cardBoxは閉じられています。再オープンします...');
        await Hive.openBox<FlashCard>(cardBoxName);
        print('   ✅ cardBoxを再オープンしました。');
      } else {
        print('   cardBoxは既に開いています。');
      }
      print('▶️ Boxの状態確認完了。');
    } catch (e) {
      print('❌ Boxの再オープン中にエラー: $e');
      // エラーが発生しても処理を続行させるため、ここでは再スローしない
      // throw e;
    }
  }

  /// CSVインポート後にデッキリストを更新するために使用できます
  static Future<void> refreshDatabase() async {
    print('▶️ データベース更新を開始します...');
    try {
      // 1. Boxがオープンしていることを確認
      await _reopenBoxes();

      // 2. Boxインスタンスを取得
      final deckBox = getDeckBox();
      final cardBox = getCardBox();

      // 3. コンパクト化を実行してデータをディスクに書き込む
      //    compact()はBoxを閉じないはずだが、安全のため後で再確認
      try {
        await deckBox.compact();
        print('   deckBoxをコンパクト化しました。');
      } catch (e) {
        print('⚠️ deckBoxのコンパクト化中にエラー: $e');
      }
      try {
        await cardBox.compact();
        print('   cardBoxをコンパクト化しました。');
      } catch (e) {
        print('⚠️ cardBoxのコンパクト化中にエラー: $e');
      }

      // 4. コンパクト化後もBoxが開いているか再確認
      await _reopenBoxes();

      // 5. データの整合性をチェック
      await _checkDataIntegrity();

      print('▶️ データベースの更新が完了しました。');

      // 最新の状態を表示（デバッグ用）
      printDatabaseStats();
    } catch (e) {
      print('❌ データベース更新処理中にエラー: $e');
      // エラー発生時はBoxの再オープンを試みることで復旧を試みる
      try {
        await _reopenBoxes();
      } catch (e2) {
        print('❌ Boxの再オープンによる復旧に失敗: $e2');
      }
    }
  }

  /// データを強制的にディスクに書き込みます
  static Future<void> forceCompact() async {
    print('▶️ データの強制保存（コンパクト化と再オープン）を開始します...');
    try {
      await _reopenBoxes(); // 開始前にBoxを開く

      final deckBox = getDeckBox();
      final cardBox = getCardBox();

      // 各ボックスのコンパクト化を実行
      await deckBox.compact();
      await cardBox.compact();
      print('▶️ コンパクト化完了。');

      // コンパクト化後にBoxを確実に再オープン
      await _reopenBoxes();
      print('▶️ Boxの再オープン完了。');
    } catch (e) {
      print('❌ 強制コンパクト中にエラー: $e');
      // エラー発生時もBoxの再オープンを試みる
      try {
        await _reopenBoxes();
      } catch (e2) {
        print('❌ Boxの再オープンによる復旧に失敗: $e2');
      }
    }
  }

  /// データベース内のデータの整合性をチェック
  static Future<void> _checkDataIntegrity() async {
    try {
      final deckBox = getDeckBox();
      final cardBox = getCardBox();
      final hiveService = HiveService(); // ID生成のためにインスタンス化

      // カードの参照するデッキ名を正規化
      final deckNames = deckBox.values.map((deck) => deck.deckName).toList();
      print('▶️ 現在のデッキ一覧: $deckNames');

      // カードが参照しているデッキ名を収集
      final referencedDeckNames = <String>{};
      for (final card in cardBox.values) {
        if (card.deckName.isNotEmpty) {
          referencedDeckNames.add(card.deckName);
        }
      }
      print('▶️ カードが参照しているデッキ名: $referencedDeckNames');

      // 存在しないデッキを自動作成
      int createdCount = 0;
      for (final deckName in referencedDeckNames) {
        // デフォルトデッキは自動作成しない（ユーザーが明示的に削除した可能性があるため）
        if (deckName == 'デフォルト') {
          print('▶️ デフォルトデッキは削除されている可能性があるため自動作成をスキップします');
          continue;
        }

        if (findDeckByName(deckName) == null) {
          print('▶️ カードが参照しているデッキ "$deckName" が存在しないため作成します');
          try {
            // findOrCreateDeck を使う (メソッドがインスタンスメソッドになったため)
            final newDeck = await hiveService.findOrCreateDeck(deckName);
            print('▶️ 新規デッキを自動作成しました: ${newDeck.deckName} (ID: ${newDeck.id})');
            createdCount++;
          } catch (e) {
            print('⚠️ デッキの自動作成に失敗: $e');
          }
        }
      }

      if (createdCount > 0) {
        print('▶️ $createdCount 個のデッキを自動作成しました');
      }
    } catch (e) {
      print('⚠️ データ整合性チェック中にエラー: $e');
    }
  }

  /// 新規デッキを確実に作成・保存します
  static Future<Deck> createAndSaveDeck(
    String deckName, {
    String description = '',
  }) async {
    final hiveService = HiveService(); // findOrCreateDeck を使うためにインスタンス化
    // findOrCreateDeck に処理を委譲する
    final deck = await hiveService.findOrCreateDeck(deckName);
    // description は findOrCreateDeck では設定されないので、必要ならここで更新
    if (description.isNotEmpty && deck.description != description) {
      deck.description = description;
      await deck.save();
    }
    return deck;
  }

  /// デッキ名でデッキを検索します
  static Deck? findDeckByName(String deckName) {
    final deckBox = getDeckBox();
    final searchName = deckName.trim();
    print('▶️ デッキ検索: "$searchName"');
    try {
      // 完全一致で検索
      for (var key in deckBox.keys) {
        final d = deckBox.get(key);
        if (d != null) {
          final currentName = d.deckName.trim();
          if (currentName == searchName) {
            print('✅ 完全一致で見つかりました: $currentName (key: $key)');
            return d;
          }
        }
      }

      // 大文字小文字を無視して検索
      for (var key in deckBox.keys) {
        final d = deckBox.get(key);
        if (d != null) {
          final currentName = d.deckName.trim();
          if (currentName.toLowerCase() == searchName.toLowerCase()) {
            print('✅ 大文字小文字を無視して見つかりました: $currentName (key: $key)');
            return d;
          }
        }
      }
    } catch (e) {
      print('❌ findDeckByName でエラー: $e');
      // エラーが発生しても null を返す（デッキが見つからなかった扱い）
    }

    print('ℹ️ デッキ "$searchName" は見つかりませんでした。');
    return null;
  }

  /// カードを安全に削除します（Firebase同期付き）
  static Future<bool> deleteCardSafely(dynamic cardKey) async {
    try {
      print('HiveService - deleteCardSafely: カード削除開始 キー=$cardKey');

      // カードボックスを取得
      final cardBox = getCardBox();

      // カードが存在するか確認
      final card = cardBox.get(cardKey);
      if (card == null) {
        print('HiveService - deleteCardSafely: カードが見つかりません キー=$cardKey');
        return false;
      }

      final String cardQuestion = card.question;
      final String? firestoreId = card.firestoreId;
      final isLoggedIn = FirebaseService.getUserId() != null;

      // 1. ローカルからカードを削除
      print('HiveService - deleteCardSafely: ローカルカード削除開始: $cardQuestion');
      await cardBox.delete(cardKey);
      print('HiveService - deleteCardSafely: ローカルからカードを削除完了: $cardQuestion');

      // 2. データをディスクに保存
      await safeCompact();

      // 3. Firebase側への同期（一方向）
      if (isLoggedIn) {
        try {
          print('HiveService - deleteCardSafely: 削除情報をクラウドに同期');
          if (firestoreId != null && firestoreId.isNotEmpty) {
            // 新しい一方向同期を使用して削除をFirebaseに反映
            final syncSuccess = await SyncService.syncOperationToCloud(
                'delete_card', {'firestoreId': firestoreId});
            print(
                'HiveService - deleteCardSafely: 同期結果: ${syncSuccess['success'] ? "成功" : "失敗"}');
          } else {
            print('HiveService - deleteCardSafely: Firestore ID がないためクラウド削除はスキップ');
          }
        } catch (e) {
          print('HiveService - deleteCardSafely: クラウド同期エラー: $e');
          // Firebase同期エラーはログに記録するが、ローカル削除は成功している
        }
      }

      print('HiveService - deleteCardSafely: カード削除処理完了');
      return true;
    } catch (e) {
      print('HiveService - deleteCardSafely: エラー発生: $e');
      return false;
    }
  }

  /// データベースの統計情報を表示する（パブリックメソッド）
  static void printDatabaseStats() {
    try {
      final deckBox = getDeckBox();
      final cardBox = getCardBox();

      print('=== データベース統計 ===');
      print('デッキ数: ${deckBox.length}');
      print('カード数: ${cardBox.length}');

      // 各デッキの詳細を表示
      for (var deck in deckBox.values) {
        final cardCount = cardBox.values
            .where((card) => card.deckName == deck.deckName)
            .length;
        print('デッキ: ${deck.deckName} (key: ${deck.key}) - カード数: $cardCount');
      }

      // カードのデッキ名分布を表示
      final deckDistribution = <String, int>{};
      for (var card in cardBox.values) {
        final deckName = card.deckName;
        deckDistribution[deckName] = (deckDistribution[deckName] ?? 0) + 1;
      }
      print('カードのデッキ分布: $deckDistribution');
      print('=====================');
    } catch (e) {
      print('統計情報取得エラー: $e');
    }
  }

  /// ボックスを閉じて再度開く（完全なデータリフレッシュ）
  static Future<void> closeAndReopenBoxes() async {
    try {
      print('HiveService - closeAndReopenBoxes: ボックスをクローズ開始');

      // 現在のボックスをクローズ
      await getDeckBox().close();
      await getCardBox().close();

      print('HiveService - closeAndReopenBoxes: ボックスをクローズ完了');

      // ボックスを再オープン
      await initHive();

      print('HiveService - closeAndReopenBoxes: ボックスを再オープン完了');
    } catch (e) {
      print('HiveService - closeAndReopenBoxes: エラー発生 $e');
      // エラーが発生しても処理を継続するため、再度ボックスを開く
      await initHive();
    }
  }

  /// 削除操作後にUIを安全に更新するためのユーティリティメソッド
  /// デッキやカードが削除された後、Boxが既に閉じられている場合にもエラーを防止します
  static Future<void> safeNavigateAfterDeletion() async {
    // 小さな遅延を入れてHiveの内部処理が完了するのを待つ
    await Future.delayed(const Duration(milliseconds: 100));

    try {
      // Boxが開いているか確認し、必要なら再オープン
      if (!Hive.isBoxOpen(deckBoxName) || !Hive.isBoxOpen(cardBoxName)) {
        print(
            'HiveService - safeNavigateAfterDeletion: Boxが閉じられています。再オープンします。');
        await _reopenBoxes();
      }

      // データを確実にディスクに書き込むために強制的にコンパクト化を実行
      final deckBox = getDeckBox();
      final cardBox = getCardBox();

      try {
        // 両方のBoxをコンパクト化（ディスクへの書き込みを強制）
        await deckBox.compact();
        await cardBox.compact();
        print('HiveService - safeNavigateAfterDeletion: データを強制的にディスクに書き込みました');
      } catch (e) {
        print('HiveService - safeNavigateAfterDeletion: コンパクト化エラー: $e');
        // エラーがあっても続行
      }

      // 問題がなければデータベースの整合性を確認
      await refreshDatabase();
      print('HiveService - safeNavigateAfterDeletion: 削除後の安全な処理が完了しました');
    } catch (e) {
      print('HiveService - safeNavigateAfterDeletion: エラー発生 $e');
      // 万が一エラーが発生した場合も処理を継続させる
      try {
        await initHive();
      } catch (e2) {
        print('HiveService - safeNavigateAfterDeletion: 復旧にも失敗 $e2');
      }
    }
  }

  /// カードを確実に削除するヘルパーメソッド
  static Future<bool> forceDeleteCards(String deckName) async {
    print('HiveService - forceDeleteCards: デッキ "$deckName" のカードを強制削除します');
    try {
      // カードボックスを取得
      final cardBox = getCardBox();
      if (!cardBox.isOpen) {
        print('HiveService - forceDeleteCards: カードボックスが閉じています。処理を中止します');
        return false;
      }

      int deletedCount = 0;

      // 削除対象のカードを特定（インデックスとキーのマップを作成）
      final cardsToDelete = <int, dynamic>{};
      for (int i = 0; i < cardBox.length; i++) {
        final card = cardBox.getAt(i);
        if (card != null && card.deckName == deckName) {
          cardsToDelete[i] = cardBox.keyAt(i);
        }
      }

      print(
          'HiveService - forceDeleteCards: ${cardsToDelete.length}枚のカードを削除します');

      // キーで削除を試みる
      for (final entry in cardsToDelete.entries) {
        try {
          final index = entry.key;
          final key = entry.value;

          // キーによる削除
          if (cardBox.containsKey(key)) {
            await cardBox.delete(key);
            deletedCount++;
          }
          // インデックスによる削除（キーによる削除が失敗した場合のフォールバック）
          else {
            try {
              await cardBox.deleteAt(index);
              deletedCount++;
            } catch (e) {
              print('HiveService - forceDeleteCards: インデックス削除エラー: $e');
            }
          }
        } catch (e) {
          print('HiveService - forceDeleteCards: カード削除エラー: $e');
        }
      }

      // データを安全に保存
      if (cardBox.isOpen) {
        await cardBox.compact();
      }

      // 削除後の確認
      int remainingCount = 0;
      if (cardBox.isOpen) {
        for (final card in cardBox.values) {
          if (card.deckName == deckName) {
            remainingCount++;
          }
        }
      }

      print(
          'HiveService - forceDeleteCards: $deletedCount枚削除、$remainingCount枚残っています');

      return deletedCount > 0;
    } catch (e) {
      print('HiveService - forceDeleteCards: エラー発生: $e');
      return false;
    }
  }

  /// データを安全にディスクに保存する（エラーハンドリング付き）
  static Future<void> safeCompact() async {
    print('HiveService - safeCompact: データを安全に保存します');
    try {
      final deckBox = getDeckBox();
      final cardBox = getCardBox();

      if (deckBox.isOpen) {
        await deckBox.compact();
        print('HiveService - safeCompact: デッキボックスをコンパクト化しました');
      }

      if (cardBox.isOpen) {
        await cardBox.compact();
        print('HiveService - safeCompact: カードボックスをコンパクト化しました');
      }

      print('HiveService - safeCompact: データを安全に保存しました');
    } catch (e) {
      print('HiveService - safeCompact: エラー発生: $e');
      // エラーを握りつぶして処理を継続できるようにする
    }
  }

  /// ブラウザのローカルキャッシュをクリアする（WebアプリとWebブラウザの場合のみ有効）
  static Future<bool> clearBrowserCache() async {
    if (!kIsWeb) {
      print('HiveService - clearBrowserCache: Webプラットフォームではないため、操作をスキップします');
      return false;
    }

    print('HiveService - clearBrowserCache: ブラウザキャッシュのクリアを開始します');

    try {
      // 1. すべてのボックスをクローズ
      await Hive.close();
      print('HiveService - clearBrowserCache: すべてのボックスをクローズしました');

      // 2. Hiveを再初期化
      await Hive.initFlutter();
      print('HiveService - clearBrowserCache: Hiveを再初期化しました');

      // 3. アダプターを再登録
      if (!Hive.isAdapterRegistered(0)) {
        Hive.registerAdapter(DeckAdapter());
      }
      if (!Hive.isAdapterRegistered(1)) {
        Hive.registerAdapter(FlashCardAdapter());
      }

      // 4. ボックスを再オープン
      await Hive.openBox<Deck>(deckBoxName);
      await Hive.openBox<FlashCard>(cardBoxName);
      await Hive.openBox(settingsBoxName);
      print('HiveService - clearBrowserCache: すべてのボックスを再オープンしました');

      // 5. データベース統計を表示（デバッグ用）
      printDatabaseStats();

      return true;
    } catch (e) {
      print('HiveService - clearBrowserCache: エラー発生: $e');

      // エラー発生時はHiveを再初期化して復旧を試みる
      try {
        await initHive();
        print('HiveService - clearBrowserCache: エラー発生後、Hiveを再初期化しました');
      } catch (e2) {
        print('HiveService - clearBrowserCache: 復旧にも失敗しました: $e2');
      }

      return false;
    }
  }

  /// Hive内の重複デッキをクリーンアップする
  static Future<void> cleanupDuplicateDecks() async {
    print('🧹 Hive内の重複デッキのクリーンアップを開始します...');
    final deckBox = HiveService.getDeckBox();
    final cardBox = HiveService.getCardBox();

    // isClosedチェックを追加
    if (!deckBox.isOpen) {
      print('⚠️ deckBoxが閉じています。クリーンアップをスキップします。');
      return;
    }
    if (!cardBox.isOpen) {
      print('⚠️ cardBoxが閉じています。クリーンアップをスキップします。');
      return;
    }

    final decks = deckBox.values.toList();
    final decksByName = <String, List<Deck>>{};

    // デッキを名前でグループ化
    for (final deck in decks) {
      decksByName.putIfAbsent(deck.deckName, () => []).add(deck);
    }

    int cleanedCount = 0;
    int cardsMovedCount = 0;

    // 重複しているグループを処理
    for (final entry in decksByName.entries) {
      final deckName = entry.key;
      final duplicateDecks = entry.value;

      if (duplicateDecks.length > 1) {
        print('🔥 重複デッキ検出: "$deckName" が ${duplicateDecks.length} 件あります');

        // 保持するデッキを選択 (Firestore IDを持つものを優先)
        Deck? deckToKeep;
        // Firestore IDを持つものを探す
        deckToKeep = duplicateDecks.firstWhere(
            (d) => d.id.isNotEmpty, // Firestore IDがあればそれを優先
            orElse: () => duplicateDecks.first // なければ最初のものを保持
            );

        print('  -> 保持するデッキ: キー=${deckToKeep.key}, ID=${deckToKeep.id}');

        // 削除対象のデッキを処理
        for (final deckToDelete in duplicateDecks) {
          if (deckToDelete.key == deckToKeep.key) continue; // 保持するデッキはスキップ

          print(
              '  🗑️ 削除対象デッキ: キー=${deckToDelete.key}, ID=${deckToDelete.id}, 名前=${deckToDelete.deckName}'); // 名前もログ追加
          final deckToDeleteName = deckToDelete.deckName; // デッキ名を保持
// Firestore ID を保持

          // --- ★★★ Firebase カード更新処理 ★★★ ---
          print('     -> Firebase上のカードのデッキ名更新を開始...');
          final cardsToMoveKeys = cardBox.keys.where((key) {
            final card = cardBox.get(key);
            return card != null && card.deckName == deckToDelete.deckName;
          }).toList();

          print(
              '        - 移動対象カードキー (Firebase更新用): ${cardsToMoveKeys.length} 件');
          List<Future<void>> cardUpdateFutures = []; // Firebase更新を並行処理
          final userId = FirebaseService.getUserId(); // ★ ユーザーIDを取得

          for (final key in cardsToMoveKeys) {
            final card = cardBox.get(key);
            if (card != null && userId != null) {
              // ★ userId チェック追加

              // ローカルのカードのデッキ名を変更
              card.deckName = deckToKeep.deckName;
              card.updateTimestamp(); // 更新日時を明示的に更新
              await card.save(); // ローカルに保存
              cardsMovedCount++;

              // Firebase上のカードも更新
              if (card.firestoreId != null && card.firestoreId!.isNotEmpty) {
                print(
                    '          - Firebase更新: ${card.question} (ID: ${card.firestoreId}) を ${deckToKeep.deckName} へ');
                // ★★★ FirebaseService.saveCard に userId を渡す ★★★
                cardUpdateFutures.add(FirebaseService.saveCard(card, userId));
              } else {
                print('          - スキップ(FirestoreIDなし): ${card.question}');
              }
            }
          }
          await Future.wait(cardUpdateFutures);
          print('     -> Firebase上のカードのデッキ名更新が完了しました。');
          // --- ★★★ Firebase カード更新処理ここまで ★★★ ---

          // --- ★★★ Firebase デッキ削除処理 (操作ログ経由) ★★★ ---
          bool firebaseDeckLogged = false;
          if (deckToDeleteName.isNotEmpty && userId != null) {
            // ★ デッキ名とuserIdをチェック
            print('     -> Firebaseへの削除操作ログ送信を開始 (デッキ名: ${deckToDeleteName})');
            try {
              // ★★★ SyncService.syncOperationToCloud を使用 ★★★
              final result = await SyncService.syncOperationToCloud(
                  'delete_deck', {'deckName': deckToDeleteName} // 引数をデッキ名に変更
                  );
              firebaseDeckLogged = result['success'] ?? false;
              if (firebaseDeckLogged) {
                print(
                    '     -> Firebaseへの削除操作ログ送信完了 (デッキ名: ${deckToDeleteName})');
              } else {
                print(
                    '     ⚠️ Firebaseへの削除操作ログ送信失敗 (デッキ名: ${deckToDeleteName}), Result: $result');
              }
            } catch (e) {
              print('     ⚠️ Firebaseへの削除操作ログ送信中にエラー: $e');
              // エラーが発生してもローカル削除は続行する
            }
          } else {
            print('     -> スキップ (デッキ名がないか未ログイン)');
          }
          // --- ★★★ Firebase デッキ削除処理ここまで ★★★ ---

          // 重複デッキをローカルから削除
          await deckBox.delete(deckToDelete.key);
          cleanedCount++;
          print('     -> ローカルの重複デッキを削除しました (キー: ${deckToDelete.key})');
        }
      }
    }

    if (cleanedCount > 0) {
      print(
          '🧹 重複デッキのクリーンアップ完了: $cleanedCount 件のデッキを削除、 $cardsMovedCount 件のカードを移動しました。');
      // 変更を保存
      await HiveService.safeCompact();
    } else {
      print('🧹 重複デッキは見つかりませんでした。');
    }

    // ★★★ ここからFirebase上の重複クリーンアップ処理を追加 ★★★
    print('🧹 Firebase上の重複デッキのクリーンアップを開始します...');
    final String? currentUserId = FirebaseService.getUserId();
    if (currentUserId == null) {
      print('⚠️ ユーザーがログインしていません。Firebase上の重複クリーンアップをスキップします。');
    } else {
      try {
        List<Deck> firebaseDecks =
            await FirebaseService.getDecks(); // 1. Firebase上の全デッキ取得
        if (firebaseDecks.isEmpty) {
          print('ℹ️ Firebase上にデッキが存在しないため、重複クリーンアップをスキップします。');
        } else {
          final firebaseDecksByName = <String, List<Deck>>{};
          for (final deck in firebaseDecks) {
            // 2. デッキ名でグループ化
            firebaseDecksByName.putIfAbsent(deck.deckName, () => []).add(deck);
          }

          int firebaseCleanedCount = 0;
          int firebaseCardsUpdatedCount = 0;

          for (final entry in firebaseDecksByName.entries) {
            final deckName = entry.key;
            final duplicateFirebaseDecks = entry.value;

            if (duplicateFirebaseDecks.length > 1) {
              // 3. 重複確認
              print(
                  '🔥 Firebase上で重複デッキ検出: "$deckName" が ${duplicateFirebaseDecks.length} 件あります');

              // 4a. 保持するデッキを選択 (firestoreUpdatedAt が最新のものを優先)
              duplicateFirebaseDecks.sort((a, b) {
                // 更新日時の降順でソート
                if (a.firestoreUpdatedAt == null &&
                    b.firestoreUpdatedAt == null) return 0;
                if (a.firestoreUpdatedAt == null) return 1; // bを優先 (nullを後に)
                if (b.firestoreUpdatedAt == null) return -1; // aを優先 (nullを後に)
                return b.firestoreUpdatedAt!
                    .compareTo(a.firestoreUpdatedAt!); // 新しい方が先頭
              });
              Deck deckToKeepFirebase =
                  duplicateFirebaseDecks.first; // ソート後の先頭が最新
              print(
                  '  -> Firebaseで保持するデッキ: ID=${deckToKeepFirebase.id}, Name=${deckToKeepFirebase.deckName}, UpdatedAt=${deckToKeepFirebase.firestoreUpdatedAt}');

              for (final deckToDeleteFirebase in duplicateFirebaseDecks) {
                if (deckToDeleteFirebase.id == deckToKeepFirebase.id)
                  continue; // 保持するものはスキップ

                print(
                    '  🗑️ Firebaseで削除対象のデッキ: ID=${deckToDeleteFirebase.id}, Name=${deckToDeleteFirebase.deckName}');

                // 4c.i & ii. 関連カードを保持デッキに付け替え
                print(
                    '     -> Firebase上のカードのデッキ名更新を開始 (対象デッキ名: ${deckToDeleteFirebase.deckName})...');
                List<FlashCard> allUserCards =
                    await FirebaseService.getAllCardsForUser(currentUserId);
                List<FlashCard> cardsToUpdateOnFirebase = allUserCards
                    .where((card) =>
                        card.deckName == deckToDeleteFirebase.deckName)
                    .toList();

                if (cardsToUpdateOnFirebase.isNotEmpty) {
                  print(
                      '        - ${cardsToUpdateOnFirebase.length}件のカードを"${deckToKeepFirebase.deckName}"に移動します。');
                  List<Future<void>> fbCardUpdateFutures = [];
                  for (final cardToUpdate in cardsToUpdateOnFirebase) {
                    cardToUpdate.deckName = deckToKeepFirebase.deckName;
                    cardToUpdate.updateTimestamp(); // 更新日時を明示的に更新
                    fbCardUpdateFutures.add(
                        FirebaseService.saveCard(cardToUpdate, currentUserId));
                  }
                  await Future.wait(fbCardUpdateFutures);
                  firebaseCardsUpdatedCount += cardsToUpdateOnFirebase.length;
                  print('     -> Firebase上のカードのデッキ名更新完了。');
                } else {
                  print('     -> 移動対象のカードはありませんでした。');
                }

                // 4c.iii & iv. Firebaseからデッキを削除し、削除ログを記録
                print(
                    '     -> Firebaseからのデッキ削除とログ記録を開始 (デッキ名: ${deckToDeleteFirebase.deckName})...');
                await SyncService.syncOperationToCloud(
                    'delete_deck', {'deckName': deckToDeleteFirebase.deckName});

                firebaseCleanedCount++;
              }
            }
          }
          if (firebaseCleanedCount > 0) {
            print(
                '🧹 Firebase上の重複デッキのクリーンアップ完了: $firebaseCleanedCount 件のデッキを削除、 $firebaseCardsUpdatedCount 件のカードのデッキ名を更新しました。');
          } else {
            print('🧹 Firebase上に新たな重複デッキは見つかりませんでした。');
          }
        }
      } catch (e) {
        print('❌ Firebase上の重複デッキのクリーンアップ中にエラー: $e');
      }
    }
  }

  // ★★★ 新規追加: Hiveの全データをクリアするメソッド ★★★
  static Future<void> clearAllData() async {
    print('🧹 Hiveの全データ（Decks, Cards, Settings）をクリアします...');
    try {
      await _reopenBoxes(); // Boxが開いていることを確認

      final deckBox = getDeckBox();
      final cardBox = getCardBox();
      final settingsBox = getSettingsBox();

      final deckCount = deckBox.length;
      final cardCount = cardBox.length;
      final settingsCount = settingsBox.length;

      await deckBox.clear();
      print('   ✅ deckBox をクリアしました ($deckCount 件)');
      await cardBox.clear();
      print('   ✅ cardBox をクリアしました ($cardCount 件)');
      await settingsBox.clear();
      print('   ✅ settingsBox をクリアしました ($settingsCount 件)');

      // クリア後にコンパクト化を実行してディスクスペースを解放（任意）
      await forceCompact();

      print('✅ Hiveの全データのクリアが完了しました。');
    } catch (e) {
      print('❌ Hiveデータのクリア中にエラーが発生しました: $e');
      // エラーが発生しても処理を続行させるか、再スローするか検討
      // rethrow;
    }
  }

  // --- インスタンスメソッド ---

  // Box を取得するためのヘルパー (インスタンスメソッド版)
  Box<Deck> get _deckBox => Hive.box<Deck>(deckBoxName);
  Box<FlashCard> get _cardBox => Hive.box<FlashCard>(cardBoxName);

  // 一意なIDを生成する (UUID v4 を使用)
  String generateUniqueId() {
    return const Uuid().v4();
  }

  // 指定された名前の Deck を検索または作成する
  Future<Deck> findOrCreateDeck(String deckName) async {
    // ★★★ 追加: デッキ名をトリム ★★★
    final trimmedDeckName = deckName.trim();

    // ★★★ 追加: 空文字チェック ★★★
    if (trimmedDeckName.isEmpty) {
      print('🚫 [findOrCreateDeck] デッキ名が空のため作成できません。');
      throw Exception('デッキ名を空にすることはできません。');
    }

    // ★★★ 追加: 削除済みデッキ名リストを取得 ★★★
    final userId = FirebaseService.getUserId();
    Set<String> deletedDeckNames = {};
    if (userId != null) {
      try {
        deletedDeckNames = await SyncService.fetchDeletedDeckNames();
        print('ℹ️ [findOrCreateDeck] 削除済みデッキ名リスト: $deletedDeckNames');
      } catch (e) {
        print('⚠️ [findOrCreateDeck] 削除済みデッキ名の取得に失敗: $e');
        // エラーが発生しても処理は続行するが、ログは残す
      }
    }

    // 名前で既存の Deck を検索
    // ★★★ 修正: トリム＆小文字化して比較 ★★★
    final existing = _deckBox.values
        .where((d) =>
            d.deckName.trim().toLowerCase() == trimmedDeckName.toLowerCase())
        .firstOrNull;
    if (existing != null) {
      // 既存が見つかった場合、それが削除済みログに含まれていないか確認
      // contains の比較も正規化する（念のため）
      if (!deletedDeckNames.any((deletedName) =>
          deletedName.trim().toLowerCase() == trimmedDeckName.toLowerCase())) {
        print(
            'ℹ️ [findOrCreateDeck] 実質的に同名の既存デッキが見つかりました（削除ログなし）: "${existing.deckName}" (入力: "$trimmedDeckName")');
        return existing; // 削除ログになければ既存を返す
      }
      // 既存が見つかっても削除済みログにある場合は、ログクリア処理に進む
      print(
          'ℹ️ [findOrCreateDeck] 実質的に同名の既存デッキが見つかりましたが、削除済みログにあるため、新規作成に進みます: "${existing.deckName}" (入力: "$trimmedDeckName")');
    }

    // ★★★ 修正: 削除済みリストに含まれている場合、削除ログをクリアして再作成を許可 ★★★
    // contains の比較も正規化する
    if (deletedDeckNames.any((deletedName) =>
        deletedName.trim().toLowerCase() == trimmedDeckName.toLowerCase())) {
      print(
          'ℹ️ [findOrCreateDeck] デッキ "$trimmedDeckName" は削除済みログに存在します。ログをクリアして再作成します。');
      if (userId != null) {
        try {
          // ★★★ 修正: cleanupDeckDeletionLog を呼び出す ★★★
          SyncService.cleanupDeckDeletionLog(userId, trimmedDeckName)
              .catchError((e) {
            print('⚠️ [findOrCreateDeck] 再作成時の削除ログクリーンアップ中にエラー (無視): $e');
          });
        } catch (e) {
          print('⚠️ [findOrCreateDeck] 再作成時の削除ログクリーンアップ呼び出し中にエラー (無視): $e');
        }
      }
      // エラーをスローせず、そのまま新規作成処理に進む
    }

    // 存在しない場合は新規作成
    print('ℹ️ [findOrCreateDeck] 新規デッキを作成処理に進みます: "$trimmedDeckName"');
    final newId = generateUniqueId();
    final newDeck = Deck(
      id: newId,
      deckName: trimmedDeckName, // ★ トリムした名前で作成
    );
    await _deckBox.put(newId, newDeck);
    print(
        '✅ [findOrCreateDeck] ローカルにデッキを保存しました: "$trimmedDeckName" (ID: $newId)');

    return newDeck;
  }

  // Flashcard を追加する
  Future<void> addFlashcard(FlashCard card) async {
    // 受け取った deckId を使うか、card.deckId を使うか要検討 -> card.deckName を使うので deckId 不要
    // ここでは card に設定されている deckId を信頼する前提
    // 必要であれば deckId の存在チェックなどを追加 -> 不要
    // Hiveキーを Firestore ID 優先で統一
    final key = (card.firestoreId != null && card.firestoreId!.isNotEmpty)
        ? card.firestoreId!
        : card.id;
    await _cardBox.put(key, card);
  }

  /// 既存のカードを別キーに移し替える（キーのリネーム相当）
  static Future<void> rekeyCard(dynamic oldKey, String newKey) async {
    if (oldKey == null || newKey.isEmpty) return;
    final cardBox = getCardBox();
    if (!cardBox.isOpen) {
      await _reopenBoxes();
    }
    if (!cardBox.containsKey(oldKey)) {
      return; // 既に移動済みか削除済み
    }
    if (oldKey == newKey) {
      return; // 変更不要
    }
    final value = cardBox.get(oldKey);
    if (value == null) {
      // 何もないなら旧キーを掃除して終了
      try {
        await cardBox.delete(oldKey);
      } catch (_) {}
      return;
    }
    // newKey へ保存（すでに存在する場合は上書き優先: firestoreId一致を優先）
    await cardBox.put(newKey, value);
    // 旧キーを削除
    if (cardBox.containsKey(oldKey)) {
      await cardBox.delete(oldKey);
    }
  }

  // 不正な日付を持つ全てのカードを修正するメソッド
  static Future<void> _fixInvalidDates() async {
    int fixedCount = 0;
    for (final card in getCardBox().values) {
      if (card.checkAndFixInvalidDate()) {
        await card.save();
        fixedCount++;
      }
    }

    if (fixedCount > 0) {
      print('📅 [HiveService] 不正な日付を持つ $fixedCount 枚のカードを修正しました');
    }
  }

  // デフォルトデッキが存在しない場合に作成

  // ★★★ 追加: ローカルのユーザーデータ（デッキとカード）をクリアするメソッド ★★★
  static Future<void> clearUserData() async {
    print('🗑️ [HiveService] ローカルユーザーデータのクリアを開始します...');
    try {
      final deckBox = getDeckBox();
      final cardBox = getCardBox();

      print('📊 クリア前のデータ状態:');
      print('  - デッキ数: ${deckBox.length}');
      print('  - カード数: ${cardBox.length}');

      // デッキの情報を出力
      if (deckBox.length > 0) {
        print('  - デッキ一覧:');
        for (var deck in deckBox.values) {
          print('    * ${deck.deckName} (ID: ${deck.id})');
        }
      }

      await deckBox.clear();
      print('✅ デッキボックスをクリアしました');

      await cardBox.clear();
      print('✅ カードボックスをクリアしました');

      // クリア後の確認
      print('📊 クリア後のデータ状態:');
      print('  - デッキ数: ${deckBox.length}');
      print('  - カード数: ${cardBox.length}');

      print('✨ ローカルユーザーデータのクリアが完了しました');
    } catch (e, stackTrace) {
      print('❌ ローカルユーザーデータのクリア中にエラーが発生しました:');
      print('  エラー: $e');
      print('  スタックトレース: $stackTrace');
      rethrow; // エラーを上位に伝播させる
    }
  }
  // ★★★ 追加ここまで ★★★

  // --- ここまでインスタンスメソッド ---
}

// HiveService のインスタンスを提供する Provider
final hiveServiceProvider = Provider<HiveService>((ref) {
  // HiveService の初期化 (initHive) は main.dart などで行われている前提
  return HiveService();
});
