import 'package:flutter/material.dart';

import '../app_scope.dart';
import 'tts_setting_screen.dart';

/// アプリ設定画面（ダークモードなど）
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final current = appThemeNotifier.mode;
    return Scaffold(
      appBar: AppBar(
        title: const Text('設定'),
      ),
      body: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 24, 16, 8),
            child: Text(
              '表示',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey,
              ),
            ),
          ),
          ListTile(
            leading: Icon(
              current == ThemeMode.dark ? Icons.dark_mode : Icons.light_mode,
              color: Theme.of(context).colorScheme.primary,
            ),
            title: const Text('ダークモード'),
            subtitle: Text(
              current == ThemeMode.light
                  ? 'ライト'
                  : current == ThemeMode.dark
                      ? 'ダーク'
                      : 'システムに従う',
            ),
            onTap: () => _showThemeModePicker(context),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 24, 16, 8),
            child: Text(
              '読み上げ',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey,
              ),
            ),
          ),
          ListTile(
            leading: Icon(
              Icons.volume_up,
              color: Theme.of(context).colorScheme.primary,
            ),
            title: const Text('読み上げ設定'),
            subtitle: const Text('速度・繰り返し・ランダムなど'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (context) => const TtsSettingScreen(),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 24, 16, 8),
            child: Text(
              'アカウント',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey,
              ),
            ),
          ),
          ListTile(
            leading: Icon(
              Icons.logout,
              color: Theme.of(context).colorScheme.error,
            ),
            title: Text(
              'ログアウト',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            onTap: () async {
              await appAuthNotifier.logout();
            },
          ),
        ],
      ),
    );
  }

  void _showThemeModePicker(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Builder(
          builder: (context) {
            final current = appThemeNotifier.mode;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('テーマを選択', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ),
                RadioListTile<ThemeMode>(
                  title: const Text('ライト'),
                  secondary: const Icon(Icons.light_mode),
                  value: ThemeMode.light,
                  groupValue: current,
                  onChanged: (v) {
                    if (v != null) {
                      appThemeNotifier.setThemeMode(v);
                      Navigator.of(context).pop();
                    }
                  },
                ),
                RadioListTile<ThemeMode>(
                  title: const Text('ダーク'),
                  secondary: const Icon(Icons.dark_mode),
                  value: ThemeMode.dark,
                  groupValue: current,
                  onChanged: (v) {
                    if (v != null) {
                      appThemeNotifier.setThemeMode(v);
                      Navigator.of(context).pop();
                    }
                  },
                ),
                RadioListTile<ThemeMode>(
                  title: const Text('システムに従う'),
                  secondary: const Icon(Icons.settings_suggest),
                  value: ThemeMode.system,
                  groupValue: current,
                  onChanged: (v) {
                    if (v != null) {
                      appThemeNotifier.setThemeMode(v);
                      Navigator.of(context).pop();
                    }
                  },
                ),
                const SizedBox(height: 16),
              ],
            );
          },
        ),
      ),
    );
  }
}
