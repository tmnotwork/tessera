import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/english_example.dart';
import '../supabase/english_example_learning_state_remote.dart';
import '../sync/ensure_synced_for_local_read.dart';
import '../utils/english_example_review_filter.dart';
import 'english_example_solve_screen.dart';

/// 出題モードの種類
enum _StudyFilter {
  dueToday, // 今日が復習日のものだけ
  all,       // 全件
}

class EnglishExampleListScreen extends StatefulWidget {
  const EnglishExampleListScreen({
    super.key,
    this.subjectId,
    this.subjectName,
    this.isLearnerMode = false,
    this.readAloudMenuOnly = false,
  });

  final String? subjectId;
  final String? subjectName;

  /// true: 閲覧・出題のみ（教師向けの追加・編集は不可）
  final bool isLearnerMode;

  /// true かつ [isLearnerMode]: 一覧ではなく「チャプターごとに出題」「復習モード」の2メニューのみ表示
  final bool readAloudMenuOnly;

  @override
  State<EnglishExampleListScreen> createState() => _EnglishExampleListScreenState();
}

class _EnglishExampleListScreenState extends State<EnglishExampleListScreen> {
  final _client = Supabase.instance.client;

  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _knowledgeRows = [];

  /// example_id → 学習状態（learner のみ）
  Map<String, Map<String, dynamic>> _learningStates = {};

  bool _loading = true;
  bool _schemaMissing = false;
  String? _error;

  _StudyFilter _studyFilter = _StudyFilter.dueToday;

  String? get _learnerId => _client.auth.currentUser?.id;

  bool get _readAloudMenuOnly =>
      widget.isLearnerMode && widget.readAloudMenuOnly;

  @override
  void initState() {
    super.initState();
    _load();
  }

  // ──────────────────────────────
  // データ取得
  // ──────────────────────────────

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _schemaMissing = false;
      _error = null;
    });
    try {
      await ensureSyncedForLocalRead();
      if (!mounted) return;

      final knowledge = widget.subjectId == null
          ? await _client
              .from('knowledge')
              .select('id, content, unit')
              .order('display_order', ascending: true)
              .order('created_at', ascending: true)
          : await _client
              .from('knowledge')
              .select('id, content, unit')
              .eq('subject_id', widget.subjectId!)
              .order('display_order', ascending: true)
              .order('created_at', ascending: true);

      List<Map<String, dynamic>> examples = [];
      try {
        final rows = widget.subjectId == null
            ? await _client
                .from('english_examples')
                .select('id, knowledge_id, front_ja, back_en, explanation, supplement, display_order, '
                    'knowledge:knowledge_id(id, content, unit)')
                .order('display_order', ascending: true)
                .order('created_at', ascending: true)
            : await _client
                .from('english_examples')
                .select('id, knowledge_id, front_ja, back_en, explanation, supplement, display_order, '
                    'knowledge:knowledge_id(id, content, unit)')
                .eq('knowledge.subject_id', widget.subjectId!)
                .order('display_order', ascending: true)
                .order('created_at', ascending: true);
        examples = List<Map<String, dynamic>>.from(rows);
      } on PostgrestException catch (e) {
        final missingTable =
            e.code == 'PGRST205' && e.message.contains('public.english_examples');
        if (!missingTable) rethrow;
        if (!mounted) return;
        setState(() {
          _schemaMissing = true;
          _error = '英語例文DBのテーブルが未作成です。Supabase で migration 00016 を適用してください。';
        });
        return;
      }

      // 学習者モードのみ SM-2 状態を取得
      Map<String, Map<String, dynamic>> states = {};
      if (widget.isLearnerMode && _learnerId != null && examples.isNotEmpty) {
        final ids = examples.map((e) => e['id'] as String).toList();
        states = await EnglishExampleLearningStateRemote.fetchStates(
          client: _client,
          learnerId: _learnerId!,
          exampleIds: ids,
        );
      }

      if (!mounted) return;
      setState(() {
        _items = examples;
        _knowledgeRows = List<Map<String, dynamic>>.from(knowledge);
        _learningStates = states;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ──────────────────────────────
  // フィルタリング
  // ──────────────────────────────

  /// 表示対象の例文リスト（フィルター適用後）
  List<Map<String, dynamic>> get _filteredItems {
    if (!widget.isLearnerMode || _studyFilter == _StudyFilter.all) {
      return _items;
    }
    // 今日の復習: next_review_at が今日以前 or 未学習
    final todayEnd = DateTime.now().add(const Duration(days: 1));
    return _items.where((item) {
      final state = _learningStates[item['id'] as String?];
      if (state == null) return true; // 未学習は常に出題
      final nextReviewStr = state['next_review_at'] as String?;
      if (nextReviewStr == null) return true;
      final nextReview = DateTime.tryParse(nextReviewStr);
      if (nextReview == null) return true;
      return nextReview.isBefore(todayEnd);
    }).toList();
  }

  // ──────────────────────────────
  // 出題開始
  // ──────────────────────────────

  void _startSolve(
    List<Map<String, dynamic>> targetItems, {
    String? sessionDescriptor,
  }) {
    final examples =
        targetItems.map((e) => EnglishExample.fromRow(Map<String, dynamic>.from(e))).toList();

    final initialStates = <String, Map<String, dynamic>>{};
    for (final ex in examples) {
      final s = _learningStates[ex.id];
      if (s != null) initialStates[ex.id] = s;
    }

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => EnglishExampleSolveScreen(
          examples: examples,
          subjectName: widget.subjectName,
          sessionDescriptor: sessionDescriptor,
          initialStates: initialStates,
        ),
      ),
    ).then((_) => _load()); // 戻ったら状態を再読込
  }

  /// knowledge.unit（参考書チャプター）ごとにグループ化し、表示順の先頭が早い単元ほど上に並べる。
  List<MapEntry<String, List<Map<String, dynamic>>>> _chaptersOrdered() {
    final map = <String, List<Map<String, dynamic>>>{};
    for (final item in _items) {
      final u = _unitKeyFromItem(item);
      map.putIfAbsent(u, () => []).add(item);
    }
    int minDisplayOrder(List<Map<String, dynamic>> xs) {
      var m = 1 << 30;
      for (final e in xs) {
        final o = e['display_order'] as int?;
        if (o != null && o < m) m = o;
      }
      return m;
    }

    final entries = map.entries.toList()
      ..sort((a, b) => minDisplayOrder(a.value).compareTo(minDisplayOrder(b.value)));
    return entries;
  }

  static String _unitKeyFromItem(Map<String, dynamic> item) {
    final k = item['knowledge'];
    if (k is Map<String, dynamic>) {
      final u = k['unit']?.toString().trim();
      if (u != null && u.isNotEmpty) return u;
    }
    return '（単元なし）';
  }

  void _startReviewMode() {
    if (_learnerId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('復習モードはログイン後に利用できます。')),
      );
      return;
    }

    final targets = _items.where((item) {
      final id = item['id'] as String?;
      if (id == null) return false;
      return EnglishExampleReviewFilter.needsReview(_learningStates[id]);
    }).toList();

    if (targets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('復習モードの対象となる例文がありません。')),
      );
      return;
    }

    _startSolve(targets, sessionDescriptor: '復習モード');
  }

  Widget _buildReadAloudMenuBody() {
    if (_items.isEmpty) {
      return const Center(child: Text('この科目の例文はまだありません'));
    }

    final chapters = _chaptersOrdered();

    // スマホ含め常に縦一列：復習モード → 各チャプター名
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        ListTile(
          title: const Text('復習モード'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _loading ? null : _startReviewMode,
        ),
        for (final e in chapters) ...[
          const Divider(height: 1),
          ListTile(
            title: Text(
              e.key,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: _loading
                ? null
                : () {
                    final label = e.key;
                    _startSolve(
                      List<Map<String, dynamic>>.from(e.value),
                      sessionDescriptor: '単元「$label」',
                    );
                  },
          ),
        ],
      ],
    );
  }

  // ──────────────────────────────
  // 教師向け編集・削除
  // ──────────────────────────────

  String _knowledgeLabel(Map<String, dynamic> row) {
    final unit = row['unit']?.toString();
    final content = row['content']?.toString() ?? '';
    if (unit == null || unit.isEmpty) return content;
    return '$unit / $content';
  }

  Future<void> _openEditor({Map<String, dynamic>? current}) async {
    final messenger = ScaffoldMessenger.of(context);
    final candidates = List<Map<String, dynamic>>.from(_knowledgeRows);

    if (candidates.isEmpty) {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(
          content: Text('紐づけ可能な知識がありません。'),
          duration: Duration(seconds: 5),
        ),
      );
      return;
    }

    final frontController =
        TextEditingController(text: current?['front_ja']?.toString() ?? '');
    final backController =
        TextEditingController(text: current?['back_en']?.toString() ?? '');
    final explanationController =
        TextEditingController(text: current?['explanation']?.toString() ?? '');
    final supplementController =
        TextEditingController(text: current?['supplement']?.toString() ?? '');
    final orderController =
        TextEditingController(text: current?['display_order']?.toString() ?? '');
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
                        onChanged: (v) =>
                            setLocalState(() => selectedKnowledgeId = v),
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
        await _client
            .from('english_examples')
            .update(payload)
            .eq('id', current['id']);
      }
      if (!mounted) return;
      await _load();
      messenger.showSnackBar(
        SnackBar(content: Text(current == null ? '追加しました' : '保存しました')),
      );
    } on PostgrestException catch (e) {
      if (!mounted) return;
      final missingTable =
          e.code == 'PGRST205' && e.message.contains('public.english_examples');
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
      messenger.showSnackBar(SnackBar(content: Text('保存に失敗しました: $e')));
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
      messenger.showSnackBar(const SnackBar(content: Text('削除しました')));
    } on PostgrestException catch (e) {
      if (!mounted) return;
      final missingTable =
          e.code == 'PGRST205' && e.message.contains('public.english_examples');
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
      messenger.showSnackBar(SnackBar(content: Text('削除に失敗しました: $e')));
    }
  }

  // ──────────────────────────────
  // Build
  // ──────────────────────────────

  @override
  Widget build(BuildContext context) {
    final baseTitle = widget.subjectName == null || widget.subjectName!.isEmpty
        ? '英語例文'
        : '${widget.subjectName} · 英語例文';
    final title = widget.isLearnerMode ? baseTitle : '$baseTitle DB';

    final filtered = _filteredItems;
    final dueCount = widget.isLearnerMode ? _filteredItemsCount(_StudyFilter.dueToday) : 0;

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          if (widget.isLearnerMode && !_readAloudMenuOnly && _items.isNotEmpty) ...[
            _FilterToggleButton(
              current: _studyFilter,
              dueCount: dueCount,
              onChanged: (f) => setState(() => _studyFilter = f),
            ),
            if (filtered.isNotEmpty)
              TextButton.icon(
                onPressed: _loading ? null : () => _startSolve(filtered),
                icon: const Icon(Icons.record_voice_over),
                label: Text('読み上げ (${filtered.length})'),
              ),
          ],
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
                        Text('読み込みに失敗しました\n$_error',
                            textAlign: TextAlign.center),
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
              : _readAloudMenuOnly
                  ? _buildReadAloudMenuBody()
                  : filtered.isEmpty
                      ? _buildEmpty()
                      : ListView.separated(
                          itemCount: filtered.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, index) =>
                              _buildListItem(context, filtered[index]),
                        ),
    );
  }

  int _filteredItemsCount(_StudyFilter filter) {
    if (filter == _StudyFilter.all) return _items.length;
    final todayEnd = DateTime.now().add(const Duration(days: 1));
    return _items.where((item) {
      final state = _learningStates[item['id'] as String?];
      if (state == null) return true;
      final nextReviewStr = state['next_review_at'] as String?;
      if (nextReviewStr == null) return true;
      final nextReview = DateTime.tryParse(nextReviewStr);
      if (nextReview == null) return true;
      return nextReview.isBefore(todayEnd);
    }).length;
  }

  Widget _buildEmpty() {
    if (widget.isLearnerMode && _studyFilter == _StudyFilter.dueToday && _items.isNotEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle_outline, size: 64, color: Colors.green),
            const SizedBox(height: 16),
            const Text('今日の復習はすべて完了しました！', style: TextStyle(fontSize: 16)),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => setState(() => _studyFilter = _StudyFilter.all),
              child: const Text('全件を表示する'),
            ),
          ],
        ),
      );
    }
    return const Center(child: Text('この科目の例文はまだありません'));
  }

  Widget _buildListItem(BuildContext context, Map<String, dynamic> item) {
    final knowledge = item['knowledge'] as Map<String, dynamic>?;
    final knowledgeTitle = knowledge?['content']?.toString();
    final frontJa = item['front_ja']?.toString() ?? '';
    final backEn = item['back_en']?.toString() ?? '';
    final exampleId = item['id'] as String?;
    final state = exampleId != null ? _learningStates[exampleId] : null;

    return ListTile(
      title: Text(frontJa, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!widget.isLearnerMode && backEn.isNotEmpty)
            Text(backEn, maxLines: 1, overflow: TextOverflow.ellipsis),
          if ((knowledgeTitle ?? '').isNotEmpty)
            Text('知識: $knowledgeTitle', maxLines: 1, overflow: TextOverflow.ellipsis),
          if (widget.isLearnerMode && state != null)
            _buildStateLine(state),
        ],
      ),
      isThreeLine: widget.isLearnerMode && state != null,
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
          _startSolve([item]);
        } else {
          _openEditor(current: item);
        }
      },
    );
  }

  /// リスト行の学習状況テキスト
  Widget _buildStateLine(Map<String, dynamic> state) {
    final rep = (state['repetitions'] as int?) ?? 0;
    final nextReviewStr = state['next_review_at'] as String?;
    String nextLabel = '未設定';
    if (nextReviewStr != null) {
      final dt = DateTime.tryParse(nextReviewStr)?.toLocal();
      if (dt != null) {
        final diff = dt.difference(DateTime.now()).inDays;
        nextLabel = diff <= 0 ? '今日' : '$diff日後';
      }
    }
    return Text(
      '連続正解 $rep 回 · 次回 $nextLabel',
      style: const TextStyle(fontSize: 11, color: Colors.grey),
    );
  }
}

// ──────────────────────────────────────────────
// フィルタートグルボタン
// ──────────────────────────────────────────────

class _FilterToggleButton extends StatelessWidget {
  const _FilterToggleButton({
    required this.current,
    required this.dueCount,
    required this.onChanged,
  });

  final _StudyFilter current;
  final int dueCount;
  final ValueChanged<_StudyFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    final isDue = current == _StudyFilter.dueToday;
    return TextButton.icon(
      onPressed: () =>
          onChanged(isDue ? _StudyFilter.all : _StudyFilter.dueToday),
      icon: Icon(isDue ? Icons.today : Icons.list),
      label: Text(isDue ? '今日($dueCount)' : '全件'),
    );
  }
}
