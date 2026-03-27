// ignore_for_file: use_build_context_synchronously

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/auth_service.dart';
import '../services/app_settings_service.dart';
import '../services/multi_day_backfill_service.dart';
import '../services/inbox_task_service.dart';
import '../services/project_service.dart';
import '../services/project_sync_service.dart';
import '../services/routine_task_v2_service.dart';
import '../services/routine_template_v2_service.dart';
import '../services/routine_block_v2_service.dart';
import '../services/routine_v2_backfill_service.dart';
import '../services/shortcut_display_diagnostics.dart';
import '../services/utc_timestamp_normalization_service.dart';
import 'report_screenshot_mock_screen.dart';
import 'shortcut_template_screen.dart';

class DeveloperModeScreen extends StatefulWidget {
  const DeveloperModeScreen({super.key});

  @override
  State<DeveloperModeScreen> createState() => _DeveloperModeScreenState();
}

class _DeveloperModeScreenState extends State<DeveloperModeScreen> {
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
      leading: Icon(icon, color: textColor),
      title: Text(
        title,
        style: textColor != null ? TextStyle(color: textColor) : null,
      ),
      subtitle: Text(subtitle),
      trailing: onTap != null ? const Icon(Icons.chevron_right) : null,
      onTap: onTap,
    );
  }

  Future<void> _runMultiDayBackfillFlow() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('多日キーのバックフィル（手動）'),
        content: const Text(
          '欠損している startAt/dayKeys/monthKeys 等を補完するため、Firestoreへ書き込みを行います。\n'
          '（通常は一度で完了する想定です）\n\n実行しますか？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('実行'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _runMultiDayBackfill(force: false);
  }

  Future<void> _runMultiDayBackfill({required bool force}) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const AlertDialog(
        title: Text('実行中...'),
        content: SizedBox(
          height: 56,
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
    );

    MultiDayBackfillReport report;
    try {
      report = await MultiDayBackfillService.runManual(force: force);
    } catch (e) {
      report = MultiDayBackfillReport(
        status: MultiDayBackfillStatus.failed,
        startedAtUtc: DateTime.now().toUtc(),
        endedAtUtc: DateTime.now().toUtc(),
        note: e.toString(),
      );
    }

    if (mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }

    final text = report.toText();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('バックフィル結果'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(text),
          ),
        ),
        actions: [
          if (report.status == MultiDayBackfillStatus.skippedDone && !force)
            TextButton(
              onPressed: () async {
                Navigator.of(ctx).pop();
                await _runMultiDayBackfill(force: true);
              },
              child: const Text('強制実行'),
            ),
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('結果をコピーしました')),
                );
              }
            },
            child: const Text('コピー'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('閉じる'),
          ),
        ],
      ),
    );
  }

  Future<void> _runUtcNormalizationFlow() async {
    const targets = UtcTimestampNormalizationService.defaultTargetCollections;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('UTC正規化（手動）'),
        content: Text(
          '過去に保存されたデータで lastModified の形式がUTC(Z)で揃っていない場合、\n'
          '差分同期（diff）が同じ更新を繰り返し取得して read が増えることがあります。\n\n'
          'この操作は Firestore を走査し、必要なドキュメントだけ lastModified 等をUTC(Z)に正規化して書き込みます。\n'
          '（読み取り/書き込みが発生します。Wi‑Fi推奨）\n\n'
          '対象コレクション: ${targets.join(', ')}\n\n'
          '実行しますか？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('実行'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const AlertDialog(
        title: Text('実行中...'),
        content: SizedBox(
          height: 56,
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
    );

    UtcTimestampNormalizationReport report;
    try {
      report = await UtcTimestampNormalizationService.runManual();
    } catch (e) {
      report = UtcTimestampNormalizationReport(
        status: UtcTimestampNormalizationStatus.failed,
        startedAtUtc: DateTime.now().toUtc(),
        endedAtUtc: DateTime.now().toUtc(),
        targetCollections: targets,
        collections: const [],
        note: e.toString(),
      );
    }

    if (mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }

    final text = report.toText();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('UTC正規化結果'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(text),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('結果をコピーしました')),
                );
              }
            },
            child: const Text('コピー'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('閉じる'),
          ),
        ],
      ),
    );
  }

  Future<void> _showMainUiTypeDialog(BuildContext context) async {
    final current = AppSettingsService.mainUiTypeNotifier.value;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('メイン画面のUI'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 400),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RadioListTile<String>(
                  title: const Text('旧UI（下部バー）'),
                  subtitle: const Text('従来の下部タブナビ'),
                  value: 'old',
                  groupValue: current,
                  onChanged: (v) async {
                    if (v != null) {
                      await AppSettingsService.setString(
                        AppSettingsService.keyMainUiType,
                        v,
                      );
                      if (context.mounted) Navigator.pop(dialogContext);
                      if (mounted) setState(() {});
                    }
                  },
                ),
                RadioListTile<String>(
                  title: const Text('新UI・GitHub版（左メニュー）'),
                  subtitle: const Text('リポジトリのメイン版'),
                  value: 'new',
                  groupValue: current,
                  onChanged: (v) async {
                    if (v != null) {
                      await AppSettingsService.setString(
                        AppSettingsService.keyMainUiType,
                        v,
                      );
                      if (context.mounted) Navigator.pop(dialogContext);
                      if (mounted) setState(() {});
                    }
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tertiary = Theme.of(context).colorScheme.tertiary;
    return Scaffold(
      appBar: AppBar(
        title: const Text('開発者モード', overflow: TextOverflow.ellipsis),
        toolbarHeight: 48,
      ),
      body: ListView(
        children: [
          _buildSectionHeader('LP・宣伝用'),
          _buildListTile(
            'レポート画面モック（スクリーンショット用）',
            '架空データの週次レポート（英語学習・仕事・副業の予実）',
            Icons.photo_camera_outlined,
            () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const ReportScreenshotMockScreen(),
                ),
              );
            },
          ),
          const Divider(),
          _buildSectionHeader('UI'),
          ValueListenableBuilder<String>(
            valueListenable: AppSettingsService.mainUiTypeNotifier,
            builder: (context, uiType, _) {
              final subtitle = switch (uiType) {
                'old' => '旧UI（下部バー）',
                _ => '新UI・GitHub版（左メニュー）',
              };
              return _buildListTile(
                'メイン画面のUI',
                subtitle,
                Icons.dashboard_customize_outlined,
                () => _showMainUiTypeDialog(context),
              );
            },
          ),
          const Divider(),
          _buildSectionHeader('Firestore 手動処理'),
          _buildListTile(
            '多日キーのバックフィル（手動）',
            'startAt/dayKeys等の欠損を補完（Firestoreへ書き込み）',
            Icons.build_circle,
            _runMultiDayBackfillFlow,
            textColor: tertiary,
          ),
          _buildListTile(
            'UTC正規化（手動）',
            '過去データのlastModified形式揺れを修正（Firestoreへ書き込み）',
            Icons.schedule_send,
            _runUtcNormalizationFlow,
            textColor: tertiary,
          ),
          const Divider(),
          _buildSectionHeader('プロジェクト userId 補完（移行用）'),
          _buildListTile(
            'ローカルHiveのプロジェクトでuserIdを補完',
            'userIdが空のプロジェクトを現在ユーザーで上書き（管理者用・1回実行）',
            Icons.person_add_outlined,
            _runProjectUserIdBackfillLocal,
            textColor: tertiary,
          ),
          _buildListTile(
            'Firebaseからプロジェクトを再取得してuserIdを付与',
            'Firestoreのプロジェクトを取得し、userIdが無いものに現在ユーザーを付与して保存',
            Icons.cloud_download,
            _runProjectUserIdCompletionFromFirebase,
            textColor: tertiary,
          ),
          const Divider(),
          _buildSectionHeader('タスク userId 補完（移行用）'),
          _buildListTile(
            'userIdが空のタスクを現在ユーザーで上書き',
            'ローカルHive内のインボックスタスクで userId が空のものを、現在ログイン中のユーザーで上書きします。',
            Icons.assignment_ind,
            _runInboxTaskUserIdBackfillLocal,
            textColor: tertiary,
          ),
          const Divider(),
          _buildSectionHeader('ルーティンV2 userId 補完（移行用）'),
          _buildListTile(
            'ルーティンV2 一式を補完（推奨）',
            'テンプレート・ブロック・ルーティンタスクのうち userId が空のものを現在ユーザーで上書き。ショートカットが出ない場合はこちら。',
            Icons.auto_fix_high,
            _runRoutineV2FullUserIdBackfillLocal,
            textColor: tertiary,
          ),
          _buildListTile(
            'ルーティンテンプレート（V2）のみ',
            'テンプレのみ userId 補完（通常は一式補完で十分）',
            Icons.description_outlined,
            _runRoutineTemplateUserIdBackfillLocal,
            textColor: tertiary,
          ),
          _buildListTile(
            'ルーティンブロック（V2）のみ',
            'ブロックのみ userId 補完',
            Icons.view_agenda_outlined,
            _runRoutineBlockUserIdBackfillLocal,
            textColor: tertiary,
          ),
          _buildListTile(
            'ルーティンタスク（V2）のみ',
            'タスクのみ userId 補完（空白のみの userId も対象）',
            Icons.list_alt,
            _runRoutineTaskUserIdBackfillLocal,
            textColor: tertiary,
          ),
          _buildListTile(
            'ショートカットタスク userId 強制修正',
            'ショートカット正規ID（templateId=shortcut, blockId=v2blk_shortcut_0）のタスクのuserIdを強制的に現在ユーザーで上書き。空でない誤ったuserIdが原因でショートカット一覧が空になる場合の救済用。',
            Icons.link,
            _runShortcutTaskUserIdForceFixLocal,
            textColor: tertiary,
          ),
          _buildListTile(
            'ショートカットID整合（template/block を正規化）',
            'legacy/分裂ID（例: shortcut_*）のショートカットタスクを正規ID（templateId=shortcut, blockId=v2blk_shortcut_0）へ移行します。',
            Icons.merge_type,
            _runShortcutCanonicalIdNormalizationLocal,
            textColor: tertiary,
          ),
          _buildListTile(
            'ショートカット表示診断（原因レポート）',
            'FAB・編集と同条件の件数・生Hiveの分岐・推定原因を一覧表示（コピー可）',
            Icons.bug_report_outlined,
            _showShortcutDisplayDiagnostics,
            textColor: tertiary,
          ),
          _buildListTile(
            '正規ショートカット編集を直接開く（診断）',
            'templateId=shortcut を固定して ShortcutTemplateScreen を直接開き、UI経路の差分を切り分けます。',
            Icons.open_in_new,
            _openCanonicalShortcutEditorForDebug,
            textColor: tertiary,
          ),
          const Divider(),
          _buildSectionHeader('危険な操作'),
          ListTile(
            leading: Icon(Icons.delete_forever,
                color: Theme.of(context).colorScheme.error),
            title: Text('アカウント削除',
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
            subtitle: const Text('ユーザーIDを完全に削除'),
            onTap: _showDeleteAccountDialog,
          ),
        ],
      ),
    );
  }

  Future<void> _runProjectUserIdBackfillLocal() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('プロジェクト userId 補完（ローカル）'),
        content: const Text(
          'ローカルHive内で userId が空のプロジェクトを、現在ログイン中のユーザーで上書きします。\n'
          '移行時の救済用です。実行しますか？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('実行'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const AlertDialog(
        title: Text('実行中...'),
        content: SizedBox(
          height: 56,
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
    );
    int count = 0;
    try {
      count = await ProjectService.runUserIdBackfillForAdmin();
    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('エラー: $e'), backgroundColor: Theme.of(context).colorScheme.error),
        );
      }
      return;
    }
    if (mounted) {
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$count 件のプロジェクトを補完しました')),
      );
    }
  }

  Future<void> _runProjectUserIdCompletionFromFirebase() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Firebase からプロジェクトを再取得（userId 付与）'),
        content: const Text(
          'Firestore のプロジェクトを再取得し、userId が無いドキュメントに現在ユーザーを付与してローカルに保存します。\n'
          '移行時の救済用です。実行しますか？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('実行'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const AlertDialog(
        title: Text('実行中...'),
        content: SizedBox(
          height: 56,
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
    );
    int count = 0;
    try {
      count = await ProjectSyncService().runUserIdCompletionFromFirebase();
    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('エラー: $e'), backgroundColor: Theme.of(context).colorScheme.error),
        );
      }
      return;
    }
    if (mounted) {
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$count 件のプロジェクトを取得・保存しました')),
      );
    }
  }

  Future<void> _runInboxTaskUserIdBackfillLocal() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('タスク userId 補完（ローカル）'),
        content: const Text(
          'ローカルHive内で userId が空のインボックスタスクを、現在ログイン中のユーザーで上書きします。\n'
          '移行時の救済用です。実行しますか？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('実行'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const AlertDialog(
        title: Text('実行中...'),
        content: SizedBox(
          height: 56,
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
    );
    int count = 0;
    try {
      count = await InboxTaskService.runUserIdBackfillForAdmin();
    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('エラー: $e'), backgroundColor: Theme.of(context).colorScheme.error),
        );
      }
      return;
    }
    if (mounted) {
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$count 件のタスクを補完しました')),
      );
    }
  }

  Future<void> _runRoutineV2FullUserIdBackfillLocal() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ルーティンV2 一式 userId 補完'),
        content: const Text(
          'ルーティンテンプレート（V2）・ルーティンブロック（V2）・ルーティンタスク（V2）のうち、\n'
          'userId が空または空白のみのレコードを、現在ログイン中のユーザーで上書きします。\n\n'
          '昔のデータで userId が無いと、ショートカット一覧やルーティンが表示されないことがあります。\n\n'
          '実行しますか？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('実行'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const AlertDialog(
        title: Text('実行中...'),
        content: SizedBox(
          height: 56,
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
    );
    int templates = 0, blocks = 0, tasks = 0;
    try {
      templates = await RoutineTemplateV2Service.runUserIdBackfillForAdmin();
      blocks = await RoutineBlockV2Service.runUserIdBackfillForAdmin();
      tasks = await RoutineTaskV2Service.runUserIdBackfillForAdmin();
    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('エラー: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
      return;
    }
    if (mounted) {
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'テンプレ $templates 件・ブロック $blocks 件・タスク $tasks 件を補完しました',
          ),
        ),
      );
    }
  }

  Future<void> _runRoutineTemplateUserIdBackfillLocal() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ルーティンテンプレート userId 付与'),
        content: const Text(
          'ローカルHive内のルーティンテンプレート（V2）で userId が空のものを現在ユーザーで上書きします。\n'
          '実行しますか？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('実行'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const AlertDialog(
        title: Text('実行中...'),
        content: SizedBox(
          height: 56,
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
    );
    int count = 0;
    try {
      count = await RoutineTemplateV2Service.runUserIdBackfillForAdmin();
    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('エラー: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
      return;
    }
    if (mounted) {
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$count 件のテンプレートを補完しました')),
      );
    }
  }

  Future<void> _runRoutineBlockUserIdBackfillLocal() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ルーティンブロック userId 付与'),
        content: const Text(
          'ローカルHive内のルーティンブロック（V2）で userId が空のものを現在ユーザーで上書きします。\n'
          '実行しますか？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('実行'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const AlertDialog(
        title: Text('実行中...'),
        content: SizedBox(
          height: 56,
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
    );
    int count = 0;
    try {
      count = await RoutineBlockV2Service.runUserIdBackfillForAdmin();
    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('エラー: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
      return;
    }
    if (mounted) {
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$count 件のブロックを補完しました')),
      );
    }
  }

  Future<void> _runRoutineTaskUserIdBackfillLocal() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ルーティンタスク userId 付与（ローカル）'),
        content: const Text(
          'ローカルHive内で userId が空または空白のみのルーティンタスク（V2）を、現在ログイン中のユーザーで上書きします。\n'
          'ショートカット一覧が空になる不具合の救済用です。実行しますか？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('実行'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const AlertDialog(
        title: Text('実行中...'),
        content: SizedBox(
          height: 56,
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
    );
    int count = 0;
    try {
      count = await RoutineTaskV2Service.runUserIdBackfillForAdmin();
    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('エラー: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
      return;
    }
    if (mounted) {
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$count 件のルーティンタスクに userId を付与しました')),
      );
    }
  }

  Future<void> _runShortcutTaskUserIdForceFixLocal() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ショートカットタスク userId 強制修正'),
        content: const Text(
          'ショートカット正規ID（templateId=shortcut, blockId=v2blk_shortcut_0）を持つタスクのuserIdを、'
          '現在ログイン中のユーザーで強制上書きします。\n\n'
          '通常の補完（userId が空のみ対象）では直らない場合の救済用です。\n\n'
          '実行しますか？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('実行'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const AlertDialog(
        title: Text('実行中...'),
        content: SizedBox(
          height: 56,
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
    );
    int count = 0;
    try {
      count = await RoutineTaskV2Service.runShortcutUserIdForceFixForAdmin();
    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('エラー: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
      return;
    }
    if (mounted) {
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$count 件のショートカットタスクの userId を修正しました')),
      );
    }
  }

  Future<void> _runShortcutCanonicalIdNormalizationLocal() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ショートカットID整合（正規化）'),
        content: const Text(
          'legacy/分裂ID（例: shortcut_*）に保存されたショートカットタスクを、\n'
          '正規ID（templateId=shortcut, blockId=v2blk_shortcut_0）へ移行します。\n\n'
          '既存ユーザー向けの救済用です。実行しますか？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('実行'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const AlertDialog(
        title: Text('実行中...'),
        content: SizedBox(
          height: 56,
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
    );
    int moved = 0;
    try {
      moved = await RoutineV2BackfillService.normalizeShortcutTasksToCanonical();
    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('エラー: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
      return;
    }
    if (mounted) {
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$moved 件のショートカットタスクIDを正規化しました')),
      );
    }
  }

  Future<void> _showShortcutDisplayDiagnostics() async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const AlertDialog(
        title: Text('診断中...'),
        content: SizedBox(
          height: 56,
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
    );
    String report;
    try {
      report = await ShortcutDisplayDiagnostics.buildReport();
    } catch (e, st) {
      report = '診断の取得に失敗しました\n$e\n$st';
    }
    if (mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ショートカット表示診断'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(report),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: report));
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('レポートをコピーしました')),
                );
              }
            },
            child: const Text('コピー'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('閉じる'),
          ),
        ],
      ),
    );
  }

  Future<void> _openCanonicalShortcutEditorForDebug() async {
    final canonical = RoutineTemplateV2Service.getById('shortcut');
    if (canonical == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('templateId=shortcut が見つかりません'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ShortcutTemplateScreen(routine: canonical),
        fullscreenDialog: true,
      ),
    );
  }

  Future<void> _showDeleteAccountDialog() async {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('アカウントを削除'),
        content: const Text(
          'アカウントを削除すると、すべてのデータが失われます。\n\n'
          '本当にアカウントを削除しますか？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(dialogContext);
              try {
                final currentUserId = AuthService.getCurrentUserId();
                if (currentUserId != null) {
                  await ProjectService.clearAllProjects();
                  await AuthService.deleteUser(currentUserId);

                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: const Text('アカウントを削除しました'),
                        backgroundColor: Theme.of(context).colorScheme.secondary,
                      ),
                    );
                    Navigator.of(context).pushNamedAndRemoveUntil('/auth', (route) => false);
                  }
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('アカウント削除エラー: $e'),
                      backgroundColor: Theme.of(context).colorScheme.error,
                    ),
                  );
                }
              }
            },
            child: const Text('削除'),
          ),
        ],
      ),
    );
  }
}
