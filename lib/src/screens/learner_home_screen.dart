import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app_scope.dart';
import 'knowledge_list_screen.dart';
import 'memorization_list_screen.dart';
import 'question_solve_screen.dart';
import 'settings_screen.dart';

/// 学習者向けホーム画面
/// 知識を学ぶ / 四択問題を解く / 暗記カード の入口
class LearnerHomeScreen extends StatefulWidget {
  const LearnerHomeScreen({super.key, this.onOpenManage});

  /// 教材管理（編集）画面へ遷移するときに呼ぶ。未指定の場合は何もしない。
  final VoidCallback? onOpenManage;

  @override
  State<LearnerHomeScreen> createState() => _LearnerHomeScreenState();
}

class _LearnerHomeScreenState extends State<LearnerHomeScreen> {
  List<Map<String, dynamic>> _subjects = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetchSubjects();
  }

  Future<void> _fetchSubjects() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = Supabase.instance.client;
      final rows = await client.from('subjects').select().order('display_order');
      if (mounted) {
        setState(() {
          _subjects = List<Map<String, dynamic>>.from(rows);
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _openKnowledgePicker() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => _LearnerSubjectPicker(
          subjects: _subjects,
          title: '知識を学ぶ',
          mode: _LearnerPickMode.knowledge,
        ),
      ),
    );
  }

  void _openFourChoiceSolve() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => const LearnerFourChoiceSolveScreen(),
      ),
    );
  }

  void _openMemorizationPicker() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => _LearnerSubjectPicker(
          subjects: _subjects,
          title: '暗記カード',
          mode: _LearnerPickMode.memorization,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('学習'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => const SettingsScreen(),
                ),
              );
            },
            tooltip: '設定',
          ),
          if (widget.onOpenManage != null)
            TextButton.icon(
              onPressed: widget.onOpenManage,
              icon: const Icon(Icons.edit_note, size: 20),
              label: const Text('教材管理'),
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _fetchSubjects,
            tooltip: '再読み込み',
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'ログアウト',
            onPressed: () async {
              await appAuthNotifier.logout();
            },
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
                        Text(_error!, style: Theme.of(context).textTheme.bodyMedium, textAlign: TextAlign.center),
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
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _MenuCard(
                      icon: Icons.menu_book,
                      title: '知識を学ぶ',
                      subtitle: '解説付きの知識カードを読む',
                      onTap: _openKnowledgePicker,
                    ),
                    const SizedBox(height: 12),
                    _MenuCard(
                      icon: Icons.quiz,
                      title: '四択問題を解く',
                      subtitle: '四択クイズに挑戦する',
                      onTap: _openFourChoiceSolve,
                    ),
                    const SizedBox(height: 12),
                    _MenuCard(
                      icon: Icons.style,
                      title: '暗記カード',
                      subtitle: '表・裏の暗記カードで覚える',
                      onTap: _openMemorizationPicker,
                    ),
                  ],
                ),
    );
  }
}

enum _LearnerPickMode { knowledge, memorization }

class _LearnerSubjectPicker extends StatelessWidget {
  const _LearnerSubjectPicker({
    required this.subjects,
    required this.title,
    required this.mode,
  });

  final List<Map<String, dynamic>> subjects;
  final String title;
  final _LearnerPickMode mode;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: subjects.isEmpty
          ? const Center(child: Text('科目がありません'))
          : ListView.separated(
              itemCount: subjects.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final s = subjects[index];
                final subjectId = s['id'] as String?;
                final subjectName = s['name']?.toString() ?? '科目';
                if (subjectId == null) return const SizedBox.shrink();
                return ListTile(
                  title: Text(subjectName),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    if (mode == _LearnerPickMode.knowledge) {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) => KnowledgeListScreen(
                            subjectId: subjectId,
                            subjectName: subjectName,
                          ),
                        ),
                      );
                    } else {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) => MemorizationListScreen(
                            subjectId: subjectId,
                            subjectName: subjectName,
                          ),
                        ),
                      );
                    }
                  },
                );
              },
            ),
    );
  }
}

/// 学習者向け：四択問題を解く画面（問題ID一覧 → 解く）
class LearnerFourChoiceSolveScreen extends StatefulWidget {
  const LearnerFourChoiceSolveScreen({super.key});

  @override
  State<LearnerFourChoiceSolveScreen> createState() => _LearnerFourChoiceSolveScreenState();
}

class _LearnerFourChoiceSolveScreenState extends State<LearnerFourChoiceSolveScreen> {
  List<String> _questionIds = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = Supabase.instance.client;
      final rows = await client
          .from('questions')
          .select('id')
          .eq('question_type', 'multiple_choice')
          .order('created_at', ascending: false);
      if (mounted) {
        setState(() {
          _questionIds = (rows as List)
              .map((r) => (r as Map<String, dynamic>)['id']?.toString())
              .where((id) => id != null && id.isNotEmpty)
              .cast<String>()
              .toList();
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _startSolve() {
    if (_questionIds.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => QuestionSolveScreen(
          questionIds: _questionIds,
          knowledgeTitle: '四択問題',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('四択問題を解く'),
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
                        Text(_error!, style: Theme.of(context).textTheme.bodyMedium, textAlign: TextAlign.center),
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
              : _questionIds.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.quiz, size: 64, color: Theme.of(context).colorScheme.outline),
                          const SizedBox(height: 16),
                          Text(
                            '四択問題がまだありません',
                            style: Theme.of(context).textTheme.bodyLarge,
                          ),
                        ],
                      ),
                    )
                  : Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            '${_questionIds.length} 問あります。',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 24),
                          FilledButton.icon(
                            onPressed: _startSolve,
                            icon: const Icon(Icons.play_arrow),
                            label: const Text('問題を解く'),
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                            ),
                          ),
                        ],
                      ),
                    ),
    );
  }
}

class _MenuCard extends StatelessWidget {
  const _MenuCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.6),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, size: 28, color: Theme.of(context).colorScheme.onPrimaryContainer),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: Theme.of(context).colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
