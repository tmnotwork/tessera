import 'package:flutter/foundation.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'app_settings_service.dart';

/// Final State: dayKey/monthKey は accountTimeZoneId の暦日/暦月で計算する。
///
/// NOTE:
/// - `timezone` の初期化が必要なので、アプリ起動時に `initialize()` を呼ぶこと。
/// - 初期化前は UTC を暫定で使用する（クラッシュ回避）。
class DayKeyService {
  DayKeyService._();

  static bool _initialized = false;
  static tz.Location _location = tz.UTC;

  static tz.Location get location => _location;
  static bool get isInitialized => _initialized;

  static Future<void> initialize() async {
    if (_initialized) return;
    try {
      tzdata.initializeTimeZones();
    } catch (e) {
      // ignore: avoid_print
      print('⚠️ DayKeyService: initializeTimeZones failed: $e');
    }

    try {
      await AppSettingsService.initialize();
    } catch (_) {}

    String? tzId = AppSettingsService.getString(AppSettingsService.keyAccountTimeZoneId);
    tzId = (tzId == null || tzId.trim().isEmpty) ? null : tzId.trim();

    tzId ??= await _detectDeviceTimeZoneId();

    tz.Location resolved = tz.UTC;
    try {
      resolved = tz.getLocation(tzId);
    } catch (_) {
      try {
        resolved = tz.local;
      } catch (_) {
        resolved = tz.UTC;
      }
    }

    _location = resolved;
    try {
      tz.setLocalLocation(resolved);
    } catch (_) {}

    try {
      await AppSettingsService.setString(
        AppSettingsService.keyAccountTimeZoneId,
        resolved.name,
      );
    } catch (_) {}

    _initialized = true;
  }

  static Future<String> _detectDeviceTimeZoneId() async {
    try {
      final id = await FlutterTimezone.getLocalTimezone();
      if (id.trim().isNotEmpty) return id.trim();
    } catch (_) {}
    return 'UTC';
  }

  static String formatDayKeyYmd(int year, int month, int day) {
    final y = year.toString().padLeft(4, '0');
    final m = month.toString().padLeft(2, '0');
    final d = day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  static List<String> computeDayKeysUtc(
    DateTime startAtUtc,
    DateTime endAtUtcExclusive,
  ) {
    // Safety: normalize to UTC
    final sUtc = startAtUtc.toUtc();
    final eUtc = endAtUtcExclusive.toUtc();
    if (!sUtc.isBefore(eUtc)) return const [];

    final loc = _location;
    final sLocal = tz.TZDateTime.from(sUtc, loc);
    final eLocal = tz.TZDateTime.from(eUtc, loc);

    var cursor = tz.TZDateTime(loc, sLocal.year, sLocal.month, sLocal.day);
    final out = <String>[];
    while (cursor.isBefore(eLocal)) {
      out.add(formatDayKeyYmd(cursor.year, cursor.month, cursor.day));
      cursor = cursor.add(const Duration(days: 1));
    }
    return out;
  }

  static List<String> computeMonthKeysFromDayKeys(List<String> dayKeys) {
    final set = <String>{};
    for (final k in dayKeys) {
      if (k.length >= 7) set.add(k.substring(0, 7));
    }
    final out = set.toList()..sort();
    return out;
  }

  /// accountTimeZoneId（= DayKeyService.location）の wall-clock を UTC へ正規化する。
  /// Final State: UI入力（日付+時刻）は accountTimeZoneId 基準で解釈し、UTC保存する。
  static DateTime toUtcFromAccountLocalParts({
    required int year,
    required int month,
    required int day,
    required int hour,
    required int minute,
  }) {
    final loc = _location;
    final local = tz.TZDateTime(loc, year, month, day, hour, minute);
    return local.toUtc();
  }

  /// `DateTime` の年月日時分を「accountTimeZoneId の wall-clock」とみなして UTC へ変換する。
  /// 端末ローカルのタイムゾーン解釈には依存しない（中身の“数値”だけ使用）。
  static DateTime toUtcFromAccountWallClock(DateTime wallClock) {
    return toUtcFromAccountLocalParts(
      year: wallClock.year,
      month: wallClock.month,
      day: wallClock.day,
      hour: wallClock.hour,
      minute: wallClock.minute,
    );
  }

  /// UTC の絶対時刻を、accountTimeZoneId の wall-clock（TZDateTime）へ変換する。
  /// 画面表示や「開始日の yyyy-mm-dd」を得る用途。
  static DateTime toAccountWallClockFromUtc(DateTime utc) {
    final loc = _location;
    return tz.TZDateTime.from(utc.toUtc(), loc);
  }
}

