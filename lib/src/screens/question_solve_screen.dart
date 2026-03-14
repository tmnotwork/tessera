import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/knowledge.dart';
import 'four_choice_create_screen.dart';
import 'knowledge_detail_screen.dart';

/// 知識に紐づく問題を解く画面（四択 or テキスト入力）
class QuestionSolveScreen extends StatefulWidget {
  const QuestionSolveScreen({
    super.key,
    required this.questionIds,
    required this.knowledgeTitle,
  });

  final List<String> questionIds;
  final String knowledgeTitle;

  @override
  State<QuestionSolveScreen> createState() => _QuestionSolveScreenState();
}

class _QuestionSolveScreenState extends State<QuestionSolveScreen> {
  int _index = 0;
  Map<String, dynamic>? _question;
  List<String> _choices = [];
  List<Knowledge> _linkedKnowledge = [];
  bool _loading = true;
  String? _error;
  int? _selectedIndex;
  bool _answered = false;

  List<String> get _currentChoices {
    if (_choices.isNotEmpty) return _choices;
    final c = _question?['choices'];
    if (c is List) return c.map((e) => e.toString()).toList();
    return [];
  }

  @override
  void initState() {
    super.initState();
    _loadQuestion();
  }

  Future<void> _loadQuestion() async {
    if (_index >= widget.questionIds.length) return;
    setState(() {
      _loading = true;
      _error = null;
      _question = null;
      _choices = [];
      _linkedKnowledge = [];
      _selectedIndex = null;
      _answered = false;
    });
    try {
      final client = Supabase.instance.client;
      final id = widget.questionIds[_index];
      final row = await client
          .from('questions')
          .select('id, knowledge_id, question_type, question_text, correct_answer, explanation, choices, created_at, updated_at')
          .eq('id', id)
          .maybeSingle();
      if (row == null) {
        setState(() {
          _error = '問題が見つかりません';
          _loading = false;
        });
        return;
      }
      List<String> choices = [];
      try {
        final choiceRows = await client.from('question_choices').select('choice_text, position').eq('question_id', id).order('position');
        final choiceList = choiceRows as List;
        if (choiceList.isNotEmpty) {
          choices = choiceList.map((r) => (r as Map<String, dynamic>)['choice_text']?.toString() ?? '').toList();
        }
      } catch (_) {}
      if (choices.isEmpty) {
        final c = row['choices'];
        if (c is List) {
          choices = c.map((e) => e.toString()).toList();
        } else if (c is String && c.isNotEmpty) {
          try {
            final decoded = jsonDecode(c);
            if (decoded is List) {
              choices = decoded.map((e) => e.toString()).toList();
            }
          } catch (_) {}
        }
      }
      // 紐づく知識を取得（question_knowledge + questions.knowledge_id）
      List<String> knowledgeIds = [];
      try {
        final junc = await client.from('question_knowledge').select('knowledge_id').eq('question_id', id);
        for (final r in junc as List) {
          final kid = (r as Map<String, dynamic>)['knowledge_id']?.toString();
          if (kid != null && kid.isNotEmpty && !knowledgeIds.contains(kid)) knowledgeIds.add(kid);
        }
        final legacyId = row['knowledge_id']?.toString();
        if (legacyId != null && legacyId.isNotEmpty && !knowledgeIds.contains(legacyId)) knowledgeIds.add(legacyId);
      } catch (_) {}
      List<Knowledge> linked = [];
      if (knowledgeIds.isNotEmpty) {
        try {
          List<dynamic> kRows;
          try {
            kRows = await client
                .from('knowledge')
                .select('*, knowledge_card_tags(tag_id, knowledge_tags(name))')
                .inFilter('id', knowledgeIds);
          } catch (_) {
            kRows = await client.from('knowledge').select().inFilter('id', knowledgeIds);
          }
          linked = kRows.map((r) => Knowledge.fromSupabase(r as Map<String, dynamic>)).toList();
        } catch (_) {}
      }
      if (mounted) {
        setState(() {
          _question = row;
          _choices = choices;
          _linkedKnowledge = linked;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  void _onSelectChoice(int i) {
    if (_answered) return;
    setState(() {
      _selectedIndex = i;
      _answered = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text('問題（${_index + 1}/${widget.questionIds.length}）')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null || _question == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('問題')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SelectableText(_error ?? '問題を読み込めません', textAlign: TextAlign.center),
              const SizedBox(height: 16),
              TextButton.icon(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.arrow_back),
                label: const Text('知識に戻る'),
              ),
            ],
          ),
        ),
      );
    }

    final questionText = _question!['question_text']?.toString() ?? '';
    final explanation = _question!['explanation']?.toString() ?? '';
    final choices = _currentChoices;
    final isMultipleChoice = choices.length >= 2;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('問題を解く（${_index + 1}/${widget.questionIds.length}）'),
            if (widget.knowledgeTitle.isNotEmpty)
              Text(widget.knowledgeTitle, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit),
            tooltip: 'この問題を編集',
            onPressed: () async {
              final questionId = widget.questionIds[_index];
              final updated = await Navigator.of(context).push<bool>(
                MaterialPageRoute(
                  builder: (context) => FourChoiceCreateScreen(questionId: questionId),
                ),
              );
              if (updated == true && mounted) _loadQuestion();
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        key: ValueKey<String>(widget.questionIds[_index]),
        padding: const EdgeInsets.all(16),
        child: SelectionArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
            SelectableText(
              questionText,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w500),
            ),
            if (_linkedKnowledge.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                '紐づく知識',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(height: 8),
              ..._linkedKnowledge.asMap().entries.map((e) {
                final idx = e.key;
                final k = e.value;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Material(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                    child: InkWell(
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute<bool>(
                            builder: (context) => KnowledgeDetailScreen(
                              allKnowledge: _linkedKnowledge,
                              initialIndex: idx,
                              initialEditing: false,
                            ),
                          ),
                        );
                      },
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        child: Row(
                          children: [
                            Icon(Icons.menu_book, size: 20, color: Theme.of(context).colorScheme.primary),
                            const SizedBox(width: 8),
                            Expanded(child: SelectableText(k.title, style: Theme.of(context).textTheme.bodyMedium)),
                            Icon(Icons.chevron_right, color: Theme.of(context).colorScheme.onSurfaceVariant),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }),
              const SizedBox(height: 16),
            ],
            const SizedBox(height: 24),
            if (isMultipleChoice) ...[
              Text(
                '四択',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(height: 8),
              ...choices.asMap().entries.map((e) {
                final i = e.key;
                final text = e.value;
                final selected = _selectedIndex == i;
                final correct = _question!['correct_answer']?.toString() == text;
                Color? bg;
                if (_answered) {
                  if (correct) bg = Colors.green.shade100;
                  else if (selected && !correct) bg = Colors.red.shade100;
                }
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Material(
                    color: bg ?? Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(
                        color: Theme.of(context).colorScheme.outlineVariant,
                        width: 1,
                      ),
                    ),
                    child: InkWell(
                      onTap: () => _onSelectChoice(i),
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        child: Row(
                          children: [
                            Text(
                              '${String.fromCharCode(65 + i)}.',
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color: Theme.of(context).colorScheme.primary,
                                  ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: SelectableText(
                                text,
                                style: Theme.of(context).textTheme.bodyLarge,
                              ),
                            ),
                            if (_answered && correct) Icon(Icons.check_circle, color: Colors.green.shade700, size: 22),
                            if (_answered && selected && !correct) Icon(Icons.cancel, color: Colors.red.shade700, size: 22),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ] else
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text('（この問題は四択形式ではありません）', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ),
            if (_answered) ...[
              const SizedBox(height: 24),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('解説', style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
                    const SizedBox(height: 4),
                    SelectableText(explanation.isNotEmpty ? explanation : '（解説はありません）'),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                if (_index > 0)
                  TextButton.icon(
                    onPressed: () {
                      setState(() {
                        _index--;
                        _answered = false;
                        _selectedIndex = null;
                      });
                      _loadQuestion();
                    },
                    icon: const Icon(Icons.chevron_left),
                    label: const Text('前の問題'),
                  )
                else const SizedBox.shrink(),
                if (_index < widget.questionIds.length - 1)
                  FilledButton.icon(
                    onPressed: () {
                      setState(() {
                        _index++;
                        _answered = false;
                        _selectedIndex = null;
                      });
                      _loadQuestion();
                    },
                    icon: const Icon(Icons.chevron_right),
                    label: const Text('次の問題'),
                  )
                else
                  FilledButton.icon(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.menu_book),
                    label: const Text('知識に戻る'),
                  ),
              ],
            ),
          ],
        ),
        ),
      ),
    );
  }
}
