import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/english_example.dart';
import '../sync/english_example_state_sync.dart';
import '../sync/ensure_synced_for_local_read.dart';
import '../sync/sync_engine.dart';
import 'english_example_solve_screen.dart';
import 'question_solve_screen.dart';

/// 復習モード: 一度回答済かつ不正解の問題をまとめて出題する画面。
///
/// - 四択問題: `question_learning_states.last_is_correct == false` のもの
/// - 例文読み上げ: `english_example_learning_states.last_quality` が 0 or 1 のもの
class ReviewModeScreen extends StatefulWidget {
  const ReviewModeScreen({super.key});

  @override
  State<ReviewModeScreen> createState() => _ReviewModeScreenState();
}

class _ReviewModeScreenState extends State<ReviewModeScreen> {
  final _client = Supabase.instance.client;

  bool _loading = true;
  String? _error;

  /// 四択: 不正解の question_id リスト
  List<String> _wrongQuestionIds = [];

  /// 例文: 不正解の EnglishExample リスト
  List<EnglishExample> _wrongExamples = [];

  /// 例文の学習状態キャッシュ（EnglishExampleSolveScreen の initialStates 用）
  Map<String, Map<String, dynamic>> _exampleStates = {};

  String? get _learnerId => _client.auth.currentUser?.id;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await triggerBackgroundSyncWithThrottle();
      if (!mounted) return;

      await Future.wait([
        _loadWrongQuestions(),
        _loadWrongExamples(),
      ]);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 四択問題: last_is_correct == false のものを取得する。
  Future<void> _loadWrongQuestions() async {
    final learnerId = _learnerId;
    if (learnerId == null) return;

    try {
      // 不正解の learning state を取得
      final stateRows = await _client
          .from('question_learning_states')
          .select('question_id')
          .eq('learner_id', learnerId)
          .eq('last_is_correct', false);

      final ids = (stateRows as List)
          .map((r) => (r as Map<String, dynamic>)['question_id']?.toString())
          .where((id) => id != null && id.isNotEmpty)
          .cast<String>()
          .toList();

      if (ids.isEmpty) {
        if (mounted) setState(() => _wrongQuestionIds = []);
        return;
      }

      // 実際に存在する multiple_choice 問題のみ残す
      final questionRows = await _client
          .from('questions')
          .select('id')
          .eq('question_type', 'multiple_choice')
          .inFilter('id', ids);

      final validIds = (questionRows as List)
          .map((r) => (r as Map<String, dynamic>)['id']?.toString())
          .where((id) => id != null && id.isNotEmpty)
          .cast<String>()
          .toList();

      if (mounted) setState(() => _wrongQuestionIds = validIds);
    } catch (e, st) {
      if (kDebugMode) debugPrint('ReviewMode: 四択不正解取得失敗: $e\n$st');
      rethrow;
    }
  }

  /// 例文読み上げ: last_quality が 0 または 1 のものを取得する。
  Future<void> _loadWrongExamples() async {
    final learnerId = _learnerId;
    if (learnerId == null) return;

    try {
      // last_quality == 0 (当日中) または 1 (難しい) の例文 ID を取得
      final stateRows = await _client
          .from('english_example_learning_states')
          .select('example_id, last_quality, repetitions, e_factor, interval_days, next_review_at, reviewed_count')
          .eq('learner_id', learnerId)
          .or('last_quality.eq.0,last_quality.eq.1');

      if ((stateRows as List).isEmpty) {
        if (mounted) {
          setState(() {
            _wrongExamples = [];
            _exampleStates = {};
          });
        }
        return;
      }

      final stateMap = <String, Map<String, dynamic>>{};
      for (final raw in stateRows) {
        final row = raw as Map<String, dynamic>;
        final exId = row['example_id']?.toString();
        if (exId != null && exId.isNotEmpty) {
          stateMap[exId] = row;
        }
      }

      final exampleIds = stateMap.keys.toList();

      // 実際の例文データを取得
      final exampleRows = await _client
          .from('english_examples')
          .select('id, knowledge_id, front_ja, back_en, explanation, supplement, prompt_supplement')
          .inFilter('id', exampleIds);

      final examples = (exampleRows as List)
          .map((r) => EnglishExample.fromRow(r as Map<String, dynamic>))
          .toList();

      // ネイティブ環境ではローカル DB とマージ
      final learnerId2 = _learnerId;
      if (learnerId2 != null && examples.isNotEmpty) {
        try {
          final mergedStates = await EnglishExampleStateSync.fetchLearningStatesHybrid(
            client: _client,
            learnerId: learnerId2,
            exampleIds: exampleIds,
            localDb: SyncEngine.maybeLocalDb,
          );
          // ローカル DB にある場合は last_quality が更新されている可能性があるため再フィルタ
          final filteredExamples = examples.where((ex) {
            final state = mergedStates[ex.id] ?? stateMap[ex.id];
            final q = state?['last_quality'] as int?;
            return q == 0 || q == 1;
          }).toList();

          if (mounted) {
            setState(() {
              _wrongExamples = filteredExamples;
              _exampleStates = mergedStates;
            });
          }
          return;
        } catch (e, st) {
          if (kDebugMode) debugPrint('ReviewMode: hybrid fetch 失敗、リモートデータで続行: $e\n$st');
        }
      }

      // フォールバック: リモートデータをそのまま使う
      if (mounted) {
        setState(() {
          _wrongExamples = examples;
          _exampleStates = stateMap;
        });
      }
    } catch (e, st) {
      if (kDebugMode) debugPrint('ReviewMode: 例文不正解取得失敗: $e\n$st');
      rethrow;
    }
  }

  Future<void> _startQuestionReview() async {
    if (_wrongQuestionIds.isEmpty) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => QuestionSolveScreen(
          questionIds: List<String>.from(_wrongQuestionIds),
          knowledgeTitle: '復習モード',
          isLearnerMode: true,
        ),
      ),
    );
    if (mounted) _load();
  }

  Future<void> _startExampleReview() async {
    if (_wrongExamples.isEmpty) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => EnglishExampleSolveScreen(
          examples: List<EnglishExample>.from(_wrongExamples),
          subjectName: '復習モード',
          sessionDescriptor: '復習モード',
          initialStates: Map<String, Map<String, dynamic>>.from(_exampleStates),
        ),
      ),
    );
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('復習モード'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
            tooltip: '再読み込み',
          ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 16),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('再試行'),
              ),
            ],
          ),
        ),
      );
    }

    final bothEmpty = _wrongQuestionIds.isEmpty && _wrongExamples.isEmpty;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '不正解だった問題をまとめて復習できます。',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 24),
          if (bothEmpty) ...[
            Center(
              child: Column(
                children: [
                  Icon(
                    Icons.check_circle_outline,
                    size: 64,
                    color: Colors.green.shade400,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '不正解の問題はありません',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '引き続き学習を続けましょう！',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
          ] else ...[
            _ReviewCard(
              icon: Icons.quiz_outlined,
              title: '四択問題',
              count: _wrongQuestionIds.length,
              onStart: _wrongQuestionIds.isEmpty ? null : _startQuestionReview,
            ),
            const SizedBox(height: 16),
            _ReviewCard(
              icon: Icons.record_voice_over_outlined,
              title: '例文読み上げ',
              count: _wrongExamples.length,
              onStart: _wrongExamples.isEmpty ? null : _startExampleReview,
            ),
          ],
        ],
      ),
    );
  }
}

/// 各モードの復習カード UI。
class _ReviewCard extends StatelessWidget {
  const _ReviewCard({
    required this.icon,
    required this.title,
    required this.count,
    required this.onStart,
  });

  final IconData icon;
  final String title;
  final int count;
  final VoidCallback? onStart;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasItems = count > 0;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: hasItems
                    ? Colors.red.shade50
                    : Colors.green.shade50,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                icon,
                size: 24,
                color: hasItems ? Colors.red.shade400 : Colors.green.shade400,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    hasItems ? '不正解: $count 問' : '不正解なし',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: hasItems
                              ? Colors.red.shade600
                              : Colors.green.shade600,
                        ),
                  ),
                ],
              ),
            ),
            if (hasItems)
              FilledButton(
                onPressed: onStart,
                child: const Text('復習する'),
              )
            else
              Icon(
                Icons.check_circle,
                color: Colors.green.shade400,
                size: 28,
              ),
          ],
        ),
      ),
    );
  }
}
