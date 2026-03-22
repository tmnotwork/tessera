import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app_route_observer.dart';
import '../sync/ensure_synced_for_local_read.dart';
import 'question_solve_screen.dart';

class FourChoiceProgressScreen extends StatefulWidget {
  const FourChoiceProgressScreen({super.key});

  @override
  State<FourChoiceProgressScreen> createState() => _FourChoiceProgressScreenState();
}

enum _TileStatus { unseen, notRemembered, remembered }

class _QuestionTileItem {
  const _QuestionTileItem({
    required this.questionId,
    required this.status,
    required this.createdAt,
  });

  final String questionId;
  final _TileStatus status;
  final String createdAt;
}

class _FourChoiceProgressScreenState extends State<FourChoiceProgressScreen> with RouteAware, WidgetsBindingObserver {
  bool _loading = true;
  String? _error;
  Map<String, List<_QuestionTileItem>> _groupedTiles = {};
  bool _routeSubscribed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_routeSubscribed) {
      appRouteObserver.unsubscribe(this);
    }
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_routeSubscribed) {
      final route = ModalRoute.of(context);
      if (route is PageRoute<dynamic>) {
        appRouteObserver.subscribe(this, route);
        _routeSubscribed = true;
      }
    }
  }

  @override
  void didPopNext() {
    _load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ensureSyncedForLocalRead();
      if (!mounted) return;
      final client = Supabase.instance.client;
      final rows = await client
          .from('questions')
          .select('id, knowledge_id, created_at')
          .eq('question_type', 'multiple_choice')
          .order('created_at', ascending: true);
      final questionRows = List<Map<String, dynamic>>.from(rows);

      final userId = client.auth.currentUser?.id;
      final stateByQuestion = <String, Map<String, dynamic>>{};
      if (userId != null) {
        try {
          final stateRows = await client
              .from('question_learning_states')
              .select('question_id, retrievability, success_streak, lapse_count, reviewed_count, last_is_correct, next_review_at')
              .eq('learner_id', userId);
          for (final raw in stateRows as List) {
            final row = raw as Map<String, dynamic>;
            final qid = row['question_id']?.toString();
            if (qid != null && qid.isNotEmpty) {
              stateByQuestion[qid] = row;
            }
          }
        } catch (e, st) {
          if (kDebugMode) {
            debugPrint('FourChoiceProgress: question_learning_states 取得失敗: $e\n$st');
          }
          if (mounted) {
            setState(() => _error = '学習状況の取得に失敗しました。ログイン状態と DB（マイグレーション）を確認してください。\n$e');
          }
        }
      }

      final knowledgeIds = questionRows
          .map((r) => r['knowledge_id']?.toString())
          .where((id) => id != null && id.isNotEmpty)
          .cast<String>()
          .toSet()
          .toList();

      final knowledgeNameById = <String, String>{};
      if (knowledgeIds.isNotEmpty) {
        try {
          final knowledgeRows = await client
              .from('knowledge')
              .select('id, unit, content')
              .inFilter('id', knowledgeIds);
          for (final raw in knowledgeRows as List) {
            final row = raw as Map<String, dynamic>;
            final id = row['id']?.toString();
            if (id == null || id.isEmpty) continue;
            final unit = row['unit']?.toString().trim();
            final title = row['content']?.toString().trim();
            knowledgeNameById[id] = (unit != null && unit.isNotEmpty)
                ? unit
                : ((title != null && title.isNotEmpty) ? title : 'その他');
          }
        } catch (_) {}
      }

      final grouped = <String, List<_QuestionTileItem>>{};
      for (final q in questionRows) {
        final qid = q['id']?.toString();
        if (qid == null || qid.isEmpty) continue;
        final knowledgeId = q['knowledge_id']?.toString();
        final unit = knowledgeId != null && knowledgeNameById.containsKey(knowledgeId)
            ? knowledgeNameById[knowledgeId]!
            : 'その他';
        final state = stateByQuestion[qid];
        grouped.putIfAbsent(unit, () => []).add(
              _QuestionTileItem(
                questionId: qid,
                status: _tileStatusFromState(state),
                createdAt: q['created_at']?.toString() ?? '',
              ),
            );
      }

      final sortedGrouped = <String, List<_QuestionTileItem>>{};
      final keys = grouped.keys.toList()..sort();
      for (final k in keys) {
        final items = grouped[k]!;
        items.sort((a, b) => a.createdAt.compareTo(b.createdAt));
        sortedGrouped[k] = items;
      }

      if (mounted) {
        setState(() {
          _groupedTiles = sortedGrouped;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  _TileStatus _tileStatusFromState(Map<String, dynamic>? state) {
    if (state == null) return _TileStatus.unseen;
    final lastCorrect = state['last_is_correct'] == true;
    if (!lastCorrect) return _TileStatus.notRemembered;

    final reviewed = (state['reviewed_count'] as num?)?.toInt() ?? 0;
    final lapse = (state['lapse_count'] as num?)?.toInt() ?? 0;
    final isInitialKnown = reviewed <= 1 && lapse == 0;
    if (isInitialKnown) return _TileStatus.remembered;

    final nextReviewRaw = state['next_review_at']?.toString();
    if (nextReviewRaw == null || nextReviewRaw.isEmpty) return _TileStatus.remembered;
    DateTime? nextReviewAt;
    try {
      nextReviewAt = DateTime.parse(nextReviewRaw).toUtc();
    } catch (_) {
      nextReviewAt = null;
    }
    if (nextReviewAt == null) return _TileStatus.remembered;
    final now = DateTime.now().toUtc();
    return now.isAfter(nextReviewAt) ? _TileStatus.notRemembered : _TileStatus.remembered;
  }

  Color _tileColor(BuildContext context, _TileStatus status) {
    final scheme = Theme.of(context).colorScheme;
    switch (status) {
      case _TileStatus.remembered:
        return Colors.green.shade300;
      case _TileStatus.notRemembered:
        return Colors.red.shade300;
      case _TileStatus.unseen:
        return scheme.surfaceContainerHighest;
    }
  }

  static const double _tileExtent = 24;

  /// チャプター名を書記素ごとに [_tileExtent] 四方のタイルに分割（隙間なし）。
  /// 進捗マス（明るい地＋枠）と反転させ、地を暗く文字を明るくする。
  Widget _chapterLabel(BuildContext context, String name) {
    if (name.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final textStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w800,
          height: 1.0,
          color: scheme.onInverseSurface,
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Wrap(
        spacing: 0,
        runSpacing: 0,
        children: [
          for (final ch in name.characters)
            Container(
              width: _tileExtent,
              height: _tileExtent,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: scheme.inverseSurface,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: scheme.onInverseSurface.withValues(alpha: 0.35),
                  width: 1.5,
                ),
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(ch, style: textStyle),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('四択問題の学習状況')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('四択問題の学習状況')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
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
        ),
      );
    }

    if (_groupedTiles.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('四択問題の学習状況')),
        body: const Center(child: Text('四択問題がありません')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('四択問題の学習状況'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
            tooltip: '再読み込み',
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 0,
          runSpacing: 0,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final entry in _groupedTiles.entries) ...[
              _chapterLabel(context, entry.key),
              for (final item in entry.value)
                InkWell(
                  onTap: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) => QuestionSolveScreen(
                          questionIds: [item.questionId],
                          knowledgeTitle: entry.key,
                          isLearnerMode: true,
                        ),
                      ),
                    );
                    if (mounted) _load();
                  },
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    width: _tileExtent,
                    height: _tileExtent,
                    decoration: BoxDecoration(
                      color: _tileColor(context, item.status),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outline,
                        width: 1.5,
                      ),
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
