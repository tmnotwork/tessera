import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'src/asset_import.dart';
import 'src/init_sqflite_stub.dart' if (dart.library.io) 'src/init_sqflite_io.dart' as init_sqflite;
import 'src/screens/knowledge_list_screen.dart';

// 実機ビルドでは .env が同梱されないため、フォールバック用の公開キー
const _fallbackSupabaseUrl = 'https://wnufzrehvhcwclnwxwim.supabase.co';
const _fallbackSupabaseAnonKey =
    'sb_publishable_6ZOloNwIgIFjF9SKRLGgmA_Yc55g0es';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  runZonedGuarded(() async {
    if (kIsWeb) {
      await Supabase.initialize(
        url: _fallbackSupabaseUrl,
        anonKey: _fallbackSupabaseAnonKey,
      );
      runApp(const RootApp(localDb: null));
      return;
    }

    // 実機・エミュレータ: .env があれば使う。なければ埋め込みキーで接続
    String supabaseUrl = _fallbackSupabaseUrl;
    String supabaseAnonKey = _fallbackSupabaseAnonKey;
    try {
      await dotenv.load(fileName: '.env');
      final fromEnvUrl = (dotenv.env['SUPABASE_URL'] ?? '').trim();
      final fromEnvKey = (dotenv.env['SUPABASE_ANON_KEY'] ?? '').trim();
      if (fromEnvUrl.isNotEmpty && fromEnvKey.isNotEmpty) {
        supabaseUrl = fromEnvUrl;
        supabaseAnonKey = fromEnvKey;
      }
    } catch (_) {
      // .env が無い（実機に同梱されていない等）→ 埋め込みキーを使用
    }

    await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);
    init_sqflite.initSqliteForDesktop();
    final localDb = await _initLocalDb();
    runApp(RootApp(localDb: localDb));
  }, (error, stack) {
    if (kDebugMode) {
      debugPrint('$error\n$stack');
    }
    runApp(StartupErrorApp(error: error, stack: stack));
  });
}

/// 起動時に例外が起きた場合のエラー画面（真っ黒を防ぐ）
class StartupErrorApp extends StatelessWidget {
  const StartupErrorApp({super.key, required this.error, this.stack});

  final Object error;
  final StackTrace? stack;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: Scaffold(
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline, size: 48, color: Colors.red.shade700),
                const SizedBox(height: 16),
                Text(
                  '起動エラー',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const SizedBox(height: 12),
                Text('$error', style: const TextStyle(height: 1.5)),
                if (stack != null) ...[
                  const SizedBox(height: 16),
                  Text('$stack', style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class RootApp extends StatelessWidget {
  const RootApp({super.key, required this.localDb});

  final Database? localDb;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Learning Platform',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: RootScaffold(localDb: localDb),
    );
  }
}

class RootScaffold extends StatefulWidget {
  const RootScaffold({super.key, required this.localDb});

  final Database? localDb;

  @override
  State<RootScaffold> createState() => _RootScaffoldState();
}

class _RootScaffoldState extends State<RootScaffold> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      LearningSyncPage(localDb: widget.localDb),
      TeacherAdminPage(localDb: widget.localDb),
    ];

    return Scaffold(
      body: pages[_index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.school_outlined),
            selectedIcon: Icon(Icons.school),
            label: '学習テスト',
          ),
          NavigationDestination(
            icon: Icon(Icons.manage_search_outlined),
            selectedIcon: Icon(Icons.manage_search),
            label: '教師用管理',
          ),
        ],
      ),
    );
  }
}

/// ローカル DB と Supabase の同期テスト用画面
class LearningSyncPage extends StatefulWidget {
  const LearningSyncPage({super.key, required this.localDb});

  final Database? localDb;

  @override
  State<LearningSyncPage> createState() => _LearningSyncPageState();
}

class _LearningSyncPageState extends State<LearningSyncPage> {
  bool _syncing = false;
  String _status = '未同期';
  List<Map<String, dynamic>> _localKnowledge = [];

  Database get _db => widget.localDb!;

  @override
  void initState() {
    super.initState();
    _loadLocalKnowledge();
  }

  Future<void> _loadLocalKnowledge() async {
    final rows = await _db.query('knowledge_local', orderBy: 'created_at DESC');
    setState(() {
      _localKnowledge = rows;
    });
  }

  Future<void> _insertDummyKnowledge() async {
    String? subjectId;
    try {
      final rows = await Supabase.instance.client
          .from('subjects')
          .select('id')
          .limit(1)
          .order('display_order');
      if (rows.isNotEmpty) {
        subjectId = rows.first['id']?.toString();
      }
    } catch (_) {}
    await _db.insert('knowledge_local', {
      'subject': 'english',
      'subject_id': subjectId,
      'unit': 'TOEIC basic',
      'content': 'apple',
      'description': 'りんご / 基本語彙',
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
      'synced': 0,
    });
    await _loadLocalKnowledge();
    setState(() {
      _status = 'ローカルに 1 件追加しました';
    });
  }

  Future<void> _importAssetData() async {
    setState(() {
      _syncing = true;
      _status = '参考書データをインポート中...';
    });
    try {
      final importer = AssetImport(localDb: _db);
      await importer.run();
      await _loadLocalKnowledge();
      setState(() {
        _status = 'インポート完了: 知識 ${importer.knowledgeCount} 件、問題 ${importer.questionCount} 件';
        if (importer.message != null && importer.message!.isNotEmpty) {
          _status = '$_status\n${importer.message}';
        }
      });
    } catch (e) {
      setState(() => _status = 'インポートエラー: $e');
    } finally {
      setState(() => _syncing = false);
    }
  }

  Future<void> _syncToSupabase() async {
    setState(() {
      _syncing = true;
      _status = 'Supabase と同期中...';
    });

    try {
      final client = Supabase.instance.client;

      final unsynced = await _db.query(
        'knowledge_local',
        where: 'synced = ?',
        whereArgs: [0],
      );

      for (final row in unsynced) {
        final payload = {
          'unit': row['unit'],
          'content': row['content'],
          'description': row['description'],
        };
        if (row['subject_id'] != null && row['subject_id'].toString().isNotEmpty) {
          payload['subject_id'] = row['subject_id'];
        }
        if (row['subject'] != null) payload['subject'] = row['subject'];
        final inserted = await client.from('knowledge').insert(payload).select().maybeSingle();

        if (inserted != null) {
          await _db.update(
            'knowledge_local',
            {
              'synced': 1,
              'supabase_id': inserted['id'],
              'updated_at': DateTime.now().toIso8601String(),
            },
            where: 'id = ?',
            whereArgs: [row['id']],
          );
        }
      }

      await _loadLocalKnowledge();
      setState(() {
        _status = '同期完了 (${unsynced.length} 件同期)';
      });
    } catch (e) {
      setState(() {
        _status = '同期エラー: $e';
      });
    } finally {
      setState(() {
        _syncing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || widget.localDb == null) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('ローカル同期テスト'),
        ),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'このローカルDB同期デモは現在モバイル/デスクトップ用です。\n'
              'Web 版では Supabase へのオンライン学習のみを想定しています。',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('ローカル同期テスト'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('状態:', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 120),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  _status,
                  style: TextStyle(
                    color: _status.contains('エラー') ? Colors.red.shade700 : null,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                ElevatedButton(
                  onPressed: _insertDummyKnowledge,
                  child: const Text('ローカルにダミー知識を追加'),
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  onPressed: _syncing ? null : _syncToSupabase,
                  child: const Text('Supabase へ同期'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _syncing ? null : _importAssetData,
              icon: const Icon(Icons.upload_file),
              label: const Text('参考書データをインポート'),
            ),
            const SizedBox(height: 24),
            const Text(
              'ローカル knowledge 一覧',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: _localKnowledge.length,
                itemBuilder: (context, index) {
                  final row = _localKnowledge[index];
                  final desc = row['description']?.toString() ?? '';
                  final descShort = desc.length > 80 ? '${desc.substring(0, 80)}...' : desc;
                  return ListTile(
                    title: Text(row['content']?.toString() ?? ''),
                    subtitle: Text(
                      '${row['unit'] ?? '-'}${descShort.isNotEmpty ? ' · $descShort' : ''}\n'
                      'subject: ${row['subject']} / synced: ${row['synced'] == 1 ? 'はい' : 'いいえ'}',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 教師（管理者）向け管理画面
class TeacherAdminPage extends StatefulWidget {
  const TeacherAdminPage({super.key, this.localDb});

  final Database? localDb;

  @override
  State<TeacherAdminPage> createState() => _TeacherAdminPageState();
}

class _TeacherAdminPageState extends State<TeacherAdminPage> {
  bool _loading = false;
  String? _error;
  List<Map<String, dynamic>> _subjects = [];

  @override
  void initState() {
    super.initState();
    _fetchSubjects();
  }

  Future<void> _fetchSubjects() async {
    setState(() => _loading = true);
    try {
      final client = Supabase.instance.client;
      final rows = await client.from('subjects').select().order('display_order');
      setState(() {
        _subjects = List<Map<String, dynamic>>.from(rows);
        _error = null;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
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
      await _fetchSubjects();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '参考書データをインポートしました: 知識 ${importer.knowledgeCount} 件、問題 ${importer.questionCount} 件',
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

  void _openKnowledgeList(Map<String, dynamic> subject) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => KnowledgeListScreen(
          subjectId: subject['id'] as String,
          subjectName: subject['name']?.toString() ?? '知識カード',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('教師用管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.upload_file),
            tooltip: '参考書データをインポート',
            onPressed: _loading ? null : _importAssetData,
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '科目を追加',
            onPressed: _loading ? null : _showAddSubjectDialog,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_loading) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          Expanded(
            child: _subjects.isEmpty && !_loading
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text('科目がまだありません'),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: _showAddSubjectDialog,
                          icon: const Icon(Icons.add),
                          label: const Text('最初の科目を追加'),
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    itemCount: _subjects.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final s = _subjects[index];
                      return ListTile(
                        title: Text(s['name']?.toString() ?? ''),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _openKnowledgeList(s),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

Future<Database> _initLocalDb() async {
  final dir = await getApplicationDocumentsDirectory();
  final path = p.join(dir.path, 'learning_platform.db');

  return openDatabase(
    path,
    version: 2,
    onCreate: (db, version) async {
      await db.execute('''
        CREATE TABLE knowledge_local (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          subject TEXT NOT NULL,
          subject_id TEXT,
          unit TEXT,
          content TEXT NOT NULL,
          description TEXT,
          supabase_id TEXT,
          synced INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        )
      ''');
    },
    onUpgrade: (db, oldVersion, newVersion) async {
      if (oldVersion < 2) {
        await db.execute(
          'ALTER TABLE knowledge_local ADD COLUMN subject_id TEXT',
        );
      }
    },
  );
}

