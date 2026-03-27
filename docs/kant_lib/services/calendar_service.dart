import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/calendar_entry.dart';
import 'auth_service.dart';
import 'package:holiday_jp/holiday_jp.dart' as holiday_jp;
import 'package:flutter/foundation.dart';
import 'app_settings_service.dart';

class CalendarService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final Map<String, CalendarEntry> _cache = {};
  static final Map<String, DateTime> _cacheTimestamps = {};
  static const int _cacheExpiryHours = 24;
  static bool hideRoutineBlocksWithoutInboxInMonth = true;
  static final ValueNotifier<bool> hideRoutineNotifier =
      ValueNotifier<bool>(hideRoutineBlocksWithoutInboxInMonth);
  static void setHideRoutineBlocksWithoutInboxInMonth(bool value) {
    hideRoutineBlocksWithoutInboxInMonth = value;
    hideRoutineNotifier.value = value;
    // persist
    AppSettingsService.setBool(
        AppSettingsService.keyHideRoutineBlocksWithoutInboxInMonth, value);
  }

  /// Firebase コレクション参照
  static CollectionReference get _calendarCollection {
    final userId = AuthService.getCurrentUserId();
    if (userId == null) {
      throw Exception('User not authenticated');
    }
    return _firestore
        .collection('users')
        .doc(userId)
        .collection('calendar_entries');
  }

  /// サービスの初期化
  static Future<void> initialize() async {
    // Load persisted settings
    await AppSettingsService.initialize();
    hideRoutineBlocksWithoutInboxInMonth = AppSettingsService.getBool(
      AppSettingsService.keyHideRoutineBlocksWithoutInboxInMonth,
      defaultValue: hideRoutineBlocksWithoutInboxInMonth,
    );
    hideRoutineNotifier.value = hideRoutineBlocksWithoutInboxInMonth;
  }

  /// 特定の日付のカレンダーエントリを取得（Firebase直接アクセス + キャッシュ）
  static Future<CalendarEntry?> getCalendarEntryForDate(DateTime date) async {
    final key =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

    // キャッシュチェック
    if (_cache.containsKey(key) && _isCacheValid(key)) {
      return _cache[key];
    }

    try {
      // fetching calendar entry from Firebase
      final doc = await _calendarCollection.doc(key).get();

      CalendarEntry? entry;
      if (doc.exists) {
        final data = doc.data() as Map<String, dynamic>;
        data['cloudId'] = doc.id;
        entry = CalendarEntry.fromJson(data);
      } else {
        entry = null;
      }

      // キャッシュに保存
      if (entry != null) {
        _cache[key] = entry;
        _cacheTimestamps[key] = DateTime.now();
      }

      return entry;
    } catch (e) {
      print('❌ Failed to fetch calendar entry from Firebase: $e');
      return null;
    }
  }

  /// 期間指定でカレンダーエントリを取得（Firebase直接アクセス）
  static Future<List<CalendarEntry>> getCalendarEntriesForPeriod(
      DateTime startDate, DateTime endDate) async {
    try {
      // fetching calendar entries for period

      final startKey =
          '${startDate.year}-${startDate.month.toString().padLeft(2, '0')}-${startDate.day.toString().padLeft(2, '0')}';
      final endKey =
          '${endDate.year}-${endDate.month.toString().padLeft(2, '0')}-${endDate.day.toString().padLeft(2, '0')}';

      final querySnapshot = await _calendarCollection
          .where(FieldPath.documentId, isGreaterThanOrEqualTo: startKey)
          .where(FieldPath.documentId, isLessThanOrEqualTo: endKey)
          .get();

      final entries = <CalendarEntry>[];
      for (final doc in querySnapshot.docs) {
        try {
          final data = doc.data() as Map<String, dynamic>;
          data['cloudId'] = doc.id;
          final entry = CalendarEntry.fromJson(data);
          entries.add(entry);

          // キャッシュに保存
          _cache[doc.id] = entry;
          _cacheTimestamps[doc.id] = DateTime.now();
        } catch (e) {
          print('⚠️ Failed to parse calendar entry ${doc.id}: $e');
        }
      }

      // fetched calendar entries
      return entries;
    } catch (e) {
      print('❌ Failed to fetch calendar entries from Firebase: $e');
      return [];
    }
  }

  /// 休日判定（カスタマイズ対応 + holiday_jpフォールバック）
  static Future<bool> isHoliday(DateTime date) async {
    try {
      final entry = await getCalendarEntryForDate(date);
      if (entry != null) {
        // カスタマイズされた休日設定を使用
        // use customized holiday setting
        return entry.isHoliday;
      }
    } catch (e) {
      print(
          '⚠️ Failed to get calendar entry, using default logic fallback: $e');
    }

    // フォールバック: 土日 + 祝日判定
    // 土日をチェック
    if (date.weekday == DateTime.saturday || date.weekday == DateTime.sunday) {
      // weekend fallback true
      return true;
    }

    // 祝日をチェック
    final isHolidayResult = holiday_jp.isHoliday(date);
    return isHolidayResult;
  }

  /// 非同期を避けたいUI描画用の簡易キャッシュ版休日判定
  /// - 先に getCalendarEntriesForPeriod / getCalendarEntryForDate を呼んでおくと正確な結果になる
  /// - キャッシュが無い場合は週末+holiday_jpでフォールバック
  static bool isHolidayCached(DateTime date) {
    final key =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    final entry = _cache[key];
    if (entry != null) {
      return entry.isHoliday;
    }
    if (date.weekday == DateTime.saturday || date.weekday == DateTime.sunday) {
      return true;
    }
    return holiday_jp.isHoliday(date);
  }

  /// 休日判定の詳細情報を取得
  static Future<Map<String, dynamic>> getHolidayInfo(DateTime date) async {
    try {
      final entry = await getCalendarEntryForDate(date);
      if (entry != null) {
        // カスタマイズされたエントリが存在
        return {
          'isHoliday': entry.isHoliday,
          'reason': 'カスタマイズ設定: ${entry.isHoliday ? '休日' : '平日'}',
        };
      }
    } catch (e) {
      print(
          '⚠️ Failed to get calendar entry, using default logic fallback: $e');
    }

    // フォールバック: 土日 + 祝日判定
    String reason;
    bool isHolidayResult;

    if (date.weekday == DateTime.saturday) {
      isHolidayResult = true;
      reason = 'デフォルト判定: 土曜日';
    } else if (date.weekday == DateTime.sunday) {
      isHolidayResult = true;
      reason = 'デフォルト判定: 日曜日';
    } else {
      // 平日の場合、祝日かどうかチェック
      isHolidayResult = holiday_jp.isHoliday(date);
      if (isHolidayResult) {
        reason = 'デフォルト判定: 祝日';
      } else {
        reason = 'デフォルト判定: 平日';
      }
    }

    return {
      'isHoliday': isHolidayResult,
      'reason': reason,
    };
  }

  /// 休日をカスタマイズ（新機能）
  static Future<void> customizeHoliday(DateTime date, bool isHoliday,
      {String? reason}) async {
    try {
      final key =
          '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
      final now = DateTime.now();

      final entry = CalendarEntry(
        id: key,
        date: date,
        routineTypeId: null,
        color: isHoliday ? 'FFE0E0E0' : 'FFFFFFFF',
        isHoliday: isHoliday,
        isOff: false,
        createdAt: now,
        lastModified: now,
        userId: AuthService.getCurrentUserId() ?? '',
        cloudId: key,
      );

      await _calendarCollection.doc(key).set(entry.toCloudJson());

      // キャッシュを更新
      _cache[key] = entry;
      _cacheTimestamps[key] = now;

      // 休日変更を通知
      holidayChangeNotifier.value++;
    } catch (e) {
      print('❌ Failed to customize holiday: $e');
      rethrow;
    }
  }

  /// 休日変更通知用の ValueNotifier
  static final ValueNotifier<int> holidayChangeNotifier = ValueNotifier<int>(0);

  /// キャッシュの有効性チェック
  static bool _isCacheValid(String key) {
    if (!_cacheTimestamps.containsKey(key)) return false;

    final timestamp = _cacheTimestamps[key]!;
    final now = DateTime.now();
    final diff = now.difference(timestamp).inHours;

    return diff < _cacheExpiryHours;
  }

  /// キャッシュをクリア
  static void clearCache() {
    _cache.clear();
    _cacheTimestamps.clear();
    print('🗑️ Calendar cache cleared');
  }

  /// ユーザー登録時の初期化（軽量化）
  static Future<void> initializeUserCalendar(String userId) async {
    print('📅 Calendar initialized for user: $userId (Firebase-only mode)');
    print('📅 Calendar entries will be created on-demand or via customization');
  }

  /// === カレンダー画面用の同期メソッド ===

  /// 単日のカレンダーエントリを同期（実際は取得のみ）
  static Future<void> syncCalendarEntryForDate(DateTime date) async {
    await getCalendarEntryForDate(date);
  }

  /// 週のカレンダーエントリを同期
  static Future<void> syncCalendarEntriesForWeek(DateTime weekDate) async {
    final startOfWeek = weekDate.subtract(Duration(days: weekDate.weekday - 1));
    final endOfWeek = startOfWeek.add(const Duration(days: 6));
    await getCalendarEntriesForPeriod(startOfWeek, endOfWeek);
  }

  /// 月のカレンダーエントリを同期
  static Future<void> syncCalendarEntriesForMonth(DateTime month) async {
    final startOfMonth = DateTime(month.year, month.month, 1);
    final endOfMonth = DateTime(month.year, month.month + 1, 0);
    await getCalendarEntriesForPeriod(startOfMonth, endOfMonth);
  }

  /// 年のカレンダーエントリを同期
  static Future<void> syncCalendarEntriesForYear(int year) async {
    final startOfYear = DateTime(year, 1, 1);
    final endOfYear = DateTime(year, 12, 31);
    await getCalendarEntriesForPeriod(startOfYear, endOfYear);
  }
}
