import 'package:flutter/material.dart';

import '../screens/settings_screen.dart';

import '../screens/category_management_screen.dart';
import '../screens/mode_edit_screen.dart';
import '../screens/sync_all_history_screen.dart';
import '../services/auth_service.dart';
import '../services/main_navigation_service.dart';

class AppDrawer extends StatelessWidget {
  const AppDrawer({super.key});

  // 画像のように「細い・縦長」で、上の角は直角（切り落とさない）、
  // 下の角だけ丸い“吊り下げラベル”にする。
  static const double _headerHeight = 88.0;
  // 文字がギリギリ収まる程度の幅にする
  static const double _headerWidth = 82.0;

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: SafeArea(
        // ステータスバー（ノッチ）と重なって上部が見えなくなるのを防ぐ
        top: true,
        bottom: true,
        child: Stack(
          children: [
            // メニュー本体。上部の「吊り下げラベル」分だけ余白を確保する。
            ListView(
              padding: const EdgeInsets.only(top: _headerHeight + 16),
              children: [
                // メイン画面（タブ）への移動
                ListTile(
                  leading: const Icon(Icons.schedule),
                  title: const Text('ルーティン'),
                  onTap: () {
                    Navigator.pop(context); // close drawer
                    Navigator.of(context).popUntil((r) => r.isFirst);
                    MainNavigationService.navigate(MainDestination.routine);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.storage),
                  title: const Text('DB'),
                  onTap: () {
                    Navigator.pop(context); // close drawer
                    Navigator.of(context).popUntil((r) => r.isFirst);
                    MainNavigationService.navigate(MainDestination.db);
                  },
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.category),
                  title: const Text('カテゴリ管理'),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const CategoryManagementScreen(),
                      ),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.mode),
                  title: const Text('モード編集'),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (context) => const ModeEditScreen()),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.settings),
                  title: const Text('設定'),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (context) => const SettingsScreen()),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.history),
                  title: const Text('同期/読取 履歴'),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const SyncAllHistoryScreen(),
                      ),
                    );
                  },
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.logout),
                  title: const Text('ログアウト'),
                  onTap: () async {
                    final currentContext = context;
                    Navigator.pop(currentContext);
                    try {
                      await AuthService.signOut();
                      if (currentContext.mounted) {
                        ScaffoldMessenger.of(
                          currentContext,
                        ).showSnackBar(SnackBar(
                            content: const Text('ログアウトしました'),
                            backgroundColor: Theme.of(currentContext)
                                .colorScheme
                                .secondary));
                      }
                    } catch (e) {
                      if (currentContext.mounted) {
                        ScaffoldMessenger.of(currentContext).showSnackBar(
                          SnackBar(
                            content: Text('ログアウトエラー: $e'),
                            backgroundColor:
                                Theme.of(context).colorScheme.error,
                          ),
                        );
                      }
                    }
                  },
                ),
              ],
            ),

            // 画像のように「上端から下に伸びる」ラベルを上に重ねる
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  width: _headerWidth,
                  height: _headerHeight,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(0),
                      topRight: Radius.circular(0),
                      bottomLeft: Radius.circular(22),
                      bottomRight: Radius.circular(22),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Theme.of(context)
                            .colorScheme
                            .shadow
                            .withOpacity(0.18),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  alignment: Alignment.center,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text(
                        'KANT',
                        style: Theme.of(context)
                            .textTheme
                            .headlineSmall
                            ?.copyWith(
                              fontSize: 21,
                              color: Theme.of(context).colorScheme.onPrimary,
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
