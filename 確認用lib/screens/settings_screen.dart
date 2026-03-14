import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/platform_utils.dart';

/// 設定画面（テーマ・データフォルダなど）
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.initialThemeMode,
    required this.onThemeModeChanged,
    this.openDrawer,
    this.onDataFolderChanged,
  });

  final ThemeMode initialThemeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;

  /// スマホでドロワーを開くコールバック（指定時は AppBar にメニューアイコンを表示）
  final VoidCallback? openDrawer;

  /// データフォルダを変更したときのコールバック（スマホで知識一覧の再読み込み用）
  final VoidCallback? onDataFolderChanged;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String? _dataFolderPath;
  bool _dataFolderLoading = true;

  @override
  void initState() {
    super.initState();
    _loadDataFolderPath();
  }

  Future<void> _loadDataFolderPath() async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString(dataFolderKey);
    if (mounted) {
      setState(() {
        _dataFolderPath = path;
        _dataFolderLoading = false;
      });
    }
  }

  Future<void> _pickDataFolder() async {
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'データフォルダを選択（books.json を含むフォルダ）',
      lockParentWindow: true,
    );
    if (path == null || path.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(dataFolderKey, path);
    if (mounted) {
      setState(() => _dataFolderPath = path);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('データフォルダを保存しました。知識一覧を再読み込みします。')),
      );
      widget.onDataFolderChanged?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('設定'),
        leading: widget.openDrawer != null
            ? IconButton(icon: const Icon(Icons.menu), onPressed: widget.openDrawer, tooltip: 'メニュー')
            : null,
      ),
      body: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 24, 16, 8),
            child: Text(
              'データ',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
            ),
          ),
          ListTile(
            leading: Icon(Icons.folder_open, color: Theme.of(context).colorScheme.primary),
            title: const Text('データフォルダ'),
            subtitle: _dataFolderLoading
                ? const Text('読み込み中…')
                : Text(
                    _dataFolderPath != null && _dataFolderPath!.isNotEmpty
                        ? _dataFolderPath!
                        : '未設定（アプリ内の初期データを使用）',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
            trailing: FilledButton.tonal(
              onPressed: _dataFolderLoading ? null : _pickDataFolder,
              child: const Text('フォルダを選択'),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 24, 16, 8),
            child: Text(
              '外観',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
            ),
          ),
          _ThemeModeTile(
            title: 'ライトモード',
            subtitle: '明るいテーマ',
            icon: Icons.light_mode,
            value: ThemeMode.light,
            groupValue: widget.initialThemeMode,
            onChanged: widget.onThemeModeChanged,
          ),
          _ThemeModeTile(
            title: 'ダークモード',
            subtitle: '暗いテーマ',
            icon: Icons.dark_mode,
            value: ThemeMode.dark,
            groupValue: widget.initialThemeMode,
            onChanged: widget.onThemeModeChanged,
          ),
          _ThemeModeTile(
            title: 'システムに合わせる',
            subtitle: '端末の設定に従う',
            icon: Icons.brightness_auto,
            value: ThemeMode.system,
            groupValue: widget.initialThemeMode,
            onChanged: widget.onThemeModeChanged,
          ),
        ],
      ),
    );
  }
}

class _ThemeModeTile extends StatelessWidget {
  const _ThemeModeTile({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.value,
    required this.groupValue,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final ThemeMode value;
  final ThemeMode groupValue;
  final ValueChanged<ThemeMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final selected = value == groupValue;
    return ListTile(
      leading: Icon(
        icon,
        color: selected
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      title: Text(title),
      subtitle: Text(
        subtitle,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: selected
          ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary)
          : null,
      onTap: () => onChanged(value),
    );
  }
}

/// SharedPreferences から保存済みの ThemeMode を読み込む
Future<ThemeMode> loadThemeMode() async {
  final prefs = await SharedPreferences.getInstance();
  final s = prefs.getString(themeModeKey);
  switch (s) {
    case 'dark':
      return ThemeMode.dark;
    case 'system':
      return ThemeMode.system;
    default:
      return ThemeMode.light;
  }
}

/// ThemeMode を SharedPreferences に保存する
Future<void> saveThemeMode(ThemeMode mode) async {
  final prefs = await SharedPreferences.getInstance();
  final s = mode == ThemeMode.dark
      ? 'dark'
      : mode == ThemeMode.system
          ? 'system'
          : 'light';
  await prefs.setString(themeModeKey, s);
}
