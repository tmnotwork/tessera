// ignore_for_file: avoid_print, use_build_context_synchronously, unused_element, prefer_const_constructors, await_only_futures, curly_braces_in_flow_control_structures, deprecated_member_use, prefer_const_literals_to_create_immutables

import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:yomiage/models/deck.dart';
import 'package:yomiage/models/flashcard.dart';
import 'package:yomiage/services/hive_service.dart';
import 'package:yomiage/services/firebase_service.dart';
import 'package:yomiage/screens/deck_edit_screen.dart';
import 'package:yomiage/screens/card_edit_screen.dart';
import 'package:yomiage/services/sync_service.dart';
import 'package:yomiage/services/sync/pending_operations.dart';

class DeckScreen extends StatefulWidget {
  const DeckScreen({Key? key}) : super(key: key);

  @override
  State<DeckScreen> createState() => _DeckScreenState();
}

class _DeckScreenState extends State<DeckScreen> {
  late Box<Deck> deckBox;
  // FloatingActionButtonを特定するためのキー
  final GlobalKey _fabKey = GlobalKey();
  // ★★★ 追加: デッキ削除処理中フラグ ★★★
  bool _isDeleting = false;

  @override
  void initState() {
    super.initState();
    deckBox = HiveService.getDeckBox();
    // ★★★ initStateでもDB統計を出力 ★★★
    print("--- DeckScreen initState --- ");
    HiveService.printDatabaseStats();
  }

  @override
  Widget build(BuildContext context) {
    // ★★★ buildメソッド開始時にもDB統計を出力 ★★★
    print("--- DeckScreen build START --- ");
    HiveService.printDatabaseStats();

    final decks = deckBox.values
        .where((d) => !d.isDeleted)
        .toList()
      ..sort((a, b) => a.deckName.compareTo(b.deckName));

    // ★★★ デバッグログ強化: デッキ名とキーを詳細に出力 ★★★
    print('--- DeckScreen build: 表示対象デッキ一覧 (${decks.length}件) ---');
    for (int i = 0; i < decks.length; i++) {
      final deck = decks[i];
      print(
          '  [$i] 名前: "${deck.deckName}", キー: ${deck.key}, ID(Firestore): ${deck.id}');
    }
    print('----------------------------------------------------');

    return Scaffold(
      appBar: AppBar(
        title: const Text('デッキ作成・編集', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.black,
      ),
      backgroundColor: Colors.black,
      body: decks.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                    'デッキがありません',
                    style: TextStyle(color: Colors.white, fontSize: 18),
                  ),
                  const SizedBox(height: 20),
                  ElevatedButton(
                    onPressed: () => _showCreateOptions(context),
                    child: const Text('作成'),
                  ),
                ],
              ),
            )
          : ListView(
              children: [
                const Divider(color: Colors.white54),
                ...decks.map((deck) {
                  return Dismissible(
                    key: ValueKey(deck.key),
                    direction: DismissDirection.endToStart,
                    confirmDismiss: (direction) async {
                      final String deckName = deck.deckName;
                      final bool? confirm = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('デッキを削除'),
                          content: Text(
                            'デッキ「$deckName」とその中のすべてのカードを削除しますか？\nこの操作は元に戻せません。',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('キャンセル'),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(context, true),
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.red,
                              ),
                              child: const Text('削除する'),
                            ),
                          ],
                        ),
                      );
                      return confirm == true;
                    },
                    onDismissed: (direction) async {
                      await _deleteDeck(deck);
                    },
                    background: Container(
                      color: Colors.red,
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: const Icon(Icons.delete, color: Colors.white),
                    ),
                    child: ListTile(
                      leading: _buildLeadingIcon(deck),
                      title: Text(
                        deck.deckName,
                        style: const TextStyle(
                          fontSize: 20,
                          color: Colors.white,
                        ),
                      ),
                      onTap:
                          _isDeleting ? null : () => _navigateToCardList(deck),
                    ),
                  );
                }).toList(),
              ],
            ),
      floatingActionButton: FloatingActionButton(
        key: _fabKey,
        onPressed: _isDeleting ? null : () => _showCreateOptions(context),
        backgroundColor:
            _isDeleting ? Colors.grey : Theme.of(context).colorScheme.primary,
        child: Icon(
          Icons.edit,
          color: _isDeleting
              ? Colors.grey
              : Theme.of(context).colorScheme.onPrimary,
        ),
      ),
    );
  }

  /// デッキを削除する
  Future<void> _deleteDeck(Deck deck) async {
    final String deckName = deck.deckName;
    final dynamic deckKey = deck.key;
    String? pendingOpId;

    // ★★★ 追加: 削除処理開始、フラグを立てる ★★★
    setState(() {
      _isDeleting = true;
    });

    // 削除処理中であることを示すローディングインジケータを表示
    showDialog(
      context: context,
      barrierDismissible: false, // ユーザーは背景をタップしてダイアログを閉じられない
      builder: (BuildContext context) {
        return const AlertDialog(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('デッキを削除中...\nこの処理には時間がかかる場合があります。'),
            ],
          ),
        );
      },
    );

    try {
      print('DeckScreen - _deleteDeck: 削除処理を開始: $deckName (キー: $deckKey)');

      // カードボックスとデッキボックスを取得
      final cardBox = HiveService.getCardBox();
      HiveService.getDeckBox();

      // 1. このデッキに属するカードのキーリストを作成
      final deletedCardKeys = <String>[];
      final cardsToDelete = <dynamic, FlashCard>{};

      try {
        print('DeckScreen - _deleteDeck: 1. カード情報を収集中...');
        for (int i = 0; i < cardBox.length; i++) {
          final card = cardBox.getAt(i);
          final key = cardBox.keyAt(i);
          if (card != null && card.deckName == deckName) {
            cardsToDelete[key] = card;
            deletedCardKeys.add(key.toString());
          }
        }
        print('DeckScreen - _deleteDeck: 削除対象カード: ${cardsToDelete.length}枚');
      } catch (e) {
        print('DeckScreen - _deleteDeck: カード情報収集中にエラー: $e');
      }

      // 2. カードを削除（ローカルのみ）
      try {
        print('DeckScreen - _deleteDeck: 2. カードをローカルから削除中...');
        for (final entry in cardsToDelete.entries) {
          await cardBox.delete(entry.key);
        }
        print('DeckScreen - _deleteDeck: ローカルカード削除完了');
      } catch (e) {
        print('DeckScreen - _deleteDeck: ローカルカード削除中にエラー: $e');
      }

      // 3. ローカルデッキを削除
      try {
        print('DeckScreen - _deleteDeck: 3. デッキをローカルから削除中...');
        if (deckKey != null) {
          pendingOpId = await PendingOperationsService.deleteDeckAndMaybeEnqueue(
            deckKey,
            deckName: deckName,
          );
        } else {
          await deck.delete();
        }
        print('DeckScreen - _deleteDeck: ローカルデッキ削除完了');
      } catch (e) {
        print('DeckScreen - _deleteDeck: ローカルデッキ削除中にエラー: $e');
      }

      // 4. データをディスクに保存
      try {
        print('DeckScreen - _deleteDeck: 4. 変更を保存中...');
        await HiveService.safeCompact();
        print('DeckScreen - _deleteDeck: 変更の保存完了');
      } catch (e) {
        print('DeckScreen - _deleteDeck: データ保存中にエラー: $e');
      }

      // 5. Firebase同期（ログイン時のみ）- 一方向同期を使用
      if (FirebaseService.getUserId() != null) {
        try {
          print('DeckScreen - _deleteDeck: 5. 削除情報をクラウドに同期中...');
          // 新しい一方向同期メソッドを使用
          final syncResult = await SyncService.syncOperationToCloud(
            'delete_deck',
            {'deckName': deckName},
          );
          print(
            'DeckScreen - _deleteDeck: クラウド同期結果: ${syncResult['success'] ? "成功" : "失敗"}',
          );
          if (syncResult['success'] == true &&
              pendingOpId != null &&
              pendingOpId!.isNotEmpty) {
            try {
              await PendingOperationsService.deleteOpById(pendingOpId!);
            } catch (_) {}
          }
        } catch (e) {
          print('DeckScreen - _deleteDeck: クラウド同期中にエラー: $e');
        }
      } else {
        print('DeckScreen - _deleteDeck: ユーザーがログインしていないため、クラウド同期をスキップ');
      }

      // ローディングダイアログを閉じる
      if (context.mounted) Navigator.of(context).pop();

      // 6. UIを更新
      print('DeckScreen - _deleteDeck: 6. UI更新中...');
      if (mounted) {
        setState(() {});
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'デッキ「$deckName」と関連カード${cardsToDelete.length}枚を削除しました',
              ),
            ),
          );
        }
      }

      print('DeckScreen - _deleteDeck: 削除処理が完了しました');
    } catch (e) {
      print('DeckScreen - _deleteDeck: 予期せぬエラー: $e');

      // ローディングダイアログを閉じる
      if (context.mounted) Navigator.of(context).pop();

      // エラーメッセージを表示
      if (mounted && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('デッキ「$deckName」の削除中にエラーが発生しました: $e')),
        );
      }
    } finally {
      // ★★★ 追加: 削除処理完了、フラグを下ろす ★★★
      if (mounted) {
        setState(() {
          _isDeleting = false;
        });
      }
    }
  }

  /// カード一覧画面へ遷移
  void _navigateToCardList(Deck deck) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => DeckCardListScreen(deck: deck)),
    ).then((_) {
      // 画面から戻ってきたら再描画（最新のデータを反映）
      HiveService.refreshDatabase().then((_) {
        print('デッキ画面 - カード一覧から戻り: データベースを再取得しました');
        if (mounted) {
          setState(() {
            // ここでビルドが実行され、最新のデッキリスト表示
          });
        }
      }).catchError((e) {
        print('デッキ画面 - カード一覧から戻り時のエラー: $e');
        // エラーがあっても画面更新を試みる
        if (mounted) setState(() {});
      });
    });
  }

  /// デッキ編集画面へ遷移
  void _navigateToDeckEditScreen(Deck deck) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => DeckEditScreen(deckKey: deck.key),
      ),
    ).then((_) {
      // 画面から戻ってきたら確実にデータベースを更新してから再描画
      HiveService.refreshDatabase().then((_) {
        print('デッキ画面 - デッキ編集から戻り: データベースを再取得しました');
        if (mounted) {
          setState(() {
            // ここでビルドが実行され、最新のデッキリスト表示
          });
        }
      }).catchError((e) {
        print('デッキ画面 - デッキ編集から戻り時のエラー: $e');
        // エラーがあっても画面更新を試みる
        if (mounted) setState(() {});
      });
    });
  }

  /// 古いダイアログ形式でのデッキ編集（置き換え予定）
  void _editDeck(Deck deck) {
    // ダイアログではなくDeckEditScreenに遷移するため、
    // こちらは使用しません。
    _navigateToDeckEditScreen(deck);
  }

  Future<void> _showNewDeckDialog(BuildContext context) async {
    final TextEditingController newDeckController = TextEditingController();
    final TextEditingController descriptionController = TextEditingController();
    String? errorMessage;

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setStateDialog) {
          return AlertDialog(
            backgroundColor: Colors.black,
            title: const Text(
              '新規デッキ作成',
              style: TextStyle(color: Colors.white),
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: newDeckController,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      labelText: 'デッキ名',
                      labelStyle: TextStyle(color: Colors.white70),
                      border: UnderlineInputBorder(),
                    ),
                  ),
                  // エラーメッセージを入力欄の下に表示
                  if (errorMessage != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4.0),
                      child: Text(
                        errorMessage!,
                        style: const TextStyle(color: Colors.red),
                      ),
                    ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: descriptionController,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      labelText: '説明',
                      labelStyle: TextStyle(color: Colors.white70),
                      hintText: 'デッキの説明を入力（任意）',
                      hintStyle: TextStyle(color: Colors.white30),
                      border: UnderlineInputBorder(),
                    ),
                    maxLines: 2,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                child: const Text('キャンセル'),
                onPressed: () => Navigator.of(context).pop(),
              ),
              TextButton(
                child: const Text('作成'),
                onPressed: () async {
                  final deckName = newDeckController.text.trim();
                  if (deckName.isEmpty) {
                    setStateDialog(() {
                      errorMessage = 'デッキ名を入力してください';
                    });
                    return;
                  }

                  // ★★★ 移動: 削除ログのクリーンアップを先に行う ★★★
                  final userId = FirebaseService.getUserId();
                  if (userId != null && deckName.isNotEmpty) {
                    print('🧹 [DeckScreen] デッキ作成前に削除ログを確認・クリーンアップ: $deckName');
                    await SyncService.cleanupDeckDeletionLogIfNeeded(
                        userId, deckName);
                  }

                  // ★★★ 移動: 削除ログクリーンアップ後にローカルの存在チェックを行う ★★★
                  if (deckBox.values.any((d) => d.deckName == deckName)) {
                    setStateDialog(() {
                      errorMessage = '同じ名前のデッキが既に存在します';
                    });
                    return;
                  }

                  setStateDialog(() {
                    errorMessage = null;
                  });

                  // デッキを作成してローカルに保存
                  try {
                    final newDeck = await HiveService.createAndSaveDeck(
                      deckName,
                      description: descriptionController.text.trim(),
                    );
                    print(
                      '新規デッキを作成しました: ${newDeck.deckName} (キー: ${newDeck.key})',
                    );

                    // クラウドに同期 (ログイン時のみ)
                    if (FirebaseService.getUserId() != null) {
                      await SyncService.syncOperationToCloud(
                        'create_deck',
                        {'deck': newDeck},
                      );
                    }

                    // 画面を更新するため再描画
                    setState(() {});

                    Navigator.of(context).pop();

                    // 成功メッセージを表示
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('デッキ「$deckName」を作成しました')),
                    );
                  } catch (e) {
                    print('デッキ作成エラー: $e');

                    // エラーが発生しても、ローカルのデッキは作成されているか確認
                    final possibleDeck = HiveService.findDeckByName(
                      deckName,
                    );
                    if (possibleDeck != null) {
                      // デッキが見つかった場合は作成成功とみなす
                      print('デッキは作成されていました: ${possibleDeck.deckName}');
                      setState(() {}); // 画面を更新
                      Navigator.of(context).pop(); // ダイアログを閉じる

                      // 成功メッセージを表示（Firebase同期は失敗したが、ローカル作成は成功）
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('デッキ「$deckName」を作成しました')),
                      );
                    } else {
                      // 本当に失敗した場合はエラーメッセージを表示
                      setStateDialog(() {
                        errorMessage = 'デッキの作成に失敗しました: $e';
                      });
                    }
                  }
                },
              ),
            ],
          );
        },
      ),
    );

    // コントローラのクリーンアップ
    newDeckController.dispose();
    descriptionController.dispose();
  }

  /// 作成オプションを表示するメニュー
  void _showCreateOptions(BuildContext context) async {
    // FloatingActionButtonの位置を取得
    final RenderBox fabRenderBox =
        _fabKey.currentContext!.findRenderObject() as RenderBox;
    final Offset fabPosition = fabRenderBox.localToGlobal(Offset.zero);
    final Size fabSize = fabRenderBox.size;
    final RenderBox overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;

    // FAB の上端から、FAB の高さ＋20px分上に表示して、FAB と全く重ならないようにする
    final RelativeRect position = RelativeRect.fromRect(
      Rect.fromLTWH(
        fabPosition.dx,
        fabPosition.dy - fabSize.height - 20,
        fabSize.width,
        fabSize.height,
      ),
      Offset.zero & overlay.size,
    );

    final selected = await showMenu(
      context: context,
      position: position,
      elevation: 8.0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      items: [
        PopupMenuItem(
          value: 'deck',
          child: const Text(
            'デッキを作成',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        PopupMenuItem(
          value: 'card',
          child: const Text(
            'カードを作成',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );

    if (selected == 'deck') {
      _showNewDeckDialog(context);
    } else if (selected == 'card') {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => const CardEditScreen()),
      ).then((_) {
        // カード作成後に画面を更新
        setState(() {
          // デッキ一覧を再取得（新しいデッキが作成された可能性もあるため）
          HiveService.refreshDatabase().then((_) {
            print('デッキ画面 - カード作成後の更新: データベースを再取得しました');
            // 強制的に再描画（特に必要な場合）
            setState(() {});
          }).catchError((e) {
            print('デッキ画面 - カード作成後の更新エラー: $e');
          });
        });
      });
    }
  }

  // ▼▼▼ スタブメソッド追加 ▼▼▼
  Widget _buildLeadingIcon(Deck deck) {
    return Icon(Icons.folder); // 仮のアイコン
  }

  // デッキがレビュー期日を迎えているか判断するヘルパーメソッド
  bool _isDue(Deck deck) {
    final cardBox = HiveService.getCardBox();
    final now = DateTime.now();
    // デッキに属するカードを取得
    final cardsInDeck =
        cardBox.values.where((card) => !card.isDeleted && card.deckName == deck.deckName);

    // 期日が来ているカードが1枚でもあるかチェック
    return cardsInDeck.any(
        (card) => card.nextReview == null || card.nextReview!.isBefore(now));
  }

  Color? _getTileColor(Deck deck) {
    // ここも _isDue を使うべきかもしれないが、一旦保留
    // if (_isDue(deck)) {
    return null; // デフォルトの色
  }
  // ▲▲▲ スタブメソッド追加 ▲▲▲
}

/// デッキ内のカード一覧画面
class DeckCardListScreen extends StatefulWidget {
  final Deck deck;
  const DeckCardListScreen({Key? key, required this.deck}) : super(key: key);

  @override
  State<DeckCardListScreen> createState() => _DeckCardListScreenState();
}

class _DeckCardListScreenState extends State<DeckCardListScreen> {
  late List<FlashCard> cards = [];
  bool isProcessing = false; // データ処理中フラグ
  String? _progressText; // 進捗テキスト表示用

  @override
  void initState() {
    super.initState();
    _loadCards();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 画面が表示される度に毎回カードを再読み込み
    _loadCards();
  }

  void _loadCards() {
    print('DeckCardListScreen - カードを再読み込みします: ${widget.deck.deckName}');

    try {
      // デッキに属するカードを取得
      final cardBox = HiveService.getCardBox();

      // Boxが閉じている場合に対応
      if (!cardBox.isOpen) {
        print('DeckCardListScreen - カードボックスが閉じています。再オープンを試みます...');
        // 安全に処理
        HiveService.initHive().then((_) {
          if (mounted) {
            setState(() {
              _loadCardsFromBox();
            });
          }
        });
        return;
      }

      _loadCardsFromBox();
    } catch (e) {
      print('DeckCardListScreen - カード読み込みエラー: $e');
      // エラーが発生しても画面表示は続行
      if (mounted) {
        setState(() {
          cards = [];
        });
      }
    }
  }

  void _loadCardsFromBox() {
    final cardBox = HiveService.getCardBox();

    // 現在のカード数をログ出力
    print('DeckCardListScreen - カードボックス内の総カード数: ${cardBox.length}');

    // デッキ名が一致するカードを検索
    cards = cardBox.values
        .where((card) => !card.isDeleted && card.deckName == widget.deck.deckName)
        .toList();

    print('DeckCardListScreen - 読み込んだカード数: ${cards.length}');

    // アルファベット順にソート
    cards.sort((a, b) => a.question.compareTo(b.question));

    // 更新を反映
    setState(() {});
  }

  /// このデッキに属するすべてのカードを削除
  Future<void> _deleteAllCards() async {
    final String deckName = widget.deck.deckName;

    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('すべてのカードを削除'),
        content: Text('デッキ「$deckName」のすべてのカードを削除しますか？\n\nこの操作は元に戻せません。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('削除する'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    // --- 処理開始 ---
    if (!mounted) return; // 非同期ギャップ後のmountedチェック
    setState(() {
      isProcessing = true; // ★ 画面ロック開始
      _progressText = '削除処理を準備中...'; // ★ 初期メッセージ設定
    });

    final SyncService syncService = SyncService();
    bool wasSyncActive = false;

    try {
      // 同期停止
      wasSyncActive = await _isSyncActive();
      if (wasSyncActive) {
        print('DeckCardListScreen - 自動同期を一時停止');
        syncService.stopAutoSync();
      }

      // --- 削除処理本体 (tryブロック内) ---
      final cardBox = HiveService.getCardBox();
      final isLoggedIn = FirebaseService.getUserId() != null;

      // 1. 削除対象特定
      _updateProgress('削除対象のカードを特定中...');
      final cardsToDelete = <dynamic, FlashCard>{};
      final deletedCardKeys = <String>[];
      final initialDeckCards =
          cardBox.values
              .where((card) => !card.isDeleted && card.deckName == deckName)
              .toList();
      final initialDeckCardCount = initialDeckCards.length;
      _updateProgress('削除準備中: デッキ「$deckName」内の $initialDeckCardCount 枚のカードを検出');

      if (initialDeckCardCount == 0) {
        _updateProgress('削除するカードがありません');
        await Future.delayed(const Duration(seconds: 1));
        // 早期リターンの場合も isProcessing を false にする
        if (mounted) {
          setState(() => isProcessing = false);
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('削除するカードがありません')));
        }
        return;
      }

      try {
        for (var i = 0; i < cardBox.length; i++) {
          final key = cardBox.keyAt(i);
          final card = cardBox.getAt(i);
          if (card != null && !card.isDeleted && card.deckName == deckName) {
            cardsToDelete[key] = card;
            deletedCardKeys.add(key.toString());
          }
          if (i % (cardBox.length ~/ 10 + 1) == 0) {
            _updateProgress('カードをスキャン中... (${i + 1}/${cardBox.length})');
          }
        }
        _updateProgress('削除対象: ${cardsToDelete.length}枚を特定');
        if (cardsToDelete.isEmpty) throw Exception("削除対象カード特定後0件");
      } catch (e) {
        _updateProgress('カード特定中にエラー: $e');
        rethrow; // エラーを上位に投げる
      }

      // 2. ローカル削除
      int deletedLocalCount = 0;
      int totalCards = cardsToDelete.length;
      _updateProgress('ローカル削除開始 (0/$totalCards)');
      try {
        int counter = 0;
        for (final entry in cardsToDelete.entries) {
          await cardBox.delete(entry.key);
          deletedLocalCount++;
          counter++;
          if (counter % (totalCards ~/ 10 + 1) == 0 || counter % 10 == 0) {
            _updateProgress('ローカル削除中... ($counter/$totalCards)');
          }
        }
        _updateProgress('ローカル削除完了 ($deletedLocalCount/$totalCards)');
      } catch (e) {
        _updateProgress('ローカル削除中にエラー: $e');
        rethrow;
      }

      // 3. ディスク保存
      _updateProgress('ディスク保存中...');
      try {
        await HiveService.safeCompact();
        _updateProgress('ディスク保存完了');
      } catch (e) {
        _updateProgress('データ保存中にエラー: $e');
        rethrow;
      }

      // 3.1 ローカル削除検証 & 再試行
      _updateProgress('削除検証中...');
      bool localDeletionVerified = await _verifyLocalDeletion(
        deckName,
        cardsToDelete.keys.toList(),
      );
      _updateProgress('検証結果: ${localDeletionVerified ? "成功" : "失敗"}');
      if (!localDeletionVerified) {
        _updateProgress('検証失敗、再削除中...');
        try {
          final remainingCards = cardBox.values
              .where((card) => !card.isDeleted && card.deckName == deckName)
              .toList();
          int retryCount = 0;
          for (final card in remainingCards) {
            for (int i = 0; i < cardBox.length; i++) {
              final c = cardBox.getAt(i);
              final k = cardBox.keyAt(i);
              if (c != null &&
                  c.question == card.question &&
                  c.answer == card.answer &&
                  c.deckName == card.deckName) {
                await cardBox.delete(k);
                retryCount++;
                _updateProgress(
                  'カードを再削除中... ($retryCount/${remainingCards.length})',
                );
                break;
              }
            }
          }
          _updateProgress('変更を再保存中...');
          await HiveService.safeCompact();
          _updateProgress('再削除・再保存完了');
        } catch (e) {
          _updateProgress('カード再削除中にエラー: $e');
          // 再削除に失敗しても続行
        }
      }

      // 4. Firebase同期 (一方向)
      bool cloudSyncSuccess = false;
      bool isNetworkError = false;
      String errorMessage = '';
      if (isLoggedIn) {
        _updateProgress('クラウド同期中...');
        try {
          // delete_deck_cards は Firestore docId が必須（Hiveキーでは削除できない）
          final firestoreIdsToDelete = <String>[];
          for (final card in cardsToDelete.values) {
            final id = (card.firestoreId != null && card.firestoreId!.isNotEmpty)
                ? card.firestoreId!
                : card.id;
            if (id.isNotEmpty) {
              firestoreIdsToDelete.add(id);
            }
          }
          final syncResult = await SyncService.syncOperationToCloud(
            'delete_deck_cards',
            {
              'deckName': deckName,
              'firestoreIds': firestoreIdsToDelete,
            },
          );
          cloudSyncSuccess = syncResult['success'] as bool;
          isNetworkError = syncResult['isNetworkError'] as bool;
          errorMessage = syncResult['message'] as String;
          _updateProgress('クラウド同期完了: ${cloudSyncSuccess ? "成功" : "失敗"}');
          if (!cloudSyncSuccess) {
            await Future.delayed(const Duration(seconds: 1));
          }
        } catch (e) {
          _updateProgress('クラウド同期エラー: $e');
          cloudSyncSuccess = false;
          if (e.toString().contains('network') ||
              e.toString().contains('socket') ||
              e.toString().contains('connection') ||
              e.toString().contains('timeout') ||
              e.toString().contains('unavailable')) {
            isNetworkError = true;
            errorMessage = 'ネットワーク接続エラー: $e';
          }
          await Future.delayed(const Duration(seconds: 1));
        }
      } else {
        cloudSyncSuccess = true;
        _updateProgress('クラウド同期スキップ (未ログイン)');
      }

      // --- 正常完了 ---
      _updateProgress('すべての処理が完了しました');
      await Future.delayed(const Duration(seconds: 1));

      // 正常完了時も isProcessing を false に
      if (mounted) {
        setState(() {
          isProcessing = false; // ★ 画面ロック解除
          _progressText = null;
        });

        // ネットワークエラーがあった場合は警告ダイアログを表示
        if (isNetworkError == true) {
          await showDialog(
            context: context,
            builder: (BuildContext context) {
              return AlertDialog(
                title: const Text('ネットワークエラー'),
                content: Text(
                  'カードはローカルで削除されましたが、クラウドとの同期に失敗しました。\n\n$errorMessage\n\nネットワーク接続を確認した後、アプリを再起動して再度同期をお試しください。',
                ),
                actions: <Widget>[
                  TextButton(
                    child: const Text('OK'),
                    onPressed: () {
                      Navigator.of(context).pop();
                    },
                  ),
                ],
              );
            },
          );
        }
      }

      // UI更新と結果表示
      if (mounted) {
        _loadCards();
        final message = isNetworkError
            ? 'ローカル削除は完了しましたが、ネットワーク接続エラーによりクラウド同期に失敗しました'
            : cloudSyncSuccess
                ? 'デッキ「${widget.deck.deckName}」から${cardsToDelete.length}枚のカードを削除しました'
                : 'ローカル削除は完了しましたが、クラウド同期に失敗しました: $errorMessage';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: isNetworkError ? Colors.red : null,
          ),
        );
      }
    } catch (e) {
      // --- エラー発生時 ---
      print('DeckCardListScreen - カード削除中に予期せぬエラー: $e');
      if (mounted) _updateProgress('エラー発生: $e');
      await Future.delayed(const Duration(seconds: 2));

      // エラー時も isProcessing を false にしてロック解除
      if (mounted) {
        setState(() {
          isProcessing = false; // ★ 画面ロック解除
          _progressText = null;
        });
      }

      // エラーメッセージ表示
      if (mounted) {
        bool isNetworkError = e.toString().contains('network') ||
            e.toString().contains('socket') ||
            e.toString().contains('connection') ||
            e.toString().contains('timeout') ||
            e.toString().contains('unavailable');

        String message = isNetworkError
            ? 'ネットワーク接続エラーのためカード削除処理に失敗しました'
            : 'カード削除中にエラーが発生しました: $e';

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: isNetworkError ? Colors.red : null,
          ),
        );
        _loadCards();
      }
    } finally {
      // --- 最後に必ず実行 ---
      // 同期再開
      if (wasSyncActive && mounted) {
        print('DeckCardListScreen - 自動同期を再開します');
        await Future.delayed(const Duration(seconds: 1));
        syncService.startAutoSync();
      }
      // isProcessing の解除は try/catch の中で行うため、ここでは不要
    }
  }

  // _isSyncActive, _verifyLocalDeletion は変更なし
  Future<bool> _isSyncActive() async {
    // SyncServiceから現在の自動同期状態を取得する実装が必要
    // 例: return SyncService.instance.isAutoSyncActive;
    return true; // 仮に常に有効としておく
  }

  Future<bool> _verifyLocalDeletion(
    String deckName,
    List<dynamic> deletedKeys,
  ) async {
    try {
      final cardBox = HiveService.getCardBox();
      final remainingCards =
          cardBox.values
              .where((card) => !card.isDeleted && card.deckName == deckName)
              .toList();
      bool allKeysDeleted = true;
      for (final key in deletedKeys) {
        if (cardBox.containsKey(key)) {
          allKeysDeleted = false;
          break;
        }
      }
      return remainingCards.isEmpty && allKeysDeleted;
    } catch (e) {
      return false;
    }
  }

  // 進捗テキストを更新するシンプルなメソッド
  void _updateProgress(String message) {
    print('進捗: $message');
    // mountedチェックを追加
    if (mounted) {
      setState(() {
        _progressText = message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // ★ PopScope で Scaffold 全体をラップ
    return PopScope(
      canPop: !isProcessing, // isProcessing中はシステムナビゲーションの戻るを無効化
      onPopInvoked: (didPop) {
        if (isProcessing && !didPop) {
          // 戻る操作がブロックされた場合にメッセージ表示 (任意)
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('処理が完了するまでお待ちください')));
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            widget.deck.deckName,
            style: TextStyle(color: Colors.white),
          ),
          backgroundColor: Colors.black,
          actions: [
            IconButton(
              icon: const Icon(Icons.settings, color: Colors.white),
              onPressed: isProcessing
                  ? null
                  : () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) =>
                              DeckEditScreen(deckKey: widget.deck.key),
                        ),
                      ).then((result) {
                        if (result == true) {
                          if (mounted) Navigator.pop(context);
                        } else {
                          if (mounted) setState(() => _loadCards());
                        }
                      });
                    },
              color: isProcessing ? Colors.white30 : Colors.white,
            ),
          ],
          // AppBarの戻るボタンも制御 (leading を isProcessing で出し入れ)
          leading: isProcessing
              ? Container() // 処理中は非表示
              : BackButton(color: Colors.white), // 通常は表示
        ),
        backgroundColor: Colors.black,
        // ★ body を Stack でラップ
        body: Stack(
          children: [
            // --- メインコンテンツ ---
            cards.isEmpty
                ? const Center(
                    child: Text(
                      'このデッキにはカードがありません',
                      style: TextStyle(color: Colors.white, fontSize: 18),
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: ListView.builder(
                      itemCount: cards.length,
                      itemBuilder: (context, index) {
                        final card = cards[index];
                        return Card(
                          color: Colors.grey[850],
                          elevation: 3.0,
                          margin: const EdgeInsets.symmetric(vertical: 4.0),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12.0),
                            side: BorderSide(
                              color: Colors.grey[700]!,
                              width: 1.0,
                            ),
                          ),
                          child: ListTile(
                            leading: null,
                            title: Text(
                              card.question,
                              style: const TextStyle(
                                fontSize: 16,
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(card.answer,
                                style: TextStyle(fontSize: 14)),
                            trailing: Wrap(
                              spacing: -8, // アイコン間のスペースを調整
                              children: [
                                // if (_isDue(card)) // 期日アイコン  <-- この条件とアイコン表示を削除
                                //   Icon(Icons.notification_important,
                                //       color: Colors.orange),
                              ],
                            ),
                            tileColor:
                                null, // <-- _getTileColor(card) から null に変更
                            onTap: isProcessing
                                ? null
                                : () async {
                                    final result = await Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (context) => CardEditScreen(
                                          cardKey: card.key,
                                        ),
                                      ),
                                    );
                                    if (result == true && mounted) {
                                      setState(() => _loadCards());
                                    }
                                  },
                            enabled: !isProcessing,
                          ),
                        );
                      },
                    ),
                  ),

            // --- ★処理中オーバーレイ ---
            if (isProcessing)
              Positioned.fill(
                // 画面全体を覆う
                child: Container(
                  // ModalBarrierでタップイベントを吸収
                  color: Colors.black.withOpacity(0.7),
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CircularProgressIndicator(color: Colors.white),
                        SizedBox(height: 20),
                        Text(
                          _progressText ?? '処理中...',
                          style: TextStyle(color: Colors.white, fontSize: 16),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: isProcessing
              ? null
              : () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => CardEditScreen()),
                  ).then((_) {
                    if (mounted) setState(() => _loadCards());
                  });
                },
          backgroundColor: isProcessing
              ? Colors.grey
              : Theme.of(context).colorScheme.primary,
          child: Icon(
            Icons.add,
            color: isProcessing
                ? Colors.grey
                : Theme.of(context).colorScheme.onPrimary,
          ),
        ),
      ),
    );
  }

  Widget _buildLeadingIcon(FlashCard card) {
    return Icon(Icons.folder); // 仮のアイコン
  }

  bool _isDue(FlashCard card) {
    // card.nextReview が null の場合は、そもそも isBefore の比較対象にならないようにする
    // null でない場合のみ、期日かどうかを判定する
    return card.nextReview != null && card.nextReview!.isBefore(DateTime.now());
  }

  Color? _getTileColor(FlashCard card) {
    // if (_isDue(card)) return Colors.orange[50]; <-- この行をコメントアウトまたは削除
    return null; // デフォルトの色
  }
}
