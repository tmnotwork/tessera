import 'dart:async';
import 'dart:developer' as developer;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:flutter/foundation.dart'
    show ValueListenable, ValueNotifier, kIsWeb;
import 'package:flutter/widgets.dart' show WidgetsBinding;

import '../utils/web_auth_signals_stub.dart'
    if (dart.library.html) '../utils/web_auth_signals_web.dart' as web_signals;
import '../core/feature_flags.dart';
import '../utils/perf_logger.dart';
import '../models/syncable_model.dart';
import '../models/user.dart' as app_user;
import 'app_settings_service.dart';
import 'block_service.dart';
import 'block_sync_service.dart';
import 'calendar_service.dart';
import 'local_data_clear_service.dart';
import 'mode_sync_service.dart';
import 'network_manager.dart';
import 'routine_v2_defaults_service.dart';
import 'sync_manager.dart';
import 'project_service.dart';
import 'project_sync_service.dart';
import 'sub_project_sync_service.dart';

enum AuthSessionPhase { stable, rehydrating, signedOut }

class AuthService {
  static final firebase_auth.FirebaseAuth _auth =
      firebase_auth.FirebaseAuth.instance;
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static app_user.User? _currentUser;
  static final StreamController<app_user.User?> _authStateController =
      StreamController<app_user.User?>.broadcast();
  static bool _isInitialized = false;
  static StreamSubscription<firebase_auth.User?>? _authStateSubscription;
  static bool _suppressWebNullEvents = false;
  static Timer? _legacyWebRehydrateTimer;
  static const Duration _legacyWebRehydrateGrace = Duration(seconds: 5);

  static final ValueNotifier<AuthSessionPhase> _phase =
      ValueNotifier<AuthSessionPhase>(AuthSessionPhase.stable);
  static final Completer<void> _firestorePersistenceReady = Completer<void>();
  static Completer<void>? _pendingWebRehydrate;
  static Timer? _webRehydrateTimer;
  static Duration _webRehydrateHoldBase =
      const Duration(milliseconds: 1200);
  static final String _tabId =
      DateTime.now().millisecondsSinceEpoch.toString();
  static bool _featureFlagListenerAttached = false;
  static DateTime? _webRehydrateStartedAt;
  static String? _lastKnownUid;
  static bool _webSignalsInitialized = false;
  static DateTime? _lastUserFetchAt;
  static String? _lastUserFetchUid;
  static const Duration _recentUserFetchSkipWindow = Duration(seconds: 5);
  static bool _postAuthWorkScheduled = false;
  static String? _postAuthWorkScheduledUid;
  /// Web のみ: emitUser 時は Hive 未準備のため postAuth をスケジュールせず、deferred 完了後に実行するためのフラグ。
  static bool _postAuthPendingWeb = false;
  static String? _postAuthPendingUid;
  // 新しいタブを開いた直後は FirebaseAuth がまだ IndexedDB からセッションを復元中であり、
  // この間の null イベントで rehydrating に入ると「セッションを復元しています」が表示されてしまう。
  // 初期化から一定時間は rehydrating をスキップすることで、この問題を回避する。
  static DateTime? _initializationCompletedAt;
  static const Duration _postInitRehydrateGrace = Duration(milliseconds: 1500);

  // Web multi-tab auth signals (localStorage)
  static const String _kWebLastUidKey = 'kant.auth.lastUid';
  static const String _kWebSignOutAtKey = 'kant.auth.signoutAtMs';
  static const Duration _webSignOutSignalWindow = Duration(seconds: 20);
  static const Duration _webRehydrateHoldMinWhenKnown =
      Duration(milliseconds: 6000);
  static const Duration _webRehydrateMaxTotal = Duration(seconds: 30);
  static DateTime? _webRehydrateDeadline;

  // Post-auth full sync guard:
  // - We MUST NOT run heavy "syncAll" on every idTokenChanges() event.
  // - Allow at most once per device per user (persisted), with a conservative retry throttle.
  static const String _postAuthSyncDoneKeyPrefix = 'sync.postAuthFullSyncDone.';
  static const String _postAuthSyncAttemptAtKeyPrefix =
      'sync.postAuthFullSyncAttemptAt.';
  static final Map<String, Future<void>> _postAuthSyncInFlightByUid =
      <String, Future<void>>{};
  static const Duration _postAuthSyncRetryThrottle = Duration(hours: 6);

  static String _postAuthSyncDoneKey(String uid) =>
      '$_postAuthSyncDoneKeyPrefix$uid';

  static String _postAuthSyncAttemptAtKey(String uid) =>
      '$_postAuthSyncAttemptAtKeyPrefix$uid';

  /// post-auth フル同期がこの端末・ユーザーで完了済みか（画面側フォールバック用）
  static Future<bool> hasCompletedPostAuthSync() async {
    final uid = getCurrentUserId();
    if (uid == null || uid.isEmpty) return true;
    try {
      await AppSettingsService.initialize();
      return AppSettingsService.getBool(_postAuthSyncDoneKey(uid));
    } catch (_) {
      return false;
    }
  }

  /// post-auth フル同期完了をマーク（画面側フォールバックで syncAll 成功時に呼ぶ）
  static Future<void> markPostAuthSyncCompleted() async {
    final uid = getCurrentUserId();
    if (uid == null || uid.isEmpty) return;
    try {
      await AppSettingsService.initialize();
      await AppSettingsService.setBool(_postAuthSyncDoneKey(uid), true);
    } catch (_) {}
  }

  // Initial blocks full download guard (per device per user):
  // Requirement: On first login on a device, ALL non-deleted blocks must be downloaded.
  static const String _blocksInitialFullSyncDoneKeyPrefix =
      'sync.blocks.initialFullSyncDone.';
  static const String _blocksInitialFullSyncAttemptAtKeyPrefix =
      'sync.blocks.initialFullSyncAttemptAt.';
  static const Duration _blocksInitialFullSyncRetryThrottle =
      Duration(minutes: 10);
  static final Map<String, Future<void>> _blocksInitialFullSyncInFlightByUid =
      <String, Future<void>>{};

  // Initial projects full download guard (per device per user):
  // Requirement (implicit): On first login on a device, projects must be available locally.
  // We keep this separate from post-auth syncAll so it can run even if syncAll is throttled/guarded.
  static const String _projectsInitialFullSyncDoneKeyPrefix =
      'sync.projects.initialFullSyncDone.';
  static const String _projectsInitialFullSyncAttemptAtKeyPrefix =
      'sync.projects.initialFullSyncAttemptAt.';
  static const Duration _projectsInitialFullSyncRetryThrottle =
      Duration(minutes: 10);
  static final Map<String, Future<void>> _projectsInitialFullSyncInFlightByUid =
      <String, Future<void>>{};

  /// 初回プロジェクト同期フローが「終了した」ときに true になる（同期実行・スキップ・失敗いずれでも）。
  /// ProjectListScreen 等がこれを購読し、true になった時点で _loadProjects() して一覧を更新する。
  static final ValueNotifier<bool> initialProjectSyncSettled =
      ValueNotifier<bool>(false);

  static String _projectsInitialFullSyncDoneKey(String uid) =>
      '$_projectsInitialFullSyncDoneKeyPrefix$uid';

  static String _projectsInitialFullSyncAttemptAtKey(String uid) =>
      '$_projectsInitialFullSyncAttemptAtKeyPrefix$uid';

  static String _blocksInitialFullSyncDoneKey(String uid) =>
      '$_blocksInitialFullSyncDoneKeyPrefix$uid';

  static String _blocksInitialFullSyncAttemptAtKey(String uid) =>
      '$_blocksInitialFullSyncAttemptAtKeyPrefix$uid';

  static ValueListenable<AuthSessionPhase> get sessionPhase => _phase;
  static Future<void> get firestorePersistenceReady =>
      _firestorePersistenceReady.future;

  static void markFirestorePersistenceReady() {
    if (!_firestorePersistenceReady.isCompleted) {
      _firestorePersistenceReady.complete();
    }
  }

  static bool get _useMultiTabHold =>
      kIsWeb && FeatureFlags.webMultiTabAuthHold;

  static void _refreshWebHoldConfig() {
    final holdMs = FeatureFlags.webMultiTabHoldMs;
    _webRehydrateHoldBase = Duration(milliseconds: holdMs);
  }

  static void _attachFeatureFlagListener() {
    if (_featureFlagListenerAttached) return;
    FeatureFlags.addListener(_refreshWebHoldConfig);
    _featureFlagListenerAttached = true;
  }

  // AuthService初期化
  static Future<void> initialize() async {
    final initStartMs = PerfLogger.elapsedMs;
    PerfLogger.mark('AuthService.initialize.start');
    FeatureFlags.ensureInitialized();
    if (kIsWeb) {
      await PerfLogger.time(
        'AuthService.waitFirestorePersistenceReady',
        () => firestorePersistenceReady,
      );
    } else {
      markFirestorePersistenceReady();
      PerfLogger.mark('AuthService.firestorePersistence.ready');
    }
    _refreshWebHoldConfig();
    _attachFeatureFlagListener();
    _initWebSignalsIfNeeded();

    try {
      if (kIsWeb) {
        try {
          await PerfLogger.time(
            'AuthService.setPersistence',
            () => _auth.setPersistence(firebase_auth.Persistence.LOCAL),
          );
        } catch (e) {
          PerfLogger.mark(
            'AuthService.setPersistence.fail',
            {'error': e.toString()},
          );
        }
        if (!_useMultiTabHold) {
          if (_auth.currentUser == null) {
            _beginLegacyWebRehydrateHold();
          } else {
            _clearLegacyWebRehydrateHold();
          }
        }
      }

      await _authStateSubscription?.cancel();
      _authStateSubscription = null;

      final firebaseUser = _auth.currentUser;
      final hasFirebaseUser = firebaseUser != null;
      PerfLogger.mark(
        'AuthService.currentUser',
        {'present': hasFirebaseUser},
      );
      bool deferredUserLoad = false;
      if (firebaseUser != null) {
        if (firebaseUser.isAnonymous) {
          await _rejectAnonymousSession(firebaseUser, origin: 'initialize');
        } else {
          _rememberSignedInUid(firebaseUser.uid);
          if (_currentUser == null || _currentUser!.id != firebaseUser.uid) {
            _currentUser = _buildFallbackUser(firebaseUser);
            PerfLogger.mark(
              'AuthService.fallbackUser.set',
              {'uid': firebaseUser.uid},
            );
          }
          // 1回だけ Firestore 取得し、idTokenChanges 発火時の重複をスキップさせる
          await _processSignedInUser(firebaseUser);
          deferredUserLoad = true;
        }
      } else {
        _currentUser = null;
      }

      _authStateSubscription =
          _auth.idTokenChanges().listen((firebaseUser) async {
        await _handleAuthStateChange(firebaseUser);
      });

      _isInitialized = true;
      _initializationCompletedAt = DateTime.now();
      _phase.value = AuthSessionPhase.stable;
      _authStateController.add(_currentUser);
      if (_currentUser != null && !kIsWeb) {
        _schedulePostAuthWork();
      }
      PerfLogger.mark(
        'AuthService.initialize.done',
        {
          'durMs': PerfLogger.elapsedMs - initStartMs,
          'hasUser': _currentUser != null,
          'deferredUserLoad': deferredUserLoad,
        },
      );
    } catch (e, stack) {
      PerfLogger.mark(
        'AuthService.initialize.fail',
        {
          'durMs': PerfLogger.elapsedMs - initStartMs,
          'error': e.toString(),
        },
      );
      developer.log(
        'AuthService initialization failed',
        error: e,
        stackTrace: stack,
        name: 'AuthService',
      );
      rethrow;
    }
  }

  static Future<void> _handleAuthStateChange(
    firebase_auth.User? firebaseUser,
  ) async {
    if (_useMultiTabHold) {
      await _handleMultiTabAuthState(firebaseUser);
      return;
    }
    await _handleLegacyAuthState(firebaseUser);
  }

  static Future<void> _handleLegacyAuthState(
    firebase_auth.User? firebaseUser,
  ) async {
    if (_shouldSuppressWebNullEvent(firebaseUser)) {
      _logAuthEvent('auth/null-suppressed');
      return;
    }
    if (kIsWeb && firebaseUser != null) {
      _clearLegacyWebRehydrateHold();
    }
    if (firebaseUser != null) {
      if (firebaseUser.isAnonymous) {
        await _rejectAnonymousSession(firebaseUser, origin: 'legacy');
        _emitNull();
        return;
      }
      _rememberSignedInUid(firebaseUser.uid);
      await _processSignedInUser(firebaseUser);
      _emitUser();
    } else {
      _currentUser = null;
      _forgetSignedInUid();
      _emitNull();
    }
  }

  static Future<void> _handleMultiTabAuthState(
    firebase_auth.User? firebaseUser,
  ) async {
    if (firebaseUser != null) {
      if (firebaseUser.isAnonymous) {
        await _rejectAnonymousSession(firebaseUser, origin: 'multiTab');
        _markSignedOut(tag: 'auth/anonymous-rejected');
        _emitNull();
        return;
      }
      _rememberSignedInUid(firebaseUser.uid);
      _clearRehydrateHold(AuthSessionPhase.stable);
      await _processSignedInUser(firebaseUser);
      _emitUser();
      return;
    }

    _logAuthEvent('auth/null-received');

    // 初期化直後のグレース期間中は null イベントを完全に無視する。
    // この間は FirebaseAuth がまだ IndexedDB からセッションを復元中の可能性が高い。
    if (_isWithinPostInitGrace()) {
      _logAuthEvent('auth/null-ignored-post-init-grace');
      return;
    }

    if (_isSignOutSignaledByOtherTab()) {
      _logAuthEvent('auth/signout-signaled');
      _markSignedOut(tag: 'auth/user-signed-out(signaled)');
      _currentUser = null;
      _forgetSignedInUid();
      _emitNull();
      return;
    }
    // FirebaseAuth Web は複数タブ同期の途中で `idTokenChanges()` が一瞬 null を流すことがある。
    // この時点で `_auth.currentUser` が残っているなら「確定ログアウト」ではないため、
    // 画面上の rehydrate 表示は出さずに無視する（偽ログアウト/復元チラつき対策）。
    final stillSignedIn = _auth.currentUser != null;
    if (stillSignedIn) {
      _logAuthEvent('auth/null-ignored-currentUser-present');
      return;
    }
    if (_beginRehydrateHoldIfNeeded()) {
      try {
        await _auth.currentUser?.reload();
      } catch (e, stack) {
        developer.log(
          'auth reload failed',
          error: e,
          stackTrace: stack,
          name: 'AuthService',
        );
      }
      return;
    }

    _logAuthEvent('auth/rehydrate-skip');
    _markSignedOut();
    _currentUser = null;
    _forgetSignedInUid();
    _emitNull();
  }

  static Future<void> _rejectAnonymousSession(
    firebase_auth.User firebaseUser, {
    required String origin,
  }) async {
    _logAuthEvent('auth/anonymous-rejected', {
      'uid': firebaseUser.uid,
      'origin': origin,
    });
    try {
      await _auth.signOut();
    } catch (_) {}
    _currentUser = null;
    _forgetSignedInUid();
  }

  static Future<void> _processSignedInUser(
    firebase_auth.User firebaseUser,
  ) async {
    final now = DateTime.now();
    if (_currentUser != null &&
        _currentUser!.id == firebaseUser.uid &&
        _lastUserFetchUid == firebaseUser.uid &&
        _lastUserFetchAt != null &&
        now.difference(_lastUserFetchAt!) < _recentUserFetchSkipWindow) {
      PerfLogger.mark(
        'AuthService.processSignedInUser.skipRecent',
        {
          'uid': firebaseUser.uid,
          'sinceMs': now.difference(_lastUserFetchAt!).inMilliseconds,
        },
      );
      return;
    }
      _currentUser = await _getUserFromFirebase(firebaseUser);
    _lastUserFetchUid = firebaseUser.uid;
    _lastUserFetchAt = DateTime.now();
    // recordStartMonth は Hive 依存のため待たずに実行（onDeferredInitComplete 等で完了する）
    unawaited(_ensureReportRecordStartMonthForCurrentUser(firebaseUser: firebaseUser));
  }

  static void _emitUser() {
    PerfLogger.event(
      'AuthService.emitUser',
      {'uid': _currentUser?.id ?? ''},
    );
    _authStateController.add(_currentUser);
    if (_currentUser != null) {
      _rememberSignedInUid(_currentUser!.id);
      if (kIsWeb) {
        _postAuthPendingWeb = true;
        _postAuthPendingUid = _currentUser!.id;
      } else {
        _schedulePostAuthWork();
      }
    }
  }

  /// Deferred 初期化（ProjectService 等）完了後に main から呼ぶ。Web で emitUser 時に保留した postAuth を 1 回だけ実行する。
  static void onDeferredInitComplete() {
    if (!kIsWeb) return;
    if (!_postAuthPendingWeb || _currentUser == null) return;
    if (_postAuthPendingUid != _currentUser!.id) return;
    _postAuthPendingWeb = false;
    _postAuthPendingUid = null;
    _schedulePostAuthWork();
    // Hive 準備済みのため、レポート用 recordStartMonth をここで設定（ログイン/復元どちらでも）
    unawaited(ensureReportRecordStartMonthWhenReady());
  }

  static void _emitNull() {
    PerfLogger.event('AuthService.emitNull');
    _authStateController.add(null);
  }

  static void _schedulePostAuthWork() {
    final uid = _currentUser?.id ?? '';
    if (uid.isEmpty) return;
    if (_postAuthWorkScheduled && _postAuthWorkScheduledUid == uid) {
      PerfLogger.mark('AuthService.postAuthWork.skipScheduled', {'uid': uid});
      return;
    }
    _postAuthWorkScheduled = true;
    _postAuthWorkScheduledUid = uid;

    void run() {
      _postAuthWorkScheduled = false;
      _postAuthWorkScheduledUid = null;
      PerfLogger.mark('AuthService.postAuthWork.start', {'uid': uid});
      // Ensure initial blocks are fully downloaded at least once per device per user.
      // We intentionally run this independent from "post-auth syncAll" to guarantee blocks availability
      // even when on-demand(dayKeys) sync can't fetch legacy blocks.
      unawaited(ensureInitialBlocksDownloaded());
      // Ensure projects are available at least once per device per user.
      unawaited(ensureInitialProjectsDownloaded());
      _triggerPostAuthSync();
    }

    try {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        run();
      });
      PerfLogger.mark('AuthService.postAuthWork.scheduled', {'uid': uid});
    } catch (_) {
      run();
    }
  }

  static app_user.User _buildFallbackUser(firebase_auth.User firebaseUser) {
    final createdAt = firebaseUser.metadata.creationTime?.toLocal() ?? DateTime.now();
    return app_user.User(
      id: firebaseUser.uid,
      email: firebaseUser.email ?? '',
      passwordHash: '',
      createdAt: createdAt,
      lastModified: DateTime.now(),
      isActive: true,
      userId: firebaseUser.uid,
    );
  }

  static void _scheduleProcessSignedInUser(
    firebase_auth.User firebaseUser,
  ) {
    final uid = firebaseUser.uid;
    if (uid.isEmpty) return;
    try {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        PerfLogger.mark(
          'AuthService.processSignedInUser.deferred.start',
          {'uid': uid},
        );
        try {
          await _processSignedInUser(firebaseUser);
        } catch (e) {
          PerfLogger.mark(
            'AuthService.processSignedInUser.deferred.fail',
            {'uid': uid, 'error': e.toString()},
          );
        }
        _authStateController.add(_currentUser);
        PerfLogger.mark(
          'AuthService.processSignedInUser.deferred.done',
          {'uid': uid, 'hasUser': _currentUser != null},
        );
      });
      PerfLogger.mark(
        'AuthService.processSignedInUser.deferred.scheduled',
        {'uid': uid},
      );
    } catch (_) {
      unawaited(
        _processSignedInUser(firebaseUser).then((_) {
          _authStateController.add(_currentUser);
        }),
      );
    }
  }

  // Firebaseユーザーからアプリユーザーを取得
  static Future<app_user.User?> _getUserFromFirebase(
    firebase_auth.User firebaseUser,
  ) async {
    final startMs = PerfLogger.elapsedMs;
    PerfLogger.mark(
      'AuthService.getUserFromFirebase.start',
      {'uid': firebaseUser.uid},
    );
    try {
      final getStartMs = PerfLogger.elapsedMs;
      final doc =
          await _firestore.collection('users').doc(firebaseUser.uid).get();
      PerfLogger.mark(
        'AuthService.getUserFromFirebase.firestoreGet',
        {
          'uid': firebaseUser.uid,
          'durMs': PerfLogger.elapsedMs - getStartMs,
          'exists': doc.exists,
        },
      );
      if (doc.exists) {
        final data = doc.data()!;
        final user = app_user.User(
          id: firebaseUser.uid,
          email: firebaseUser.email ?? '',
          passwordHash: '', // Firebaseではパスワードハッシュは管理しない
          createdAt: (data['createdAt'] as Timestamp).toDate(),
          lastModified: (data['lastModified'] as Timestamp).toDate(),
          isActive: data['isActive'] ?? true,
          userId: firebaseUser.uid, // 同期フィールド追加
        );
        PerfLogger.mark(
          'AuthService.getUserFromFirebase.done',
          {
            'uid': firebaseUser.uid,
            'durMs': PerfLogger.elapsedMs - startMs,
            'path': 'existing',
          },
        );
        return user;
      } else {
        // Firestoreにユーザー情報がない場合は新規作成
        final user = app_user.User(
          id: firebaseUser.uid,
          email: firebaseUser.email ?? '',
          passwordHash: '',
          createdAt: firebaseUser.metadata.creationTime?.toLocal() ?? DateTime.now(),
          lastModified: DateTime.now(),
          isActive: true,
          userId: firebaseUser.uid, // 同期フィールド追加
        );
        final saveStartMs = PerfLogger.elapsedMs;
        await _saveUserToFirestore(user);
        PerfLogger.mark(
          'AuthService.getUserFromFirebase.saveUser',
          {
            'uid': firebaseUser.uid,
            'durMs': PerfLogger.elapsedMs - saveStartMs,
          },
        );
        PerfLogger.mark(
          'AuthService.getUserFromFirebase.done',
          {
            'uid': firebaseUser.uid,
            'durMs': PerfLogger.elapsedMs - startMs,
            'path': 'created',
          },
        );
        return user;
      }
    } catch (e) {
      // Firestore接続エラーの場合でも、基本的なユーザー情報を返す
      if (e.toString().contains('unavailable') ||
          e.toString().contains('offline')) {
        PerfLogger.mark(
          'AuthService.getUserFromFirebase.offline',
          {
            'uid': firebaseUser.uid,
            'durMs': PerfLogger.elapsedMs - startMs,
            'error': e.toString(),
          },
        );
        return app_user.User(
          id: firebaseUser.uid,
          email: firebaseUser.email ?? '',
          passwordHash: '',
          createdAt: firebaseUser.metadata.creationTime?.toLocal() ?? DateTime.now(),
          lastModified: DateTime.now(),
          isActive: true,
          userId: firebaseUser.uid, // 同期フィールド追加
        );
      }
      PerfLogger.mark(
        'AuthService.getUserFromFirebase.error',
        {
          'uid': firebaseUser.uid,
          'durMs': PerfLogger.elapsedMs - startMs,
          'error': e.toString(),
        },
      );
      return null;
    }
  }

  // Firestoreにユーザー情報を保存
  static Future<void> _saveUserToFirestore(app_user.User user) async {
    try {
      await _firestore.collection('users').doc(user.id).set({
        'email': user.email,
        'createdAt': Timestamp.fromDate(user.createdAt),
        'lastModified': Timestamp.fromDate(user.lastModified),
        'isActive': user.isActive,
      });
    } catch (e) {
      // 接続エラーの場合は無視して続行
      if (e.toString().contains('unavailable') ||
          e.toString().contains('offline')) {}
    }
  }

  static Future<void> _ensureReportRecordStartMonthForCurrentUser({
    firebase_auth.User? firebaseUser,
  }) async {
    try {
      await _resolveAndPersistReportRecordStartMonth(firebaseUser: firebaseUser);
    } catch (_) {}
  }

  /// Hive 初期化完了後に main から呼ぶ。レポート用の recordStartMonth を設定する（ログイン直後のブロックを避ける）。
  static Future<void> ensureReportRecordStartMonthWhenReady() =>
      _ensureReportRecordStartMonthForCurrentUser(
        firebaseUser: _auth.currentUser,
      );

  static DateTime? _resolveRegistrationCreatedAt({
    firebase_auth.User? firebaseUser,
  }) {
    return firebaseUser?.metadata.creationTime?.toLocal() ??
        _auth.currentUser?.metadata.creationTime?.toLocal();
  }

  static DateTime? _resolveRegistrationMonthStart({
    firebase_auth.User? firebaseUser,
  }) {
    final createdAt = _resolveRegistrationCreatedAt(firebaseUser: firebaseUser);
    if (createdAt == null) return null;
    return DateTime(createdAt.year, createdAt.month, 1);
  }

  static Future<DateTime?> _persistRegistrationCreatedAtIfAbsent({
    firebase_auth.User? firebaseUser,
  }) async {
    final uid = getCurrentUserId();
    if (uid == null || uid.isEmpty) return null;
    final existing = AppSettingsService.getReportRegistrationCreatedAt(uid);
    if (existing != null) {
      return existing;
    }
    final createdAt = _resolveRegistrationCreatedAt(firebaseUser: firebaseUser);
    if (createdAt == null) return null;
    await AppSettingsService.setReportRegistrationCreatedAtIfAbsent(uid, createdAt);
    return AppSettingsService.getReportRegistrationCreatedAt(uid) ?? createdAt;
  }

  static Future<DateTime?> _resolveAndPersistReportRecordStartMonth({
    firebase_auth.User? firebaseUser,
  }) async {
    final uid = getCurrentUserId();
    if (uid == null || uid.isEmpty) return null;
    await AppSettingsService.initialize();
    final existing = AppSettingsService.getReportRecordStartMonth(uid);
    final registrationCreatedAt =
        await _persistRegistrationCreatedAtIfAbsent(firebaseUser: firebaseUser);
    final registrationMonthStart =
        registrationCreatedAt == null
            ? _resolveRegistrationMonthStart(firebaseUser: firebaseUser)
            : DateTime(
                registrationCreatedAt.year,
                registrationCreatedAt.month,
                1,
              );

    if (existing != null) {
      // 既存値が登録月より後ろにずれている場合は登録月へ補正する。
      // これにより「登録年が選択肢から消える」状態を防ぐ。
      if (registrationMonthStart != null && existing.isAfter(registrationMonthStart)) {
        await AppSettingsService.setReportRecordStartMonth(
          uid,
          registrationMonthStart,
        );
        return registrationMonthStart;
      }
      return existing;
    }

    if (registrationMonthStart == null) {
      return null;
    }
    await AppSettingsService.setReportRecordStartMonth(uid, registrationMonthStart);
    return registrationMonthStart;
  }

  // 現在のユーザー取得
  static app_user.User? getCurrentUser() {
    return _currentUser;
  }

  static Future<DateTime?> getOrInitializeReportRecordStartMonth() async {
    final uid = getCurrentUserId();
    if (uid == null || uid.isEmpty) return null;
    await AppSettingsService.initialize();
    return AppSettingsService.getReportRecordStartMonth(uid);
  }

  /// 認証後の自動同期をトリガー（カレンダーデータ除く）
  static void _triggerPostAuthSync() async {
    try {
      // 少し待ってからSyncManagerが初期化されていることを確認
      await Future.delayed(const Duration(milliseconds: 500));

      // Only for authenticated users.
      final firebaseUser = _auth.currentUser;
      final uid = firebaseUser?.uid ?? '';
      if (uid.isEmpty) {
        return;
      }

      await AppSettingsService.initialize();

      // Hard stop: once per device per user.
      if (AppSettingsService.getBool(_postAuthSyncDoneKey(uid))) {
        return;
      }

      // Soft stop: avoid repeated retries on token refresh storms.
      try {
        final raw = AppSettingsService.getString(_postAuthSyncAttemptAtKey(uid));
        final lastAttempt = (raw == null || raw.isEmpty)
            ? null
            : DateTime.tryParse(raw)?.toUtc();
        final now = DateTime.now().toUtc();
        if (lastAttempt != null &&
            now.difference(lastAttempt) < _postAuthSyncRetryThrottle) {
          return;
        }
      } catch (_) {}

      final inflight = _postAuthSyncInFlightByUid[uid];
      if (inflight != null) {
        await inflight;
        return;
      }

      // Ensure SyncManager is ready before attempting syncAll.
      // If it's not ready yet (common on first app start), do NOT record attempt/throttle;
      // just bail out and let the next auth event / screen sync retry naturally.
      try {
        await SyncManager.initialize();
      } catch (_) {
        return;
      }

      if (SyncManager.currentStatus != SyncStatus.syncing) {
        print('🔄 Starting post-authentication sync (excluding calendar data)...');
        final Future<void> run = () async {
          try {
            // Record attempt only when we actually start the heavy sync.
            try {
              await AppSettingsService.setString(
                _postAuthSyncAttemptAtKey(uid),
                DateTime.now().toUtc().toIso8601String(),
              );
            } catch (_) {}
            // Also ensure blocks full sync before the general sync to satisfy first-login requirement.
            await ensureInitialBlocksDownloaded();
            final result = await SyncManager.syncAll(
              reason: 'post-auth full sync',
              origin: 'AuthService.idTokenChanges',
              userId: uid,
              extra: <String, dynamic>{
                'tabId': _tabId,
                'webMultiTabHold': _useMultiTabHold,
              },
            );
            if (result.success) {
              try {
                await AppSettingsService.setBool(_postAuthSyncDoneKey(uid), true);
              } catch (_) {}
              print(
                  '✅ Post-auth sync completed: ${result.syncedCount} items synced');
              print(
                  'ℹ️ Calendar data will be synced on-demand when calendar screen is accessed');
            } else {
              print('⚠️ Post-auth sync failed: ${result.error}');
            }
          } finally {
            _postAuthSyncInFlightByUid.remove(uid);
          }
        }();
        _postAuthSyncInFlightByUid[uid] = run;
        await run;
      } else {
        print('ℹ️ Sync already in progress, skipping post-auth sync');
      }
    } catch (e) {
      print('❌ Post-auth sync error: $e');
    }
  }

  /// 初回端末ログイン時に blocks を全件ダウンロードする（ユーザー×端末で一度だけ）
  ///
  /// - `users/{uid}/blocks` から `isDeleted == false` を全件DLする。
  /// - on-demand(dayKeys) 同期では拾えない旧データ（dayKeys欠落）を確実に復元するための必須処理。
  static Future<void> ensureInitialBlocksDownloaded({bool force = false}) async {
    try {
      if (!NetworkManager.isOnline) return;

      final uid = getCurrentUserId();
      if (uid == null || uid.isEmpty) return;

      await AppSettingsService.initialize();

      // Hard stop: once per device per user.
      if (!force && AppSettingsService.getBool(_blocksInitialFullSyncDoneKey(uid))) {
        return;
      }

      // Soft stop: throttle retries to avoid hammering on repeated failures.
      if (!force) {
        try {
          final raw = AppSettingsService.getString(_blocksInitialFullSyncAttemptAtKey(uid));
          final lastAttempt = (raw == null || raw.isEmpty)
              ? null
              : DateTime.tryParse(raw)?.toUtc();
          final now = DateTime.now().toUtc();
          if (lastAttempt != null &&
              now.difference(lastAttempt) < _blocksInitialFullSyncRetryThrottle) {
            return;
          }
        } catch (_) {}
      }

      final inflight = _blocksInitialFullSyncInFlightByUid[uid];
      if (inflight != null) {
        return await inflight;
      }

      final Future<void> run = () async {
        try {
          // Record attempt early to prevent retry storms.
          try {
            await AppSettingsService.setString(
              _blocksInitialFullSyncAttemptAtKey(uid),
              DateTime.now().toUtc().toIso8601String(),
            );
          } catch (_) {}

          // Ensure local box is ready before applying remote.
          try {
            await BlockService.initialize();
          } catch (_) {}

          print('⬇️ Initial blocks full sync start (uid=$uid)');
          final result = await BlockSyncService()
              .performSync(forceFullSync: true, uploadLocalChanges: false);
          if (result.success) {
            try {
              await AppSettingsService.setBool(_blocksInitialFullSyncDoneKey(uid), true);
            } catch (_) {}
            print('✅ Initial blocks full sync completed (synced=${result.syncedCount})');
          } else {
            print('⚠️ Initial blocks full sync failed: ${result.error}');
          }
        } finally {
          _blocksInitialFullSyncInFlightByUid.remove(uid);
        }
      }();

      _blocksInitialFullSyncInFlightByUid[uid] = run;
      await run;
    } catch (e) {
      try {
        print('⚠️ ensureInitialBlocksDownloaded error: $e');
      } catch (_) {}
    }
  }

  /// 初回端末ログイン時に projects/sub_projects を一度だけダウンロードする（ユーザー×端末で一度だけ）
  ///
  /// - post-auth syncAll の失敗/スロットリングの影響で「projectsが空」のままになるのを防ぐ。
  /// - 端末/初回タイミングのレースに耐えるため、Auth ready と AppSettings 準備を明示する。
  static Future<void> ensureInitialProjectsDownloaded({bool force = false}) async {
    void markSettled() {
      if (!initialProjectSyncSettled.value) {
        initialProjectSyncSettled.value = true;
      }
    }

    try {
      // オフラインまたは uid 未確定のときは markSettled しない（UI側のリトライで再実行できるようにする）
      if (!NetworkManager.isOnline) {
        return;
      }

      final uid = getCurrentUserId();
      if (uid == null || uid.isEmpty) {
        return;
      }

      await AppSettingsService.initialize();

      // ローカルが空の場合は必ず同期（ログアウト後再ログインでフラグだけ残った場合の救済）
      final localCount = ProjectService.getAllProjects().length;
      if (!force && localCount > 0 && AppSettingsService.getBool(_projectsInitialFullSyncDoneKey(uid))) {
        markSettled();
        return;
      }

      // Soft stop: throttle retries to avoid hammering on repeated failures.
      // スキップ時は markSettled しない（同期を一度も試みていないため。UI はリスナーで同期待ちする）
      if (!force) {
        try {
          final raw = AppSettingsService.getString(
              _projectsInitialFullSyncAttemptAtKey(uid));
          final lastAttempt = (raw == null || raw.isEmpty)
              ? null
              : DateTime.tryParse(raw)?.toUtc();
          final now = DateTime.now().toUtc();
          if (lastAttempt != null &&
              now.difference(lastAttempt) < _projectsInitialFullSyncRetryThrottle) {
            return;
          }
        } catch (_) {}
      }

      final inflight = _projectsInitialFullSyncInFlightByUid[uid];
      if (inflight != null) {
        await inflight;
        markSettled();
        return;
      }

      final Future<void> run = () async {
        try {
          // Record attempt early to prevent retry storms.
          try {
            await AppSettingsService.setString(
              _projectsInitialFullSyncAttemptAtKey(uid),
              DateTime.now().toUtc().toIso8601String(),
            );
          } catch (_) {}

          print('⬇️ Initial projects full sync start (uid=$uid)');
          // Projects
          final pr = await ProjectSyncService.syncAllProjects();
          // SubProjects are tightly related to projects UI; fetch them too.
          final spr = await SubProjectSyncService.syncAllSubProjects();

          final ok = pr.success && spr.success;
          if (ok) {
            try {
              await AppSettingsService.setBool(
                  _projectsInitialFullSyncDoneKey(uid), true);
            } catch (_) {}
            print(
                '✅ Initial projects full sync completed (projects=${pr.syncedCount}, subProjects=${spr.syncedCount})');
          } else {
            final err = pr.error ?? spr.error ?? 'unknown';
            print('⚠️ Initial projects full sync failed: $err');
          }
        } finally {
          _projectsInitialFullSyncInFlightByUid.remove(uid);
          markSettled();
        }
      }();

      _projectsInitialFullSyncInFlightByUid[uid] = run;
      await run;
    } catch (e) {
      try {
        print('⚠️ ensureInitialProjectsDownloaded error: $e');
      } catch (_) {}
      if (!initialProjectSyncSettled.value) {
        initialProjectSyncSettled.value = true;
      }
    }
  }

  // メール・パスワードでサインアップ
  static Future<app_user.User?> signUpWithEmailAndPassword(
    String email,
    String password,
  ) async {
    try {
      print('🔑 DEBUG: Starting signUpWithEmailAndPassword for email: $email');

      final credential = await _auth.createUserWithEmailAndPassword(
        email: email.toLowerCase(),
        password: password,
      );

      print(
          '✅ DEBUG: Firebase user created successfully: ${credential.user!.uid}');
      print('🔍 DEBUG: Firebase user email: ${credential.user!.email}');

      final user = await _getUserFromFirebase(credential.user!);
      print('✅ DEBUG: App user created from Firebase: ${user?.id}');

      // 同一ユーザーで authStateChanges が発火したときの重複 getDoc を防ぐ
      if (user != null) {
        _lastUserFetchUid = credential.user!.uid;
        _lastUserFetchAt = DateTime.now();
      }

      // ユーザー登録時にカレンダーDBを初期化
      if (user != null) {
        print('🔄 DEBUG: Initializing user calendar...');
        await CalendarService.initializeUserCalendar(user.id);
        print('✅ DEBUG: User calendar initialized');

        // 初回登録時の初期データ作成（モード・ルーティンテンプレート）
        try {
          print('🌱 DEBUG: Creating default modes and routine templates...');
          await ModeSyncService.createDefaultModesWithSync();
        await RoutineV2DefaultsService.ensureDefaultsIfEmpty(uid: user.id);
          print('🌱 DEBUG: Default data creation completed');
        } catch (e) {
          print('⚠️ DEBUG: Default data creation error (continuing): $e');
        }
      }

      // 現在のユーザーを更新
      _currentUser = user;
      // recordStartMonth は Hive 依存のため main の onLoginSuccess 完了後に実行（登録応答を遅らせない）
      print('✅ DEBUG: Current user updated: ${_currentUser?.id}');

      // Streamに通知
      _authStateController.add(user);
      print('✅ DEBUG: Auth state sent to stream: ${user?.id}');
      // 登録直後にプロジェクトDLを確実にキック
      _schedulePostAuthWork();

      return user;
    } catch (e) {
      print('❌ DEBUG: SignUp error: $e');
      if (e.toString().contains('email-already-in-use')) {
        throw 'このメールアドレスは既に使用されています。別のメールアドレスを試してください。';
      } else if (e.toString().contains('weak-password')) {
        throw 'パスワードが弱すぎます。6文字以上で入力してください';
      } else if (e.toString().contains('invalid-email')) {
        throw '無効なメールアドレスです';
      } else if (e.toString().contains('configuration-not-found')) {
        throw 'Firebaseの設定に問題があります。管理者に連絡してください';
      } else {
        throw 'ユーザー登録に失敗しました: $e';
      }
    }
  }

  // メール・パスワードでサインイン
  static Future<app_user.User?> signInWithEmailAndPassword(
    String email,
    String password,
  ) async {
    try {
      final credential = await _auth.signInWithEmailAndPassword(
        email: email.toLowerCase(),
        password: password,
      );

      final user = await _getUserFromFirebase(credential.user!);

      // 現在のユーザーを更新
      _currentUser = user;
      // 同一ユーザーで authStateChanges が発火したときの重複 getDoc を防ぐ
      _lastUserFetchUid = credential.user!.uid;
      _lastUserFetchAt = DateTime.now();
      // recordStartMonth は Hive 依存のため、main の onLoginSuccess 完了後に実行（ログイン応答を遅らせない）
      _authStateController.add(user);
      // ログイン直後にプロジェクトDLを確実にキック（idTokenChanges の順序に依存しない）
      _schedulePostAuthWork();

      return user;
    } catch (e) {
      if (e.toString().contains('user-not-found')) {
        throw 'ユーザーが見つかりません';
      } else if (e.toString().contains('wrong-password')) {
        throw 'パスワードが間違っています';
      } else if (e.toString().contains('invalid-email')) {
        throw '無効なメールアドレスです';
      } else if (e.toString().contains('configuration-not-found')) {
        throw 'Firebaseの設定に問題があります。管理者に連絡してください';
      } else {
        throw 'ログインに失敗しました: $e';
      }
    }
  }

  // サインアウト
  static Future<void> signOut() async {
    try {
      if (_useMultiTabHold) {
        _markSignedOut(tag: 'auth/signout-requested');
      } else {
        _clearLegacyWebRehydrateHold();
      }
      _signalSignOutToOtherTabs();
      await _auth.signOut();
      _currentUser = null;
      _forgetSignedInUid();
      _emitNull();
      // ローカルデータをクリア（別ユーザーへのデータ引き継ぎ防止）
      await LocalDataClearService.clearAllUserData();
    } catch (e) {
      // intentionally ignored
    }
  }

  // 認証状態の変更を監視するストリーム
  static Stream<app_user.User?> get authStateChanges {
    if (!_isInitialized) {
      throw StateError('AuthService is not initialized');
    }

    return _authStateController.stream;
  }

  // ユーザーID取得
  static String? getCurrentUserId() {
    if (_currentUser != null && _currentUser!.id.isNotEmpty) {
      return _currentUser!.id;
    }
    // フォールバック: FirebaseAuthの現在ユーザー
    final fb = _auth.currentUser;
    return fb?.uid;
  }

  /// ローカル表示用のユーザーIDを返す。
  ///
  /// - 通常は現在の認証UIDを返す。
  /// - 認証UIDが未確定の間は、最後に確認できたUIDへフォールバックする。
  ///   これにより、認証再水和の揺れでローカル実績が一瞬空になる現象を防ぐ。
  /// - 明示的に signedOut に遷移している場合はフォールバックしない。
  static String? getPreferredUserIdForLocalRead() {
    final current = getCurrentUserId();
    if (current != null && current.isNotEmpty) {
      return current;
    }
    if (_phase.value == AuthSessionPhase.signedOut) {
      return null;
    }
    final cached = _lastKnownUid;
    if (cached == null || cached.isEmpty) {
      return null;
    }
    return cached;
  }

  /// 認証再水和の揺れ中は、ローカルの既存表示を保持してよいかを返す。
  static bool get shouldKeepLocalSnapshotForAuthRestore {
    if (getCurrentUserId() != null) return false;
    if (_phase.value == AuthSessionPhase.signedOut) return false;
    return true;
  }

  /// Firebase Auth の再水和完了を待ち、ユーザーIDを返す
  static Future<String?> waitForUserId({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final cached = getCurrentUserId();
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }

    if (!_isInitialized) {
      try {
        await initialize();
      } catch (_) {}
      final afterInit = getCurrentUserId();
      if (afterInit != null && afterInit.isNotEmpty) {
        return afterInit;
      }
    }

    final completer = Completer<String?>();
    late StreamSubscription<app_user.User?> subscription;
    Timer? timer;

    void complete(String? value) {
      if (timer?.isActive ?? false) {
        timer!.cancel();
      }
      subscription.cancel();
      if (!completer.isCompleted) {
        completer.complete(value);
      }
    }

    subscription = _authStateController.stream.listen((user) {
      final id = user?.id ?? _auth.currentUser?.uid;
      if (id != null && id.isNotEmpty) {
        complete(id);
      }
    });

    timer = Timer(timeout, () {
      complete(null);
    });

    return completer.future;
  }

  // ユーザーがログインしているかチェック
  static bool isLoggedIn() {
    // FirebaseAuthの状態を優先（リロード直後のレース対策）
    final fb = _auth.currentUser;
    if (fb != null && !fb.isAnonymous) return true;
    return _currentUser != null;
  }

  // ユーザー情報更新
  static Future<void> updateUser(app_user.User user) async {
    try {
      user.lastModified = DateTime.now();
      await _saveUserToFirestore(user);
      if (_currentUser?.id == user.id) {
        _currentUser = user;
        _authStateController.add(user);
      }
    } catch (e) {
      // intentionally ignored
    }
  }

  // ユーザー削除
  static Future<void> deleteUser(String userId) async {
    try {
      await _firestore.collection('users').doc(userId).delete();
      if (_currentUser?.id == userId) {
        _currentUser = null;
        _authStateController.add(null);
      }
    } catch (e) {
      // intentionally ignored
    }
  }

  /// 初期化直後のグレース期間内かどうかを判定する。
  /// この期間中は FirebaseAuth がまだセッションを復元中の可能性が高いため、
  /// null イベントを無視する。
  static bool _isWithinPostInitGrace() {
    if (_initializationCompletedAt == null) return false;
    final elapsed = DateTime.now().difference(_initializationCompletedAt!);
    return elapsed < _postInitRehydrateGrace;
  }

  static bool _beginRehydrateHoldIfNeeded() {
    if (!_useMultiTabHold) {
      _logAuthEvent('auth/rehydrate-not-started', {
        'reason': 'flag-off',
        'phase': _phase.value.name,
      });
      return false;
    }
    if (_phase.value == AuthSessionPhase.signedOut) {
      _logAuthEvent('auth/rehydrate-not-started', {
        'reason': 'already-signed-out',
        'phase': _phase.value.name,
      });
      return false;
    }
    // 初期化直後は FirebaseAuth がまだ IndexedDB からセッションを復元中の可能性が高い。
    // この間の null イベントで rehydrating に入ると「セッションを復元しています」が表示されてしまう。
    // 初期化から一定時間は rehydrating をスキップし、FirebaseAuth の復元を待つ。
    if (_initializationCompletedAt != null) {
      final elapsed = DateTime.now().difference(_initializationCompletedAt!);
      if (elapsed < _postInitRehydrateGrace) {
        _logAuthEvent('auth/rehydrate-not-started', {
          'reason': 'post-init-grace',
          'elapsedMs': elapsed.inMilliseconds,
          'graceMs': _postInitRehydrateGrace.inMilliseconds,
        });
        return false;
      }
    }
    // 既存タブでは `_currentUser` が何らかの理由で null になっていても、
    // 実際は FirebaseAuth が遅延再水和中のケースがある（偽ログアウトの主因）。
    // そのため「最後に見えた uid」があれば hold を開始できるようにする。
    if (_currentUser == null &&
        _auth.currentUser == null &&
        (_lastKnownUid == null || _lastKnownUid!.isEmpty)) {
      _logAuthEvent('auth/rehydrate-not-started', {
        'reason': 'no-cached-user',
        'phase': _phase.value.name,
      });
      return false;
    }
    _phase.value = AuthSessionPhase.rehydrating;
    if (_pendingWebRehydrate == null || _pendingWebRehydrate!.isCompleted) {
      _pendingWebRehydrate = Completer<void>();
    }
    // 1回のnull揺れで即ログアウトしないため、rehydrating は最大30秒まで許容する。
    // （他タブからの signOut signal がある場合は即ログアウト扱い）
    _webRehydrateDeadline ??=
        DateTime.now().add(_webRehydrateMaxTotal);
    _webRehydrateTimer?.cancel();
    final hold = _effectiveWebHoldDuration();
    _webRehydrateTimer =
        Timer(hold, _handleRehydrateHoldTimeout);
    _webRehydrateStartedAt = DateTime.now();
    _logAuthEvent('auth/rehydrate-start',
        {'holdMs': hold.inMilliseconds});
    return true;
  }

  static Duration _effectiveWebHoldDuration() {
    final base = _webRehydrateHoldBase;
    if (_lastKnownUid != null && _lastKnownUid!.isNotEmpty) {
      if (base < _webRehydrateHoldMinWhenKnown) {
        return _webRehydrateHoldMinWhenKnown;
      }
    }
    return base;
  }

  static bool _isWebPageHidden() {
    if (!kIsWeb) return false;
    try {
      return web_signals.isPageHidden();
    } catch (_) {
      return false;
    }
  }

  static Future<void> _handleRehydrateHoldTimeout() async {
    final elapsed = _webRehydrateStartedAt == null
        ? null
        : DateTime.now().difference(_webRehydrateStartedAt!);
    final context = <String, Object?>{};
    if (elapsed != null) {
      context['elapsedMs'] = elapsed.inMilliseconds;
    }
    _logAuthEvent('auth/rehydrate-timeout', context.isEmpty ? null : context);
    try {
      await _auth.currentUser?.reload();
    } catch (e, stack) {
      developer.log(
        'auth reload failed during timeout',
        error: e,
        stackTrace: stack,
        name: 'AuthService',
      );
    }
    final reloaded = _auth.currentUser;
    if (reloaded == null) {
      final now = DateTime.now();
      if (_isWebPageHidden()) {
        // When the tab is hidden, timers are throttled and FirebaseAuth may not rehydrate.
        // Reset the deadline and retry later to avoid false sign-out.
        const retry = Duration(milliseconds: 1500);
        _webRehydrateDeadline = now.add(_webRehydrateMaxTotal);
        _webRehydrateTimer?.cancel();
        _webRehydrateTimer = Timer(retry, _handleRehydrateHoldTimeout);
        _logAuthEvent('auth/rehydrate-paused-hidden', {
          if (elapsed != null) 'elapsedMs': elapsed.inMilliseconds,
          'retryMs': retry.inMilliseconds,
        });
        return;
      }
      final deadline = _webRehydrateDeadline;
      final remainingMs = deadline == null
          ? null
          : deadline.difference(now).inMilliseconds;

      // まだ猶予があるなら延長して様子を見る（偽ログアウト対策）。
      if (deadline != null && now.isBefore(deadline)) {
        // 次のチェックは短めに（UIは既にrehydratingなので、早めに復帰させたい）
        const retry = Duration(milliseconds: 1500);
        _webRehydrateTimer?.cancel();
        _webRehydrateTimer = Timer(retry, _handleRehydrateHoldTimeout);
        _logAuthEvent('auth/rehydrate-extend', {
          if (remainingMs != null) 'remainingMs': remainingMs,
          'retryMs': retry.inMilliseconds,
        });
        return;
      }

      // 最大猶予を超えたら確定ログアウト扱い
      _markSignedOut();
      _currentUser = null;
      _forgetSignedInUid();
      _emitNull();
      return;
    }
    _rememberSignedInUid(reloaded.uid);
    await _processSignedInUser(reloaded);
    _clearRehydrateHold(AuthSessionPhase.stable);
    _emitUser();
  }

  /// Web 起動時のみ。localStorage から lastUid を同期的に読み、初回表示の判定に使う。
  /// Firebase 初期化前に main から呼ぶ。ログイン済みならローディング→本編、未ログインなら即ログイン画面の両立用。
  static void prepareWebBootAuthHint() {
    _initWebSignalsIfNeeded();
  }

  /// prepareWebBootAuthHint() 呼び出し後に使用。localStorage に「ログインしていた痕跡」があれば true。
  /// 他タブのサインアウトシグナルがあれば false。
  static bool mightHaveStoredSessionForBoot() {
    if (!kIsWeb) return false;
    if (_lastKnownUid == null || _lastKnownUid!.isEmpty) return false;
    return !_isSignOutSignaledByOtherTab();
  }

  static void _initWebSignalsIfNeeded() {
    if (!kIsWeb) return;
    if (_webSignalsInitialized) return;
    _webSignalsInitialized = true;

    try {
      final storedUid = web_signals.readWebStorage(_kWebLastUidKey);
      if (storedUid != null && storedUid.isNotEmpty) {
        _lastKnownUid = storedUid;
      }
    } catch (_) {}

    try {
      web_signals.attachWebStorageListener((key, newValue) {
        if (key == _kWebSignOutAtKey) {
          // 他タブのサインアウト要求は即反映（偽ログアウト対策の hold より優先）
          _logAuthEvent('auth/signout-storage-event', {'value': newValue ?? ''});
          _markSignedOut(tag: 'auth/user-signed-out(storage-event)');
          _currentUser = null;
          _forgetSignedInUid();
          _emitNull();
          return;
        }
        if (key == _kWebLastUidKey) {
          if (newValue != null && newValue.isNotEmpty) {
            _lastKnownUid = newValue;
          }
        }
      });
    } catch (_) {}
  }

  static void _rememberSignedInUid(String uid) {
    if (uid.isEmpty) return;
    _lastKnownUid = uid;
    if (!kIsWeb) return;
    try {
      web_signals.writeWebStorage(_kWebLastUidKey, uid);
    } catch (_) {}
  }

  static void _forgetSignedInUid() {
    _lastKnownUid = null;
    // localStorage の lastUid は「最後にログインしていた痕跡」なので、消すのはローカルのみ。
    // （他タブが rehydrate 判定に使うため）
  }

  static void _signalSignOutToOtherTabs() {
    if (!kIsWeb) return;
    try {
      web_signals.writeWebStorage(
        _kWebSignOutAtKey,
        DateTime.now().millisecondsSinceEpoch.toString(),
      );
    } catch (_) {}
  }

  static bool _isSignOutSignaledByOtherTab() {
    if (!kIsWeb) return false;
    try {
      final raw = web_signals.readWebStorage(_kWebSignOutAtKey);
      if (raw == null || raw.isEmpty) return false;
      final ms = int.tryParse(raw);
      if (ms == null) return false;
      final at = DateTime.fromMillisecondsSinceEpoch(ms);
      final diff = DateTime.now().difference(at);
      return diff >= Duration.zero && diff <= _webSignOutSignalWindow;
    } catch (_) {
      return false;
    }
  }

  static void _clearRehydrateHold(AuthSessionPhase nextPhase) {
    _webRehydrateTimer?.cancel();
    _webRehydrateTimer = null;
    if (_pendingWebRehydrate != null && !_pendingWebRehydrate!.isCompleted) {
      _pendingWebRehydrate!.complete();
    }
    _pendingWebRehydrate = null;
    Duration? elapsed;
    if (_webRehydrateStartedAt != null) {
      elapsed = DateTime.now().difference(_webRehydrateStartedAt!);
      _webRehydrateStartedAt = null;
    }
    _webRehydrateDeadline = null;
    _phase.value = nextPhase;
    if (nextPhase == AuthSessionPhase.stable && elapsed != null) {
      _logAuthEvent('auth/rehydrate-restored', {
        'elapsedMs': elapsed.inMilliseconds,
      });
    }
  }

  static void _markSignedOut({String tag = 'auth/user-signed-out'}) {
    _webRehydrateTimer?.cancel();
    _webRehydrateTimer = null;
    if (_pendingWebRehydrate != null && !_pendingWebRehydrate!.isCompleted) {
      _pendingWebRehydrate!.completeError(_SignOutRequested());
    }
    _pendingWebRehydrate = null;
    Duration? elapsed;
    if (_webRehydrateStartedAt != null) {
      elapsed = DateTime.now().difference(_webRehydrateStartedAt!);
      _webRehydrateStartedAt = null;
    }
    _webRehydrateDeadline = null;
    _phase.value = AuthSessionPhase.signedOut;
    if (elapsed != null) {
      _logAuthEvent(tag, {'elapsedMs': elapsed.inMilliseconds});
    } else {
      _logAuthEvent(tag);
    }
  }

  // パスワードリセット
  static Future<void> sendPasswordResetEmail(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email);
    } catch (e) {
      rethrow;
    }
  }

  // リソース解放
  static void dispose() {
    _authStateController.close();
    _authStateSubscription?.cancel();
    if (_featureFlagListenerAttached) {
      FeatureFlags.removeListener(_refreshWebHoldConfig);
      _featureFlagListenerAttached = false;
    }
  }

  static void _logAuthEvent(String tag, [Map<String, Object?>? context]) {
    final buffer = StringBuffer(tag);
    if (context != null && context.isNotEmpty) {
      context.forEach((key, value) {
        buffer.write(' $key=$value');
      });
    }
    buffer.write(' tab=$_tabId');
    // Webの調査では developer.log がコンソールに見えないことがあるため、
    // Auth系イベントは必ず print にも流す（頻度は低いので許容）。
    try {
      // ignore: avoid_print
      print(buffer.toString());
    } catch (_) {}
    developer.log(
      buffer.toString(),
      name: 'AuthService',
    );
  }

  static bool _shouldSuppressWebNullEvent(firebase_auth.User? user) {
    return kIsWeb && _suppressWebNullEvents && user == null;
  }

  static void _beginLegacyWebRehydrateHold() {
    if (!kIsWeb) return;
    _suppressWebNullEvents = true;
    _legacyWebRehydrateTimer?.cancel();
    _legacyWebRehydrateTimer = Timer(_legacyWebRehydrateGrace, () {
      _suppressWebNullEvents = false;
    });
  }

  static void _clearLegacyWebRehydrateHold() {
    if (!kIsWeb) return;
    _suppressWebNullEvents = false;
    _legacyWebRehydrateTimer?.cancel();
    _legacyWebRehydrateTimer = null;
  }
}

class _SignOutRequested implements Exception {}
