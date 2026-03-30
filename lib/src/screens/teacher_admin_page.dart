import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../asset_import.dart';
import '../database/local_database.dart';
import '../sync/sync_engine.dart';
import '../widgets/force_sync_icon_button.dart';
import 'english_example_list_screen.dart';
import 'four_choice_list_screen.dart';
import 'knowledge_list_screen.dart';
import 'learner_management_screen.dart';
import 'settings_screen.dart';
import 'study_time_summary_screen.dart';
import 'subject_picker_page.dart';

/// 教師（管理者）向け管理画面
class TeacherAdminPage extends StatefulWidget {
  const TeacherAdminPage({
    super.key,
    this.localDb,
    this.localDatabase,
    this.onRefreshAuthAndRetry,
  });

  final Database? localDb;
  final LocalDatabase? localDatabase;
  /// 権限キャッシュをクリアして親で再取得する。科目が空のときの「データを再取得」で使用。
  final Future<void> Function()? onRefreshAuthAndRetry;

  @override
  State<TeacherAdminPage> createState() => _TeacherAdminPageState();
}

class _TeacherAdminPageState extends State<TeacherAdminPage> {
  bool _loading = false;
  String? _error;
  List<Map<String, dynamic>> _subjects = [];

  /// 勉強時間セッションは Windows デスクトップの教師用管理からのみ開く（モバイルの学習状況メニューには出さない）。
  bool get _showStudyTimeSummaryMenu =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  @override
  void initState() {
    super.initState();
    // 初回取得は1フレーム遅らせ、ログイン直後のセッション確実反映後に実行する
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fetchSubjects();
    });
  }

  Future<void> _fetchSubjects() async {
    setState(() => _loading = true);
    setState(() => _error = null);
    try {
      final client = Supabase.instance.client;
      final rows = await client.from('subjects').select().order('display_order');
      if (mounted) {
        setState(() {
          _subjects = List<Map<String, dynamic>>.from(rows);
          _error = null;
        });
      }
    } catch (e, stack) {
      if (mounted) {
        setState(() => _error = '${e.runtimeType}: ${e.toString()}\n\n$stack');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Supabase 接続と DB の有無を確認する（詳細表示用）
  Future<void> _testConnection() async {
    setState(() => _loading = true);
    setState(() => _error = null);
    try {
      final client = Supabase.instance.client;
      final row = await client.from('subjects').select('id').limit(1).maybeSingle();
      if (mounted) {
        if (row != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('接続成功: Supabase に接続できました。')),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('接続できましたが、科目が0件です。RLS・権限または接続先プロジェクトを確認してください。'),
            ),
          );
        }
        await _fetchSubjects();
      }
    } catch (e, stack) {
      if (mounted) {
        setState(() => _error =
            '接続テスト結果:\n'
            '${e.runtimeType}: ${e.toString()}\n\n'
            'StackTrace:\n$stack\n\n'
            '--- 上記をコピーして共有してください ---');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _showAddSubjectDialog() async {
    final nameController = TextEditingController();
    final orderController = TextEditingController(
      text: (_subjects.length + 1).toString(),
    );

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('科目を追加'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '科目名（例: 英文法 / 英単語 / 世界史）',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: orderController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '表示順',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('追加'),
          ),
        ],
      ),
    );

    nameController.dispose();
    orderController.dispose();

    if (confirmed != true || !mounted) return;

    final name = nameController.text.trim();
    if (name.isEmpty) return;
    final order = int.tryParse(orderController.text.trim()) ?? _subjects.length + 1;

    try {
      final client = Supabase.instance.client;
      await client.from('subjects').insert({'name': name, 'display_order': order});
      await _fetchSubjects();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('追加エラー: $e')),
        );
      }
    }
  }

  Future<void> _importAssetData() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final importer = AssetImport(localDb: widget.localDb);
      await importer.run();
      if (!kIsWeb && SyncEngine.isInitialized) {
        await SyncEngine.instance.syncIfOnline();
      }
      await _fetchSubjects();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '参考書データをインポートしました: 知識 ${importer.knowledgeCount} 件、問題 ${importer.questionCount} 件（knowledge.json のタグ・構文フラグは Supabase に同期済み）',
            ),
          ),
        );
        if (importer.message != null && importer.message!.isNotEmpty) {
          setState(() => _error = 'インポート時の注意: ${importer.message!.trim()}');
        }
      }
    } catch (e) {
      setState(() => _error = 'インポートエラー: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  /// 既存の knowledge 行に対し、knowledge.json の tags と construction を Supabase へ書き込む（重複エラーを避けたいとき用）。
  Future<void> _syncTagsFromAssetsOnly() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final importer = AssetImport(localDb: widget.localDb);
      await importer.syncTagsFromAssetsOnly();
      if (!kIsWeb && SyncEngine.isInitialized) {
        await SyncEngine.instance.syncIfOnline();
      }
      await _fetchSubjects();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('knowledge.json のタグ・構文フラグを Supabase に反映しました（ローカルへ Pull 済み）'),
          ),
        );
        if (importer.message != null && importer.message!.isNotEmpty) {
          final note = importer.message!.trim();
          setState(() => _error = '同期の注意: $note');
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(note, style: const TextStyle(fontSize: 13)),
              duration: const Duration(seconds: 12),
              backgroundColor: Theme.of(context).colorScheme.errorContainer,
              action: SnackBarAction(
                label: '閉じる',
                textColor: Theme.of(context).colorScheme.onErrorContainer,
                onPressed: () {
                  ScaffoldMessenger.of(context).hideCurrentSnackBar();
                },
              ),
            ),
          );
        }
      }
    } catch (e) {
      setState(() => _error = 'knowledge.json 同期エラー: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  void _copyErrorAndShowDialog(BuildContext context, String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('クリップボードにコピーしました')),
    );
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('エラー全文（長押しで選択・コピー可能）'),
        content: SizedBox(
          width: double.maxFinite,
          height: 320,
          child: TextField(
            readOnly: true,
            maxLines: null,
            controller: TextEditingController(text: text),
            style: const TextStyle(fontSize: 12),
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              isDense: true,
              contentPadding: EdgeInsets.all(12),
              alignLabelWithHint: true,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('閉じる'),
          ),
          FilledButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('クリップボードにコピーしました')),
              );
            },
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('もう一度コピー'),
          ),
        ],
      ),
    );
  }

  void _openKnowledgeDb() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => SubjectPickerPage(
          subjects: _subjects,
          title: '知識DB',
          dbType: TeacherDbType.knowledge,
          localDatabase: widget.localDatabase,
        ),
      ),
    );
  }

  static const _englishGrammarSubjectName = '英文法';

  void _openEnglishGrammarKnowledgeDb() {
    Map<String, dynamic>? row;
    for (final s in _subjects) {
      if (s['name']?.toString() == _englishGrammarSubjectName) {
        row = s;
        break;
      }
    }
    final subjectId = row?['id'] as String?;
    if (subjectId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            '科目「$_englishGrammarSubjectName」が見つかりません。「知識DB」から科目を確認するか、科目を追加してください。',
          ),
        ),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => KnowledgeListScreen(
          subjectId: subjectId,
          subjectName: _englishGrammarSubjectName,
          localDatabase: widget.localDatabase,
        ),
      ),
    );
  }

  void _openMemorizationDb() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => SubjectPickerPage(
          subjects: _subjects,
          title: '暗記DB',
          dbType: TeacherDbType.memorization,
          localDatabase: widget.localDatabase,
        ),
      ),
    );
  }

  void _openEnglishExampleDb() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => const EnglishExampleListScreen(),
      ),
    );
  }

  void _openFourChoice() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => const FourChoiceListScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('教材管理'),
        actions: [
          const ForceSyncIconButton(),
          IconButton(
            icon: const Icon(Icons.wifi_find),
            tooltip: 'Supabase 接続テスト',
            onPressed: _loading ? null : _testConnection,
          ),
          IconButton(
            icon: const Icon(Icons.upload_file),
            tooltip: '参考書データをインポート',
            onPressed: _loading ? null : _importAssetData,
          ),
          IconButton(
            icon: const Icon(Icons.label_outline),
            tooltip: 'タグ・構文フラグを knowledge.json → Supabase に反映',
            onPressed: _loading ? null : _syncTagsFromAssetsOnly,
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '科目を追加',
            onPressed: _loading ? null : _showAddSubjectDialog,
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '設定',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) => const SettingsScreen(),
                ),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          if (_loading) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('エラーが発生しました。下の「コピー」で全文をコピーできます。'),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      FilledButton.icon(
                        onPressed: () => _copyErrorAndShowDialog(context, _error!),
                        icon: const Icon(Icons.copy, size: 20),
                        label: const Text('エラー全文をコピー'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        onPressed: _loading ? null : _fetchSubjects,
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('再読み込み'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          Expanded(
            child: _subjects.isEmpty
                ? _loading
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const CircularProgressIndicator(),
                            const SizedBox(height: 16),
                            Text(
                              '再取得中...',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ],
                        ),
                      )
                    : Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Text('科目がまだありません'),
                            const SizedBox(height: 8),
                            Text(
                              'ログイン直後や別端末の場合は「データを再取得」を試してください。',
                              style: Theme.of(context).textTheme.bodySmall,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 16),
                            FilledButton.icon(
                              onPressed: _loading
                                  ? null
                                  : () async {
                                      setState(() {
                                        _loading = true;
                                        _error = null;
                                      });
                                      try {
                                        await widget.onRefreshAuthAndRetry?.call();
                                        if (!mounted) return;
                                        await _fetchSubjects();
                                      } catch (e, st) {
                                        if (mounted) {
                                          setState(() => _error =
                                              '再取得でエラー:\n${e.runtimeType}: $e\n\n$st');
                                        }
                                      } finally {
                                        if (mounted) {
                                          setState(() => _loading = false);
                                        }
                                      }
                                    },
                              icon: const Icon(Icons.refresh),
                              label: const Text('データを再取得'),
                            ),
                            const SizedBox(height: 12),
                            FilledButton.icon(
                              onPressed: _showAddSubjectDialog,
                              icon: const Icon(Icons.add),
                              label: const Text('最初の科目を追加'),
                            ),
                          ],
                        ),
                      )
                : ListView(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    children: [
                      ListTile(
                        leading: const Icon(Icons.auto_stories),
                        title: const Text('英文法（知識DB）'),
                        subtitle: const Text('科目「英文法」の知識カードを管理'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _openEnglishGrammarKnowledgeDb,
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.menu_book),
                        title: const Text('知識DB'),
                        subtitle: const Text('解説メインの知識カードを管理'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _openKnowledgeDb,
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.style),
                        title: const Text('暗記DB'),
                        subtitle: const Text('表・裏の暗記カードを管理'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _openMemorizationDb,
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.translate),
                        title: const Text('英語例文DB'),
                        subtitle: const Text('表=日本語、裏=英語、解説・補足を管理'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _openEnglishExampleDb,
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.quiz_outlined),
                        title: const Text('四択問題'),
                        subtitle: const Text('四択問題の作成・一覧'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _openFourChoice,
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.people_outline),
                        title: const Text('学習者管理'),
                        subtitle: const Text('学習者アカウントの追加・削除・パスワードリセット'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (context) => const LearnerManagementScreen(),
                            ),
                          );
                        },
                      ),
                      if (_showStudyTimeSummaryMenu) ...[
                        const Divider(height: 1),
                        ListTile(
                          leading: const Icon(Icons.timer_outlined),
                          title: const Text('勉強時間（セッション一覧）'),
                          subtitle: const Text(
                            '直近7日の合計・内訳・最近のセッション（ローカルDB）',
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (context) => StudyTimeSummaryScreen(
                                  localDatabase: widget.localDatabase,
                                ),
                              ),
                            );
                          },
                        ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
