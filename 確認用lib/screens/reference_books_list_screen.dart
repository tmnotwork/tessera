import 'dart:convert';
import 'dart:io' show File;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/reference_book.dart';
import '../utils/android_data_path.dart';
import '../utils/platform_utils.dart';
import 'knowledge_list_screen.dart';

/// 参考書一覧画面（グルーピング表示）。タップでその参考書の解説一覧へ
class ReferenceBooksListScreen extends StatefulWidget {
  const ReferenceBooksListScreen({super.key, this.openDrawer, this.onOpenSettings});

  /// スマホでドロワーを開くコールバック（指定時は AppBar にメニューアイコンを表示）
  final VoidCallback? openDrawer;

  /// PC版で設定画面を開くコールバック（指定時は AppBar に設定アイコンを表示）
  final void Function(BuildContext context)? onOpenSettings;

  @override
  State<ReferenceBooksListScreen> createState() => _ReferenceBooksListScreenState();
}

class _ReferenceBooksListScreenState extends State<ReferenceBooksListScreen> {
  List<ReferenceBook> _books = [];
  String? _error;
  String? _dataFolderPath;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    final prefs = await SharedPreferences.getInstance();
    final savedPath = prefs.getString(dataFolderKey);

    if (isDesktop) {
      if (savedPath != null && savedPath.isNotEmpty) {
        _dataFolderPath = savedPath;
        await _loadBooksFromFolder(savedPath);
      }
    } else if (isAndroid) {
      // PC と同様に、設定で指定したフォルダを優先。未設定ならアプリ内フォルダを使用
      if (savedPath != null && savedPath.isNotEmpty) {
        _dataFolderPath = savedPath;
        await _loadBooksFromFolder(savedPath);
      }
      if (_dataFolderPath == null) {
        final path = await ensureAndroidDataPath();
        if (path != null) {
          _dataFolderPath = path;
          await _loadBooksFromFolder(path);
        }
      }
    }
    if (_books.isEmpty && _error == null) {
      await _loadBooksFromAssets();
    }
    setState(() => _isLoading = false);
  }

  Future<void> _loadBooksFromAssets() async {
    try {
      final jsonString = await rootBundle.loadString('assets/data/books.json');
      final list = jsonDecode(jsonString) as List<dynamic>;
      setState(() {
        _books = list
            .map((e) => ReferenceBook.fromJson(e as Map<String, dynamic>))
            .toList();
        _error = null;
      });
    } catch (e) {
      setState(() {
        _books = [];
        _error = e.toString();
      });
    }
  }

  Future<void> _loadBooksFromFolder(String folderPath) async {
    try {
      final file = File(p.join(folderPath, 'books.json'));
      if (!await file.exists()) {
        setState(() {
          _books = [];
          _error = null;
        });
        return;
      }
      final jsonString = await file.readAsString();
      final list = jsonDecode(jsonString) as List<dynamic>;
      setState(() {
        _books = list
            .map((e) => ReferenceBook.fromJson(e as Map<String, dynamic>))
            .toList();
        _dataFolderPath = folderPath;
        _error = null;
      });
    } catch (e) {
      setState(() {
        _books = [];
        _error = e.toString();
      });
    }
  }

  Future<void> _pickFolder() async {
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'データフォルダを選択（books.json を含むフォルダ）',
      lockParentWindow: true,
    );
    if (path != null && path.isNotEmpty) {
      setState(() => _isLoading = true);
      await _loadBooksFromFolder(path);
      if (_books.isEmpty) {
        await _loadBooksFromAssets();
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(dataFolderKey, path);
      setState(() => _isLoading = false);
    }
  }

  /// グループごとにまとめたマップ。キーは group または 'その他'
  Map<String, List<ReferenceBook>> get _groupedBooks {
    final map = <String, List<ReferenceBook>>{};
    for (final book in _books) {
      final key = book.group ?? 'その他';
      map.putIfAbsent(key, () => []).add(book);
    }
    return map;
  }

  List<Widget> _appBarActions(BuildContext context) {
    if (!isDesktop || widget.onOpenSettings == null) return const [];
    return [
      IconButton(
        icon: const Icon(Icons.settings_outlined),
        onPressed: () => widget.onOpenSettings!(context),
        tooltip: '設定',
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('参考書一覧'),
          leading: widget.openDrawer != null
              ? IconButton(
                  icon: const Icon(Icons.menu),
                  onPressed: widget.openDrawer,
                  tooltip: 'メニュー',
                )
              : null,
          actions: _appBarActions(context),
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (isDesktop && _dataFolderPath == null && _books.isEmpty && _error == null) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('参考書一覧'),
          leading: widget.openDrawer != null
              ? IconButton(icon: const Icon(Icons.menu), onPressed: widget.openDrawer, tooltip: 'メニュー')
              : null,
          actions: _appBarActions(context),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.folder_open,
                  size: 64,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: 24),
                Text(
                  'データフォルダを指定してください',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  'books.json を含むフォルダを選択すると、参考書一覧を表示できます。\n未選択の場合はアプリ内のデフォルト一覧を表示します。',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _pickFolder,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('フォルダを選択'),
                ),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () async {
                    setState(() => _isLoading = true);
                    await _loadBooksFromAssets();
                    if (mounted) setState(() => _isLoading = false);
                  },
                  child: const Text('デフォルト一覧を表示'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_error != null && _books.isEmpty) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('参考書一覧'),
          leading: widget.openDrawer != null
              ? IconButton(icon: const Icon(Icons.menu), onPressed: widget.openDrawer, tooltip: 'メニュー')
              : null,
          actions: [
            if (isDesktop)
              IconButton(
                icon: const Icon(Icons.folder_open),
                onPressed: _pickFolder,
                tooltip: 'フォルダを選択',
              ),
            ..._appBarActions(context),
          ],
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.error_outline, size: 48, color: Theme.of(context).colorScheme.error),
                const SizedBox(height: 16),
                Text('読み込みエラー: $_error', textAlign: TextAlign.center),
                if (isDesktop) ...[
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: _pickFolder,
                    icon: const Icon(Icons.folder_open),
                    label: const Text('フォルダを選択'),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    if (_books.isEmpty) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('参考書一覧'),
          leading: widget.openDrawer != null
              ? IconButton(icon: const Icon(Icons.menu), onPressed: widget.openDrawer, tooltip: 'メニュー')
              : null,
          actions: _appBarActions(context),
        ),
        body: const Center(child: Text('参考書がありません')),
      );
    }

    final grouped = _groupedBooks;
    final groupKeys = grouped.keys.toList()..sort();

    return Scaffold(
      appBar: AppBar(
        title: const Text('参考書一覧'),
        leading: widget.openDrawer != null
            ? IconButton(icon: const Icon(Icons.menu), onPressed: widget.openDrawer, tooltip: 'メニュー')
            : null,
        actions: [
          if (isDesktop) ...[
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () async {
                setState(() => _isLoading = true);
                if (_dataFolderPath != null) {
                  await _loadBooksFromFolder(_dataFolderPath!);
                }
                if (_books.isEmpty) await _loadBooksFromAssets();
                setState(() => _isLoading = false);
              },
              tooltip: '再読み込み',
            ),
            IconButton(
              icon: const Icon(Icons.folder_open),
              onPressed: _pickFolder,
              tooltip: 'フォルダを選択',
            ),
          ],
          ..._appBarActions(context),
        ],
      ),
      body: ListView.builder(
        itemCount: groupKeys.length,
        itemBuilder: (context, groupIndex) {
          final groupName = groupKeys[groupIndex];
          final booksInGroup = grouped[groupName]!;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                alignment: Alignment.centerLeft,
                child: Text(
                  groupName,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              ...booksInGroup.map((book) => ListTile(
                    leading: CircleAvatar(
                      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                      child: Icon(
                        Icons.menu_book,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    title: Text(book.name),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) => KnowledgeListScreen(
                            book: book,
                            dataFolderPath: _dataFolderPath,
                          ),
                        ),
                      );
                    },
                  )),
            ],
          );
        },
      ),
    );
  }
}
