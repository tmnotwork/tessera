import 'package:characters/characters.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app_route_observer.dart';
import '../models/english_example.dart';
import '../sync/english_example_state_sync.dart';
import '../sync/ensure_synced_for_local_read.dart';
import '../sync/sync_engine.dart';
import '../utils/english_example_knowledge_order.dart';
import 'english_example_composition_screen.dart';

/// 学習者向け：英作文モードの記録（正誤・試行回数）を単元ごとに色付きタイルで表示する。
class EnglishExampleCompositionProgressScreen extends StatefulWidget {
  const EnglishExampleCompositionProgressScreen({super.key});

  @override
  State<EnglishExampleCompositionProgressScreen> createState() =>
      _EnglishExampleCompositionProgressScreenState();
}

enum _TileStatus { unseen, notRemembered, remembered }

class _ExampleTileItem {
  const _ExampleTileItem({
    required this.rawRow,
    required this.status,
  });

  final Map<String, dynamic> rawRow;
  final _TileStatus status;
}

class _EnglishExampleCompositionProgressScreenState
    extends State<EnglishExampleCompositionProgressScreen>
    with RouteAware, WidgetsBindingObserver {
  final _client = Supabase.instance.client;

  bool _loading = true;
  String? _error;
  Map<String, List<_ExampleTileItem>> _groupedTiles = {};
  bool _routeSubscribed = false;

  String? get _learnerId => _client.auth.currentUser?.id;

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
      await triggerBackgroundSyncWithThrottle();
      if (!mounted) return;

      List<Map<String, dynamic>> examples = [];
      try {
        final rows = await _client
            .from('english_examples')
            .select(
              'id, knowledge_id, front_ja, back_en, explanation, supplement, prompt_supplement, display_order, created_at, '
              'knowledge:knowledge_id(id, content, unit, display_order, created_at)',
            )
            .order('display_order', ascending: true)
            .order('created_at', ascending: true);
        examples = List<Map<String, dynamic>>.from(rows);
        sortEnglishExampleRowsLikeKnowledgeList(examples);
      } on PostgrestException catch (e) {
        final missingTable =
            e.code == 'PGRST205' && e.message.contains('public.english_examples');
        if (!missingTable) rethrow;
        if (!mounted) return;
        setState(() {
          _error = '英語例文のテーブルがありません。Supabase の migration を確認してください。';
        });
        return;
      }

      Map<String, Map<String, dynamic>> states = {};
      final learnerId = _learnerId;
      if (learnerId != null && examples.isNotEmpty) {
        final ids = examples.map((e) => e['id'] as String).toList();
        states = await EnglishExampleStateSync.fetchCompositionStatesHybrid(
          client: _client,
          learnerId: learnerId,
          exampleIds: ids,
          localDb: SyncEngine.maybeLocalDb,
        );
      }

      if (!mounted) return;

      final grouped = <String, List<_ExampleTileItem>>{};
      for (final row in examples) {
        final id = row['id']?.toString();
        if (id == null || id.isEmpty) continue;
        final k = row['knowledge'];
        String chapter = '（単元なし）';
        if (k is Map<String, dynamic>) {
          final u = k['unit']?.toString().trim();
          if (u != null && u.isNotEmpty) chapter = u;
        }
        final state = states[id];
        final status = _tileStatusFromCompositionState(state);
        grouped.putIfAbsent(chapter, () => []).add(
              _ExampleTileItem(
                rawRow: Map<String, dynamic>.from(row),
                status: status,
              ),
            );
      }

      for (final list in grouped.values) {
        list.sort(
          (a, b) => compareEnglishExampleRowsByKnowledgeOrder(
            a.rawRow,
            b.rawRow,
          ),
        );
      }

      int chapterOrder(String chapter) {
        final list = grouped[chapter];
        if (list == null || list.isEmpty) return 1 << 30;
        return minKnowledgeDisplayOrderInChapter(list.map((i) => i.rawRow));
      }

      final sortedGrouped = <String, List<_ExampleTileItem>>{};
      final keys = grouped.keys.toList()
        ..sort((a, b) {
          final c = chapterOrder(a).compareTo(chapterOrder(b));
          if (c != 0) return c;
          return a.compareTo(b);
        });
      for (final k in keys) {
        sortedGrouped[k] = grouped[k]!;
      }

      setState(() {
        _groupedTiles = sortedGrouped;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// [english_example_composition_chapter_list_screen] の要練習判定に合わせる。
  _TileStatus _tileStatusFromCompositionState(Map<String, dynamic>? state) {
    if (state == null) return _TileStatus.unseen;
    final attempts = (state['attempts'] as num?)?.toInt() ?? 0;
    if (attempts <= 0) return _TileStatus.unseen;
    final last = state['last_answer_correct'] as bool?;
    if (last == false) return _TileStatus.notRemembered;
    if (last == true) return _TileStatus.remembered;
    return _TileStatus.unseen;
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

  Widget _statusTile(BuildContext context, _ExampleTileItem item) {
    return InkWell(
      onTap: () => _openComposition(item.rawRow),
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
    );
  }

  Future<void> _openComposition(Map<String, dynamic> raw) async {
    final ex = EnglishExample.fromRow(raw);
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => EnglishExampleCompositionScreen(
          examples: [ex],
          subjectName: '英作文出題',
          sessionDescriptor: '進捗から',
        ),
      ),
    );
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    const title = '英作文の学習状況';

    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text(title)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text(title)),
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
        appBar: AppBar(title: const Text(title)),
        body: const Center(child: Text('例文がありません')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text(title),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
            tooltip: '再読み込み',
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_learnerId == null)
            Material(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Text(
                  'ログインすると英作文の記録に応じた色が表示されます。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              'グレー: 未挑戦　赤: 要練習（未回答または直近不正解）　緑: 直近正解',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              child: Wrap(
                spacing: 0,
                runSpacing: 0,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (final entry in _groupedTiles.entries) ...[
                    _chapterLabel(context, entry.key),
                    for (final item in entry.value) _statusTile(context, item),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
