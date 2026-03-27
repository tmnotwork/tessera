// ignore_for_file: use_build_context_synchronously

// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/auth_service.dart';
import '../screens/sync_all_history_screen.dart';
import '../screens/developer_mode_screen.dart';

import '../screens/mode_edit_screen.dart';
import '../screens/category_management_screen.dart';
import '../screens/project_category_assignment_screen.dart';
import '../services/app_settings_service.dart'; // Added import for AppSettingsService
// duplicate import removed

class SettingsScreen extends StatefulWidget {
  final bool embedded; // true のときは中央コンテンツに埋め込み表示（AppBarなし）
  final VoidCallback? onNavigateToProjectManagement;
  final VoidCallback? onNavigateToRoutine;

  const SettingsScreen({
    super.key,
    this.embedded = false,
    this.onNavigateToProjectManagement,
    this.onNavigateToRoutine,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // 一般設定（通知・言語・テーマ・ダークモード）は削除済み

  Future<void> _showDefaultEstimatedMinutesDialog() async {
    final current = AppSettingsService.getInt(
      AppSettingsService.keyTaskDefaultEstimatedMinutes,
      defaultValue: 0,
    );
    int selected = current;

    const presets = <int>[0, 5, 10, 15, 30, 45, 60, 90, 120, 180];

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('デフォルトの所要時間（分）'),
        content: StatefulBuilder(
          builder: (context, setDialog) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final m in presets)
                RadioListTile<int>(
                  title: Text(m == 0 ? '0（未設定）' : '$m分'),
                  value: m,
                  groupValue: selected,
                  onChanged: (v) {
                    if (v == null) return;
                    setDialog(() => selected = v);
                  },
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () async {
              await AppSettingsService.setInt(
                AppSettingsService.keyTaskDefaultEstimatedMinutes,
                selected,
              );
              if (mounted) setState(() {});
              Navigator.pop(ctx);
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  String _defaultEstimatedMinutesLabel() {
    final v = AppSettingsService.getInt(
      AppSettingsService.keyTaskDefaultEstimatedMinutes,
      defaultValue: 0,
    );
    return v == 0 ? '0（未設定）' : '$v分';
  }

  String _archivedInSelectDisplayLabel() {
    final v = AppSettingsService.archivedInSelectDisplayNotifier.value;
    return v == 'dimmed'
        ? '色を薄めて表示'
        : '選択肢に表示しない';
  }

  Future<void> _showArchivedInSelectDisplayDialog() async {
    String selected =
        AppSettingsService.archivedInSelectDisplayNotifier.value;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('アーカイブ済みの選択肢表示'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'プロジェクト・サブプロジェクトの入力欄で、アーカイブ済みの項目をどう表示するか：',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              RadioListTile<String>(
                title: const Text('選択肢に表示しない'),
                subtitle: const Text('アーカイブ済みは候補に出さない'),
                value: 'hide',
                groupValue: selected,
                onChanged: (v) {
                  if (v != null) setDialog(() => selected = v);
                },
              ),
              RadioListTile<String>(
                title: const Text('色を薄めて表示'),
                subtitle: const Text('アーカイブ済みであることがわかるように表示'),
                value: 'dimmed',
                groupValue: selected,
                onChanged: (v) {
                  if (v != null) setDialog(() => selected = v);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('キャンセル'),
            ),
            ElevatedButton(
              onPressed: () async {
                await AppSettingsService.setArchivedInSelectDisplay(selected);
                if (mounted) setState(() {});
                Navigator.pop(ctx);
              },
              child: const Text('OK'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = _buildBody();
    if (widget.embedded) {
      // NOTE:
      // メイン画面では Settings を「オーバーレイ」で重ねて State を維持する設計のため、
      // embedded=true では Scaffold を返さない。しかしその場合、背景(Material)が無いと
      // 下の画面が透けて見えて「設定画面が透明」に見える。
      //
      // ここで明示的に Material+背景色を付与し、常に不透明な設定画面にする。
      return Material(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: body,
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('設定', overflow: TextOverflow.ellipsis, maxLines: 1),
        toolbarHeight: 48,
      ),
      body: body,
    );
  }

  Widget _buildBody() {
    final isMobile = MediaQuery.of(context).size.width < 800;
    return ListView(
      children: [
        // スマホのみ: ルーティンメニューへのリンク
        if (isMobile && widget.onNavigateToRoutine != null)
          _buildListTile(
            'ルーティン',
            'ルーティンテンプレートの管理',
            Icons.schedule,
            widget.onNavigateToRoutine,
          ),
        if (isMobile && widget.onNavigateToRoutine != null)
          const Divider(height: 1),

        // 外観
        _buildSectionHeader('外観'),
        _buildListTile(
          'テーマ',
          _themeModeLabel(
              AppSettingsService.getString(AppSettingsService.keyThemeMode)),
          Icons.brightness_6,
          () => _showThemeModeDialog(),
        ),

        // マスタ管理
        _buildSectionHeader('マスタ管理'),
        _buildListTile(
          'カテゴリ管理',
          'カテゴリの追加・編集・プロジェクトへの割り当て',
          Icons.category,
          () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const CategoryManagementScreen()),
          ),
        ),
        _buildListTile(
          'プロジェクト管理',
          'プロジェクトの追加・編集・カテゴリ割り当て',
          Icons.folder,
          () {
            if (widget.onNavigateToProjectManagement != null) {
              widget.onNavigateToProjectManagement!();
            } else {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const ProjectCategoryAssignmentScreen(),
                ),
              );
            }
          },
        ),
        _buildListTile(
          'モード管理',
          'タスクのモードを管理',
          Icons.mode,
          () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const ModeEditScreen()),
          ),
        ),
        ValueListenableBuilder<String>(
          valueListenable:
              AppSettingsService.archivedInSelectDisplayNotifier,
          builder: (context, _, __) => _buildListTile(
            'アーカイブ済みの選択肢表示',
            _archivedInSelectDisplayLabel(),
            Icons.archive_outlined,
            () => _showArchivedInSelectDisplayDialog(),
          ),
        ),

        // タスク設定
        _buildSectionHeader('タスク設定'),
        _buildListTile(
          'デフォルトの期限',
          '当日',
          Icons.schedule,
          () => _showDefaultDueDateDialog(),
        ),
        _buildListTile(
          'デフォルトの所要時間（分）',
          _defaultEstimatedMinutesLabel(),
          Icons.timelapse,
          () => _showDefaultEstimatedMinutesDialog(),
        ),
        const Divider(),

        // アカウント設定
        _buildSectionHeader('アカウント設定'),
        _buildListTile(
          '同期/読取 履歴',
          'read増加の原因（同期/監視/ウィジェット等）を確認',
          Icons.history,
          () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const SyncAllHistoryScreen()),
          ),
        ),
        _buildListTile(
          '正確アラームを許可',
          'Android の「アラームとリマインダー」をONにする',
          Icons.alarm_on,
          () async {
            try {
              const channel =
                  MethodChannel('com.example.task_kant_1/permissions');
              final bool canExact =
                  await channel.invokeMethod('areExactAlarmsAllowed');
              if (!canExact) {
                await channel.invokeMethod('requestExactAlarmPermission');
              }
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(canExact ? '既に許可されています' : '設定画面を開きました'),
                  ),
                );
              }
            } catch (e) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('リクエストエラー: $e'),
                    backgroundColor: Theme.of(context).colorScheme.error,
                  ),
                );
              }
            }
          },
        ),
        _buildListTile(
          '省電力の最適化を除外',
          'バックグラウンドでの通知抑止を回避',
          Icons.battery_alert,
          () async {
            try {
              const channel =
                  MethodChannel('com.example.task_kant_1/permissions');
              final bool ignoring =
                  await channel.invokeMethod('areIgnoringBatteryOptimizations');
              if (!ignoring) {
                await channel.invokeMethod('requestIgnoreBatteryOptimizations');
              }
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(ignoring ? '既に除外されています' : '設定画面を開きました'),
                  ),
                );
              }
            } catch (e) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('リクエストエラー: $e'),
                    backgroundColor: Theme.of(context).colorScheme.error,
                  ),
                );
              }
            }
          },
        ),
        _buildListTile(
          'ログアウト',
          'アカウントからログアウト',
          Icons.logout,
          () => _showLogoutDialog(),
          textColor: Theme.of(context).colorScheme.tertiary,
        ),

        const Divider(),

        // 開発者メニュー
        _buildSectionHeader('開発者'),
        _buildListTile(
          '開発者メニュー',
          '多日キーバックフィル・UTC正規化など（Firestore手動処理）',
          Icons.developer_mode,
          () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const DeveloperModeScreen()),
          ),
        ),

        const Divider(),

        // アプリ情報
        _buildSectionHeader('アプリ情報'),
        _buildListTile('バージョン', '1.0.0', Icons.info, null),
      ],
    );
  }

  Widget _buildSectionHeader(String title) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.bold,
          color: Theme.of(context).textTheme.bodySmall?.color,
        ),
      ),
    );
  }

  Widget _buildListTile(
    String title,
    String subtitle,
    IconData icon,
    VoidCallback? onTap, {
    Color? textColor,
  }) {
    return ListTile(
      leading: Icon(icon),
      title: Text(
        title,
        style: textColor != null ? TextStyle(color: textColor) : null,
      ),
      subtitle: Text(subtitle),
      trailing: onTap != null ? const Icon(Icons.chevron_right) : null,
      onTap: onTap,
    );
  }

  String _themeModeLabel(String? saved) {
    switch (saved) {
      case 'light':
        return 'ライトネイビー';
      // Backward compatibility: removed theme (ライトブルー) now maps to light.
      case 'bright_blue_light':
        return 'ライトネイビー';
      case 'teal_light':
        return 'ライトティール';
      case 'dark':
        return 'ダークネイビー';
      case 'wine':
        return 'ダークワイン';
      case 'teal':
        return 'ダークティール';
      case 'orange':
        return 'ダークオレンジ';
      case 'wine_light':
        return 'ライトワイン';
      case 'gray_light':
        return 'シンプルグレー';
      case 'black_minimal':
        return 'ミニマルブラック';
      case 'black_minimal_light':
        return 'ライトミニマル';
      default:
        return 'システムに従う';
    }
  }

  void _showThemeModeDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('テーマを選択'),
        content: StatefulBuilder(
          builder: (context, setStateDialog) {
            final current =
                AppSettingsService.getString(AppSettingsService.keyThemeMode);
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RadioListTile<String>(
                  title: const Text('システムに従う'),
                  value: 'system',
                  groupValue: current ?? 'system',
                  onChanged: (v) async {
                    await AppSettingsService.setThemeModeString('system');
                    setState(() {});
                    if (mounted) Navigator.pop(context);
                  },
                ),
                RadioListTile<String>(
                  title: const Text('ライトネイビー'),
                  value: 'light',
                  groupValue: current ?? 'system',
                  onChanged: (v) async {
                    await AppSettingsService.setThemeModeString('light');
                    setState(() {});
                    if (mounted) Navigator.pop(context);
                  },
                ),
                RadioListTile<String>(
                  title: const Text('ライトティール'),
                  value: 'teal_light',
                  groupValue: current ?? 'system',
                  onChanged: (v) async {
                    await AppSettingsService.setThemeModeString('teal_light');
                    setState(() {});
                    if (mounted) Navigator.pop(context);
                  },
                ),
                RadioListTile<String>(
                  title: const Text('ライトワイン'),
                  value: 'wine_light',
                  groupValue: current ?? 'system',
                  onChanged: (v) async {
                    await AppSettingsService.setThemeModeString('wine_light');
                    setState(() {});
                    if (mounted) Navigator.pop(context);
                  },
                ),
                RadioListTile<String>(
                  title: const Text('シンプルグレー'),
                  value: 'gray_light',
                  groupValue: current ?? 'system',
                  onChanged: (v) async {
                    await AppSettingsService.setThemeModeString('gray_light');
                    setState(() {});
                    if (mounted) Navigator.pop(context);
                  },
                ),
                RadioListTile<String>(
                  title: const Text('ライトミニマル'),
                  value: 'black_minimal_light',
                  groupValue: current ?? 'system',
                  onChanged: (v) async {
                    await AppSettingsService.setThemeModeString('black_minimal_light');
                    setState(() {});
                    if (mounted) Navigator.pop(context);
                  },
                ),
                RadioListTile<String>(
                  title: const Text('ダークネイビー'),
                  value: 'dark',
                  groupValue: current ?? 'system',
                  onChanged: (v) async {
                    await AppSettingsService.setThemeModeString('dark');
                    setState(() {});
                    if (mounted) Navigator.pop(context);
                  },
                ),
                RadioListTile<String>(
                  title: const Text('ダークティール'),
                  value: 'teal',
                  groupValue: current ?? 'system',
                  onChanged: (v) async {
                    await AppSettingsService.setThemeModeString('teal');
                    setState(() {});
                    if (mounted) Navigator.pop(context);
                  },
                ),
                RadioListTile<String>(
                  title: const Text('ダークワイン'),
                  value: 'wine',
                  groupValue: current ?? 'system',
                  onChanged: (v) async {
                    await AppSettingsService.setThemeModeString('wine');
                    setState(() {});
                    if (mounted) Navigator.pop(context);
                  },
                ),
                RadioListTile<String>(
                  title: const Text('ダークオレンジ'),
                  value: 'orange',
                  groupValue: current ?? 'system',
                  onChanged: (v) async {
                    await AppSettingsService.setThemeModeString('orange');
                    setState(() {});
                    if (mounted) Navigator.pop(context);
                  },
                ),
                RadioListTile<String>(
                  title: const Text('ミニマルブラック'),
                  value: 'black_minimal',
                  groupValue: current ?? 'system',
                  onChanged: (v) async {
                    await AppSettingsService.setThemeModeString('black_minimal');
                    setState(() {});
                    if (mounted) Navigator.pop(context);
                  },
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  void _showDefaultDueDateDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('デフォルトの期限を選択'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RadioListTile<String>(
              title: const Text('当日'),
              value: '当日',
              groupValue: '当日',
              onChanged: (value) => Navigator.pop(context),
            ),
            RadioListTile<String>(
              title: const Text('翌日'),
              value: '翌日',
              groupValue: '当日',
              onChanged: (value) => Navigator.pop(context),
            ),
            RadioListTile<String>(
              title: const Text('1週間後'),
              value: '1週間後',
              groupValue: '当日',
              onChanged: (value) => Navigator.pop(context),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showLogoutDialog() async {
    final currentContext = context;
    showDialog(
      context: currentContext,
      builder: (context) => AlertDialog(
        title: const Text('ログアウト'),
        content: const Text('本当にログアウトしますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              try {
                await AuthService.signOut();
                if (mounted) {
                  ScaffoldMessenger.of(currentContext).showSnackBar(
                    SnackBar(
                      content: const Text('ログアウトしました'),
                      backgroundColor: Theme.of(context).colorScheme.secondary,
                    ),
                  );
                  // 認証画面に戻る
                  Navigator.of(
                    currentContext,
                  ).pushNamedAndRemoveUntil('/auth', (route) => false);
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(currentContext).showSnackBar(
                    SnackBar(
                      content: Text('ログアウトエラー: $e'),
                      backgroundColor: Theme.of(context).colorScheme.error,
                    ),
                  );
                }
              }
            },
            child: const Text('ログアウト'),
          ),
        ],
      ),
    );
  }

}
