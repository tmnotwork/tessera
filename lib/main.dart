import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'src/app_scope.dart';
import 'src/asset_import.dart';
import 'src/init_sqflite_stub.dart' if (dart.library.io) 'src/init_sqflite_io.dart' as init_sqflite;
import 'src/screens/four_choice_list_screen.dart';
import 'src/screens/knowledge_list_screen.dart';
import 'src/screens/learner_home_screen.dart';
import 'src/screens/memorization_list_screen.dart';

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
      // 実機では localhost / 127.0.0.1 / 非 HTTPS は使わない（SocketException 防止）
      final urlOk = fromEnvUrl.isNotEmpty &&
          fromEnvUrl.startsWith('https://') &&
          !fromEnvUrl.contains('localhost') &&
          !fromEnvUrl.contains('127.0.0.1');
      if (urlOk && fromEnvKey.isNotEmpty) {
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
        fontFamily: 'NotoSansJP',
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
                const SizedBox(height: 24),
                FilledButton.icon(
                  icon: const Icon(Icons.copy),
                  label: const Text('エラー全文をコピー'),
                  onPressed: () {
                    final full = '$error\n\n${stack ?? ''}';
                    Clipboard.setData(ClipboardData(text: full));
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
                            controller: TextEditingController(text: full),
                            style: const TextStyle(fontSize: 12),
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              isDense: true,
                              contentPadding: EdgeInsets.all(12),
                            ),
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(ctx).pop(),
                            child: const Text('閉じる'),
                          ),
                          FilledButton.icon(
                            icon: const Icon(Icons.copy),
                            label: const Text('もう一度コピー'),
                            onPressed: () {
                              Clipboard.setData(ClipboardData(text: full));
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('クリップボードにコピーしました')),
                              );
                            },
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

const _themeModeKey = 'theme_mode';

ThemeData _buildLightTheme() {
  return ThemeData(
    colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
    useMaterial3: true,
    fontFamily: 'NotoSansJP',
  );
}

ThemeData _buildDarkTheme() {
  return ThemeData(
    colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo, brightness: Brightness.dark),
    useMaterial3: true,
    fontFamily: 'NotoSansJP',
  );
}

class RootApp extends StatefulWidget {
  const RootApp({super.key, required this.localDb});

  final Database? localDb;

  @override
  State<RootApp> createState() => _RootAppState();
}

class _RootAppState extends State<RootApp> {
  ThemeMode _themeMode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    appThemeNotifier.listen(_onThemeModeChanged);
    _loadThemeMode();
  }

  @override
  void dispose() {
    appThemeNotifier.dispose();
    super.dispose();
  }

  void _onThemeModeChanged(ThemeMode mode) {
    if (mounted) setState(() => _themeMode = mode);
    _persistThemeMode(mode);
  }

  Future<void> _persistThemeMode(ThemeMode mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = switch (mode) {
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
        ThemeMode.system => 'system',
      };
      await prefs.setString(_themeModeKey, value);
    } catch (_) {}
  }

  Future<void> _loadThemeMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_themeModeKey);
      if (stored == null) return;
      final mode = switch (stored) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
      appThemeNotifier.initThemeMode(mode);
      if (mounted) setState(() => _themeMode = mode);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tessera',
      theme: _buildLightTheme(),
      darkTheme: _buildDarkTheme(),
      themeMode: _themeMode,
      home: RootScaffold(key: _rootScaffoldKey, localDb: widget.localDb),
    );
  }
}

final _rootScaffoldKey = GlobalKey<_RootScaffoldState>();

class RootScaffold extends StatefulWidget {
  const RootScaffold({super.key, required this.localDb});

  final Database? localDb;

  @override
  State<RootScaffold> createState() => _RootScaffoldState();
}

class _RootScaffoldState extends State<RootScaffold> {
  int _index = 0;

  void _switchToManageTab(BuildContext context) {
    final navigator = Navigator.maybeOf(context, rootNavigator: true) ?? Navigator.of(context);
    navigator.popUntil((route) => route.isFirst);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _index = 2);
    });
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      LearnerHomeScreen(
        onOpenManage: () => setState(() => _index = 2),
      ),
      KnowledgeDbHomePage(localDb: widget.localDb),
      TeacherAdminPage(localDb: widget.localDb),
    ];

    openManageNotifier.openManage = (ctx) => _rootScaffoldKey.currentState?._switchToManageTab(ctx);

    return Scaffold(
      body: pages[_index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.school_outlined),
            selectedIcon: Icon(Icons.school),
            label: '学習',
          ),
          NavigationDestination(
            icon: Icon(Icons.menu_book_outlined),
            selectedIcon: Icon(Icons.menu_book),
            label: '知識DB',
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

/// 起動時初期画面：知識DB の科目一覧（タップでその科目の知識カード一覧へ）
class KnowledgeDbHomePage extends StatefulWidget {
  const KnowledgeDbHomePage({super.key, this.localDb});

  final Database? localDb;

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
                      separatorBuilder: (_, __) => const Divider(height: 1),
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
      await client.from('subjects').select('id').limit(1).maybeSingle();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('接続成功: Supabase に接続できました。')),
        );
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
        builder: (context) => _SubjectPickerPage(
          subjects: _subjects,
          title: '知識DB',
          isKnowledge: true,
        ),
      ),
    );
  }

  void _openMemorizationDb() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => _SubjectPickerPage(
          subjects: _subjects,
          title: '暗記DB',
          isKnowledge: false,
        ),
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
                : ListView(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    children: [
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
                        leading: const Icon(Icons.quiz_outlined),
                        title: const Text('四択問題'),
                        subtitle: const Text('四択問題の作成・一覧'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _openFourChoice,
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// 知識DB / 暗記DB 用の科目選択ページ
class _SubjectPickerPage extends StatelessWidget {
  const _SubjectPickerPage({
    required this.subjects,
    required this.title,
    required this.isKnowledge,
  });

  final List<Map<String, dynamic>> subjects;
  final String title;
  final bool isKnowledge;

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
                final subjectName = s['name']?.toString() ?? (isKnowledge ? '知識カード' : '暗記カード');
                if (subjectId == null) return const SizedBox.shrink();
                return ListTile(
                  title: Text(subjectName),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    if (isKnowledge) {
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

Future<Database> _initLocalDb() async {
  final dir = await getApplicationDocumentsDirectory();
  final path = p.join(dir.path, 'tessera.db');

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

