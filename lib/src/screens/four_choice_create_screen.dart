import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/question_choice.dart';
import '../sync/ensure_synced_for_local_read.dart';

/// 四択問題の新規作成・編集画面
class FourChoiceCreateScreen extends StatefulWidget {
  const FourChoiceCreateScreen({
    super.key,
    this.questionId,
    this.initialSubjectId,
    this.initialKnowledgeId,
  });

  /// 指定時は編集モード（既存問題を読み込んで更新）
  final String? questionId;
  /// 新規作成時に初期選択したい科目ID（任意）
  final String? initialSubjectId;
  /// 新規作成時に初期選択したい知識ID（任意）
  final String? initialKnowledgeId;

  @override
  State<FourChoiceCreateScreen> createState() => _FourChoiceCreateScreenState();
}

class _FourChoiceCreateScreenState extends State<FourChoiceCreateScreen> {
  final _formKey = GlobalKey<FormState>();
  final _questionController = TextEditingController();
  final _choiceControllers = List.generate(4, (_) => TextEditingController());
  final _explanationController = TextEditingController();
  final _referenceController = TextEditingController();

  int _correctIndex = 0;
  /// コア問題フラグ（true = 習得判定に含める必須問題、false = 追加演習用）
  bool _isCore = true;
  /// 開発者が問題内容を確認済み（AI 生成のレビュー用）
  bool _devCompleted = false;
  List<Map<String, dynamic>> _subjects = [];
  List<Map<String, dynamic>> _knowledgeList = [];
  String? _selectedSubjectId;
  String? _selectedKnowledgeId;
  bool _loadingSubjects = true;
  bool _loadingKnowledge = false;
  bool _loadingQuestion = false;
  bool _saving = false;

  bool get _isEditMode => widget.questionId != null && widget.questionId!.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _loadSubjects().then((_) {
      if (_isEditMode && mounted) _loadQuestion();
    });
  }

  @override
  void dispose() {
    _questionController.dispose();
    for (final c in _choiceControllers) c.dispose();
    _explanationController.dispose();
    _referenceController.dispose();
    super.dispose();
  }

  Future<void> _loadSubjects() async {
    setState(() => _loadingSubjects = true);
    try {
      await triggerBackgroundSyncWithThrottle();
      if (!mounted) return;
      final client = Supabase.instance.client;
      final rows = await client.from('subjects').select().order('display_order');
      if (mounted) {
        setState(() {
          _subjects = List<Map<String, dynamic>>.from(rows);
          _loadingSubjects = false;
          if (_subjects.isNotEmpty && _selectedSubjectId == null) {
            final preferred = widget.initialSubjectId;
            final hasPreferred = preferred != null &&
                _subjects.any((s) => s['id']?.toString() == preferred);
            _selectedSubjectId = hasPreferred
                ? preferred
                : _subjects.first['id']?.toString();
            _loadKnowledge();
          }
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loadingSubjects = false);
    }
  }

  Future<void> _loadQuestion() async {
    final id = widget.questionId;
    if (id == null) return;
    setState(() => _loadingQuestion = true);
    try {
      await triggerBackgroundSyncWithThrottle();
      if (!mounted) return;
      final client = Supabase.instance.client;
      dynamic q;
      try {
        q = await client.from('questions').select().eq('id', id).maybeSingle();
      } on PostgrestException catch (e) {
        if (e.code == '42703' || (e.message.contains('reference') && e.message.contains('does not exist'))) {
          q = await client.from('questions').select('id, question_text, explanation, correct_answer, knowledge_id, choices').eq('id', id).maybeSingle();
        } else {
          rethrow;
        }
      }
      if (q == null || !mounted) return;

      final questionText = q['question_text']?.toString() ?? '';
      final explanation = q['explanation']?.toString() ?? '';
      final reference = q['reference']?.toString() ?? '';
      final correctAnswer = q['correct_answer']?.toString() ?? '';

      final List<String> choiceTexts = List.filled(4, '');
      var correctIdx = 0;

      try {
        final choiceRows = await client.from('question_choices').select('position, choice_text, is_correct').eq('question_id', id).order('position');
        final rawList = choiceRows as List;
        for (var i = 0; i < rawList.length && i < 4; i++) {
          final c = rawList[i];
          if (c is! Map<String, dynamic>) continue;
          choiceTexts[i] = c['choice_text']?.toString() ?? '';
          if (c['is_correct'] == true) correctIdx = i;
        }
        if (rawList.length >= 4 && correctIdx == 0 && correctAnswer.isNotEmpty) {
          for (var i = 0; i < 4; i++) {
            if (choiceTexts[i] == correctAnswer) { correctIdx = i; break; }
          }
        }
      } catch (_) {}

      if (choiceTexts.every((s) => s.isEmpty)) {
        final rawChoices = q['choices'];
        if (rawChoices is List) {
          for (var i = 0; i < 4 && i < rawChoices.length; i++) {
            choiceTexts[i] = rawChoices[i].toString();
          }
          if (correctAnswer.isNotEmpty) {
            for (var i = 0; i < 4; i++) {
              if (choiceTexts[i] == correctAnswer) { correctIdx = i; break; }
            }
          }
        } else if (rawChoices is String && rawChoices.isNotEmpty) {
          try {
            final decoded = jsonDecode(rawChoices);
            if (decoded is List) {
              for (var i = 0; i < 4 && i < decoded.length; i++) {
                choiceTexts[i] = decoded[i].toString();
              }
              if (correctAnswer.isNotEmpty) {
                for (var i = 0; i < 4; i++) {
                  if (choiceTexts[i] == correctAnswer) { correctIdx = i; break; }
                }
              }
            }
          } catch (_) {}
        }
      }

      if (!mounted) return;
      final devDone = q['dev_completed'] == true;
      setState(() {
        _questionController.text = questionText;
        _explanationController.text = explanation;
        _referenceController.text = reference;
        for (var i = 0; i < 4; i++) _choiceControllers[i].text = choiceTexts[i];
        _correctIndex = correctIdx;
        _devCompleted = devDone;
        _loadingQuestion = false;
      });

      String? knowledgeId = q['knowledge_id']?.toString();
      bool isCore = true;
      try {
        final juncList = await client.from('question_knowledge').select('knowledge_id, is_core').eq('question_id', id).limit(1);
        final list = juncList as List;
        if (list.isNotEmpty && list.first is Map<String, dynamic>) {
          final first = list.first as Map<String, dynamic>;
          if (knowledgeId == null || knowledgeId.isEmpty) {
            knowledgeId = first['knowledge_id']?.toString();
          }
          isCore = first['is_core'] == true;
        }
      } catch (_) {}

      if (mounted && knowledgeId != null && knowledgeId.isNotEmpty) {
        final k = await client.from('knowledge').select('subject_id').eq('id', knowledgeId).maybeSingle();
        final sid = k?['subject_id']?.toString();
        if (mounted && sid != null) {
          setState(() {
            _selectedSubjectId = sid;
            _selectedKnowledgeId = knowledgeId;
            _isCore = isCore;
          });
          await _loadKnowledge();
        }
      } else if (mounted) {
        setState(() => _isCore = isCore);
      }
    } catch (_) {
      if (mounted) setState(() => _loadingQuestion = false);
    }
  }

  Future<void> _loadKnowledge() async {
    final subjectId = _selectedSubjectId;
    if (subjectId == null) {
      setState(() => _knowledgeList = []);
      return;
    }
    setState(() => _loadingKnowledge = true);
    try {
      await triggerBackgroundSyncWithThrottle();
      if (!mounted) return;
      final client = Supabase.instance.client;
      final rows = await client
          .from('knowledge')
          .select('id, content')
          .eq('subject_id', subjectId)
          .order('display_order', ascending: true)
          .order('created_at', ascending: true);
      if (mounted) {
        setState(() {
          _knowledgeList = List<Map<String, dynamic>>.from(rows);
          _loadingKnowledge = false;
          final preferred = !_isEditMode ? widget.initialKnowledgeId : null;
          if (_selectedKnowledgeId == null &&
              preferred != null &&
              _knowledgeList.any((k) => k['id']?.toString() == preferred)) {
            _selectedKnowledgeId = preferred;
          }
          final inList = _knowledgeList.any((k) => k['id']?.toString() == _selectedKnowledgeId);
          if (!inList) {
            _selectedKnowledgeId = _knowledgeList.isNotEmpty ? _knowledgeList.first['id']?.toString() : null;
          }
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loadingKnowledge = false);
    }
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final questionText = _questionController.text.trim();
    if (questionText.isEmpty) return;
    final choices = _choiceControllers.map((c) => c.text.trim()).toList();
    if (choices.any((s) => s.isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('4つの選択肢をすべて入力してください')),
      );
      return;
    }
    final knowledgeId = _selectedKnowledgeId;
    if (knowledgeId == null || knowledgeId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('関連する知識を1つ選んでください')),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      final client = Supabase.instance.client;
      final correctAnswer = choices[_correctIndex];
      final explanation = _explanationController.text.trim().isEmpty ? null : _explanationController.text.trim();
      final reference = _referenceController.text.trim().isEmpty ? null : _referenceController.text.trim();

      if (_isEditMode) {
        final questionId = widget.questionId!;
        final updatePayload = <String, dynamic>{
          'question_text': questionText,
          'correct_answer': correctAnswer,
          'explanation': explanation,
          'dev_completed': _devCompleted,
        };
        if (reference != null) updatePayload['reference'] = reference;
        try {
          await client.from('questions').update(updatePayload).eq('id', questionId);
        } on PostgrestException catch (e) {
          if (e.code == '42703' || (e.message.contains('reference') && e.message.contains('does not exist'))) {
            if (e.message.contains('dev_completed')) updatePayload.remove('dev_completed');
            if (e.message.contains('reference') && e.message.contains('does not exist')) {
              updatePayload.remove('reference');
            }
            await client.from('questions').update(updatePayload).eq('id', questionId);
          } else {
            rethrow;
          }
        }

        try {
          await client.from('question_choices').delete().eq('question_id', questionId);
          for (var i = 0; i < 4; i++) {
            await client.from('question_choices').insert(
              QuestionChoice.toPayload(
                questionId: questionId,
                position: i + 1,
                choiceText: choices[i],
                isCorrect: i == _correctIndex,
              ),
            );
          }
        } on PostgrestException catch (e) {
          if (e.code == 'PGRST205' || e.message.contains('question_choices') || e.message.contains('schema cache')) {
            await client.from('questions').update({'choices': choices}).eq('id', questionId);
          } else {
            rethrow;
          }
        } catch (_) {
          await client.from('questions').update({'choices': choices}).eq('id', questionId);
        }
        try {
          await client.from('question_knowledge').delete().eq('question_id', questionId);
          await client.from('question_knowledge').insert({
            'question_id': questionId,
            'knowledge_id': knowledgeId,
            'is_core': _isCore,
          });
        } catch (_) {}
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('四択問題を更新しました')),
          );
          Navigator.of(context).pop(true);
        }
      } else {
        final insertPayload = <String, dynamic>{
          'knowledge_id': knowledgeId,
          'question_type': 'multiple_choice',
          'question_text': questionText,
          'correct_answer': correctAnswer,
          'explanation': explanation,
          'dev_completed': _devCompleted,
        };
        if (reference != null) insertPayload['reference'] = reference;
        dynamic inserted;
        try {
          inserted = await client.from('questions').insert(insertPayload).select('id').single();
        } on PostgrestException catch (e) {
          if (e.code == '42703' || (e.message.contains('reference') && e.message.contains('does not exist'))) {
            if (e.message.contains('dev_completed')) insertPayload.remove('dev_completed');
            if (e.message.contains('reference') && e.message.contains('does not exist')) {
              insertPayload.remove('reference');
            }
            inserted = await client.from('questions').insert(insertPayload).select('id').single();
          } else {
            rethrow;
          }
        }

        final questionId = inserted['id'] as String;

        try {
          for (var i = 0; i < 4; i++) {
            await client.from('question_choices').insert(
              QuestionChoice.toPayload(
                questionId: questionId,
                position: i + 1,
                choiceText: choices[i],
                isCorrect: i == _correctIndex,
              ),
            );
          }
        } catch (_) {
          await client.from('questions').update({'choices': choices}).eq('id', questionId);
        }

        try {
          await client.from('question_knowledge').insert({
            'question_id': questionId,
            'knowledge_id': knowledgeId,
            'is_core': _isCore,
          });
        } catch (_) {}

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('四択問題を作成しました')),
          );
          Navigator.of(context).pop(true);
        }
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

  Future<void> _deleteQuestion() async {
    final questionId = widget.questionId;
    if (!_isEditMode || questionId == null || questionId.isEmpty) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('四択問題を削除'),
        content: const Text('この問題を削除しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _saving = true);
    try {
      final client = Supabase.instance.client;
      try {
        await client.from('question_choices').delete().eq('question_id', questionId);
      } catch (_) {}
      try {
        await client.from('question_knowledge').delete().eq('question_id', questionId);
      } catch (_) {}
      await client.from('questions').delete().eq('id', questionId);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('四択問題を削除しました')),
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('削除エラー: $e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditMode ? '四択問題を編集' : '四択問題を作成'),
        actions: [
          if (_isEditMode)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '削除',
              onPressed: _saving ? null : _deleteQuestion,
            ),
        ],
      ),
      body: _loadingQuestion
          ? const Center(child: CircularProgressIndicator())
          : Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _questionController,
              decoration: const InputDecoration(
                labelText: '問題文',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
              maxLines: 3,
              validator: (v) => (v == null || v.trim().isEmpty) ? '問題文を入力してください' : null,
            ),
            const SizedBox(height: 16),
            const Text('選択肢（正解を1つ選んでください）', style: TextStyle(fontWeight: FontWeight.w500)),
            const SizedBox(height: 8),
            ...List.generate(4, (i) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Radio<int>(
                      value: i,
                      groupValue: _correctIndex,
                      onChanged: (v) => setState(() => _correctIndex = v ?? 0),
                    ),
                    Expanded(
                      child: TextFormField(
                        controller: _choiceControllers[i],
                        decoration: InputDecoration(
                          labelText: '選択肢 ${i + 1}',
                          border: const OutlineInputBorder(),
                          isDense: true,
                        ),
                        validator: (v) => (v == null || v.trim().isEmpty) ? '入力してください' : null,
                      ),
                    ),
                  ],
                ),
              );
            }),
            const SizedBox(height: 16),
            Text(
              '解説（任意）',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _explanationController,
              decoration: const InputDecoration(
                hintText: '正解に至る思考の流れを入力。改行できます。',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              ),
              maxLines: null,
              minLines: 10,
              textAlignVertical: TextAlignVertical.top,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 20),
            Text(
              '参考（任意）',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _referenceController,
              decoration: const InputDecoration(
                hintText: '学習者に補足として表示します。解説の後に別枠で表示。',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              ),
              maxLines: null,
              minLines: 4,
              textAlignVertical: TextAlignVertical.top,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 24),
            const Text('関連する知識', style: TextStyle(fontWeight: FontWeight.w500)),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: _selectedSubjectId,
              decoration: const InputDecoration(
                labelText: '科目',
                border: OutlineInputBorder(),
              ),
              items: _subjects.map((s) {
                final id = s['id']?.toString();
                final name = s['name']?.toString() ?? '';
                return DropdownMenuItem(value: id, child: Text(name));
              }).toList(),
              onChanged: _loadingSubjects
                  ? null
                  : (v) {
                      setState(() {
                        _selectedSubjectId = v;
                        _selectedKnowledgeId = null;
                      });
                      _loadKnowledge();
                    },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _selectedKnowledgeId,
              decoration: const InputDecoration(
                labelText: '知識カード',
                border: OutlineInputBorder(),
              ),
              items: _knowledgeList.map((k) {
                final id = k['id']?.toString();
                final content = k['content']?.toString() ?? '（タイトルなし）';
                return DropdownMenuItem(value: id, child: Text(content, overflow: TextOverflow.ellipsis));
              }).toList(),
              onChanged: _loadingKnowledge ? null : (v) => setState(() => _selectedKnowledgeId = v),
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              title: const Text('コア問題'),
              subtitle: const Text('オン: 習得判定に含める必須問題／オフ: 追加演習用'),
              value: _isCore,
              onChanged: (v) => setState(() => _isCore = v),
            ),
            SwitchListTile(
              title: const Text('完成（開発者確認済み）'),
              subtitle: const Text('AI 生成などのカードを、内容確認済みとしてマークします'),
              value: _devCompleted,
              onChanged: (v) => setState(() => _devCompleted = v),
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save),
              label: Text(_saving ? '保存中...' : (_isEditMode ? '更新' : '作成')),
            ),
          ],
        ),
      ),
    );
  }
}
