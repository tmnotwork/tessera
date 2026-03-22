import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app_scope.dart';
import '../models/knowledge.dart';
import '../supabase/question_learning_state_remote.dart';
import '../sync/ensure_synced_for_local_read.dart';
import '../sync/sync_engine.dart';
import 'four_choice_create_screen.dart';
import 'knowledge_detail_screen.dart';

/// 知識に紐づく問題を解く画面（四択 or テキスト入力）
class QuestionSolveScreen extends StatefulWidget {
  const QuestionSolveScreen({
    super.key,
    required this.questionIds,
    required this.knowledgeTitle,
    this.isLearnerMode = false,
  });

  final List<String> questionIds;
  final String knowledgeTitle;
  /// true のとき、紐づく知識を開く画面も学習者向け（編集不可・例文表示）
  final bool isLearnerMode;

  @override
  State<QuestionSolveScreen> createState() => _QuestionSolveScreenState();
}

class _QuestionSolveScreenState extends State<QuestionSolveScreen> {
  static const String _dontKnowChoiceText = 'わからない';

  int _index = 0;
  Map<String, dynamic>? _question;
  List<String> _choices = [];
  List<Knowledge> _linkedKnowledge = [];
  bool _loading = true;
  String? _error;
  int? _selectedIndex;
  bool _answered = false;
  Future<void>? _pendingSave;
  bool _showManageEdit = false;

  /// 教師用一覧モード、または学習者で profiles.user_id が「教師」の特権プレビュー用 ID。
  bool get _showQuestionEditButton => !widget.isLearnerMode || _showManageEdit;

  List<String> get _currentChoices {
    if (_choices.isNotEmpty) return _choices;
    final c = _question?['choices'];
    if (c is List) return c.map((e) => e.toString()).toList();
    return [];
  }

  @override
  void initState() {
    super.initState();
    _loadQuestion();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      if (await shouldShowLearnerFlowManageShortcut()) {
        setState(() => _showManageEdit = true);
      }
    });
  }

  Future<void> _openQuestionEditor() async {
    if (_index >= widget.questionIds.length) return;
    final questionId = widget.questionIds[_index];
    final updated = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (context) => FourChoiceCreateScreen(questionId: questionId),
      ),
    );
    if (updated == true && mounted) _loadQuestion();
  }

  Future<void> _loadQuestion() async {
    if (_index >= widget.questionIds.length) return;
    setState(() {
      _loading = true;
      _error = null;
      _question = null;
      _choices = [];
      _linkedKnowledge = [];
      _selectedIndex = null;
      _answered = false;
    });
    try {
      await ensureSyncedForLocalRead();
      if (!mounted) return;
      final client = Supabase.instance.client;
      final id = widget.questionIds[_index];
      dynamic row;
      try {
        row = await client
            .from('questions')
            .select('id, knowledge_id, question_type, question_text, correct_answer, explanation, reference, choices, created_at, updated_at')
            .eq('id', id)
            .maybeSingle();
      } on PostgrestException catch (e) {
        if (e.code == '42703' || (e.message.contains('reference') && e.message.contains('does not exist'))) {
          row = await client
              .from('questions')
              .select('id, knowledge_id, question_type, question_text, correct_answer, explanation, choices, created_at, updated_at')
              .eq('id', id)
              .maybeSingle();
        } else {
          rethrow;
        }
      }
      if (row == null) {
        setState(() {
          _error = '問題が見つかりません';
          _loading = false;
        });
        return;
      }
      List<String> choices = [];
      try {
        final choiceRows = await client.from('question_choices').select('choice_text, position').eq('question_id', id).order('position');
        final choiceList = choiceRows as List;
        if (choiceList.isNotEmpty) {
          choices = choiceList.map((r) => (r as Map<String, dynamic>)['choice_text']?.toString() ?? '').toList();
        }
      } catch (_) {}
      if (choices.isEmpty) {
        final c = row['choices'];
        if (c is List) {
          choices = c.map((e) => e.toString()).toList();
        } else if (c is String && c.isNotEmpty) {
          try {
            final decoded = jsonDecode(c);
            if (decoded is List) {
              choices = decoded.map((e) => e.toString()).toList();
            }
          } catch (_) {}
        }
      }
      // 紐づく知識を取得（question_knowledge + questions.knowledge_id）
      List<String> knowledgeIds = [];
      try {
        final junc = await client.from('question_knowledge').select('knowledge_id').eq('question_id', id);
        for (final r in junc as List) {
          final kid = (r as Map<String, dynamic>)['knowledge_id']?.toString();
          if (kid != null && kid.isNotEmpty && !knowledgeIds.contains(kid)) knowledgeIds.add(kid);
        }
        final legacyId = row['knowledge_id']?.toString();
        if (legacyId != null && legacyId.isNotEmpty && !knowledgeIds.contains(legacyId)) knowledgeIds.add(legacyId);
      } catch (_) {}
      List<Knowledge> linked = [];
      if (knowledgeIds.isNotEmpty) {
        try {
          List<dynamic> kRows;
          try {
            kRows = await client
                .from('knowledge')
                .select('*, knowledge_card_tags(tag_id, knowledge_tags(name))')
                .inFilter('id', knowledgeIds);
          } catch (_) {
            kRows = await client.from('knowledge').select().inFilter('id', knowledgeIds);
          }
          linked = kRows.map((r) => Knowledge.fromSupabase(r as Map<String, dynamic>)).toList();
        } catch (_) {}
      }
      if (mounted) {
        setState(() {
          _question = row;
          _choices = choices;
          _linkedKnowledge = linked;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  void _onSelectChoice(int i) {
    if (_answered) return;
    final choices = _currentChoices;
    final selectedText = (i >= 0 && i < choices.length) ? choices[i] : '';
    final correctText = _question?['correct_answer']?.toString() ?? '';
    final isCorrect = selectedText == correctText;
    setState(() {
      _selectedIndex = i;
      _answered = true;
    });
    _pendingSave = _recordLearningProgress(
      selectedIndex: i,
      selectedChoiceText: selectedText,
      isCorrect: isCorrect,
    );
  }

  void _onSelectDontKnow() {
    if (_answered) return;
    final choices = _currentChoices;
    setState(() {
      _selectedIndex = choices.length;
      _answered = true;
    });
    _pendingSave = _recordLearningProgress(
      selectedIndex: choices.length,
      selectedChoiceText: _dontKnowChoiceText,
      isCorrect: false,
    );
  }

  Future<void> _waitPendingSave() async {
    final f = _pendingSave;
    if (f == null) return;
    try {
      await f;
    } catch (_) {
      // 保存失敗でも画面遷移は許可
    } finally {
      _pendingSave = null;
    }
  }

  Future<void> _recordLearningProgress({
    required int selectedIndex,
    required String selectedChoiceText,
    required bool isCorrect,
  }) async {
    final questionId = _question?['id']?.toString();
    if (questionId == null || questionId.isEmpty) return;

    final client = Supabase.instance.client;
    final learner = client.auth.currentUser;
    if (learner == null) return;

    var usedLocalSync = false;
    if (!kIsWeb && SyncEngine.isInitialized) {
      try {
        final recorded = await SyncEngine.instance.recordQuestionLearningProgress(
          learnerId: learner.id,
          questionSupabaseId: questionId,
          selectedIndex: selectedIndex,
          selectedChoiceText: selectedChoiceText,
          isCorrect: isCorrect,
        );
        if (recorded) usedLocalSync = true;
      } catch (_) {
        // ローカル同期経路で失敗した場合のみ Supabase 直接書き込みへフォールバック
      }
    }

    final now = DateTime.now().toUtc();
    final nowIso = now.toIso8601String();

    // 解答ログはローカル同期で送るため、ローカル成功時は Supabase へ二重 insert しない
    if (!usedLocalSync) {
      try {
        await client.from('question_answer_logs').insert({
          'learner_id': learner.id,
          'question_id': questionId,
          'selected_choice_text': selectedChoiceText,
          'selected_index': selectedIndex,
          'is_correct': isCorrect,
          'answered_at': nowIso,
        });
      } catch (_) {
        // ログ保存は失敗しても学習を止めない（未マイグレーション環境を許容）
      }
    }

    // 進捗タイルは Supabase を参照するため、学習状態は必ずリモートへ反映する
    var remoteLearningSaved = false;
    try {
      if (usedLocalSync) {
        final fromLocal = await SyncEngine.instance.buildQuestionLearningStateSupabaseUpsert(
          learnerId: learner.id,
          questionSupabaseId: questionId,
        );
        if (fromLocal != null) {
          final fields = Map<String, dynamic>.from(fromLocal)
            ..remove('learner_id')
            ..remove('question_id');
          final remoteId = await QuestionLearningStateRemote.upsertState(
            client: client,
            learnerId: learner.id,
            questionId: questionId,
            knownRemoteRowId: null,
            stateFields: fields,
          );
          remoteLearningSaved = remoteId != null;
          if (kDebugMode && !remoteLearningSaved) {
            debugPrint('QuestionSolve: question_learning_states 反映失敗（fromLocal） question=$questionId → 直接計算で再試行');
          }
          // 救済: ローカル行からの反映に失敗したら、サーバー上の現在値を読み直して再 upsert
          if (!remoteLearningSaved) {
            remoteLearningSaved = await _upsertQuestionLearningStateToSupabase(
              client: client,
              learnerId: learner.id,
              questionId: questionId,
              selectedIndex: selectedIndex,
              selectedChoiceText: selectedChoiceText,
              isCorrect: isCorrect,
              now: now,
              nowIso: nowIso,
            );
          }
        } else {
          remoteLearningSaved = await _upsertQuestionLearningStateToSupabase(
            client: client,
            learnerId: learner.id,
            questionId: questionId,
            selectedIndex: selectedIndex,
            selectedChoiceText: selectedChoiceText,
            isCorrect: isCorrect,
            now: now,
            nowIso: nowIso,
          );
        }
      } else {
        remoteLearningSaved = await _upsertQuestionLearningStateToSupabase(
          client: client,
          learnerId: learner.id,
          questionId: questionId,
          selectedIndex: selectedIndex,
          selectedChoiceText: selectedChoiceText,
          isCorrect: isCorrect,
          now: now,
          nowIso: nowIso,
        );
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('QuestionSolve: question_learning_states 例外: $e\n$st');
      }
    }

    if (!remoteLearningSaved && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: const Text(
            'サーバーへの学習状況の保存に失敗しました。通信を確認し、一覧に戻って更新（再読み込み）するか、しばらくしてから同じ問題でもう一度選択すると再送されます。',
          ),
          duration: const Duration(seconds: 8),
          action: SnackBarAction(
            label: 'OK',
            onPressed: () {},
          ),
        ),
      );
    }
  }

  /// 暗記タイル用に question_learning_states を Supabase へ反映（ローカル同期と併用可）
  /// 成功時 true。
  Future<bool> _upsertQuestionLearningStateToSupabase({
    required SupabaseClient client,
    required String learnerId,
    required String questionId,
    required int selectedIndex,
    required String selectedChoiceText,
    required bool isCorrect,
    required DateTime now,
    required String nowIso,
  }) async {
    Map<String, dynamic>? currentState;
    try {
      final state = await client
          .from('question_learning_states')
          .select('stability, success_streak, lapse_count, reviewed_count')
          .eq('learner_id', learnerId)
          .eq('question_id', questionId)
          .maybeSingle();
      if (state is Map<String, dynamic>) currentState = state;
    } catch (_) {
      currentState = null;
    }

    final prevStability = (currentState?['stability'] as num?)?.toDouble() ?? 1.0;
    final prevStreak = (currentState?['success_streak'] as num?)?.toInt() ?? 0;
    final prevLapse = (currentState?['lapse_count'] as num?)?.toInt() ?? 0;
    final prevReviewed = (currentState?['reviewed_count'] as num?)?.toInt() ?? 0;

    late final int successStreak;
    late final int lapseCount;
    late final double stability;
    late final DateTime nextReviewAt;
    late final double retrievability;

    if (isCorrect) {
      // 初回正解は「既に知っている」とみなし、忘却曲線の対象外にする
      final isFirstCorrect = prevReviewed == 0;
      successStreak = prevStreak + 1;
      lapseCount = prevLapse;
      if (isFirstCorrect) {
        stability = 3650.0;
        nextReviewAt = now.add(const Duration(days: 3650));
        retrievability = 1.0;
      } else {
        stability = (prevStability * 1.25 + 0.5).clamp(1.0, 120.0).toDouble();
        final intervalDays = (stability * (1.0 + successStreak * 0.35)).clamp(1.0, 60.0);
        nextReviewAt = now.add(Duration(minutes: (intervalDays * 24 * 60).round()));
        retrievability = 0.9;
      }
    } else {
      successStreak = 0;
      lapseCount = prevLapse + 1;
      stability = (prevStability * 0.65).clamp(0.5, 60.0).toDouble();
      final reviewHours = lapseCount <= 1 ? 6 : 12;
      nextReviewAt = now.add(Duration(hours: reviewHours));
      retrievability = 0.35;
    }

    final remoteId = await QuestionLearningStateRemote.upsertState(
      client: client,
      learnerId: learnerId,
      questionId: questionId,
      knownRemoteRowId: null,
      stateFields: {
        'stability': stability,
        'difficulty': isCorrect ? 0.45 : 0.7,
        'retrievability': retrievability,
        'success_streak': successStreak,
        'lapse_count': lapseCount,
        'reviewed_count': prevReviewed + 1,
        'last_is_correct': isCorrect,
        'last_selected_choice_text': selectedChoiceText,
        'last_selected_index': selectedIndex,
        'last_review_at': nowIso,
        'next_review_at': nextReviewAt.toUtc().toIso8601String(),
        'updated_at': nowIso,
      },
    );
    if (kDebugMode && remoteId == null) {
      debugPrint('QuestionSolve: question_learning_states 反映失敗（直接計算） question=$questionId learner=$learnerId');
    }
    return remoteId != null;
  }

  /// 学習者モードの四択では、解答するまで次の問題／終了へ進めない。
  bool _canAdvanceToNextOrFinish(List<String> choices) {
    if (!widget.isLearnerMode) return true;
    if (choices.length < 2) return true;
    return _answered;
  }

  Widget? _buildBottomNavigationBar(BuildContext context) {
    if (_loading || _error != null || _question == null) return null;
    final choices = _currentChoices;
    final canAdvance = _canAdvanceToNextOrFinish(choices);
    final theme = Theme.of(context);

    Future<void> goPrev() async {
      await _waitPendingSave();
      if (!mounted) return;
      setState(() {
        _index--;
        _answered = false;
        _selectedIndex = null;
      });
      _loadQuestion();
    }

    Future<void> goNext() async {
      await _waitPendingSave();
      if (!mounted) return;
      setState(() {
        _index++;
        _answered = false;
        _selectedIndex = null;
      });
      _loadQuestion();
    }

    Future<void> finish() async {
      await _waitPendingSave();
      if (!context.mounted) return;
      Navigator.of(context).pop();
    }

    final hasPrev = _index > 0;
    final hasNext = _index < widget.questionIds.length - 1;

    return Material(
      elevation: 8,
      color: theme.colorScheme.surfaceContainerLow,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
          child: Row(
            children: [
              if (hasPrev)
                TextButton.icon(
                  onPressed: goPrev,
                  icon: const Icon(Icons.chevron_left),
                  label: const Text('前の問題'),
                )
              else
                const SizedBox(width: 8),
              const Spacer(),
              if (hasNext)
                FilledButton.icon(
                  onPressed: canAdvance ? goNext : null,
                  icon: const Icon(Icons.chevron_right),
                  label: const Text('次の問題'),
                )
              else
                FilledButton.icon(
                  onPressed: canAdvance ? finish : null,
                  icon: const Icon(Icons.menu_book),
                  label: const Text('知識に戻る'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(
          title: Text('問題（${_index + 1}/${widget.questionIds.length}）'),
          actions: [
            if (_showQuestionEditButton)
              IconButton(
                icon: const Icon(Icons.edit),
                tooltip: 'この問題を編集',
                onPressed: _openQuestionEditor,
              ),
          ],
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null || _question == null) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('問題'),
          actions: [
            if (_showQuestionEditButton)
              IconButton(
                icon: const Icon(Icons.edit),
                tooltip: 'この問題を編集',
                onPressed: _openQuestionEditor,
              ),
          ],
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SelectableText(_error ?? '問題を読み込めません', textAlign: TextAlign.center),
              const SizedBox(height: 16),
              TextButton.icon(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.arrow_back),
                label: const Text('知識に戻る'),
              ),
            ],
          ),
        ),
      );
    }

    final questionText = _question!['question_text']?.toString() ?? '';
    final explanation = _question!['explanation']?.toString() ?? '';
    final reference = _question!['reference']?.toString() ?? '';
    final choices = _currentChoices;
    final isMultipleChoice = choices.length >= 2;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () async {
            await _waitPendingSave();
            if (!context.mounted) return;
            Navigator.of(context).pop();
          },
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('問題を解く（${_index + 1}/${widget.questionIds.length}）'),
            if (widget.knowledgeTitle.isNotEmpty)
              Text(widget.knowledgeTitle, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        actions: [
          if (_showQuestionEditButton)
            IconButton(
              icon: const Icon(Icons.edit),
              tooltip: 'この問題を編集',
              onPressed: _openQuestionEditor,
            ),
        ],
      ),
      bottomNavigationBar: _buildBottomNavigationBar(context),
      body: SingleChildScrollView(
        key: ValueKey<String>(widget.questionIds[_index]),
        padding: const EdgeInsets.all(16),
        child: SelectionArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
            SelectableText(
              questionText,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 24),
            if (isMultipleChoice) ...[
              Text(
                '選択肢',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(height: 8),
              LayoutBuilder(
                builder: (context, constraints) {
                  const breakpointWide = 600.0;
                  const minChoiceWidth = 180.0;
                  const spacing = 8.0;
                  final width = constraints.maxWidth;
                  final isWide = width >= breakpointWide;
                  final choiceCount = choices.length;
                  final useTwoRows =
                      isWide && choiceCount == 4 && (width - 3 * spacing) / 4 < minChoiceWidth;
                  final colorScheme = Theme.of(context).colorScheme;
                  final isDark = Theme.of(context).brightness == Brightness.dark;
                  // 解答後: 背景と文字をペアで揃え、ライト/ダーク両方で十分なコントラストにする
                  final correctBg = isDark ? const Color(0xFF1B4D2E) : const Color(0xFFC8E6C9);
                  final correctFg = isDark ? const Color(0xFFB9F6CA) : const Color(0xFF1B5E20);
                  final wrongBg = colorScheme.errorContainer;
                  final wrongFg = colorScheme.onErrorContainer;

                  Color? choiceBackground({
                    required bool isCorrectChoice,
                    required bool isWrongSelection,
                  }) {
                    if (!_answered) return null;
                    if (isCorrectChoice) return correctBg;
                    if (isWrongSelection) return wrongBg;
                    return null;
                  }

                  TextStyle choiceTextStyle({
                    required bool isCorrectChoice,
                    required bool isWrongSelection,
                  }) {
                    final base = Theme.of(context).textTheme.bodyLarge;
                    if (!_answered) return base ?? const TextStyle();
                    if (isCorrectChoice) {
                      return (base ?? const TextStyle()).copyWith(
                        color: correctFg,
                        fontWeight: FontWeight.w600,
                      );
                    }
                    if (isWrongSelection) {
                      return (base ?? const TextStyle()).copyWith(
                        color: wrongFg,
                        fontWeight: FontWeight.w600,
                      );
                    }
                    return (base ?? const TextStyle()).copyWith(
                      color: colorScheme.onSurface,
                    );
                  }

                  /// スクロール内では縦制約が無限になり得るため、SizedBox.expand + Row.stretch は使わない（レイアウトが壊れる）
                  Widget choiceCard(int i, String text) {
                    final selected = _selectedIndex == i;
                    final correct = _question!['correct_answer']?.toString() == text;
                    final bg = choiceBackground(
                      isCorrectChoice: correct,
                      isWrongSelection: selected && !correct,
                    );
                    final style = choiceTextStyle(
                      isCorrectChoice: correct,
                      isWrongSelection: selected && !correct,
                    );
                    final prefixStyle = Theme.of(context).textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: !_answered
                              ? colorScheme.primary
                              : style.color,
                        );
                    return SizedBox(
                      width: double.infinity,
                      child: Material(
                        color: bg ?? colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(12),
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(
                            color: colorScheme.outlineVariant,
                            width: 1,
                          ),
                        ),
                        child: InkWell(
                          onTap: () => _onSelectChoice(i),
                          borderRadius: BorderRadius.circular(12),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Text(
                                  '${String.fromCharCode(65 + i)}.',
                                  style: prefixStyle,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    text,
                                    style: style,
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (_answered && correct)
                                  Icon(Icons.check_circle, color: correctFg, size: 22),
                                if (_answered && selected && !correct)
                                  Icon(Icons.cancel, color: wrongFg, size: 22),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  }

                  Widget dontKnowCard() {
                    final dontKnowIndex = choiceCount;
                    final selected = _selectedIndex == dontKnowIndex;
                    final showWrong = _answered && selected;
                    final bg = showWrong ? wrongBg : null;
                    final style = choiceTextStyle(
                      isCorrectChoice: false,
                      isWrongSelection: showWrong,
                    );
                    final iconColor = !_answered
                        ? colorScheme.onSurfaceVariant
                        : (showWrong ? wrongFg : colorScheme.onSurfaceVariant);
                    return SizedBox(
                      width: double.infinity,
                      child: Material(
                        color: bg ?? colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(12),
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(
                            color: colorScheme.outlineVariant,
                            width: 1,
                          ),
                        ),
                        child: InkWell(
                          onTap: _onSelectDontKnow,
                          borderRadius: BorderRadius.circular(12),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Icon(Icons.help_outline, size: 22, color: iconColor),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    _dontKnowChoiceText,
                                    style: style,
                                  ),
                                ),
                                if (showWrong) Icon(Icons.cancel, color: wrongFg, size: 22),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  }

                  final belowChoices = Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: dontKnowCard(),
                  );

                  if (!isWide) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (int i = 0; i < choiceCount; i++)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: choiceCard(i, choices[i]),
                          ),
                        dontKnowCard(),
                      ],
                    );
                  }
                  if (choiceCount == 4 && useTwoRows) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: choiceCard(0, choices[0])),
                            const SizedBox(width: spacing),
                            Expanded(child: choiceCard(1, choices[1])),
                          ],
                        ),
                        const SizedBox(height: spacing),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: choiceCard(2, choices[2])),
                            const SizedBox(width: spacing),
                            Expanded(child: choiceCard(3, choices[3])),
                          ],
                        ),
                        belowChoices,
                      ],
                    );
                  }
                  if (choiceCount == 4) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: choiceCard(0, choices[0])),
                            const SizedBox(width: spacing),
                            Expanded(child: choiceCard(1, choices[1])),
                            const SizedBox(width: spacing),
                            Expanded(child: choiceCard(2, choices[2])),
                            const SizedBox(width: spacing),
                            Expanded(child: choiceCard(3, choices[3])),
                          ],
                        ),
                        belowChoices,
                      ],
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (int i = 0; i < choiceCount; i++)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: choiceCard(i, choices[i]),
                        ),
                      dontKnowCard(),
                    ],
                  );
                },
              ),
            ] else
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text('（この問題は四択形式ではありません）', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ),
            if (_answered) ...[
              const SizedBox(height: 24),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('解説', style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
                    const SizedBox(height: 4),
                    SelectableText(explanation.isNotEmpty ? explanation : '（解説はありません）'),
                  ],
                ),
              ),
              if (reference.isNotEmpty) ...[
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.8),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outlineVariant.withOpacity(0.5),
                      width: 1,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('参考', style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                      const SizedBox(height: 4),
                      SelectableText(reference, style: Theme.of(context).textTheme.bodyMedium),
                    ],
                  ),
                ),
              ],
              if (_linkedKnowledge.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  '紐づく知識',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                ),
                const SizedBox(height: 8),
                ..._linkedKnowledge.asMap().entries.map((e) {
                  final idx = e.key;
                  final k = e.value;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Material(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                      child: InkWell(
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute<bool>(
                              builder: (context) => KnowledgeDetailScreen(
                                allKnowledge: _linkedKnowledge,
                                initialIndex: idx,
                                initialEditing: false,
                                isLearnerMode: widget.isLearnerMode,
                              ),
                            ),
                          );
                        },
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          child: Row(
                            children: [
                              Icon(Icons.menu_book, size: 20, color: Theme.of(context).colorScheme.primary),
                              const SizedBox(width: 8),
                              Expanded(child: SelectableText(k.title, style: Theme.of(context).textTheme.bodyMedium)),
                              Icon(Icons.chevron_right, color: Theme.of(context).colorScheme.onSurfaceVariant),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ],
            ],
            // 前へ／次へは bottomNavigationBar に固定（解答後も常に操作しやすい）
            SizedBox(height: MediaQuery.paddingOf(context).bottom + 72),
          ],
        ),
        ),
      ),
    );
  }
}
