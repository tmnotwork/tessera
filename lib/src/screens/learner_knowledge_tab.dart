import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../database/local_database.dart';
import '../repositories/subject_repository.dart';
import 'knowledge_list_screen.dart';

/// 参考書タブ：科目一覧から知識カードへ（学習者モード）
class LearnerKnowledgeTab extends StatefulWidget {
  const LearnerKnowledgeTab({super.key, this.localDatabase});

  final LocalDatabase? localDatabase;

  @override
  State<LearnerKnowledgeTab> createState() => _LearnerKnowledgeTabState();
}

class _LearnerKnowledgeTabState extends State<LearnerKnowledgeTab> {
  List<Map<String, dynamic>> _subjects = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fetchSubjects();
    });
  }

  Future<void> _fetchSubjects() async {
    if (mounted) setState(() { _loading = true; _error = null; });
    try {
      if (widget.localDatabase != null) {
        final repo = createSubjectRepository(widget.localDatabase);
        final rows = await repo.getSubjectsOrderByDisplayOrder();
        if (mounted) setState(() { _subjects = rows; _loading = false; });
      } else {
        final rows = await Supabase.instance.client
            .from('subjects')
            .select()
            .order('display_order');
        if (mounted) {
          setState(() {
            _subjects = List<Map<String, dynamic>>.from(rows);
            _loading = false;
          });
        }
      }
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('参考書'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _fetchSubjects,
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
                        Text(_error!,
                            style: Theme.of(context).textTheme.bodyMedium,
                            textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: _fetchSubjects,
                          icon: const Icon(Icons.refresh),
                          label: const Text('再試行'),
                        ),
                      ],
                    ),
                  ),
                )
              : _subjects.isEmpty
                  ? const Center(child: Text('科目がありません'))
                  : ListView.separated(
                      itemCount: _subjects.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final s = _subjects[index];
                        final subjectId = s['id'] as String?;
                        final subjectName = s['name']?.toString() ?? '科目';
                        if (subjectId == null) return const SizedBox.shrink();
                        return ListTile(
                          title: Text(subjectName),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => KnowledgeListScreen(
                                  subjectId: subjectId,
                                  subjectName: subjectName,
                                  localDatabase: widget.localDatabase,
                                  isLearnerMode: true,
                                ),
                              ),
                            );
                          },
                        );
                      },
                    ),
    );
  }
}
