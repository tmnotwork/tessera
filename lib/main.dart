import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'src/app_route_observer.dart';
import 'src/app_scope.dart';
import 'src/database/local_db.dart';
import 'src/database/local_database.dart';
import 'src/init_sqflite_stub.dart' if (dart.library.io) 'src/init_sqflite_io.dart' as init_sqflite;
import 'src/services/study_timer_service.dart';
import 'src/sync/sync_engine.dart';
import 'src/widgets/force_sync_icon_button.dart';
import 'src/widgets/study_time_user_activity_scope.dart';
import 'src/screens/english_example_list_screen.dart';
import 'src/screens/knowledge_db_home_page.dart';
import 'src/screens/learner_home_screen.dart';
import 'src/screens/learner_knowledge_tab.dart';
import 'src/screens/learner_learning_status_menu_screen.dart';
import 'src/screens/learner_login_screen.dart';
import 'src/screens/learner_review_tab.dart';
import 'src/learner_admin.dart';
import 'src/screens/settings_screen.dart';
import 'src/screens/teacher_admin_page.dart';
import 'src/screens/teacher_login_screen.dart';
import 'src/utils/platform_utils.dart';

// 実機ビルドでは .env が同梱されないため、フォールバック用の公開キー
const _fallbackSupabaseUrl = 'https://wnufzrehvhcwclnwxwim.supabase.co';
const _fallbackSupabaseAnonKey =
    'sb_publishable_6ZOloNwIgIFjF9SKRLGgmA_Yc55g0es';

Future<void> main() async {
  runZonedGuarded(() async {
    // runApp と同一ゾーンで binding を初期化（Zone mismatch 回避）
    WidgetsFlutterBinding.ensureInitialized();
    if (kIsWeb) {
      await Supabase.initialize(
        url: _fallbackSupabaseUrl,
        anonKey: _fallbackSupabaseAnonKey,
      );
      LearnerAdmin.initFromEnv(null, null); // Web ではサービスロールキーは使わない
      appAuthNotifier.init();
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
    try {
      final serviceRoleKey = dotenv.env['SUPABASE_SERVICE_ROLE_KEY']?.trim();
      LearnerAdmin.initFromEnv(serviceRoleKey, supabaseUrl);
    } catch (_) {
      LearnerAdmin.initFromEnv(null, null);
    }
    appAuthNotifier.init();
    init_sqflite.initSqliteForDesktop();
    final db = await _initLocalDb();
    StudyTimerService.instance.attachDatabase(db);
    final localDatabase = LocalDatabase(db);
    SyncEngine.init(localDatabase);
    // 未ログインで sync すると RLS により Pull が空/失敗しやすい。セッション復元済みのときだけ起動時同期。
    if (Supabase.instance.client.auth.currentSession != null) {
      SyncEngine.instance.syncIfOnline();
    }
    runApp(RootApp(localDb: db, localDatabase: localDatabase));
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
      theme: _buildLightTheme(),
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

/// ライト: 白基調・黒をアクセント（FilledButton / 強調テキスト）
ColorScheme _monoLightColorScheme() {
  return ColorScheme.fromSeed(
    seedColor: const Color(0xFF212121),
    brightness: Brightness.light,
  ).copyWith(
    primary: const Color(0xFF000000),
    onPrimary: const Color(0xFFFFFFFF),
    primaryContainer: const Color(0xFFE8E8E8),
    onPrimaryContainer: const Color(0xFF000000),
    secondary: const Color(0xFF424242),
    onSecondary: const Color(0xFFFFFFFF),
    secondaryContainer: const Color(0xFFF2F2F2),
    onSecondaryContainer: const Color(0xFF1A1A1A),
    surface: const Color(0xFFFFFFFF),
    onSurface: const Color(0xFF000000),
    surfaceContainerLow: const Color(0xFFFAFAFA),
    surfaceContainer: const Color(0xFFF7F7F7),
    surfaceContainerHigh: const Color(0xFFF2F2F2),
    surfaceContainerHighest: const Color(0xFFEDEDED),
    onSurfaceVariant: const Color(0xFF5C5C5C),
    outline: const Color(0xFFC8C8C8),
    outlineVariant: const Color(0xFFE6E6E6),
    surfaceTint: Colors.transparent,
  );
}

/// ダーク: 黒基調・白をアクセント
ColorScheme _monoDarkColorScheme() {
  return ColorScheme.fromSeed(
    seedColor: const Color(0xFFE0E0E0),
    brightness: Brightness.dark,
  ).copyWith(
    primary: const Color(0xFFFFFFFF),
    onPrimary: const Color(0xFF000000),
    primaryContainer: const Color(0xFF2E2E2E),
    onPrimaryContainer: const Color(0xFFFFFFFF),
    secondary: const Color(0xFFBDBDBD),
    onSecondary: const Color(0xFF000000),
    secondaryContainer: const Color(0xFF242424),
    onSecondaryContainer: const Color(0xFFE8E8E8),
    surface: const Color(0xFF000000),
    onSurface: const Color(0xFFFFFFFF),
    surfaceContainerLow: const Color(0xFF0A0A0A),
    surfaceContainer: const Color(0xFF121212),
    surfaceContainerHigh: const Color(0xFF161616),
    surfaceContainerHighest: const Color(0xFF1C1C1C),
    onSurfaceVariant: const Color(0xFFB3B3B3),
    outline: const Color(0xFF4A4A4A),
    outlineVariant: const Color(0xFF333333),
    surfaceTint: Colors.transparent,
  );
}

ThemeData _buildLightTheme() {
  final scheme = _monoLightColorScheme();
  return ThemeData(
    useMaterial3: true,
    fontFamily: 'NotoSansJP',
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      iconTheme: IconThemeData(color: scheme.onSurface),
      titleTextStyle: TextStyle(
        color: scheme.onSurface,
        fontSize: 20,
        fontWeight: FontWeight.w600,
        fontFamily: 'NotoSansJP',
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      elevation: 0,
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: scheme.primaryContainer,
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          fontSize: 12,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          color: selected ? scheme.primary : scheme.onSurfaceVariant,
          fontFamily: 'NotoSansJP',
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          color: selected ? scheme.primary : scheme.onSurfaceVariant,
          size: 24,
        );
      }),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: 1),
    listTileTheme: ListTileThemeData(iconColor: scheme.onSurfaceVariant),
    dialogTheme: DialogThemeData(backgroundColor: scheme.surface, surfaceTintColor: Colors.transparent),
    bottomSheetTheme: BottomSheetThemeData(backgroundColor: scheme.surface, surfaceTintColor: Colors.transparent),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: TextStyle(color: scheme.onInverseSurface, fontFamily: 'NotoSansJP'),
      actionTextColor: scheme.inversePrimary,
    ),
  );
}

ThemeData _buildDarkTheme() {
  final scheme = _monoDarkColorScheme();
  return ThemeData(
    useMaterial3: true,
    fontFamily: 'NotoSansJP',
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      iconTheme: IconThemeData(color: scheme.onSurface),
      titleTextStyle: TextStyle(
        color: scheme.onSurface,
        fontSize: 20,
        fontWeight: FontWeight.w600,
        fontFamily: 'NotoSansJP',
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      elevation: 0,
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: scheme.primaryContainer,
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          fontSize: 12,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          color: selected ? scheme.primary : scheme.onSurfaceVariant,
          fontFamily: 'NotoSansJP',
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          color: selected ? scheme.primary : scheme.onSurfaceVariant,
          size: 24,
        );
      }),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: 1),
    listTileTheme: ListTileThemeData(iconColor: scheme.onSurfaceVariant),
    dialogTheme: DialogThemeData(backgroundColor: scheme.surface, surfaceTintColor: Colors.transparent),
    bottomSheetTheme: BottomSheetThemeData(backgroundColor: scheme.surface, surfaceTintColor: Colors.transparent),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: TextStyle(color: scheme.onInverseSurface, fontFamily: 'NotoSansJP'),
      actionTextColor: scheme.inversePrimary,
    ),
  );
}

class RootApp extends StatefulWidget {
  const RootApp({super.key, required this.localDb, this.localDatabase});

  final Database? localDb;
  final LocalDatabase? localDatabase;

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
      navigatorObservers: [appRouteObserver],
      builder: (context, child) {
        final c = child ?? const SizedBox.shrink();
        if (kIsWeb) return c;
        return StudyTimeUserActivityScope(child: c);
      },
      home: RootScaffold(key: _rootScaffoldKey, localDb: widget.localDb, localDatabase: widget.localDatabase),
    );
  }
}

final _rootScaffoldKey = GlobalKey<_RootScaffoldState>();

enum _LoginGateMode { choose, learner, teacher }

class RootScaffold extends StatefulWidget {
  const RootScaffold({super.key, required this.localDb, this.localDatabase});

  final Database? localDb;
  final LocalDatabase? localDatabase;

  @override
  State<RootScaffold> createState() => _RootScaffoldState();
}

class _RootScaffoldState extends State<RootScaffold> with WidgetsBindingObserver {
  /// Windows デスクトップ起動時は教師用管理を最初に表示（タブ順: 0学習 / 1知識DB / 2教師用管理）
  int _index = isWindows ? 2 : 0;
  /// 学習者向け5タブの選択インデックス
  int _learnerTabIndex = 0;
  String? _role;
  /// 学習者のショートログインID（profiles.user_id）
  String? _learnerDisplayId;
  bool _authReady = false;
  _LoginGateMode _loginGateMode = _LoginGateMode.choose;
  /// ログイン直後の「科目が取れるか」検証結果。null=未検証または成功、非null=失敗メッセージ（画面に表示）
  String? _postLoginSubjectsCheck;
  bool _teacherTabRoleRetried = false;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  Timer? _debounceTimer;
  Timer? _resumeSyncTimer;
  /// 同期が進行中で即時実行できなかったときの再試行（他端末の変更取りこぼし防止）
  Timer? _deferredSyncTimer;

  /// Pull→Push のフル同期を試みる。実行中なら遅延して再試行する。
  void _attemptCrossDeviceSyncOrDefer() {
    if (kIsWeb || !mounted || !SyncEngine.isInitialized || !appAuthNotifier.isLoggedIn) return;
    if (!SyncEngine.instance.isSyncing) {
      unawaited(SyncEngine.instance.syncIfOnline());
      return;
    }
    _deferredSyncTimer?.cancel();
    _deferredSyncTimer = Timer(const Duration(seconds: 12), () {
      if (!mounted || !SyncEngine.isInitialized || !appAuthNotifier.isLoggedIn) return;
      unawaited(SyncEngine.instance.syncIfOnline());
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    appAuthNotifier.listen(_onAuthChanged);
    _refreshRole();
    // onAuthStateChange は listen 登録より前に initialSession が流れると取りこぼす。
    // その場合ログイン済みでも同期が一度も走らないため、1 フレーム後にログイン時だけ明示的に同期をかける。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _attemptCrossDeviceSyncOrDefer();
    });
    if (!kIsWeb && SyncEngine.isInitialized) {
      _connectivitySubscription = Connectivity().onConnectivityChanged.listen((result) {
        final hasConnection = result.any((r) => r != ConnectivityResult.none);
        if (hasConnection) {
          _debounceTimer?.cancel();
          _debounceTimer = Timer(const Duration(seconds: 3), () {
            if (!mounted) return;
            _attemptCrossDeviceSyncOrDefer();
          });
        }
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    appAuthNotifier.dispose();
    _connectivitySubscription?.cancel();
    _debounceTimer?.cancel();
    _resumeSyncTimer?.cancel();
    _deferredSyncTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (kIsWeb) return;
    _resumeSyncTimer?.cancel();
    _resumeSyncTimer = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      _attemptCrossDeviceSyncOrDefer();
    });
  }

  void _onAuthChanged() {
    _teacherTabRoleRetried = false;
    if (!appAuthNotifier.isLoggedIn) {
      _loginGateMode = _LoginGateMode.choose;
      _postLoginSubjectsCheck = null;
    }
    if (mounted) _refreshRole();
    // モバイル/デスクトップ: ログイン後に同期を1回走らせ、ローカルに subjects/knowledge を入れる（知識DBタブがローカル参照のため）
    _attemptCrossDeviceSyncOrDefer();
  }

  Future<void> _refreshRole() async {
    final role = await appAuthNotifier.fetchRole();
    String? subjectsCheck;
    if (mounted && appAuthNotifier.isLoggedIn) {
      try {
        List<dynamic> rows = await Supabase.instance.client
            .from('subjects')
            .select('id')
            .limit(10);
        if (rows.isEmpty) {
          await Future.delayed(const Duration(milliseconds: 500));
          if (!mounted) return;
          rows = await Supabase.instance.client
              .from('subjects')
              .select('id')
              .limit(10);
        }
        if (rows.isEmpty) {
          subjectsCheck = '科目が0件です。接続先の Supabase Dashboard で subjects にデータがあるか、RLS を確認してください。';
        }
      } catch (e) {
        subjectsCheck = '科目の取得に失敗しました: $e';
      }
    }
    // 学習者の場合はショートログインIDを取得
    String? learnerDisplayId;
    if (role == 'learner' && appAuthNotifier.isLoggedIn) {
      try {
        learnerDisplayId = await appAuthNotifier.fetchProfileUserId();
      } catch (_) {}
    }
    if (mounted) {
      setState(() {
        _role = role;
        _authReady = true;
        _postLoginSubjectsCheck = subjectsCheck;
        if (role == 'learner') _learnerDisplayId = learnerDisplayId;
      });
    }
  }

  void _switchToManageTab(BuildContext context) {
    // デスクトップは従来通りタブ切替
    if (isDesktop) {
      final navigator = Navigator.maybeOf(context, rootNavigator: true) ?? Navigator.of(context);
      navigator.popUntil((route) => route.isFirst);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _index = 2);
      });
      return;
    }
    // モバイルは学習者シェルがルート。教師・学習者とも管理はモーダルで開く
    final navigator = Navigator.maybeOf(context, rootNavigator: true) ?? Navigator.of(context);
    navigator.push<void>(
      MaterialPageRoute<void>(
        builder: (context) => TeacherAdminPage(
          localDb: widget.localDb,
          localDatabase: widget.localDatabase,
          onRefreshAuthAndRetry: () async {
            appAuthNotifier.clearRoleCache();
            await _refreshRole();
            if (mounted) setState(() {});
          },
        ),
      ),
    );
  }

  /// 学習フローから「英語例文を編集」: タブ切替はせず、その場から編集画面を直接開く。
  void _switchToManageTabAndOpenEnglishExamples(BuildContext context) {
    final navigator =
        Navigator.maybeOf(context, rootNavigator: true) ?? Navigator.of(context);
    navigator.push<void>(
      MaterialPageRoute<void>(
        builder: (context) => const EnglishExampleListScreen(),
      ),
    );
  }

  /// 学習者向け：5タブのボトムナビ構成（abceed スタイル）
  Widget _buildLearnerRoot() {
    final tabs = <Widget>[
      LearnerReviewTab(displayId: _learnerDisplayId),
      LearnerLearningStatusMenuScreen(localDatabase: widget.localDatabase),
      LearnerKnowledgeTab(localDatabase: widget.localDatabase),
      const LearnerFourChoiceSolveScreen(),
      const EnglishExampleListScreen(isLearnerMode: true, readAloudMenuOnly: true),
    ];
    return Scaffold(
      body: Column(
        children: [
          if (_postLoginSubjectsCheck != null) _buildSubjectsCheckBanner(),
          Expanded(child: tabs[_learnerTabIndex]),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _learnerTabIndex,
        onDestinationSelected: (i) => setState(() => _learnerTabIndex = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.replay_outlined),
            selectedIcon: Icon(Icons.replay),
            label: '復習',
          ),
          NavigationDestination(
            icon: Icon(Icons.bar_chart_outlined),
            selectedIcon: Icon(Icons.bar_chart),
            label: '学習状況',
          ),
          NavigationDestination(
            icon: Icon(Icons.menu_book_outlined),
            selectedIcon: Icon(Icons.menu_book),
            label: '参考書',
          ),
          NavigationDestination(
            icon: Icon(Icons.quiz_outlined),
            selectedIcon: Icon(Icons.quiz),
            label: '問題集',
          ),
          NavigationDestination(
            icon: Icon(Icons.volume_up_outlined),
            selectedIcon: Icon(Icons.volume_up),
            label: '読み上げ',
          ),
        ],
      ),
    );
  }

  Widget _buildSubjectsCheckBanner() {
    return Material(
      color: Theme.of(context).colorScheme.errorContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(Icons.warning_amber,
                  color: Theme.of(context).colorScheme.onErrorContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _postLoginSubjectsCheck!,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onErrorContainer,
                      fontSize: 13),
                ),
              ),
              TextButton(
                onPressed: () =>
                    setState(() => _postLoginSubjectsCheck = null),
                child: const Text('閉じる'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLearnerTab() {
    if (!_authReady) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!appAuthNotifier.isLoggedIn) {
      return const LearnerLoginScreen();
    }
    return _buildLearnerRoot();
  }

  /// Windows / macOS / Linux のみナビに出す。学習メニューをスマホ相当幅で確認する。
  Widget _buildLearnerMobilePreviewTab() {
    if (!_authReady) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!appAuthNotifier.isLoggedIn) {
      return const LearnerLoginScreen();
    }
    final scheme = Theme.of(context).colorScheme;
    const previewWidth = 390.0;
    return Scaffold(
      backgroundColor: scheme.surfaceContainerLow,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final maxH = constraints.maxHeight - 16;
            return Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Container(
                  width: previewWidth,
                  height: maxH.clamp(0, double.infinity),
                  decoration: BoxDecoration(
                    color: Theme.of(context).scaffoldBackgroundColor,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: scheme.outline.withValues(alpha: 0.35)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.12),
                        blurRadius: 20,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: _buildLearnerRoot(),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildTeacherTab() {
    if (!_authReady) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!appAuthNotifier.isLoggedIn) {
      return const TeacherLoginScreen();
    }
    if (_role == 'teacher') {
      return TeacherAdminPage(
        localDb: widget.localDb,
        localDatabase: widget.localDatabase,
        onRefreshAuthAndRetry: () async {
          appAuthNotifier.clearRoleCache();
          await _refreshRole();
          if (mounted) setState(() {});
        },
      );
    }
    // ログイン済みだが teacher ではない（role==null は profiles 未作成 or 取得失敗、role==learner は学習者）
    if (_role == null && !_teacherTabRoleRetried) {
      _teacherTabRoleRetried = true;
      appAuthNotifier.clearRoleCache();
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await _refreshRole();
        if (mounted) setState(() {});
      });
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('教材管理'),
        actions: const [ForceSyncIconButton()],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline,
                  size: 48, color: Theme.of(context).colorScheme.outline),
              const SizedBox(height: 16),
              const Text('このタブは教師専用です'),
              const SizedBox(height: 8),
              Text(
                'このアカウントには教材管理の権限がありません。'
                '権限があるはずの場合は「再読み込み」を試すか、設定からログアウトして再度ログインしてください。',
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('再読み込み'),
                onPressed: () async {
                  appAuthNotifier.clearRoleCache();
                  await _refreshRole();
                  if (mounted) setState(() {});
                },
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.settings_outlined),
                label: const Text('設定'),
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (context) => const SettingsScreen(),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    openManageNotifier.openManage = (ctx) => _rootScaffoldKey.currentState?._switchToManageTab(ctx);
    openManageNotifier.openManageEnglishExamples =
        (ctx) => _rootScaffoldKey.currentState?._switchToManageTabAndOpenEnglishExamples(ctx);

    if (!_authReady) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!appAuthNotifier.isLoggedIn) {
      return _LoginGateScreen(
        onShowLearnerLogin: () => setState(() => _loginGateMode = _LoginGateMode.learner),
        onShowTeacherLogin: () => setState(() => _loginGateMode = _LoginGateMode.teacher),
        onBack: () => setState(() => _loginGateMode = _LoginGateMode.choose),
        mode: _loginGateMode,
      );
    }

    // デスクトップ（Windows/macOS/Linux）は従来の3タブレイアウトを維持
    if (isDesktop) {
      return _buildDesktopRoot();
    }

    // モバイル（Android/iOS）: 教師・学習者とも常に 5 タブ＋ボトムナビ（管理はショートカット等からモーダル）
    return _buildLearnerRoot();
  }

  /// デスクトップ向け：従来の3タブ（学習/知識DB/教師用管理/スマホ幅）レイアウト
  Widget _buildDesktopRoot() {
    final pages = <Widget>[
      _buildLearnerTab(),
      KnowledgeDbHomePage(localDb: widget.localDb, localDatabase: widget.localDatabase),
      _buildTeacherTab(),
      _buildLearnerMobilePreviewTab(),
    ];
    return Scaffold(
      body: Column(
        children: [
          if (_postLoginSubjectsCheck != null) _buildSubjectsCheckBanner(),
          Expanded(child: pages[_index]),
        ],
      ),
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
          NavigationDestination(
            icon: Icon(Icons.smartphone_outlined),
            selectedIcon: Icon(Icons.smartphone),
            label: 'スマホ幅',
          ),
        ],
      ),
    );
  }
}

/// 未ログイン時に表示。学習者/教師のログインを選ばせ、ログイン後にアプリ本体（タブ）へ。
class _LoginGateScreen extends StatelessWidget {
  const _LoginGateScreen({
    required this.onShowLearnerLogin,
    required this.onShowTeacherLogin,
    required this.onBack,
    required this.mode,
  });

  final VoidCallback onShowLearnerLogin;
  final VoidCallback onShowTeacherLogin;
  final VoidCallback onBack;
  final _LoginGateMode mode;

  @override
  Widget build(BuildContext context) {
    if (mode == _LoginGateMode.learner) {
      return Scaffold(
        appBar: AppBar(leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: onBack)),
        body: const LearnerLoginScreen(),
      );
    }
    if (mode == _LoginGateMode.teacher) {
      return Scaffold(
        appBar: AppBar(leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: onBack)),
        body: const TeacherLoginScreen(),
      );
    }
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.school, size: 64, color: Theme.of(context).colorScheme.primary),
                const SizedBox(height: 24),
                Text(
                  'ログインしてください',
                  style: Theme.of(context).textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                FilledButton.icon(
                  onPressed: onShowLearnerLogin,
                  icon: const Icon(Icons.school),
                  label: const Text('学習者でログイン'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(double.infinity, 48),
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: onShowTeacherLogin,
                  icon: const Icon(Icons.manage_search),
                  label: const Text('教師でログイン'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 48),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<Database> _initLocalDb() async {
  final dir = await getApplicationDocumentsDirectory();
  final path = p.join(dir.path, 'tessera.db');

  return openDatabase(
    path,
    version: kLocalDbVersion,
    onCreate: (db, version) async {
      await createLocalSyncTables(db);
      await createStudySessionsTable(db);
      // 後方互換: step 11 で削除予定の knowledge_local（AssetImport / LearningSyncPage 用）
      await db.execute('''
        CREATE TABLE IF NOT EXISTS knowledge_local (
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
      if (oldVersion < 3) {
        await createLocalSyncTables(db);
      }
      if (oldVersion < 4) {
        final cols = await db.rawQuery("PRAGMA table_info('local_question_knowledge')");
        final hasIsCore = cols.any((c) => c['name']?.toString() == 'is_core');
        if (!hasIsCore) {
          await db.execute(
            'ALTER TABLE local_question_knowledge ADD COLUMN is_core INTEGER NOT NULL DEFAULT 0',
          );
        }
      }
      if (oldVersion < 5) {
        await createLocalSyncTables(db);
      }
      if (oldVersion < 6) {
        final cols = await db.rawQuery("PRAGMA table_info('local_question_learning_states')");
        final hasQsid = cols.any((c) => c['name']?.toString() == 'question_supabase_id');
        if (!hasQsid) {
          await db.execute(
            'ALTER TABLE local_question_learning_states ADD COLUMN question_supabase_id TEXT',
          );
        }
        await db.execute('''
          UPDATE local_question_learning_states
          SET question_supabase_id = (
            SELECT q.supabase_id FROM local_questions q
            WHERE q.local_id = local_question_learning_states.question_local_id
          )
          WHERE question_supabase_id IS NULL OR TRIM(COALESCE(question_supabase_id, '')) = ''
        ''');
      }
      if (oldVersion < 7) {
        for (final entry in [
          ('local_knowledge', 'dev_completed'),
          ('local_questions', 'dev_completed'),
        ]) {
          final cols = await db.rawQuery("PRAGMA table_info('${entry.$1}')");
          final has = cols.any((c) => c['name']?.toString() == entry.$2);
          if (!has) {
            await db.execute(
              "ALTER TABLE ${entry.$1} ADD COLUMN ${entry.$2} INTEGER NOT NULL DEFAULT 0",
            );
          }
        }
      }
      if (oldVersion < 8) {
        Future<void> addTagSyncColumns(String table) async {
          Future<bool> hasCol(String n) async {
            final cols = await db.rawQuery("PRAGMA table_info('$table')");
            return cols.any((c) => c['name']?.toString() == n);
          }

          if (!await hasCol('dirty')) {
            await db.execute(
              'ALTER TABLE $table ADD COLUMN dirty INTEGER NOT NULL DEFAULT 0',
            );
          }
          if (!await hasCol('deleted')) {
            await db.execute(
              'ALTER TABLE $table ADD COLUMN deleted INTEGER NOT NULL DEFAULT 0',
            );
          }
          if (!await hasCol('updated_at')) {
            await db.execute(
              'ALTER TABLE $table ADD COLUMN updated_at TEXT NOT NULL DEFAULT \'\'',
            );
            await db.execute(
              'UPDATE $table SET updated_at = created_at WHERE TRIM(COALESCE(updated_at, \'\')) = \'\'',
            );
          }
        }

        await addTagSyncColumns('local_knowledge_tags');
        await addTagSyncColumns('local_memorization_tags');
      }
      if (oldVersion < 9) {
        await createStudySessionsTable(db);
      }
      if (oldVersion < 10) {
        final cols = await db.rawQuery("PRAGMA table_info('study_sessions')");
        final hasLocalId = cols.any((c) => c['name']?.toString() == 'local_id');
        if (!hasLocalId) {
          await db.execute('''
            CREATE TABLE study_sessions_new (
              local_id      INTEGER PRIMARY KEY AUTOINCREMENT,
              supabase_id   TEXT UNIQUE,
              dirty         INTEGER NOT NULL DEFAULT 1,
              deleted       INTEGER NOT NULL DEFAULT 0,
              synced_at     TEXT,
              session_type  TEXT NOT NULL,
              content_id    TEXT,
              content_title TEXT,
              unit          TEXT,
              subject_id    TEXT,
              subject_name  TEXT,
              tts_sec       INTEGER NOT NULL DEFAULT 0,
              started_at    TEXT NOT NULL,
              ended_at      TEXT,
              duration_sec  INTEGER,
              created_at    TEXT NOT NULL
            )
          ''');
          final oldExists = cols.isNotEmpty;
          if (oldExists) {
            await db.execute('''
              INSERT INTO study_sessions_new (
                session_type, content_id, content_title, unit, subject_id, subject_name,
                tts_sec, started_at, ended_at, duration_sec, created_at, dirty, deleted
              )
              SELECT
                session_type, content_id, content_title, unit, subject_id, subject_name,
                tts_sec, started_at, ended_at, duration_sec, created_at, 1, 0
              FROM study_sessions
            ''');
            await db.execute('DROP TABLE study_sessions');
          }
          await db.execute('ALTER TABLE study_sessions_new RENAME TO study_sessions');
          await db.execute(
            'CREATE INDEX IF NOT EXISTS ix_study_sessions_started_at ON study_sessions(started_at)',
          );
        }
      }
      if (oldVersion < 11) {
        final cols = await db.rawQuery("PRAGMA table_info('study_sessions')");
        final hasUpdatedAt = cols.any((c) => c['name']?.toString() == 'updated_at');
        if (!hasUpdatedAt && cols.isNotEmpty) {
          await db.execute(
            "ALTER TABLE study_sessions ADD COLUMN updated_at TEXT NOT NULL DEFAULT ''",
          );
          await db.execute(
            "UPDATE study_sessions SET updated_at = created_at WHERE TRIM(COALESCE(updated_at, '')) = ''",
          );
        }
      }
      if (oldVersion < 12) {
        await createEnglishExampleStateTables(db);
      }
    },
    onOpen: (db) async {
      // sqflite はデフォルトで FK 制約が無効のため明示的に有効化
      await db.execute('PRAGMA foreign_keys = ON;');
    },
  );
}

