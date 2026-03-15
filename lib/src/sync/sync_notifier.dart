import 'package:flutter/foundation.dart';

/// 同期状態: 画面がリフレッシュやインジケーター表示に使う
enum SyncState {
  idle,
  syncing,
  done,
  error,
}

/// 同期完了またはエラー時に画面に通知するための Notifier
class SyncNotifier extends ChangeNotifier {
  SyncNotifier._();

  static final SyncNotifier _instance = SyncNotifier._();

  static SyncNotifier get instance => _instance;

  SyncState _state = SyncState.idle;
  SyncState get state => _state;

  DateTime? _lastDoneAt;
  DateTime? get lastDoneAt => _lastDoneAt;

  Object? _lastError;
  Object? get lastError => _lastError;

  static void setSyncing() {
    _instance._state = SyncState.syncing;
    _instance._lastError = null;
    _instance.notifyListeners();
  }

  static void setDone() {
    _instance._state = SyncState.done;
    _instance._lastDoneAt = DateTime.now();
    _instance._lastError = null;
    _instance.notifyListeners();
  }

  static void setError(Object error) {
    _instance._state = SyncState.error;
    _instance._lastError = error;
    _instance.notifyListeners();
  }

  static void setIdle() {
    _instance._state = SyncState.idle;
    _instance.notifyListeners();
  }
}
