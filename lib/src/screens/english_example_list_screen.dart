import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/english_example.dart';
import 'english_example_solve_screen.dart';

class EnglishExampleListScreen extends StatefulWidget {
  const EnglishExampleListScreen({
    super.key,
    required this.subjectId,
    required this.subjectName,
    this.isLearnerMode = false,
  });

  final String subjectId;
  final String subjectName;
  /// true: 閲覧・出題のみ（教師向けの追加・編集は不可）
  final bool isLearnerMode;

  @override
  State<EnglishExampleListScreen> createState() => _EnglishExampleListScreenState();
}

class _EnglishExampleListScreenState extends State<EnglishExampleListScreen> {
  final _client = Supabase.instance.client;
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _knowledgeRows = [];
  bool _loading = true;
  bool _schemaMissing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _schemaMissing = false;
      _error = null;
    });
    try {
      final knowledge = await _client
          .from('knowledge')
          .select('id, content, unit')
          .eq('subject_id', widget.subjectId)
          .order('display_order', ascending: true)
          .order('created_at', ascending: true);

      List<Map<String, dynamic>> examples = [];
      try {
        final rows = await _client
            .from('english_examples')
            .select('id, knowledge_id, front_ja, back_en, explanation, supplement, display_order, '
                'knowledge:knowledge_id(id, content, unit)')
            .eq('knowledge.subject_id', widget.subjectId)
            .order('display_order', ascending: true)
            .order('created_at', ascending: true);
        examples = List<Map<String, dynamic>>.from(rows);
      } on PostgrestException catch (e) {
        final missingTable = e.code == 'PGRST205' &&
            e.message.contains("public.english_examples");
        if (!missingTable) rethrow;
        if (!mounted) return;
        setState(() {
          _schemaMissing = true;
          _error =
              '英語例文DBのテーブルが未作成です。Supabase で migration 00016 を適用してください。';
        });
      }

      if (!mounted) return;
      setState(() {
        _items = examples;
        _knowledgeRows = List<Map<String, dynamic>>.from(knowledge);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _knowledgeLabel(Map<String, dynamic> row) {
    final unit = row['unit']?.toString();
    final content = row['content']?.toString() ?? '';
    if (unit == null || unit.isEmpty) return content;
    return '$unit / $content';
  }

  Future<void> _openEditor({Map<String, dynamic>? current}) async {
    final messenger = ScaffoldMessenger.of(context);
    final usedKnowledgeIds = _items
        .where((e) => e['id'] != current?['id'])
        .map((e) => e['knowledge_id']?.toString())
        .whereType<String>()
        .toSet();

    final candidates = _knowledgeRows
        .where((k) => !usedKnowledgeIds.contains(k['id']?.toString()))
        .toList();

    if (current == null && candidates.isEmpty) {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(
          content: Text('紐づけ可能な知識がありません（各知識は1件の例文のみ登録可能です）。'),
          duration: Duration(seconds: 5),
        ),
      );
      return;
    }

    final frontController = TextEditingController(text: current?['front_ja']?.toString() ?? '');
    final backController = TextEditingController(text: current?['back_en']?.toString() ?? '');
    final explanationController = TextEditingController(text: current?['explanation']?.toString() ?? '');
    final supplementController = TextEditingController(text: current?['supplement']?.toString() ?? '');
    final orderController = TextEditingController(text: current?['display_order']?.toString() ?? '');
    String? selectedKnowledgeId = current?['knowledge_id']?.toString() ??
        (candidates.isNotEmpty ? candidates.first['id']?.toString() : null);

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(current == null ? '英語例文を追加' : '英語例文を編集'),
          content: StatefulBuilder(
            builder: (ctx, setLocalState) {
              return SizedBox(
                width: 640,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      DropdownButtonFormField<String>(
                        initialValue: selectedKnowledgeId,
                        decoration: const InputDecoration(
                          labelText: '対応する知識',
                          border: OutlineInputBorder(),
                        ),
                        items: candidates
                            .map(
                              (k) => DropdownMenuItem<String>(
                                value: k['id'].toString(),
                                child: Text(
                                  _knowledgeLabel(k),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (v) => setLocalState(() => selectedKnowledgeId = v),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: frontController,
                        minLines: 2,
                        maxLines: 5,
                        decoration: const InputDecoration(
                          labelText: '表（日本語）',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: backController,
                        minLines: 2,
                        maxLines: 5,
                        decoration: const InputDecoration(
                          labelText: '裏（英語）',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: explanationController,
                        minLines: 2,
                        maxLines: 6,
                        decoration: const InputDecoration(
                          labelText: '解説',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: supplementController,
                        minLines: 1,
                        maxLines: 4,
                        decoration: const InputDecoration(
                          labelText: '補足',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: orderController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: '表示順（任意）',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );

    if (saved != true || !mounted) return;

    final frontJa = frontController.text.trim();
    final backEn = backController.text.trim();
    final explanation = explanationController.text.trim();
    final supplement = supplementController.text.trim();
    final displayOrder = int.tryParse(orderController.text.trim());
    final knowledgeId = selectedKnowledgeId;

    frontController.dispose();
    backController.dispose();
    explanationController.dispose();
    supplementController.dispose();
    orderController.dispose();

    if (knowledgeId == null || frontJa.isEmpty || backEn.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('「対応する知識」「表（日本語）」「裏（英語）」は必須です。')),
      );
      return;
    }

    try {
      final payload = <String, dynamic>{
        'knowledge_id': knowledgeId,
        'front_ja': frontJa,
        'back_en': backEn,
        'explanation': explanation.isEmpty ? null : explanation,
        'supplement': supplement.isEmpty ? null : supplement,
        'display_order': displayOrder,
      };
      if (current == null) {
        await _client.from('english_examples').insert(payload);
      } else {
        await _client.from('english_examples').update(payload).eq('id', current['id']);
      }
      if (!mounted) return;
      await _load();
      messenger.showSnackBar(
        SnackBar(content: Text(current == null ? '追加しました' : '保存しました')),
      );
    } on PostgrestException catch (e) {
      if (!mounted) return;
      final missingTable = e.code == 'PGRST205' && e.message.contains("public.english_examples");
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            missingTable
                ? '英語例文DBのテーブルが未作成です。migration 00016 を適用してください。'
                : '保存に失敗しました: $e',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('保存に失敗しました: $e')),
      );
    }
  }

  Future<void> _delete(Map<String, dynamic> row) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('例文を削除'),
        content: const Text('この例文を削除しますか？'),
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

    try {
      await _client.from('english_examples').delete().eq('id', row['id']);
      if (!mounted) return;
      await _load();
      messenger.showSnackBar(
        const SnackBar(content: Text('削除しました')),
      );
    } on PostgrestException catch (e) {
      if (!mounted) return;
      final missingTable = e.code == 'PGRST205' && e.message.contains("public.english_examples");
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            missingTable
                ? '英語例文DBのテーブルが未作成です。migration 00016 を適用してください。'
                : '削除に失敗しました: $e',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('削除に失敗しました: $e')),
      );
    }
  }

  List<EnglishExample> get _examplesAsModels =>
      _items.map((e) => EnglishExample.fromRow(Map<String, dynamic>.from(e))).toList();

  @override
  Widget build(BuildContext context) {
    final title = widget.isLearnerMode
        ? '${widget.subjectName} · 英語例文'
        : '${widget.subjectName} / 英語例文DB';
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          if (widget.isLearnerMode && _items.isNotEmpty)
            TextButton.icon(
              onPressed: _loading
                  ? null
                  : () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (context) => EnglishExampleSolveScreen(
                            examples: _examplesAsModels,
                            subjectName: widget.subjectName,
                          ),
                        ),
                      );
                    },
              icon: const Icon(Icons.quiz),
              label: const Text('出題'),
            ),
          IconButton(
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
            tooltip: '再読み込み',
          ),
        ],
      ),
      floatingActionButton: widget.isLearnerMode
          ? null
          : FloatingActionButton.extended(
              onPressed: _loading || _schemaMissing ? null : () => _openEditor(),
              icon: const Icon(Icons.add),
              label: const Text('追加'),
            ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('読み込みに失敗しました\n$_error', textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: _load,
                          icon: const Icon(Icons.refresh),
                          label: const Text('再試行'),
                        ),
                      ],
                    ),
                  ),
                )
              : _items.isEmpty
                  ? const Center(child: Text('この科目の例文はまだありません'))
                  : ListView.separated(
                      itemCount: _items.length,
                      separatorBuilder: (context, index) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final item = _items[index];
                        final knowledge = item['knowledge'] as Map<String, dynamic>?;
                        final knowledgeTitle = knowledge?['content']?.toString();
                        final frontJa = item['front_ja']?.toString() ?? '';
                        final backEn = item['back_en']?.toString() ?? '';
                        return ListTile(
                          title: Text(
                            frontJa,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            [
                              if (!widget.isLearnerMode && backEn.isNotEmpty) backEn,
                              if ((knowledgeTitle ?? '').isNotEmpty) '知識: $knowledgeTitle',
                            ].join('\n'),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: widget.isLearnerMode
                              ? const Icon(Icons.chevron_right)
                              : PopupMenuButton<String>(
                                  onSelected: (v) {
                                    if (v == 'edit') _openEditor(current: item);
                                    if (v == 'delete') _delete(item);
                                  },
                                  itemBuilder: (context) => const [
                                    PopupMenuItem(value: 'edit', child: Text('編集')),
                                    PopupMenuItem(value: 'delete', child: Text('削除')),
                                  ],
                                ),
                          onTap: () {
                            if (widget.isLearnerMode) {
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (context) => EnglishExampleSolveScreen(
                                    examples: [EnglishExample.fromRow(Map<String, dynamic>.from(item))],
                                    subjectName: widget.subjectName,
                                  ),
                                ),
                              );
                            } else {
                              _openEditor(current: item);
                            }
                          },
                        );
                      },
                    ),
    );
  }
}
