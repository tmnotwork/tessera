import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

/// 連続学習日数の算出・キャッシュ。
///
/// `study_sessions` のローカル日付（`date(started_at, 'localtime')`）から集計する。
class StreakInfo {
  const StreakInfo({
    required this.current,
    required this.longest,
    this.isNewRecord = false,
    this.milestoneToCelebrate,
  });

  /// 現在の連続日数（今日未学習でも昨日までなら継続）
  final int current;

  /// これまでの最長連続日数（履歴＋過去に保存した最大）
  final int longest;

  /// 今回の再計算で [longest] が更新されたか
  final bool isNewRecord;

  /// 表示すべきマイルストーン（まだ祝っていない到達点のうち最も手前のもの）。なければ null
  final int? milestoneToCelebrate;

  static StreakInfo zero() => const StreakInfo(current: 0, longest: 0);
}

class StreakRepository {
  StreakRepository(this._db);

  final Database _db;

  static String _prefId(String learnerId) =>
      'streak_${learnerId.replaceAll('-', '_')}';

  /// ログイン UUID 用（外部から prefs キーを組み立てるとき）
  static String prefIdForLearner(String learnerId) => _prefId(learnerId);

  static String todayKeyLocal() => _fmtDate(_dateOnlyLocal(DateTime.now()));

  static const _dailyGreetingSuffix = '_daily_greeting';
  static const _lastGreetStreakSuffix = '_last_greet_streak';

  static const _milestoneThresholds = [3, 7, 14, 30, 60, 100];

  /// 当日初回の連続日数ダイアログを出してよいとき true。
  ///
  /// **暦日ごとに最大1回**のみ。連続日数が変わらない日も、起動のたびに「〇日連続」を見せるため
  /// 「前回と同じ日数なら出さない」条件は付けない。
  static Future<bool> shouldShowDailyGreeting(
    String learnerId,
    int currentStreak,
  ) async {
    if (learnerId.isEmpty) return false;
    final prefs = await SharedPreferences.getInstance();
    final id = _prefId(learnerId);
    final today = todayKeyLocal();
    if (prefs.getString('$id$_dailyGreetingSuffix') == today) {
      return false;
    }
    return true;
  }

  /// 当日分のあいさつを表示済みにする（マイルストーン祝辞の日はこちらで揃える）。
  static Future<void> markDailyGreetingShown(
    String learnerId,
    int streakAtShow,
  ) async {
    if (learnerId.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final id = _prefId(learnerId);
    await prefs.setString('$id$_dailyGreetingSuffix', todayKeyLocal());
    await prefs.setInt('$id$_lastGreetStreakSuffix', streakAtShow);
  }

  static String _milestoneSeenKey(String id, int m) => '${id}_milestone_seen_$m';

  /// 旧版の単一 int [_celebrated] を各マイルストーンの表示済みフラグへ移す（一度だけ）。
  static Future<void> _migrateLegacyCelebrated(
    SharedPreferences prefs,
    String id,
  ) async {
    final legacy = prefs.getInt('${id}_celebrated');
    if (legacy == null || legacy <= 0) return;
    for (final m in _milestoneThresholds) {
      if (m <= legacy) {
        await prefs.setBool(_milestoneSeenKey(id, m), true);
      }
    }
    await prefs.remove('${id}_celebrated');
  }

  static bool _milestoneSeen(SharedPreferences prefs, String id, int m) =>
      prefs.getBool(_milestoneSeenKey(id, m)) ?? false;

  static String _fmtDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  static DateTime _dateOnlyLocal(DateTime dt) {
    final l = dt.toLocal();
    return DateTime(l.year, l.month, l.day);
  }

  /// キャッシュが「今日」分なら prefs から返す。日付が変わったら [recompute]。
  Future<StreakInfo> getStreakInfo(String learnerId) async {
    if (learnerId.isEmpty) return StreakInfo.zero();
    final prefs = await SharedPreferences.getInstance();
    final id = _prefId(learnerId);
    final todayKey = _fmtDate(_dateOnlyLocal(DateTime.now()));
    final computed = prefs.getString('${id}_computed_date');
    if (computed == todayKey) {
      return StreakInfo(
        current: prefs.getInt('${id}_current') ?? 0,
        longest: prefs.getInt('${id}_longest') ?? 0,
        isNewRecord: false,
        milestoneToCelebrate: null,
      );
    }
    return recompute(learnerId);
  }

  /// DB から再計算し prefs を更新する。
  Future<StreakInfo> recompute(String learnerId) async {
    if (learnerId.isEmpty) return StreakInfo.zero();

    final prefs = await SharedPreferences.getInstance();
    final id = _prefId(learnerId);
    await _migrateLegacyCelebrated(prefs, id);

    final prevLongestStored = prefs.getInt('${id}_longest') ?? 0;
    final today = _dateOnlyLocal(DateTime.now());
    final todayKey = _fmtDate(today);

    final daySet = await _loadStudyDaySet(learnerId);

    var current = 0;
    final yesterdayKey = _fmtDate(today.subtract(const Duration(days: 1)));
    if (daySet.contains(todayKey) || daySet.contains(yesterdayKey)) {
      var cursor = daySet.contains(todayKey)
          ? today
          : today.subtract(const Duration(days: 1));
      while (daySet.contains(_fmtDate(cursor))) {
        current++;
        cursor = cursor.subtract(const Duration(days: 1));
      }
    }

    final longestInHistory = _longestConsecutiveRun(daySet);
    final longest = math.max(longestInHistory, prevLongestStored);
    final isNewRecord = longest > prevLongestStored;

    await prefs.setInt('${id}_current', current);
    await prefs.setInt('${id}_longest', longest);
    await prefs.setString('${id}_computed_date', todayKey);

    int? milestoneToCelebrate;
    if (current > 0) {
      for (final m in _milestoneThresholds) {
        if (current >= m && !_milestoneSeen(prefs, id, m)) {
          milestoneToCelebrate = m;
          break;
        }
      }
    }

    return StreakInfo(
      current: current,
      longest: longest,
      isNewRecord: isNewRecord,
      milestoneToCelebrate: milestoneToCelebrate,
    );
  }

  /// お祝いダイアログを閉じたあとに呼ぶ。
  Future<void> markMilestoneCelebrated(String learnerId, int milestone) async {
    if (learnerId.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final id = _prefId(learnerId);
    await prefs.setBool(_milestoneSeenKey(id, milestone), true);
  }

  Future<Set<String>> _loadStudyDaySet(String learnerId) async {
    try {
      final rows = await _db.rawQuery(
        '''
        SELECT DISTINCT date(started_at, 'localtime') AS study_date
        FROM study_sessions
        WHERE deleted = 0
          AND TRIM(COALESCE(started_at, '')) != ''
          AND (
            learner_id IS NULL OR TRIM(COALESCE(learner_id, '')) = ''
            OR learner_id = ?
          )
        ORDER BY study_date DESC
        ''',
        [learnerId],
      );
      return rows
          .map((r) => r['study_date']?.toString() ?? '')
          .where((s) => s.isNotEmpty)
          .toSet();
    } catch (_) {
      return {};
    }
  }

  static int _longestConsecutiveRun(Set<String> days) {
    if (days.isEmpty) return 0;
    final sorted = days.toList()..sort();
    var best = 1;
    var run = 1;
    for (var i = 1; i < sorted.length; i++) {
      final a = DateTime.parse(sorted[i - 1]);
      final b = DateTime.parse(sorted[i]);
      final diff = b.difference(a).inDays;
      if (diff == 1) {
        run++;
        if (run > best) best = run;
      } else if (diff > 1) {
        run = 1;
      }
    }
    return best;
  }
}
