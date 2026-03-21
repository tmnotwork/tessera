import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/english_example.dart';
import '../services/sm2_calculator.dart';
import '../services/tts_service.dart';
import '../supabase/english_example_learning_state_remote.dart';

/// 英語例文の出題画面（SM-2 学習状況管理付き）
///
/// 表=日本語 → 裏=英語 → 解説・補足 → 4段階自己評価
///
/// TTS 動作:
///   - カード表示時に日本語（表）を自動読み上げ
///   - 「英語（裏）を見る」押下後に英語を自動読み上げ
///   - スピーカーボタンで手動再生
///
/// SM-2 保存:
///   - 評価ボタン押下時に Supabase の english_example_learning_states へ upsert
///   - 学習者ごとに独立して管理（RLS による保護）
class EnglishExampleSolveScreen extends StatefulWidget {
  const EnglishExampleSolveScreen({
    super.key,
    required this.examples,
    this.subjectName,
    /// 各 example_id に対する既存学習状態（null = 未学習）
    this.initialStates = const {},
  });

  final List<EnglishExample> examples;
  final String? subjectName;
  final Map<String, Map<String, dynamic>> initialStates;

  @override
  State<EnglishExampleSolveScreen> createState() => _EnglishExampleSolveScreenState();
}

class _EnglishExampleSolveScreenState extends State<EnglishExampleSolveScreen> {
  final _client = Supabase.instance.client;

  int _index = 0;
  bool _showBack = false;
  bool _ttsPlaying = false;
  bool _saving = false;

  /// 現在の例文の学習状態（Supabase 行データ）
  /// null = 未学習
  Map<String, dynamic>? _currentState;

  /// 各カードの最新状態キャッシュ（example_id → 行データ）
  late Map<String, Map<String, dynamic>> _statesCache;

  EnglishExample get _current => widget.examples[_index];
  bool get _hasNext => _index + 1 < widget.examples.length;
  bool get _hasEn => _current.backEn.trim().isNotEmpty;

  String? get _learnerId => _client.auth.currentUser?.id;

  @override
  void initState() {
    super.initState();
    _statesCache = Map.from(widget.initialStates);
    _currentState = _statesCache[_current.id];
    TtsService.initTts().then((_) => _speakFront());
  }

  @override
  void dispose() {
    TtsService.stop();
    super.dispose();
  }

  // ──────────────────────────────
  // TTS
  // ──────────────────────────────

  Future<void> _speakFront() async {
    if (!mounted) return;
    setState(() => _ttsPlaying = true);
    await TtsService.speak(_current.frontJa, isEnglish: false);
    if (mounted) setState(() => _ttsPlaying = false);
  }

  Future<void> _speakBack() async {
    if (!mounted || !_hasEn) return;
    setState(() => _ttsPlaying = true);
    for (int i = 0; i < TtsService.answerRepeatCount; i++) {
      if (!mounted) break;
      await TtsService.speak(_current.backEn, isEnglish: true);
    }
    if (mounted) setState(() => _ttsPlaying = false);
  }

  Future<void> _onRevealBack() async {
    setState(() => _showBack = true);
    await _speakBack();
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
    TtsService.stop();

    final learnerId = _learnerId;
    if (learnerId == null) {
      // 未ログイン時はスキップして次へ
      _advance();
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
      // キャッシュを更新
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
      _advance();
    }
  }

  void _advance() {
    if (_hasNext) {
      setState(() {
        _index += 1;
        _showBack = false;
        _ttsPlaying = false;
        _currentState = _statesCache[_current.id];
      });
      _speakFront();
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

    final theme = Theme.of(context);
    final ex = _current;
    final exp = ex.explanation?.trim();
    final sup = ex.supplement?.trim();

    return Scaffold(
      appBar: AppBar(
        title: widget.examples.length > 1
            ? Text('${widget.subjectName ?? '英語例文'}（${_index + 1} / ${widget.examples.length}）')
            : Text(widget.subjectName ?? '英語例文'),
        actions: [
          if (_ttsPlaying || _saving)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 学習状況バッジ
            if (_currentState != null) _buildStateBadge(theme),
            const SizedBox(height: 8),

            // 表（日本語）
            Row(
              children: [
                Expanded(
                  child: Text(
                    '日本語（表）',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: _ttsPlaying ? null : _speakFront,
                  icon: const Icon(Icons.volume_up),
                  tooltip: '日本語を読み上げ',
                  color: theme.colorScheme.primary,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SelectableText(
                  ex.frontJa.isEmpty ? '（未設定）' : ex.frontJa,
                  style: theme.textTheme.titleMedium,
                ),
              ),
            ),
            const SizedBox(height: 24),

            if (!_showBack) ...[
              if (_hasEn)
                FilledButton.icon(
                  onPressed: _ttsPlaying ? null : _onRevealBack,
                  icon: const Icon(Icons.translate),
                  label: const Text('英語（裏）を見る'),
                )
              else
                Text(
                  '英語の本文がありません',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ] else ...[
              // 裏（英語）
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '英語（裏）',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _ttsPlaying ? null : _speakBack,
                    icon: const Icon(Icons.volume_up),
                    tooltip: '英語を読み上げ',
                    color: theme.colorScheme.primary,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Card(
                margin: EdgeInsets.zero,
                color: theme.colorScheme.surfaceContainerHighest,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(
                    ex.backEn,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ),

              if (exp != null && exp.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text(
                  '解説',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: SelectableText(exp, style: theme.textTheme.bodyLarge),
                  ),
                ),
              ],
              if (sup != null && sup.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  '補足',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: SelectableText(sup, style: theme.textTheme.bodyMedium),
                  ),
                ),
              ],

              const SizedBox(height: 24),
              Text(
                '英訳できましたか？',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              _buildRatingButtons(theme),
            ],
          ],
        ),
      ),
    );
  }

  /// 現在の学習状況バッジ（次回出題日・連続正解数）
  Widget _buildStateBadge(ThemeData theme) {
    final nextReviewStr = _currentState?['next_review_at'] as String?;
    final rep = _repetitions;
    final reviewedCount = (_currentState?['reviewed_count'] as int?) ?? 0;

    String nextLabel = '';
    if (nextReviewStr != null) {
      final dt = DateTime.tryParse(nextReviewStr)?.toLocal();
      if (dt != null) {
        final diff = dt.difference(DateTime.now()).inDays;
        nextLabel = diff <= 0 ? '今日' : '$diff日後';
      }
    }

    return Wrap(
      spacing: 8,
      children: [
        if (nextLabel.isNotEmpty)
          _Badge(label: '次回 $nextLabel', color: theme.colorScheme.primary),
        _Badge(label: '連続正解 $rep 回', color: theme.colorScheme.secondary),
        _Badge(label: '累計 $reviewedCount 回', color: theme.colorScheme.tertiary),
      ],
    );
  }

  /// 4段階評価ボタン（当日中 / 難しい / 正解 / 簡単）
  Widget _buildRatingButtons(ThemeData theme) {
    final disabled = _saving || _ttsPlaying;
    return Row(
      children: [
        _RatingButton(
          label: '当日中',
          sublabel: null,
          borderColor: theme.colorScheme.error,
          labelColor: theme.colorScheme.error,
          onPressed: disabled ? null : () => _onRate(0),
        ),
        const SizedBox(width: 6),
        _RatingButton(
          label: '難しい',
          sublabel: '${_previewDays(1)}日後',
          borderColor: Colors.orange,
          labelColor: Colors.orange,
          onPressed: disabled ? null : () => _onRate(1),
        ),
        const SizedBox(width: 6),
        _RatingButton(
          label: '正解',
          sublabel: '${_previewDays(3)}日後',
          borderColor: Colors.green,
          labelColor: Colors.green,
          onPressed: disabled ? null : () => _onRate(3),
        ),
        const SizedBox(width: 6),
        _RatingButton(
          label: '簡単',
          sublabel: '${_previewDays(4)}日後',
          borderColor: theme.colorScheme.primary,
          labelColor: theme.colorScheme.primary,
          onPressed: disabled ? null : () => _onRate(4),
        ),
      ],
    );
  }
}

// ──────────────────────────────────────────────
// サブウィジェット
// ──────────────────────────────────────────────

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _RatingButton extends StatelessWidget {
  const _RatingButton({
    required this.label,
    required this.sublabel,
    required this.borderColor,
    required this.labelColor,
    required this.onPressed,
  });

  final String label;
  final String? sublabel;
  final Color borderColor;
  final Color labelColor;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: onPressed == null ? Colors.grey : borderColor),
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
          minimumSize: const Size(0, 52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                color: onPressed == null ? Colors.grey : labelColor,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (sublabel != null)
              Text(
                sublabel!,
                style: TextStyle(
                  color: (onPressed == null ? Colors.grey : labelColor).withOpacity(0.7),
                  fontSize: 11,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
