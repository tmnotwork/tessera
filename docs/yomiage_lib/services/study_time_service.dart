import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';

class StudyTimeService {
  static final StudyTimeService _instance = StudyTimeService._internal();
  factory StudyTimeService() => _instance;
  StudyTimeService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final _prefs = SharedPreferences.getInstance();

  DateTime? _startTime;
  String? _currentMode;
  Timer? _syncTimer;

  // 学習開始
  Future<void> startStudy(String mode) async {
    _startTime = DateTime.now();
    _currentMode = mode;

    // 5分ごとにローカルに保存
    _syncTimer = Timer.periodic(const Duration(minutes: 5), (timer) {
      _saveLocalStudyTime();
    });
  }

  // 学習終了
  Future<void> endStudy() async {
    if (_startTime == null || _currentMode == null) return;

    _syncTimer?.cancel();
    final endTime = DateTime.now();
    final duration = endTime.difference(_startTime!).inSeconds;

    await _saveStudyTime(_currentMode!, duration);
    _startTime = null;
    _currentMode = null;
  }

  // ローカルに保存
  Future<void> _saveLocalStudyTime() async {
    if (_startTime == null || _currentMode == null) return;

    final prefs = await _prefs;
    final now = DateTime.now();
    final duration = now.difference(_startTime!).inSeconds;

    final key =
        'study_time_${_currentMode}_${_startTime!.millisecondsSinceEpoch}';
    await prefs.setInt(key, duration);
  }

  // Firestoreに保存
  Future<void> _saveStudyTime(String mode, int durationSeconds) async {
    final user = _auth.currentUser;
    if (user == null) return;

    final studyTime = {
      'userId': user.uid,
      'mode': mode,
      'startTime': _startTime,
      'endTime': DateTime.now(),
      'durationSeconds': durationSeconds,
      'createdAt': FieldValue.serverTimestamp(),
    };

    await _firestore.collection('study_times').add(studyTime);
  }

  // 週間の学習時間を取得
  Future<Map<DateTime, int>> getStudyTimeForWeek(DateTime weekStart) async {
    final user = _auth.currentUser;
    if (user == null) return {};

    // 週開始は必ず 0:00 に丸める
    final startOfWeek =
        DateTime(weekStart.year, weekStart.month, weekStart.day);
    final endOfWeek = startOfWeek.add(const Duration(days: 7));

    final snapshot = await _firestore
        .collection('study_times')
        .where('userId', isEqualTo: user.uid)
        .where('startTime', isGreaterThanOrEqualTo: startOfWeek)
        .where('startTime', isLessThan: endOfWeek)
        .get();

    final Map<DateTime, int> dailyStudyTime = {};

    for (var doc in snapshot.docs) {
      final data = doc.data();
      final startTime = (data['startTime'] as Timestamp).toDate();
      final date = DateTime(startTime.year, startTime.month, startTime.day);
      final duration = data['durationSeconds'] as int;

      dailyStudyTime[date] = (dailyStudyTime[date] ?? 0) + duration;
    }

    return dailyStudyTime;
  }

  // 現在週の学習時間を取得（後方互換）
  Future<Map<DateTime, int>> getWeeklyStudyTime() async {
    final now = DateTime.now();
    final tmpStart = now.subtract(Duration(days: now.weekday - 1));
    final startOfWeek = DateTime(tmpStart.year, tmpStart.month, tmpStart.day);
    return getStudyTimeForWeek(startOfWeek);
  }

  // 指定月の学習時間（日単位）の合計を取得
  Future<Map<DateTime, int>> getStudyTimeForMonth(DateTime monthStart) async {
    final user = _auth.currentUser;
    if (user == null) return {};

    // 月初 0:00
    final startOfMonth = DateTime(monthStart.year, monthStart.month, 1);
    // 翌月初 0:00  (DateTime は月を自動繰り上げる)
    final endOfMonth = DateTime(monthStart.year, monthStart.month + 1, 1);

    final snapshot = await _firestore
        .collection('study_times')
        .where('userId', isEqualTo: user.uid)
        .where('startTime', isGreaterThanOrEqualTo: startOfMonth)
        .where('startTime', isLessThan: endOfMonth)
        .get();

    final Map<DateTime, int> dailyStudyTime = {};

    for (var doc in snapshot.docs) {
      final data = doc.data();
      final startTime = (data['startTime'] as Timestamp).toDate();
      final date = DateTime(startTime.year, startTime.month, startTime.day);
      final duration = data['durationSeconds'] as int;

      dailyStudyTime[date] = (dailyStudyTime[date] ?? 0) + duration;
    }

    return dailyStudyTime;
  }
}
