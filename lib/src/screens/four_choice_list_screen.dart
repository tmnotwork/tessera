import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../sync/ensure_synced_for_local_read.dart';
import 'four_choice_create_screen.dart';

/// 四択問題一覧（教材管理から開く）
class FourChoiceListScreen extends StatefulWidget {
  const FourChoiceListScreen({super.key});

  @override
  State<FourChoiceListScreen> createState() => _FourChoiceListScreenState();
}

class _ListedQuestion {
  const _ListedQuestion({
    required this.raw,
    required this.chapterTitle,
    required this.knowledgeDisplayOrder,
  });

  final Map<String, dynamic> raw;
  final String chapterTitle;
  final int knowledgeDisplayOrder;
}

class _ChapterSection {
  const _ChapterSection({required this.title, required this.questions});

  final String title;
  final List<_ListedQuestion> questions;
}

class _FourChoiceListScreenState extends State<FourChoiceListScreen> {
  List<_ChapterSection> _sections = [];
  bool _loading = true;
  String? _error;
  bool _isLoadInFlight = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_isLoadInFlight) return;
    _isLoadInFlight = true;
    setState(() {
      _loading = _sections.isEmpty;
      _error = null;
    });
    try {
      await triggerBackgroundSyncWithThrottle();
      final client = Supabase.instance.client;
      final rows = await client
          .from('questions')
          .select(
            'id, question_text, question_type, correct_answer, created_at, knowledge_id',
          )
          .eq('question_type', 'multiple_choice')
          .order('created_at', ascending: false);

      final items = List<Map<String, dynamic>>.from(rows);
      final qIds = items
          .map((e) => e['id']?.toString())
          .whereType<String>()
          .toList();

      final junctionFirst = <String, String>{};
      if (qIds.isNotEmpty) {
        final jRows = await client
            .from('question_knowledge')
            .select('question_id, knowledge_id')
            .inFilter('question_id', qIds);
        for (final raw in jRows as List) {
          final r = raw as Map<String, dynamic>;
          final qid = r['question_id']?.toString();
          final kid = r['knowledge_id']?.toString();
          if (qid != null &&
              kid != null &&
              kid.isNotEmpty &&
              !junctionFirst.containsKey(qid)) {
            junctionFirst[qid] = kid;
          }
        }
      }

      final knowledgeIds = <String>{};
      for (final q in items) {
        final id = q['id']?.toString();
        if (id == null) continue;
        var kid = q['knowledge_id']?.toString();
        if (kid == null || kid.isEmpty) kid = junctionFirst[id];
        if (kid != null && kid.isNotEmpty) knowledgeIds.add(kid);
      }

      final knowledgeById = <String, Map<String, dynamic>>{};
      if (knowledgeIds.isNotEmpty) {
        final kRows = await client
            .from('knowledge')
            .select('id, unit, display_order')
            .inFilter('id', knowledgeIds.toList());
        for (final raw in kRows as List) {
          final r = raw as Map<String, dynamic>;
          final id = r['id']?.toString();
          if (id != null) knowledgeById[id] = r;
        }
      }

      final listed = <_ListedQuestion>[];
      for (final q in items) {
        final qid = q['id']?.toString();
        if (qid == null) continue;
        var kid = q['knowledge_id']?.toString();
        if (kid == null || kid.isEmpty) kid = junctionFirst[qid];
        final krow = kid != null ? knowledgeById[kid] : null;
        if (krow == null) {
          listed.add(
            _ListedQuestion(
              raw: q,
              chapterTitle: '（知識未紐づけ）',
              knowledgeDisplayOrder: 1 << 30,
            ),
          );
          continue;
        }
        final unitRaw = krow['unit']?.toString().trim();
        final chapterTitle =
            (unitRaw != null && unitRaw.isNotEmpty) ? unitRaw : 'その他';
        final dispOrder = (krow['display_order'] as num?)?.toInt() ?? 1 << 30;
        listed.add(
          _ListedQuestion(
            raw: q,
            chapterTitle: chapterTitle,
            knowledgeDisplayOrder: dispOrder,
          ),
        );
      }

      final groups = <String, List<_ListedQuestion>>{};
      for (final l in listed) {
        groups.putIfAbsent(l.chapterTitle, () => []).add(l);
      }

      final chapterTitles = groups.keys.toList()
        ..sort((a, b) {
          final listA = groups[a]!;
          final listB = groups[b]!;
          final minA = listA
              .map((x) => x.knowledgeDisplayOrder)
              .reduce(math.min);
          final minB = listB
              .map((x) => x.knowledgeDisplayOrder)
              .reduce(math.min);
          final c = minA.compareTo(minB);
          if (c != 0) return c;
          return a.compareTo(b);
        });

      final sections = <_ChapterSection>[];
      for (final title in chapterTitles) {
        final qs = groups[title]!
          ..sort((a, b) {
            final o = a.knowledgeDisplayOrder.compareTo(b.knowledgeDisplayOrder);
            if (o != 0) return o;
            final ca = a.raw['created_at']?.toString() ?? '';
            final cb = b.raw['created_at']?.toString() ?? '';
            return cb.compareTo(ca);
          });
        sections.add(_ChapterSection(title: title, questions: qs));
      }

      setState(() {
        _sections = sections;
        _loading = false;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
      _isLoadInFlight = false;
    }
  }

  Future<void> _openCreate() async {
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (context) => const FourChoiceCreateScreen(),
      ),
    );
    if (created == true && mounted) await _load();
  }

  Future<void> _openEdit(String questionId) async {
    final updated = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (context) => FourChoiceCreateScreen(questionId: questionId),
      ),
    );
    if (updated == true && mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('四択問題'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
            tooltip: '再読み込み',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      _error!,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                      label: const Text('再試行'),
                    ),
                  ],
                ),
              ),
            )
          : _sections.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('四択問題がありません'),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _openCreate,
                    icon: const Icon(Icons.add),
                    label: const Text('最初の四択問題を作成'),
                  ),
                ],
              ),
            )
          : ListView(
              children: [
                for (final sec in _sections) ...[
                  Material(
                    color: scheme.surfaceContainerHighest,
                    child: ListTile(
                      dense: true,
                      title: Text(
                        sec.title,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                    ),
                  ),
                  ...sec.questions.map((lq) {
                    final qid = lq.raw['id']?.toString();
                    return ListTile(
                      title: Text(
                        lq.raw['question_text']?.toString() ?? '（問題文なし）',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '正答: ${lq.raw['correct_answer'] ?? ''}',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: qid != null ? () => _openEdit(qid) : null,
                    );
                  }),
                ],
              ],
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _openCreate,
        tooltip: '四択問題を追加',
        child: const Icon(Icons.add),
      ),
    );
  }
}
