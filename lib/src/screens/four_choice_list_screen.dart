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

class _FourChoiceListScreenState extends State<FourChoiceListScreen> {
  List<Map<String, dynamic>> _items = [];
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
      _loading = _items.isEmpty;
      _error = null;
    });
    try {
      await triggerBackgroundSyncWithThrottle();
      final client = Supabase.instance.client;
      final rows = await client
          .from('questions')
          .select('id, question_text, question_type, correct_answer, created_at')
          .eq('question_type', 'multiple_choice')
          .order('created_at', ascending: false);

      setState(() {
        _items = List<Map<String, dynamic>>.from(rows);
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

  @override
  Widget build(BuildContext context) {
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
                        Text(_error!, style: Theme.of(context).textTheme.bodyMedium),
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
              : _items.isEmpty
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
                  : ListView.builder(
                      itemCount: _items.length,
                      itemBuilder: (context, index) {
                        final q = _items[index];
                        final text = q['question_text']?.toString() ?? '（問題文なし）';
                        final questionId = q['id']?.toString();
                        return ListTile(
                          title: Text(
                            text,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text('正答: ${q['correct_answer'] ?? ''}'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: questionId != null
                              ? () async {
                                  final updated = await Navigator.of(context).push<bool>(
                                    MaterialPageRoute(
                                      builder: (context) => FourChoiceCreateScreen(questionId: questionId),
                                    ),
                                  );
                                  if (updated == true && mounted) await _load();
                                }
                              : null,
                        );
                      },
                    ),
      floatingActionButton: FloatingActionButton(
        onPressed: _openCreate,
        tooltip: '四択問題を追加',
        child: const Icon(Icons.add),
      ),
    );
  }
}
