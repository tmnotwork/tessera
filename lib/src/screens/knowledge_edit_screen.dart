import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/knowledge.dart';

/// モバイル用の全画面編集画面
class KnowledgeEditScreen extends StatefulWidget {
  const KnowledgeEditScreen({
    super.key,
    required this.currentKnowledge,
    required this.initialTitle,
    required this.initialExplanation,
    required this.initialConstruction,
    required this.initialTags,
    required this.initialAuthorComment,
    this.initialTopic,
  });

  final Knowledge currentKnowledge;
  final String initialTitle;
  final String initialExplanation;
  final bool initialConstruction;
  final List<String> initialTags;
  final String initialAuthorComment;
  final String? initialTopic;

  @override
  State<KnowledgeEditScreen> createState() => _KnowledgeEditScreenState();
}

class _KnowledgeEditScreenState extends State<KnowledgeEditScreen> {
  late TextEditingController _titleController;
  late TextEditingController _explanationController;
  late TextEditingController _authorCommentController;
  late TextEditingController _customTagController;
  late TextEditingController _topicController;
  late bool _construction;
  late List<String> _tags;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.initialTitle);
    _explanationController = TextEditingController(text: widget.initialExplanation);
    _authorCommentController = TextEditingController(text: widget.initialAuthorComment);
    _customTagController = TextEditingController();
    _topicController = TextEditingController(
      text: widget.initialTopic ?? widget.currentKnowledge.unit ?? '',
    );
    _construction = widget.initialConstruction;
    _tags = List.from(widget.initialTags);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _explanationController.dispose();
    _authorCommentController.dispose();
    _customTagController.dispose();
    _topicController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final client = Supabase.instance.client;
      await client.from('knowledge').update(
        Knowledge.toUpdatePayload(
          title: _titleController.text,
          explanation: _explanationController.text,
          topic: _topicController.text,
          construction: _construction,
          tags: _tags,
          authorComment: _authorCommentController.text,
        ),
      ).eq('id', widget.currentKnowledge.id);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('保存しました')),
        );
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存エラー: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('カードを削除'),
        content: Text('「${widget.currentKnowledge.title}」を削除しますか？'),
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

    setState(() => _saving = true);
    try {
      final client = Supabase.instance.client;
      await client.from('knowledge').delete().eq('id', widget.currentKnowledge.id);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('削除しました')),
        );
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('削除エラー: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('編集'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(false),
          tooltip: '閉じる',
        ),
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else ...[
            IconButton(
              icon: const Icon(Icons.check),
              onPressed: _save,
              tooltip: '保存',
            ),
            IconButton(
              icon: Icon(Icons.delete_outline, color: scheme.error),
              onPressed: _delete,
              tooltip: 'カードを削除',
            ),
          ],
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _titleController,
              decoration: const InputDecoration(
                labelText: 'タイトル',
                border: OutlineInputBorder(),
              ),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Padding(
              padding: const EdgeInsets.only(top: 12.0, bottom: 4.0),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
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
                    onSelected: (value) => setState(() {
                      if (value) {
                        if (!_tags.contains('基本')) _tags = [..._tags, '基本']..sort();
                      } else {
                        _tags = _tags.where((t) => t != '基本').toList();
                      }
                    }),
                    selectedColor: scheme.surfaceContainerHighest,
                  ),
                  FilterChip(
                    label: const Text('構文'),
                    selected: _construction,
                    onSelected: (value) => setState(() => _construction = value),
                    selectedColor: scheme.surfaceContainerHighest,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4.0, bottom: 8.0),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  ..._tags.map((t) => Chip(
                        label: Text(t),
                        deleteIcon: const Icon(Icons.close, size: 18),
                        onDeleted: () => setState(
                          () => _tags = _tags.where((x) => x != t).toList(),
                        ),
                        backgroundColor: scheme.surfaceContainerHighest,
                      )),
                  SizedBox(
                    width: 140,
                    child: TextField(
                      controller: _customTagController,
                      decoration: const InputDecoration(
                        hintText: 'タグを追加',
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      ),
                      onSubmitted: (value) {
                        final t = value.trim();
                        if (t.isNotEmpty && !_tags.contains(t)) {
                          setState(() {
                            _tags = [..._tags, t]..sort();
                            _customTagController.clear();
                          });
                        }
                      },
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add),
                    onPressed: () {
                      final t = _customTagController.text.trim();
                      if (t.isNotEmpty && !_tags.contains(t)) {
                        setState(() {
                          _tags = [..._tags, t]..sort();
                          _customTagController.clear();
                        });
                      }
                    },
                    tooltip: 'タグを追加',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _explanationController,
              maxLines: null,
              minLines: 12,
              textAlignVertical: TextAlignVertical.top,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '説明を入力...',
                alignLabelWithHint: true,
              ),
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 16),
            Text(
              '執筆者用コメント',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
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
    );
  }
}
