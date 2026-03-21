// ignore_for_file: library_private_types_in_public_api, avoid_print, prefer_adjacent_string_concatenation, deprecated_member_use, unused_import, prefer_const_constructors, unnecessary_brace_in_string_interps, curly_braces_in_flow_control_structures

import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:yomiage/models/deck.dart';
import 'package:yomiage/models/flashcard.dart';
import 'package:yomiage/services/hive_service.dart';
import 'package:yomiage/screens/card_edit_screen.dart';
import 'dart:math';
import 'package:yomiage/services/firebase_service.dart';
import 'package:yomiage/services/sync_service.dart';
import 'package:yomiage/services/sync/pending_operations.dart';
import 'package:yomiage/services/tts_service.dart';
import 'package:yomiage/themes/app_theme.dart';

// StudyModeFilter Enum定義
enum StudyModeFilter { dueToday, allCards }

// Web用出題モード画面 (リスト表示)
class WebStudyModeScreen extends StatefulWidget {
  const WebStudyModeScreen({Key? key}) : super(key: key);

  @override
  State<WebStudyModeScreen> createState() => _WebStudyModeScreenState();
}

class _WebStudyModeScreenState extends State<WebStudyModeScreen> {
  @override
  Widget build(BuildContext context) {
    final decks = HiveService.getDeckBox().values.where((d) => !d.isDeleted).toList();
    final now = DateTime.now();
    final todayEnd = DateTime(now.year, now.month, now.day, 23, 59, 59);

    // 今日出題するカードがあるデッキのみ表示
    final filteredDecks = decks.where((deck) {
      final deckCards = HiveService.getCardBox()
          .values
          .where((c) => !c.isDeleted && c.deckName == deck.deckName)
          .toList();
      final dueCount = deckCards
          .where((c) =>
              c.nextReview == null ||
              c.nextReview!.isBefore(todayEnd) ||
              c.nextReview!.isAtSameMomentAs(todayEnd))
          .length;
      return dueCount > 0;
    }).toList();

    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 800),
          child: Scaffold(
            appBar: AppBar(
              title: Text('出題モード（忘却曲線）',
                  style: TextStyle(
                      color: Theme.of(context).appBarTheme.foregroundColor)),
            ),
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            body: ListView.builder(
              itemCount: filteredDecks.length,
              itemBuilder: (context, index) {
                final deck = filteredDecks[index];
                final deckCards = HiveService.getCardBox()
                    .values
                    .where((c) => c.deckName == deck.deckName)
                    .toList();

                if (deckCards.isEmpty) {
                  return ListTile(
                    title: Text(
                      deck.deckName,
                      style: TextStyle(
                          fontSize: 20,
                          color:
                              Theme.of(context).textTheme.headlineSmall?.color),
                    ),
                    subtitle: Text(
                      'カードがありません',
                      style: TextStyle(
                          color: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.color
                              ?.withOpacity(0.6)),
                    ),
                  );
                }

                final dueCount = deckCards
                    .where((c) =>
                        c.nextReview == null ||
                        (c.nextReview?.isBefore(todayEnd) ?? false) ||
                        (c.nextReview?.isAtSameMomentAs(todayEnd) ?? false))
                    .length;
                final notDueCount = deckCards.length - dueCount;

                return ListTile(
                  title: Text(
                    deck.deckName,
                    style: TextStyle(
                        fontSize: 20,
                        color:
                            Theme.of(context).textTheme.headlineSmall?.color),
                  ),
                  subtitle: Text(
                    '今日: $dueCount枚 / 全体: ${deckCards.length}枚',
                    style: TextStyle(
                        color: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.color
                            ?.withOpacity(0.6)),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('$dueCount',
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                              fontSize: 16)),
                      const SizedBox(width: 4),
                      Text('$notDueCount',
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.secondary,
                              fontSize: 16)),
                    ],
                  ),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => WebStudySessionPage(
                            deckKey: deck.key,
                            chapter: null, // Chapterなしで学習開始
                            filter:
                                StudyModeFilter.dueToday), // ここでは常にDueTodayで開始
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

// --- ここから下が修正対象の WebStudySessionPage ---

class WebStudySessionPage extends StatefulWidget {
  final dynamic deckKey;
  final String? chapter;
  final StudyModeFilter filter;

  const WebStudySessionPage({
    required this.deckKey,
    this.chapter,
    required this.filter,
    Key? key,
  }) : super(key: key);

  @override
  State<WebStudySessionPage> createState() => _WebStudySessionPageState();
}

class _WebStudySessionPageState extends State<WebStudySessionPage> {
  late Deck deck;
  List<FlashCard> sessionCards = [];
  bool isLoading = true;
  int currentIndex = 0;
  bool showAnswer = false;
  List<FlashCard> cardsToReview = [];
  final int reviewInterval = 3;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() {
      isLoading = true;
    });
    try {
      final deckBox = HiveService.getDeckBox();
      final cardBox = HiveService.getCardBox();
      final loadedDeck = deckBox.get(widget.deckKey);

      if (loadedDeck == null) {
        if (mounted) {
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text(
                    'エラー: 対象のデッキが見つかりません。\nError: Target deck not found.')),
          );
        }
        return;
      }
      deck = loadedDeck;

      final now = DateTime.now();
      final todayEnd = DateTime(now.year, now.month, now.day, 23, 59, 59);

      var query = cardBox.values.where((c) => c.deckName == deck.deckName);

      if (widget.chapter != null) {
        final chapterFilter = widget.chapter == '' ? '' : widget.chapter;
        query = query.where((c) => c.chapter == chapterFilter);
      }

      if (widget.filter == StudyModeFilter.dueToday) {
        query = query.where((c) =>
            c.nextReview == null ||
            c.nextReview!.isBefore(todayEnd) ||
            c.nextReview!.isAtSameMomentAs(todayEnd));
      }

      final loadedCards = query.toList();
      loadedCards.shuffle();

      if (mounted) {
        if (loadedCards.isEmpty) {
          String filterText =
              widget.filter == StudyModeFilter.dueToday ? '本日出題予定の' : '';
          String chapterText = widget.chapter == null
              ? ''
              : 'チャプター「${widget.chapter == '' ? '未分類' : widget.chapter}」の';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text(
                    '${filterText}${chapterText}学習するカードがありません。\nNo cards to study.')),
          );
          Navigator.pop(context);
          return;
        }
        setState(() {
          sessionCards = loadedCards;
          isLoading = false;
          currentIndex = 0;
          showAnswer = false;
          cardsToReview.clear();
        });
      }
    } catch (e) {
      print("Error loading study session data: $e");
      if (mounted) {
        setState(() {
          isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content:
                  Text('学習データの読み込みに失敗しました: $e\nFailed to load study data: $e')),
        );
        if (Navigator.canPop(context)) Navigator.pop(context);
      }
    }
  }

  Future<void> _updateSM2(FlashCard card, int quality) async {
    // ★★★ Boxから最新のカードオブジェクトを取得 ★★★
    final cardToSave = HiveService.getCardBox().get(card.key);
    if (cardToSave == null) {
      print(
          '🚨 [WebStudy] Error: Card not found in Box before saving update. Key: ${card.key}');
      return; // 保存対象が見つからない場合は処理中断
    }

    // final now = DateTime.now(); // <- 変更前
    final nowUtc = DateTime.now().toUtc(); // UTCで現在時刻を取得

    if (quality == 0) {
      cardToSave.repetitions = 0;
      cardToSave.intervalDays = 0;
      cardToSave.nextReview = nowUtc; // 当日中に再出題
    } else if (quality == 1) {
      // 難しい: リセットせず、間隔を短縮して再スケジュール（推奨A）
      final int prevI =
          (cardToSave.intervalDays > 0) ? cardToSave.intervalDays : 1;

      // EFはやや下げる（下限1.3）
      cardToSave.eFactor = cardToSave.eFactor - 0.15;
      if (cardToSave.eFactor < 1.3) {
        cardToSave.eFactor = 1.3;
      }

      // 成熟(>=21日)は7日に戻し、未成熟は半減（下限3日）
      int newInterval;
      if (prevI >= 21) {
        newInterval = 7;
      } else {
        newInterval = (prevI * 0.5).round();
        if (newInterval < 3) newInterval = 3;
      }

      // repetitionsは維持
      cardToSave.intervalDays = newInterval;
      cardToSave.nextReview = nowUtc.add(Duration(days: newInterval));
    } else if (quality < 3) {
      cardToSave.repetitions = 0;
      cardToSave.intervalDays = 1;
      cardToSave.nextReview = nowUtc.add(const Duration(days: 1));
    } else {
      cardToSave.repetitions += 1;
      if (cardToSave.repetitions == 1) {
        if (quality >= 4) {
          cardToSave.intervalDays = 4;
        } else {
          cardToSave.intervalDays = 2;
        }
      } else if (cardToSave.repetitions == 2) {
        cardToSave.intervalDays = 6;
      } else {
        cardToSave.intervalDays =
            (cardToSave.intervalDays * cardToSave.eFactor).round();
        if (cardToSave.intervalDays <= 0) cardToSave.intervalDays = 1;
      }
      cardToSave.eFactor = cardToSave.eFactor +
          (0.1 - (5 - quality) * (0.08 + (5 - quality) * 0.02));
      if (cardToSave.eFactor < 1.3) {
        cardToSave.eFactor = 1.3;
      }
      cardToSave.nextReview =
          nowUtc.add(Duration(days: cardToSave.intervalDays));
    }

    cardToSave.checkAndFixInvalidDate();

    // ★★★ updatedAt を更新 (int型ミリ秒エポック) ★★★
    // cardToSave.updatedAt = now; // <- 変更前
    cardToSave.updatedAt = nowUtc.millisecondsSinceEpoch; // <- 変更後

    // デバッグログ
    print(
        '🔄 _updateSM2: Updating card ${cardToSave.key} with quality $quality.');
    print(
        '  Rep: ${cardToSave.repetitions}, Int: ${cardToSave.intervalDays}, EF: ${cardToSave.eFactor.toStringAsFixed(2)}');
    print('  Next Review: ${cardToSave.nextReview?.toIso8601String()}');
    print('  Repetitions: ${cardToSave.repetitions}');
    print('  E-Factor: ${cardToSave.eFactor}');
    print('  Interval Days: ${cardToSave.intervalDays}');
    print('--------- END ----------');

    try {
      await PendingOperationsService.putCardAndMaybeEnqueue(
        cardToSave,
        hiveKey: card.key,
      );
      print('✅ _updateSM2: Card ${cardToSave.key} updated successfully.');
    } catch (e) {
      print('❌ _updateSM2: Error updating card ${cardToSave.key}: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text('学習データの更新に失敗しました: $e\nFailed to update study data: $e')));
      }
    }
  }

  // Firebase同期を複数回試行する関数
  // ignore: unused_element
  void _syncCardToFirebase(FlashCard card, int retriesLeft) {
    // ★★★ 送信処理開始時の値もログ出力 ★★★
    print(
        '➡️ [WebStudyMode] _syncCardToFirebase 開始時の nextReview (UTC): ${card.nextReview}'); // ★ ログ追加 3
    print(
        '🔄 [WebStudyMode] カード「${card.question.substring(0, min(20, card.question.length))}...」のFirebase同期を試行中 (残り試行回数: $retriesLeft)');

    SyncService.syncOperationToCloud('update_card', {'card': card})
        .then((result) {
      if (!result['success']) {
        print(
            '❌ [WebStudyMode] カード「${card.question.substring(0, min(20, card.question.length))}...」のFirebase同期に失敗しました: ${result['message']}');

        // 試行回数が残っていれば再試行
        if (retriesLeft > 1) {
          print('🔁 [WebStudyMode] 3秒後に再試行します...');
          // 3秒待ってから再試行
          Future.delayed(Duration(seconds: 3), () {
            _syncCardToFirebase(card, retriesLeft - 1);
          });
        } else {
          print('⛔ [WebStudyMode] 最大試行回数に達しました。同期に失敗しました。');
        }
      } else {
        print(
            '✅ [WebStudyMode] カード「${card.question.substring(0, min(20, card.question.length))}...」のFirebase同期に成功しました');
      }
    }).catchError((error) {
      print(
          '❌ [WebStudyMode] カード「${card.question.substring(0, min(20, card.question.length))}...」のFirebase同期中にエラーが発生しました: $error');

      // 試行回数が残っていれば再試行
      if (retriesLeft > 1) {
        print('🔁 [WebStudyMode] 3秒後に再試行します...');
        // 3秒待ってから再試行
        Future.delayed(Duration(seconds: 3), () {
          _syncCardToFirebase(card, retriesLeft - 1);
        });
      } else {
        print('⛔ [WebStudyMode] 最大試行回数に達しました。同期に失敗しました。');
      }
    });
  }

  int _getDaysUntilNextReview(int quality) {
    if (currentIndex >= sessionCards.length) return 0;
    final card = sessionCards[currentIndex];
    if (quality == 0) return 0;

    if (quality == 1) {
      // 難しい: 推奨Aに基づく短縮プレビュー
      final int prevI = (card.intervalDays > 0) ? card.intervalDays : 1;
      if (prevI >= 21) {
        return 7;
      }
      final int half = (prevI * 0.5).round();
      return half >= 3 ? half : 3;
    }

    if (quality < 3) return 1;
    int repetitions = card.repetitions + 1;
    double eFactor = card.eFactor;
    if (quality >= 4) {
      eFactor += (0.1 - (5 - quality) * (0.08 + (5 - quality) * 0.02));
      if (eFactor < 1.3) eFactor = 1.3;
    }
    if (repetitions == 1) return quality >= 4 ? 4 : 2;
    if (repetitions == 2) return 6;
    int days = (card.intervalDays * eFactor).round();
    return days > 0 ? days : 1;
  }

  void _goToNextCard() {
    setState(() {
      currentIndex++;
      showAnswer = false;
      if (cardsToReview.isNotEmpty &&
          (currentIndex >= sessionCards.length ||
              (currentIndex > 0 && currentIndex % reviewInterval == 0))) {
        final cardToReview = cardsToReview.removeAt(0);
        if (currentIndex < sessionCards.length) {
          sessionCards.insert(currentIndex, cardToReview);
        } else {
          sessionCards.add(cardToReview);
        }
      }
    });
  }

  Future<void> _refreshCardsAfterEdit() async {
    final currentIdx = currentIndex;
    final currentShowAnswer = showAnswer;
    await _loadData();
    if (mounted && !isLoading) {
      // isLoadingチェック追加
      setState(() {
        currentIndex = (currentIdx < sessionCards.length)
            ? currentIdx
            : (sessionCards.isNotEmpty ? sessionCards.length - 1 : 0); // 範囲外調整
        showAnswer = currentShowAnswer;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return Scaffold(
        appBar: AppBar(title: Text('読み込み中...')),
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    String appBarTitle = deck.deckName;
    if (widget.chapter != null) {
      appBarTitle += ' - ${widget.chapter == '' ? '未分類' : widget.chapter}';
    }

    if (sessionCards.isEmpty) {
      // _loadData 内で pop されるはずだが念のため
      return Scaffold(
        appBar: AppBar(title: Text(appBarTitle)),
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: Center(
            child: Text('学習するカードがありません。',
                style: TextStyle(
                    color: Theme.of(context).textTheme.bodyLarge?.color))),
      );
    }

    if (currentIndex >= sessionCards.length) {
      return Scaffold(
        appBar: AppBar(title: Text('完了: $appBarTitle')),
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: Center(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text('全てのカードを学習しました！',
                style: TextStyle(
                    color: Theme.of(context).textTheme.bodyLarge?.color)),
            SizedBox(height: 20),
            ElevatedButton(
                onPressed: () => Navigator.pop(context), child: Text('戻る')),
          ]),
        ),
      );
    }

    final currentCard = sessionCards[currentIndex];
    final screenWidth = MediaQuery.of(context).size.width;
    final double baseFontSize =
        screenWidth < 600 ? 15 : (screenWidth < 960 ? 17 : 19);
    final double buttonFontSize = baseFontSize * 0.92;
    final double intervalFontSize = buttonFontSize * 0.85;
    appBarTitle += ' (${currentIndex + 1}/${sessionCards.length})';

    return WillPopScope(
      onWillPop: () async {
        await HiveService.refreshDatabase();
        return true;
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(appBarTitle),
          actions: [
            IconButton(
              icon: Icon(Icons.edit),
              onPressed: () async {
                await Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (context) =>
                            CardEditScreen(cardKey: currentCard.key)));
                if (mounted) _refreshCardsAfterEdit();
              },
            )
          ],
        ),
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () {
            if (!showAnswer) {
              setState(() {
                showAnswer = true;
              });
            }
          },
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                      child: SingleChildScrollView(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                        Text(currentCard.question,
                            style: TextStyle(
                                fontSize: baseFontSize * 1.4,
                                color: Theme.of(context)
                                    .textTheme
                                    .headlineMedium
                                    ?.color)),
                        const SizedBox(height: 20),
                        if (showAnswer) ...[
                          Divider(
                              color: Theme.of(context).dividerColor,
                              thickness: 1.0),
                          Text(currentCard.answer,
                              style: TextStyle(
                                  fontSize: baseFontSize * 1.2,
                                  color: Theme.of(context)
                                      .textTheme
                                      .headlineSmall
                                      ?.color)),
                        ]
                      ]))),
                  const SizedBox(height: 20),
                  if (!showAnswer)
                    ElevatedButton(
                      onPressed: () {
                        setState(() {
                          showAnswer = true;
                        });
                      },
                      style: ElevatedButton.styleFrom(
                          backgroundColor:
                              Theme.of(context).colorScheme.surface,
                          foregroundColor:
                              Theme.of(context).colorScheme.onSurface,
                          side: BorderSide(
                              color: Theme.of(context).colorScheme.outline),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8)),
                          minimumSize: const Size(double.infinity, 48),
                          textStyle: TextStyle(fontSize: baseFontSize)),
                      child: const Text('回答を表示'),
                    )
                  else
                    // ★ Android版の4ボタン評価 (サイズと中央寄せを調整)
                    Row(
                      // mainAxisAlignment: MainAxisAlignment.spaceEvenly, // spaceEvenly を削除
                      mainAxisAlignment: MainAxisAlignment.center, // 中央寄せに変更
                      children: [
                        _buildRatingButton(
                            context,
                            '当日中',
                            0,
                            Theme.of(context).colorScheme.error,
                            buttonFontSize,
                            intervalFontSize),
                        const SizedBox(width: 12), // 間隔を調整
                        _buildRatingButton(
                            context,
                            '難しい',
                            1,
                            CustomColors.difficult,
                            buttonFontSize,
                            intervalFontSize),
                        const SizedBox(width: 12), // 間隔を調整
                        _buildRatingButton(
                            context,
                            '正解',
                            3,
                            CustomColors.correct,
                            buttonFontSize,
                            intervalFontSize),
                        const SizedBox(width: 12), // 間隔を調整
                        _buildRatingButton(
                            context,
                            '簡単',
                            4,
                            Theme.of(context).colorScheme.primary,
                            buttonFontSize,
                            intervalFontSize),
                      ],
                    ),
                  const SizedBox(height: 20),
                ]),
          ),
        ),
      ),
    );
  }

  Widget _buildRatingButton(BuildContext context, String label, int quality,
      Color color, double fontSize, double smallFontSize) {
    final days = _getDaysUntilNextReview(quality);
    final daysText = quality == 0 ? '' : '$days日後';

    // return Expanded( // Expanded を削除
    // child:
    return ElevatedButton(
      // 直接 ElevatedButton を返す
      onPressed: () {
        if (currentIndex < sessionCards.length) {
          // 範囲チェック
          if (quality == 0) {
            cardsToReview.add(sessionCards[currentIndex]);
          }
          _updateSM2(sessionCards[currentIndex], quality);
          _goToNextCard();
        }
      },
      style: ElevatedButton.styleFrom(
        backgroundColor: Theme.of(context).colorScheme.surface,
        foregroundColor: color,
        side: BorderSide(color: color),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        // minimumSize: const Size(0, 60), // minimumSize を削除または調整
        padding: const EdgeInsets.symmetric(
            horizontal: 16, vertical: 8), // Padding を調整してサイズを決定
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(label,
              style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
              maxLines: 1),
          if (daysText.isNotEmpty) const SizedBox(height: 2),
          if (daysText.isNotEmpty)
            Text(daysText,
                style: TextStyle(
                    color: color.withOpacity(0.8),
                    fontSize: smallFontSize + 1,
                    fontWeight: FontWeight.w600),
                textAlign: TextAlign.center,
                maxLines: 1),
        ],
      ),
      // ),
    );
  }
}
