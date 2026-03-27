import 'auth_service.dart';

class SyncService {
  static bool _isInitialized = false;
  static bool _isFirebaseAvailable = false;

  // 同期サービス初期化
  static Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      await AuthService.initialize();
      final userId = AuthService.getCurrentUserId();
      _isFirebaseAvailable = userId != null && userId.isNotEmpty;
    } catch (e) {
      // Firebase認証エラーを無視
    }

    _isInitialized = true;
  }

  // Firebase利用可能かどうかを取得
  static bool get isFirebaseAvailable => _isFirebaseAvailable;

  // 同期状態をリセット
  static void reset() {
    _isInitialized = false;
    _isFirebaseAvailable = false;
  }
}
