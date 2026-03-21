// ignore_for_file: prefer_const_constructors_in_immutables, library_private_types_in_public_api, prefer_const_constructors, use_build_context_synchronously, avoid_print, unused_import, unused_field, unnecessary_import, unused_local_variable, library_prefixes, unused_element, sort_child_properties_last, prefer_const_literals_to_create_immutables, unnecessary_string_escapes, non_constant_identifier_names

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:yomiage/models/deck.dart';
import 'package:yomiage/screens/review_mode_screen.dart';
import 'package:yomiage/screens/csv_import_screen.dart';
import 'package:yomiage/screens/csv_export_screen.dart';
import 'package:yomiage/screens/tts_setting_screen.dart';
import 'package:yomiage/screens/deck_screen.dart';
import 'package:yomiage/screens/card_edit_screen.dart';
import 'package:yomiage/screens/profile_screen.dart';
import 'package:yomiage/screens/shared_decks_screen.dart';
import 'package:yomiage/screens/study_time_screen.dart';
import 'package:yomiage/screens/cloud_reading_mode_screen.dart';
import 'package:yomiage/screens/study_mode_filter.dart';
import 'package:yomiage/services/hive_service.dart';
import 'package:yomiage/screens/login_screen.dart';
import 'package:yomiage/services/firebase_service.dart';
import 'package:yomiage/services/sync_service.dart';
import 'package:yomiage/services/sync/notification_service.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'dart:math' as math;
import 'package:csv/csv.dart';
import 'dart:convert';
import 'package:intl/intl.dart';
import 'package:yomiage/models/flashcard.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_selector/file_selector.dart';
import 'package:collection/collection.dart';
import 'package:yomiage/services/csv_service.dart';
import 'package:yomiage/services/tts_service.dart';

// 分離した機能をインポート
import 'package:yomiage/screens/csv_handler.dart';
import 'package:yomiage/screens/sync_handler.dart';
import 'package:yomiage/screens/reading_mode_section.dart';
import 'package:yomiage/widgets/study_mode_drawer.dart';
import 'package:yomiage/themes/app_theme.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({Key? key}) : super(key: key);

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final GlobalKey _fabKey = GlobalKey();
  final int _currentIndex = 0;
  StreamSubscription? _syncStatusSubscription;
  SyncStatus _syncStatus = SyncStatus.idle;
  bool _isUserLoggedIn = FirebaseService.getUserId() != null;
  bool _isResolvingDiscrepancy = false;

  // チャプター展開状態を管理するマップ
  final Map<dynamic, bool> _deckExpansionState = {};
  // デッキごとのチャプターリストを保持するマップ
  final Map<dynamic, List<String>> _deckChapters = {};

  // 展開状態の変数
  bool _studyExpanded = true;
  bool _sortingExpanded = true;
  bool _readingExpanded = true;

  // フィルター状態
  StudyModeFilter _studyModeFilter = StudyModeFilter.dueToday;

  // 保存された設定を読み込む
  void _loadSettings() {
    final settingsBox = HiveService.getSettingsBox();
    _studyExpanded = settingsBox.get('studyExpanded', defaultValue: true);
    _sortingExpanded = settingsBox.get('sortingExpanded', defaultValue: true);
    _readingExpanded = settingsBox.get('readingExpanded', defaultValue: true);

    final filterString = settingsBox.get('studyModeFilter');
    if (filterString == 'allCards') {
      _studyModeFilter = StudyModeFilter.allCards;
    } else {
      _studyModeFilter = StudyModeFilter.dueToday;
    }
  }

  // 設定を保存する
  void _saveSettings() {
    final settingsBox = HiveService.getSettingsBox();
    settingsBox.put('studyExpanded', _studyExpanded);
    settingsBox.put('sortingExpanded', _sortingExpanded);
    settingsBox.put('readingExpanded', _readingExpanded);
    settingsBox.put('studyModeFilter',
        _studyModeFilter == StudyModeFilter.allCards ? 'allCards' : 'dueToday');
  }

  @override
  void initState() {
    super.initState();
    _loadSettings();

    // TTSサービスを初期化して設定を読み込む
    TtsService.initTts();

    // 同期状態の変更を監視
    final syncService = SyncService();
    _syncStatusSubscription = syncService.syncStatusStream.listen((status) {
      setState(() {
        _syncStatus = status;
      });
    });

    // 認証状態の変更を監視
    FirebaseAuth.instance.authStateChanges().listen((User? user) {
      setState(() {
        _isUserLoggedIn = user != null;
      });

      if (user != null) {
        setState(() {
          _syncStatus = SyncStatus.syncing;
        });
      } else {
        setState(() {
          _syncStatus = SyncStatus.idle;
        });
      }
    });

    // 初回データロード時にチャプター情報も取得
    _loadDeckChapters();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _refreshDatabaseState();
  }

  // デッキごとのチャプターリストを取得
  Future<void> _loadDeckChapters() async {
    final deckBox = HiveService.getDeckBox();
    final cardBox = HiveService.getCardBox();
    final decks = deckBox.values.where((d) => !d.isDeleted).toList();
    final Map<dynamic, List<String>> chaptersMap = {};

    for (final deck in decks) {
      final cardsInDeck = cardBox.values
          .where((card) => !card.isDeleted && card.deckName == deck.deckName)
          .toList();

      final hasUncategorized = cardsInDeck.any((card) => card.chapter.isEmpty);
      final categorizedCards =
          cardsInDeck.where((card) => card.chapter.isNotEmpty).toList();

      final chapters =
          categorizedCards.map((card) => card.chapter).toSet().toList()..sort();

      if (hasUncategorized) {
        chapters.add('未分類');
      }

      chaptersMap[deck.key] = chapters;
    }

    if (mounted) {
      setState(() {
        _deckChapters.clear();
        _deckChapters.addAll(chaptersMap);
      });
    }
  }

  // データベースの状態を更新する
  Future<void> _refreshDatabaseState() async {
    print('ホーム画面: データベースの状態を更新します');
    try {
      await HiveService.refreshDatabase();
      await _loadDeckChapters();

      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      print('ホーム画面: データベース更新中にエラー: $e');
    }
  }

  @override
  void dispose() {
    _syncStatusSubscription?.cancel();
    super.dispose();
  }

  void _showEditMenu(BuildContext context) async {
    final RenderBox fabRenderBox =
        _fabKey.currentContext!.findRenderObject() as RenderBox;
    final Offset fabPosition = fabRenderBox.localToGlobal(Offset.zero);
    final Size fabSize = fabRenderBox.size;
    final RenderBox overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;

    final RelativeRect position = RelativeRect.fromRect(
      Rect.fromLTWH(
        fabPosition.dx,
        fabPosition.dy - fabSize.height - 20,
        fabSize.width,
        fabSize.height,
      ),
      Offset.zero & overlay.size,
    );

    final selected = await showMenu(
      context: context,
      position: position,
      items: [
        PopupMenuItem(
          value: 'deck',
          child: Row(
            children: const [
              Icon(Icons.folder),
              SizedBox(width: 8),
              Text('デッキ作成・編集', style: TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'card',
          child: const Text('カード作成',
              style: TextStyle(fontWeight: FontWeight.bold)),
        ),
      ],
    );

    if (selected != null) {
      switch (selected) {
        case 'deck':
          Navigator.push(
              context, MaterialPageRoute(builder: (_) => const DeckScreen()));
          break;
        case 'card':
          Navigator.push(context,
              MaterialPageRoute(builder: (_) => const CardEditScreen()));
          break;
      }
    }
  }

  // チャプター展開状態の切り替え
  void _toggleDeckExpansion(dynamic deckKey) {
    setState(() {
      _deckExpansionState[deckKey] = !(_deckExpansionState[deckKey] ?? false);
    });
  }

  // 同期差異解決処理
  Future<void> _resolveDiscrepanciesAndShowResult() async {
    if (_isResolvingDiscrepancy) return;

    setState(() {
      _isResolvingDiscrepancy = true;
    });

    try {
      final result = await SyncHandler.resolveDiscrepanciesAndShowResult(
          context, _isResolvingDiscrepancy);

      if (result['status'] == 'success') {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result['message']),
            backgroundColor: result['color'],
            duration: Duration(seconds: 2),
          ),
        );

        // 同期後にホーム画面のデータをリフレッシュ
        await _refreshDatabaseState();
      }
    } finally {
      if (mounted) {
        setState(() {
          _isResolvingDiscrepancy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      ListView(
        children: [
          if (!kIsWeb)
            ReadingModeSection(
              deckExpansionState: _deckExpansionState,
              deckChapters: _deckChapters,
              studyModeFilter: _studyModeFilter,
              isResolvingDiscrepancy: _isResolvingDiscrepancy,
              onDeckExpansionToggle: _toggleDeckExpansion,
            ),
        ],
      ),
      const DeckScreen(),
      const ProfileScreen(),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('yomiage'),
        toolbarHeight: 56.0,
        automaticallyImplyLeading: false,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48.0),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // 出題方法メニュー（ドロワーを開く）
                Builder(
                  builder: (context) => IconButton(
                    icon: Icon(
                      Icons.tune,
                      color: Theme.of(context).appBarTheme.foregroundColor,
                    ),
                    tooltip: '出題方法',
                    onPressed: () {
                      Scaffold.of(context).openDrawer();
                    },
                  ),
                ),
                // デッキ編集アイコン
                IconButton(
                  icon: Icon(
                    Icons.folder,
                    color: Theme.of(context).appBarTheme.foregroundColor,
                  ),
                  tooltip: 'デッキ一覧',
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const DeckScreen(),
                      ),
                    );
                  },
                ),
                // プロフィールアイコン
                IconButton(
                  icon: Icon(
                    Icons.person,
                    color: Theme.of(context).appBarTheme.foregroundColor,
                  ),
                  tooltip: 'プロフィール',
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const ProfileScreen(),
                      ),
                    );
                  },
                ),
                // 同期差異チェックボタン
                _isResolvingDiscrepancy
                    ? Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12.0),
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Theme.of(context)
                                      .appBarTheme
                                      .foregroundColor ??
                                  IconTheme.of(context).color),
                        ),
                      )
                    : IconButton(
                        icon: Icon(
                          Icons.sync_problem,
                          color: Theme.of(context).appBarTheme.foregroundColor,
                        ),
                        tooltip: 'データの同期と差異チェック',
                        onPressed: _resolveDiscrepanciesAndShowResult,
                      ),
                // 設定メニュー（ポップアップメニュー）
                PopupMenuButton<String>(
                  icon: Icon(
                    Icons.menu,
                    color: Theme.of(context).appBarTheme.foregroundColor,
                  ),
                  tooltip: 'メニュー',
                  onSelected: (String value) async {
                    switch (value) {
                      case 'studyTime':
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => const StudyTimeScreen(),
                          ),
                        );
                        break;
                      case 'csvImport':
                        final result = await Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const CsvImportScreen()));
                        if (result != null) {
                          CsvHandler.handleCsvImportResult(context, result);
                        }
                        break;
                      case 'csvExport':
                        if (kIsWeb) {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const CsvExportScreen()),
                          );
                        } else {
                          try {
                            await CsvService.exportAllCsv(isWeb: false);
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content:
                                        Text('CSVファイルを共有/保存するアプリを選択してください.')),
                              );
                            }
                          } catch (e) {
                            if (mounted) {
                              print('CSV Export Error: $e');
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content:
                                      Text('CSVエクスポートに失敗しました: ${e.toString()}'),
                                  backgroundColor: CustomColors.error,
                                ),
                              );
                            }
                          }
                        }
                        break;
                      case 'tts':
                        if (!kIsWeb) {
                          Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const TtsSettingScreen()));
                        }
                        break;
                      case 'cloudTts':
                        if (!kIsWeb) {
                          Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const CloudReadingModeScreen()));
                        }
                        break;
                      case 'sharedDecks':
                        Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const SharedDecksScreen()));
                        break;
                      case 'sync':
                        _handleSyncIconTap(context);
                        break;
                      case 'logout':
                        _showLogoutConfirmationDialog(context);
                        break;
                    }
                  },
                  itemBuilder: (BuildContext context) =>
                      <PopupMenuEntry<String>>[
                    const PopupMenuItem<String>(
                      value: 'studyTime',
                      child: Text('学習時間'),
                    ),
                    const PopupMenuItem<String>(
                      value: 'csvImport',
                      child: Text('CSV取り込み'),
                    ),
                    const PopupMenuItem<String>(
                      value: 'csvExport',
                      child: Text('CSV出力'),
                    ),
                    if (!kIsWeb)
                      const PopupMenuItem<String>(
                        value: 'tts',
                        child: Text('読み上げ設定'),
                      ),
                    if (!kIsWeb)
                      const PopupMenuItem<String>(
                        value: 'cloudTts',
                        child: Text('クラウド読み上げ（β）'),
                      ),
                    const PopupMenuItem<String>(
                      value: 'sharedDecks',
                      child: Text('共有デッキ'),
                    ),
                    if (kIsWeb) ...[
                      const PopupMenuDivider(),
                      PopupMenuItem<String>(
                        value: 'sync',
                        child: Row(children: [
                          Icon(
                            Icons.sync,
                            color:
                                Theme.of(context).appBarTheme.foregroundColor,
                          ),
                          SizedBox(width: 8),
                          Text('手動同期')
                        ]),
                      ),
                      PopupMenuItem<String>(
                        value: 'logout',
                        child: Row(children: [
                          Icon(
                            Icons.logout,
                            color:
                                Theme.of(context).appBarTheme.foregroundColor,
                          ),
                          SizedBox(width: 8),
                          Text('ログアウト')
                        ]),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await _refreshDatabaseState();
        },
        child: screens[_currentIndex],
      ),
      floatingActionButton: FloatingActionButton(
        key: _fabKey,
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const CardEditScreen()),
        ),
        backgroundColor: Theme.of(context).colorScheme.primary,
        child: Icon(
          Icons.add,
          color: Theme.of(context).colorScheme.onPrimary,
        ),
        tooltip: 'カード作成',
      ),
      drawer: _buildStudyModeDrawer(context),
    );
  }

  // 同期ステータスに応じたアイコンを返す
  Widget _getSyncStatusIcon() {
    final Color defaultAppBarIconColor =
        Theme.of(context).appBarTheme.foregroundColor ??
            IconTheme.of(context).color ??
            Theme.of(context).colorScheme.onPrimary;
    switch (_syncStatus) {
      case SyncStatus.syncing:
        return SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
              strokeWidth: 2.0, color: defaultAppBarIconColor),
        );
      case SyncStatus.synced:
        return Icon(Icons.cloud_done, color: CustomColors.success);
      case SyncStatus.error:
        return Icon(Icons.cloud_off, color: CustomColors.error);
      case SyncStatus.idle:
        if (!_isUserLoggedIn) {
          return Icon(Icons.cloud_off,
              color: CustomColors.getSecondaryTextColor(Theme.of(context)));
        }
        return Icon(Icons.cloud_queue, color: defaultAppBarIconColor);
    }
  }

  // 同期ステータスに応じたツールチップを返す
  String _getSyncStatusTooltip() {
    switch (_syncStatus) {
      case SyncStatus.syncing:
        return '同期中...';
      case SyncStatus.synced:
        return '同期済み';
      case SyncStatus.error:
        return '同期エラー';
      case SyncStatus.idle:
        if (!_isUserLoggedIn) {
          return 'ログインしていません';
        }
        return '同期待機中';
    }
  }

  // 同期アイコンタップ時の処理
  void _handleSyncIconTap(BuildContext context) async {
    if (!_isUserLoggedIn) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const LoginScreen()),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('手動同期を開始します...'), duration: Duration(seconds: 2)),
      );
      try {
        await SyncService.forceCloudSync();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('手動同期が完了しました'), duration: Duration(seconds: 3)),
        );
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('同期中にエラーが発生しました: $e'),
              duration: Duration(seconds: 3)),
        );
      }
    }
  }

  // ログアウト確認ダイアログを表示する
  Future<void> _showLogoutConfirmationDialog(BuildContext context) async {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('ログアウト確認'),
          content: const SingleChildScrollView(
            child: ListBody(
              children: <Widget>[
                Text('本当にログアウトしますか？'),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('キャンセル'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
            TextButton(
              child: const Text('ログアウト'),
              onPressed: () async {
                Navigator.of(context).pop();
                try {
                  await FirebaseService.signOut();
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(
                        builder: (context) => const LoginScreen()),
                  );
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('ログアウト中にエラーが発生しました: $e')),
                  );
                }
              },
            ),
          ],
        );
      },
    );
  }

  // 出題モードドロワー関連ウィジェット
  Widget _buildStudyModeDrawer(BuildContext context) {
    if (kIsWeb) return const SizedBox.shrink();

    return FractionallySizedBox(
      widthFactor: 0.75,
      child: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            DrawerHeader(
              decoration: BoxDecoration(color: Theme.of(context).primaryColor),
              child: Align(
                alignment: Alignment.bottomLeft,
                child: Text(
                  '出題モード',
                  style: TextStyle(
                      color: CustomColors.getTextColor(Theme.of(context)),
                      fontSize: 24,
                      fontWeight: FontWeight.bold),
                ),
              ),
            ),
            _buildDrawerToggle(
              title: '全問出題',
              subtitle: '既に覚えた問題も含めて、全問を出題します。',
              value: _studyModeFilter == StudyModeFilter.allCards,
              onChanged: (value) {
                setState(() {
                  _studyModeFilter = value
                      ? StudyModeFilter.allCards
                      : StudyModeFilter.dueToday;
                  _saveSettings();
                });
              },
            ),
            _buildDrawerToggle(
              title: 'ランダム出題',
              subtitle: 'ランダムに出題します。',
              value: TtsService.randomPlayback,
              onChanged: (v) {
                setState(() {
                  TtsService.setRandomPlayback(v);
                });
              },
            ),
            _buildDrawerToggle(
              title: '逆出題',
              subtitle: '回答→質問の順番で出題します。',
              value: TtsService.reversePlayback,
              onChanged: (v) {
                setState(() {
                  TtsService.setReversePlayback(v);
                });
              },
            ),
            _buildDrawerToggle(
              title: '集中暗記',
              subtitle: '連続正解回数が0～1の問題のみを出題します。',
              value: TtsService.focusedMemorization,
              onChanged: (v) {
                setState(() {
                  TtsService.setFocusedMemorization(v);
                });
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDrawerToggle({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile.adaptive(
      title: Text(title),
      subtitle: Text(subtitle),
      value: value,
      onChanged: onChanged,
    );
  }
}
