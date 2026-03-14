import 'dart:async';

import 'dart:convert';
import 'dart:io' show File;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/knowledge.dart';
import '../models/reference_book.dart';
import '../utils/platform_utils.dart';
import 'knowledge_detail_screen.dart';

/// 指定した参考書の解説（knowledge）一覧画面
class KnowledgeListScreen extends StatefulWidget {
  const KnowledgeListScreen({
    super.key,
    required this.book,
    this.dataFolderPath,
  });

  final ReferenceBook book;
  final String? dataFolderPath;

  @override
  State<KnowledgeListScreen> createState() => _KnowledgeListScreenState();
}

class _KnowledgeListScreenState extends State<KnowledgeListScreen> {
  List<Knowledge> _items = [];
  String? _error;
  String? _dataFolderPath;
  bool _isLoading = true;
  StreamSubscription? _fileWatchSubscription;
  /// タグでフィルタ（null = すべて表示）
  String? _filterTag;

  /// 表示用のフィルタ済みリスト（選択タグが付いたカードのみ、またはすべて）
  List<Knowledge> get _filteredItems {
    if (_filterTag == null) return _items;
    return _items.where((k) => k.tags.contains(_filterTag)).toList();
  }

  /// 全カードからユニークなタグを取得（ソート済み）
  List<String> get _allTags {
    final set = <String>{};
    for (final k in _items) {
      set.addAll(k.tags);
    }
    final list = set.toList()..sort();
    return list;
  }

  @override
  void initState() {
    super.initState();
    _dataFolderPath = widget.dataFolderPath;
    _initialize();
  }

  @override
  void dispose() {
    _fileWatchSubscription?.cancel();
    super.dispose();
  }

  Future<void> _initialize() async {
    if (isDesktop && widget.dataFolderPath != null && widget.dataFolderPath!.isNotEmpty) {
      await _loadFromFolder(widget.dataFolderPath!);
    } else {
      await _loadFromAssets();
    }
    setState(() => _isLoading = false);
  }

  List<Knowledge> _parseJson(String jsonString) {
    final list = jsonDecode(jsonString) as List<dynamic>;
    final items = list
        .map((e) => Knowledge.fromJson(e as Map<String, dynamic>))
        .toList();
    items.sort((a, b) => (a.order ?? 0).compareTo(b.order ?? 0));
    return items;
  }

  Future<void> _loadFromAssets() async {
    try {
      final path = 'assets/data/${widget.book.knowledgeFile}';
      final jsonString = await rootBundle.loadString(path);
      setState(() {
        _items = _parseJson(jsonString);
        _error = null;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  Future<void> _loadFromFolder(String folderPath) async {
    _fileWatchSubscription?.cancel();
    try {
      final file = File(p.join(folderPath, widget.book.knowledgeFile));
      if (!await file.exists()) {
        setState(() {
          _error = '${widget.book.knowledgeFile} が見つかりません: $folderPath';
          _items = [];
        });
        return;
      }
      final jsonString = await file.readAsString();
      setState(() {
        _items = _parseJson(jsonString);
        _dataFolderPath = folderPath;
        _error = null;
      });
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(dataFolderKey, folderPath);

      _fileWatchSubscription = file.watch().listen((event) {
        if (mounted) {
          _loadFromFolder(folderPath);
        }
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _items = [];
      });
    }
  }

  Future<void> _pickFolder() async {
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'データフォルダを選択（${widget.book.knowledgeFile} を含むフォルダ）',
      lockParentWindow: true,
    );
    if (path != null && path.isNotEmpty) {
      setState(() => _isLoading = true);
      await _loadFromFolder(path);
      setState(() => _isLoading = false);
    }
  }

  Future<void> _changeFolder() async {
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'データフォルダを選択（${widget.book.knowledgeFile} を含むフォルダ）',
      lockParentWindow: true,
      initialDirectory: _dataFolderPath,
    );
    if (path != null && path.isNotEmpty) {
      setState(() => _isLoading = true);
      await _loadFromFolder(path);
      setState(() => _isLoading = false);
    }
  }

  Future<void> _reload() async {
    if (isDesktop && _dataFolderPath != null) {
      setState(() => _isLoading = true);
      await _loadFromFolder(_dataFolderPath!);
      setState(() => _isLoading = false);
    } else if (!isDesktop) {
      setState(() => _isLoading = true);
      await _loadFromAssets();
      setState(() => _isLoading = false);
    }
  }

  Future<void> _addCard() async {
    if (_dataFolderPath == null) return;
    try {
      final file = File(p.join(_dataFolderPath!, widget.book.knowledgeFile));
      final jsonString = await file.readAsString();
      final list = jsonDecode(jsonString) as List<dynamic>;

      int maxNum = 0;
      for (final item in list) {
        final id = item['id']?.toString() ?? '';
        final match = RegExp(r'^[a-z]*(\d+)$').firstMatch(id);
        if (match != null) {
          final n = int.tryParse(match.group(1) ?? '0') ?? 0;
          if (n > maxNum) maxNum = n;
        }
      }
      final newId = 'k${(maxNum + 1).toString().padLeft(3, '0')}';
      final maxOrder = list.isEmpty ? 0 : (list.map((e) => (e['order'] as num?)?.toInt() ?? 0).reduce((a, b) => a > b ? a : b));

      final newCard = {
        'id': newId,
        'type': 'grammar',
        'topic': null,
        'order': maxOrder + 1,
        'title': '',
        'explanation': '',
        'construction': false,
        'tags': [],
      };
      list.add(newCard);

      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(list),
        flush: true,
      );
      await _loadFromFolder(_dataFolderPath!);

      if (mounted && _items.isNotEmpty) {
        final newIndex = _items.indexWhere((e) => e.id == newId);
        if (newIndex >= 0) {
          await Navigator.of(context).push<bool>(
            MaterialPageRoute<bool>(
              builder: (context) => KnowledgeDetailScreen(
                allKnowledge: _items,
                initialIndex: newIndex,
                dataFolderPath: _dataFolderPath,
                knowledgeFileName: widget.book.knowledgeFile,
                initialEditing: true,
              ),
            ),
          );
          if (mounted) {
            if (_dataFolderPath != null) {
              await _loadFromFolder(_dataFolderPath!);
            } else {
              await _loadFromAssets();
            }
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

  Widget _buildSortChips(BuildContext context) {
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
        final prevTopic = index > 0 ? _items[index - 1].topic : null;
        final showChapterHeader = item.topic != prevTopic;
        final chapterTitle = item.topic ?? 'その他';
        return KeyedSubtree(
          key: ValueKey(item.id),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (showChapterHeader)
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                  alignment: Alignment.centerLeft,
                  child: Text(
                    chapterTitle,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
              ReorderableDragStartListener(
                index: index,
                child: ListTile(
                  title: Text(item.title),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (item.construction)
                        Padding(
                          padding: const EdgeInsets.only(right: 8.0),
                          child: Chip(
                            label: Text('構文', style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: Theme.of(context).colorScheme.onSurface,
                            )),
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            visualDensity: VisualDensity.compact,
                            backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                          ),
                        ),
                      ...item.tags.map((t) => Padding(
                            padding: const EdgeInsets.only(right: 8.0),
                            child: Chip(
                              label: Text(t, style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                color: Theme.of(context).colorScheme.onSurface,
                              )),
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
                              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              visualDensity: VisualDensity.compact,
                              backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                            ),
                          )),
                      Icon(Icons.drag_handle, color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ],
                  ),
                  onTap: () => _openDetail(context, index),
                ),
              ),
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
        final prevTopic = index > 0 ? list[index - 1].topic : null;
        final showChapterHeader = item.topic != prevTopic;
        final chapterTitle = item.topic ?? 'その他';
        final detailIndex = _items.indexWhere((e) => e.id == item.id);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          key: ValueKey(item.id),
          children: [
            if (showChapterHeader)
              Container(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                alignment: Alignment.centerLeft,
                child: Text(
                  chapterTitle,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
            ListTile(
              title: Text(item.title),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (item.construction)
                    Padding(
                      padding: const EdgeInsets.only(right: 8.0),
                      child: Chip(
                        label: Text('構文', style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurface,
                        )),
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                      ),
                    ),
                  ...item.tags.map((t) => Padding(
                        padding: const EdgeInsets.only(right: 8.0),
                        child: Chip(
                          label: Text(t, style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSurface,
                          )),
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                          backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                        ),
                      )),
                  const Icon(Icons.chevron_right),
                ],
              ),
              onTap: () => _openDetail(context, detailIndex),
            ),
          ],
        );
      },
    );
  }

  Future<void> _openDetail(BuildContext context, int index) async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (context) => KnowledgeDetailScreen(
          allKnowledge: _items,
          initialIndex: index,
          dataFolderPath: _dataFolderPath,
          knowledgeFileName: widget.book.knowledgeFile,
          initialEditing: isDesktop && _dataFolderPath != null,
        ),
      ),
    );
    if (mounted) {
      if (_dataFolderPath != null) {
        await _loadFromFolder(_dataFolderPath!);
      } else {
        await _loadFromAssets();
      }
    }
  }

  Future<void> _reorderCards(int oldIndex, int newIndex) async {
    if (_dataFolderPath == null) return;
    if (newIndex > oldIndex) newIndex--;
    final reordered = List<Knowledge>.from(_items);
    final item = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, item);

    try {
      final file = File(p.join(_dataFolderPath!, widget.book.knowledgeFile));
      final jsonString = await file.readAsString();
      final list = jsonDecode(jsonString) as List<dynamic>;

      for (var i = 0; i < reordered.length; i++) {
        final id = reordered[i].id;
        for (final obj in list) {
          if (obj['id'] == id) {
            obj['order'] = i + 1;
            break;
          }
        }
      }

      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(list),
        flush: true,
      );
      await _loadFromFolder(_dataFolderPath!);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('並び替えエラー: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.book.name)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null) {
      return Scaffold(
        appBar: AppBar(
          title: Text(widget.book.name),
          actions: isDesktop
              ? [
                  IconButton(
                    icon: const Icon(Icons.folder_open),
                    onPressed: _pickFolder,
                    tooltip: 'フォルダを選択',
                  ),
                ]
              : null,
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.error_outline, size: 48, color: Theme.of(context).colorScheme.error),
                const SizedBox(height: 16),
                Text('読み込みエラー: $_error', textAlign: TextAlign.center),
                if (isDesktop) ...[
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: _pickFolder,
                    icon: const Icon(Icons.folder_open),
                    label: const Text('フォルダを選択'),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.book.name),
            if (_dataFolderPath != null)
              Text(
                _dataFolderPath!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withOpacity(0.7),
                    ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
          ],
        ),
        actions: [
          if (isDesktop) ...[
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _reload,
              tooltip: '再読み込み（編集の反映）',
            ),
            IconButton(
              icon: const Icon(Icons.folder_open),
              onPressed: _changeFolder,
              tooltip: 'フォルダを変更',
            ),
          ],
        ],
      ),
      body: _items.isEmpty
          ? const Center(child: Text('データがありません'))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildSortChips(context),
                Expanded(
                  child: _filterTag == null && isDesktop && _dataFolderPath != null
                      ? _buildReorderableList(context)
                      : _buildPlainList(context),
                ),
              ],
            ),
      floatingActionButton: isDesktop && _dataFolderPath != null
          ? FloatingActionButton(
              onPressed: _addCard,
              tooltip: 'カードを追加',
              child: const Icon(Icons.add),
            )
          : null,
    );
  }
}
