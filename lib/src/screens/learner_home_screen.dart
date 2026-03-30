import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app_route_observer.dart';
import '../app_scope.dart';
import '../database/local_database.dart';
import '../repositories/subject_repository.dart';
import '../sync/ensure_synced_for_local_read.dart';
import '../widgets/force_sync_icon_button.dart';
import 'english_example_list_screen.dart';
import 'learner_learning_status_menu_screen.dart';
import 'knowledge_list_screen.dart';
import 'review_mode_screen.dart';
import 'question_solve_screen.dart';
import 'settings_screen.dart';

/// 学習者向けホーム画面
/// 知識を学ぶ / 四択・例文などの入口（暗記カードメニューは一時非表示）
class LearnerHomeScreen extends StatefulWidget {
  const LearnerHomeScreen({
    super.key,
    this.localDatabase,
    this.embedInDesktopMobileFrame = false,
  });

  /// 非 Web で教材データをローカルから読むために渡す（知識一覧など）。
  final LocalDatabase? localDatabase;

  /// PC 向け「スマホ幅」タブ用。true のとき学習画面を狭幅フレーム内に収める。
  final bool embedInDesktopMobileFrame;

  @override
  State<LearnerHomeScreen> createState() => _LearnerHomeScreenState();
}

class _LearnerHomeScreenState extends State<LearnerHomeScreen> {
  static const double _mobilePreviewWidth = 390;

  /// デスクトップ「スマホ幅」プレビュー時のみ。ホームの [State.context] はこの Navigator より上にあるため、
  /// push は [Navigator.of] ではなくこのキー経由で行う。
  final GlobalKey<NavigatorState> _mobilePreviewNavKey =
      GlobalKey<NavigatorState>();

  List<Map<String, dynamic>> _subjects = [];
  bool _loading = true;
  String? _error;
  bool _isFetchingSubjects = false;

  @override
  void initState() {
    super.initState();
    // ログイン直後のセッション確実反映後に取得する（教師タブと同様）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fetchSubjects();
    });
  }

  Future<void> _fetchSubjects() async {
    if (_isFetchingSubjects) return;
    _isFetchingSubjects = true;
    if (mounted) {
      setState(() {
        _loading = _subjects.isEmpty;
        _error = null;
      });
    }
    try {
      final rows = await _loadSubjectsPrimary();
      if (mounted) {
        setState(() {
          _subjects = rows;
          _error = null;
          _loading = false;
        });
      }
      unawaited(() async {
        await triggerBackgroundSyncWithThrottle();
        final freshRows = await _loadSubjectsPrimary();
        if (!mounted) return;
        if (!_sameSubjects(_subjects, freshRows)) {
          setState(() => _subjects = freshRows);
        }
      }());
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    } finally {
      _isFetchingSubjects = false;
    }
  }

  Future<List<Map<String, dynamic>>> _loadSubjectsPrimary() async {
    if (widget.localDatabase != null) {
      final repo = createSubjectRepository(widget.localDatabase);
      return repo.getSubjectsOrderByDisplayOrder();
    }
    final rows = await Supabase.instance.client
        .from('subjects')
        .select()
        .order('display_order');
    return List<Map<String, dynamic>>.from(rows);
  }

  bool _sameSubjects(
      List<Map<String, dynamic>> a, List<Map<String, dynamic>> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i]['id']?.toString() != b[i]['id']?.toString()) return false;
      if (a[i]['name']?.toString() != b[i]['name']?.toString()) return false;
      if (a[i]['display_order'] != b[i]['display_order']) return false;
    }
    return true;
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
          localDatabase: widget.localDatabase,
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

  void _openReviewMode() {
    _learnerPush(
      MaterialPageRoute<void>(
        builder: (context) => const ReviewModeScreen(),
      ),
    );
  }

  void _openLearningStatusMenu() {
    _learnerPush(
      MaterialPageRoute(
        builder: (context) => LearnerLearningStatusMenuScreen(
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
          readAloudMenuOnly: true,
        ),
      ),
    );
  }

  void _openEnglishComposition() {
    _learnerPush(
      MaterialPageRoute(
        builder: (context) => const EnglishExampleListScreen(
          isLearnerMode: true,
          compositionMenuOnly: true,
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
                MaterialPageRoute(builder: (context) => const SettingsScreen()),
              );
            },
            tooltip: '設定',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _fetchSubjects,
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
                    Text(
                      _error!,
                      style: Theme.of(context).textTheme.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
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
                  icon: Icons.replay,
                  title: '復習モード',
                  subtitle: '不正解の四択・例文読み上げ・英作文をまとめて復習',
                  onTap: _openReviewMode,
                ),
                const SizedBox(height: 12),
                _MenuCard(
                  icon: Icons.insights_outlined,
                  title: '学習状況の確認',
                  onTap: _openLearningStatusMenu,
                ),
                const SizedBox(height: 12),
                _MenuCard(
                  icon: Icons.translate,
                  title: '例文読み上げ',
                  onTap: _openEnglishExamples,
                ),
                const SizedBox(height: 12),
                _MenuCard(
                  icon: Icons.edit_note,
                  title: '英作文出題',
                  subtitle: 'チャプター別に例文を選んで英作文',
                  onTap: _openEnglishComposition,
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
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

class _LearnerSubjectPicker extends StatefulWidget {
  const _LearnerSubjectPicker({
    required this.subjects,
    required this.title,
    this.localDatabase,
  });

  final List<Map<String, dynamic>> subjects;
  final String title;
  final LocalDatabase? localDatabase;

  @override
  State<_LearnerSubjectPicker> createState() => _LearnerSubjectPickerState();
}

class _LearnerSubjectPickerState extends State<_LearnerSubjectPicker> {
  bool _showManageEdit = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      if (await shouldShowLearnerFlowManageShortcut()) {
        setState(() => _showManageEdit = true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          if (_showManageEdit)
            IconButton(
              icon: const Icon(Icons.edit),
              tooltip: '教材を編集',
              onPressed: () => openManageNotifier.openManage?.call(context),
            ),
        ],
      ),
      body: widget.subjects.isEmpty
          ? const Center(child: Text('科目がありません'))
          : ListView.separated(
              itemCount: widget.subjects.length,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final s = widget.subjects[index];
                final subjectId = s['id'] as String?;
                final subjectName = s['name']?.toString() ?? '科目';
                if (subjectId == null) return const SizedBox.shrink();
                return ListTile(
                  title: Text(subjectName),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) => KnowledgeListScreen(
                          subjectId: subjectId,
                          subjectName: subjectName,
                          localDatabase: widget.localDatabase,
                          isLearnerMode: true,
                        ),
                      ),
                    );
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
  State<LearnerFourChoiceSolveScreen> createState() =>
      _LearnerFourChoiceSolveScreenState();
}

class _LearnerFourChoiceSolveScreenState
    extends State<LearnerFourChoiceSolveScreen>
    with RouteAware, WidgetsBindingObserver {
  List<String> _questionIds = [];
  Map<String, List<_QuestionTileItem>> _groupedTiles = {};
  final Set<String> _expandedChapters = {};
  bool _loading = true;
  String? _error;
  bool _routeSubscribed = false;
  bool _showManageEdit = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      if (await shouldShowLearnerFlowManageShortcut()) {
        setState(() => _showManageEdit = true);
      }
    });
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
      await triggerBackgroundSyncWithThrottle();
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
              .map(
                (r) => (r as Map<String, dynamic>)['question_id']?.toString(),
              )
              .where((id) => id != null && id.isNotEmpty)
              .cast<String>()
              .toList();

          final stateRows = await client
              .from('question_learning_states')
              .select(
                'question_id, retrievability, success_streak, lapse_count, reviewed_count, last_is_correct, next_review_at',
              )
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
            debugPrint(
              'LearnerFourChoiceSolve: question_learning_states 取得失敗: $e\n$st',
            );
          }
          dueQuestionIds = [];
          if (mounted) {
            setState(
              () => _error =
                  '学習状況の取得に失敗しました。同じアカウントでログインしているか、Supabase のマイグレーションを確認してください。\n$e',
            );
          }
        }
      }

      final knowledgeIds = allQuestionRows
          .map((r) => r['knowledge_id']?.toString())
          .where((id) => id != null && id.isNotEmpty)
          .cast<String>()
          .toSet()
          .toList();
      final knowledgeMetaById = <String, _KnowledgeMeta>{};
      if (knowledgeIds.isNotEmpty) {
        try {
          final knowledgeRows = await client
              .from('knowledge')
              .select('id, unit, content, display_order')
              .inFilter('id', knowledgeIds);
          for (final raw in knowledgeRows as List) {
            final row = raw as Map<String, dynamic>;
            final id = row['id']?.toString();
            if (id == null || id.isEmpty) continue;
            final unit = row['unit']?.toString().trim();
            final chapterKey = (unit != null && unit.isNotEmpty)
                ? unit
                : '（単元なし）';
            final content = row['content']?.toString().trim();
            final cardTitle = (content != null && content.isNotEmpty)
                ? content
                : '（無題）';
            final displayOrder = (row['display_order'] as num?)?.toInt();
            knowledgeMetaById[id] = _KnowledgeMeta(
              chapterKey: chapterKey,
              cardTitle: cardTitle,
              displayOrder: displayOrder,
            );
          }
        } catch (_) {}
      }

      final allSet = allQuestionIds.toSet();
      final dueUnique = dueQuestionIds.where(allSet.contains).toList();
      final dueSet = dueUnique.toSet();
      final unseenOrNotDue = allQuestionIds
          .where((id) => !dueSet.contains(id))
          .toList();
      final ordered = [...dueUnique, ...unseenOrNotDue];
      final grouped = <String, List<_QuestionTileItem>>{};
      for (final q in allQuestionRows) {
        final qid = q['id']?.toString();
        if (qid == null || qid.isEmpty) continue;
        final knowledgeId = q['knowledge_id']?.toString();
        final meta =
            (knowledgeId != null && knowledgeMetaById.containsKey(knowledgeId))
            ? knowledgeMetaById[knowledgeId]!
            : const _KnowledgeMeta(
                chapterKey: '（単元なし）',
                cardTitle: '（紐づけなし）',
                displayOrder: null,
              );
        final state = stateByQuestion[qid];
        final status = _tileStatusFromState(state);
        grouped
            .putIfAbsent(meta.chapterKey, () => [])
            .add(
              _QuestionTileItem(
                questionId: qid,
                status: status,
                cardTitle: meta.cardTitle,
                displayOrder: meta.displayOrder,
              ),
            );
      }
      for (final list in grouped.values) {
        list.sort((a, b) {
          final ao = a.displayOrder ?? 1 << 30;
          final bo = b.displayOrder ?? 1 << 30;
          if (ao != bo) return ao.compareTo(bo);
          return a.cardTitle.compareTo(b.cardTitle);
        });
      }
      int chapterOrder(String chapter) {
        final list = grouped[chapter];
        if (list == null || list.isEmpty) return 1 << 30;
        var m = 1 << 30;
        for (final item in list) {
          final o = item.displayOrder ?? (1 << 29);
          if (o < m) m = o;
        }
        return m;
      }

      final sortedGrouped = <String, List<_QuestionTileItem>>{};
      final keys = grouped.keys.toList()
        ..sort((a, b) {
          final c = chapterOrder(a).compareTo(chapterOrder(b));
          if (c != 0) return c;
          return a.compareTo(b);
        });
      for (final k in keys) {
        sortedGrouped[k] = grouped[k]!;
      }

      if (mounted) {
        setState(() {
          _questionIds = ordered;
          _groupedTiles = sortedGrouped;
          _expandedChapters.removeWhere((k) => !sortedGrouped.containsKey(k));
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 「覚えている」以外（未挑戦・要復習＝未回答・不正解／復習期限）を [_questionIds] の並びのまま返す。
  List<String> _orderedQuestionIdsNeedingPractice() {
    final need = <String>{};
    for (final list in _groupedTiles.values) {
      for (final item in list) {
        if (item.status != _TileStatus.remembered) {
          need.add(item.questionId);
        }
      }
    }
    return _questionIds.where((id) => need.contains(id)).toList();
  }

  void _startNeedsPracticeSolve() {
    final ids = _orderedQuestionIdsNeedingPractice();
    if (ids.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('未回答・不正解の問題はありません')),
      );
      return;
    }
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (context) => QuestionSolveScreen(
              questionIds: ids,
              knowledgeTitle: '四択問題（未回答・不正解）',
              isLearnerMode: true,
            ),
          ),
        )
        .then((_) {
          if (mounted) _load();
        });
  }

  void _startChapterSolve(String chapterKey) {
    final tiles = _groupedTiles[chapterKey];
    if (tiles == null || tiles.isEmpty) return;
    final ids = tiles.map((t) => t.questionId).toList();
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (context) => QuestionSolveScreen(
              questionIds: ids,
              knowledgeTitle: chapterKey,
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
    if (nextReviewRaw == null || nextReviewRaw.isEmpty)
      return _TileStatus.remembered;
    DateTime? nextReviewAt;
    try {
      nextReviewAt = DateTime.parse(nextReviewRaw).toUtc();
    } catch (_) {
      nextReviewAt = null;
    }
    if (nextReviewAt == null) return _TileStatus.remembered;
    final now = DateTime.now().toUtc();
    return now.isAfter(nextReviewAt)
        ? _TileStatus.notRemembered
        : _TileStatus.remembered;
  }

  String _statusLabel(_TileStatus status) {
    switch (status) {
      case _TileStatus.unseen:
        return '未挑戦';
      case _TileStatus.remembered:
        return '覚えている';
      case _TileStatus.notRemembered:
        return '要復習';
    }
  }

  /// 一覧ではマーク表示。長押し／ホバーで文言（ツールチップ）。
  Widget _statusMark(BuildContext context, _TileStatus status) {
    final scheme = Theme.of(context).colorScheme;
    final IconData icon;
    final Color color;
    switch (status) {
      case _TileStatus.unseen:
        icon = Icons.radio_button_unchecked;
        color = scheme.outline;
      case _TileStatus.remembered:
        icon = Icons.check_circle;
        color = Colors.green.shade700;
      case _TileStatus.notRemembered:
        icon = Icons.error_outline;
        color = scheme.error;
    }
    return Tooltip(
      message: _statusLabel(status),
      child: Icon(icon, size: 22, color: color),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('四択問題を解く'),
        actions: [
          if (_showManageEdit)
            IconButton(
              icon: const Icon(Icons.edit),
              tooltip: '教材を編集',
              onPressed: () => openManageNotifier.openManage?.call(context),
            ),
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
                    Text(
                      _error!,
                      style: Theme.of(context).textTheme.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
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
                  Icon(
                    Icons.quiz,
                    size: 64,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '四択問題がまだありません',
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(0, 16, 0, 24),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: FilledButton.icon(
                    onPressed: _startNeedsPracticeSolve,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('未回答・不正解の問題を解く'),
                  ),
                ),
                const SizedBox(height: 8),
                ..._groupedTiles.entries.map((entry) {
                  final chapter = entry.key;
                  final tiles = entry.value;
                  final expanded = _expandedChapters.contains(chapter);
                  return Column(
                    key: PageStorageKey<String>('four_choice_chapter_$chapter'),
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              child: InkWell(
                                onTap: () => _startChapterSolve(chapter),
                                borderRadius: BorderRadius.circular(8),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 12,
                                  ),
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      chapter,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleSmall
                                          ?.copyWith(
                                            fontWeight: FontWeight.w600,
                                          ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            IconButton(
                              onPressed: () {
                                setState(() {
                                  if (expanded) {
                                    _expandedChapters.remove(chapter);
                                  } else {
                                    _expandedChapters.add(chapter);
                                  }
                                });
                              },
                              icon: Icon(
                                expanded
                                    ? Icons.expand_less
                                    : Icons.expand_more,
                              ),
                              tooltip: expanded ? '折りたたむ' : '展開する',
                            ),
                          ],
                        ),
                      ),
                      if (expanded)
                        ...tiles.asMap().entries.map((e) {
                          final item = e.value;
                          final listIndex = e.key;
                          final chapterIds =
                              tiles.map((t) => t.questionId).toList();
                          return ListTile(
                            contentPadding: const EdgeInsets.only(
                              left: 24,
                              right: 16,
                            ),
                            title: Text(
                              item.cardTitle,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: _statusMark(context, item.status),
                            onTap: () async {
                              await Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (context) => QuestionSolveScreen(
                                    questionIds: chapterIds,
                                    initialQuestionIndex: listIndex,
                                    knowledgeTitle: chapter,
                                    isLearnerMode: true,
                                  ),
                                ),
                              );
                              if (mounted) _load();
                            },
                          );
                        }),
                      const Divider(height: 1),
                    ],
                  );
                }),
              ],
            ),
    );
  }
}

enum _TileStatus { unseen, notRemembered, remembered }

class _KnowledgeMeta {
  const _KnowledgeMeta({
    required this.chapterKey,
    required this.cardTitle,
    this.displayOrder,
  });

  final String chapterKey;
  final String cardTitle;
  final int? displayOrder;
}

class _QuestionTileItem {
  const _QuestionTileItem({
    required this.questionId,
    required this.status,
    required this.cardTitle,
    this.displayOrder,
  });

  final String questionId;
  final _TileStatus status;
  final String cardTitle;
  final int? displayOrder;
}

class _MenuCard extends StatelessWidget {
  const _MenuCard({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
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
                  border: Border.all(
                    color: scheme.outline.withValues(alpha: 0.35),
                  ),
                ),
                child: Icon(
                  icon,
                  size: 28,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (subtitle != null && subtitle!.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        subtitle!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
