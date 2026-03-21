// ignore_for_file: sized_box_for_whitespace, unnecessary_this, use_build_context_synchronously, await_only_futures, avoid_print, unused_local_variable, deprecated_member_use

import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:yomiage/models/flashcard.dart';
import 'package:yomiage/models/deck.dart';
import 'package:yomiage/services/hive_service.dart';
import 'package:yomiage/services/firebase_service.dart';
import 'package:yomiage/services/sync_service.dart';
import 'package:yomiage/services/sync/pending_operations.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart';
import 'dart:async';

class CardEditScreen extends StatefulWidget {
  final dynamic cardKey;
  final String? initialDeckName;
  final String? initialAnswer;
  final String? initialDeckNameForShare;

  const CardEditScreen(
      {Key? key,
      this.cardKey,
      this.initialDeckName,
      this.initialAnswer,
      this.initialDeckNameForShare})
      : super(key: key);

  @override
  State<CardEditScreen> createState() => _CardEditScreenState();
}

class _CardEditScreenState extends State<CardEditScreen> {
  late Box<FlashCard> cardBox;
  late Box<Deck> deckBox;
  final _questionController = TextEditingController();
  final _answerController = TextEditingController();
  final _explanationController = TextEditingController();
  final _chapterController = TextEditingController();
  final _headlineController = TextEditingController();
  final _supplementController = TextEditingController();

  // 選択中のデッキ名
  String? _selectedDeckName;

  // 英語フラグの状態
  bool _questionEnglishFlag = false;
  bool _answerEnglishFlag = true;

  bool _isProcessingAutoSave = false; // 自動保存処理中のフラグ
  String _autoSaveMessage = ''; // 自動保存中のメッセージ
  Set<String> _deletedDeckNames = {}; // 削除済みデッキ名のセット

  @override
  void initState() {
    super.initState();
    cardBox = HiveService.getCardBox();
    deckBox = HiveService.getDeckBox();
    _loadDeletedDeckNames();

    // 共有機能からのデッキ名指定がある場合の処理
    if (widget.initialDeckNameForShare != null) {
      // 共有機能からの場合、自動保存処理中フラグを立て、メッセージを設定
      // initState内で直接setStateを呼ぶのは通常避けるべきだが、
      // この場合は画面表示直後に状態を確定させるため、問題ないと判断
      // WidgetsBinding.instance.addPostFrameCallbackなどを使う方がより丁寧
      _isProcessingAutoSave = true;
      _autoSaveMessage = '「後で調べる」に追加しています...'; // Fixed message
      // 即時setStateを呼んでローディング表示を開始
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });

      _selectedDeckName = widget.initialDeckNameForShare;
      _questionController.text = "後で調べる";
      print('共有機能からの初期デッキ名を設定: ${widget.initialDeckNameForShare}');
      _createDefaultDeckIfNotExists(widget.initialDeckNameForShare!)
          .then((deck) {
        if (deck != null) {
          _questionEnglishFlag = deck.questionEnglishFlag;
          _answerEnglishFlag = deck.answerEnglishFlag;
          print('「${widget.initialDeckNameForShare}」デッキの設定を適用しました。');
        } else {
          print('「${widget.initialDeckNameForShare}」デッキのセットアップに失敗しました。');
          // フォールバックとしてデフォルトの英語フラグを設定
          _questionEnglishFlag = false;
          _answerEnglishFlag = true;
        }
        // デッキ設定後に initialAnswer を設定 (共有時も回答は渡される想定)
        if (widget.initialAnswer != null) {
          _answerController.text = widget.initialAnswer!;
          print('初期回答を設定 (共有フロー): ${widget.initialAnswer}');
        }

        // UIのビルド後に自動保存処理を実行
        //マウントされているか確認してから実行
        if (mounted) {
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            // 再度マウントされているか確認 (非同期処理後に状態が変わる可能性があるため)
            if (mounted) {
              print('自動保存処理を開始します。');
              await _saveCard().catchError((e) {
                // _saveCard内のエラーもここでキャッチできるように
                print('自動保存処理中にエラーが発生しました: $e');
                if (mounted) {
                  setState(() {
                    _isProcessingAutoSave = false; // エラー時はローディング解除
                    // ここでユーザーにエラーを通知するSnackBarなどを表示してもよい
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('自動保存中にエラーが発生しました: $e'),
                        backgroundColor: Theme.of(context).colorScheme.error,
                        duration: const Duration(seconds: 3),
                      ),
                    );
                  });
                }
              });
            }
          });
        }
      }).catchError((error) {
        // _createDefaultDeckIfNotExists のエラー
        if (mounted) {
          print('デッキ準備処理でエラー: $error');
          setState(() {
            _isProcessingAutoSave = false; // エラー時はローディング解除
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('デッキ準備中にエラーが発生しました: $error'),
                backgroundColor: Theme.of(context).colorScheme.error,
                duration: const Duration(seconds: 3),
              ),
            );
          });
        }
      });
    }
    // 既存カード編集の場合 (共有機能からの指定がない場合)
    else if (widget.cardKey != null) {
      final card = cardBox.get(widget.cardKey) as FlashCard;
      _questionController.text = card.question;
      _answerController.text = card.answer; // 通常編集時はカードの値を表示
      _explanationController.text = card.explanation;
      _selectedDeckName = card.deckName;
      _questionEnglishFlag = card.questionEnglishFlag;
      _answerEnglishFlag = card.answerEnglishFlag;
      _chapterController.text = card.chapter;
      _headlineController.text = card.headline;
      _supplementController.text = card.supplement ?? '';
      // initialAnswer がもし渡されていれば上書き (通常編集フローではあまりない想定だが念のため)
      if (widget.initialAnswer != null) {
        _answerController.text = widget.initialAnswer!;
        print('初期回答を設定 (編集フロー、initialAnswerあり): ${widget.initialAnswer}');
      }
    }
    // 新規カード作成の場合 (共有機能からの指定がなく、カードキーもない場合)
    else {
      // initialAnswer があれば設定 (URLスキーム経由など)
      if (widget.initialAnswer != null) {
        _answerController.text = widget.initialAnswer!;
        print('初期回答を設定 (新規フロー): ${widget.initialAnswer}');
      }
      // 初期デッキ名 (initialDeckName) があれば設定
      if (widget.initialDeckName != null) {
        _selectedDeckName = widget.initialDeckName;
        print('初期デッキ名を設定: $_selectedDeckName');
        final initialDeck = HiveService.findDeckByName(widget.initialDeckName!);
        if (initialDeck != null) {
          _questionEnglishFlag = initialDeck.questionEnglishFlag;
          _answerEnglishFlag = initialDeck.answerEnglishFlag;
        } else {
          _questionEnglishFlag = false;
          _answerEnglishFlag = true;
        }
      } else {
        // 前回選択したデッキ名など、既存のフォールバックロジック
        final prefs = HiveService.getSettingsBox();
        final lastSelectedDeck = prefs.get('lastSelectedDeck');
        if (lastSelectedDeck != null &&
            deckBox.values.any((deck) => deck.deckName == lastSelectedDeck)) {
          _selectedDeckName = lastSelectedDeck;
          final selectedDeck =
              deckBox.values.firstWhere((d) => d.deckName == _selectedDeckName);
          _questionEnglishFlag = selectedDeck.questionEnglishFlag;
          _answerEnglishFlag = selectedDeck.answerEnglishFlag;
        } else if (deckBox.isNotEmpty) {
          _selectedDeckName = deckBox.values.first.deckName;
          final selectedDeck = deckBox.values.first;
          _questionEnglishFlag = selectedDeck.questionEnglishFlag;
          _answerEnglishFlag = selectedDeck.answerEnglishFlag;
        } else {
          _selectedDeckName = 'デフォルト'; // 更なるフォールバック
          _createDefaultDeckIfNotExists(_selectedDeckName!).then((deck) {
            if (deck != null) {
              _questionEnglishFlag = deck.questionEnglishFlag;
              _answerEnglishFlag = deck.answerEnglishFlag;
            }
          });
        }
        print('フォールバックまたは前回選択デッキ: $_selectedDeckName');

        // 直前に選択したチャプターをプリセット
        final lastSelectedChapter = prefs.get('lastSelectedChapter');
        if (lastSelectedChapter != null && lastSelectedChapter is String) {
          _chapterController.text = lastSelectedChapter;
        }
      }
    }
  }

  @override
  void dispose() {
    _questionController.dispose();
    _answerController.dispose();
    _explanationController.dispose();
    _chapterController.dispose();
    _headlineController.dispose();
    _supplementController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isProcessingAutoSave) {
      // 自動保存処理中の場合
      return Scaffold(
        backgroundColor:
            Theme.of(context).scaffoldBackgroundColor, // テーマに合わせた背景色
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(
                    Theme.of(context).colorScheme.primary),
              ),
              const SizedBox(height: 24),
              Text(
                _autoSaveMessage, // 設定したメッセージを表示
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Theme.of(context).textTheme.bodyLarge?.color,
                    fontSize: 18),
              ),
            ],
          ),
        ),
      );
    }

    // --- 通常のカード編集画面のビルド処理 (以下は既存のbuildメソッドの内容) ---
    final allDecks = deckBox.values.toList();
    final decks = _filterValidDecks(allDecks);
    final isEditing = widget.cardKey != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          isEditing ? 'カード編集' : 'カード作成',
          style: TextStyle(
              color: Theme.of(context).appBarTheme.titleTextStyle?.color ??
                  Theme.of(context).colorScheme.onSurface),
        ),
        backgroundColor: Theme.of(context).appBarTheme.backgroundColor ??
            Theme.of(context).colorScheme.surface,
        actions: [
          // 保存アイコンボタン
          IconButton(
            icon: Icon(Icons.save,
                color: Theme.of(context).appBarTheme.iconTheme?.color ??
                    Theme.of(context).colorScheme.onSurface),
            onPressed: _saveCard,
            tooltip: isEditing ? 'カードを保存' : 'カードを作成',
          ),
          // 削除アイコンボタン (編集モードのみ)
          if (isEditing)
            IconButton(
              icon: Icon(Icons.delete,
                  color: Theme.of(context).appBarTheme.iconTheme?.color ??
                      Theme.of(context).colorScheme.onSurface),
              onPressed: _deleteCard,
              tooltip: 'カードを削除',
            ),
        ],
      ),
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Shortcuts(
        shortcuts: <LogicalKeySet, Intent>{
          LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyS):
              const ActivateIntent(),
          LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.keyS):
              const ActivateIntent(), // Mac対応
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            ActivateIntent: CallbackAction<Intent>(onInvoke: (intent) {
              _saveCard();
              return null;
            }),
          },
          child: Focus(
            autofocus: true,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    // プルダウンで所属デッキを選択
                    Row(
                      children: [
                        Text(
                          'デッキ:',
                          style: TextStyle(
                            fontSize: 20,
                            color:
                                Theme.of(context).textTheme.titleLarge?.color,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Row(
                            children: [
                              Expanded(
                                child: GestureDetector(
                                  onTap: () {
                                    _showDeckSearchDialog(context);
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 16),
                                    decoration: BoxDecoration(
                                      border: Border(
                                        bottom: BorderSide(
                                          color: Theme.of(context)
                                              .dividerColor
                                              .withOpacity(0.7),
                                          width: 1,
                                        ),
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            _selectedDeckName ?? 'デッキを選択',
                                            style: TextStyle(
                                              color: Theme.of(context)
                                                  .textTheme
                                                  .titleLarge
                                                  ?.color,
                                              fontSize: 20,
                                            ),
                                          ),
                                        ),
                                        Icon(
                                          Icons.arrow_drop_down,
                                          color: Theme.of(context)
                                                  .iconTheme
                                                  .color ??
                                              Theme.of(context)
                                                  .colorScheme
                                                  .onSurface,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              IconButton(
                                icon: Icon(Icons.search,
                                    color: Theme.of(context).iconTheme.color ??
                                        Theme.of(context)
                                            .colorScheme
                                            .onSurface),
                                onPressed: () {
                                  _showDeckSearchDialog(context);
                                },
                                tooltip: 'デッキを検索',
                              ),
                              IconButton(
                                icon: Icon(Icons.add,
                                    color: Theme.of(context).iconTheme.color ??
                                        Theme.of(context)
                                            .colorScheme
                                            .onSurface),
                                onPressed: () {
                                  _showNewDeckDialog(context);
                                },
                                tooltip: '新規デッキ作成',
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _buildTextField(_questionController, '質問'),
                    const SizedBox(height: 12),
                    _buildTextField(_answerController, '回答'),
                    const SizedBox(height: 12),
                    _buildTextField(_explanationController, '解説'),
                    const SizedBox(height: 12),
                    _buildTextField(_supplementController, '補足'),
                    const SizedBox(height: 12),
                    _buildTextField(_headlineController, '見出し'),
                    const SizedBox(height: 12),
                    // _buildTextField(_chapterController, 'チャプター (任意)'),
                    // チャプター選択UI
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'チャプター',
                          style: TextStyle(
                              color: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.color
                                  ?.withOpacity(0.7),
                              fontSize: 16),
                        ),
                        GestureDetector(
                          onTap: () {
                            _showChapterSearchDialog(context);
                          },
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 16),
                            decoration: BoxDecoration(
                              border: Border(
                                bottom: BorderSide(
                                  color: Theme.of(context)
                                      .dividerColor
                                      .withOpacity(0.7),
                                  width: 1,
                                ),
                              ),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    _chapterController.text.isEmpty
                                        ? '未選択'
                                        : _chapterController.text,
                                    style: TextStyle(
                                      color: Theme.of(context)
                                          .textTheme
                                          .titleLarge
                                          ?.color,
                                      fontSize: 20,
                                    ),
                                  ),
                                ),
                                Icon(
                                  Icons.arrow_drop_down,
                                  color: Theme.of(context).iconTheme.color ??
                                      Theme.of(context).colorScheme.onSurface,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // 英語フラグの設定
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          '質問英語フラグ',
                          style: TextStyle(fontSize: 18),
                        ),
                        Switch(
                          value: _questionEnglishFlag,
                          onChanged: (value) {
                            setState(() {
                              _questionEnglishFlag = value;
                            });
                          },
                        ),
                      ],
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          '回答英語フラグ',
                          style: TextStyle(fontSize: 18),
                        ),
                        Switch(
                          value: _answerEnglishFlag,
                          onChanged: (value) {
                            setState(() {
                              _answerEnglishFlag = value;
                            });
                          },
                        ),
                      ],
                    ),

                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTextField(TextEditingController controller, String label) {
    return TextField(
      controller: controller,
      style: TextStyle(
        color: Theme.of(context).textTheme.bodyLarge?.color,
        fontSize: 20,
      ),
      maxLines: null, // 自動折り返し
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(
          color:
              Theme.of(context).textTheme.bodyMedium?.color?.withOpacity(0.7),
        ),
        border: const UnderlineInputBorder(),
      ),
    );
  }

  // 削除済みデッキ名を取得
  Future<void> _loadDeletedDeckNames() async {
    try {
      final deletedNames = await SyncService.fetchDeletedDeckNames();
      if (mounted) {
        setState(() {
          _deletedDeckNames = deletedNames;
        });
      }
    } catch (e) {
      print('削除済みデッキ名の取得エラー: $e');
    }
  }

  // 有効なデッキをフィルタリング（削除済みデッキとアーカイブ済みデッキを除外）
  List<Deck> _filterValidDecks(List<Deck> allDecks) {
    return allDecks
        .where((deck) =>
            !deck.isDeleted &&
            !_deletedDeckNames.contains(deck.deckName) &&
            !deck.isArchived)
        .toList();
  }

  // Firebase側へカードを同期するヘルパーメソッド
  Future<void> _syncCardToFirebase(
    FlashCard card,
    dynamic cardKey, {
    String? pendingOpId,
    bool isDuringAutoSave = false,
  }) async {
    final userId = FirebaseService.getUserId(); // ユーザーIDを最初に取得
    if (userId == null) {
      print('CardEditScreen - Firebase同期: ユーザーがログインしていないため同期をスキップ');
      return;
    }

    try {
      // 編集か新規作成かでオペレーションタイプを決定
      final operationType =
          widget.cardKey != null ? 'update_card' : 'create_card';
      print(
          'CardEditScreen - Firebase同期: カード「${card.question}」を操作「$operationType」で同期します');

      // SyncService.syncOperationToCloud を呼び出す
      final result = await SyncService.syncOperationToCloud(
        operationType,
        {'card': card}, // data にカードオブジェクトを渡す
      );

      if (result['success']) {
        print(
            'CardEditScreen - Firebase同期: 操作「$operationType」成功: ${result['message']}');

        // ★★★ 新規作成の場合、返された Firestore ID をローカルに保存 ★★★
        if (operationType == 'create_card' &&
            result['newFirestoreId'] != null) {
          final newFirestoreId = result['newFirestoreId'] as String;
          final savedCard = cardBox.get(cardKey);
          if (savedCard != null) {
            // firestoreId と id を揃える
            savedCard.firestoreId = newFirestoreId;
            savedCard.id = newFirestoreId;
            await savedCard.save();
            // HiveキーもFirestore IDに統一
            await HiveService.rekeyCard(cardKey, newFirestoreId);
            print(
                'CardEditScreen - Firestore ID 確定に伴いHiveキーを統一: $cardKey -> $newFirestoreId');
          } else {
            print('CardEditScreen - 警告: Hiveから新規保存したカードが見つかりません。Key: $cardKey');
          }
        }

        // Phase 2.5: 即時同期が成功したら、pending op を削除（重複送信を防ぐ）
        if (pendingOpId != null && pendingOpId.isNotEmpty) {
          try {
            await PendingOperationsService.deleteOpById(pendingOpId);
          } catch (_) {}
        }
      } else {
        print(
            'CardEditScreen - Firebase同期: 操作「$operationType」失敗: ${result['message']}');

        // ★★★ 失敗時のフォールバック処理 ★★★
        await _handleSyncFailure(
            card, cardKey, operationType, result, isDuringAutoSave);
      }
    } on FirebaseException catch (e) {
      print('CardEditScreen - Firebase同期エラー (syncOperationToCloud): $e');
      if (mounted && !isDuringAutoSave) {
        // 自動保存中でなければエラー表示
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('クラウド同期エラー: ${e.message ?? e.code}'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } catch (e) {
      print('CardEditScreen - Firebase同期で予期せぬ例外発生: $e');
      if (mounted && !isDuringAutoSave) {
        // 自動保存中でなければエラー表示
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('クラウド同期中に予期せぬエラーが発生しました: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  Future<void> _saveCard() async {
    final question = _questionController.text.trim();
    final answer = _answerController.text.trim();
    final explanation = _explanationController.text.trim();
    final chapter = _chapterController.text.trim();
    final headline = _headlineController.text.trim();
    final supplement = _supplementController.text.trim(); // ★ supplementの取得
    final currentDeckName = _selectedDeckName ?? 'デフォルト';

    // 入力チェック (自動保存時は question と answer が設定されている前提)
    // ただし、ユーザーが意図せず空にする可能性も考慮するなら残しても良い
    if (question.isEmpty || answer.isEmpty) {
      // 自動保存の場合、このエラーはユーザーには見えにくい可能性がある
      print('自動保存エラー: 質問または回答が空です。');
      // エラー発生時はローディングを解除し、元の画面に戻らないようにする
      if (mounted && _isProcessingAutoSave) {
        // _isProcessingAutoSaveもチェック
        setState(() {
          _isProcessingAutoSave = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: const Text('質問と回答が設定されていません。自動保存を中止しました。'),
              backgroundColor: Theme.of(context).colorScheme.tertiary),
        );
      } else if (mounted) {
        // 通常の保存時
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('質問と回答を入力してください')),
        );
      }
      return; // ここで処理を中断
    }

    // 編集モードか新規作成モードかを判定
    if (widget.cardKey != null) {
      // 既存カードの編集
      final card = cardBox.get(widget.cardKey) as FlashCard;
      card.question = question;
      card.answer = answer;
      card.explanation = explanation;
      card.deckName = currentDeckName;
      card.questionEnglishFlag = _questionEnglishFlag;
      card.answerEnglishFlag = _answerEnglishFlag;
      card.chapter = chapter;
      card.headline = headline;
      card.supplement = supplement; // ★ supplementの設定 (既存)
      card.updateTimestamp(); // 更新日時を更新

      // Phase 2.5: ローカル反映＋pending enqueue を同一クリティカルセクションで実行
      final String? pendingOpId =
          await PendingOperationsService.putCardAndMaybeEnqueue(
        card,
        hiveKey: widget.cardKey,
      );

      // Firebase側への同期処理
      if (_isProcessingAutoSave) {
        await _syncCardToFirebase(card, widget.cardKey,
            pendingOpId: pendingOpId,
            isDuringAutoSave: true); // 自動保存時は待機
      } else {
        unawaited(_syncCardToFirebase(card, widget.cardKey,
            pendingOpId: pendingOpId,
            isDuringAutoSave: false)); // 通常時は非同期で実行
      }

      // 編集の場合は画面を閉じる
      Navigator.pop(context);
      return;
    }

    // 新規カードの作成
    // キー統一: まずローカルで暫定IDを採番し、保存時にFirebase側のdocIdと揃える
    final provisionalId = HiveService().generateUniqueId();
    final newCard = FlashCard(
      id: provisionalId,
      question: question,
      answer: answer,
      explanation: explanation,
      deckName: currentDeckName,
      questionEnglishFlag: _questionEnglishFlag,
      answerEnglishFlag: _answerEnglishFlag,
      chapter: chapter,
      headline: headline,
      supplement: supplement, // ★ supplementの設定 (新規)
    );
    newCard.updateTimestamp(); // 更新日時を更新

    // Phase 2.5: ローカル反映＋pending enqueue を同一クリティカルセクションで実行
    final String? pendingOpId =
        await PendingOperationsService.putCardAndMaybeEnqueue(
      newCard,
      hiveKey: newCard.id,
    );

    // Firebase側への同期処理
    if (_isProcessingAutoSave) {
      await _syncCardToFirebase(newCard, newCard.id,
          pendingOpId: pendingOpId,
          isDuringAutoSave: true); // 自動保存時は待機
    } else {
      unawaited(_syncCardToFirebase(newCard, newCard.id,
          pendingOpId: pendingOpId,
          isDuringAutoSave: false)); // 通常時は非同期で実行
    }

    // 共有経由で起動された場合の処理 (Androidを想定)
    if (widget.initialDeckNameForShare != null && _isProcessingAutoSave) {
      // _isProcessingAutoSave も条件に追加
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('カードを保存しました。元のアプリに戻ります。'),
            duration: Duration(milliseconds: 1500),
          ),
        );
        await Future.delayed(const Duration(milliseconds: 1600));
      }
      SystemNavigator.pop();
      return;
    }

    // --- 通常の新規作成フロー (共有経由でない場合) ---
    // (ここは _isProcessingAutoSave が false のはずなので、通常通り動作)
    final prefs = HiveService.getSettingsBox();
    prefs.put('lastSelectedDeck', currentDeckName);
    prefs.put('lastSelectedChapter', chapter);

    _questionController.clear();
    _answerController.clear();
    _explanationController.clear();
    _headlineController.clear();
    _supplementController.clear(); // ★ supplementコントローラーのクリア

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('カードを保存しました。続けて登録できます。'),
        duration: Duration(seconds: 2),
      ),
    );

    // フォーカスを質問フィールドに戻す
    FocusScope.of(context).requestFocus(FocusNode());
    Future.delayed(const Duration(milliseconds: 100), () {
      FocusScope.of(context).requestFocus(FocusNode());
    });
  }

  void _deleteCard() {
    if (widget.cardKey != null) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('削除確認'),
          content: const Text('本当に削除しますか？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル'),
            ),
            TextButton(
              onPressed: _handleDeleteCard,
              child: const Text('削除'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _handleDeleteCard() async {
    Navigator.pop(context); // 最初の確認ダイアログを閉じる

    if (widget.cardKey != null) {
      try {
        // カードの情報を取得（削除前に表示用）
        final cardBox = HiveService.getCardBox();
        final card = cardBox.get(widget.cardKey);
        final cardQuestion = card?.question ?? "不明なカード";
        final firestoreId = card?.firestoreId;

        // Phase 2.5: 先にローカル反映＋pending enqueue（失敗時はローカルもロールバック）
        final String? pendingOpId =
            await PendingOperationsService.deleteCardAndMaybeEnqueue(
          widget.cardKey,
          firestoreId: firestoreId,
        );

        // 即時クラウド同期（失敗してもpendingが残るのでOK）
        if (firestoreId != null && firestoreId.isNotEmpty) {
          final result = await SyncService.syncOperationToCloud(
              'delete_card', {'firestoreId': firestoreId});
          if (result['success'] == true &&
              pendingOpId != null &&
              pendingOpId.isNotEmpty) {
            try {
              await PendingOperationsService.deleteOpById(pendingOpId);
            } catch (_) {}
          }
        } else {
          // firestoreIdが無い場合はローカルのみ（クラウドへは送れない）
          print("⚠️ Firestore ID がないカードをローカル削除しました: ${widget.cardKey}");
        }
        if (mounted) {
          Navigator.pop(context); // 編集画面を閉じる
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('カード「$cardQuestion」を削除しました')),
          );
        }
      } catch (e) {
        print('カード削除エラー: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text('カード削除に失敗しました: $e'),
                backgroundColor: Theme.of(context).colorScheme.error),
          );
        }
      }
    }
  }

  void _showDeckSearchDialog(BuildContext context) {
    final TextEditingController inputController = TextEditingController();
    final allDecks = deckBox.values.toList();
    final validDecks = _filterValidDecks(allDecks);
    List<Deck> filteredDecks = List.from(validDecks);
    String inputText = '';
    bool hasExactMatch = false;
    Deck? exactMatchDeck;

    print('デッキ選択ダイアログを表示します');

    showDialog(
      context: context,
      builder: (BuildContext context) {
          return StatefulBuilder(
            builder: (context, setState) {
              return AlertDialog(
              backgroundColor: Theme.of(context).dialogTheme.backgroundColor ??
                  Theme.of(context).colorScheme.surface,
              title: Text('デッキを選択または作成',
                  style: TextStyle(
                      color:
                          Theme.of(context).dialogTheme.titleTextStyle?.color ??
                              Theme.of(context).textTheme.titleLarge?.color)),
              content: SizedBox(
                width: double.maxFinite,
                height: 400,
                child: Column(
                  children: [
                    // 入力欄
                    Container(
                      decoration: BoxDecoration(
                        border: Border.all(
                            color:
                                Theme.of(context).dividerColor.withOpacity(0.7),
                            width: 2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: TextField(
                        controller: inputController,
                        style: TextStyle(
                            color: Theme.of(context).textTheme.bodyLarge?.color,
                            fontSize: 18),
                        decoration: InputDecoration(
                          labelText: 'デッキ名を入力または選択',
                          labelStyle: TextStyle(
                              color: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.color
                                  ?.withOpacity(0.7)),
                          prefixIcon: Icon(Icons.folder,
                              color: Theme.of(context)
                                      .iconTheme
                                      .color
                                      ?.withOpacity(0.7) ??
                                  Theme.of(context)
                                      .colorScheme
                                      .onSurface
                                      .withOpacity(0.7)),
                          border: const OutlineInputBorder(),
                          enabledBorder: OutlineInputBorder(
                            borderSide: BorderSide(
                                color: Theme.of(context)
                                    .dividerColor
                                    .withOpacity(0.7)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderSide: BorderSide(
                                color: Theme.of(context).colorScheme.primary),
                          ),
                        ),
                        onChanged: (value) {
                          print('入力値変更: $value');
                          setState(() {
                            inputText = value.trim();

                            // 完全一致のデッキを探す
                            final matches = validDecks
                                .where(
                                  (deck) =>
                                      deck.deckName.toLowerCase() ==
                                      inputText.toLowerCase(),
                                )
                                .toList();
                            hasExactMatch = matches.isNotEmpty;
                            exactMatchDeck =
                                hasExactMatch ? matches.first : null;

                            // フィルタリング（部分一致）
                            if (value.isEmpty) {
                              filteredDecks = List.from(validDecks);
                            } else {
                              filteredDecks = validDecks
                                  .where((deck) => deck.deckName
                                      .toLowerCase()
                                      .contains(value.toLowerCase()))
                                  .toList();
                            }
                          });
                        },
                      ),
                    ),
                    const SizedBox(height: 12),

                    // 入力されたデッキ名の処理結果
                    if (inputText.isNotEmpty) ...[
                      if (hasExactMatch && exactMatchDeck != null)
                        // 完全一致デッキのサジェスト
                          Container(
                            width: double.infinity,
                            margin: const EdgeInsets.only(bottom: 8),
                            child: ElevatedButton.icon(
                              icon: Icon(
                                Icons.check_circle,
                                color: Theme.of(context).colorScheme.tertiary,
                              ),
                              label: Text(
                                '「${exactMatchDeck!.deckName}」を選択',
                                style: TextStyle(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onTertiaryContainer,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Theme.of(context)
                                    .colorScheme
                                    .tertiaryContainer,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12),
                              ),
                              onPressed: () {
                                final deck = exactMatchDeck!;
                                final previousDeckName = _selectedDeckName;
                                final deckNameChanged =
                                    previousDeckName != deck.deckName;
                                this.setState(() {
                                  _selectedDeckName = deck.deckName;
                                  if (deckNameChanged) {
                                    _chapterController.clear();
                                  }
                                  if (widget.cardKey == null) {
                                    _questionEnglishFlag =
                                        deck.questionEnglishFlag;
                                    _answerEnglishFlag =
                                        deck.answerEnglishFlag;
                                  }
                                });
                                Navigator.of(context).pop();
                              },
                            ),
                          )
                      else
                        // 新規作成ボタン
                          Container(
                            width: double.infinity,
                            margin: const EdgeInsets.only(bottom: 8),
                            child: ElevatedButton.icon(
                              icon: Icon(
                                Icons.add_circle,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              label: Text(
                                '「$inputText」を新規作成',
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.onPrimary,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor:
                                    Theme.of(context).colorScheme.primary,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12),
                              ),
                              onPressed: () async {
                                // 入力されたデッキ名での新規作成
                                try {
                                  final newDeck =
                                      await HiveService.createAndSaveDeck(
                                    inputText,
                                    description: 'カード作成時に新規作成されたデッキ',
                                  );

                                  final previousDeckName = _selectedDeckName;
                                  final deckNameChanged =
                                      previousDeckName != newDeck.deckName;
                                  this.setState(() {
                                    _selectedDeckName = newDeck.deckName;
                                    if (deckNameChanged) {
                                      _chapterController.clear();
                                    }
                                    _questionEnglishFlag =
                                        newDeck.questionEnglishFlag;
                                    _answerEnglishFlag =
                                        newDeck.answerEnglishFlag;
                                  });

                                  Navigator.of(context).pop();
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                        content: Text('デッキ「$inputText」を作成しました')),
                                  );
                                } catch (e) {
                                  print('デッキ作成エラー: $e');
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text('デッキの作成に失敗しました: $e'),
                                      backgroundColor:
                                          Theme.of(context).colorScheme.error,
                                    ),
                                  );
                                }
                              },
                            ),
                          ),

                      // 区切り線
                      Divider(
                          color:
                              Theme.of(context).dividerColor.withOpacity(0.54)),
                      Text(
                        '既存のデッキから選択:',
                        style: TextStyle(
                            color: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.color
                                ?.withOpacity(0.7),
                            fontSize: 14),
                      ),
                      const SizedBox(height: 8),
                    ] else ...[
                      Text(
                        '既存のデッキから選択:',
                        style: TextStyle(
                            color: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.color
                                ?.withOpacity(0.7),
                            fontSize: 14),
                      ),
                        const SizedBox(height: 8),
                      ],

                      // 既存デッキリスト
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: Theme.of(context)
                                  .dividerColor
                                  .withOpacity(0.24),
                            ),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: ListView.builder(
                            shrinkWrap: true,
                            itemCount: filteredDecks.length,
                            itemBuilder: (context, index) {
                              final deck = filteredDecks[index];
                              final isHighlighted = hasExactMatch &&
                                  deck.deckName.toLowerCase() ==
                                      inputText.toLowerCase();

                              return ListTile(
                                leading: Icon(
                                  Icons.folder,
                                  color: isHighlighted
                                      ? Theme.of(context).colorScheme.tertiary
                                      : Theme.of(context)
                                              .iconTheme
                                              .color
                                              ?.withOpacity(0.7) ??
                                          Theme.of(context)
                                              .colorScheme
                                              .onSurface
                                              .withOpacity(0.7),
                                ),
                                title: Text(
                                  deck.deckName,
                                  style: TextStyle(
                                    color: isHighlighted
                                        ? Theme.of(context).colorScheme.tertiary
                                        : Theme.of(context)
                                            .textTheme
                                            .bodyLarge
                                            ?.color,
                                    fontWeight: isHighlighted
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                  ),
                                ),
                                tileColor: isHighlighted
                                    ? Theme.of(context)
                                        .colorScheme
                                        .tertiary
                                        .withOpacity(0.1)
                                    : null,
                                onTap: () {
                                  final previousDeckName = _selectedDeckName;
                                  final deckNameChanged =
                                      previousDeckName != deck.deckName;
                                  this.setState(() {
                                    _selectedDeckName = deck.deckName;
                                    if (deckNameChanged) {
                                      _chapterController.clear();
                                    }
                                    if (widget.cardKey == null) {
                                      _questionEnglishFlag =
                                          deck.questionEnglishFlag;
                                      _answerEnglishFlag =
                                          deck.answerEnglishFlag;
                                    }
                                  });
                                  Navigator.of(context).pop();
                                },
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              actions: [
                TextButton(
                  child: const Text('キャンセル'),
                  onPressed: () {
                    Navigator.of(context).pop();
                  },
                ),
              ],
                );
            },
        );
      },
    );
  }

  void _showNewDeckDialog(BuildContext context) {
    final TextEditingController newDeckController = TextEditingController();
    final TextEditingController descriptionController = TextEditingController();
    String? errorMessage;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setStateDialog) {
          return AlertDialog(
            title: const Text('新規デッキ作成'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: newDeckController,
                    decoration: const InputDecoration(
                      labelText: 'デッキ名',
                      border: UnderlineInputBorder(),
                    ),
                  ),
                  // エラーメッセージを入力欄の下に表示
                  if (errorMessage != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4.0),
                      child: Text(errorMessage!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error)),
                    ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: descriptionController,
                    decoration: const InputDecoration(
                      labelText: '説明',
                      hintText: 'デッキの説明を入力（任意）',
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

                  // 既存デッキの存在チェック
                  if (deckBox.values.any((d) => d.deckName == deckName)) {
                    setStateDialog(() {
                      errorMessage = '同じ名前のデッキが既に存在します';
                    });
                    return;
                  }

                  setStateDialog(() {
                    errorMessage = null;
                  });

                  // デッキ作成
                  try {
                      final newDeck = await HiveService.createAndSaveDeck(
                        deckName,
                        description: descriptionController.text.trim(),
                      );

                      final previousDeckName = _selectedDeckName;
                      final deckNameChanged =
                          previousDeckName != newDeck.deckName;

                      // 新しく作成したデッキを選択状態にする
                      this.setState(() {
                        _selectedDeckName = newDeck.deckName;
                        if (deckNameChanged) {
                          _chapterController.clear();
                        }
                        // 新しいデッキのデフォルト設定を反映
                        _questionEnglishFlag = newDeck.questionEnglishFlag;
                        _answerEnglishFlag = newDeck.answerEnglishFlag;
                      });

                    Navigator.of(context).pop();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('デッキ「$deckName」を作成しました')),
                    );
                  } catch (e) {
                    print('デッキ作成エラー: $e');
                    // エラーは表示せず、ダイアログを閉じる
                    // デッキは作成されているが、Firebase同期でエラーが発生した可能性がある
                    Navigator.of(context).pop();

                    // 作成されたデッキを探してみる
                    final possibleDeck = HiveService.findDeckByName(deckName);
                      if (possibleDeck != null) {
                        // デッキが見つかった場合は選択状態にする
                        final previousDeckName = _selectedDeckName;
                        final deckNameChanged =
                            previousDeckName != possibleDeck.deckName;
                        this.setState(() {
                          _selectedDeckName = possibleDeck.deckName;
                          if (deckNameChanged) {
                            _chapterController.clear();
                          }
                          _questionEnglishFlag =
                              possibleDeck.questionEnglishFlag;
                          _answerEnglishFlag =
                              possibleDeck.answerEnglishFlag;
                        });

                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('デッキ「$deckName」を作成しました')),
                      );
                    } else {
                      // 本当に作成に失敗した場合はエラーを表示
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('デッキの作成に失敗しました: $e')),
                      );
                    }
                  }
                },
              ),
            ],
          );
        },
      ),
    );
  }

  void _showChapterSearchDialog(BuildContext context) {
    final TextEditingController inputController =
        TextEditingController(text: _chapterController.text);
    final String currentDeckName = _selectedDeckName ?? 'デフォルト';

    // 現在のデッキに所属するカードからチャプターリストを生成
    final allCardsInDeck = HiveService.getCardBox()
        .values
        .where((card) => card.deckName == currentDeckName);

    // 空でなく、ユニークなチャプター名のみをリスト化し、ソートする
    final List<String> uniqueChapters = allCardsInDeck
        .map((card) => card.chapter)
        .where((chapter) => chapter.isNotEmpty)
        .toSet()
        .toList()
      ..sort();

    List<String> filteredChapters = List.from(uniqueChapters);
    String inputText = _chapterController.text;

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setState) {
              return AlertDialog(
                title: Text('「$currentDeckName」のチャプター'),
                content: SizedBox(
                  width: double.maxFinite,
                  height: 400,
                  child: Column(
                    children: [
                      TextField(
                        controller: inputController,
                        style: TextStyle(
                          fontSize: 18,
                          color: Theme.of(context).textTheme.bodyLarge?.color,
                        ),
                        decoration: InputDecoration(
                          labelText: 'チャプターを選択または入力',
                          prefixIcon: Icon(
                            Icons.category,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withOpacity(0.7),
                          ),
                          border: const OutlineInputBorder(),
                        ),
                        onChanged: (value) {
                          setState(() {
                            inputText = value.trim();
                            if (value.isEmpty) {
                              filteredChapters = List.from(uniqueChapters);
                            } else {
                              filteredChapters = uniqueChapters
                                  .where((chapter) => chapter
                                      .toLowerCase()
                                      .contains(value.toLowerCase()))
                                  .toList();
                            }
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: Theme.of(context)
                                  .colorScheme
                                  .outline
                                  .withOpacity(0.3),
                            ),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: ListView.builder(
                            shrinkWrap: true,
                            itemCount: filteredChapters.length,
                            itemBuilder: (context, index) {
                              final chapter = filteredChapters[index];
                              return ListTile(
                                title: Text(chapter),
                                onTap: () {
                                  this.setState(() {
                                    _chapterController.text = chapter;
                                  });
                                  Navigator.of(context).pop();
                                },
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    child: const Text('キャンセル'),
                    onPressed: () {
                      Navigator.of(context).pop();
                    },
                  ),
                  TextButton(
                    child: const Text('決定'),
                    onPressed: () {
                      // 入力されているテキストをチャプターとして設定
                      this.setState(() {
                        _chapterController.text = inputText;
                      });
                      Navigator.of(context).pop();
                    },
                  ),
                ],
              );
          },
        );
      },
    );
  }

  // 「後で調べる」などのデフォルトデッキが存在しない場合に作成するヘルパーメソッド
  Future<Deck?> _createDefaultDeckIfNotExists(String deckName) async {
    Deck? deck = HiveService.findDeckByName(deckName);
    if (deck == null) {
      print('デッキ「$deckName」が存在しないため、新規作成します。');
      try {
        deck = await HiveService.createAndSaveDeck(deckName,
            description: '共有機能やあとで調べるために自動作成されたデッキ');
        // 新規作成したデッキをDeckリストに追加してUIに反映させるため、再読み込みを促す
        // ただし、この画面でdecksリストを直接更新するのは難しいため、
        // 保存後に一度画面を閉じて再度開くか、親ウィジェットでの状態管理が必要になる場合がある。
        // ここでは、deckBoxが更新されることを期待する。
        // setState(() {}); // UIの再描画を促す（デッキリストが更新されることを期待） // 不要なsetStateの可能性
        if (mounted) {
          // UI更新が必要な場合に備えてmountedチェック
          setState(() {});
        }
      } catch (e) {
        print('デッキ「$deckName」の自動作成に失敗しました: $e');
        return null;
      }
    }
    return deck;
  }

  /// ★★★ 同期失敗時のフォールバック処理 ★★★
  Future<void> _handleSyncFailure(
      FlashCard card,
      dynamic cardKey,
      String operationType,
      Map<String, dynamic> result,
      bool isDuringAutoSave) async {
    print('🔄 同期失敗のフォールバック処理開始: $operationType');

    try {
      // 失敗理由を分析
      final shouldRetryLater = result['shouldRetryLater'] ?? false;
      final useTemporaryMode = result['useTemporaryMode'] ?? false;

      if (shouldRetryLater && operationType == 'create_card') {
        print('🔄 重要操作の失敗：後で再試行される予定');

        if (useTemporaryMode) {
          // 一時的なFirestore IDを予約（今回は簡易実装）
          await _setTemporaryFirestoreId(card, cardKey);
        }

        // 再試行スケジューリング（バックグラウンドで）
        _scheduleRetry(card, cardKey, operationType);

        // ユーザーには成功として表示（ローカル保存は完了しているため）
        if (mounted && !isDuringAutoSave) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('カードを保存しました（クラウド同期は後で完了します）'),
              backgroundColor: Theme.of(context).colorScheme.primary,
              duration: const Duration(seconds: 2),
            ),
          );
        }
      } else {
        // 通常の失敗処理
        if (mounted && !isDuringAutoSave) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('クラウド同期に失敗しました: ${result['message']}'),
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
          );
        }
      }
    } catch (e) {
      print('⚠️ フォールバック処理エラー: $e');
    }
  }

  /// ★★★ 一時的なFirestore ID設定 ★★★
  Future<void> _setTemporaryFirestoreId(FlashCard card, dynamic cardKey) async {
    try {
      // 一時IDを生成（実際のFirestoreドキュメント参照形式）
      final tempId = 'temp_${DateTime.now().millisecondsSinceEpoch}_${card.id}';

      final savedCard = cardBox.get(cardKey);
      if (savedCard != null) {
        savedCard.firestoreId = tempId;
        await savedCard.save();
        print('🆔 一時Firestore ID設定: $tempId');
      }
    } catch (e) {
      print('⚠️ 一時ID設定エラー: $e');
    }
  }

  /// ★★★ 再試行スケジューリング ★★★
  void _scheduleRetry(FlashCard card, dynamic cardKey, String operationType) {
    // バックグラウンドで数秒後に再試行
    Timer(const Duration(seconds: 5), () async {
      try {
        print('🔄 スケジュールされた再試行実行: $operationType');

        final result = await SyncService.syncOperationToCloud(
          operationType,
          {'card': card},
        );

        if (result['success']) {
          print('✅ 再試行成功: ${result['message']}');

          // 一時IDを実際のIDに更新
          if (operationType == 'create_card' &&
              result['newFirestoreId'] != null) {
            final newFirestoreId = result['newFirestoreId'] as String;
            final savedCard = cardBox.get(cardKey);
            if (savedCard != null) {
              savedCard.firestoreId = newFirestoreId;
              await savedCard.save();
              print('🆔 一時IDを実際のIDに更新: $newFirestoreId');
            }
          }
        } else {
          print('❌ 再試行も失敗: ${result['message']}');
        }
      } catch (e) {
        print('❌ 再試行処理エラー: $e');
      }
    });
  }
}
