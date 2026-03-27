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
import 'src/asset_import.dart';
import 'src/database/local_db.dart';
import 'src/database/local_database.dart';
import 'src/init_sqflite_stub.dart' if (dart.library.io) 'src/init_sqflite_io.dart' as init_sqflite;
import 'src/repositories/subject_repository.dart';
import 'src/sync/ensure_synced_for_local_read.dart';
import 'src/services/study_timer_service.dart';
import 'src/sync/sync_engine.dart';
import 'src/widgets/force_sync_icon_button.dart';
import 'src/widgets/study_time_user_activity_scope.dart';
import 'src/screens/four_choice_list_screen.dart';
import 'src/screens/knowledge_list_screen.dart';
import 'src/screens/english_example_list_screen.dart';
import 'src/screens/learner_home_screen.dart';
import 'src/screens/learner_learning_status_menu_screen.dart';
import 'src/screens/learner_login_screen.dart';
import 'src/screens/memorization_list_screen.dart';
import 'src/learner_admin.dart';
import 'src/screens/learner_management_screen.dart';
import 'src/screens/settings_screen.dart';
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
    if (_role == 'teacher') {
      // 教師は既に管理画面がルートなので何もしない
      final navigator = Navigator.maybeOf(context, rootNavigator: true) ?? Navigator.of(context);
      navigator.popUntil((route) => route.isFirst);
      return;
    }
    // 学習者フロー（'教師'ショートカット等）→ 管理画面をモーダルで表示
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
      _LearnerReviewTab(displayId: _learnerDisplayId),
      LearnerLearningStatusMenuScreen(localDatabase: widget.localDatabase),
      _LearnerKnowledgeTab(localDatabase: widget.localDatabase),
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

  /// 教師向け：管理画面（ロール確認付き）
  Widget _buildTeacherRoot() {
    if (_role == 'teacher') {
      final teacherEmail = appAuthNotifier.currentUser?.email ?? '';
      return Scaffold(
        body: Column(
          children: [
            if (_postLoginSubjectsCheck != null) _buildSubjectsCheckBanner(),
            if (teacherEmail.isNotEmpty)
              Material(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(
                      children: [
                        Icon(Icons.person_outline,
                            size: 16,
                            color: Theme.of(context).colorScheme.onSurfaceVariant),
                        const SizedBox(width: 6),
                        Text(
                          '教師ID: $teacherEmail',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            Expanded(
              child: TeacherAdminPage(
                localDb: widget.localDb,
                localDatabase: widget.localDatabase,
                onRefreshAuthAndRetry: () async {
                  appAuthNotifier.clearRoleCache();
                  await _refreshRole();
                  if (mounted) setState(() {});
                },
              ),
            ),
          ],
        ),
      );
    }
    // role == null（取得中 or 失敗）
    if (_role == null && !_teacherTabRoleRetried) {
      _teacherTabRoleRetried = true;
      appAuthNotifier.clearRoleCache();
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await _refreshRole();
        if (mounted) setState(() {});
      });
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    // teacher 権限なし
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline,
                  size: 48, color: Theme.of(context).colorScheme.outline),
              const SizedBox(height: 16),
              const Text('このアカウントには教材管理の権限がありません'),
              const SizedBox(height: 8),
              Text(
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
    return LearnerHomeScreen(
      localDatabase: widget.localDatabase,
    );
  }

  /// Windows / macOS / Linux のみナビに出す。学習メニューをスマホ相当幅で確認する。
  Widget _buildLearnerMobilePreviewTab() {
    if (!_authReady) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!appAuthNotifier.isLoggedIn) {
      return const LearnerLoginScreen();
    }
    return LearnerHomeScreen(
      localDatabase: widget.localDatabase,
      embedInDesktopMobileFrame: true,
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

    // ロールに応じてUI分岐
    if (_role == 'learner' ||
        (_role == null && _loginGateMode == _LoginGateMode.learner)) {
      return _buildLearnerRoot();
    }
    return _buildTeacherRoot();
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

// ---------------------------------------------------------------------------
// 学習者向け新規タブウィジェット
// ---------------------------------------------------------------------------

/// 復習タブ（プレースホルダ）：生徒IDを表示し、近日追加予定のメッセージを表示
class _LearnerReviewTab extends StatelessWidget {
  const _LearnerReviewTab({this.displayId});

  final String? displayId;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('復習'),
        actions: [
          const ForceSyncIconButton(),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '設定',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const SettingsScreen(),
                ),
              );
            },
          ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.badge_outlined, size: 16, color: scheme.onPrimaryContainer),
                    const SizedBox(width: 6),
                    Text(
                      displayId != null ? '生徒ID: $displayId' : '生徒',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: scheme.onPrimaryContainer,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 40),
              Icon(Icons.replay, size: 72, color: scheme.outline),
              const SizedBox(height: 20),
              Text(
                '復習',
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              Text(
                '復習機能は近日公開予定です',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 参考書タブ：科目一覧から知識カードへ（学習者モード）
class _LearnerKnowledgeTab extends StatefulWidget {
  const _LearnerKnowledgeTab({this.localDatabase});

  final LocalDatabase? localDatabase;

  @override
  State<_LearnerKnowledgeTab> createState() => _LearnerKnowledgeTabState();
}

class _LearnerKnowledgeTabState extends State<_LearnerKnowledgeTab> {
  List<Map<String, dynamic>> _subjects = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fetchSubjects();
    });
  }

  Future<void> _fetchSubjects() async {
    if (mounted) setState(() { _loading = true; _error = null; });
    try {
      if (widget.localDatabase != null) {
        final repo = createSubjectRepository(widget.localDatabase);
        final rows = await repo.getSubjectsOrderByDisplayOrder();
        if (mounted) setState(() { _subjects = rows; _loading = false; });
      } else {
        final rows = await Supabase.instance.client
            .from('subjects')
            .select()
            .order('display_order');
        if (mounted) {
          setState(() {
            _subjects = List<Map<String, dynamic>>.from(rows);
            _loading = false;
          });
        }
      }
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('参考書'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _fetchSubjects,
            tooltip: '再読み込み',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(_error!,
                            style: Theme.of(context).textTheme.bodyMedium,
                            textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: _fetchSubjects,
                          icon: const Icon(Icons.refresh),
                          label: const Text('再試行'),
                        ),
                      ],
                    ),
                  ),
                )
              : _subjects.isEmpty
                  ? const Center(child: Text('科目がありません'))
                  : ListView.separated(
                      itemCount: _subjects.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final s = _subjects[index];
                        final subjectId = s['id'] as String?;
                        final subjectName = s['name']?.toString() ?? '科目';
                        if (subjectId == null) return const SizedBox.shrink();
                        return ListTile(
                          title: Text(subjectName),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => KnowledgeListScreen(
                                  subjectId: subjectId,
                                  subjectName: subjectName,
                                  localDatabase: widget.localDatabase,
                                  isLearnerMode: true,
                                ),
                              ),
                            );
                          },
                        );
                      },
                    ),
    );
  }
}

// ---------------------------------------------------------------------------

/// 起動時初期画面：知識DB の科目一覧（タップでその科目の知識カード一覧へ）
/// 表示されるのはログイン後のみ（未ログイン時はタブ自体を出さない）。
class KnowledgeDbHomePage extends StatefulWidget {
  const KnowledgeDbHomePage({super.key, this.localDb, this.localDatabase});

  final Database? localDb;
  final LocalDatabase? localDatabase;

  @override
  State<KnowledgeDbHomePage> createState() => _KnowledgeDbHomePageState();
}

class _KnowledgeDbHomePageState extends State<KnowledgeDbHomePage> {
  List<Map<String, dynamic>> _subjects = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    // 初回取得は1フレーム遅らせ、ログイン直後のセッション確実反映後に実行する
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fetchSubjects();
    });
  }

  Future<void> _fetchSubjects() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ensureSyncedForLocalRead();
      if (!mounted) return;
      final repo = createSubjectRepository(widget.localDatabase);
      final rows = await repo.getSubjectsOrderByDisplayOrder();
      if (mounted) {
        setState(() {
          _subjects = rows;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString());
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('知識DB'),
        actions: [
          const ForceSyncIconButton(),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _fetchSubjects,
            tooltip: '再読み込み',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(_error!, style: Theme.of(context).textTheme.bodyMedium),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: _fetchSubjects,
                          icon: const Icon(Icons.refresh),
                          label: const Text('再試行'),
                        ),
                      ],
                    ),
                  ),
                )
              : _subjects.isEmpty
                  ? const Center(child: Text('科目がありません'))
                  : ListView.separated(
                              itemCount: _subjects.length,
                              separatorBuilder: (context, index) => const Divider(height: 1),
                              itemBuilder: (context, index) {
                                final s = _subjects[index];
                                final subjectId = s['id'] as String?;
                                final subjectName = s['name']?.toString() ?? '知識カード';
                                if (subjectId == null) return const SizedBox.shrink();
                                return ListTile(
                                  title: Text(subjectName),
                                  trailing: const Icon(Icons.chevron_right),
                                  onTap: () {
                                    Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (context) => KnowledgeListScreen(
                                          subjectId: subjectId,
                                          subjectName: subjectName,
                                          localDatabase: widget.localDatabase,
                                        ),
                                      ),
                                    );
                                  },
                                );
                              },
                            ),
    );
  }
}

/// ローカル DB と Supabase の同期テスト用画面
class LearningSyncPage extends StatefulWidget {
  const LearningSyncPage({super.key, required this.localDb});

  final Database? localDb;

  @override
  State<LearningSyncPage> createState() => _LearningSyncPageState();
}

class _LearningSyncPageState extends State<LearningSyncPage> {
  bool _syncing = false;
  String _status = '未同期';
  List<Map<String, dynamic>> _localKnowledge = [];

  Database get _db => widget.localDb!;

  @override
  void initState() {
    super.initState();
    _loadLocalKnowledge();
  }

  Future<void> _loadLocalKnowledge() async {
    final rows = await _db.query('knowledge_local', orderBy: 'created_at DESC');
    setState(() {
      _localKnowledge = rows;
    });
  }

  Future<void> _insertDummyKnowledge() async {
    String? subjectId;
    try {
      final rows = await Supabase.instance.client
          .from('subjects')
          .select('id')
          .limit(1)
          .order('display_order');
      if (rows.isNotEmpty) {
        subjectId = rows.first['id']?.toString();
      }
    } catch (_) {}
    await _db.insert('knowledge_local', {
      'subject': 'english',
      'subject_id': subjectId,
      'unit': 'TOEIC basic',
      'content': 'apple',
      'description': 'りんご / 基本語彙',
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
      'synced': 0,
    });
    await _loadLocalKnowledge();
    setState(() {
      _status = 'ローカルに 1 件追加しました';
    });
  }

  Future<void> _importAssetData() async {
    setState(() {
      _syncing = true;
      _status = '参考書データをインポート中...';
    });
    try {
      final importer = AssetImport(localDb: _db);
      await importer.run();
      await _loadLocalKnowledge();
      setState(() {
        _status = 'インポート完了: 知識 ${importer.knowledgeCount} 件、問題 ${importer.questionCount} 件';
        if (importer.message != null && importer.message!.isNotEmpty) {
          _status = '$_status\n${importer.message}';
        }
      });
    } catch (e) {
      setState(() => _status = 'インポートエラー: $e');
    } finally {
      setState(() => _syncing = false);
    }
  }

  Future<void> _syncToSupabase() async {
    setState(() {
      _syncing = true;
      _status = 'Supabase と同期中...';
    });

    try {
      final client = Supabase.instance.client;

      final unsynced = await _db.query(
        'knowledge_local',
        where: 'synced = ?',
        whereArgs: [0],
      );

      for (final row in unsynced) {
        final payload = {
          'unit': row['unit'],
          'content': row['content'],
          'description': row['description'],
        };
        if (row['subject_id'] != null && row['subject_id'].toString().isNotEmpty) {
          payload['subject_id'] = row['subject_id'];
        }
        if (row['subject'] != null) payload['subject'] = row['subject'];
        final inserted = await client.from('knowledge').insert(payload).select().maybeSingle();

        if (inserted != null) {
          await _db.update(
            'knowledge_local',
            {
              'synced': 1,
              'supabase_id': inserted['id'],
              'updated_at': DateTime.now().toIso8601String(),
            },
            where: 'id = ?',
            whereArgs: [row['id']],
          );
        }
      }

      await _loadLocalKnowledge();
      setState(() {
        _status = '同期完了 (${unsynced.length} 件同期)';
      });
    } catch (e) {
      setState(() {
        _status = '同期エラー: $e';
      });
    } finally {
      setState(() {
        _syncing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || widget.localDb == null) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('ローカル同期テスト'),
        ),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'このローカルDB同期デモは現在モバイル/デスクトップ用です。\n'
              'Web 版では Supabase へのオンライン学習のみを想定しています。',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('ローカル同期テスト'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('状態:', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 120),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  _status,
                  style: TextStyle(
                    color: _status.contains('エラー') ? Colors.red.shade700 : null,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                ElevatedButton(
                  onPressed: _insertDummyKnowledge,
                  child: const Text('ローカルにダミー知識を追加'),
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  onPressed: _syncing ? null : _syncToSupabase,
                  child: const Text('Supabase へ同期'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _syncing ? null : _importAssetData,
              icon: const Icon(Icons.upload_file),
              label: const Text('参考書データをインポート'),
            ),
            const SizedBox(height: 24),
            const Text(
              'ローカル knowledge 一覧',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: _localKnowledge.length,
                itemBuilder: (context, index) {
                  final row = _localKnowledge[index];
                  final desc = row['description']?.toString() ?? '';
                  final descShort = desc.length > 80 ? '${desc.substring(0, 80)}...' : desc;
                  return ListTile(
                    title: Text(row['content']?.toString() ?? ''),
                    subtitle: Text(
                      '${row['unit'] ?? '-'}${descShort.isNotEmpty ? ' · $descShort' : ''}\n'
                      'subject: ${row['subject']} / synced: ${row['synced'] == 1 ? 'はい' : 'いいえ'}',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 教師（管理者）向け管理画面
class TeacherAdminPage extends StatefulWidget {
  const TeacherAdminPage({
    super.key,
    this.localDb,
    this.localDatabase,
    this.onRefreshAuthAndRetry,
  });

  final Database? localDb;
  final LocalDatabase? localDatabase;
  /// 権限キャッシュをクリアして親で再取得する。科目が空のときの「データを再取得」で使用。
  final Future<void> Function()? onRefreshAuthAndRetry;

  @override
  State<TeacherAdminPage> createState() => _TeacherAdminPageState();
}

class _TeacherAdminPageState extends State<TeacherAdminPage> {
  bool _loading = false;
  String? _error;
  List<Map<String, dynamic>> _subjects = [];

  @override
  void initState() {
    super.initState();
    // 初回取得は1フレーム遅らせ、ログイン直後のセッション確実反映後に実行する
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fetchSubjects();
    });
  }

  Future<void> _fetchSubjects() async {
    setState(() => _loading = true);
    setState(() => _error = null);
    try {
      final client = Supabase.instance.client;
      final rows = await client.from('subjects').select().order('display_order');
      if (mounted) {
        setState(() {
          _subjects = List<Map<String, dynamic>>.from(rows);
          _error = null;
        });
      }
    } catch (e, stack) {
      if (mounted) {
        setState(() => _error = '${e.runtimeType}: ${e.toString()}\n\n$stack');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Supabase 接続と DB の有無を確認する（詳細表示用）
  Future<void> _testConnection() async {
    setState(() => _loading = true);
    setState(() => _error = null);
    try {
      final client = Supabase.instance.client;
      final row = await client.from('subjects').select('id').limit(1).maybeSingle();
      if (mounted) {
        if (row != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('接続成功: Supabase に接続できました。')),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('接続できましたが、科目が0件です。RLS・権限または接続先プロジェクトを確認してください。'),
            ),
          );
        }
        await _fetchSubjects();
      }
    } catch (e, stack) {
      if (mounted) {
        setState(() => _error =
            '接続テスト結果:\n'
            '${e.runtimeType}: ${e.toString()}\n\n'
            'StackTrace:\n$stack\n\n'
            '--- 上記をコピーして共有してください ---');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _showAddSubjectDialog() async {
    final nameController = TextEditingController();
    final orderController = TextEditingController(
      text: (_subjects.length + 1).toString(),
    );

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('科目を追加'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '科目名（例: 英文法 / 英単語 / 世界史）',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: orderController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '表示順',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('追加'),
          ),
        ],
      ),
    );

    nameController.dispose();
    orderController.dispose();

    if (confirmed != true || !mounted) return;

    final name = nameController.text.trim();
    if (name.isEmpty) return;
    final order = int.tryParse(orderController.text.trim()) ?? _subjects.length + 1;

    try {
      final client = Supabase.instance.client;
      await client.from('subjects').insert({'name': name, 'display_order': order});
      await _fetchSubjects();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('追加エラー: $e')),
        );
      }
    }
  }

  Future<void> _importAssetData() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final importer = AssetImport(localDb: widget.localDb);
      await importer.run();
      if (!kIsWeb && SyncEngine.isInitialized) {
        await SyncEngine.instance.syncIfOnline();
      }
      await _fetchSubjects();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '参考書データをインポートしました: 知識 ${importer.knowledgeCount} 件、問題 ${importer.questionCount} 件（knowledge.json のタグ・構文フラグは Supabase に同期済み）',
            ),
          ),
        );
        if (importer.message != null && importer.message!.isNotEmpty) {
          setState(() => _error = 'インポート時の注意: ${importer.message!.trim()}');
        }
      }
    } catch (e) {
      setState(() => _error = 'インポートエラー: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  /// 既存の knowledge 行に対し、knowledge.json の tags と construction を Supabase へ書き込む（重複エラーを避けたいとき用）。
  Future<void> _syncTagsFromAssetsOnly() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final importer = AssetImport(localDb: widget.localDb);
      await importer.syncTagsFromAssetsOnly();
      if (!kIsWeb && SyncEngine.isInitialized) {
        await SyncEngine.instance.syncIfOnline();
      }
      await _fetchSubjects();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('knowledge.json のタグ・構文フラグを Supabase に反映しました（ローカルへ Pull 済み）'),
          ),
        );
        if (importer.message != null && importer.message!.isNotEmpty) {
          final note = importer.message!.trim();
          setState(() => _error = '同期の注意: $note');
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(note, style: const TextStyle(fontSize: 13)),
              duration: const Duration(seconds: 12),
              backgroundColor: Theme.of(context).colorScheme.errorContainer,
              action: SnackBarAction(
                label: '閉じる',
                textColor: Theme.of(context).colorScheme.onErrorContainer,
                onPressed: () {
                  ScaffoldMessenger.of(context).hideCurrentSnackBar();
                },
              ),
            ),
          );
        }
      }
    } catch (e) {
      setState(() => _error = 'knowledge.json 同期エラー: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  void _copyErrorAndShowDialog(BuildContext context, String text) {
    Clipboard.setData(ClipboardData(text: text));
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
            controller: TextEditingController(text: text),
            style: const TextStyle(fontSize: 12),
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              isDense: true,
              contentPadding: EdgeInsets.all(12),
              alignLabelWithHint: true,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('閉じる'),
          ),
          FilledButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('クリップボードにコピーしました')),
              );
            },
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('もう一度コピー'),
          ),
        ],
      ),
    );
  }

  void _openKnowledgeDb() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => _SubjectPickerPage(
          subjects: _subjects,
          title: '知識DB',
          dbType: _TeacherDbType.knowledge,
          localDatabase: widget.localDatabase,
        ),
      ),
    );
  }

  static const _englishGrammarSubjectName = '英文法';

  void _openEnglishGrammarKnowledgeDb() {
    Map<String, dynamic>? row;
    for (final s in _subjects) {
      if (s['name']?.toString() == _englishGrammarSubjectName) {
        row = s;
        break;
      }
    }
    final subjectId = row?['id'] as String?;
    if (subjectId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            '科目「$_englishGrammarSubjectName」が見つかりません。「知識DB」から科目を確認するか、科目を追加してください。',
          ),
        ),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => KnowledgeListScreen(
          subjectId: subjectId,
          subjectName: _englishGrammarSubjectName,
          localDatabase: widget.localDatabase,
        ),
      ),
    );
  }

  void _openMemorizationDb() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => _SubjectPickerPage(
          subjects: _subjects,
          title: '暗記DB',
          dbType: _TeacherDbType.memorization,
          localDatabase: widget.localDatabase,
        ),
      ),
    );
  }

  void _openEnglishExampleDb() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => const EnglishExampleListScreen(),
      ),
    );
  }

  void _openFourChoice() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => const FourChoiceListScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('教材管理'),
        actions: [
          const ForceSyncIconButton(),
          IconButton(
            icon: const Icon(Icons.wifi_find),
            tooltip: 'Supabase 接続テスト',
            onPressed: _loading ? null : _testConnection,
          ),
          IconButton(
            icon: const Icon(Icons.upload_file),
            tooltip: '参考書データをインポート',
            onPressed: _loading ? null : _importAssetData,
          ),
          IconButton(
            icon: const Icon(Icons.label_outline),
            tooltip: 'タグ・構文フラグを knowledge.json → Supabase に反映',
            onPressed: _loading ? null : _syncTagsFromAssetsOnly,
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '科目を追加',
            onPressed: _loading ? null : _showAddSubjectDialog,
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '設定',
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
      body: Column(
        children: [
          if (_loading) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('エラーが発生しました。下の「コピー」で全文をコピーできます。'),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      FilledButton.icon(
                        onPressed: () => _copyErrorAndShowDialog(context, _error!),
                        icon: const Icon(Icons.copy, size: 20),
                        label: const Text('エラー全文をコピー'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        onPressed: _loading ? null : _fetchSubjects,
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('再読み込み'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          Expanded(
            child: _subjects.isEmpty
                ? _loading
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const CircularProgressIndicator(),
                            const SizedBox(height: 16),
                            Text(
                              '再取得中...',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ],
                        ),
                      )
                    : Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Text('科目がまだありません'),
                            const SizedBox(height: 8),
                            Text(
                              'ログイン直後や別端末の場合は「データを再取得」を試してください。',
                              style: Theme.of(context).textTheme.bodySmall,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 16),
                            FilledButton.icon(
                              onPressed: _loading
                                  ? null
                                  : () async {
                                      setState(() {
                                        _loading = true;
                                        _error = null;
                                      });
                                      try {
                                        await widget.onRefreshAuthAndRetry?.call();
                                        if (!mounted) return;
                                        await _fetchSubjects();
                                      } catch (e, st) {
                                        if (mounted) {
                                          setState(() => _error =
                                              '再取得でエラー:\n${e.runtimeType}: $e\n\n$st');
                                        }
                                      } finally {
                                        if (mounted) {
                                          setState(() => _loading = false);
                                        }
                                      }
                                    },
                              icon: const Icon(Icons.refresh),
                              label: const Text('データを再取得'),
                            ),
                            const SizedBox(height: 12),
                            FilledButton.icon(
                              onPressed: _showAddSubjectDialog,
                              icon: const Icon(Icons.add),
                              label: const Text('最初の科目を追加'),
                            ),
                          ],
                        ),
                      )
                : ListView(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    children: [
                      ListTile(
                        leading: const Icon(Icons.auto_stories),
                        title: const Text('英文法（知識DB）'),
                        subtitle: const Text('科目「英文法」の知識カードを管理'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _openEnglishGrammarKnowledgeDb,
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.menu_book),
                        title: const Text('知識DB'),
                        subtitle: const Text('解説メインの知識カードを管理'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _openKnowledgeDb,
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.style),
                        title: const Text('暗記DB'),
                        subtitle: const Text('表・裏の暗記カードを管理'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _openMemorizationDb,
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.translate),
                        title: const Text('英語例文DB'),
                        subtitle: const Text('表=日本語、裏=英語、解説・補足を管理'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _openEnglishExampleDb,
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.quiz_outlined),
                        title: const Text('四択問題'),
                        subtitle: const Text('四択問題の作成・一覧'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _openFourChoice,
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.people_outline),
                        title: const Text('学習者管理'),
                        subtitle: const Text('学習者アカウントの追加・削除・パスワードリセット'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (context) => const LearnerManagementScreen(),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// 知識DB / 暗記DB 用の科目選択ページ
enum _TeacherDbType { knowledge, memorization }

class _SubjectPickerPage extends StatelessWidget {
  const _SubjectPickerPage({
    required this.subjects,
    required this.title,
    required this.dbType,
    this.localDatabase,
  });

  final List<Map<String, dynamic>> subjects;
  final String title;
  final _TeacherDbType dbType;
  final LocalDatabase? localDatabase;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: subjects.isEmpty
          ? const Center(child: Text('科目がありません'))
          : ListView.separated(
              itemCount: subjects.length,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final s = subjects[index];
                final subjectId = s['id'] as String?;
                final subjectName = s['name']?.toString() ?? '科目';
                if (subjectId == null) return const SizedBox.shrink();
                return ListTile(
                  title: Text(subjectName),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    if (dbType == _TeacherDbType.knowledge) {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) => KnowledgeListScreen(
                            subjectId: subjectId,
                            subjectName: subjectName,
                            localDatabase: localDatabase,
                          ),
                        ),
                      );
                    } else if (dbType == _TeacherDbType.memorization) {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) => MemorizationListScreen(
                            subjectId: subjectId,
                            subjectName: subjectName,
                          ),
                        ),
                      );
                    } else {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) => EnglishExampleListScreen(
                            subjectId: subjectId,
                            subjectName: subjectName,
                          ),
                        ),
                      );
                    }
                  },
                );
              },
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

