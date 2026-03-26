import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app_scope.dart';
import '../models/english_example.dart';
import '../services/study_timer_service.dart';
import '../supabase/english_example_composition_state_remote.dart';
import '../sync/english_example_state_sync.dart';
import '../sync/sync_engine.dart';
import '../utils/word_diff.dart';
import '../widgets/diff_text_display.dart';
import 'english_example_composition_progress_screen.dart';

/// 日本語を見て英語例文を入力し、答え合わせの正誤を自動記録する（読み上げの SM-2 とは別集計）
class EnglishExampleCompositionScreen extends StatefulWidget {
  const EnglishExampleCompositionScreen({
    super.key,
    required this.examples,
    this.subjectName,
    this.sessionDescriptor,
    this.initialIndex = 0,
  });

  final List<EnglishExample> examples;
  final String? subjectName;
  final String? sessionDescriptor;

  /// 0 始まり。チャプター一覧などから途中の例文から連続出題するときに指定。
  final int initialIndex;

  @override
  State<EnglishExampleCompositionScreen> createState() => _EnglishExampleCompositionScreenState();
}

class _EnglishExampleCompositionScreenState extends State<EnglishExampleCompositionScreen> {
  final _client = Supabase.instance.client;
  late final TextEditingController _controller;
  int _index = 0;
  bool _showResult = false;
  bool _lastCorrect = false;
  bool _saving = false;
  bool _showManageEdit = false;

  EnglishExample get _current => widget.examples[_index];

  @override
  void initState() {
    super.initState();
    final n = widget.examples.length;
    if (n > 0) {
      _index = widget.initialIndex.clamp(0, n - 1);
    }
    _controller = TextEditingController();
    unawaited(_restartStudySession());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_refreshManageShortcut());
    });
  }

  Future<void> _refreshManageShortcut() async {
    if (!mounted) return;
    final show = await shouldShowLearnerFlowManageShortcut();
    if (mounted) setState(() => _showManageEdit = show);
  }

  List<Widget> _compositionAppBarActions() {
    return [
      IconButton(
        icon: const Icon(Icons.insights_outlined),
        tooltip: '学習状況',
        onPressed: () {
          Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (context) =>
                  const EnglishExampleCompositionProgressScreen(),
            ),
          );
        },
      ),
      if (_showManageEdit)
        IconButton(
          icon: const Icon(Icons.edit),
          tooltip: '教材を編集',
          onPressed: () =>
              openManageNotifier.openManageEnglishExamples?.call(context),
        ),
    ];
  }

  @override
  void dispose() {
    unawaited(StudyTimerService.instance.endSession());
    _controller.dispose();
    super.dispose();
  }

  Future<void> _restartStudySession() async {
    await StudyTimerService.instance.endSession();
    if (!mounted || widget.examples.isEmpty) return;
    final ex = _current;
    await StudyTimerService.instance.startSession(
      sessionType: 'english_example_composition',
      contentId: ex.id,
      contentTitle: ex.frontJa,
      subjectId: null,
      subjectName: widget.subjectName,
      unit: null,
    );
  }

  /// 採点用：前後空白・連続空白・英大文字小文字を揃え、末尾の句読点差を許容
  static bool answersMatch(String expected, String user) {
    String norm(String s) {
      var t = s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
      t = t.replaceAll(RegExp(r'[.!?，、。．]+$'), '');
      return t;
    }

    return norm(expected) == norm(user);
  }

  Future<void> _checkAnswer() async {
    if (_saving) return;
    final user = _controller.text;
    final ok = answersMatch(_current.backEn, user);

    setState(() => _saving = true);

    final uid = _client.auth.currentUser?.id;
    if (uid != null) {
      if (!kIsWeb && SyncEngine.isInitialized) {
        try {
          await EnglishExampleStateSync.recordCompositionAnswerLocal(
            SyncEngine.instance.localDb,
            learnerId: uid,
            exampleId: _current.id,
            answerCorrect: ok,
          );
          unawaited(SyncEngine.instance.pushDirtyEnglishExampleStatesIfOnline());
        } catch (e, st) {
          if (kDebugMode) {
            debugPrint('EnglishExampleCompositionScreen local save: $e\n$st');
          }
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('記録の保存に失敗しました: $e'),
              duration: const Duration(seconds: 6),
            ),
          );
        }
      } else {
        final saved = await EnglishExampleCompositionStateRemote.recordSession(
          client: _client,
          learnerId: uid,
          exampleId: _current.id,
          answerCorrect: ok,
        );
        if (!mounted) return;
        if (!saved.ok) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(saved.message ?? '記録の保存に失敗しました'),
              duration: const Duration(seconds: 6),
            ),
          );
        }
      }
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ログインすると記録が保存されます')),
      );
    }

    if (!mounted) return;
    setState(() {
      _showResult = true;
      _lastCorrect = ok;
      _saving = false;
    });
  }

  void _goNextOrFinish() {
    final hasNext = _index + 1 < widget.examples.length;
    if (hasNext) {
      setState(() {
        _index++;
        _controller.clear();
        _showResult = false;
      });
      unawaited(_restartStudySession());
    } else {
      Navigator.of(context).pop();
    }
  }

  String _title() {
    final base = widget.sessionDescriptor ?? widget.subjectName ?? '英作文';
    if (widget.examples.length <= 1) return base;
    return '$base（${_index + 1} / ${widget.examples.length}）';
  }

  /// 不正解時: 単語 diff を色付き表示。記号のみ等でトークンが空なら全文をそのまま表示。
  Widget _buildAnswerDiff(BuildContext context, EnglishExample ex) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    final user = _controller.text;
    final lines = wordDiffLines(user, ex.backEn);
    if (lines.userWords.isEmpty && lines.correctWords.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(
            user.isEmpty ? '（入力なし）' : user,
            style: theme.textTheme.bodyLarge?.copyWith(color: onSurface),
          ),
          const SizedBox(height: 12),
          Text(
            '模範解答',
            style: theme.textTheme.labelMedium?.copyWith(color: onSurface),
          ),
          const SizedBox(height: 4),
          SelectableText(
            ex.backEn,
            style: theme.textTheme.bodyLarge?.copyWith(color: onSurface),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DiffTextDisplay.buildUserAnswerText(
          context,
          lines.userWords,
          matchedColor: onSurface,
          addedColor: theme.colorScheme.error,
        ),
        const SizedBox(height: 12),
        Text(
          '模範解答',
          style: theme.textTheme.labelMedium?.copyWith(color: onSurface),
        ),
        const SizedBox(height: 4),
        DiffTextDisplay.buildCorrectAnswerText(
          context,
          lines.correctWords,
          matchedColor: onSurface,
          missingColor: theme.colorScheme.primary,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.examples.isEmpty) {
      return Scaffold(
        appBar: AppBar(
          title: Text(widget.subjectName ?? '英作文'),
          actions: _compositionAppBarActions(),
        ),
        body: const Center(child: Text('例文がありません')),
      );
    }

    final theme = Theme.of(context);
    final ex = _current;

    return Scaffold(
      appBar: AppBar(
        title: Text(_title()),
        actions: _compositionAppBarActions(),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '日本語',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(
                    ex.frontJa.isEmpty ? '（日本語が未設定）' : ex.frontJa,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                '英語で入力',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _controller,
                enabled: !_showResult && !_saving,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: '英文を入力してください',
                ),
              ),
              const SizedBox(height: 16),
              if (!_showResult)
                FilledButton.icon(
                  onPressed: _saving ? null : () => unawaited(_checkAnswer()),
                  icon: _saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.fact_check),
                  label: Text(_saving ? '記録中…' : '答え合わせ'),
                )
              else ...[
                const SizedBox(height: 8),
                Material(
                  color: _lastCorrect
                      ? theme.colorScheme.primaryContainer
                      : theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _lastCorrect ? '正解です' : '不正解です',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: _lastCorrect
                                ? theme.colorScheme.onPrimaryContainer
                                : theme.colorScheme.error,
                          ),
                        ),
                        if (!_lastCorrect) ...[
                          const SizedBox(height: 12),
                          _buildAnswerDiff(context, ex),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _saving ? null : _goNextOrFinish,
                  child: Text(
                    _index + 1 < widget.examples.length ? '次の例文' : '終了',
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
