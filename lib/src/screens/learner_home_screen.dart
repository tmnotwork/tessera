import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app_route_observer.dart';
import '../app_scope.dart';
import '../database/local_database.dart';
import '../sync/ensure_synced_for_local_read.dart';
import '../widgets/force_sync_icon_button.dart';
import 'english_example_list_screen.dart';
import 'four_choice_progress_screen.dart';
import 'knowledge_list_screen.dart';
import 'memorization_list_screen.dart';
import 'question_solve_screen.dart';
import 'settings_screen.dart';

/// 学習者向けホーム画面
/// 知識を学ぶ / 四択問題を解く / 暗記カード の入口
class LearnerHomeScreen extends StatefulWidget {
  const LearnerHomeScreen({
    super.key,
    this.localDatabase,
    this.onOpenManage,
    this.embedInDesktopMobileFrame = false,
  });

  /// 非 Web で教材データをローカルから読むために渡す（知識一覧など）。
  final LocalDatabase? localDatabase;

  /// 教材管理（編集）画面へ遷移するときに呼ぶ。未指定の場合は何もしない。
  final VoidCallback? onOpenManage;

  /// PC 向け「スマホ幅」タブ用。true のとき学習画面を狭幅フレーム内に収める。
  final bool embedInDesktopMobileFrame;

  @override
  State<LearnerHomeScreen> createState() => _LearnerHomeScreenState();
}

class _LearnerHomeScreenState extends State<LearnerHomeScreen> {
  static const double _mobilePreviewWidth = 390;

  /// デスクトップ「スマホ幅」プレビュー時のみ。ホームの [State.context] はこの Navigator より上にあるため、
  /// push は [Navigator.of] ではなくこのキー経由で行う。
  final GlobalKey<NavigatorState> _mobilePreviewNavKey = GlobalKey<NavigatorState>();

  List<Map<String, dynamic>> _subjects = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    // ログイン直後のセッション確実反映後に取得する（教師タブと同様）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fetchSubjects();
    });
  }

  Future<void> _fetchSubjects() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ensureSyncedForLocalRead();
      if (!mounted) return;
      final client = Supabase.instance.client;
      final rows = await client.from('subjects').select().order('display_order');
      if (mounted) {
        setState(() {
          _subjects = List<Map<String, dynamic>>.from(rows);
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 学習ホームからの遷移。スマホ幅タブではフレーム内 Navigator に積む。
  Future<T?> _learnerPush<T extends Object?>(Route<T> route) {
    if (widget.embedInDesktopMobileFrame) {
      final nav = _mobilePreviewNavKey.currentState;
      if (nav != null) {
        return nav.push(route);
      }
    }
    return Navigator.of(context).push(route);
  }

  void _openKnowledgePicker() {
    _learnerPush(
      MaterialPageRoute(
        builder: (context) => _LearnerSubjectPicker(
          subjects: _subjects,
          title: '知識を学ぶ',
          mode: _LearnerPickMode.knowledge,
        ),
      ),
    );
  }

  void _openFourChoiceSolve() {
    _learnerPush(
      MaterialPageRoute(
        builder: (context) => const LearnerFourChoiceSolveScreen(),
      ),
    );
  }

  void _openFourChoiceProgress() {
    _learnerPush(
      MaterialPageRoute(
        builder: (context) => const FourChoiceProgressScreen(),
      ),
    );
  }

  void _openMemorizationPicker() {
    _learnerPush(
      MaterialPageRoute(
        builder: (context) => _LearnerSubjectPicker(
          subjects: _subjects,
          title: '暗記カード',
          mode: _LearnerPickMode.memorization,
          localDatabase: widget.localDatabase,
        ),
      ),
    );
  }

  void _openEnglishExamples() {
    _learnerPush(
      MaterialPageRoute(
        builder: (context) => const EnglishExampleListScreen(
          isLearnerMode: true,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final inner = Scaffold(
      appBar: AppBar(
        title: const Text('学習'),
        actions: [
          const ForceSyncIconButton(),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () {
              _learnerPush(
                MaterialPageRoute(
                  builder: (context) => const SettingsScreen(),
                ),
              );
            },
            tooltip: '設定',
          ),
          if (widget.onOpenManage != null)
            TextButton.icon(
              onPressed: widget.onOpenManage,
              icon: const Icon(Icons.edit_note, size: 20),
              label: const Text('教材管理'),
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _fetchSubjects,
            tooltip: '再読み込み',
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'ログアウト',
            onPressed: () async {
              await appAuthNotifier.logout();
            },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(_error!, style: Theme.of(context).textTheme.bodyMedium, textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: _fetchSubjects,
                          icon: const Icon(Icons.refresh),
                          label: const Text('再試行'),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _MenuCard(
                      icon: Icons.menu_book,
                      title: '知識を学ぶ',
                      subtitle: '解説付きの知識カードを読む',
                      onTap: _openKnowledgePicker,
                    ),
                    const SizedBox(height: 12),
                    _MenuCard(
                      icon: Icons.quiz,
                      title: '四択問題を解く',
                      subtitle: '四択クイズに挑戦する',
                      onTap: _openFourChoiceSolve,
                    ),
                    const SizedBox(height: 12),
                    _MenuCard(
                      icon: Icons.grid_view,
                      title: '四択の暗記状況',
                      subtitle: '単元ごとの暗記状況を色で確認する',
                      onTap: _openFourChoiceProgress,
                    ),
                    const SizedBox(height: 12),
                    _MenuCard(
                      icon: Icons.style,
                      title: '暗記カード',
                      subtitle: '表・裏の暗記カードで覚える',
                      onTap: _openMemorizationPicker,
                    ),
                    const SizedBox(height: 12),
                    _MenuCard(
                      icon: Icons.translate,
                      title: '英語例文',
                      subtitle: '日本語から英語を思い出す（解説・補足付き）',
                      onTap: _openEnglishExamples,
                    ),
                  ],
                ),
    );

    if (!widget.embedInDesktopMobileFrame) {
      return inner;
    }

    return Scaffold(
      backgroundColor: scheme.surfaceContainerLow,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final maxH = constraints.maxHeight - 16;
            return Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Container(
                  width: _mobilePreviewWidth,
                  height: maxH.clamp(0, double.infinity),
                  decoration: BoxDecoration(
                    color: theme.scaffoldBackgroundColor,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: scheme.outline.withValues(alpha: 0.35),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.12),
                        blurRadius: 20,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Navigator(
                    key: _mobilePreviewNavKey,
                    observers: [appRouteObserver],
                    onGenerateInitialRoutes: (navigator, initialRoute) {
                      return [
                        MaterialPageRoute<void>(
                          settings: const RouteSettings(name: '/'),
                          builder: (context) => inner,
                        ),
                      ];
                    },
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

enum _LearnerPickMode { knowledge, memorization }

class _LearnerSubjectPicker extends StatelessWidget {
  const _LearnerSubjectPicker({
    required this.subjects,
    required this.title,
    required this.mode,
    this.localDatabase,
  });

  final List<Map<String, dynamic>> subjects;
  final String title;
  final _LearnerPickMode mode;
  final LocalDatabase? localDatabase;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: subjects.isEmpty
          ? const Center(child: Text('科目がありません'))
          : ListView.separated(
              itemCount: subjects.length,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final s = subjects[index];
                final subjectId = s['id'] as String?;
                final subjectName = s['name']?.toString() ?? '科目';
                if (subjectId == null) return const SizedBox.shrink();
                return ListTile(
                  title: Text(subjectName),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    if (mode == _LearnerPickMode.knowledge) {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) => KnowledgeListScreen(
                            subjectId: subjectId,
                            subjectName: subjectName,
                            localDatabase: localDatabase,
                            isLearnerMode: true,
                          ),
                        ),
                      );
                    } else if (mode == _LearnerPickMode.memorization) {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) => MemorizationListScreen(
                            subjectId: subjectId,
                            subjectName: subjectName,
                          ),
                        ),
                      );
                    }
                  },
                );
              },
            ),
    );
  }
}

/// 学習者向け：四択問題を解く画面（問題ID一覧 → 解く）
class LearnerFourChoiceSolveScreen extends StatefulWidget {
  const LearnerFourChoiceSolveScreen({super.key});

  @override
  State<LearnerFourChoiceSolveScreen> createState() => _LearnerFourChoiceSolveScreenState();
}

class _LearnerFourChoiceSolveScreenState extends State<LearnerFourChoiceSolveScreen> with RouteAware, WidgetsBindingObserver {
  List<String> _questionIds = [];
  Map<String, List<_QuestionTileItem>> _groupedTiles = {};
  int _dueCount = 0;
  bool _loading = true;
  String? _error;
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
      final allRows = await client
          .from('questions')
          .select('id, knowledge_id')
          .eq('question_type', 'multiple_choice')
          .order('created_at', ascending: false);
      final allQuestionRows = List<Map<String, dynamic>>.from(allRows);
      final allQuestionIds = allQuestionRows
          .map((r) => r['id']?.toString())
          .where((id) => id != null && id.isNotEmpty)
          .cast<String>()
          .toList();

      final userId = client.auth.currentUser?.id;
      List<String> dueQuestionIds = [];
      final stateByQuestion = <String, Map<String, dynamic>>{};
      if (userId != null) {
        try {
          final nowIso = DateTime.now().toUtc().toIso8601String();
          final dueRows = await client
              .from('question_learning_states')
              .select('question_id, next_review_at')
              .eq('learner_id', userId)
              .lte('next_review_at', nowIso)
              .order('next_review_at', ascending: true);
          dueQuestionIds = (dueRows as List)
              .map((r) => (r as Map<String, dynamic>)['question_id']?.toString())
              .where((id) => id != null && id.isNotEmpty)
              .cast<String>()
              .toList();

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
            debugPrint('LearnerFourChoiceSolve: question_learning_states 取得失敗: $e\n$st');
          }
          dueQuestionIds = [];
          if (mounted) {
            setState(() => _error = '学習状況の取得に失敗しました。同じアカウントでログインしているか、Supabase のマイグレーションを確認してください。\n$e');
          }
        }
      }

      final knowledgeIds = allQuestionRows
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

      final allSet = allQuestionIds.toSet();
      final dueUnique = dueQuestionIds.where(allSet.contains).toList();
      final dueSet = dueUnique.toSet();
      final unseenOrNotDue = allQuestionIds.where((id) => !dueSet.contains(id)).toList();
      final ordered = [...dueUnique, ...unseenOrNotDue];
      final grouped = <String, List<_QuestionTileItem>>{};
      for (final q in allQuestionRows) {
        final qid = q['id']?.toString();
        if (qid == null || qid.isEmpty) continue;
        final knowledgeId = q['knowledge_id']?.toString();
        final unit = knowledgeId != null && knowledgeNameById.containsKey(knowledgeId)
            ? knowledgeNameById[knowledgeId]!
            : 'その他';
        final state = stateByQuestion[qid];
        final status = _tileStatusFromState(state);
        grouped.putIfAbsent(unit, () => []).add(
              _QuestionTileItem(
                questionId: qid,
                status: status,
              ),
            );
      }
      final sortedGrouped = <String, List<_QuestionTileItem>>{};
      final keys = grouped.keys.toList()..sort();
      for (final k in keys) {
        sortedGrouped[k] = grouped[k]!;
      }

      if (mounted) {
        setState(() {
          _questionIds = ordered;
          _dueCount = dueUnique.length;
          _groupedTiles = sortedGrouped;
          // _error は先頭で null に済ませる。学習状態取得失敗時は inner catch でだけセットし、ここで消さない。
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _startSolve() {
    if (_questionIds.isEmpty) return;
    Navigator.of(context)
        .push(
      MaterialPageRoute(
        builder: (context) => QuestionSolveScreen(
          questionIds: _questionIds,
          knowledgeTitle: '四択問題',
          isLearnerMode: true,
        ),
      ),
    )
        .then((_) {
      if (mounted) _load();
    });
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
        // surface 単色だと背景と同化するため、わずかに浮かせる
        return scheme.surfaceContainerHighest;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('四択問題を解く'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
            tooltip: '再読み込み',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(_error!, style: Theme.of(context).textTheme.bodyMedium, textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: _load,
                          icon: const Icon(Icons.refresh),
                          label: const Text('再試行'),
                        ),
                      ],
                    ),
                  ),
                )
              : _questionIds.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.quiz, size: 64, color: Theme.of(context).colorScheme.outline),
                          const SizedBox(height: 16),
                          Text(
                            '四択問題がまだありません',
                            style: Theme.of(context).textTheme.bodyLarge,
                          ),
                        ],
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        Text(
                          '${_questionIds.length} 問（復習期限: $_dueCount 問）',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: _startSolve,
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('全問題を解く'),
                        ),
                        const SizedBox(height: 16),
                        ..._groupedTiles.entries.map((entry) {
                          final unit = entry.key;
                          final tiles = entry.value;
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 20),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  unit,
                                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                        fontWeight: FontWeight.w700,
                                      ),
                                ),
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 2,
                                  runSpacing: 2,
                                  children: tiles.map((item) {
                                    return InkWell(
                                      onTap: () async {
                                        await Navigator.of(context).push(
                                          MaterialPageRoute(
                                            builder: (context) => QuestionSolveScreen(
                                              questionIds: [item.questionId],
                                              knowledgeTitle: unit,
                                              isLearnerMode: true,
                                            ),
                                          ),
                                        );
                                        if (mounted) _load();
                                      },
                                      borderRadius: BorderRadius.circular(6),
                                      child: Container(
                                        width: 28,
                                        height: 28,
                                        decoration: BoxDecoration(
                                          color: _tileColor(context, item.status),
                                          borderRadius: BorderRadius.circular(6),
                                          border: Border.all(
                                            color: Theme.of(context).colorScheme.outline,
                                            width: 1.5,
                                          ),
                                        ),
                                      ),
                                    );
                                  }).toList(),
                                ),
                              ],
                            ),
                          );
                        }),
                      ],
                    ),
    );
  }
}

enum _TileStatus { unseen, notRemembered, remembered }

class _QuestionTileItem {
  const _QuestionTileItem({
    required this.questionId,
    required this.status,
  });

  final String questionId;
  final _TileStatus status;
}

class _MenuCard extends StatelessWidget {
  const _MenuCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      elevation: 0,
      shadowColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outline, width: 1.5),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: scheme.outline.withValues(alpha: 0.35)),
                ),
                child: Icon(icon, size: 28, color: Theme.of(context).colorScheme.onPrimaryContainer),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: Theme.of(context).colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
