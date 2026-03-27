import 'dart:io';

import 'package:path_provider/path_provider.dart';

class AppLogService {
  static bool _initialized = false;
  static File? _notificationLogFile;
  static final List<String> _memoryBuffer = <String>[]; // session fallback
  static const int _maxBufferLines = 10000;

  static Future<void> initialize() async {
    if (_initialized) return;
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/notification_logs.txt');
    if (!await file.exists()) {
      await file.create(recursive: true);
    }
    _notificationLogFile = file;
    _initialized = true;
  }

  static Future<void> appendNotification(String message) async {
    await initialize();
    final ts = DateTime.now().toIso8601String();
    final line = '[$ts] $message\n';
    try {
      await _notificationLogFile!
          .writeAsString(line, mode: FileMode.append, flush: true);
    } catch (_) {}
    _memoryBuffer.add(line);
    if (_memoryBuffer.length > _maxBufferLines) {
      _memoryBuffer.removeRange(0, _memoryBuffer.length - _maxBufferLines);
    }
  }

  static Future<String> readNotification() async {
    await initialize();
    try {
      final content = await _notificationLogFile!.readAsString();
      if (content.isNotEmpty) return content;
      return _memoryBuffer.join();
    } catch (_) {
      return _memoryBuffer.join();
    }
  }

  static Future<void> clearNotification() async {
    await initialize();
    try {
      await _notificationLogFile!.writeAsString('', flush: true);
    } catch (_) {}
    _memoryBuffer.clear();
  }
}

