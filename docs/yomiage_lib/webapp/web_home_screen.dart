// ignore_for_file: prefer_const_constructors_in_immutables, library_private_types_in_public_api, prefer_const_constructors, use_build_context_synchronously, avoid_print, unused_import, unused_field, unnecessary_import, unused_local_variable, library_prefixes, unused_element, sort_child_properties_last, unnecessary_brace_in_string_interps

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:yomiage/models/deck.dart';
import 'package:yomiage/models/flashcard.dart';
import 'package:yomiage/screens/review_mode_screen.dart';
import 'package:yomiage/screens/csv_import_screen.dart';
import 'package:yomiage/screens/csv_export_screen.dart';
import 'package:yomiage/screens/tts_setting_screen.dart';
import 'package:yomiage/screens/deck_screen.dart';
import 'package:yomiage/screens/card_edit_screen.dart';
import 'package:yomiage/screens/profile_screen.dart';
import 'package:yomiage/screens/shared_decks_screen.dart';
import 'package:yomiage/services/hive_service.dart';
import 'package:yomiage/screens/login_screen.dart';
import 'package:yomiage/services/firebase_service.dart';
import 'package:yomiage/services/sync_service.dart';
import 'package:yomiage/services/sync/notification_service.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'dart:io';
import 'dart:math' as Math;
import 'package:yomiage/webapp/web_deck_cards_screen.dart';
import 'package:yomiage/screens/deck_edit_screen.dart';
import 'package:yomiage/webapp/web_study_mode_screen.dart';
import 'package:yomiage/webapp/web_deck_table_screen.dart';
import 'package:csv/csv.dart';
import 'dart:convert';
import 'package:universal_html/html.dart' as html;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/csv_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart'; // DateFormat のためにインポート
import 'package:collection/collection.dart'; // groupBy を使用するため
import 'package:yomiage/webapp/web_csv_import_handler.dart';
import 'package:yomiage/webapp/web_settings_manager.dart';
import 'package:yomiage/webapp/web_sync_handler.dart';
import 'package:yomiage/webapp/web_deck_list_builder.dart';
import 'package:yomiage/webapp/web_database_manager.dart';
import 'package:yomiage/webapp/web_menu_handler.dart';

// StudyModeFilterのenumをここで定義せず、web_study_mode_screen.dartからインポートして使用する

class WebHomeScreen extends ConsumerStatefulWidget {
  const WebHomeScreen({Key? key}) : super(key: key);

  @override
  ConsumerState<WebHomeScreen> createState() => _WebHomeScreenState();
}

class _WebHomeScreenState extends ConsumerState<WebHomeScreen> {
  final GlobalKey _fabKey = GlobalKey();
  final int _currentIndex = 0;
  StreamSubscription? _syncStatusSubscription;
  SyncStatus _syncStatus = SyncStatus.idle;
  bool _isUserLoggedIn = FirebaseService.getUserId() != null;
  bool _isInitialLoading = true;
  bool _hasShownMainScreen = false; // 一度でも同期完了したらtrue

  // 展開状態の変数
  bool _studyExpanded = true;
  bool _sortingExpanded = true;
  bool _readingExpanded = true;

  // --- 追加: チャプター管理用 State ---
  final Map<dynamic, bool> _deckExpansionState = {};
  final Map<dynamic, List<String>> _deckChapters = {};

  // ★★★ 追加: 学習モードフィルタの状態 ★★★
  StudyModeFilter _studyModeFilter = StudyModeFilter.dueToday; // デフォルトは本日出題分

  bool _isResolvingDiscrepancy = false; // 同期処理中フラグを追加

  // デバッグログの制御
  static const bool _enableDebugLogs = false;

  void _debugPrint(String message) {
    if (_enableDebugLogs) {
      print(message);
    }
  }

  Future<void> _loadDeckChapters() async {
    await WebDatabaseManager.loadDeckChapters(
      setDeckChapters: (chaptersMap) {
        setState(() {
          _deckChapters.clear();
          _deckChapters.addAll(chaptersMap);
        });
      },
      mounted: mounted,
    );
  }

  @override
  void initState() {
    super.initState();
    WebSettingsManager.loadSettings(
      setStudyExpanded: (value) => _studyExpanded = value,
      setSortingExpanded: (value) => _sortingExpanded = value,
      setReadingExpanded: (value) => _readingExpanded = value,
      setStudyModeFilter: (value) => _studyModeFilter = value,
    );
    WebDatabaseManager.initAndLoadDatabase(
      isUserLoggedIn: _isUserLoggedIn,
      setSyncStatus: (status) => setState(() => _syncStatus = status),
      setIsInitialLoading: (loading) =>
          setState(() => _isInitialLoading = loading),
      loadDeckChapters: () => _loadDeckChapters(),
      mounted: mounted,
    );

    // 同期状態の変更を監視
    final syncService = SyncService();
    _syncStatus = _isUserLoggedIn ? SyncStatus.syncing : SyncStatus.idle;
    _syncStatusSubscription = syncService.syncStatusStream.listen((status) {
      final effectiveStatus = status;
      if (mounted && _syncStatus != effectiveStatus) {
        // print('Sync Status Updated: $effectiveStatus');
        if (effectiveStatus == SyncStatus.synced ||
            effectiveStatus == SyncStatus.idle ||
            effectiveStatus == SyncStatus.error) {
          setState(() {
            _syncStatus = effectiveStatus;
          });
          // ★★★ 追加: 同期完了後にチャプターを再読み込み ★★★
          if (effectiveStatus == SyncStatus.synced) {
            // print('Sync completed, reloading chapters...');
            _loadDeckChapters();
          }
        } else if (_syncStatus != SyncStatus.syncing &&
            effectiveStatus == SyncStatus.syncing) {
          setState(() {
            _syncStatus = effectiveStatus;
          });
        }
      }
    });

    // 認証状態の変更を監視
    FirebaseAuth.instance.authStateChanges().listen((User? user) {
      final wasLoggedIn = _isUserLoggedIn;
      final isLoggedIn = user != null;
      if (mounted) {
        setState(() {
          _isUserLoggedIn = isLoggedIn;
          _syncStatus = isLoggedIn ? SyncStatus.syncing : SyncStatus.idle;
        });
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    // 画面に戻ってきたときにデータを更新
    _refreshDatabaseState();
  }

  // データベースの状態を更新する
  Future<void> _refreshDatabaseState() async {
    await WebDatabaseManager.refreshDatabaseState(
      loadDeckChapters: _loadDeckChapters,
      setState: () => setState(() {}),
      mounted: mounted,
    );
  }

  @override
  void dispose() {
    _syncStatusSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isLoadingComplete = !_isInitialLoading &&
        (!_isUserLoggedIn || _syncStatus == SyncStatus.synced);

    if (!_hasShownMainScreen && !isLoadingComplete) {
      return Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Now Loading...',
                  style: TextStyle(color: Theme.of(context).textTheme.bodyLarge?.color, fontSize: 18)),
            ],
          ),
        ),
      );
    }

    if (!_hasShownMainScreen && isLoadingComplete) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_hasShownMainScreen) {
          setState(() {
            _hasShownMainScreen = true;
          });
        }
      });
      return Container(color: Theme.of(context).scaffoldBackgroundColor);
    }

    final screens = [
      WebDeckListBuilder.buildDeckList(
        context,
        _syncStatus,
        _isUserLoggedIn,
        _deckExpansionState,
        _deckChapters,
        _studyModeFilter,
        () => setState(() {}),
      ),
      const DeckScreen(),
      const ProfileScreen(),
    ];

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Container(
        color: Theme.of(context).scaffoldBackgroundColor,
        width: double.infinity,
        height: double.infinity,
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 800),
            child: Scaffold(
              appBar: AppBar(
                title: Row(
                  children: [
                    const Text('yomiage'),
                    if (_isUserLoggedIn &&
                        _syncStatus == SyncStatus.syncing) ...[
                      const SizedBox(width: 8),
                      SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor:
                                  AlwaysStoppedAnimation<Color>(Theme.of(context).appBarTheme.foregroundColor ?? Colors.white))),
                    ] else if (_isUserLoggedIn &&
                        _syncStatus == SyncStatus.error) ...[
                      const SizedBox(width: 8),
                      const Icon(Icons.error_outline,
                          color: Colors.red, size: 18),
                    ]
                  ],
                ),
                primary: false,
                actions: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8.0),
                    child: Tooltip(
                      message: _studyModeFilter == StudyModeFilter.allCards
                          ? '全問出題モード\n全カードを出題'
                          : '本日出題分のみモード\n今日の復習対象カードのみ出題',
                      waitDuration: Duration(milliseconds: 500),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '全問出題',
                            style: TextStyle(
                              color:
                                  _studyModeFilter == StudyModeFilter.allCards
                                      ? Colors.amber
                                      : Theme.of(context).appBarTheme.foregroundColor,
                            ),
                          ),
                          const SizedBox(width: 4),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor:
                                  _studyModeFilter == StudyModeFilter.allCards
                                      ? Colors.amber
                                      : Theme.of(context).colorScheme.secondary,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              minimumSize: const Size(0, 0),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            onPressed: () {
                              setState(() {
                                final isOn = _studyModeFilter ==
                                    StudyModeFilter.allCards;
                                _studyModeFilter = isOn
                                    ? StudyModeFilter.dueToday
                                    : StudyModeFilter.allCards;
                                WebSettingsManager.saveStudyModeFilter(
                                    _studyModeFilter);
                              });

                              final message =
                                  _studyModeFilter == StudyModeFilter.allCards
                                      ? '総復習モード: 全カードが出題されます'
                                      : '本日出題分のみ出題モード: 今日は復習対象カードのみが出題されます';
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(message),
                                  duration: const Duration(seconds: 2),
                                ),
                              );
                            },
                            child: Text(
                              _studyModeFilter == StudyModeFilter.allCards
                                  ? 'オン'
                                  : 'オフ',
                              style: TextStyle(color: Theme.of(context).appBarTheme.foregroundColor),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.folder_copy),
                    tooltip: 'デッキ一覧',
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const WebDeckTableScreen(),
                        ),
                      );
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.person),
                    tooltip: 'アカウント設定',
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const ProfileScreen()),
                      );
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.file_upload),
                    tooltip: 'CSV取り込み',
                    onPressed: () => WebCsvImportHandler.importCsvWeb(
                        context, _refreshDatabaseState),
                  ),
                  IconButton(
                    icon: const Icon(Icons.file_download),
                    tooltip: 'CSV出力',
                    onPressed: () async {
                      try {
                        await CsvService.exportAllCsv(isWeb: true);
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('CSVファイルのダウンロードを開始しました')),
                          );
                        }
                      } catch (e) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('CSVエクスポートエラー: $e')),
                          );
                        }
                      }
                    },
                  ),
                  _isResolvingDiscrepancy
                      ? Padding(
                          padding: const EdgeInsets.only(right: 16.0),
                          child: Center(
                            child: SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Theme.of(context).appBarTheme.foregroundColor,
                              ),
                            ),
                          ),
                        )
                      : IconButton(
                          icon: const Icon(Icons.sync),
                          tooltip: 'データの同期と差異解決',
                          onPressed: () =>
                              WebSyncHandler.resolveDiscrepanciesAndShowResult(
                            context,
                            _isResolvingDiscrepancy,
                            (value) =>
                                setState(() => _isResolvingDiscrepancy = value),
                            _refreshDatabaseState,
                          ),
                        ),
                ],
              ),
              backgroundColor: Theme.of(context).scaffoldBackgroundColor,
              body: screens[_currentIndex],
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
            ),
          ),
        ),
      ),
    );
  }
}
