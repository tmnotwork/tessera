import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app_route_observer.dart';
import '../models/english_example.dart';
import '../supabase/english_example_learning_state_remote.dart';
import '../sync/ensure_synced_for_local_read.dart';
import '../utils/english_example_review_filter.dart';
import 'english_example_solve_screen.dart';

/// 学習者向け：英語例文の暗記状況を単元ごとに色付きタイルで表示する。
class EnglishExampleProgressScreen extends StatefulWidget {
  const EnglishExampleProgressScreen({super.key});

  @override
  State<EnglishExampleProgressScreen> createState() => _EnglishExampleProgressScreenState();
}

enum _TileStatus { unseen, notRemembered, remembered }

class _ExampleTileItem {
  const _ExampleTileItem({
    required this.rawRow,
    required this.status,
    required this.sortOrder,
  });

  final Map<String, dynamic> rawRow;
  final _TileStatus status;
  final int sortOrder;
}

class _EnglishExampleProgressScreenState extends State<EnglishExampleProgressScreen>
    with RouteAware, WidgetsBindingObserver {
  final _client = Supabase.instance.client;

  bool _loading = true;
  String? _error;
  Map<String, List<_ExampleTileItem>> _groupedTiles = {};
  Map<String, Map<String, dynamic>> _learningStates = {};
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
      await ensureSyncedForLocalRead();
      if (!mounted) return;

      List<Map<String, dynamic>> examples = [];
      try {
        final rows = await _client
            .from('english_examples')
            .select(
              'id, knowledge_id, front_ja, back_en, explanation, supplement, display_order, created_at, '
              'knowledge:knowledge_id(id, content, unit)',
            )
            .order('display_order', ascending: true)
            .order('created_at', ascending: true);
        examples = List<Map<String, dynamic>>.from(rows);
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
        try {
          final ids = examples.map((e) => e['id'] as String).toList();
          states = await EnglishExampleLearningStateRemote.fetchStates(
            client: _client,
            learnerId: learnerId,
            exampleIds: ids,
          );
        } catch (e, st) {
          if (kDebugMode) {
            debugPrint('EnglishExampleProgress: learning states 取得失敗: $e\n$st');
          }
          if (mounted) {
            setState(() => _error = '学習状況の取得に失敗しました。ログイン状態と DB を確認してください。\n$e');
          }
        }
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
        final status = _tileStatusFromState(state);
        final sortOrder = (row['display_order'] as num?)?.toInt() ?? (1 << 30);
        grouped.putIfAbsent(chapter, () => []).add(
              _ExampleTileItem(
                rawRow: Map<String, dynamic>.from(row),
                status: status,
                sortOrder: sortOrder,
              ),
            );
      }

      for (final list in grouped.values) {
        list.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
      }

      int chapterOrder(String chapter) {
        final list = grouped[chapter];
        if (list == null || list.isEmpty) return 1 << 30;
        var m = 1 << 30;
        for (final item in list) {
          if (item.sortOrder < m) m = item.sortOrder;
        }
        return m;
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
        _learningStates = states;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  _TileStatus _tileStatusFromState(Map<String, dynamic>? state) {
    if (state == null) return _TileStatus.unseen;
    if (EnglishExampleReviewFilter.needsReview(state)) return _TileStatus.notRemembered;
    return _TileStatus.remembered;
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
  /// 進捗マスと色を反転（暗い地・明るい文字）。
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
      onTap: () => _openExample(item.rawRow),
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

  Future<void> _openExample(Map<String, dynamic> raw) async {
    final ex = EnglishExample.fromRow(raw);
    final initial = <String, Map<String, dynamic>>{};
    final s = _learningStates[ex.id];
    if (s != null) initial[ex.id] = s;

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => EnglishExampleSolveScreen(
          examples: [ex],
          subjectName: '英語例文',
          initialStates: initial,
        ),
      ),
    );
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    const title = '英語例文の学習状況';

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
        body: const Center(child: Text('英語例文がありません')),
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
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
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
    );
  }
}
