import 'package:flutter/material.dart';

import 'phone_preview_screen.dart';
import 'question_flashcard_screen.dart';
import 'reference_books_list_screen.dart';
import 'settings_screen.dart';

/// スマホ用：ドロワー付きシェル。起動時は「知識一覧」を表示し、ドロワーから各メニューに切り替え。
class MobileShellScreen extends StatefulWidget {
  const MobileShellScreen({
    super.key,
    required this.themeMode,
    required this.onThemeModeChanged,
  });

  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;

  @override
  State<MobileShellScreen> createState() => _MobileShellScreenState();
}

enum _MobileMenu {
  knowledge,
  questions,
  phonePreview,
  settings,
}

class _MobileShellScreenState extends State<MobileShellScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  _MobileMenu _selected = _MobileMenu.knowledge;
  int _dataFolderVersion = 0;

  void _openDrawer() {
    _scaffoldKey.currentState?.openDrawer();
  }

  void _select(_MobileMenu menu) {
    setState(() => _selected = menu);
    Navigator.of(context).pop(); // ドロワーを閉じる
  }

  void _onDataFolderChanged() {
    setState(() => _dataFolderVersion++);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      drawer: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            DrawerHeader(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
              ),
              child: Text(
                'Knowledge Viewer',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.menu_book),
              title: const Text('知識一覧'),
              subtitle: const Text('参考書を選んで解説を読む'),
              selected: _selected == _MobileMenu.knowledge,
              onTap: () => _select(_MobileMenu.knowledge),
            ),
            ListTile(
              leading: const Icon(Icons.quiz),
              title: const Text('問題確認'),
              subtitle: const Text('英作文を暗記カードで確認'),
              selected: _selected == _MobileMenu.questions,
              onTap: () => _select(_MobileMenu.questions),
            ),
            ListTile(
              leading: const Icon(Icons.smartphone),
              title: const Text('スマホ画面で確認'),
              subtitle: const Text('プレビュー'),
              selected: _selected == _MobileMenu.phonePreview,
              onTap: () => _select(_MobileMenu.phonePreview),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: const Text('設定'),
              selected: _selected == _MobileMenu.settings,
              onTap: () => _select(_MobileMenu.settings),
            ),
          ],
        ),
      ),
      body: IndexedStack(
        index: _selected.index,
        children: [
          KeyedSubtree(
            key: ValueKey('knowledge_$_dataFolderVersion'),
            child: ReferenceBooksListScreen(openDrawer: _openDrawer),
          ),
          KeyedSubtree(
            key: ValueKey('questions_$_dataFolderVersion'),
            child: QuestionFlashcardScreen(openDrawer: _openDrawer),
          ),
          PhonePreviewScreen(openDrawer: _openDrawer),
          SettingsScreen(
            initialThemeMode: widget.themeMode,
            onThemeModeChanged: widget.onThemeModeChanged,
            openDrawer: _openDrawer,
            onDataFolderChanged: _onDataFolderChanged,
          ),
        ],
      ),
    );
  }
}
