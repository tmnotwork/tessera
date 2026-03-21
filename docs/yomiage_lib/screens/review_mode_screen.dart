// ignore_for_file: library_private_types_in_public_api, prefer_const_constructors, avoid_print, deprecated_member_use

import 'dart:math';
import 'package:flutter/material.dart';
import 'package:yomiage/models/deck.dart';
import 'package:yomiage/models/flashcard.dart';
import 'package:yomiage/services/hive_service.dart';
import 'package:yomiage/services/loop_mode.dart';
import 'package:yomiage/services/tts_playback_controller.dart';
import 'package:yomiage/screens/card_edit_screen.dart';
import 'package:yomiage/screens/tts_setting_screen.dart';
import '../screens/study_mode_filter.dart';
import 'package:yomiage/services/study_time_service.dart';
import 'package:yomiage/themes/app_theme.dart';

// LoopModeを共通定義からインポート

class ReviewModeScreen extends StatefulWidget {
  final Deck deck;
  final String? chapterName; // チャプター名（オプショナル）
  final StudyModeFilter? filter; // ★ フィルター（オプショナル）を追加
  final TtsPlaybackController ttsController;

  const ReviewModeScreen({
    Key? key,
    required this.deck,
    this.chapterName,
    this.filter, // ★ コンストラクタに追加
    this.ttsController = const LocalTtsPlaybackController(),
  }) : super(key: key);

  @override
  _ReviewModeScreenState createState() => _ReviewModeScreenState();
}

class _ReviewModeScreenState extends State<ReviewModeScreen> {
  late List<FlashCard> cards;
  late List<int> cardIndices; // カードのインデックスを管理する配列
  int currentIndex = 0;
  bool isPlaying = false;
  bool _showAnswer = false;
  bool _showRatingButtons = false; // 4択ボタン表示状態を管理するフラグを追加
  bool _stopRequested = false;
  int _readingGeneration = 0;
  late LoopMode _loopMode;
  late bool _randomPlayback;
  late bool _reversePlayback; // ★ 逆出題モードの状態
  late bool _focusedMemorization; // ★ 集中暗記モードの状態
  bool isPausing = false;
  bool _shuffleOnNextTransition = false;
  final _studyTimeService = StudyTimeService();

  TtsPlaybackController get _tts => widget.ttsController;

  @override
  void initState() {
    super.initState();
    _studyTimeService.startStudy('review_mode');

    // TTSの初期化を確実に行う
    _tts.init().then((_) {
      if (mounted) {
        // ★ mounted チェック
        setState(() {
          _loopMode = _tts.loopMode;
          _randomPlayback = _tts.randomPlayback;
          _reversePlayback = _tts.reversePlayback; // ★ 逆再生モードを初期化
          _focusedMemorization =
              _tts.focusedMemorization; // ★ 集中暗記モードを初期化
        });
      }
    });

    // ★ 初期値設定を initState 内に移動
    _loopMode = _tts.loopMode;
    _randomPlayback = _tts.randomPlayback;
    _reversePlayback = _tts.reversePlayback; // ★ 逆再生モードを初期化
    _focusedMemorization =
        _tts.focusedMemorization; // ★ 集中暗記モードを初期化
    isPlaying = true; // ★ 再生状態で開始

    _initCards(); // カード初期化
  }

  @override
  void dispose() {
    _studyTimeService.endStudy();
    super.dispose();
  }

  void _initCards() {
    final cardBox = HiveService.getCardBox();
    final targetChapter = widget.chapterName;
    final currentFilter =
        widget.filter ?? StudyModeFilter.dueToday; // ★ filterを取得、なければdueToday
    final now = DateTime.now();
    final todayEnd = DateTime(now.year, now.month, now.day, 23, 59, 59);

    // 1. デッキでフィルタリング
    var query =
        cardBox.values.where((card) =>
            !card.isDeleted && card.deckName == widget.deck.deckName);

    // 2. チャプターでフィルタリング (指定があれば)
    if (targetChapter != null && targetChapter.isNotEmpty) {
      query = query.where((card) => card.chapter == targetChapter);
    }

    // 3. ★ StudyModeFilter でフィルタリング
    if (currentFilter == StudyModeFilter.dueToday) {
      query = query.where((c) =>
          c.nextReview == null ||
          c.nextReview!.isBefore(todayEnd) ||
          c.nextReview!.isAtSameMomentAs(todayEnd));
    }
    // allCards の場合は追加のフィルターなし

    // 4. ★ 集中暗記モードでフィルタリング (他フィルターと併用)
    if (_focusedMemorization) {
      query = query.where((c) => c.repetitions <= 1);
    }

    cards = query.toList();

    // デバッグ情報の調整
    final chapterInfo = targetChapter != null && targetChapter.isNotEmpty
        ? 'チャプター「$targetChapter」'
        : '全チャプター';
    final filterInfo =
        currentFilter == StudyModeFilter.allCards ? '全問' : '本日出題';
    print(
        '読み上げモード: ${widget.deck.deckName} デッキ ($chapterInfo, $filterInfo) のカード数: ${cards.length}');

    if (cards.isNotEmpty) {
      _initCardIndices();
      _speakCurrentCard();
    } else {
      print('読み上げ対象のカードがありません。');
      if (mounted) {
        setState(() {
          isPlaying = false;
        });
      }
      // ★ カードがない場合はダイアログ表示の処理を追加するかもしれない
      // _showNoCardsDialog();
    }
  }

  // カードインデックスの初期化（ランダムかどうかで処理が変わる）
  void _initCardIndices() {
    cardIndices = List.generate(cards.length, (index) => index);

    if (_randomPlayback) {
      cardIndices.shuffle(Random());
    }

    currentIndex = 0;
  }

  // 次のカードに進む際のインデックス取得
  int _getNextCardIndex() {
    if (currentIndex < cardIndices.length - 1) {
      return currentIndex + 1;
    } else {
      // 最後まで行った場合、ランダムモードなら再シャッフル
      if (_randomPlayback) {
        cardIndices = List.generate(cards.length, (index) => index);
        cardIndices.shuffle(Random());
        return 0;
      } else {
        return 0; // 通常モードでも最初に戻る
      }
    }
  }

  // 前のカードに戻る際のインデックス取得
  int _getPreviousCardIndex() {
    if (currentIndex > 0) {
      return currentIndex - 1;
    } else {
      // 最初のカードの場合、ランダムモードならシャッフルを検討
      if (_randomPlayback &&
          (_loopMode != LoopMode.none && _loopMode != LoopMode.once)) {
        // ループモードが「なし」「一周」以外の場合のみシャッフル
        cardIndices = List.generate(cards.length, (index) => index);
        cardIndices.shuffle(Random());
        return cardIndices.length - 1; // 最後のカードへ
      } else {
        return cardIndices.length - 1; // 最初のカードなら最後に移動
      }
    }
  }

  // 現在表示すべきカードを取得
  FlashCard _getCurrentCard() {
    return cards[cardIndices[currentIndex]];
  }

  // ★ UI表示用のテキストを取得するヘルパー
  String get _questionText {
    final card = _getCurrentCard();
    return _reversePlayback ? card.answer : card.question;
  }

  String get _answerText {
    final card = _getCurrentCard();
    return _reversePlayback ? card.question : card.answer;
  }

  Widget _buildLoopIcon() {
    String tooltipMessage;

    switch (_loopMode) {
      case LoopMode.none:
        tooltipMessage = 'ループなし';
        return Tooltip(
          message: tooltipMessage,
          child:
              Icon(Icons.repeat_outlined, size: 30, color: Theme.of(context).colorScheme.outline),
        );
      case LoopMode.once:
        tooltipMessage = '一周ループ';
        return Tooltip(
          message: tooltipMessage,
          child:
              Icon(Icons.repeat_outlined, size: 30, color: Theme.of(context).colorScheme.onSurface),
        );
      case LoopMode.all:
        tooltipMessage = '全てループ';
        return Tooltip(
          message: tooltipMessage,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(Icons.repeat, size: 30, color: Theme.of(context).colorScheme.onSurface),
              Text("all", style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.onSurface)),
            ],
          ),
        );
      case LoopMode.single:
        tooltipMessage = '単一カードループ';
        return Tooltip(
          message: tooltipMessage,
          child: Icon(Icons.repeat_one, size: 30, color: Theme.of(context).colorScheme.onSurface),
        );
    }
  }

  void _toggleLoopMode() {
    setState(() {
      switch (_loopMode) {
        case LoopMode.none:
          _loopMode = LoopMode.once;
          break;
        case LoopMode.once:
          _loopMode = LoopMode.all;
          break;
        case LoopMode.all:
          _loopMode = LoopMode.single;
          break;
        case LoopMode.single:
          _loopMode = LoopMode.none;
          break;
      }

      // ループモード変更を保存
      _tts.setLoopMode(_loopMode);
    });
  }

  void _toggleRandomPlayback() {
    setState(() {
      _randomPlayback = !_randomPlayback;

      // 設定を保存
      _tts.setRandomPlayback(_randomPlayback);

      // シャッフル変更フラグを設定（次回のカード遷移時に適用するため）
      _shuffleOnNextTransition = true;
    });
  }

  void _showRepeatCountDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('回答の読み上げ回数'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (int i = 1; i <= 5; i++)
              RadioListTile<int>(
                title: Text('$i 回'),
                value: i,
                groupValue: _tts.answerRepeatCount,
                onChanged: (value) async {
                  if (value != null) {
                    await _tts.setAnswerRepeatCount(value);
                    Navigator.of(context).pop();
                    setState(() {});
                  }
                },
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('キャンセル'),
          ),
        ],
      ),
    );
  }

  Future<void> _speakCurrentCard() async {
    if (cards.isEmpty) return;

    print('_speakCurrentCard: 開始');
    final int gen = ++_readingGeneration;

    // 必ず再生中にし、回答とボタンは非表示にする
    setState(() {
      isPlaying = true;
      isPausing = false;
      _stopRequested = false;
      _showAnswer = false;
      _showRatingButtons = false; // 開始時にボタンも非表示
    });

    // すぐにUIを更新するための小さな遅延
    await Future.delayed(Duration.zero);

    final card = _getCurrentCard();

    try {
      // 質問の読み上げ (逆出題モードを考慮)
      final questionText = _reversePlayback ? card.answer : card.question;
      final questionIsEnglish =
          _reversePlayback ? card.answerEnglishFlag : card.questionEnglishFlag;
      print('質問読み上げ開始: $questionText');
      await _tts.speak(questionText, questionIsEnglish);
      print('質問読み上げ完了');

      // 中断要求があれば終了（質問読み上げ完了直後）
      if (_stopRequested || gen != _readingGeneration) {
        print('質問読み上げ中に中断されました。');
        return;
      }

      // ポーズ期間
      print('ポーズ開始: ${_tts.answerPauseSeconds}秒');
      await Future.delayed(Duration(seconds: _tts.answerPauseSeconds));
      print('ポーズ完了');

      // 中断要求があれば終了（ポーズ期間完了直後）
      if (_stopRequested || gen != _readingGeneration) {
        print('ポーズ中に中断されました。');
        return;
      }

      // 回答と4択ボタンを表示
      print('回答と4択ボタンを表示');
      setState(() {
        _showAnswer = true;
        _showRatingButtons = true;
      });

      // 回答の読み上げを設定回数繰り返す (質問が英語かつ回答が日本語なら1回に固定)
      final answerIsEnglish =
          _reversePlayback ? card.questionEnglishFlag : card.answerEnglishFlag;
      final bool questionEnAnswerJa = questionIsEnglish && !answerIsEnglish;
      final int repeatCount = questionEnAnswerJa ? 1 : _tts.answerRepeatCount;
      print('回答読み上げ開始 (リピート: $repeatCount 回)');
      for (int i = 0; i < repeatCount; i++) {
        // 最終回でなければ1秒間隔を空ける
        if (i > 0) {
          await Future.delayed(const Duration(seconds: 1));
        }

        // 中断要求があれば終了（回答読み上げループ中）
        if (_stopRequested || gen != _readingGeneration) {
          print('回答読み上げ中に中断されました (ループ $i 回目)');
          return;
        }

        // 回答の読み上げ (逆出題モードを考慮)
        final answerText = _reversePlayback ? card.question : card.answer;
        final answerIsEnglish = _reversePlayback
            ? card.questionEnglishFlag
            : card.answerEnglishFlag;
        print('回答読み上げ実行 (ループ $i 回目)');
        await _tts.speak(answerText, answerIsEnglish);
      }
      print('回答読み上げ完了');

      // 回答読み上げ完了後の処理を呼び出す
      await _handlePostAnswerPlayback(gen);
    } catch (e) {
      print('読み上げエラー: $e');
      // エラー発生時も停止状態にする
      if (gen == _readingGeneration) {
        // 他のプロセスが始まっていなければ
        setState(() {
          isPlaying = false;
        });
      }
    }
  }

  // 回答読み上げ完了後の共通処理 (ループモードに応じた遷移など)
  Future<void> _handlePostAnswerPlayback(int generation) async {
    // この関数が呼び出された時点での状態を確認
    if (!_stopRequested && generation == _readingGeneration) {
      print('回答再生後処理: 開始 (generation=$generation)');
      // 少し待機してから次のアクションへ
      await Future.delayed(const Duration(seconds: 1));

      // 待機後にもう一度状態を確認 (この間に停止などが押されていないか)
      if (!_stopRequested && generation == _readingGeneration) {
        print('次のアクション実行: $_loopMode');
        switch (_loopMode) {
          case LoopMode.none:
            // ループなしの場合は読み上げ完了後に停止状態にする
            setState(() {
              isPlaying = false;
            });
            print('ループなしのため待機、再生停止状態に移行');
            break;
          case LoopMode.once:
          case LoopMode.all:
            print('次のカードへ');
            // _goToNextCard は内部で isPlaying = true にして _speakCurrentCard を呼ぶ
            _goToNextCard();
            break;
          case LoopMode.single:
            print('単一カードループ');
            // _speakCurrentCard は内部で isPlaying = true にする
            _speakCurrentCard();
            break;
        }
      } else {
        print(
            '回答再生後処理: 待機中に中断されました (stopRequested:$_stopRequested, generation:$_readingGeneration expected:$generation)');
      }
    } else {
      print(
          '回答再生後処理: 呼び出し時点で既に中断/世代ずれ (stopRequested:$_stopRequested, generation:$_readingGeneration expected:$generation)');
    }
  }

  Future<void> _stopSpeaking() async {
    print('_stopSpeaking: 読み上げを停止します');
    _stopRequested = true;
    _readingGeneration++;
    await _tts.stop();

    // 再生停止状態に設定
    setState(() {
      isPlaying = false;
      isPausing = false;
    });
  }

  Future<void> _goToNextCard() async {
    // TTSの停止だけを行い、isPlayingフラグは維持する
    _stopRequested = true;
    _readingGeneration++;
    await _tts.stop();

    // 次のカードがあるか、またはループモードが「all」または「once」の場合
    if (currentIndex < cardIndices.length - 1 ||
        (_loopMode != LoopMode.none && _loopMode != LoopMode.once)) {
      setState(() {
        // シャッフル変更フラグがONの場合、残りのカードをシャッフル
        if (_shuffleOnNextTransition) {
          _shuffleRemainingCards();
          _shuffleOnNextTransition = false;
        }

        // 次のカードインデックスを取得
        int nextIndex = _getNextCardIndex();

        // 一周ループモードで最初のカードに戻る場合は停止
        if (_loopMode == LoopMode.once &&
            nextIndex == 0 &&
            currentIndex == cardIndices.length - 1) {
          isPlaying = false;
          isPausing = false;
          currentIndex = 0;
          _showFinishDialog();
          return;
        }

        currentIndex = nextIndex;
        // 常に再生中状態にする
        isPlaying = true;
      });

      _speakCurrentCard();
    } else {
      setState(() {
        isPlaying = false;
        isPausing = false;
      });
      _showFinishDialog();
    }
  }

  Future<void> _goToPreviousCard() async {
    // TTSの停止だけを行い、isPlayingフラグは維持する
    _stopRequested = true;
    _readingGeneration++;
    await _tts.stop();

    if (currentIndex > 0 ||
        (_loopMode != LoopMode.none && _loopMode != LoopMode.once)) {
      setState(() {
        // シャッフル変更フラグがONの場合、残りのカードをシャッフル
        if (_shuffleOnNextTransition) {
          _shuffleRemainingCards();
          _shuffleOnNextTransition = false;
        }
        currentIndex = _getPreviousCardIndex();

        // 常に再生中状態にする
        isPlaying = true;
      });

      _speakCurrentCard();
    } else {
      setState(() {
        isPlaying = false;
        isPausing = false;
      });
    }
  }

  // 現在のカードより後ろの残りカードをシャッフルする
  void _shuffleRemainingCards() {
    if (_randomPlayback) {
      // 現在のカードのインデックスを保存

      // 残りのカードのインデックスを取得
      final remainingIndices = cardIndices.sublist(currentIndex + 1);

      if (remainingIndices.isNotEmpty) {
        // 残りのカードをシャッフル
        remainingIndices.shuffle(Random());

        // シャッフルされたインデックスを元の配列に戻す
        cardIndices = [
          ...cardIndices.sublist(0, currentIndex + 1),
          ...remainingIndices
        ];
      }
    } else {
      // シャッフルOFFの場合は通常順に戻す
      cardIndices = List.generate(cards.length, (index) => index);
    }
  }

  void _showFinishDialog() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('完了'),
        content: const Text('すべてのカードの読み上げが終了しました。'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              Navigator.pop(context);
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  // SM2アルゴリズムを使って次回の出題日を設定する
  Future<void> _updateSM2(FlashCard card, int quality) async {
    final now = DateTime.now();
    if (quality == 0) {
      // 「もう一度」の場合は当日中に再出題
      card.repetitions = 0;
      card.intervalDays = 0;
      card.nextReview = now; // 当日に設定
    } else if (quality == 1) {
      // 「難しい」: 推奨A（リセットせず、間隔を短縮）
      final int prevI = (card.intervalDays > 0) ? card.intervalDays : 1;

      // EFはやや下げる（下限1.3）
      card.eFactor = card.eFactor - 0.15;
      if (card.eFactor < 1.3) {
        card.eFactor = 1.3;
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
      card.intervalDays = newInterval;
      card.nextReview = now.add(Duration(days: newInterval));
    } else if (quality < 3) {
      // 「難しい」以外の低評価（フォールバック）: 翌日
      card.repetitions = 0;
      card.intervalDays = 1;
      card.nextReview = now.add(const Duration(days: 1));
    } else {
      card.repetitions += 1;
      if (card.repetitions == 1) {
        // 初回出題の場合
        if (quality >= 4) {
          // 「簡単」は4日後
          card.intervalDays = 4;
        } else {
          // 「正解」は2日後
          card.intervalDays = 2;
        }
      } else if (card.repetitions == 2) {
        // 2回目の出題の場合
        if (quality >= 4) {
          // 「簡単」は8日後
          card.intervalDays = 8;
        } else {
          // 「正解」は6日後
          card.intervalDays = 6;
        }
      } else {
        // 3回目以降
        // 評価に応じて間隔を調整
        double intervalMultiplier = 1.0;
        if (quality >= 4) {
          // 「簡単」の場合は間隔を1.5倍に
          intervalMultiplier = 1.5;
        } else {
          // 「正解」の場合は通常の間隔
          intervalMultiplier = 1.0;
        }

        // 新しい間隔を計算（評価の影響を反映）
        card.intervalDays =
            (card.intervalDays * card.eFactor * intervalMultiplier).round();

        // 最小間隔を1日に設定
        if (card.intervalDays <= 0) card.intervalDays = 1;
      }

      // E-Factorの更新（評価の影響をより大きく）
      card.eFactor =
          card.eFactor + (0.1 - (5 - quality) * (0.08 + (5 - quality) * 0.02));
      if (card.eFactor < 1.3) {
        card.eFactor = 1.3;
      }

      card.nextReview = now.add(Duration(days: card.intervalDays));
    }

    // 不正な日付をチェックして修正
    card.checkAndFixInvalidDate();

    // 最終更新日時を設定
    print('  -> updateTimestamp() を呼び出します');
    // ★★★ updatedAt 更新前の値 ★★★
    final updatedAtBefore = card.updatedAt;
    print('    [DEBUG] updatedAt 更新前: $updatedAtBefore');

    card.updateTimestamp();

    // ★★★ updatedAt 更新直後の値 ★★★
    final updatedAtAfterUpdate = card.updatedAt;
    print('    [DEBUG] updatedAt 更新直後: $updatedAtAfterUpdate');
    print('  <- updateTimestamp() の呼び出し完了');
    print('⏰ [_updateSM2] 更新日時を設定しました');
    print('  - 設定した値: ${card.updatedAt}'); // これは updatedAtAfterUpdate と同じはず
    print(
        '  - 日時に変換: ${DateTime.fromMillisecondsSinceEpoch(card.updatedAt!).toIso8601String()}');

    try {
      print('  -> HiveService.getCardBox().put() を呼び出します');
      // ★★★ put 直前の値 ★★★
      final updatedAtBeforePut = card.updatedAt;
      print('    [DEBUG] put 直前: $updatedAtBeforePut');

      await HiveService.getCardBox().put(card.key, card);

      print('  <- HiveService.getCardBox().put() の呼び出し完了');
      print('✅ [_updateSM2] カードを保存しました');

      // 保存後の値を確認
      print('  -> 保存後の値を確認します');
      // ★★★ put 直後に再取得した値 ★★★
      final savedCard = HiveService.getCardBox().get(card.key);
      final updatedAtAfterPut = savedCard?.updatedAt;
      print('    [DEBUG] put 直後に再取得: $updatedAtAfterPut');
      print('  <- 保存後の値の取得完了');
      print('  - 保存後のupdatedAt: ${savedCard?.updatedAt}');
      if (savedCard?.updatedAt != null) {
        final savedDateTime =
            DateTime.fromMillisecondsSinceEpoch(savedCard!.updatedAt!);
        print('  - 保存後の日時: ${savedDateTime.toIso8601String()}');
      }
    } catch (e) {
      print('カード保存エラー: $e');
    }
  }

  // 現在のカードに対して、指定された評価をした場合の次回表示日までの日数を計算
  int _getDaysUntilNextReview(int quality) {
    final card = _getCurrentCard();

    if (quality == 0) {
      // もう一度: 当日中（0日後）
      return 0;
    } else if (quality == 1) {
      // 難しい: 推奨Aに基づく短縮プレビュー
      final int prevI = (card.intervalDays > 0) ? card.intervalDays : 1;
      if (prevI >= 21) {
        return 7;
      }
      final int half = (prevI * 0.5).round();
      return half >= 3 ? half : 3;
    } else if (quality < 3) {
      // フォールバック: 1日後
      return 1;
    } else {
      // 正解/簡単
      int repetitions = card.repetitions + 1;
      double eFactor = card.eFactor;
      if (quality >= 4) {
        // 簡単
        eFactor =
            eFactor + (0.1 - (5 - quality) * (0.08 + (5 - quality) * 0.02));
        if (eFactor < 1.3) eFactor = 1.3;
      }

      if (repetitions == 1) {
        // 初回出題の場合
        return quality >= 4 ? 4 : 2; // 「簡単」は4日後、「正解」は2日後
      } else if (repetitions == 2) {
        // 2回目の出題の場合
        return quality >= 4 ? 8 : 6; // 「簡単」は8日後、「正解」は6日後
      } else {
        // 3回目以降
        double intervalMultiplier = quality >= 4 ? 1.5 : 1.0;
        return (card.intervalDays * eFactor * intervalMultiplier).round();
      }
    }
  }

  // 「回答を表示」ボタンが押されたときの処理
  Future<void> _handleShowAnswerButtonPressed() async {
    print('_handleShowAnswerButtonPressed: 開始');

    // 現在の読み上げ（質問）を停止
    _stopRequested = true; // _speakCurrentCard内の待機処理を中断させる
    _readingGeneration++; // 世代をインクリメントして古い読み上げを無効化
    await _tts.stop();

    print('質問読み上げ停止');

    // 回答と4択ボタンを表示、再生状態は維持
    setState(() {
      _showAnswer = true;
      _showRatingButtons = true;
      isPlaying = true; // 回答読み上げが始まるため再生状態は維持
      isPausing = false;
    });

    // 少し待ってから回答読み上げ開始（UI更新とTTS準備のため）
    await Future.delayed(const Duration(milliseconds: 100));

    // 新しい世代で回答の読み上げを開始
    final int currentGen = _readingGeneration; // 新しい世代番号を取得
    _stopRequested = false; // ★ 新しい読み上げのために中断フラグをリセット

    print(
        '回答読み上げ開始準備 (ボタン経由): generation=$currentGen, stopRequested=$_stopRequested');

    // カードが存在しない場合は処理しない（念のため）
    if (cards.isEmpty) return;
    final card = _getCurrentCard();
    // 質問が英語かつ回答が日本語ならリピートを1回に固定
    final bool questionIsEnglish = card.questionEnglishFlag;
    final bool answerIsEnglish = card.answerEnglishFlag;
    final int repeatCount = (questionIsEnglish && !answerIsEnglish)
        ? 1
        : _tts.answerRepeatCount;
    print('回答読み上げ開始 (ボタン経由, リピート: $repeatCount 回)');

    try {
      for (int i = 0; i < repeatCount; i++) {
        // 最終回でなければ1秒間隔を空ける
        if (i > 0) {
          await Future.delayed(const Duration(seconds: 1));
        }

        // ボタン経由の読み上げ中に別の操作（停止、次へ、前へなど）があった場合の中断チェック
        if (_stopRequested || currentGen != _readingGeneration) {
          print(
              '回答読み上げ(ボタン経由)中に中断されました (ループ $i 回目) stopRequested:$_stopRequested, generation:$_readingGeneration (expected:$currentGen)');
          // _stopSpeaking が呼ばれていれば isPlaying は false になっているはず
          // そうでない場合（例：次へ/前へ）は isPlaying は true のままかもしれないが、
          // 新しい _speakCurrentCard が始まるので、ここでの setState は不要かもしれない。
          // 安全のため、明示的な停止要求(_stopRequested=true)で世代が一致する場合のみ isPlaying=false にする。
          if (_stopRequested && currentGen == _readingGeneration) {
            setState(() {
              isPlaying = false;
            });
          }
          return; // 中断されたらこの関数の処理を終了
        }

        print('回答読み上げ実行 (ボタン経由, ループ $i 回目)');
        // コントローラーの speak が完了するまで待つ
        await _tts.speak(card.answer, card.answerEnglishFlag);
      }
      print('回答読み上げ完了 (ボタン経由)');

      // 読み上げが中断されずに完了した場合、共通の後処理を呼び出す
      await _handlePostAnswerPlayback(currentGen);
    } catch (e) {
      print('回答読み上げエラー (ボタン経由): $e');
      // エラー発生時も停止状態にする
      if (currentGen == _readingGeneration) {
        // 他のプロセスが始まっていなければ
        setState(() {
          isPlaying = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (cards.isEmpty) {
      return Scaffold(
        appBar: AppBar(
          title: Text('読み上げ: ${widget.deck.deckName}'),
          backgroundColor: Theme.of(context).appBarTheme.backgroundColor,
          actions: [
            // 設定アイコン
            IconButton(
              icon: Icon(Icons.settings, color: Theme.of(context).appBarTheme.foregroundColor),
              tooltip: '読み上げ設定',
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const TtsSettingScreen(),
                  ),
                ).then((_) {
                  setState(() {});
                });
              },
            ),
            // ホームアイコン
            IconButton(
              icon: const Icon(Icons.home),
              tooltip: 'ホームへ戻る',
              onPressed: () {
                Navigator.of(context).popUntil((route) => route.isFirst);
              },
            ),
          ],
        ),
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: const Center(
          child: Text(
            '対象となるカードがありません.',
            style: TextStyle(fontSize: 20),
          ),
        ),
      );
    }
    // 画面サイズによって文字サイズを調整
    final screenWidth = MediaQuery.of(context).size.width;
    final double fontSize =
        screenWidth < 360 ? 10 : (screenWidth < 400 ? 11 : 13);
    final double smallFontSize = fontSize * 0.85;

    return WillPopScope(
      onWillPop: () async {
        if (isPlaying) {
          await _stopSpeaking();
        }

        // ホーム画面のデータを更新するための処理
        HiveService.refreshDatabase();

        return true;
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text('読み上げ: ${widget.deck.deckName}'),
          backgroundColor: Theme.of(context).appBarTheme.backgroundColor,
          actions: [
            // 設定アイコン（右から2番目）
            IconButton(
              icon: Icon(Icons.settings, color: Theme.of(context).appBarTheme.foregroundColor),
              tooltip: '読み上げ設定',
              onPressed: () {
                // --- 追加: 再生中なら停止 ---
                if (isPlaying) {
                  _stopSpeaking();
                }
                // --- 追加ここまで ---
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const TtsSettingScreen(),
                  ),
                ).then((_) {
                  setState(() {
                    // --- 変更: _initCards() の代わりに設定値を更新 ---
                    // 設定が変わった可能性があるので、コントローラーから最新の値を取得して反映
                    _loopMode = _tts.loopMode;
                    _randomPlayback = _tts.randomPlayback;
                    _reversePlayback = _tts.reversePlayback;
                    _focusedMemorization = _tts.focusedMemorization;
                    // 必要であれば他の設定値もここで更新
                    // 例: _answerRepeatCount = _tts.answerRepeatCount;
                    //     _answerPauseSeconds = _tts.answerPauseSeconds;
                    // --- 変更ここまで ---
                  });
                });
              },
            ),
            // 編集アイコン（右端）
            IconButton(
              icon: Icon(Icons.edit, color: Theme.of(context).appBarTheme.foregroundColor),
              onPressed: () {
                // --- 追加: 再生中なら停止 ---
                if (isPlaying) {
                  _stopSpeaking(); // awaitは不要かもしれないが念のため追加しておく
                }
                // --- 追加ここまで ---

                final cardBox = HiveService.getCardBox();
                final currentCard = _getCurrentCard(); // 現在表示されているカードを取得
                final cardKey =
                    cardBox.keyAt(cardBox.values.toList().indexOf(currentCard));

                print('編集: カード "${currentCard.question}" (キー: $cardKey)');

                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => CardEditScreen(cardKey: cardKey),
                  ),
                ).then((_) {
                  setState(() {
                    // --- 変更: _initCards() の代わりに状態を更新 ---
                    try {
                      final cardBox = HiveService.getCardBox();
                      final updatedCard = cardBox.get(cardKey); // 編集後のカードを取得

                      if (updatedCard != null) {
                        // カードが存在する場合 (編集された場合)
                        print('カード情報更新: ${updatedCard.question}');
                        // cardsリスト内で該当カードを探して更新
                        final indexInList =
                            cards.indexWhere((card) => card.key == cardKey);
                        if (indexInList != -1) {
                          cards[indexInList] = updatedCard;
                          // cardIndices はキーが変わらない限り更新不要
                        } else {
                          // もしリストに存在しないキーならエラーだが、通常は起こらないはず
                          print('エラー: 更新対象のカードがリスト内に見つかりません (key: $cardKey)');
                          // 安全のため再初期化も検討
                          _initCards();
                        }
                      } else {
                        // カードが存在しない場合 (削除された場合)
                        print('カード削除: キー $cardKey');

                        // 元のインデックスとリスト内での位置を取得
                        final originalCardIndex =
                            cards.indexWhere((c) => c.key == cardKey);
                        if (originalCardIndex == -1) {
                          print('エラー: 削除対象のカードがリスト内に見つかりません (key: $cardKey)');
                          return; // 何もしない
                        }
                        final indexInCardIndices =
                            cardIndices.indexOf(originalCardIndex);

                        // リストから削除
                        cards.removeAt(originalCardIndex);

                        // cardIndicesからも削除し、それより大きい値はデクリメント
                        if (indexInCardIndices != -1) {
                          cardIndices.removeAt(indexInCardIndices);
                          for (int i = 0; i < cardIndices.length; i++) {
                            if (cardIndices[i] > originalCardIndex) {
                              cardIndices[i]--;
                            }
                          }
                        }

                        // currentIndexの調整
                        if (cards.isEmpty) {
                          // リストが空になった場合
                          print('カードがなくなりました');
                          currentIndex = 0;
                          isPlaying = false; // 再生停止
                          _showAnswer = false;
                          _showRatingButtons = false;
                          // 必要なら「カードなし」画面に遷移するなどの処理
                        } else {
                          if (currentIndex >= cards.length) {
                            // 削除によってcurrentIndexが範囲外になった場合(最後のカードが削除されたなど)
                            currentIndex = cards.length - 1; // 最後のカードに移動
                          }
                          // それ以外（表示中より前のカードが削除されたなど）の場合、
                          // cardIndicesの更新で対応されるためcurrentIndex自体の変更は不要な場合が多い
                          // ただし、表示中のカードが削除された場合は考慮が必要
                          if (indexInCardIndices != -1 &&
                              indexInCardIndices == currentIndex) {
                            // 表示中のカードが削除された場合、currentIndexを調整する必要がある
                            // 例: 範囲を超えないように調整（既に上で実施）
                            // 必要であれば再生を停止し、表示を更新する
                            print('表示中のカードが削除されました。');
                            if (isPlaying) {
                              _stopSpeaking(); // 再生中なら停止
                            }
                            _showAnswer = false;
                            _showRatingButtons = false;
                            // 新しいcurrentIndexでカードを読み上げるかは要件次第
                            // ここでは停止して表示更新のみ行う
                          }
                        }
                      }

                      // Hiveの変更をリフレッシュ（他の画面に影響する可能性があるため）
                      HiveService.refreshDatabase();
                    } catch (e) {
                      print('カード情報の確認または更新エラー: $e');
                      // エラーが発生した場合は安全のため再初期化
                      _initCards();
                    }
                    // --- 変更ここまで ---
                  });
                });
              },
            ),
          ],
        ),
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              // --- スクロール可能エリア ---
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: double.infinity,
                        child: SelectableText(
                          // 質問
                          _questionText,
                          style: TextStyle(
                              fontSize: 24, color: Theme.of(context).textTheme.headlineMedium?.color),
                          textAlign: TextAlign.left,
                        ),
                      ),
                      const SizedBox(height: 20),
                      if (_showAnswer) ...[
                        Divider(
                          color: Theme.of(context).dividerColor,
                          thickness: 1.0,
                          height: 20,
                        ),
                        SelectableText(
                          // 回答
                          _answerText,
                          style: TextStyle(
                              fontSize: 24, color: Theme.of(context).textTheme.headlineSmall?.color),
                        ),
                        // --- 解説表示を追加 ---
                        if (_getCurrentCard().explanation.isNotEmpty) ...[
                          const SizedBox(height: 20), // 回答との間にスペース
                          Divider(
                            // 区切り線
                            color: Theme.of(context).dividerColor,
                            thickness: 0.5,
                            height: 10,
                          ),
                          const SizedBox(height: 8), // Dividerと解説本文のスペース
                          SelectableText(
                            // 解説本文
                            _getCurrentCard().explanation,
                            style: TextStyle(
                                fontSize: 18, color: Theme.of(context).textTheme.bodyMedium?.color?.withOpacity(0.7)),
                          ),
                        ],
                        // --- 解説表示ここまで ---

                        // ★★★ 補足表示を追加 ★★★
                        if (_getCurrentCard().supplement != null &&
                            _getCurrentCard().supplement!.isNotEmpty) ...[
                          const SizedBox(height: 20), // 解説との間にスペース
                          Divider(
                            color: Theme.of(context).dividerColor,
                            thickness: 0.5,
                            height: 10,
                          ),
                          const SizedBox(height: 8), // Dividerと補足本文のスペース
                          SelectableText(
                            // 補足本文
                            _getCurrentCard().supplement!,
                            style: TextStyle(
                                fontSize: 16,
                                color: Theme.of(context).textTheme.bodySmall?.color?.withOpacity(0.6)), // 少し小さめの文字
                          ),
                        ],
                        // ★★★ 補足表示ここまで ★★★
                      ],
                    ],
                  ),
                ),
              ),
              // --- スクロール可能エリアここまで ---

              // ボタンエリア: 状態に応じて「回答を表示」または4択ボタンを表示
              if (_showRatingButtons) ...[
                // 理解度評価ボタン（4段階）- 回答表示後に表示
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () {
                          _updateSM2(_getCurrentCard(), 0);
                          _goToNextCard();
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Theme.of(context).colorScheme.surface,
                          side: BorderSide(color: Theme.of(context).colorScheme.error),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          minimumSize: const Size(0, 48),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 2, vertical: 4),
                        ),
                        child: Text('当日中',
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error, fontSize: fontSize, fontWeight: FontWeight.w600),
                            textAlign: TextAlign.center,
                            maxLines: 1),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () {
                          _updateSM2(_getCurrentCard(), 1);
                          _goToNextCard();
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Theme.of(context).colorScheme.surface,
                          side: BorderSide(color: CustomColors.difficult),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          minimumSize: const Size(0, 48),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 2, vertical: 4),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text('難しい',
                                style: TextStyle(
                                    color: CustomColors.difficult, fontSize: fontSize, fontWeight: FontWeight.w600),
                                textAlign: TextAlign.center,
                                maxLines: 1),
                            Text('${_getDaysUntilNextReview(1)}日後',
                                style: TextStyle(
                                    color: CustomColors.difficult.withOpacity(0.7),
                                    fontSize: smallFontSize + 1,
                                    fontWeight: FontWeight.w600),
                                textAlign: TextAlign.center,
                                maxLines: 1),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () {
                          _updateSM2(_getCurrentCard(), 3);
                          _goToNextCard();
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Theme.of(context).colorScheme.surface,
                          side: BorderSide(color: CustomColors.correct),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          minimumSize: const Size(0, 48),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 2, vertical: 4),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text('正解',
                                style: TextStyle(
                                    color: CustomColors.correct, fontSize: fontSize, fontWeight: FontWeight.w600),
                                textAlign: TextAlign.center,
                                maxLines: 1),
                            Text('${_getDaysUntilNextReview(3)}日後',
                                style: TextStyle(
                                    color: CustomColors.correct.withOpacity(0.7),
                                    fontSize: smallFontSize + 1,
                                    fontWeight: FontWeight.w600),
                                textAlign: TextAlign.center,
                                maxLines: 1),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () {
                          _updateSM2(_getCurrentCard(), 4);
                          _goToNextCard();
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Theme.of(context).colorScheme.surface,
                          side: BorderSide(color: Theme.of(context).colorScheme.primary),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          minimumSize: const Size(0, 48),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 2, vertical: 4),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text('簡単',
                                style: TextStyle(
                                    color: Theme.of(context).colorScheme.primary, fontSize: fontSize, fontWeight: FontWeight.w600),
                                textAlign: TextAlign.center,
                                maxLines: 1),
                            Text('${_getDaysUntilNextReview(4)}日後',
                                style: TextStyle(
                                    color: Theme.of(context).colorScheme.primary.withOpacity(0.7),
                                    fontSize: smallFontSize + 1,
                                    fontWeight: FontWeight.w600),
                                textAlign: TextAlign.center,
                                maxLines: 1),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ] else ...[
                // 「回答を表示」ボタン - 質問読み上げ中に表示
                SizedBox(
                  // RowではなくSizedBoxでラップして中央寄せや幅調整をしやすくする
                  width: double.infinity, // 横幅いっぱいに広げる
                  child: ElevatedButton(
                    onPressed: _handleShowAnswerButtonPressed, // 新しいハンドラを呼び出す
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.surface,
                      side: BorderSide(color: Theme.of(context).colorScheme.outline),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      minimumSize: const Size(0, 48), // 高さを指定
                      padding: const EdgeInsets.symmetric(
                          vertical: 12), // 上下のパディング調整
                    ),
                    child: Text('回答を表示',
                        style: TextStyle(fontSize: 18, color: Theme.of(context).colorScheme.onSurface)),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              // 上段：ループモード切替 & 読み上げ回数設定 & ランダム再生
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _toggleLoopMode,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.surface,
                        side: BorderSide(color: Theme.of(context).colorScheme.outline),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        minimumSize: const Size(0, 48),
                      ),
                      child: _buildLoopIcon(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () {
                        // 読み上げ回数設定ボタン
                        _showRepeatCountDialog();
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.surface,
                        side: BorderSide(color: Theme.of(context).colorScheme.outline),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        minimumSize: const Size(0, 48),
                      ),
                      child: Text(
                        "${_tts.answerRepeatCount}",
                        style: TextStyle(
                          fontSize: 24,
                          color: Theme.of(context).colorScheme.onSurface,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _toggleRandomPlayback,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.surface,
                        side: BorderSide(color: Theme.of(context).colorScheme.outline),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        minimumSize: const Size(0, 48),
                      ),
                      child: Tooltip(
                        message: 'ランダム再生 ${_randomPlayback ? "ON" : "OFF"}',
                        child: Icon(
                          Icons.shuffle,
                          size: 30,
                          color: _randomPlayback ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // 下段：前のカード／停止or再生／次のカード（各ボタンを Expanded で均等配置）
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () async {
                        await _goToPreviousCard();
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.surface,
                        side: BorderSide(color: Theme.of(context).colorScheme.outline),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        minimumSize: const Size(0, 48),
                      ),
                      child: Icon(Icons.chevron_left,
                          size: 24, color: Theme.of(context).colorScheme.onSurface),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton(
                      key: ValueKey<String>('play_stop_button_$isPlaying'),
                      onPressed: () {
                        if (isPlaying) {
                          _stopSpeaking();
                        } else {
                          _speakCurrentCard();
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.surface,
                        side: BorderSide(
                          color: Theme.of(context).colorScheme.outline,
                          width: 1.0,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        minimumSize: const Size(0, 48),
                      ),
                      child: Icon(isPlaying ? Icons.stop : Icons.play_arrow,
                          size: 28, color: Theme.of(context).colorScheme.onSurface),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () async {
                        await _goToNextCard();
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.surface,
                        side: BorderSide(color: Theme.of(context).colorScheme.outline),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        minimumSize: const Size(0, 48),
                      ),
                      child: Icon(Icons.chevron_right,
                          size: 24, color: Theme.of(context).colorScheme.onSurface),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 64),
            ],
          ),
        ),
      ),
    );
  }
}
