import 'dart:async';

import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/foundation.dart';
import '../utils/perf_logger.dart';

class FeatureFlags {
  static final Set<VoidCallback> _listeners = <VoidCallback>{};
  static Future<void>? _initializationFuture;
  static FirebaseRemoteConfig? _remoteConfig;
  static StreamSubscription<RemoteConfigUpdate>? _remoteConfigSubscription;
  static bool _defaultsApplied = false;

  static bool _webMultiTabAuthHold =
      const bool.fromEnvironment('WEB_MULTI_TAB_AUTH_HOLD', defaultValue: true);
  static int _webMultiTabHoldMs = const int.fromEnvironment(
    'WEB_MULTI_TAB_HOLD_MS',
    defaultValue: 1200,
  );

  static Future<void> initialize() {
    _initializationFuture ??= _init();
    return _initializationFuture!;
  }

  static Future<void> _init() async {
    PerfLogger.mark('FeatureFlags.init.start');
    _applyDefaults();
    try {
      _remoteConfig = FirebaseRemoteConfig.instance;
      PerfLogger.mark('FeatureFlags.remoteConfig.instance');
      await PerfLogger.time(
        'FeatureFlags.remoteConfig.setConfigSettings',
        () => _remoteConfig!.setConfigSettings(
          RemoteConfigSettings(
            fetchTimeout: const Duration(seconds: 5),
            minimumFetchInterval: const Duration(minutes: 5),
          ),
        ),
      );
      await PerfLogger.time(
        'FeatureFlags.remoteConfig.setDefaults',
        () => _remoteConfig!.setDefaults(const {
          'webMultiTabAuthHold': true,
          'webMultiTabHoldMs': 1200,
        }),
      );
      await PerfLogger.time(
        'FeatureFlags.remoteConfig.fetchAndActivate',
        () => _remoteConfig!.fetchAndActivate(),
      );
      _applyRemoteConfigValues();
      PerfLogger.mark('FeatureFlags.remoteConfig.applied');
      _remoteConfigSubscription ??=
          _remoteConfig!.onConfigUpdated.listen((event) async {
        try {
          await PerfLogger.time(
            'FeatureFlags.remoteConfig.onConfigUpdated.activate',
            () => _remoteConfig!.activate(),
          );
          _applyRemoteConfigValues();
          PerfLogger.mark('FeatureFlags.remoteConfig.onConfigUpdated.applied');
        } catch (e) {
          debugPrint('FeatureFlags activate failed: $e');
          PerfLogger.mark(
            'FeatureFlags.remoteConfig.onConfigUpdated.fail',
            {'error': e.toString()},
          );
        }
      });
    } catch (e) {
      PerfLogger.mark(
        'FeatureFlags.remoteConfig.unavailable',
        {'error': e.toString()},
      );
    }
    PerfLogger.mark('FeatureFlags.init.done');
  }

  static void ensureInitialized() {
    _applyDefaults();
  }

  static void _applyDefaults() {
    if (_defaultsApplied) return;
    _webMultiTabHoldMs = _clampHold(_webMultiTabHoldMs);
    _defaultsApplied = true;
  }

  static bool get webMultiTabAuthHold => _webMultiTabAuthHold;

  static int get webMultiTabHoldMs => _clampHold(_webMultiTabHoldMs);

  static void updateWebMultiTabAuthHold(bool enabled) {
    if (_webMultiTabAuthHold == enabled) return;
    _webMultiTabAuthHold = enabled;
    _notifyListeners();
  }

  static void disableWebMultiTabAuthHold() {
    updateWebMultiTabAuthHold(false);
  }

  static void updateWebMultiTabHoldMs(int value) {
    final clamped = _clampHold(value);
    if (_webMultiTabHoldMs == clamped) return;
    _webMultiTabHoldMs = clamped;
    _notifyListeners();
  }

  static void addListener(VoidCallback listener) {
    _listeners.add(listener);
  }

  static void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
  }

  static int _clampHold(int raw) {
    if (raw < 0) return 0;
    // Webの複数タブ再水和は端末・ブラウザ・拡張機能等で数秒かかることがあるため、
    // 1500ms 上限だと偽ログアウトを誘発しやすい。チューニング余地を残すため上限を拡大する。
    if (raw > 10000) return 10000;
    return raw;
  }

  static void _applyRemoteConfigValues() {
    if (_remoteConfig == null) return;
    updateWebMultiTabAuthHold(
      _remoteConfig!.getBool('webMultiTabAuthHold'),
    );
    updateWebMultiTabHoldMs(
      _remoteConfig!.getInt('webMultiTabHoldMs'),
    );
  }

  static void _notifyListeners() {
    for (final listener in List<VoidCallback>.from(_listeners)) {
      try {
        listener();
      } catch (e) {
        debugPrint('FeatureFlags listener error: $e');
      }
    }
  }
}
