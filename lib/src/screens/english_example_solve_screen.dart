import 'dart:math';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/english_example.dart';
import '../services/sm2_calculator.dart';
import '../services/tts_service.dart';
import '../supabase/english_example_learning_state_remote.dart';
import '../widgets/english_example_sm2_rating_row.dart';
import 'tts_setting_screen.dart';

/// 英語例文の出題画面（SM-2 学習状況管理付き）
///
/// 表=日本語 → 裏=英語（[TtsService.reversePlayback] で逆転可）
///
/// TTS は yomiage 読み上げ復習モードに準拠:
///   - 質問を読み上げ → [TtsService.answerPauseSeconds] 秒ポーズ → 答え表示
///   - 答えを [TtsService.answerRepeatCount] 回（英問日答なら 1 回）、間に 1 秒
///   - 「回答を表示」でポーズをスキップして答え側へ
///   - ループモード・ランダム・停止/再生・前後カード
///
/// [cardMode] が true のとき（知識カードからの例文など）:
///   - 自動では読み上げない。中央の再生ボタンでそのとき表示中の面だけ読む（質問面＝和文/出題のみ、解答表示後＝英文など）
///   - 「回答を表示」は表示のみ（音声は付けない）
///   - ループ・ランダム・SM-2・前後カードなどは読み上げモードと同じ
///
/// SM-2 保存は評価ボタン押下時に Supabase へ upsert。
class EnglishExampleSolveScreen extends StatefulWidget {
  const EnglishExampleSolveScreen({
    super.key,
    required this.examples,
    this.subjectName,
    this.sessionDescriptor,
    this.initialStates = const {},
    this.cardMode = false,
  });

  final List<EnglishExample> examples;
  final String? subjectName;

  /// AppBar 用（例: 復習モード、単元名）
  final String? sessionDescriptor;
  final Map<String, Map<String, dynamic>> initialStates;

  /// true: 自動読み上げなし・音声は再生ボタンのみ（上記コメント参照）
  final bool cardMode;

  @override
  State<EnglishExampleSolveScreen> createState() => _EnglishExampleSolveScreenState();
}

class _EnglishExampleSolveScreenState extends State<EnglishExampleSolveScreen> {
  final _client = Supabase.instance.client;

  /// `widget.examples` へのインデックス（集中暗記フィルタ後・任意でシャッフル）
  List<int> _displayOrder = [];
  int _orderPos = 0;

  int _readingGeneration = 0;
  bool _stopRequested = false;
  bool _shuffleOnNextTransition = false;

  bool _showAnswer = false;
  bool _showRatingButtons = false;
  bool _ttsPlaying = false;
  bool _saving = false;

  Map<String, dynamic>? _currentState;
  late Map<String, Map<String, dynamic>> _statesCache;

  EnglishExample get _current => widget.examples[_displayOrder[_orderPos]];

  String? get _learnerId => _client.auth.currentUser?.id;

  String get _questionText {
    final ex = _current;
    return TtsService.reversePlayback ? ex.backEn : ex.frontJa;
  }

  bool get _questionIsEnglish => TtsService.reversePlayback;

  String get _answerText {
    final ex = _current;
    return TtsService.reversePlayback ? ex.frontJa : ex.backEn;
  }

  bool get _answerIsEnglish => !TtsService.reversePlayback;

  bool get _hasQuestion => _questionText.trim().isNotEmpty;
  bool get _hasAnswer => _answerText.trim().isNotEmpty;

  void _maybeAutoStartSpeaking() {
    if (!widget.cardMode) {
      _speakCurrentCard();
    }
  }

  @override
  void initState() {
    super.initState();
    _statesCache = Map.from(widget.initialStates);
    TtsService.initTts().then((_) {
      if (!mounted) return;
      _rebuildDisplayOrder();
      if (_displayOrder.isEmpty) {
        setState(() {});
        return;
      }
      _currentState = _statesCache[_current.id];
      // cardMode では自動読み上げが無く、この後に setState が無いと初回の空表示のままになる。
      setState(() {});
      _maybeAutoStartSpeaking();
    });
  }

  @override
  void dispose() {
    TtsService.stop();
    super.dispose();
  }

  void _rebuildDisplayOrder() {
    final eligible = <int>[];
    for (var i = 0; i < widget.examples.length; i++) {
      if (TtsService.focusedMemorization) {
        final id = widget.examples[i].id;
        final rep = (_statesCache[id]?['repetitions'] as int?) ?? 0;
        if (rep > 1) continue;
      }
      eligible.add(i);
    }
    _displayOrder = eligible;
    if (TtsService.randomPlayback && _displayOrder.length > 1) {
      _displayOrder = List.of(_displayOrder)..shuffle(Random());
    }
    _orderPos = 0;
  }

  void _shuffleRemainingFromOrderPos() {
    if (!TtsService.randomPlayback || _displayOrder.length <= 1) return;
    if (_orderPos >= _displayOrder.length - 1) return;
    final head = _displayOrder.sublist(0, _orderPos + 1);
    final tail = _displayOrder.sublist(_orderPos + 1)..shuffle(Random());
    _displayOrder = [...head, ...tail];
  }

  // ──────────────────────────────
  // TTS（yomiage 相当）
  // ──────────────────────────────

  Future<void> _stopSpeaking() async {
    _stopRequested = true;
    _readingGeneration++;
    await TtsService.stop();
    if (mounted) setState(() => _ttsPlaying = false);
  }

  Future<void> _speakCurrentCard() async {
    if (!mounted || _displayOrder.isEmpty || !_hasQuestion) return;

    final int gen = ++_readingGeneration;

    setState(() {
      _ttsPlaying = true;
      _stopRequested = false;
      _showAnswer = false;
      _showRatingButtons = false;
    });

    await Future.delayed(Duration.zero);

    try {
      await TtsService.speak(_questionText, isEnglish: _questionIsEnglish);
      if (_stopRequested || gen != _readingGeneration || !mounted) return;

      await Future.delayed(Duration(seconds: TtsService.answerPauseSeconds));
      if (_stopRequested || gen != _readingGeneration || !mounted) return;

      if (!mounted) return;
      setState(() {
        _showAnswer = true;
        _showRatingButtons = true;
      });

      final a = _answerText;
      if (a.trim().isEmpty) {
        await _handlePostAnswerPlayback(gen);
        return;
      }

      final ae = _answerIsEnglish;
      final bool qEnAJa = _questionIsEnglish && !ae;
      final int repeatCount = qEnAJa ? 1 : TtsService.answerRepeatCount;

      for (var i = 0; i < repeatCount; i++) {
        if (i > 0) {
          await Future.delayed(const Duration(seconds: 1));
        }
        if (_stopRequested || gen != _readingGeneration || !mounted) return;
        await TtsService.speak(a, isEnglish: ae);
      }

      if (!mounted) return;
      await _handlePostAnswerPlayback(gen);
    } catch (_) {
      if (mounted && gen == _readingGeneration) {
        setState(() => _ttsPlaying = false);
      }
    }
  }

  /// [cardMode]: 再生ボタンのみ。質問面では出題文のみ、解答表示後は答え（繰り返し設定どおり）。
  /// 解答読了後は読み上げモードと同様にループ設定で進む。
  Future<void> _manualCardModePlayback() async {
    if (!mounted || _displayOrder.isEmpty) return;
    final int gen = ++_readingGeneration;
    _stopRequested = false;
    setState(() => _ttsPlaying = true);

    try {
      if (!_showAnswer) {
        if (!_hasQuestion) {
          if (mounted) setState(() => _ttsPlaying = false);
          return;
        }
        await TtsService.speak(_questionText, isEnglish: _questionIsEnglish);
        if (_stopRequested || gen != _readingGeneration || !mounted) return;
        if (mounted) setState(() => _ttsPlaying = false);
        return;
      }

      final a = _answerText;
      if (a.trim().isEmpty) {
        if (mounted) setState(() => _ttsPlaying = false);
        return;
      }
      final ae = _answerIsEnglish;
      final bool qEnAJa = _questionIsEnglish && !ae;
      final int repeatCount = qEnAJa ? 1 : TtsService.answerRepeatCount;

      for (var i = 0; i < repeatCount; i++) {
        if (i > 0) await Future.delayed(const Duration(seconds: 1));
        if (_stopRequested || gen != _readingGeneration || !mounted) return;
        await TtsService.speak(a, isEnglish: ae);
      }
      if (!mounted) return;
      await _handlePostAnswerPlayback(gen);
    } catch (_) {
      if (mounted && gen == _readingGeneration) {
        setState(() => _ttsPlaying = false);
      }
    }
  }

  Future<void> _handleShowAnswerButtonPressed() async {
    _stopRequested = true;
    _readingGeneration++;
    await TtsService.stop();

    if (!mounted) return;

    if (widget.cardMode) {
      setState(() {
        _showAnswer = true;
        _showRatingButtons = true;
        _ttsPlaying = false;
      });
      return;
    }

    setState(() {
      _showAnswer = true;
      _showRatingButtons = true;
      _ttsPlaying = true;
    });

    await Future.delayed(const Duration(milliseconds: 100));

    final int currentGen = _readingGeneration;
    _stopRequested = false;

    final a = _answerText;
    if (a.trim().isEmpty) {
      if (mounted) setState(() => _ttsPlaying = false);
      return;
    }

    final ae = _answerIsEnglish;
    final bool qEnAJa = _questionIsEnglish && !ae;
    final int repeatCount = qEnAJa ? 1 : TtsService.answerRepeatCount;

    try {
      for (var i = 0; i < repeatCount; i++) {
        if (i > 0) {
          await Future.delayed(const Duration(seconds: 1));
        }
        if (_stopRequested || currentGen != _readingGeneration || !mounted) {
          if (_stopRequested && currentGen == _readingGeneration && mounted) {
            setState(() => _ttsPlaying = false);
          }
          return;
        }
        await TtsService.speak(a, isEnglish: ae);
      }
      if (!mounted) return;
      await _handlePostAnswerPlayback(currentGen);
    } catch (_) {
      if (mounted && currentGen == _readingGeneration) {
        setState(() => _ttsPlaying = false);
      }
    }
  }

  Future<void> _handlePostAnswerPlayback(int generation) async {
    if (_stopRequested || generation != _readingGeneration || !mounted) return;
    await Future.delayed(const Duration(seconds: 1));
    if (_stopRequested || generation != _readingGeneration || !mounted) return;

    switch (TtsService.loopMode) {
      case LoopMode.none:
        if (mounted) setState(() => _ttsPlaying = false);
        break;
      case LoopMode.once:
      case LoopMode.all:
        await _advanceAfterAnswerPlayback(generation);
        break;
      case LoopMode.single:
        if (!mounted) return;
        setState(() {
          _showAnswer = false;
          _showRatingButtons = false;
        });
        await Future.delayed(Duration.zero);
        if (_stopRequested || generation != _readingGeneration || !mounted) return;
        _maybeAutoStartSpeaking();
        break;
    }
  }

  Future<void> _advanceAfterAnswerPlayback(int generation) async {
    if (!mounted || _stopRequested || generation != _readingGeneration) return;

    final atLast = _orderPos >= _displayOrder.length - 1;

    if (atLast && TtsService.loopMode == LoopMode.once) {
      _stopRequested = true;
      _readingGeneration++;
      await TtsService.stop();
      if (!mounted) return;
      setState(() {
        _ttsPlaying = false;
        _orderPos = 0;
        _showAnswer = false;
        _showRatingButtons = false;
      });
      await _showRoundCompletedDialog();
      return;
    }

    _stopRequested = true;
    _readingGeneration++;
    await TtsService.stop();

    if (!mounted) return;
    setState(() {
      _stopRequested = false;
      if (atLast) {
        if (TtsService.randomPlayback) {
          _displayOrder = List.of(_displayOrder)..shuffle(Random());
        }
        _orderPos = 0;
      } else {
        _orderPos++;
      }
      _showAnswer = false;
      _showRatingButtons = false;
      _currentState = _statesCache[_current.id];
    });

    _maybeAutoStartSpeaking();
  }

  void _toggleLoopMode() {
    LoopMode next;
    switch (TtsService.loopMode) {
      case LoopMode.none:
        next = LoopMode.once;
        break;
      case LoopMode.once:
        next = LoopMode.all;
        break;
      case LoopMode.all:
        next = LoopMode.single;
        break;
      case LoopMode.single:
        next = LoopMode.none;
        break;
    }
    TtsService.setLoopMode(next);
    setState(() {});
  }

  void _toggleRandomPlayback() {
    TtsService.setRandomPlayback(!TtsService.randomPlayback);
    setState(() {
      _shuffleOnNextTransition = true;
    });
  }

  void _toggleReversePlayback() {
    TtsService.setReversePlayback(!TtsService.reversePlayback);
    setState(() {});
  }

  Widget _buildLoopIcon(ThemeData theme) {
    switch (TtsService.loopMode) {
      case LoopMode.none:
        return Tooltip(
          message: 'ループなし',
          child: Icon(Icons.repeat_outlined, size: 30, color: theme.colorScheme.outline),
        );
      case LoopMode.once:
        return Tooltip(
          message: '一周ループ',
          child: Icon(Icons.repeat_outlined, size: 30, color: theme.colorScheme.onSurface),
        );
      case LoopMode.all:
        return Tooltip(
          message: '全てループ',
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(Icons.repeat, size: 30, color: theme.colorScheme.onSurface),
              Text('all', style: TextStyle(fontSize: 10, color: theme.colorScheme.onSurface)),
            ],
          ),
        );
      case LoopMode.single:
        return Tooltip(
          message: '単一カードループ',
          child: Icon(Icons.repeat_one, size: 30, color: theme.colorScheme.onSurface),
        );
    }
  }

  Future<void> _goToNextCardManual() async {
    _stopRequested = true;
    _readingGeneration++;
    await TtsService.stop();

    if (_displayOrder.isEmpty) return;

    final atLast = _orderPos >= _displayOrder.length - 1;
    final lm = TtsService.loopMode;
    final allowWrap = lm == LoopMode.all || lm == LoopMode.single;

    if (atLast && !allowWrap) {
      if (lm == LoopMode.once) {
        if (mounted) {
          setState(() {
            _ttsPlaying = false;
            _orderPos = 0;
            _showAnswer = false;
            _showRatingButtons = false;
          });
          await _showRoundCompletedDialog();
        }
        return;
      }
      if (mounted) {
        setState(() => _ttsPlaying = false);
        await _showStudyFinishedDialog();
      }
      return;
    }

    setState(() {
      if (_shuffleOnNextTransition) {
        _shuffleRemainingFromOrderPos();
        _shuffleOnNextTransition = false;
      }
      if (atLast) {
        if (TtsService.randomPlayback) {
          _displayOrder = List.of(_displayOrder)..shuffle(Random());
        }
        _orderPos = 0;
      } else {
        _orderPos++;
      }
      _showAnswer = false;
      _showRatingButtons = false;
      _ttsPlaying = !widget.cardMode;
      _currentState = _statesCache[_current.id];
    });
    _maybeAutoStartSpeaking();
  }

  Future<void> _goToPreviousCardManual() async {
    _stopRequested = true;
    _readingGeneration++;
    await TtsService.stop();

    if (_displayOrder.isEmpty) return;

    final canGo = _orderPos > 0 ||
        (TtsService.loopMode != LoopMode.none && TtsService.loopMode != LoopMode.once);

    if (!canGo) {
      if (mounted) setState(() => _ttsPlaying = false);
      return;
    }

    setState(() {
      if (_shuffleOnNextTransition) {
        _shuffleRemainingFromOrderPos();
        _shuffleOnNextTransition = false;
      }
      if (_orderPos > 0) {
        _orderPos--;
      } else {
        _orderPos = _displayOrder.length - 1;
      }
      _showAnswer = false;
      _showRatingButtons = false;
      _ttsPlaying = !widget.cardMode;
      _currentState = _statesCache[_current.id];
    });
    _maybeAutoStartSpeaking();
  }

  void _showRepeatCountDialog() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('回答の読み上げ回数'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 1; i <= 5; i++)
              RadioListTile<int>(
                title: Text('$i 回'),
                value: i,
                groupValue: TtsService.answerRepeatCount,
                onChanged: (value) async {
                  if (value != null) {
                    await TtsService.setAnswerRepeatCount(value);
                    if (context.mounted) Navigator.of(context).pop();
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

  Future<void> _showStudyFinishedDialog() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('完了'),
        content: const Text('このセットの読み上げが終わりました。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _showRoundCompletedDialog() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('完了'),
        content: const Text('一周分の読み上げが終了しました。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _openTtsSettings() async {
    if (_ttsPlaying) {
      await _stopSpeaking();
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const TtsSettingScreen()),
    );
    await TtsService.refreshPrefs();
    if (!mounted) return;
    _stopRequested = true;
    _readingGeneration++;
    await TtsService.stop();
    _rebuildDisplayOrder();
    setState(() {
      _ttsPlaying = false;
      _showAnswer = false;
      _showRatingButtons = false;
    });
    if (_displayOrder.isEmpty) return;
    _orderPos = _orderPos.clamp(0, _displayOrder.length - 1);
    _currentState = _statesCache[_current.id];
    _maybeAutoStartSpeaking();
  }

  // ──────────────────────────────
  // SM-2
  // ──────────────────────────────

  int get _repetitions => (_currentState?['repetitions'] as int?) ?? 0;
  double get _eFactor => (_currentState?['e_factor'] as num?)?.toDouble() ?? 2.5;
  int get _intervalDays => (_currentState?['interval_days'] as int?) ?? 0;
  String? get _remoteRowId => _currentState?['id']?.toString();

  int _previewDays(int quality) => Sm2Calculator.daysUntilNextReview(
        repetitions: _repetitions,
        eFactor: _eFactor,
        intervalDays: _intervalDays,
        quality: quality,
      );

  Future<void> _onRate(int quality) async {
    await TtsService.stop();
    _stopRequested = true;
    _readingGeneration++;

    final learnerId = _learnerId;
    if (learnerId == null) {
      _advanceAfterRate();
      return;
    }

    final result = Sm2Calculator.calculate(
      repetitions: _repetitions,
      eFactor: _eFactor,
      intervalDays: _intervalDays,
      quality: quality,
    );

    setState(() => _saving = true);

    final newId = await EnglishExampleLearningStateRemote.upsertState(
      client: _client,
      learnerId: learnerId,
      exampleId: _current.id,
      knownRemoteRowId: _remoteRowId,
      stateFields: {
        ...result.toSupabaseFields(),
        'reviewed_count': (_currentState?['reviewed_count'] as int?) ?? 0,
      },
      quality: quality,
    );

    if (mounted) {
      final updated = <String, dynamic>{
        ...?_currentState,
        ...result.toSupabaseFields(),
        'id': newId ?? _remoteRowId,
        'learner_id': learnerId,
        'example_id': _current.id,
        'last_quality': quality,
        'reviewed_count': ((_currentState?['reviewed_count'] as int?) ?? 0) + 1,
      };
      _statesCache[_current.id] = updated;
      setState(() => _saving = false);
      _advanceAfterRate();
    }
  }

  void _advanceAfterRate() {
    if (_displayOrder.isEmpty) {
      Navigator.of(context).pop();
      return;
    }

    final atLast = _orderPos >= _displayOrder.length - 1;
    if (!atLast) {
      setState(() {
        _orderPos++;
        _showAnswer = false;
        _showRatingButtons = false;
        _currentState = _statesCache[_current.id];
      });
      _maybeAutoStartSpeaking();
      return;
    }

    final lm = TtsService.loopMode;
    if (lm == LoopMode.all || lm == LoopMode.single) {
      setState(() {
        if (TtsService.randomPlayback) {
          _displayOrder = List.of(_displayOrder)..shuffle(Random());
        }
        _orderPos = 0;
        _showAnswer = false;
        _showRatingButtons = false;
        _currentState = _statesCache[_current.id];
      });
      _maybeAutoStartSpeaking();
    } else {
      Navigator.of(context).pop();
    }
  }

  // ──────────────────────────────
  // Build
  // ──────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (widget.examples.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.subjectName ?? '英語例文')),
        body: const Center(child: Text('出題する例文がありません')),
      );
    }

    if (_displayOrder.isEmpty) {
      return Scaffold(
        appBar: AppBar(
          title: Text(widget.subjectName ?? '英語例文'),
          actions: [
            IconButton(
              icon: const Icon(Icons.settings),
              tooltip: '読み上げ設定',
              onPressed: () async {
                await Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(builder: (_) => const TtsSettingScreen()),
                );
                await TtsService.refreshPrefs();
                if (!mounted) return;
                _rebuildDisplayOrder();
                setState(() {});
                if (_displayOrder.isNotEmpty) {
                  _currentState = _statesCache[_current.id];
                  _maybeAutoStartSpeaking();
                }
              },
            ),
          ],
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              TtsService.focusedMemorization
                  ? '集中暗記の条件に合う例文がありません（連続正解が1以下のカードのみ）。\n読み上げ設定で集中暗記をオフにしてください。'
                  : '出題する例文がありません',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    final theme = Theme.of(context);
    final ex = _current;
    final exp = ex.explanation?.trim();
    final sup = ex.supplement?.trim();

    final disabledRating = _saving || (_ttsPlaying && _showRatingButtons);

    final screenWidth = MediaQuery.sizeOf(context).width;
    final ratingFont =
        screenWidth < 360 ? 10.0 : (screenWidth < 400 ? 11.0 : 13.0);
    final ratingSmall = ratingFont * 0.85;

    final appBarFg = theme.appBarTheme.foregroundColor ?? theme.colorScheme.onSurface;
    var title = widget.cardMode ? 'カード' : '読み上げ';
    final desc = widget.sessionDescriptor?.trim();
    if (desc != null && desc.isNotEmpty) {
      title += ' · $desc';
    }
    title += ': ${widget.subjectName ?? '英語例文'}';
    if (_displayOrder.length > 1) {
      title += '（${_orderPos + 1} / ${_displayOrder.length}）';
    }

    return PopScope(
      canPop: !_ttsPlaying,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await _stopSpeaking();
        if (context.mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        appBar: AppBar(
          title: Text(title),
          backgroundColor: theme.appBarTheme.backgroundColor,
          foregroundColor: appBarFg,
          actions: [
            IconButton(
              icon: Icon(
                Icons.swap_horiz,
                color: TtsService.reversePlayback ? theme.colorScheme.primary : appBarFg,
              ),
              tooltip: '逆出題 ${TtsService.reversePlayback ? "ON" : "OFF"}',
              onPressed: _saving ? null : _toggleReversePlayback,
            ),
            IconButton(
              icon: Icon(Icons.settings, color: appBarFg),
              tooltip: '読み上げ設定',
              onPressed: _saving ? null : _openTtsSettings,
            ),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_currentState != null) ...[
                        _buildStateSummaryLine(theme),
                        const SizedBox(height: 8),
                      ],
                      SizedBox(
                        width: double.infinity,
                        child: SelectableText(
                          _hasQuestion ? _questionText : '（未設定）',
                          style: TextStyle(
                            fontSize: 24,
                            color: theme.textTheme.headlineMedium?.color,
                          ),
                          textAlign: TextAlign.left,
                        ),
                      ),
                      const SizedBox(height: 20),
                      if (_showAnswer) ...[
                        Divider(
                          color: theme.dividerColor,
                          thickness: 1,
                          height: 20,
                        ),
                        SelectableText(
                          _hasAnswer ? _answerText : '（未設定）',
                          style: TextStyle(
                            fontSize: 24,
                            color: theme.textTheme.headlineSmall?.color,
                          ),
                          textAlign: TextAlign.left,
                        ),
                        if (exp != null && exp.isNotEmpty) ...[
                          const SizedBox(height: 20),
                          Divider(
                            color: theme.dividerColor,
                            thickness: 0.5,
                            height: 10,
                          ),
                          const SizedBox(height: 8),
                          SelectableText(
                            exp,
                            style: TextStyle(
                              fontSize: 18,
                              color: theme.textTheme.bodyMedium?.color?.withOpacity(0.7),
                            ),
                          ),
                        ],
                        if (sup != null && sup.isNotEmpty) ...[
                          const SizedBox(height: 20),
                          Divider(
                            color: theme.dividerColor,
                            thickness: 0.5,
                            height: 10,
                          ),
                          const SizedBox(height: 8),
                          SelectableText(
                            sup,
                            style: TextStyle(
                              fontSize: 16,
                              color: theme.textTheme.bodySmall?.color?.withOpacity(0.6),
                            ),
                          ),
                        ],
                      ],
                    ],
                  ),
                ),
              ),
              if (_showRatingButtons)
                EnglishExampleSm2RatingRow(
                  previewDays: _previewDays,
                  onRate: _onRate,
                  disabled: disabledRating,
                  fontSize: ratingFont,
                  smallFontSize: ratingSmall,
                )
              else ...[
                if (!_hasAnswer && !_hasQuestion)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      '質問・答えの本文がありません',
                      style: TextStyle(
                        fontSize: 14,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                else if (_hasQuestion && !_hasAnswer)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      '答えの本文がありません',
                      style: TextStyle(
                        fontSize: 14,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _saving ? null : _handleShowAnswerButtonPressed,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: theme.colorScheme.surface,
                      side: BorderSide(color: theme.colorScheme.outline),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      minimumSize: const Size(0, 48),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: Text(
                      '回答を表示',
                      style: TextStyle(fontSize: 18, color: theme.colorScheme.onSurface),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _toggleLoopMode,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: theme.colorScheme.surface,
                        side: BorderSide(color: theme.colorScheme.outline),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        minimumSize: const Size(0, 48),
                      ),
                      child: _buildLoopIcon(theme),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _showRepeatCountDialog,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: theme.colorScheme.surface,
                        side: BorderSide(color: theme.colorScheme.outline),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        minimumSize: const Size(0, 48),
                      ),
                      child: Text(
                        '${TtsService.answerRepeatCount}',
                        style: TextStyle(
                          fontSize: 24,
                          color: theme.colorScheme.onSurface,
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
                        backgroundColor: theme.colorScheme.surface,
                        side: BorderSide(color: theme.colorScheme.outline),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        minimumSize: const Size(0, 48),
                      ),
                      child: Tooltip(
                        message: 'ランダム再生 ${TtsService.randomPlayback ? "ON" : "OFF"}',
                        child: Icon(
                          Icons.shuffle,
                          size: 30,
                          color: TtsService.randomPlayback
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _saving ? null : () => _goToPreviousCardManual(),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: theme.colorScheme.surface,
                        side: BorderSide(color: theme.colorScheme.outline),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        minimumSize: const Size(0, 48),
                      ),
                      child: Icon(Icons.chevron_left, color: theme.colorScheme.onSurface),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _saving
                          ? null
                          : () {
                              if (_ttsPlaying) {
                                _stopSpeaking();
                              } else if (widget.cardMode) {
                                _manualCardModePlayback();
                              } else {
                                _speakCurrentCard();
                              }
                            },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: theme.colorScheme.surface,
                        side: BorderSide(color: theme.colorScheme.outline),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        minimumSize: const Size(0, 48),
                      ),
                      child: Icon(
                        _ttsPlaying ? Icons.stop : Icons.play_arrow,
                        size: 28,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _saving ? null : () => _goToNextCardManual(),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: theme.colorScheme.surface,
                        side: BorderSide(color: theme.colorScheme.outline),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        minimumSize: const Size(0, 48),
                      ),
                      child: Icon(Icons.chevron_right, color: theme.colorScheme.onSurface),
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

  /// yomiage 読み上げ画面に合わせた学習状況の 1 行サマリ（スクロール領域内）
  Widget _buildStateSummaryLine(ThemeData theme) {
    final nextReviewStr = _currentState?['next_review_at'] as String?;
    final rep = _repetitions;
    final reviewedCount = (_currentState?['reviewed_count'] as int?) ?? 0;

    var nextLabel = '';
    if (nextReviewStr != null) {
      final dt = DateTime.tryParse(nextReviewStr)?.toLocal();
      if (dt != null) {
        final diff = dt.difference(DateTime.now()).inDays;
        nextLabel = diff <= 0 ? '今日' : '$diff日後';
      }
    }

    final parts = <String>[
      if (nextLabel.isNotEmpty) '次回 $nextLabel',
      '連続正解 $rep 回',
      '累計 $reviewedCount 回',
    ];

    return Text(
      parts.join(' · '),
      style: TextStyle(
        fontSize: 12,
        color: theme.textTheme.bodySmall?.color?.withOpacity(0.75),
      ),
    );
  }

}
