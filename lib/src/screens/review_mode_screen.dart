import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../database/local_database.dart';
import '../models/english_example.dart';
import '../sync/english_example_state_sync.dart';
import '../sync/ensure_synced_for_local_read.dart';
import '../sync/sync_engine.dart';
import '../utils/english_example_knowledge_order.dart';
import '../utils/knowledge_learner_mem_status.dart';
import '../widgets/force_sync_icon_button.dart';
import 'english_example_composition_screen.dart';
import 'english_example_solve_screen.dart';
import 'question_solve_screen.dart';
import 'settings_screen.dart';

/// ローカル SQLite の [last_is_correct] が 0/1 でも [KnowledgeLearnerMemStatus.triForMcqItem] と整合するよう正規化する。
Map<String, dynamic> _localQuestionLearningRowToUiState(Map<String, dynamic> r) {
  final lic = r['last_is_correct'];
  bool? lastCorrect;
  if (lic == null) {
    lastCorrect = null;
  } else if (lic == true || lic == 1 || lic == 1.0) {
    lastCorrect = true;
  } else if (lic == false || lic == 0 || lic == 0.0) {
    lastCorrect = false;
  } else {
    lastCorrect = null;
  }
  return {
    'last_is_correct': lastCorrect,
    'reviewed_count': r['reviewed_count'],
    'lapse_count': r['lapse_count'],
    'next_review_at': r['next_review_at'],
  };
}

/// 復習モード: 学習状況（四択・例文読み上げ・英作文の進捗画面）で赤タイルになる項目をまとめて出題する画面。
///
/// - 四択: [KnowledgeLearnerMemStatus.triForMcqItem] が要復習（直近不正解 or 復習期限切れ）
/// - 例文読み上げ: [KnowledgeLearnerMemStatus.triForExampleItem] が要復習（進捗画面と同じ）
/// - 英作文: [KnowledgeLearnerMemStatus.triForCompositionItem] が要復習（直近の英作文が不正解）
class ReviewModeScreen extends StatefulWidget {
  const ReviewModeScreen({super.key});

  @override
  State<ReviewModeScreen> createState() => _ReviewModeScreenState();
}

class _ReviewModeScreenState extends State<ReviewModeScreen> {
  final _client = Supabase.instance.client;

  bool _loading = true;
  String? _error;

  /// 四択: 要復習の question_id リスト
  List<String> _wrongQuestionIds = [];

  /// 例文: 要復習の EnglishExample リスト
  List<EnglishExample> _wrongExamples = [];

  /// 英作文: 要復習の EnglishExample リスト（読み上げとは別集計）
  List<EnglishExample> _wrongCompositionExamples = [];

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
        _loadExampleDerivedReviews(),
      ]);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 四択: 進捗画面と同じ「要復習」判定。dirty なローカル行で上書きする。
  Future<void> _loadWrongQuestions() async {
    final learnerId = _learnerId;
    if (learnerId == null) return;

    try {
      final stateRows = await _client
          .from('question_learning_states')
          .select(
            'question_id, last_is_correct, reviewed_count, lapse_count, next_review_at',
          )
          .eq('learner_id', learnerId);

      final stateByQuestion = <String, Map<String, dynamic>>{};
      for (final raw in stateRows as List) {
        final row = raw as Map<String, dynamic>;
        final qid = row['question_id']?.toString();
        if (qid != null && qid.isNotEmpty) {
          stateByQuestion[qid] = row;
        }
      }

      final localDb = SyncEngine.maybeLocalDb;
      if (localDb != null) {
        try {
          final localRows = await localDb.db.query(
            LocalTable.questionLearningStates,
            where:
                'learner_id = ? AND question_supabase_id IS NOT NULL AND IFNULL(deleted, 0) = 0',
            whereArgs: [learnerId],
          );
          for (final r in localRows) {
            final dirty = r['dirty'] == 1 || r['dirty'] == true;
            if (!dirty) continue;
            final qid = r['question_supabase_id']?.toString();
            if (qid == null || qid.isEmpty) continue;
            stateByQuestion[qid] = _localQuestionLearningRowToUiState(r);
          }
        } catch (e, st) {
          if (kDebugMode) {
            debugPrint('ReviewMode: ローカル四択状態マージ失敗: $e\n$st');
          }
        }
      }

      final reviewIds = <String>[];
      for (final e in stateByQuestion.entries) {
        if (KnowledgeLearnerMemStatus.triForMcqItem(e.value) ==
            KnowledgePracticeTriState.incorrectOrNeedsWork) {
          reviewIds.add(e.key);
        }
      }

      if (reviewIds.isEmpty) {
        if (mounted) setState(() => _wrongQuestionIds = []);
        return;
      }

      final questionRows = await _client
          .from('questions')
          .select('id')
          .eq('question_type', 'multiple_choice')
          .inFilter('id', reviewIds);

      final validIds = (questionRows as List)
          .map((r) => (r as Map<String, dynamic>)['id']?.toString())
          .where((id) => id != null && id.isNotEmpty)
          .cast<String>()
          .toList();

      if (mounted) setState(() => _wrongQuestionIds = validIds);
    } catch (e, st) {
      if (kDebugMode) debugPrint('ReviewMode: 四択要復習取得失敗: $e\n$st');
      rethrow;
    }
  }

  /// `english_examples` の全行を教材順で返す。テーブル欠如時は []。
  Future<List<Map<String, dynamic>>> _fetchEnglishExampleRows() async {
    try {
      final rows = await _client
          .from('english_examples')
          .select(
            'id, knowledge_id, front_ja, back_en, explanation, supplement, prompt_supplement, display_order, created_at, '
            'knowledge:knowledge_id(id, content, unit, display_order, created_at)',
          )
          .order('display_order', ascending: true)
          .order('created_at', ascending: true);
      final exampleRows = List<Map<String, dynamic>>.from(rows);
      sortEnglishExampleRowsLikeKnowledgeList(exampleRows);
      return exampleRows;
    } on PostgrestException catch (e) {
      final missingTable =
          e.code == 'PGRST205' && e.message.contains('public.english_examples');
      if (!missingTable) rethrow;
      return [];
    }
  }

  /// 例文読み上げ・英作文の要復習を、例文一覧1回取得でまとめて計算する。
  Future<void> _loadExampleDerivedReviews() async {
    final learnerId = _learnerId;
    if (learnerId == null) {
      if (mounted) {
        setState(() {
          _wrongExamples = [];
          _exampleStates = {};
          _wrongCompositionExamples = [];
        });
      }
      return;
    }

    try {
      final exampleRows = await _fetchEnglishExampleRows();
      if (!mounted) return;

      if (exampleRows.isEmpty) {
        setState(() {
          _wrongExamples = [];
          _exampleStates = {};
          _wrongCompositionExamples = [];
        });
        return;
      }

      final exampleIds = exampleRows
          .map((e) => e['id']?.toString())
          .where((id) => id != null && id.isNotEmpty)
          .cast<String>()
          .toList();

      await Future.wait([
        _applyReadingReviewAfterFetch(learnerId, exampleRows, exampleIds),
        _applyCompositionReviewAfterFetch(learnerId, exampleRows, exampleIds),
      ]);
    } catch (e, st) {
      if (kDebugMode) debugPrint('ReviewMode: 例文系要復習取得失敗: $e\n$st');
      rethrow;
    }
  }

  /// 例文読み上げ: hybrid 状態で [KnowledgeLearnerMemStatus.triForExampleItem]。
  Future<void> _applyReadingReviewAfterFetch(
    String learnerId,
    List<Map<String, dynamic>> exampleRows,
    List<String> exampleIds,
  ) async {
    final mergedStates = await EnglishExampleStateSync.fetchLearningStatesHybrid(
      client: _client,
      learnerId: learnerId,
      exampleIds: exampleIds,
      localDb: SyncEngine.maybeLocalDb,
    );

    final wrongExamples = <EnglishExample>[];
    final stateMap = <String, Map<String, dynamic>>{};
    for (final row in exampleRows) {
      final id = row['id']?.toString();
      if (id == null || id.isEmpty) continue;
      final state = mergedStates[id];
      if (KnowledgeLearnerMemStatus.triForExampleItem(state) !=
          KnowledgePracticeTriState.incorrectOrNeedsWork) {
        continue;
      }
      wrongExamples.add(EnglishExample.fromRow(Map<String, dynamic>.from(row)));
      if (state != null) stateMap[id] = state;
    }

    if (mounted) {
      setState(() {
        _wrongExamples = wrongExamples;
        _exampleStates = stateMap;
      });
    }
  }

  /// 英作文: [KnowledgeLearnerMemStatus.triForCompositionItem]（学習状況の赤タイルと同じ）。
  Future<void> _applyCompositionReviewAfterFetch(
    String learnerId,
    List<Map<String, dynamic>> exampleRows,
    List<String> exampleIds,
  ) async {
    final mergedStates = await EnglishExampleStateSync.fetchCompositionStatesHybrid(
      client: _client,
      learnerId: learnerId,
      exampleIds: exampleIds,
      localDb: SyncEngine.maybeLocalDb,
    );

    final wrong = <EnglishExample>[];
    for (final row in exampleRows) {
      final id = row['id']?.toString();
      if (id == null || id.isEmpty) continue;
      final state = mergedStates[id];
      if (KnowledgeLearnerMemStatus.triForCompositionItem(state) !=
          KnowledgePracticeTriState.incorrectOrNeedsWork) {
        continue;
      }
      wrong.add(EnglishExample.fromRow(Map<String, dynamic>.from(row)));
    }

    if (mounted) {
      setState(() => _wrongCompositionExamples = wrong);
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

  Future<void> _startCompositionReview() async {
    if (_wrongCompositionExamples.isEmpty) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => EnglishExampleCompositionScreen(
          examples: List<EnglishExample>.from(_wrongCompositionExamples),
          subjectName: '復習モード',
          sessionDescriptor: '復習モード',
        ),
      ),
    );
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('復習'),
        actions: [
          const ForceSyncIconButton(),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '設定',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const SettingsScreen(),
                ),
              );
            },
          ),
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

    final bothEmpty = _wrongQuestionIds.isEmpty &&
        _wrongExamples.isEmpty &&
        _wrongCompositionExamples.isEmpty;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
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
                    '今のところ復習対象はありません',
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
            const SizedBox(height: 16),
            _ReviewCard(
              icon: Icons.edit_note_outlined,
              title: '英作文',
              count: _wrongCompositionExamples.length,
              onStart: _wrongCompositionExamples.isEmpty
                  ? null
                  : _startCompositionReview,
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
                    hasItems ? '復習対象: $count 件' : '復習対象なし',
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
