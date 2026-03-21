import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../database/local_database.dart';
import '../models/knowledge.dart';
import '../repositories/knowledge_repository.dart';
import '../sync/knowledge_save_remote_status.dart';

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
    required this.initialDevCompleted,
    this.initialTopic,
    this.localDatabase,
    this.subjectId,
    this.subjectName,
  });

  final Knowledge currentKnowledge;
  final String initialTitle;
  final String initialExplanation;
  final bool initialConstruction;
  final List<String> initialTags;
  final String initialAuthorComment;
  final bool initialDevCompleted;
  final String? initialTopic;
  final LocalDatabase? localDatabase;
  final String? subjectId;
  final String? subjectName;

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
  late bool _devCompleted;
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
    _devCompleted = widget.initialDevCompleted;
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
      final title = _titleController.text;
      final explanation = _explanationController.text;
      final topic = _topicController.text;
      final authorComment = _authorCommentController.text;

      late final String saveStatusMessage;
      if (widget.localDatabase != null &&
          widget.subjectId != null &&
          widget.subjectName != null) {
        final repo = createKnowledgeRepository(widget.localDatabase);
        final updated = Knowledge(
          id: widget.currentKnowledge.id,
          subjectId: widget.subjectId,
          subject: widget.subjectName,
          unit: topic.trim().isEmpty ? null : topic.trim(),
          content: title,
          description: explanation.isEmpty ? null : explanation,
          displayOrder: widget.currentKnowledge.displayOrder,
          construction: _construction,
          tags: List.from(_tags),
          authorComment: authorComment.trim().isEmpty ? null : authorComment.trim(),
          devCompleted: _devCompleted,
        );
        final saved = await repo.save(updated, subjectId: widget.subjectId!, subjectName: widget.subjectName!);
        saveStatusMessage = await knowledgeSaveRemoteStatusAfterLocalPersist(
          localDb: widget.localDatabase!,
          knowledgeId: saved.id,
        );
      } else {
        final client = Supabase.instance.client;
        await client.from('knowledge').update(
          Knowledge.toUpdatePayload(
            title: title,
            explanation: explanation,
            topic: topic,
            construction: _construction,
            authorComment: authorComment,
            devCompleted: _devCompleted,
          ),
        ).eq('id', widget.currentKnowledge.id);
        await Knowledge.syncTags(client, widget.currentKnowledge.id, _tags);
        saveStatusMessage = 'Supabaseに反映しました';
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(saveStatusMessage)),
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
                FilterChip(
                  label: const Text('完成'),
                  selected: _devCompleted,
                  onSelected: (value) => setState(() => _devCompleted = value),
                  tooltip: '開発者が内容を確認済み',
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
