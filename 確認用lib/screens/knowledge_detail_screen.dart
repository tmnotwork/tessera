import 'dart:convert';
import 'dart:io' show File;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../models/knowledge.dart';
import '../utils/platform_utils.dart';
import '../widgets/edit_intents.dart';
import '../widgets/explanation_text.dart';
import 'knowledge_edit_screen.dart';

/// knowledge 詳細画面
class KnowledgeDetailScreen extends StatefulWidget {
  final List<Knowledge> allKnowledge;
  final int initialIndex;
  final String? dataFolderPath;
  /// 保存先ファイル名（例: knowledge.json）。未指定時は 'knowledge.json'
  final String knowledgeFileName;
  final bool initialEditing;

  const KnowledgeDetailScreen({
    super.key,
    required this.allKnowledge,
    required this.initialIndex,
    this.dataFolderPath,
    this.knowledgeFileName = 'knowledge.json',
    this.initialEditing = false,
  });

  @override
  State<KnowledgeDetailScreen> createState() => _KnowledgeDetailScreenState();
}

class _KnowledgeDetailScreenState extends State<KnowledgeDetailScreen> {
  bool _isEditing = false;
  late PageController _pageController;
  late int _currentIndex;
  late List<Knowledge> _allKnowledge;
  late TextEditingController _controller;
  bool _isLeftHovering = false;
  bool _isRightHovering = false;
  final Map<String, String> _savedExplanations = {};
  final Map<String, String> _savedTitles = {};
  final Map<String, bool> _savedConstruction = {};
  final Map<String, List<String>> _savedTags = {};
  final Map<String, String> _savedAuthorComments = {};
  final Map<String, String?> _savedTopic = {};
  late TextEditingController _titleController;
  late TextEditingController _customTagController;
  late TextEditingController _authorCommentController;
  late TextEditingController _topicController;
  bool _construction = false;
  List<String> _tags = [];

  @override
  void initState() {
    super.initState();
    _allKnowledge = List.from(widget.allKnowledge);
    _currentIndex = widget.initialIndex.clamp(0, _allKnowledge.length - 1);
    _pageController = PageController(initialPage: _currentIndex);
    final k = _allKnowledge[_currentIndex];
    _controller = TextEditingController(text: k.explanation);
    _titleController = TextEditingController(text: k.title);
    _customTagController = TextEditingController();
    _authorCommentController = TextEditingController(text: k.authorComment ?? '');
    _topicController = TextEditingController(text: k.topic ?? '');
    _construction = k.construction;
    _tags = List.from(k.tags);
    _isEditing = isDesktop && widget.dataFolderPath != null && widget.initialEditing;
  }

  Future<void> _reloadFromFile() async {
    if (widget.dataFolderPath == null || widget.dataFolderPath!.isEmpty) return;
    try {
      final file = File(p.join(widget.dataFolderPath!, widget.knowledgeFileName));
      if (!await file.exists()) return;
      final jsonString = await file.readAsString();
      final list = jsonDecode(jsonString) as List<dynamic>;
      final items = list
          .map((e) => Knowledge.fromJson(e as Map<String, dynamic>))
          .toList();
      items.sort((a, b) => (a.order ?? 0).compareTo(b.order ?? 0));
      if (mounted) {
        setState(() {
          _allKnowledge = items;
          final id = _allKnowledge[_currentIndex].id;
          final idx = _allKnowledge.indexWhere((e) => e.id == id);
          if (idx >= 0) {
            _currentIndex = idx;
            final k = _allKnowledge[_currentIndex];
            _controller.text = k.explanation;
            _titleController.text = k.title;
            _authorCommentController.text = _savedAuthorComments[k.id] ?? k.authorComment ?? '';
            _topicController.text = _savedTopic[k.id] ?? k.topic ?? '';
            _construction = k.construction;
            _tags = List.from(k.tags);
          }
        });
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _pageController.dispose();
    _controller.dispose();
    _titleController.dispose();
    _customTagController.dispose();
    _authorCommentController.dispose();
    _topicController.dispose();
    super.dispose();
  }

  void _onPageChanged(int index) {
    setState(() {
      _currentIndex = index;
      final k = _allKnowledge[index];
      _controller.text = k.explanation;
      _titleController.text = k.title;
      _authorCommentController.text = _savedAuthorComments[k.id] ?? k.authorComment ?? '';
      _topicController.text = _savedTopic[k.id] ?? k.topic ?? '';
      _construction = _savedConstruction[k.id] ?? k.construction;
      _tags = List.from(_savedTags[k.id] ?? k.tags);
    });
  }

  /// 編集モード用：指定インデックスのカードに切り替え（PageView がないため直接 state を更新）
  void _goToIndex(int index) {
    if (index < 0 || index >= _allKnowledge.length) return;
    _onPageChanged(index);
  }

  Future<void> _saveChanges({bool exitEditMode = false}) async {
    if (widget.dataFolderPath == null || widget.dataFolderPath!.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('保存できません：データフォルダが指定されていません'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
      return;
    }

    try {
      final file = File(p.join(widget.dataFolderPath!, widget.knowledgeFileName));
      final jsonString = await file.readAsString();
      final list = jsonDecode(jsonString) as List<dynamic>;

      final text = _controller.text;
      final title = _titleController.text;

      final currentKnowledge = _allKnowledge[_currentIndex];
      final authorComment = _authorCommentController.text.trim();
      final topic = _topicController.text.trim();
      final updatedList = list.map((item) {
        if (item['id'] == currentKnowledge.id) {
          return {
            ...item,
            'title': title,
            'explanation': text,
            'topic': topic.isEmpty ? null : topic,
            'construction': _construction,
            'tags': _tags,
            'author_comment': authorComment.isEmpty ? null : authorComment,
          };
        }
        return item;
      }).toList();

      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(updatedList),
        flush: true,
      );

      if (mounted) {
        setState(() {
          _savedTitles[currentKnowledge.id] = title;
          _savedExplanations[currentKnowledge.id] = text;
          _savedAuthorComments[currentKnowledge.id] = authorComment;
          _savedTopic[currentKnowledge.id] = topic.isEmpty ? null : topic;
          _savedConstruction[currentKnowledge.id] = _construction;
          _savedTags[currentKnowledge.id] = List.from(_tags);
        });
        final messenger = ScaffoldMessenger.of(context);
        messenger.showSnackBar(
          const SnackBar(content: Text('保存しました')),
        );
        if (exitEditMode) {
          Navigator.of(context).pop(true);
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存エラー: $e')),
        );
      }
    }
  }

  Future<void> _deleteCard() async {
    if (widget.dataFolderPath == null || widget.dataFolderPath!.isEmpty) return;

    final currentKnowledge = _allKnowledge[_currentIndex];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('カードを削除'),
        content: Text('「${currentKnowledge.title}」を削除しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      final file = File(p.join(widget.dataFolderPath!, widget.knowledgeFileName));
      final jsonString = await file.readAsString();
      final list = jsonDecode(jsonString) as List<dynamic>;

      final updatedList = list.where((item) => item['id'] != currentKnowledge.id).toList();

      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(updatedList),
        flush: true,
      );

      if (mounted) {
        final messenger = ScaffoldMessenger.of(context);
        Navigator.of(context).pop(true);
        messenger.showSnackBar(
          const SnackBar(content: Text('削除しました')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('削除エラー: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = (isDesktop || isAndroid) && widget.dataFolderPath != null;
    final currentKnowledge = _allKnowledge[_currentIndex];
    final hasPrevious = _currentIndex > 0;
    final hasNext = _currentIndex < _allKnowledge.length - 1;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _savedTitles[currentKnowledge.id] ?? currentKnowledge.title,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              '${_currentIndex + 1} / ${_allKnowledge.length}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          if (hasPrevious)
            IconButton(
              icon: const Icon(Icons.chevron_left),
              onPressed: () {
                if (_isEditing) {
                  _goToIndex(_currentIndex - 1);
                } else {
                  _pageController.previousPage(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeInOut,
                  );
                }
              },
              tooltip: '前のカード',
            ),
          if (hasNext)
            IconButton(
              icon: const Icon(Icons.chevron_right),
              onPressed: () {
                if (_isEditing) {
                  _goToIndex(_currentIndex + 1);
                } else {
                  _pageController.nextPage(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeInOut,
                  );
                }
              },
              tooltip: '次のカード',
            ),
          if (canEdit && !_isEditing)
            IconButton(
              icon: const Icon(Icons.edit),
              onPressed: () async {
                if (isAndroid) {
                  final currentKnowledge = _allKnowledge[_currentIndex];
                  final saved = await Navigator.of(context).push<bool>(
                    MaterialPageRoute<bool>(
                      builder: (context) => KnowledgeEditScreen(
                        dataFolderPath: widget.dataFolderPath!,
                        knowledgeFileName: widget.knowledgeFileName,
                        currentKnowledge: currentKnowledge,
                        initialTitle: _titleController.text,
                        initialExplanation: _controller.text,
                        initialConstruction: _construction,
                        initialTags: List.from(_tags),
                        initialAuthorComment: _authorCommentController.text,
                        initialTopic: _topicController.text.trim().isEmpty ? null : _topicController.text.trim(),
                      ),
                    ),
                  );
                  if (saved == true && mounted) await _reloadFromFile();
                } else {
                  setState(() => _isEditing = true);
                }
              },
              tooltip: '編集',
            ),
          if (_isEditing) ...[
            IconButton(
              icon: const Icon(Icons.check),
              onPressed: () => _saveChanges(exitEditMode: true),
              tooltip: '保存して終了',
            ),
            IconButton(
              icon: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
              onPressed: _deleteCard,
              tooltip: 'カードを削除',
            ),
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => _saveChanges(exitEditMode: true),
              tooltip: '保存して一覧に戻る（Ctrl+W）',
            ),
          ],
        ],
      ),
      body: _isEditing
          ? Shortcuts(
              shortcuts: const {
                SingleActivator(LogicalKeyboardKey.keyS, control: true): SaveIntent(),
                SingleActivator(LogicalKeyboardKey.keyW, control: true): CloseEditIntent(),
              },
              child: Actions(
                actions: {
                  SaveIntent: CallbackAction<SaveIntent>(
                    onInvoke: (_) {
                      _saveChanges(exitEditMode: false);
                      return null;
                    },
                  ),
                  CloseEditIntent: CallbackAction<CloseEditIntent>(
                    onInvoke: (_) {
                      _saveChanges(exitEditMode: true);
                      return null;
                    },
                  ),
                },
                child: Focus(
                  autofocus: true,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '編集',
                                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              ),
                              const SizedBox(height: 8),
                              TextField(
                                controller: _titleController,
                                decoration: const InputDecoration(
                                  labelText: 'タイトル',
                                  border: OutlineInputBorder(),
                                ),
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              Padding(
                                padding: const EdgeInsets.only(top: 8.0, bottom: 4.0),
                                child: Wrap(
                                  spacing: 8,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    SizedBox(
                                      width: 140,
                                      child: TextField(
                                        controller: _topicController,
                                        decoration: const InputDecoration(
                                          labelText: 'チャプター',
                                          hintText: '例：仮定法',
                                          isDense: true,
                                          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                                        ),
                                      ),
                                    ),
                                    FilterChip(
                                      label: const Text('基本'),
                                      selected: _tags.contains('基本'),
                                      onSelected: (value) async {
                                        setState(() {
                                          if (value) {
                                            if (!_tags.contains('基本')) _tags = [..._tags, '基本']..sort();
                                          } else {
                                            _tags = _tags.where((t) => t != '基本').toList();
                                          }
                                        });
                                        await _saveChanges(exitEditMode: false);
                                      },
                                      selectedColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                                    ),
                                    FilterChip(
                                      label: const Text('構文'),
                                      selected: _construction,
                                      onSelected: (value) async {
                                        setState(() => _construction = value);
                                        await _saveChanges(exitEditMode: false);
                                      },
                                      selectedColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                                    ),
                                  ],
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.only(top: 4.0, bottom: 8.0),
                                child: Wrap(
                                  spacing: 8,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    ..._tags.map((t) => Chip(
                                      label: Text(t),
                                      deleteIcon: const Icon(Icons.close, size: 18),
                                      onDeleted: () async {
                                        setState(() => _tags = _tags.where((x) => x != t).toList());
                                        await _saveChanges(exitEditMode: false);
                                      },
                                      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                                    )),
                                    SizedBox(
                                      width: 100,
                                      child: TextField(
                                        controller: _customTagController,
                                        decoration: const InputDecoration(
                                          hintText: 'タグを入力して追加',
                                          isDense: true,
                                          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                        ),
                                        onSubmitted: (value) async {
                                          final t = value.trim();
                                          if (t.isNotEmpty && !_tags.contains(t)) {
                                            setState(() {
                                              _tags = [..._tags, t]..sort();
                                              _customTagController.clear();
                                            });
                                            await _saveChanges(exitEditMode: false);
                                          }
                                        },
                                      ),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.add),
                                      onPressed: () async {
                                        final t = _customTagController.text.trim();
                                        if (t.isNotEmpty && !_tags.contains(t)) {
                                          setState(() {
                                            _tags = [..._tags, t]..sort();
                                            _customTagController.clear();
                                          });
                                          await _saveChanges(exitEditMode: false);
                                        }
                                      },
                                      tooltip: 'タグを追加',
                                    ),
                                  ],
                                ),
                              ),
                              Expanded(
                                child: TextField(
                                  controller: _controller,
                                  maxLines: null,
                                  expands: true,
                                  textAlignVertical: TextAlignVertical.top,
                                  decoration: const InputDecoration(
                                    border: OutlineInputBorder(),
                                    hintText: '説明を入力...（Ctrl+S 保存 / Ctrl+W 編集終了）',
                                    contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                                    alignLabelWithHint: true,
                                  ),
                                  style: Theme.of(context).textTheme.bodyLarge,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                '執筆者用コメント',
                                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 4),
                              TextField(
                                controller: _authorCommentController,
                                maxLines: 2,
                                minLines: 1,
                                textAlignVertical: TextAlignVertical.top,
                                decoration: const InputDecoration(
                                  hintText: '参考書には出しません。メモ用です。',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  alignLabelWithHint: true,
                                ),
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ],
                          ),
                        ),
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(
                        child: ListenableBuilder(
                          listenable: Listenable.merge([_controller, _titleController]),
                          builder: (context, _) {
                            return Container(
                              color: Theme.of(context).colorScheme.surface,
                              padding: const EdgeInsets.all(16.0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'プレビュー',
                                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                                      color: Theme.of(context).colorScheme.primary,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    _titleController.text,
                                    style: Theme.of(context).textTheme.titleMedium,
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.only(top: 8.0, bottom: 4.0),
                                    child: Wrap(
                                      spacing: 8,
                                      children: [
                                        if (_topicController.text.trim().isNotEmpty)
                                          Chip(
                                            label: Text(_topicController.text.trim()),
                                            backgroundColor: Theme.of(context)
                                                .colorScheme
                                                .surfaceContainerHighest,
                                          ),
                                        if (_construction)
                                          Chip(
                                            label: const Text('構文'),
                                            backgroundColor: Theme.of(context)
                                                .colorScheme
                                                .surfaceContainerHighest,
                                          ),
                                      ],
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4.0, bottom: 8.0),
                                    child: Wrap(
                                      spacing: 8,
                                      children: [
                                        ..._tags.map((t) => Chip(
                                          label: Text(t),
                                          backgroundColor: Theme.of(context)
                                              .colorScheme
                                              .surfaceContainerHighest,
                                        )),
                                      ],
                                    ),
                                  ),
                                  Expanded(
                                    child: SingleChildScrollView(
                                      child: ExplanationText(text: _controller.text),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            )
          : Stack(
              children: [
                PageView.builder(
                  controller: _pageController,
                  onPageChanged: _onPageChanged,
                  itemCount: _allKnowledge.length,
                  itemBuilder: (context, index) {
                    final knowledge = _allKnowledge[index];
                    final explanation = _savedExplanations[knowledge.id] ?? knowledge.explanation;
                    final construction = _savedConstruction[knowledge.id] ?? knowledge.construction;
                    final tags = _savedTags[knowledge.id] ?? knowledge.tags;
                    final topic = _savedTopic[knowledge.id] ?? knowledge.topic;
                    final authorComment = _savedAuthorComments[knowledge.id] ?? knowledge.authorComment ?? '';
                    return SelectionArea(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (topic != null || construction || tags.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.all(16.0),
                              child: Wrap(
                                spacing: 8,
                                children: [
                                  if (topic != null)
                                    Chip(
                                      label: Text(topic),
                                      backgroundColor: Theme.of(context)
                                          .colorScheme
                                          .surfaceContainerHighest,
                                    ),
                                  if (construction)
                                    Chip(
                                      label: const Text('構文'),
                                      backgroundColor: Theme.of(context)
                                          .colorScheme
                                          .surfaceContainerHighest,
                                    ),
                                  ...tags.map((t) => Chip(
                                    label: Text(t),
                                    backgroundColor: Theme.of(context)
                                        .colorScheme
                                        .surfaceContainerHighest,
                                  )),
                                ],
                              ),
                            ),
                          Expanded(
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.all(16.0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  ExplanationText(text: explanation),
                                  if (widget.dataFolderPath != null) ...[
                                    const SizedBox(height: 24),
                                    Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .surfaceContainerHighest
                                            .withOpacity(0.7),
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .outlineVariant
                                              .withOpacity(0.5),
                                        ),
                                      ),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            '執筆者用コメント（参考書には出しません）',
                                            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            authorComment.isEmpty ? '（未記入）' : authorComment,
                                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                              color: authorComment.isEmpty
                                                  ? Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.7)
                                                  : Theme.of(context).colorScheme.onSurface,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
                if (hasPrevious)
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    child: MouseRegion(
                      onEnter: (_) => setState(() => _isLeftHovering = true),
                      onExit: (_) => setState(() => _isLeftHovering = false),
                      child: GestureDetector(
                        onTap: () {
                          _pageController.previousPage(
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.easeInOut,
                          );
                        },
                        child: Container(
                          width: 100,
                          color: _isLeftHovering
                              ? Theme.of(context).colorScheme.outline.withOpacity(0.08)
                              : Colors.transparent,
                          child: Center(
                            child: AnimatedOpacity(
                              opacity: _isLeftHovering ? 1.0 : 0.0,
                              duration: const Duration(milliseconds: 200),
                              child: Icon(
                                Icons.chevron_left,
                                size: 48,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (hasNext)
                  Positioned(
                    right: 0,
                    top: 0,
                    bottom: 0,
                    child: MouseRegion(
                      onEnter: (_) => setState(() => _isRightHovering = true),
                      onExit: (_) => setState(() => _isRightHovering = false),
                      child: GestureDetector(
                        onTap: () {
                          _pageController.nextPage(
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.easeInOut,
                          );
                        },
                        child: Container(
                          width: 100,
                          color: _isRightHovering
                              ? Theme.of(context).colorScheme.outline.withOpacity(0.08)
                              : Colors.transparent,
                          child: Center(
                            child: AnimatedOpacity(
                              opacity: _isRightHovering ? 1.0 : 0.0,
                              duration: const Duration(milliseconds: 200),
                              child: Icon(
                                Icons.chevron_right,
                                size: 48,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
