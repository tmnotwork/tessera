// ignore_for_file: avoid_print, use_build_context_synchronously, unused_local_variable, deprecated_member_use, prefer_const_constructors, curly_braces_in_flow_control_structures, unnecessary_brace_in_string_interps, prefer_const_declarations

import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:yomiage/models/deck.dart';
import 'package:yomiage/models/flashcard.dart';
import 'package:yomiage/services/hive_service.dart';
import 'package:yomiage/services/firebase_service.dart';
import 'package:yomiage/services/sync_service.dart';
import 'package:yomiage/services/sync/pending_operations.dart';
import 'package:yomiage/services/sync/critical_operation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:async';

class DeckEditScreen extends StatefulWidget {
  final dynamic deckKey;
  const DeckEditScreen({super.key, required this.deckKey});

  @override
  State<DeckEditScreen> createState() => _DeckEditScreenState();
}

class _DeckEditScreenState extends State<DeckEditScreen> {
  late Box<Deck> deckBox;
  late Box<FlashCard> cardBox;
  late Deck deck;
  late TextEditingController _deckNameController;
  late TextEditingController _descriptionController;
  int _cardCount = 0;
  bool isProcessing = false;
  String? _progressText;
  late bool _isArchived;

  @override
  void initState() {
    super.initState();
    deckBox = HiveService.getDeckBox();
    cardBox = HiveService.getCardBox();
    if (widget.deckKey == null) {
      _handleInitializationError("デッキ情報の読み込みに失敗しました。");
      return;
    } else {
      final fetchedDeck = deckBox.get(widget.deckKey);
      if (fetchedDeck == null) {
        _handleInitializationError("指定されたデッキが見つかりません。");
        return;
      } else {
        deck = fetchedDeck;
        _deckNameController = TextEditingController(text: deck.deckName);
        _descriptionController = TextEditingController(text: deck.description);
        _isArchived = deck.isArchived;
        _updateCardCount();
      }
    }
  }

  void _handleInitializationError(String message) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
        Navigator.of(context).pop();
      }
    });
    _deckNameController = TextEditingController();
    _descriptionController = TextEditingController();
    deck = Deck(id: '', deckName: '');
  }

  @override
  void dispose() {
    _deckNameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.deckKey != null) {
      final currentDeck = deckBox.get(widget.deckKey);
      if (currentDeck != null) {
        deck = currentDeck;
        _updateCardCount();
        print(
            'DeckEditScreen - didChangeDependencies: カード数を更新しました: $_cardCount');
      } else {
        print('DeckEditScreen - didChangeDependencies: デッキが見つかりません。');
        if (mounted) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text("デッキが見つかりません。再読み込みしてください。")));
          });
        }
      }
    }
  }

  void _updateCardCount() {
    if (!mounted) return;
    try {
      cardBox = HiveService.getCardBox();
      if (deck.key != null) {
        _cardCount = cardBox.values
            .where((card) => card.deckName == deck.deckName)
            .length;
      } else {
        _cardCount = 0;
      }
    } catch (e) {
      print("Error updating card count: $e");
      _cardCount = 0;
    }
    setState(() {});
  }

  void _updateProgress(String message) {
    print('進捗 (DeckEditScreen): $message');
    if (mounted) {
      setState(() {
        _progressText = message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final buttonStyle = ElevatedButton.styleFrom(
      backgroundColor: const Color(0xFF0D47A1),
      foregroundColor: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      minimumSize: const Size(280, 48),
      maximumSize: const Size(280, 48),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      disabledBackgroundColor: Colors.grey.shade800,
      disabledForegroundColor: Colors.grey.shade500,
    );

    return PopScope(
      canPop: !isProcessing,
      onPopInvoked: (didPop) {
        if (isProcessing && !didPop) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('処理が完了するまでお待ちください')),
          );
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('デッキ編集'),
          leading: isProcessing
              ? Container()
              : IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () {
                    if (mounted) Navigator.of(context).pop();
                  },
                ),
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
        ),
        backgroundColor: Colors.black,
        body: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 600),
            child: Stack(
              children: [
                SingleChildScrollView(
                  physics: isProcessing ? NeverScrollableScrollPhysics() : null,
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'デッキ名',
                          style: TextStyle(fontSize: 16, color: Colors.white70),
                        ),
                        TextField(
                          controller: _deckNameController,
                          style: const TextStyle(
                              fontSize: 20, color: Colors.white),
                          decoration: const InputDecoration(
                            hintText: 'デッキ名を入力',
                            hintStyle: TextStyle(color: Colors.white54),
                            enabledBorder: UnderlineInputBorder(
                                borderSide: BorderSide(color: Colors.white54)),
                            focusedBorder: UnderlineInputBorder(
                                borderSide: BorderSide(color: Colors.white)),
                          ),
                          enabled: !isProcessing,
                        ),
                        // ★★★ ID表示を追加 ★★★
                        const SizedBox(height: 8),
                        Padding(
                          padding: const EdgeInsets.only(left: 4.0),
                          child: Text(
                            'Hive: ${deck.key} / Firebase: ${deck.id}',
                            style: const TextStyle(
                                color: Colors.white54, fontSize: 10),
                          ),
                        ),
                        // ★★★ ここまで追加 ★★★
                        const SizedBox(height: 24),
                        const Text(
                          '説明',
                          style: TextStyle(fontSize: 16, color: Colors.white70),
                        ),
                        TextField(
                          controller: _descriptionController,
                          style: const TextStyle(
                              fontSize: 16, color: Colors.white),
                          decoration: const InputDecoration(
                            hintText: 'デッキの説明を入力してください',
                            hintStyle: TextStyle(color: Colors.white54),
                            enabledBorder: UnderlineInputBorder(
                                borderSide: BorderSide(color: Colors.white54)),
                            focusedBorder: UnderlineInputBorder(
                                borderSide: BorderSide(color: Colors.white)),
                          ),
                          maxLines: 3,
                          enabled: !isProcessing,
                        ),
                        const SizedBox(height: 32),
                        Center(
                          child: Text(
                            'このデッキには $_cardCount 枚のカードがあります',
                            style: const TextStyle(
                                fontSize: 16, color: Colors.white70),
                          ),
                        ),
                        const SizedBox(height: 16),
                        if (_cardCount > 0)
                          Center(
                            child: ElevatedButton(
                              onPressed:
                                  isProcessing ? null : _confirmResetStudyData,
                              style: buttonStyle,
                              child: const Text('学習状況をリセット',
                                  style: TextStyle(color: Colors.white)),
                            ),
                          ),
                        const SizedBox(height: 16),
                        if (_cardCount > 0)
                          Center(
                            child: ElevatedButton(
                              onPressed:
                                  isProcessing ? null : _confirmMoveCards,
                              style: buttonStyle,
                              child: const Text('カードを別のデッキに移動する',
                                  style: TextStyle(color: Colors.white)),
                            ),
                          ),
                        const SizedBox(height: 16),
                        if (_cardCount > 0)
                          Center(
                            child: ElevatedButton(
                              onPressed:
                                  isProcessing ? null : _confirmClearCards,
                              style: buttonStyle,
                              child: const Text('このデッキのカードをすべて削除',
                                  style: TextStyle(color: Colors.white)),
                            ),
                          ),
                        const SizedBox(height: 16),
                        Center(
                          child: ElevatedButton(
                            onPressed: isProcessing ? null : _confirmDeleteDeck,
                            style: buttonStyle,
                            child: const Text('このデッキを削除',
                                style: TextStyle(color: Colors.white)),
                          ),
                        ),
                        const SizedBox(height: 32),
                        Center(
                          child: ElevatedButton(
                            onPressed: isProcessing ? null : _saveDeck,
                            style: buttonStyle,
                            child: const Text('保存',
                                style: TextStyle(color: Colors.white)),
                          ),
                        ),
                        const SizedBox(height: 24),
                        SwitchListTile(
                          title: const Text('アーカイブ',
                              style:
                                  TextStyle(fontSize: 16, color: Colors.white)),
                          subtitle: Text(
                            _isArchived
                                ? 'アーカイブ済み (ホーム画面に表示されません)'
                                : 'ホーム画面に表示されます',
                            style: TextStyle(color: Colors.white70),
                          ),
                          value: _isArchived,
                          onChanged: isProcessing
                              ? null
                              : (bool value) {
                                  setState(() {
                                    _isArchived = value;
                                  });
                                  _saveArchiveStatus(value);
                                },
                          activeColor: Colors.blueAccent,
                          inactiveThumbColor: Colors.grey,
                          contentPadding: EdgeInsets.zero,
                        ),
                      ],
                    ),
                  ),
                ),
                if (isProcessing)
                  Positioned.fill(
                    child: Container(
                      color: Colors.black.withOpacity(0.7),
                      child: Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            CircularProgressIndicator(color: Colors.white),
                            SizedBox(height: 20),
                            Text(
                              _progressText ?? '処理中...',
                              style:
                                  TextStyle(color: Colors.white, fontSize: 16),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _confirmResetStudyData() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('学習状況のリセット確認', style: TextStyle(color: Colors.white)),
        content: Text(
            'このデッキに属するカード $_cardCount 枚の学習状況をすべてリセットします。\n\n暗記状態や出題スケジュールがリセットされ、すべてのカードが今日出題されるようになります。\n\nよろしいですか？',
            style: const TextStyle(color: Colors.white)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('キャンセル', style: TextStyle(color: Colors.white)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: Colors.orange,
            ),
            child: const Text('リセットする', style: TextStyle(color: Colors.orange)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _resetStudyData();
    }
  }

  Future<void> _resetStudyData() async {
    if (!mounted) return;
    // ★★★ 追加: 重要操作開始 - 新しいサービスを使用 ★★★
    CriticalOperationService.startCriticalOperation();
    try {
      setState(() {
        isProcessing = true;
        _progressText = '学習状況をリセット中...';
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('学習状況をリセット中...'), duration: Duration(seconds: 1)));
      final cardsToReset = cardBox.values
          .where((card) => card.deckName == deck.deckName)
          .toList();
      if (cardsToReset.isEmpty) {
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('リセット対象のカードがありません。'),
              backgroundColor: Colors.orange));
        // ★★★ 修正: isProcessingをfalseにする前に重要操作終了 ★★★
        // setState(() => isProcessing = false);
        // return;
      } else {
        _updateProgress('ローカルデータをリセット中...');
        int counter = 0;
        final totalCards = cardsToReset.length;

        for (final card in cardsToReset) {
          card.resetLearningStatus();
          card.updatedAt = DateTime.now().millisecondsSinceEpoch;
          await card.save();
          counter++;
          _updateProgress('ローカルリセット ($counter/$totalCards)...');
        }
        _updateProgress('ローカルリセット完了');

        // クラウド同期処理をバッチ書き込みに変更
        final userId = FirebaseService.getUserId();
        if (userId != null) {
          _updateProgress('Firebaseと同期中...');
          final batch = FirebaseService.firestore.batch();
          final cardsToUpdateInFirebase = cardsToReset
              .where((card) =>
                  card.firestoreId != null && card.firestoreId!.isNotEmpty)
              .toList();

          print('リセット対象のFirebaseカード: ${cardsToUpdateInFirebase.length} 件');

          if (cardsToUpdateInFirebase.isNotEmpty) {
            // バッチ処理のサイズ制限を考慮 (Firestoreは500件まで)
            const batchSize = 400; // 余裕を持たせる
            for (int i = 0;
                i < cardsToUpdateInFirebase.length;
                i += batchSize) {
              final end = (i + batchSize < cardsToUpdateInFirebase.length)
                  ? i + batchSize
                  : cardsToUpdateInFirebase.length;
              final batchCards = cardsToUpdateInFirebase.sublist(i, end);

              for (final card in batchCards) {
                final docRef = FirebaseService.firestore
                    .collection('users')
                    .doc(userId)
                    .collection('cards')
                    .doc(card.firestoreId!);

                batch.update(docRef, {
                  'repetitions': 0,
                  'eFactor': 2.5,
                  'intervalDays': 0,
                  'nextReview': null, // Firestoreにはnullを設定
                  'deckName': _deckNameController.text,
                  'updatedAt':
                      card.updatedAt, // ローカルのupdatedAt (int?) を使用 <- 変更後
                });
              }
              _updateProgress('バッチ ${i ~/ batchSize + 1} を準備中...');
            }

            try {
              _updateProgress('Firebaseにバッチ書き込み実行中...');
              await batch.commit();
              print('Firebaseへのバッチ書き込みが完了しました。');
              _updateProgress('Firebase同期完了。');
            } catch (e) {
              print('Firebaseへのバッチ書き込みエラー: $e');
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Firebaseとの同期中にエラーが発生しました: $e')),
              );
              // エラーが発生しても処理は続行するが、フラグを立てるなどしても良い
            }
          } else {
            _updateProgress('Firebaseに更新するカードはありません。');
          }
        } else {
          _updateProgress('ログインしていないため、Firebaseとの同期はスキップされました。');
        }

        await HiveService.refreshDatabase();
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('${cardsToReset.length}枚のカードの学習状況をリセットしました'),
              backgroundColor: Colors.green));
      } // <- else ブロックの閉じ括弧
    } catch (e) {
      print("Error resetting study data: $e");
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('リセット中にエラーが発生しました: $e'),
            backgroundColor: Colors.red));
    } finally {
      // ★★★ 追加: 重要操作終了 - 新しいサービスを使用 ★★★
      CriticalOperationService.endCriticalOperation();
      if (mounted) {
        setState(() {
          isProcessing = false;
          _progressText = null;
        });
      }
    }
  }

  Future<void> _confirmMoveCards() async {
    if (isProcessing) return;
    // 利用可能なデッキのリストを取得（現在のデッキを除く）
    final availableDecks = deckBox.values
        .where((d) => d.deckName != deck.deckName)
        .toList()
      ..sort((a, b) => a.deckName.compareTo(b.deckName));

    if (availableDecks.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('移動先デッキがありません。他のデッキを作成してください。'),
          backgroundColor: Colors.orange));
      return;
    }

    // 移動先デッキの選択状態を管理する変数
    String? selectedDeckName = availableDecks.first.deckName;

    final action = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          backgroundColor: Colors.grey[900],
          title: const Text('カードの移動', style: TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'デッキ「${deck.deckName}」のカード $_cardCount 枚を別のデッキに移動します。',
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 16),
              const Text(
                'カードの移動先：',
                style: TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: Colors.grey[800],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: DropdownButton<String>(
                  value: selectedDeckName,
                  isExpanded: true,
                  dropdownColor: Colors.grey[800],
                  style: const TextStyle(color: Colors.white),
                  underline: Container(),
                  onChanged: (newValue) {
                    if (newValue != null) {
                      setState(() => selectedDeckName = newValue);
                    }
                  },
                  items: availableDecks.map((deck) {
                    return DropdownMenuItem<String>(
                      value: deck.deckName,
                      child: Text(deck.deckName),
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop('cancel'),
              child: const Text('キャンセル', style: TextStyle(color: Colors.white)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(selectedDeckName),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0D47A1),
              ),
              child: const Text('移動する', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );

    if (action != null && action != 'cancel') {
      await _moveCards(action);
    }
  }

  Future<void> _moveCards(String targetDeckName) async {
    if (isProcessing) return;
    setState(() {
      isProcessing = true;
      _progressText = 'カード移動を準備中...';
    });

    final SyncService syncService = SyncService();
    bool wasSyncActive = false;

    try {
      wasSyncActive = await _isSyncActive();
      if (wasSyncActive) {
        syncService.stopAutoSync();
        print('DeckEditScreen - 自動同期を一時停止');
      }

      final String sourceDeckName = deck.deckName;
      _updateProgress('移動対象のカードを検索中...');
      var currentCardBox = HiveService.getCardBox();

      final cardsToMove = currentCardBox.values
          .where((card) => card.deckName == sourceDeckName)
          .toList();

      final int totalCards = cardsToMove.length;
      _updateProgress('移動対象: $totalCards 枚');

      if (totalCards == 0) {
        _updateProgress('移動するカードがありません');
        await Future.delayed(const Duration(seconds: 1));
        if (mounted) setState(() => isProcessing = false);
        if (mounted)
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('移動するカードがありません')));
        return;
      }

      _updateProgress('カードを「$targetDeckName」に移動中...');
      int successCount = 0;
      List<String> errors = [];
      int counter = 0;

      try {
        for (final card in cardsToMove) {
          card.deckName = targetDeckName;
          card.updateTimestamp();
          await card.save();
          successCount++;
          counter++;
          _updateProgress(
              'カード移動中 ($counter/$totalCards)...\n処理済み: ${((counter / totalCards) * 100).toStringAsFixed(1)}%');
          await Future.delayed(const Duration(milliseconds: 20));
        }
        _updateProgress('カード移動完了: $successCount / $totalCards枚');

        _updateProgress('データベースを更新中...');
        await HiveService.safeCompact();
        await HiveService.refreshDatabase();
        _updateCardCount();
        if (mounted) setState(() {});
        _updateProgress('カードの移動が完了しました');
        await Future.delayed(const Duration(milliseconds: 500));
      } catch (e) {
        _updateProgress('カード移動中にエラー: $e');
        errors.add('Error: $e');
      }

      bool cloudSyncAttempted = false;
      bool cloudSyncSuccess = false;

      if (FirebaseService.getUserId() != null) {
        _updateProgress('クラウド同期を開始...');
        cloudSyncAttempted = true;
        try {
          // クラウド同期処理（カードごとに更新通知を送信）
          for (final card in cardsToMove) {
            await FirebaseService.saveCard(card, FirebaseService.getUserId()!);
          }
          cloudSyncSuccess = true;
          _updateProgress('クラウド同期完了');
        } catch (e) {
          _updateProgress('クラウド同期中にエラー: $e');
          cloudSyncSuccess = false;
          errors.add('Cloud sync error: $e');
        }
      } else {
        _updateProgress('クラウド同期スキップ (未ログイン)');
        cloudSyncSuccess = true;
      }

      _updateProgress('処理完了');
      await Future.delayed(const Duration(seconds: 1));

      if (mounted) {
        setState(() {
          isProcessing = false;
          _progressText = null;
        });
      }

      if (mounted) {
        String message =
            'カード移動完了: $successCount / $totalCards枚を「$targetDeckName」に移動しました';
        if (errors.isNotEmpty) message += '\n(${errors.length}件のエラー発生)';
        if (cloudSyncAttempted && !cloudSyncSuccess)
          message += '\nクラウド同期に失敗しました。';

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: errors.isEmpty && cloudSyncSuccess
                ? Colors.green
                : Colors.orange,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      print('カード移動処理中に予期せぬエラー: $e');
      if (mounted) {
        _updateProgress('エラー発生: $e');
        await Future.delayed(const Duration(seconds: 2));
        setState(() {
          isProcessing = false;
          _progressText = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('エラーが発生しました: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (wasSyncActive && mounted) {
        syncService.startAutoSync();
        print('DeckEditScreen - 自動同期を再開');
      }

      // 処理中フラグは必ず解除する
      if (mounted && isProcessing) {
        setState(() {
          isProcessing = false;
          _progressText = null;
        });
      }
    }
  }

  Future<void> _confirmClearCards() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('カードの削除確認', style: TextStyle(color: Colors.white)),
        content: Text(
            'このデッキに属するカード $_cardCount 枚をすべて削除します。\n\nこの操作は元に戻せません。よろしいですか？',
            style: const TextStyle(color: Colors.white)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('キャンセル', style: TextStyle(color: Colors.white)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('削除する', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _clearCards();
    }
  }

  Future<void> _clearCards() async {
    if (!mounted) return;
    setState(() {
      isProcessing = true;
      _progressText = 'カード削除を準備中...';
    });

    final SyncService syncService = SyncService();
    bool wasSyncActive = false;

    try {
      wasSyncActive = await _isSyncActive();
      if (wasSyncActive) {
        syncService.stopAutoSync();
        print('DeckEditScreen - 自動同期を一時停止');
      }

      final String deckName = deck.deckName;
      _updateProgress('削除対象のカードキーを収集...');
      List<dynamic> keysToDelete = [];
      var currentCardBox = HiveService.getCardBox();

      final isDefaultDeck = deckName == 'デフォルト';
      if (isDefaultDeck) {
        _updateProgress('「デフォルト」デッキは特別なシステムデッキです。カードのみ削除します。');
      }

      try {
        int count = 0;
        for (int i = 0; i < currentCardBox.length; i++) {
          final dynamic key = currentCardBox.keyAt(i);
          final FlashCard? card = currentCardBox.getAt(i);
          if (card != null && card.deckName == deckName) {
            keysToDelete.add(key);
            count++;
          }
          if (i % 10 == 0 || i == currentCardBox.length - 1) {
            _updateProgress('キー収集中... ($count 件)');
          }
        }
      } catch (e) {
        _updateProgress('キー収集中にエラー: $e');
        rethrow;
      }

      final int totalCards = keysToDelete.length;
      _updateProgress('削除対象: $totalCards 件');

      if (totalCards == 0) {
        _updateProgress('削除するカードがありません');
        await Future.delayed(const Duration(seconds: 1));
        if (mounted) setState(() => isProcessing = false);
        if (mounted)
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('削除するカードがありません')));
        return;
      }

      // ★★★ 修正点1: Firestore ID の収集を先に行う ★★★
      _updateProgress('削除対象のFirestore IDを収集中...');
      List<String> firestoreIdsToDelete = [];
      final cardBoxForIdCollection = HiveService.getCardBox(); // この時点のBoxを使う
      for (final hiveKey in keysToDelete) {
        final card = cardBoxForIdCollection.get(hiveKey);
        if (card != null &&
            card.firestoreId != null &&
            card.firestoreId!.isNotEmpty) {
          firestoreIdsToDelete.add(card.firestoreId!);
        } else {
          // IDが見つからない場合はログに残す（基本的には発生しないはず）
          print('⚠️ [ID収集時] Firestore ID が見つかりません (Hive Key: $hiveKey)');
        }
      }
      _updateProgress('Firestore ID 収集完了: ${firestoreIdsToDelete.length} 件');
      print('クラウド削除対象のFirestore ID: $firestoreIdsToDelete');
      // ★★★ 修正ここまで ★★★

      _updateProgress('ローカル削除を開始 (0/$totalCards)...');
      int successCount = 0;
      List<String> errors = [];
      // ローカル削除用のBoxを再取得（ID収集中に変更があった場合に備えるのは念のためだが、通常は不要）
      currentCardBox = HiveService.getCardBox();
      final keysSnapshot = List<dynamic>.from(keysToDelete);
      int counter = 0;
      try {
        for (final key in keysSnapshot) {
          await currentCardBox.delete(key); // ここでローカル削除
          successCount++;
          counter++;
          _updateProgress(
              'ローカル削除中 ($counter/$totalCards)件...\n処理済み: ${((counter / totalCards) * 100).toStringAsFixed(1)}%');
          await Future.delayed(const Duration(milliseconds: 50));
        }
        _updateProgress('ローカル削除完了: $successCount / $totalCards件');

        _updateProgress('ローカル変更を保存中...');
        await HiveService.safeCompact();
        await HiveService.refreshDatabase();
        _updateCardCount();
        if (mounted) setState(() {});
        _updateProgress('ローカル削除と更新が完了しました');
        await Future.delayed(const Duration(milliseconds: 500));
      } catch (e) {
        _updateProgress('ローカル削除または保存中にエラー: $e');
        errors.add('Local delete/save error: $e');
      }

      // ★★★ 修正点2: Firestore ID 収集ループを削除し、クラウド同期処理を修正 ★★★
      bool cloudSyncAttempted = false;
      bool cloudSyncSuccess = false;
      // Firestore ID 収集ループは上に移動したので削除

      // クラウド同期: 収集済みの firestoreIdsToDelete を使う
      if (FirebaseService.getUserId() != null &&
          firestoreIdsToDelete.isNotEmpty) {
        // ここで収集済みリストを使う
        _updateProgress('クラウド同期を開始 (削除情報送信)...');
        cloudSyncAttempted = true;
        try {
          int syncSuccessCount = 0;
          final operation = 'delete_card';
          // 収集済みのIDリストを渡す
          final operationData = {'firestoreIds': firestoreIdsToDelete};

          final syncResult =
              await SyncService.syncOperationToCloud(operation, operationData);

          cloudSyncSuccess = syncResult['success'] as bool;
          final bool isNetworkError = syncResult['isNetworkError'] as bool;
          final String errorMessage = syncResult['message'] as String;

          if (cloudSyncSuccess) {
            syncSuccessCount = firestoreIdsToDelete.length;
            _updateProgress(
                'クラウド同期: ${syncSuccessCount}/${firestoreIdsToDelete.length}件の削除指示に成功');
          } else {
            if (isNetworkError) {
              _updateProgress('クラウド同期: ネットワークエラー - $errorMessage');
            } else {
              // 一括失敗時の個別試行ロジックは維持
              _updateProgress('クラウド同期: 一括削除指示に失敗、個別指示を試行中...');
              for (final firestoreId in firestoreIdsToDelete) {
                final singleResult = await SyncService.syncOperationToCloud(
                    'delete_card', {'firestoreId': firestoreId});
                if (singleResult['success'] as bool) syncSuccessCount++;
              }
              _updateProgress(
                  '個別削除指示完了: $syncSuccessCount/${firestoreIdsToDelete.length}件');
            }
          }

          // クラウド削除確認ロジックは維持
          cloudSyncSuccess = syncSuccessCount > 0;

          if (cloudSyncSuccess) {
            _updateProgress('クラウド削除を確認中...');
            await Future.delayed(const Duration(seconds: 2));
            bool verificationSuccess =
                await _verifyCardsDeleted(firestoreIdsToDelete);
            if (!verificationSuccess) {
              _updateProgress('警告: クラウドでのカード削除を確認できませんでした。');
              cloudSyncSuccess = false; // 確認失敗は同期失敗扱い
              await Future.delayed(const Duration(seconds: 2));
            } else {
              _updateProgress('クラウド削除を確認しました。');
              await Future.delayed(const Duration(seconds: 1));
            }
          }
        } catch (e) {
          _updateProgress('クラウド同期中にエラー: $e');
          cloudSyncSuccess = false;
          errors.add('Cloud sync error: $e');
        } finally {
          // finallyブロックは変更なし
        }
      } else if (FirebaseService.getUserId() != null &&
          firestoreIdsToDelete.isEmpty) {
        // ここも収集済みリストで判定
        _updateProgress('クラウド同期スキップ (削除対象のFirestore IDが見つかりません)');
        cloudSyncSuccess = true; // 削除対象がないので成功扱い
      } else {
        _updateProgress('クラウド同期スキップ (未ログイン)');
        cloudSyncSuccess = true; // ログインしていないので同期不要=成功扱い
      }
      // ★★★ 修正ここまで ★★★

      _updateProgress('すべての処理が完了しました');
      await Future.delayed(const Duration(seconds: 1));

      if (mounted) {
        setState(() {
          isProcessing = false;
          _progressText = null;
        });
      }

      if (mounted) {
        final finalCardCount = HiveService.getCardBox()
            .values
            .where((c) => c.deckName == deckName)
            .length;
        String message = 'カード削除完了: $successCount 件 (最終確認: $finalCardCount 枚)';
        if (errors.isNotEmpty) message += '\n(${errors.length}件のエラー発生)';
        if (cloudSyncAttempted && !cloudSyncSuccess)
          message += '\nクラウド同期に失敗または未確認。';

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: errors.isEmpty && cloudSyncSuccess
                ? Colors.green
                : Colors.orange,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      print('カード一括削除処理中に予期せぬエラー: $e');
      if (mounted) {
        _updateProgress('エラー発生: $e');
        await Future.delayed(const Duration(seconds: 2));
        setState(() {
          isProcessing = false;
          _progressText = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('エラーが発生しました: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      // ★★★ 自動同期の即時再開を削除 ★★★
      // if (wasSyncActive && mounted) {
      //   // await Future.delayed(const Duration(seconds: 3));
      //   syncService.startAutoSync();
      //   print('DeckEditScreen - 自動同期を再開');
      // }
      // ★★★ ここまで変更 ★★★

      // 処理中フラグは必ず解除する
      if (mounted && isProcessing) {
        setState(() {
          isProcessing = false;
          _progressText = null;
        });
      }
    }
  }

  Future<void> _saveDeck() async {
    if (isProcessing) return;
    setState(() {
      isProcessing = true;
      _progressText = "デッキ保存中...";
    });
    try {
      String oldName = deck.deckName;
      String newName = _deckNameController.text.trim();
      String description = _descriptionController.text.trim();
      if (newName.isEmpty) throw Exception('デッキ名は必須です');

      if (oldName != newName) {
        bool nameExists = deckBox.values
            .any((d) => d.deckName == newName && d.key != deck.key);
        if (nameExists) throw Exception('同じ名前のデッキが存在します');
      }

      deck.deckName = newName;
      deck.description = description;
      print(
          '[DeckEditScreen] Saving deck ${deck.deckName} with isArchived: $_isArchived');
      deck.isArchived = _isArchived;

      // キー統一: Hiveキーは deck.id（UUID）を使用する
      final dynamic oldHiveKey = deck.key;
      if (deck.id.isEmpty) {
        // 互換: 旧データで id が空の場合は、可能なら既存keyを採用。無理なら新規発番。
        final keyStr = oldHiveKey?.toString();
        deck.id = (keyStr != null && keyStr.isNotEmpty)
            ? keyStr
            : HiveService().generateUniqueId();
      }

      // Phase 2.5: ローカル反映＋pending enqueue（デッキ単位で原子化）
      String? pendingOpId;
      try {
        pendingOpId = await PendingOperationsService.putDeckAndMaybeEnqueue(
          deck,
          hiveKey: deck.id,
        );
        // 旧キーが残っている場合は掃除（同一デッキの二重保持を防ぐ）
        if (oldHiveKey != null && oldHiveKey.toString() != deck.id) {
          try {
            if (deckBox.containsKey(oldHiveKey)) {
              await deckBox.delete(oldHiveKey);
            }
          } catch (_) {}
        }
        print(
            '[DeckEditScreen] Deck ${deck.deckName} saved successfully to Hive (key=${deck.id}).');
      } catch (hiveError) {
        print('[DeckEditScreen] Error saving deck to Hive: $hiveError');
        throw Exception('ローカルデータベースへの保存に失敗しました。');
      }

      _updateProgress('ローカルに保存しました');

      if (oldName != newName) {
        _updateProgress('関連カードのデッキ名を更新中...');
        final cardsToUpdate =
            cardBox.values.where((card) => card.deckName == oldName).toList();
        int cardUpdateCounter = 0;
        final totalCardsToUpdate = cardsToUpdate.length;
        for (var card in cardsToUpdate) {
          card.deckName = newName;
          await card.save();
          cardUpdateCounter++;
          if (cardUpdateCounter % (totalCardsToUpdate ~/ 10 + 1) == 0) {
            _updateProgress(
                'カード更新中 ($cardUpdateCounter/$totalCardsToUpdate)...');
          }
        }
        _updateProgress('カードのデッキ名更新完了 ($totalCardsToUpdate枚)');
      }

      await HiveService.refreshDatabase();

      if (FirebaseService.getUserId() != null) {
        _updateProgress('クラウドに同期中...');
        print('[DeckEditScreen] Syncing deck to Firebase: ${deck.toString()}');
        try {
          await FirebaseService.saveDeck(deck);
          // 即時クラウド同期が成功した場合は該当pending opを削除（重複送信を抑制）
          if (pendingOpId != null && pendingOpId.isNotEmpty) {
            try {
              await PendingOperationsService.deleteOpById(pendingOpId);
            } catch (_) {}
          }
        } catch (_) {
          // 失敗時は pending が残る/または次回の同期で救済される想定
          rethrow;
        }
        _updateProgress('クラウド同期完了');
      }

      _updateProgress('保存完了');
      await Future.delayed(const Duration(seconds: 1));
      if (mounted) {
        setState(() {
          isProcessing = false;
          _progressText = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('デッキを保存しました'), backgroundColor: Colors.green));
        Navigator.pop(context, true);
      }
    } catch (e) {
      print('[DeckEditScreen] デッキ保存エラー: $e');
      if (mounted) {
        setState(() {
          isProcessing = false;
          _progressText = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('保存エラー: $e'), backgroundColor: Colors.red));
      }
    }
  }

  Future<void> _confirmDeleteDeck() async {
    if (isProcessing) return;
    final cardsInDeck =
        cardBox.values.where((card) => card.deckName == deck.deckName).toList();
    if (cardsInDeck.isEmpty) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: Colors.grey[900],
          title: const Text('デッキの削除確認', style: TextStyle(color: Colors.white)),
          content: Text(
              'デッキ「${deck.deckName}」を削除します。\n\nこの操作は元に戻せません。\n\nよろしいですか？',
              style: const TextStyle(color: Colors.white)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('キャンセル', style: TextStyle(color: Colors.white)),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: TextButton.styleFrom(
                foregroundColor: Colors.red,
              ),
              child: const Text('削除する', style: TextStyle(color: Colors.red)),
            ),
          ],
        ),
      );

      if (confirmed == true) {
        await _deleteDeck(deleteCards: false);
      }
    } else {
      // デッキにカードが含まれている場合の確認ダイアログ（移動オプション削除）
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: Colors.grey[900],
          title: const Text('デッキの削除確認', style: TextStyle(color: Colors.white)),
          content: Text(
              'デッキ「${deck.deckName}」には${cardsInDeck.length}枚のカードが含まれています。\n\nデッキを削除すると、これらのカードもすべて削除されます。\nこの操作は元に戻せません。\n\nよろしいですか？',
              style: const TextStyle(color: Colors.white)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('キャンセル', style: TextStyle(color: Colors.white)),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: TextButton.styleFrom(
                foregroundColor: Colors.red,
              ),
              child:
                  const Text('デッキとカードを削除', style: TextStyle(color: Colors.red)),
            ),
          ],
        ),
      );

      if (confirmed == true) {
        await _deleteDeck(deleteCards: true);
      }
    }
  }

  Future<void> _deleteDeck(
      {required bool deleteCards,
      bool moveToDefault = false,
      String? targetDeckName}) async {
    if (isProcessing) return;
    setState(() {
      isProcessing = true;
      _progressText = "デッキ削除中...";
    });
    final SyncService syncService = SyncService();
    bool wasSyncActive = false;
    try {
      wasSyncActive = await _isSyncActive();
      if (wasSyncActive) syncService.stopAutoSync();

      final String deckNameToDelete = deck.deckName;
      final dynamic deckKeyToDelete = deck.key;
      print('デッキ削除開始: 名前=$deckNameToDelete');

      final cards = HiveService.getCardBox();
      final deckBox = HiveService.getDeckBox();
      final isLoggedIn = FirebaseService.getUserId() != null;
      List<String> cardKeysToDeleteOrMoveStr = [];
      final List<String> pendingOpIdsToCleanup = [];
      bool cloudSyncSuccessForCleanup = false;

      if (deckKeyToDelete != null) {
        final cardKeysToProcess = cards.keys.where((key) {
          final card = cards.get(key);
          return card != null && card.deckName == deckNameToDelete;
        }).toList();
        final int cardCount = cardKeysToProcess.length;
        _updateProgress('関連カード処理中 ($cardCount 枚)...');

        if (deleteCards) {
          _updateProgress('カードを削除中...');
          int delCounter = 0;
          for (final key in cardKeysToProcess) {
            // Phase 2.5: ローカル反映＋pending enqueue（カード単位で原子化）
            final card = cards.get(key);
            final opId = await PendingOperationsService.deleteCardAndMaybeEnqueue(
              key,
              firestoreId: card?.firestoreId,
            );
            if (opId != null && opId.isNotEmpty) {
              pendingOpIdsToCleanup.add(opId);
            }
            cardKeysToDeleteOrMoveStr.add(key.toString());
            delCounter++;
            if (delCounter % (cardCount ~/ 10 + 1) == 0) {
              _updateProgress('カード削除中 ($delCounter/$cardCount)...');
            }
          }
          _updateProgress('カード削除完了 ($cardCount 枚)');
        } else if (moveToDefault && targetDeckName != null) {
          // カードの移動先デッキ名を設定
          final moveTarget = targetDeckName;
          _updateProgress('カードを「$moveTarget」デッキに移動中...');

          int moveCounter = 0;
          for (final key in cardKeysToProcess) {
            final card = cards.get(key);
            if (card != null) {
              card.deckName = moveTarget;
              await card.save();
              moveCounter++;
              if (moveCounter % (cardCount ~/ 10 + 1) == 0) {
                _updateProgress('カード移動中 ($moveCounter/$cardCount)...');
              }
            }
          }
          _updateProgress('カード移動完了 ($moveCounter/$cardCount 枚)');
        }
      }

      if (isLoggedIn) {
        _updateProgress('クラウドからデッキを削除中...');
        final Map<String, dynamic> payload = {'deckName': deckNameToDelete};
        if (deleteCards && cardKeysToDeleteOrMoveStr.isNotEmpty) {
          payload['cardKeys'] = cardKeysToDeleteOrMoveStr;
        }
        final syncResult =
            await SyncService.syncOperationToCloud('delete_deck', payload);
        final bool cloudSyncSuccess = syncResult['success'] as bool;
        final bool isNetworkError = syncResult['isNetworkError'] as bool;
        final String errorMessage = syncResult['message'] as String;

        if (isNetworkError) {
          _updateProgress('クラウド同期エラー (ネットワーク接続の問題): $errorMessage');
        } else if (!cloudSyncSuccess) {
          _updateProgress('クラウド同期エラー: $errorMessage');
        } else {
          _updateProgress('クラウドからのデッキ情報削除完了');
        }

        cloudSyncSuccessForCleanup = cloudSyncSuccess;
      }

      if (deckKeyToDelete != null) {
        _updateProgress('ローカルからデッキを削除中...');
        final opId = await PendingOperationsService.deleteDeckAndMaybeEnqueue(
          deckKeyToDelete,
          deckName: deckNameToDelete,
        );
        if (opId != null && opId.isNotEmpty) {
          pendingOpIdsToCleanup.add(opId);
        }
        _updateProgress('ローカルからのデッキ削除完了');
      }

      // Phase 2.5: 即時同期が成功したら、pending op を削除（重複送信を防ぐ）
      if (cloudSyncSuccessForCleanup) {
        for (final opId in pendingOpIdsToCleanup) {
          try {
            await PendingOperationsService.deleteOpById(opId);
          } catch (_) {}
        }
      }

      await HiveService.safeCompact();
      _updateProgress('保存完了');

      _updateProgress('削除処理完了');
      await Future.delayed(const Duration(seconds: 1));

      if (mounted) {
        setState(() {
          isProcessing = false;
          _progressText = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('デッキ「$deckNameToDelete」を削除しました'),
            backgroundColor: Colors.green));
        Navigator.pop(context, true);
      }
    } catch (e) {
      print('デッキ削除エラー: $e');
      if (mounted) {
        setState(() {
          isProcessing = false;
          _progressText = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('削除エラー: $e'), backgroundColor: Colors.red));
      }
    } finally {
      // ★★★ 自動同期の即時再開を削除 ★★★
      // if (wasSyncActive && mounted) {
      //   // await Future.delayed(const Duration(seconds: 3));
      //   syncService.startAutoSync();
      //   print('DeckEditScreen - 自動同期を再開');
      // }
      // ★★★ ここまで変更 ★★★

      // 処理中フラグは必ず解除する
      if (mounted && isProcessing) {
        setState(() {
          isProcessing = false;
          _progressText = null;
        });
      }
    }
  }

  Future<bool> _verifyCardsDeleted(List<String> firestoreIds) async {
    if (firestoreIds.isEmpty) return true;
    print('Firebase上のカード削除確認を開始: ${firestoreIds.length}件');
    try {
      final userId = FirebaseService.getUserId();
      if (userId == null) {
        print('未ログインのためFirebase削除確認をスキップ');
        return true;
      }

      final firestore = FirebaseService.firestore;
      final cardsRef =
          firestore.collection('users').doc(userId).collection('cards');
      int foundCount = 0;

      List<Future<QuerySnapshot>> checks = [];
      for (int i = 0; i < firestoreIds.length; i += 10) {
        final sublist = firestoreIds.sublist(
            i, i + 10 > firestoreIds.length ? firestoreIds.length : i + 10);
        checks
            .add(cardsRef.where(FieldPath.documentId, whereIn: sublist).get());
      }

      final results = await Future.wait(checks);

      for (final snapshot in results) {
        if (snapshot.docs.isNotEmpty) {
          foundCount += snapshot.docs.length;
          for (var doc in snapshot.docs) {
            print('警告: 削除したはずのカードがFirebaseに存在します: ${doc.id}');
          }
        }
      }

      if (foundCount > 0) {
        print('確認結果: ${foundCount}件の削除済みカードがまだ存在します。');
        return false;
      } else {
        print('確認結果: すべての対象カードがFirebaseから削除されていることを確認しました。');
        return true;
      }
    } catch (e) {
      print('Firebase削除確認中にエラー: $e');
      return false;
    }
  }

  Future<bool> _isSyncActive() async {
    return true;
  }

  // ★★★ 追加: アーカイブ状態のみを保存するメソッド ★★★
  Future<void> _saveArchiveStatus(bool isArchived) async {
    // isProcessing フラグはここではチェックしない (他の処理中でもトグルは可能に)
    // ただし、実際の保存処理は非同期で行う
    try {
      deck.isArchived = isArchived;
      print('[DeckEditScreen] Saving archive status: ${deck.isArchived}');
      await deck.save(); // ローカルに即時保存
      print('[DeckEditScreen] Archive status saved to Hive.');

      // クラウド同期 (バックグラウンドで実行、エラーはコンソールに出力)
      if (FirebaseService.getUserId() != null) {
        FirebaseService.saveDeck(deck).then((_) {
          print('[DeckEditScreen] Archive status synced to Firebase.');
        }).catchError((e) {
          print(
              '[DeckEditScreen] Error syncing archive status to Firebase: $e');
          // ここでのエラーはユーザーに直接表示しない (操作を妨げないため)
        });
      }

      // 成功フィードバック
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(isArchived ? 'デッキをアーカイブしました' : 'デッキをアーカイブから戻しました'),
            duration: const Duration(seconds: 2),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      print('[DeckEditScreen] Error saving archive status: $e');
      if (mounted) {
        // エラーフィードバック
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('アーカイブ状態の保存に失敗しました: $e'),
            backgroundColor: Colors.red,
          ),
        );
        // エラーが発生したら状態を元に戻す
        setState(() {
          _isArchived = !isArchived;
        });
      }
    }
  }
}
