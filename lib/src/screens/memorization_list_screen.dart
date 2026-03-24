import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/memorization_card.dart';
import '../sync/ensure_synced_for_local_read.dart';
import 'memorization_solve_screen.dart';

/// 指定した科目の暗記カード一覧画面
class MemorizationListScreen extends StatefulWidget {
  const MemorizationListScreen({
    super.key,
    required this.subjectId,
    required this.subjectName,
  });

  final String subjectId;
  final String subjectName;

  @override
  State<MemorizationListScreen> createState() => _MemorizationListScreenState();
}

class _MemorizationListScreenState extends State<MemorizationListScreen> {
  List<MemorizationCard> _items = [];
  bool _isLoading = true;
  String? _error;

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
      await triggerBackgroundSyncWithThrottle();
      if (!mounted) return;
      final client = Supabase.instance.client;
      final rows = await client
          .from('memorization_cards')
          .select('*, memorization_card_tags(tag_id, memorization_tags(name))')
          .eq('subject_id', widget.subjectId)
          .order('display_order', ascending: true)
          .order('created_at', ascending: true);

      setState(() {
        _items = rows.map((r) => MemorizationCard.fromSupabase(r)).toList();
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _isLoading = false);
    }
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
          if (_items.isNotEmpty)
            TextButton.icon(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (context) => MemorizationSolveScreen(
                      cards: _items,
                      subjectName: widget.subjectName,
                    ),
                  ),
                );
              },
              icon: const Icon(Icons.quiz),
              label: const Text('出題'),
            ),
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
                    const Text('暗記カードがありません'),
                    const SizedBox(height: 16),
                    Text(
                      'この科目の暗記カードを追加できます',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              )
          : ListView.builder(
              itemCount: _items.length,
              itemBuilder: (context, index) {
                final item = _items[index];
                final prevUnit = index > 0 ? _items[index - 1].unit : null;
                final showHeader = item.unit != prevUnit;
                return Column(
                  key: ValueKey(item.id),
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (showHeader)
                      _buildChapterHeader(
                          context, item.unit ?? 'その他'),
                    ListTile(
                      title: Text(
                        item.frontContent.isEmpty
                            ? '（表が未設定）'
                            : item.frontContent,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: item.backContent != null &&
                              item.backContent!.isNotEmpty
                          ? Text(
                              item.backContent!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            )
                          : null,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (item.tags.isNotEmpty)
                            ...item.tags.map(
                              (t) => Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: Chip(
                                  label: Text(
                                    t,
                                    style: Theme.of(context).textTheme.labelSmall,
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 0),
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  visualDensity: VisualDensity.compact,
                                  backgroundColor: Theme.of(context)
                                      .colorScheme
                                      .surfaceContainerHighest,
                                ),
                              ),
                            ),
                          const Icon(Icons.chevron_right),
                        ],
                      ),
                      onTap: () {
                        // TODO: カード詳細・編集
                      },
                    ),
                  ],
                );
              },
            ),
    );
  }
}
