class AppLogService {
  static bool _initialized = false;
  static final List<String> _memoryBuffer = <String>[]; // session-only
  static const int _maxBufferLines = 10000;

  static Future<void> initialize() async {
    // Web: path_provider is not available. Keep logs in memory only.
    _initialized = true;
  }

  static Future<void> appendNotification(String message) async {
    if (!_initialized) {
      await initialize();
    }
    final ts = DateTime.now().toIso8601String();
    final line = '[$ts] $message\n';
    _memoryBuffer.add(line);
    if (_memoryBuffer.length > _maxBufferLines) {
      _memoryBuffer.removeRange(0, _memoryBuffer.length - _maxBufferLines);
    }
  }

  static Future<String> readNotification() async {
    if (!_initialized) {
      await initialize();
    }
    return _memoryBuffer.join();
  }

  static Future<void> clearNotification() async {
    if (!_initialized) {
      await initialize();
    }
    _memoryBuffer.clear();
  }
}

