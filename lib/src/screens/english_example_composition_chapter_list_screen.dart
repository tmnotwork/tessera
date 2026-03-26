import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app_scope.dart';
import '../models/english_example.dart';
import '../sync/english_example_state_sync.dart';
import '../sync/sync_engine.dart';
import '../utils/knowledge_learner_mem_status.dart';
import 'english_example_list_screen.dart';
import 'english_example_composition_progress_screen.dart';
import 'english_example_composition_screen.dart';

/// 英作文：1チャプター内の例文一覧から個別出題、「正解以外」一括出題ができる。
class EnglishExampleCompositionChapterListScreen extends StatefulWidget {
  const EnglishExampleCompositionChapterListScreen({
    super.key,
    required this.chapterTitle,
    required this.items,
    this.subjectName,
  });

  final String chapterTitle;
  final List<Map<String, dynamic>> items;
  final String? subjectName;

  @override
  State<EnglishExampleCompositionChapterListScreen> createState() =>
      _EnglishExampleCompositionChapterListScreenState();
}

class _EnglishExampleCompositionChapterListScreenState
    extends State<EnglishExampleCompositionChapterListScreen> {
  final _client = Supabase.instance.client;
  Map<String, Map<String, dynamic>> _compStates = {};
  bool _loading = true;
  bool _showManageEdit = false;

  String? get _learnerId => _client.auth.currentUser?.id;

  /// [english_example_list_screen] の要練習判定と同じ（未回答・直近不正解）。
  static bool _compositionNeedsDrill(Map<String, dynamic>? state) {
    if (state == null) return true;
    final attempts = (state['attempts'] as num?)?.toInt() ?? 0;
    if (attempts <= 0) return true;
    final last = state['last_answer_correct'] as bool?;
    if (last == false) return true;
    return false;
  }

  /// 一覧の並びのまま、正解以外（要練習）だけ。
  List<Map<String, dynamic>> get _itemsNotMasteredInOrder {
    return widget.items.where((item) {
      final id = item['id'] as String?;
      if (id == null) return false;
      return _compositionNeedsDrill(_compStates[id]);
    }).toList();
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadStates());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_refreshManageShortcut());
    });
  }

  Future<void> _refreshManageShortcut() async {
    if (!mounted) return;
    final show = await shouldShowLearnerFlowManageShortcut();
    if (mounted) setState(() => _showManageEdit = show);
  }

  void _openManageEnglishExamples() {
    final cb = openManageNotifier.openManageEnglishExamples;
    if (cb != null) {
      cb(context);
      return;
    }
    Navigator.of(context, rootNavigator: true).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => const EnglishExampleListScreen(),
      ),
    );
  }

  Future<void> _loadStates() async {
    final uid = _learnerId;
    if (uid == null || widget.items.isEmpty) {
      if (mounted) setState(() => _loading = false);
      await _refreshManageShortcut();
      return;
    }
    final ids = widget.items.map((e) => e['id'] as String).toList();
    final m = await EnglishExampleStateSync.fetchCompositionStatesHybrid(
      client: _client,
      learnerId: uid,
      exampleIds: ids,
      localDb: SyncEngine.maybeLocalDb,
    );
    if (!mounted) return;
    setState(() {
      _compStates = m;
      _loading = false;
    });
    await _refreshManageShortcut();
  }

  Future<void> _openComposition(
    List<EnglishExample> examples, {
    int initialIndex = 0,
    String? sessionDescriptor,
  }) async {
    if (examples.isEmpty) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => EnglishExampleCompositionScreen(
          examples: examples,
          initialIndex: initialIndex,
          subjectName: widget.subjectName ?? '英作文出題',
          sessionDescriptor:
              sessionDescriptor ?? '単元「${widget.chapterTitle}」',
        ),
      ),
    );
    if (mounted) await _loadStates();
  }

  /// チャプター内の全例文を渡し、タップした位置から「次の例文」で続きへ進める。
  Future<void> _openFromListIndex(int listIndex) async {
    final examples = widget.items
        .map((e) => EnglishExample.fromRow(Map<String, dynamic>.from(e)))
        .toList();
    await _openComposition(examples, initialIndex: listIndex);
  }

  Future<void> _openNotCorrectOnly() async {
    if (_learnerId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('正解以外への絞り込みはログイン後に利用できます。'),
        ),
      );
      return;
    }
    final rows = _itemsNotMasteredInOrder;
    if (rows.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('この単元に正解以外の例文はありません。')),
      );
      return;
    }
    final examples = rows
        .map((e) => EnglishExample.fromRow(Map<String, dynamic>.from(e)))
        .toList();
    await _openComposition(
      examples,
      sessionDescriptor: '単元「${widget.chapterTitle}」· 正解以外',
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.chapterTitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (_showManageEdit)
            IconButton(
              icon: const Icon(Icons.edit),
              tooltip: '教材を編集',
              onPressed: _openManageEnglishExamples,
            ),
          IconButton(
            icon: const Icon(Icons.insights_outlined),
            tooltip: '学習状況',
            onPressed: _loading
                ? null
                : () {
                    Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (context) =>
                            const EnglishExampleCompositionProgressScreen(),
                      ),
                    );
                  },
          ),
          if (widget.items.isNotEmpty)
            TextButton.icon(
              onPressed: _loading ? null : () => unawaited(_openNotCorrectOnly()),
              icon: const Icon(Icons.filter_alt_outlined),
              label: Text(
                _learnerId != null && !_loading
                    ? '正解以外 (${_itemsNotMasteredInOrder.length})'
                    : '正解以外',
              ),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView.separated(
              itemCount: widget.items.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final item = widget.items[index];
                final frontJa = item['front_ja']?.toString() ?? '';
                final knowledge = item['knowledge'] as Map<String, dynamic>?;
                final knowledgeTitle = knowledge?['content']?.toString();
                final id = item['id'] as String?;

                final subtitle = (knowledgeTitle ?? '').isNotEmpty
                    ? Text(
                        '知識: $knowledgeTitle',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      )
                    : null;

                return ListTile(
                  title: Text(
                    frontJa.isEmpty ? '（日本語なし）' : frontJa,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: subtitle,
                  isThreeLine: subtitle != null,
                  trailing: KnowledgeLearnerMemStatus.compositionPracticeMark(
                    context,
                    isLoggedIn: _learnerId != null,
                    compositionState:
                        id != null ? _compStates[id] : null,
                  ),
                  onTap: () => unawaited(_openFromListIndex(index)),
                );
              },
            ),
    );
  }
}
