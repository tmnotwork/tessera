import 'dart:developer' as developer;

class PerfLogger {
  static final Stopwatch _boot = Stopwatch();
  static bool _bootStarted = false;

  static void resetBoot([String reason = '']) {
    _boot
      ..reset()
      ..start();
    _bootStarted = true;
    _log('BOOT', 'reset', reason.isEmpty ? null : {'reason': reason});
  }

  static int get elapsedMs {
    _ensureBoot();
    return _boot.elapsedMilliseconds;
  }

  static void mark(String label, [Map<String, Object?>? meta]) {
    _ensureBoot();
    _log('MARK', label, meta);
  }

  static void event(String label, [Map<String, Object?>? meta]) {
    _ensureBoot();
    _log('EVENT', label, meta);
  }

  static Future<T> time<T>(
    String label,
    Future<T> Function() action, {
    Map<String, Object?>? meta,
  }) async {
    _ensureBoot();
    final startMs = _boot.elapsedMilliseconds;
    _log('START', label, meta);
    try {
      final result = await action();
      final durMs = _boot.elapsedMilliseconds - startMs;
      _log('END', label, {
        if (meta != null) ...meta,
        'durMs': durMs,
      });
      return result;
    } catch (e) {
      final durMs = _boot.elapsedMilliseconds - startMs;
      _log('FAIL', label, {
        if (meta != null) ...meta,
        'durMs': durMs,
        'error': e.toString(),
      });
      rethrow;
    }
  }

  static void _ensureBoot() {
    if (_bootStarted) return;
    _boot
      ..reset()
      ..start();
    _bootStarted = true;
  }

  /// 通常の計測ログは出さず、失敗・タイムアウト・ゾーンエラー等のみコンソールへ出す。
  static bool _shouldEmit(String phase, String label) {
    if (phase == 'FAIL') return true;
    if (phase != 'MARK') return false;
    if (label == 'zone.error') return true;
    if (label.contains('.fail')) return true;
    if (label.contains('.timeout')) return true;
    if (label.endsWith('.error')) return true;
    if (label == 'FirestorePersistence.web.unavailable') return true;
    return false;
  }

  static void _log(String phase, String label, Map<String, Object?>? meta) {
    final elapsedMs = _boot.elapsedMilliseconds;
    final metaText = _formatMeta(meta);
    final line = '[PERF] +${elapsedMs}ms $phase $label$metaText';
    if (_shouldEmit(phase, label)) {
      try {
        // ignore: avoid_print
        print(line);
      } catch (_) {}
      developer.log(line, name: 'PerfLogger');
    }
  }

  static String _formatMeta(Map<String, Object?>? meta) {
    if (meta == null || meta.isEmpty) return '';
    final buffer = StringBuffer();
    meta.forEach((key, value) {
      buffer.write(' ');
      buffer.write(key);
      buffer.write('=');
      buffer.write(value);
    });
    return buffer.toString();
  }
}
