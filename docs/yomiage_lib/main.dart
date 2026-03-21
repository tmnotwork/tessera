// ignore_for_file: library_private_types_in_public_api, deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yomiage/services/hive_service.dart';
import 'package:yomiage/services/firebase_service.dart';
import 'package:yomiage/services/sync_service.dart';
import 'package:yomiage/screens/home_screen.dart';
import 'package:yomiage/screens/login_screen.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show kIsWeb, kReleaseMode;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:yomiage/webapp/web_home_screen.dart' as web_home;
import 'firebase_options.dart';
import 'package:yomiage/screens/card_edit_screen.dart';
import 'package:app_links/app_links.dart';
import 'dart:async';
import 'package:yomiage/services/theme_service.dart';
import 'package:yomiage/providers/theme_provider.dart';
import 'package:yomiage/themes/app_theme.dart';
import 'package:yomiage/services/sync/pending_operations.dart';

// グローバル変数として同期サービスのインスタンスを保持
final syncService = SyncService();

// デバッグログの制御
const bool _enableDebugLogs = false;

// MethodChannel for receiving data from native
const platform = MethodChannel('app.channel.shared.data');

void _debugPrint(String message) {
  if (_enableDebugLogs) {}
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ★★★ Firebase 初期化が完了するまで待つ ★★★
  bool firebaseInitialized = false;
  try {
    _debugPrint('Firebaseを初期化します...');
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    _debugPrint('Firebaseの初期化完了');
    // 開発中のみ App Check を有効化（リリースAPKのサイドロードを阻害しないため）
    if (!kReleaseMode) {
      await FirebaseAppCheck.instance.activate(
        androidProvider: AndroidProvider.debug,
        appleProvider: AppleProvider.debug,
        // Web 用の debug プロバイダ指定は現行版では未使用（必要なら ReCaptchaV3/Enterprise を設定）
      );
    }
    firebaseInitialized = true; // 成功フラグ
  } catch (e) {
    _debugPrint('Firebaseの初期化エラー: $e');
    // エラーが発生した場合、アプリを続行するかどうかを決定する必要があります。
    // ここでは続行しますが、エラーメッセージを表示するなどの処理が考えられます。
    firebaseInitialized = false;
  }

  // Hive 初期化 と クリーンアップ
  try {
    _debugPrint('Hiveを初期化します...');
    await HiveService.initHive();
    _debugPrint('Hiveの初期化完了');

    _debugPrint('アプリ起動時のデータベース確認');
    await HiveService.forceCompact();

    _debugPrint('重複デッキのクリーンアップを実行します...');
    await HiveService.cleanupDuplicateDecks();
    _debugPrint('重複デッキのクリーンアップ完了');
  } catch (e) {
    _debugPrint('Hiveの初期化またはクリーンアップエラー: $e');
  }

  // アプリの向きを固定
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // 透明ステータスバーの設定
  // 初期はAppBarの暗色背景に合わせて明色アイコンで暫定設定（後でBuilder内で上書きする）
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
  ));

  // データベース統計情報を表示
  HiveService.printDatabaseStats();

  // ★★★ Firebase認証状態の監視は、初期化成功時のみ行う ★★★
  if (firebaseInitialized) {
    try {
      _debugPrint('Firebase認証状態の監視を開始します...');
      // ★★★ 起動時のユーザー状態をチェックし、同期を開始するか決定 ★★★
      final initialUser = FirebaseAuth.instance.currentUser;
      if (initialUser != null) {
        _debugPrint('アプリ起動時にログイン済み: ${initialUser.uid}');
        // ログイン済みであれば同期を開始
        syncService.startAutoSync(interval: const Duration(minutes: 15));
        _debugPrint('🔄 自動同期を開始: 15分間隔');
      } else {
        _debugPrint('アプリ起動時は未ログイン');
      }

      // 認証状態の変更をリッスン
      FirebaseAuth.instance.authStateChanges().listen((User? user) async {
        _debugPrint('認証状態変更: ${user != null ? "ログイン" : "未ログイン"}');
        if (user != null) {
          if (initialUser == null || user.uid != initialUser.uid) {
            // 初回起動時以外、またはユーザーが変わった場合のみ同期開始
            _debugPrint('ログイン検出: ユーザーID=${user.uid}');
            syncService.startAutoSync(interval: const Duration(minutes: 15));
            _debugPrint('🔄 自動同期を開始: 15分間隔');
          }
        } else {
          _debugPrint('⏹️ ログアウト: 同期サービスを停止します');
          syncService.stopAutoSync();
          _debugPrint('⏹️ 自動同期を停止しました');
        }
      });
    } catch (e) {
      _debugPrint('Firebase認証監視のセットアップエラー: $e');
    }
  } else {
    _debugPrint('Firebaseが初期化されていないため、認証監視と同期は開始されません。');
  }

  // アプリのエラーハンドリング
  FlutterError.onError = (FlutterErrorDetails details) {
    _debugPrint('Flutter エラーハンドラー: ${details.exception}');
    _debugPrint('スタックトレース: ${details.stack}');
    FlutterError.presentError(details);
  };

  _debugPrint('アプリ起動: MyAppを実行します');
  runApp(
    ProviderScope(
      child: MyApp(firebaseInitialized: firebaseInitialized),
    ),
  );
}

class MyApp extends StatefulWidget {
  final bool firebaseInitialized;

  const MyApp({Key? key, required this.firebaseInitialized}) : super(key: key);

  @override
  MyAppState createState() => MyAppState();
}

class MyAppState extends State<MyApp> with WidgetsBindingObserver {
  late AppLinks _appLinks;
  StreamSubscription<Uri>? _linkSubscription;
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initAppLinks();
    _initPlatformState();
    _listenForSharedText();
  }

  @override
  void dispose() {
    _linkSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // Phase 2.5: 復帰時にpending operationsをflush（失敗しても次回で再試行）
    unawaited(PendingOperationsService.flushPendingOperations());
  }

  Future<void> _initAppLinks() async {
    _appLinks = AppLinks();

    // アプリ起動時の初期リンクを取得
    try {
      final initialUri = await _appLinks.getInitialAppLink();
      if (initialUri != null && mounted) {
        _handleLink(initialUri);
      }
    } catch (e) {
      _debugPrint('Error getting initial AppLink: $e');
    }

    // アプリが既に起動している場合のリンクをリッスン
    _linkSubscription = _appLinks.uriLinkStream.listen((uri) {
      if (mounted) {
        _handleLink(uri);
      }
    }, onError: (err) {
      _debugPrint('Error listening to AppLinks: $err');
    });
  }

  void _handleLink(Uri uri) {
    _debugPrint('Got URI: $uri');
    if (uri.scheme == 'yomiage' && uri.host == 'add-card') {
      final text = uri.queryParameters['text'];
      if (text != null && text.isNotEmpty) {
        _debugPrint('Received text for new card: $text');
        navigatorKey.currentState?.push(MaterialPageRoute(
          builder: (context) => CardEditScreen(
            initialAnswer: text,
            initialDeckNameForShare: '後で調べる',
          ),
        ));
      }
    }
  }

  // MethodChannelからテキストを受け取る処理 (主にURLスキーム経由でMainActivityのsharedText変数から取得)
  Future<void> _initPlatformState() async {
    try {
      final String? sharedText = await platform.invokeMethod('getSharedText');
      if (sharedText != null && sharedText.isNotEmpty && mounted) {
        _debugPrint(
            'Received shared text via getSharedText (likely URL scheme): $sharedText');
        navigatorKey.currentState?.push(MaterialPageRoute(
          builder: (context) => CardEditScreen(
            initialAnswer: sharedText,
            initialDeckNameForShare: '後で調べる',
          ),
        ));
      }
    } on PlatformException catch (e) {
      _debugPrint(
          "Failed to get shared text via getSharedText: '${e.message}'.");
    }
  }

  // ACTION_PROCESS_TEXT インテントから直接送られてくるテキストをリッスン
  void _listenForSharedText() {
    platform.setMethodCallHandler((call) async {
      if (call.method == "sharedTextReceived") {
        final String? text = call.arguments as String?;
        if (text != null && text.isNotEmpty && mounted) {
          _debugPrint(
              'Received text via sharedTextReceived (ACTION_PROCESS_TEXT): $text');
          navigatorKey.currentState?.push(MaterialPageRoute(
            builder: (context) => CardEditScreen(
              initialAnswer: text,
              initialDeckNameForShare: '後で調べる',
            ),
          ));
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    _debugPrint('MyApp: buildメソッドが呼ばれました');

    // 競合通知のリスナーを設定
    final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
        GlobalKey<ScaffoldMessengerState>();

    // アプリ起動後に競合通知のリスナーを設定
    WidgetsBinding.instance.addPostFrameCallback((_) {
      FirebaseService.syncConflictStream.listen((message) {
        scaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: CustomColors.warning,
            duration: const Duration(seconds: 5),
            action: SnackBarAction(
              label: '了解',
              textColor: CustomColors.getTextColor(Theme.of(context)),
              onPressed: () {
                // スナックバーを閉じる
              },
            ),
          ),
        );
      });
    });

    return Consumer(
      builder: (context, ref, child) {
        // テーマモードを監視
        final currentThemeMode = ref.watch(currentThemeModeProvider);
        final flutterThemeMode =
            ThemeService.toFlutterThemeMode(currentThemeMode);

        return MaterialApp(
          navigatorKey: navigatorKey,
          scaffoldMessengerKey: scaffoldMessengerKey,
          title: 'Yomiage',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: flutterThemeMode,
          supportedLocales: const [
            Locale('ja', 'JP'),
            Locale('en', 'US'),
          ],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          builder: (context, child) {
            // エラーウィジェットをカスタマイズ
            ErrorWidget.builder = (FlutterErrorDetails details) {
              _debugPrint('ErrorWidget.builder が呼ばれました: ${details.exception}');
              return Scaffold(
                backgroundColor: CustomColors.error,
                body: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Text(
                      'アプリでエラーが発生しました。\n${details.exception}',
                      style: TextStyle(
                          color: CustomColors.getTextColor(Theme.of(context))),
                    ),
                  ),
                ),
              );
            };

            // ステータスバーの色をテーマに応じて動的に設定
            final currentThemeMode = ref.watch(currentThemeModeProvider);
            final flutterThemeMode =
                ThemeService.toFlutterThemeMode(currentThemeMode);
            final isLightMode = flutterThemeMode == ThemeMode.light;

            SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
              statusBarColor: Colors.transparent,
              statusBarIconBrightness:
                  isLightMode ? Brightness.dark : Brightness.light,
              statusBarBrightness:
                  isLightMode ? Brightness.light : Brightness.dark,
            ));

            return MediaQuery(
              data: MediaQuery.of(context).copyWith(
                boldText: false,
                textScaler: const TextScaler.linear(1.0),
              ),
              child: child ?? const SizedBox.shrink(),
            );
          },
          home: AuthWrapper(firebaseInitialized: widget.firebaseInitialized),
        );
      },
    );
  }
}

// シンプルなスプラッシュ画面（起動時の黒画面対策）
class SimpleSplashScreen extends StatefulWidget {
  const SimpleSplashScreen({super.key});

  @override
  SimpleSplashScreenState createState() => SimpleSplashScreenState();
}

class SimpleSplashScreenState extends State<SimpleSplashScreen> {
  @override
  void initState() {
    super.initState();
    _debugPrint('スプラッシュ画面: initState 呼び出し');

    // 少し遅延してからメイン画面に遷移（レンダリング問題回避）
    Future.delayed(const Duration(milliseconds: 800), () {
      if (mounted) {
        _debugPrint('スプラッシュ画面: AuthWrapperに遷移');
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
              builder: (_) => const SafeArea(
                  child: AuthWrapper(firebaseInitialized: false))),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    _debugPrint('スプラッシュ画面: build 呼び出し');
    return Scaffold(
      backgroundColor: CustomColors.getBackgroundColor(Theme.of(context)),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'yomiage',
              style: TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.bold,
                color: CustomColors.getTextColor(Theme.of(context)),
              ),
            ),
            const SizedBox(height: 30),
            const CircularProgressIndicator(
              valueColor: AlwaysStoppedAnimation<Color>(CustomColors.info),
            ),
          ],
        ),
      ),
    );
  }
}

class AuthWrapper extends StatelessWidget {
  final bool firebaseInitialized;

  const AuthWrapper({Key? key, required this.firebaseInitialized})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    _debugPrint('AuthWrapper: buildメソッドが呼ばれました');
    // Firebaseが初期化されていない場合は直接ログイン画面に遷移
    if (!firebaseInitialized) {
      _debugPrint('Firebase未初期化のため、ログイン画面に直接遷移します');
      return const LoginScreen();
    }

    // Firebase初期化済みの場合、認証状態を監視して画面を切り替える
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        _debugPrint(
            'AuthWrapper - StreamBuilder: 接続状態=${snapshot.connectionState}');
        if (snapshot.connectionState == ConnectionState.waiting) {
          _debugPrint('AuthWrapper - StreamBuilder: 認証状態待機中...');
          return const Scaffold(
            body: Center(
              child: CircularProgressIndicator(),
            ),
          );
        } else if (snapshot.hasError) {
          _debugPrint(
              'AuthWrapper - StreamBuilder: 認証状態エラー: ${snapshot.error}');
          return const Scaffold(
            body: Center(
              child: Text('認証エラーが発生しました'),
            ),
          );
        } else if (snapshot.hasData) {
          // ログイン済み
          _debugPrint('AuthWrapper - StreamBuilder: ログイン済み、ホーム画面へ遷移');
          // ★★★ プラットフォームに応じて遷移先を切り替え ★★★
          if (kIsWeb) {
            return const web_home.WebHomeScreen();
          } else {
            return const HomeScreen();
          }
        } else {
          // 未ログイン
          _debugPrint('AuthWrapper - StreamBuilder: 未ログイン、ログイン画面へ遷移');
          return const LoginScreen();
        }
      },
    );
  }
}
