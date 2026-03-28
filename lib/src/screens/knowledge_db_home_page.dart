import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';

import '../database/local_database.dart';
import '../repositories/subject_repository.dart';
import '../sync/ensure_synced_for_local_read.dart';
import '../widgets/force_sync_icon_button.dart';
import 'knowledge_list_screen.dart';

/// 起動時初期画面：知識DB の科目一覧（タップでその科目の知識カード一覧へ）
/// 表示されるのはログイン後のみ（未ログイン時はタブ自体を出さない）。
class KnowledgeDbHomePage extends StatefulWidget {
  const KnowledgeDbHomePage({super.key, this.localDb, this.localDatabase});

  final Database? localDb;
  final LocalDatabase? localDatabase;

  @override
  State<KnowledgeDbHomePage> createState() => _KnowledgeDbHomePageState();
}

class _KnowledgeDbHomePageState extends State<KnowledgeDbHomePage> {
  List<Map<String, dynamic>> _subjects = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    // 初回取得は1フレーム遅らせ、ログイン直後のセッション確実反映後に実行する
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fetchSubjects();
    });
  }

  Future<void> _fetchSubjects() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ensureSyncedForLocalRead();
      if (!mounted) return;
      final repo = createSubjectRepository(widget.localDatabase);
      final rows = await repo.getSubjectsOrderByDisplayOrder();
      if (mounted) {
        setState(() {
          _subjects = rows;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString());
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('知識DB'),
        actions: [
          const ForceSyncIconButton(),
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
                        Text(_error!, style: Theme.of(context).textTheme.bodyMedium),
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
                              separatorBuilder: (context, index) => const Divider(height: 1),
                              itemBuilder: (context, index) {
                                final s = _subjects[index];
                                final subjectId = s['id'] as String?;
                                final subjectName = s['name']?.toString() ?? '知識カード';
                                if (subjectId == null) return const SizedBox.shrink();
                                return ListTile(
                                  title: Text(subjectName),
                                  trailing: const Icon(Icons.chevron_right),
                                  onTap: () {
                                    Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (context) => KnowledgeListScreen(
                                          subjectId: subjectId,
                                          subjectName: subjectName,
                                          localDatabase: widget.localDatabase,
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
