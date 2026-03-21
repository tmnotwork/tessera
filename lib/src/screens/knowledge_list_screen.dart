import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../database/local_database.dart';
import '../models/knowledge.dart';
import '../repositories/knowledge_repository.dart';
import '../sync/ensure_synced_for_local_read.dart';
import '../sync/sync_engine.dart';
import '../utils/platform_utils.dart';
import 'knowledge_detail_screen.dart';

bool _rowNotSoftDeleted(Map<String, dynamic> row) {
  final v = row['deleted_at'];
  if (v == null) return true;
  return v.toString().trim().isEmpty;
}

/// 指定した科目（subject）の knowledge カード一覧画面
class KnowledgeListScreen extends StatefulWidget {
  const KnowledgeListScreen({
    super.key,
    required this.subjectId,
    required this.subjectName,
    this.localDatabase,
    this.isLearnerMode = false,
  });

  final String subjectId;
  final String subjectName;
  final LocalDatabase? localDatabase;
  /// true: 学習メニューから開いた場合。閲覧のみ・編集不可・問題リンク表示。
  final bool isLearnerMode;

  @override
  State<KnowledgeListScreen> createState() => _KnowledgeListScreenState();
}

class _KnowledgeListScreenState extends State<KnowledgeListScreen> {
  List<Knowledge> _items = [];
  bool _isLoading = true;
  String? _error;
  String? _filterTag;

  List<Knowledge> get _filteredItems {
    if (_filterTag == null) return _items;
    return _items.where((k) => k.tags.contains(_filterTag)).toList();
  }

  List<String> get _allTags {
    final set = <String>{};
    for (final k in _items) {
      set.addAll(k.tags);
    }
    return set.toList()..sort();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Supabase から knowledge を subject_id で取得。join 失敗時は select のみでリトライ。
  Future<List<Knowledge>> _fetchKnowledgeFromSupabase() async {
    final client = Supabase.instance.client;
    List<dynamic> rows;
    try {
      if (kDebugMode) debugPrint('[KnowledgeListScreen] Supabase try1: select with knowledge_card_tags join');
      rows = await client
          .from('knowledge')
          .select('*, knowledge_card_tags(tag_id, knowledge_tags(name))')
          .eq('subject_id', widget.subjectId)
          .order('display_order', ascending: true)
          .order('created_at', ascending: true);
      if (kDebugMode) debugPrint('[KnowledgeListScreen] Supabase try1 ok: count=${rows.length}');
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[KnowledgeListScreen] Supabase try1 FAILED: $e');
        debugPrint('[KnowledgeListScreen] try1 stack: $st');
      }
      final msg = e.toString();
      if (msg.contains('knowledge_card_tags') ||
          msg.contains('PGRST200') ||
          msg.contains('relationship')) {
        if (kDebugMode) debugPrint('[KnowledgeListScreen] Supabase try2: select() only (no join)');
        rows = await client
            .from('knowledge')
            .select()
            .eq('subject_id', widget.subjectId)
            .order('display_order', ascending: true)
            .order('created_at', ascending: true);
        if (kDebugMode) debugPrint('[KnowledgeListScreen] Supabase try2 ok: count=${rows.length}');
      } else {
        rethrow;
      }
    }
    final maps = (rows as List<Map<String, dynamic>>).where(_rowNotSoftDeleted).toList();
    return maps.map(Knowledge.fromSupabase).toList();
  }

  /// ローカルに一部の行しか無いとき、Supabase 上にだけあるカードを足して欠損を防ぐ。
  Future<List<Knowledge>> _mergeLocalWithSupabase(List<Knowledge> local) async {
    try {
      final remote = await _fetchKnowledgeFromSupabase();
      if (remote.isEmpty) return local;
      final seen = <String, Knowledge>{for (final k in local) k.id: k};
      var added = 0;
      for (final k in remote) {
        if (!seen.containsKey(k.id)) {
          seen[k.id] = k;
          added++;
        }
      }
      if (kDebugMode && added > 0) {
        debugPrint(
          '[KnowledgeListScreen] merge: local=${local.length}, +$added from Supabase → ${seen.length} total',
        );
      }
      final merged = seen.values.toList()
        ..sort((a, b) {
          final oa = a.displayOrder ?? 0;
          final ob = b.displayOrder ?? 0;
          final c = oa.compareTo(ob);
          if (c != 0) return c;
          return a.id.compareTo(b.id);
        });
      return merged;
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[KnowledgeListScreen] merge skipped: $e\n$st');
      }
      return local;
    }
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    await ensureSyncedForLocalRead();
    if (!mounted) return;

    final dataSource = widget.localDatabase != null ? 'LocalDB' : 'Supabase';
    if (kDebugMode) {
      debugPrint('[KnowledgeListScreen._load] subjectId=${widget.subjectId}, dataSource=$dataSource');
    }
    try {
      if (widget.localDatabase != null) {
        final repo = createKnowledgeRepository(widget.localDatabase);
        var list = await repo.getBySubject(widget.subjectId);
        if (kDebugMode) debugPrint('[KnowledgeListScreen._load] LocalDB result: count=${list.length}');
        // ローカルに 0 件のときは Supabase から取得する（Sync 未完了やリモートのみのデータ対応）
        if (list.isEmpty) {
          if (kDebugMode) debugPrint('[KnowledgeListScreen._load] LocalDB empty → fallback to Supabase');
          list = await _fetchKnowledgeFromSupabase();
        } else {
          list = await _mergeLocalWithSupabase(list);
        }
        if (mounted) setState(() => _items = list);
      } else {
        final list = await _fetchKnowledgeFromSupabase();
        if (mounted) setState(() => _items = list);
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[KnowledgeListScreen._load] FAILED: $e');
        debugPrint('[KnowledgeListScreen._load] stack: $st');
      }
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _addCard() async {
    try {
      final maxOrder = _items.isEmpty
          ? 0
          : _items.map((e) => e.displayOrder ?? 0).reduce((a, b) => a > b ? a : b);

      if (widget.localDatabase != null) {
        final repo = createKnowledgeRepository(widget.localDatabase);
        final newCard = Knowledge(
          id: 'local_0',
          content: '',
          subjectId: widget.subjectId,
          subject: widget.subjectName,
          displayOrder: maxOrder + 1,
        );
        final saved = await repo.save(newCard, subjectId: widget.subjectId, subjectName: widget.subjectName);
        if (SyncEngine.isInitialized) SyncEngine.instance.syncIfOnline();
        await _load();
        if (mounted) {
          final newIndex = _items.indexWhere((e) => e.id == saved.id);
          if (newIndex >= 0) {
            await Navigator.of(context).push<bool>(
              MaterialPageRoute<bool>(
                builder: (context) => KnowledgeDetailScreen(
                  allKnowledge: _items,
                  initialIndex: newIndex,
                  initialEditing: true,
                  isLearnerMode: widget.isLearnerMode,
                  localDatabase: widget.localDatabase,
                  subjectId: widget.subjectId,
                  subjectName: widget.subjectName,
                ),
              ),
            );
            if (mounted) await _load();
          }
        }
      } else {
        final client = Supabase.instance.client;
        final inserted = await client.from('knowledge').insert({
          'subject_id': widget.subjectId,
          'subject': widget.subjectName,
          'content': '',
          'type': 'grammar',
          'construction': false,
          'display_order': maxOrder + 1,
        }).select().single();

        final newCard = Knowledge.fromSupabase(inserted);
        await _load();

        if (mounted) {
          final newIndex = _items.indexWhere((e) => e.id == newCard.id);
          if (newIndex >= 0) {
            await Navigator.of(context).push<bool>(
              MaterialPageRoute<bool>(
                builder: (context) => KnowledgeDetailScreen(
                  allKnowledge: _items,
                  initialIndex: newIndex,
                  initialEditing: true,
                  isLearnerMode: widget.isLearnerMode,
                  localDatabase: widget.localDatabase,
                  subjectId: widget.subjectId,
                  subjectName: widget.subjectName,
                ),
              ),
            );
            if (mounted) await _load();
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('追加エラー: $e')),
        );
      }
    }
  }

  Future<void> _openDetail(int index) async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (context) => KnowledgeDetailScreen(
          allKnowledge: _items,
          initialIndex: index,
          initialEditing: widget.isLearnerMode ? false : isDesktop,
          isLearnerMode: widget.isLearnerMode,
          localDatabase: widget.localDatabase,
          subjectId: widget.subjectId,
          subjectName: widget.subjectName,
        ),
      ),
    );
    // OS/AppBar の戻るは pop(true) にならない。手動「再読み込み」と同様、戻ったら常に再取得する。
    if (mounted) await _load();
  }

  Future<void> _reorderCards(int oldIndex, int newIndex) async {
    if (newIndex > oldIndex) newIndex--;
    final reordered = List<Knowledge>.from(_items);
    final item = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, item);

    setState(() => _items = reordered);

    try {
      final client = Supabase.instance.client;
      for (var i = 0; i < reordered.length; i++) {
        await client
            .from('knowledge')
            .update({'display_order': i + 1})
            .eq('id', reordered[i].id);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('並び替えエラー: $e')),
        );
        await _load();
      }
    }
  }

  Widget _buildTagFilter(BuildContext context) {
    final tags = _allTags;
    if (tags.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: FilterChip(
              label: const Text('すべて'),
              selected: _filterTag == null,
              onSelected: (_) => setState(() => _filterTag = null),
              selectedColor: scheme.primaryContainer,
              checkmarkColor: scheme.primary,
            ),
          ),
          ...tags.map((tag) => Padding(
                padding: const EdgeInsets.only(right: 8.0),
                child: FilterChip(
                  label: Text(tag),
                  selected: _filterTag == tag,
                  onSelected: (_) => setState(() => _filterTag = tag),
                  selectedColor: scheme.primaryContainer,
                  checkmarkColor: scheme.primary,
                ),
              )),
        ],
      ),
    );
  }

  Widget _buildReorderableList(BuildContext context) {
    return ReorderableListView.builder(
      buildDefaultDragHandles: false,
      itemCount: _items.length,
      onReorder: _reorderCards,
      itemBuilder: (context, index) {
        final item = _items[index];
        final prevTopic = index > 0 ? _items[index - 1].unit : null;
        final showHeader = item.unit != prevTopic;

        final tile = _buildListTile(context, item, index, draggable: true);
        final dragListener = isDesktop
            ? ReorderableDragStartListener(index: index, child: tile)
            : ReorderableDelayedDragStartListener(index: index, child: tile);

        return KeyedSubtree(
          key: ValueKey(item.id),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (showHeader)
                _buildChapterHeader(context, item.unit ?? 'その他'),
              dragListener,
            ],
          ),
        );
      },
    );
  }

  Widget _buildPlainList(BuildContext context) {
    final list = _filteredItems;
    if (list.isEmpty) {
      return Center(
        child: Text(
          _filterTag != null ? '「$_filterTag」のカードはありません' : 'データがありません',
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      );
    }
    return ListView.builder(
      itemCount: list.length,
      itemBuilder: (context, index) {
        final item = list[index];
        final prevTopic = index > 0 ? list[index - 1].unit : null;
        final showHeader = item.unit != prevTopic;
        final detailIndex = _items.indexWhere((e) => e.id == item.id);
        return Column(
          key: ValueKey(item.id),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showHeader) _buildChapterHeader(context, item.unit ?? 'その他'),
            _buildListTile(context, item, detailIndex, draggable: false),
          ],
        );
      },
    );
  }

  Widget _buildChapterHeader(BuildContext context, String title) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      alignment: Alignment.centerLeft,
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
      ),
    );
  }

  Widget _buildListTile(BuildContext context, Knowledge item, int index,
      {required bool draggable}) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      title: Text(item.title.isEmpty ? '（タイトル未設定）' : item.title),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (item.construction)
            Padding(
              padding: const EdgeInsets.only(right: 8.0),
              child: Chip(
                label: Text(
                  '構文',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            ),
          ...item.tags.map((t) => Padding(
                padding: const EdgeInsets.only(right: 8.0),
                child: Chip(
                  label: Text(t, style: Theme.of(context).textTheme.labelSmall),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                  backgroundColor: scheme.surfaceContainerHighest,
                ),
              )),
          draggable
              ? Icon(Icons.drag_handle, color: scheme.onSurfaceVariant)
              : const Icon(Icons.chevron_right),
        ],
      ),
      onTap: () => _openDetail(index),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.subjectName)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.subjectName)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.error_outline,
                    size: 48, color: Theme.of(context).colorScheme.error),
                const SizedBox(height: 16),
                Text('読み込みエラー: $_error', textAlign: TextAlign.center),
                const SizedBox(height: 24),
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

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.subjectName),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
            tooltip: '再読み込み',
          ),
        ],
      ),
      body: _items.isEmpty
          ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text('カードがありません'),
                    if (!widget.isLearnerMode) ...[
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _addCard,
                        icon: const Icon(Icons.add),
                        label: const Text('最初のカードを追加'),
                      ),
                    ],
                  ],
                ),
              )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildTagFilter(context),
                Expanded(
                  child: _filterTag == null && !widget.isLearnerMode
                      ? _buildReorderableList(context)
                      : _buildPlainList(context),
                ),
              ],
            ),
      floatingActionButton: !widget.isLearnerMode && _items.isNotEmpty
          ? FloatingActionButton(
              onPressed: _addCard,
              tooltip: 'カードを追加',
              child: const Icon(Icons.add),
            )
          : null,
    );
  }
}
