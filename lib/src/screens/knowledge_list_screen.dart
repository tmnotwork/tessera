import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/knowledge.dart';
import '../utils/platform_utils.dart';
import 'knowledge_detail_screen.dart';

/// 指定した科目（subject）の knowledge カード一覧画面
class KnowledgeListScreen extends StatefulWidget {
  const KnowledgeListScreen({
    super.key,
    required this.subjectId,
    required this.subjectName,
  });

  final String subjectId;
  final String subjectName;

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

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final client = Supabase.instance.client;
      final rows = await client
          .from('knowledge')
          .select()
          .eq('subject_id', widget.subjectId)
          .order('display_order', ascending: true)
          .order('created_at', ascending: true);

      setState(() {
        _items = rows.map((r) => Knowledge.fromSupabase(r)).toList();
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _addCard() async {
    try {
      final client = Supabase.instance.client;
      final maxOrder = _items.isEmpty
          ? 0
          : _items.map((e) => e.displayOrder ?? 0).reduce((a, b) => a > b ? a : b);

      final inserted = await client.from('knowledge').insert({
        'subject_id': widget.subjectId,
        'subject': widget.subjectName,
        'content': '',
        'type': 'grammar',
        'construction': false,
        'tags': <String>[],
        'display_order': maxOrder + 1,
      }).select().single();

      final newCard = Knowledge.fromSupabase(inserted);
      await _load();

      if (mounted) {
        final newIndex = _items.indexWhere((e) => e.id == newCard.id);
        if (newIndex >= 0) {
          final changed = await Navigator.of(context).push<bool>(
            MaterialPageRoute<bool>(
              builder: (context) => KnowledgeDetailScreen(
                allKnowledge: _items,
                initialIndex: newIndex,
                initialEditing: true,
              ),
            ),
          );
          if (changed == true && mounted) await _load();
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
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (context) => KnowledgeDetailScreen(
          allKnowledge: _items,
          initialIndex: index,
          initialEditing: isDesktop,
        ),
      ),
    );
    if (changed == true && mounted) await _load();
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
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _addCard,
                    icon: const Icon(Icons.add),
                    label: const Text('最初のカードを追加'),
                  ),
                ],
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildTagFilter(context),
                Expanded(
                  child: _filterTag == null
                      ? _buildReorderableList(context)
                      : _buildPlainList(context),
                ),
              ],
            ),
      floatingActionButton: _items.isNotEmpty
          ? FloatingActionButton(
              onPressed: _addCard,
              tooltip: 'カードを追加',
              child: const Icon(Icons.add),
            )
          : null,
    );
  }
}
