// ignore_for_file: library_private_types_in_public_api, use_build_context_synchronously, avoid_print

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:yomiage/models/deck.dart';
import 'package:yomiage/models/flashcard.dart';
import 'package:yomiage/services/hive_service.dart';
import 'package:yomiage/services/firebase_service.dart';
import 'package:yomiage/screens/card_edit_screen.dart';
import 'package:yomiage/services/sync/pending_operations.dart';

/// カード一覧を確認・編集する画面
class CardListScreen extends StatefulWidget {
  final Deck deck;
  const CardListScreen({Key? key, required this.deck}) : super(key: key);

  @override
  _CardListScreenState createState() => _CardListScreenState();
}

class _CardListScreenState extends State<CardListScreen> {
  late final Box<FlashCard> cardBox;

  @override
  void initState() {
    super.initState();
    cardBox = HiveService.getCardBox();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.deck.deckName} のカード'),
        actions: [
          // デッキ削除ボタン
          IconButton(
            icon: const Icon(Icons.delete_forever),
            onPressed: () => _confirmDeleteDeck(widget.deck),
          ),
          // カード編集ボタン
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const CardEditScreen(),
                ),
              ).then((_) {
                // 戻ってきたら再描画
                setState(() {});
              });
            },
          ),
        ],
      ),
      body: ValueListenableBuilder(
        valueListenable: cardBox.listenable(),
        builder: (context, Box<FlashCard> box, _) {
          final cards = box.values
              .where((card) =>
                  !card.isDeleted && card.deckName == widget.deck.deckName)
              .toList();

          if (cards.isEmpty) {
            return const Center(
              child: Text('このデッキにはまだカードがありません'),
            );
          }

          return ListView.builder(
            itemCount: cards.length,
            itemBuilder: (context, index) {
              final card = cards[index];
              return Dismissible(
                key: Key(card.key.toString()),
                background: Container(
                  color: Colors.red,
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.symmetric(horizontal: 20.0),
                  child: const Icon(
                    Icons.delete,
                    color: Colors.white,
                  ),
                ),
                direction: DismissDirection.endToStart,
                onDismissed: (direction) async {
                  await _deleteCard(card);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('${card.question} を削除しました')),
                  );
                },
                child: ListTile(
                  title: Text(card.question),
                  subtitle: Text(card.answer),
                  trailing: const Icon(Icons.keyboard_arrow_right),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => CardEditScreen(
                          cardKey: card.key,
                        ),
                      ),
                    ).then((_) {
                      // 戻ってきたら再描画
                      setState(() {});
                    });
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }

  void _confirmDeleteDeck(Deck deck) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('デッキの削除'),
        content: Text('${deck.deckName} を削除しますか？\n所属する全てのカードも削除されます。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await _deleteDeck(deck);
              Navigator.pop(context); // カード一覧画面を閉じる
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('${deck.deckName} を削除しました')),
              );
            },
            child: const Text('削除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  /// カードを削除する処理
  Future<void> _deleteCard(FlashCard card) async {
    try {
      // Phase 2.5: ローカル反映＋pending enqueue（失敗時はロールバック）
      final opId = await PendingOperationsService.deleteCardAndMaybeEnqueue(
        card.key,
        firestoreId: card.firestoreId,
      );

      // 即時クラウド同期（失敗してもpendingが残る）
      if (FirebaseService.getUserId() != null) {
        final id = (card.firestoreId != null && card.firestoreId!.isNotEmpty)
            ? card.firestoreId!
            : card.id;
        if (id.isNotEmpty) {
          await FirebaseService.deleteCard(id);
          if (opId != null && opId.isNotEmpty) {
            try {
              await PendingOperationsService.deleteOpById(opId);
            } catch (_) {}
          }
        }
      }
    } catch (e) {
      print('カード削除エラー: $e');
      // ここに到達している=ロールバック済み or そもそもローカル削除前
    }
  }

  /// 対象のデッキとその所属カードを削除する処理
  Future<void> _deleteDeck(Deck deck) async {
    try {
      String? deckPendingOpId;
      // Firebaseからデッキを削除（ログイン中の場合）
      if (FirebaseService.getUserId() != null) {
        if (deck.id.isNotEmpty) {
          // Firebase上でデッキと関連カードを削除
          await FirebaseService.deleteDeck(deck.id);
          print('Firebaseからデッキを削除しました: ${deck.deckName}');
        }
      }

      // ローカルの対象のデッキに所属するカードを全て削除
      List<FlashCard> cardsToDelete =
          cardBox.values.where((c) => c.deckName == deck.deckName).toList();
      for (FlashCard card in cardsToDelete) {
        await card.delete();
      }
      // ローカルのデッキ自体を削除
      deckPendingOpId = await PendingOperationsService.deleteDeckAndMaybeEnqueue(
        deck.key,
        deckName: deck.deckName,
      );
      if (FirebaseService.getUserId() != null &&
          deckPendingOpId != null &&
          deckPendingOpId.isNotEmpty) {
        try {
          await PendingOperationsService.deleteOpById(deckPendingOpId);
        } catch (_) {}
      }
      print('ローカルからデッキを削除しました: ${deck.deckName}');
    } catch (e) {
      print('デッキ削除エラー: $e');
      // エラーが発生してもローカル削除は必ず行う
      List<FlashCard> cardsToDelete =
          cardBox.values.where((c) => c.deckName == deck.deckName).toList();
      for (FlashCard card in cardsToDelete) {
        await card.delete();
      }
      await deck.delete();
    }
  }
}
