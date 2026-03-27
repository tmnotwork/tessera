import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;

/// ネットワーク管理サービス
class NetworkManager {
  static bool _isOnline = true;
  static Timer? _checkTimer;
  static final StreamController<bool> _connectivityController =
      StreamController<bool>.broadcast();

  /// 現在のオンライン状態
  static bool get isOnline => _isOnline;

  /// 接続状態の変更を監視するストリーム
  static Stream<bool> get connectivityStream => _connectivityController.stream;

  /// ネットワーク管理を初期化
  static Future<void> initialize() async {
    // 初期状態をチェック
    await _checkConnectivity();
    
    // 定期的にネットワーク状態をチェック（30秒間隔）
    _startPeriodicCheck();
  }

  /// 定期的なネットワークチェックを開始
  static void _startPeriodicCheck() {
    _checkTimer?.cancel();
    _checkTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _checkConnectivity(),
    );
  }

  /// ネットワーク接続をチェック
  static Future<bool> _checkConnectivity() async {
    try {
      bool newStatus;
      
      if (kIsWeb) {
        // Web環境では常にオンラインとみなす
        // （実際のFirebase接続は各サービスで個別にハンドリング）
        newStatus = true;
      } else {
        // モバイル環境では従来のDNS lookupを使用
        final result = await InternetAddress.lookup('google.com');
        newStatus = result.isNotEmpty && result[0].rawAddress.isNotEmpty;
      }
      
      if (newStatus != _isOnline) {
        _isOnline = newStatus;
        _connectivityController.add(_isOnline);
      }
      
      return _isOnline;
    } catch (e) {
      if (_isOnline) {
        _isOnline = false;
        _connectivityController.add(_isOnline);
      }
      return false;
    }
  }

  /// 手動でネットワーク状態をチェック
  static Future<bool> checkNow() async {
    return await _checkConnectivity();
  }

  /// Firebase接続をテスト
  static Future<bool> testFirebaseConnection() async {
    try {
      if (kIsWeb) {
        // Web環境では常にtrueを返す（実際の接続テストはFirebase SDKに委ねる）
        return true;
      } else {
        // モバイル環境では従来のDNS lookupを使用
        final result = await InternetAddress.lookup('firebase.google.com');
        return result.isNotEmpty && result[0].rawAddress.isNotEmpty;
      }
    } catch (e) {
      print('Firebase connection test failed: $e');
      return false;
    }
  }

  /// 接続品質をテスト（簡易版）
  static Future<ConnectionQuality> testConnectionQuality() async {
    if (!_isOnline) {
      return ConnectionQuality.offline;
    }

    try {
      final stopwatch = Stopwatch()..start();
      await InternetAddress.lookup('google.com');
      stopwatch.stop();

      final latency = stopwatch.elapsedMilliseconds;

      if (latency < 100) {
        return ConnectionQuality.excellent;
      } else if (latency < 300) {
        return ConnectionQuality.good;
      } else if (latency < 1000) {
        return ConnectionQuality.fair;
      } else {
        return ConnectionQuality.poor;
      }
    } catch (e) {
      return ConnectionQuality.offline;
    }
  }

  /// オンライン状態になるまで待機
  static Future<void> waitForConnection({
    Duration timeout = const Duration(minutes: 5),
  }) async {
    if (_isOnline) return;

    final completer = Completer<void>();
    late StreamSubscription subscription;

    // タイムアウトタイマー
    final timeoutTimer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.completeError(
          TimeoutException('Network connection timeout', timeout),
        );
      }
    });

    // 接続状態を監視
    subscription = connectivityStream.listen((isConnected) {
      if (isConnected && !completer.isCompleted) {
        timeoutTimer.cancel();
        subscription.cancel();
        completer.complete();
      }
    });

    // 現在の状態を再チェック
    await checkNow();

    return completer.future;
  }

  /// リソースをクリーンアップ
  static void dispose() {
    _checkTimer?.cancel();
    _connectivityController.close();
  }

  /// ネットワーク統計を取得
  static NetworkStats getStats() {
    return NetworkStats(
      isOnline: _isOnline,
      lastChecked: DateTime.now(),
    );
  }
}

/// 接続品質の列挙
enum ConnectionQuality {
  offline,
  poor,
  fair,
  good,
  excellent,
}

/// ネットワーク統計
class NetworkStats {
  final bool isOnline;
  final DateTime lastChecked;

  NetworkStats({
    required this.isOnline,
    required this.lastChecked,
  });

  Map<String, dynamic> toJson() {
    return {
      'isOnline': isOnline,
      'lastChecked': lastChecked.toIso8601String(),
    };
  }
}

/// タイムアウト例外
class TimeoutException implements Exception {
  final String message;
  final Duration timeout;

  TimeoutException(this.message, this.timeout);

  @override
  String toString() => 'TimeoutException: $message (${timeout.inSeconds}s)';
}