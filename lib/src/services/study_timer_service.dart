import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../sync/sync_engine.dart';
import 'tts_service.dart';

/// 勉強時間のセッション計測（ローカル SQLite 保存）
///
/// [attachDatabase] 後にのみ動作。Web や DB 未初期化時は no-op。
///
/// フォアグラウンドでも [idleTimeout] 間ユーザー操作が無いと集計を止める。
/// [onUserInteraction] は `StudyTimeUserActivityScope` から送る。
/// TTS 再生中は操作が無くても集計を継続する。
class StudyTimerService with WidgetsBindingObserver {
  StudyTimerService._();
  static final StudyTimerService instance = StudyTimerService._();

  /// この時間操作が無いと「操作待ち」とみなし、[duration_sec] に含めない（TTS 中は除く）
  static const Duration idleTimeout = Duration(minutes: 2);

  Database? _db;
  bool _observerRegistered = false;

  AppLifecycleState _lifecycle = AppLifecycleState.resumed;
  bool _ttsPlaying = false;

  Timer? _idleTimer;
  bool _idleTimedOut = false;

  bool _hasSession = false;
  String _sessionType = '';
  String? _contentId;
  String? _contentTitle;
  String? _unit;
  String? _subjectId;
  String? _subjectName;
  DateTime? _startedAtUtc;

  int _studyMs = 0;
  int _ttsMs = 0;
  Stopwatch? _studySegment;
  Stopwatch? _ttsSegment;

  bool get _shouldAccumulateStudy =>
      (_lifecycle == AppLifecycleState.resumed && !_idleTimedOut) || _ttsPlaying;

  void _cancelIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = null;
  }

  void _armIdleTimer() {
    _cancelIdleTimer();
    if (!_hasSession) return;
    _idleTimer = Timer(idleTimeout, () {
      _idleTimedOut = true;
      _syncRunningSegments();
    });
  }

  /// タップ・スクロール等。セッション中なら無操作タイマーをリセットする。
  void onUserInteraction() {
    if (!_hasSession) return;
    final wasIdle = _idleTimedOut;
    _idleTimedOut = false;
    _armIdleTimer();
    if (wasIdle) {
      _syncRunningSegments();
    }
  }

  void attachDatabase(Database db) {
    _db = db;
    if (!_observerRegistered) {
      WidgetsBinding.instance.addObserver(this);
      _observerRegistered = true;
    }
    TtsService.setStudyTimerTtsPlayingCallback(_onTtsPlayingFromEngine);
    unawaited(_cleanupOrphanSessions());
  }

  static void _onTtsPlayingFromEngine(bool playing) {
    instance._setTtsPlaying(playing);
  }

  void _setTtsPlaying(bool playing) {
    if (_ttsPlaying == playing) return;
    _ttsPlaying = playing;
    _syncRunningSegments();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    _syncRunningSegments();
  }

  void _flushStudySegment() {
    final sw = _studySegment;
    if (sw != null) {
      _studyMs += sw.elapsedMilliseconds;
      _studySegment = null;
    }
  }

  void _flushTtsSegment() {
    final sw = _ttsSegment;
    if (sw != null) {
      _ttsMs += sw.elapsedMilliseconds;
      _ttsSegment = null;
    }
  }

  void _syncRunningSegments() {
    if (!_hasSession) return;

    if (_shouldAccumulateStudy) {
      _studySegment ??= Stopwatch()..start();
    } else {
      _flushStudySegment();
    }

    if (_ttsPlaying) {
      _ttsSegment ??= Stopwatch()..start();
    } else {
      _flushTtsSegment();
    }
  }

  static String? truncateTitle(String? raw) {
    if (raw == null) return null;
    final t = raw.trim();
    if (t.isEmpty) return null;
    if (t.length <= 50) return t;
    return '${t.substring(0, 50)}…';
  }

  /// 進行中セッションがあれば終了してから開始する。
  Future<void> startSession({
    required String sessionType,
    String? contentId,
    String? contentTitle,
    String? unit,
    String? subjectId,
    String? subjectName,
  }) async {
    if (_db == null) return;
    if (_hasSession) await endSession();

    _sessionType = sessionType;
    _contentId = contentId;
    _contentTitle = truncateTitle(contentTitle);
    final u = unit?.trim();
    _unit = (u == null || u.isEmpty) ? null : u;
    final sid = subjectId?.trim();
    _subjectId = (sid == null || sid.isEmpty) ? null : sid;
    final sname = subjectName?.trim();
    _subjectName = (sname == null || sname.isEmpty) ? null : sname;
    _startedAtUtc = DateTime.now().toUtc();
    _studyMs = 0;
    _ttsMs = 0;
    _studySegment = null;
    _ttsSegment = null;
    _idleTimedOut = false;
    _hasSession = true;
    _armIdleTimer();
    _syncRunningSegments();
  }

  Future<void> endSession() async {
    if (!_hasSession || _db == null) return;

    _cancelIdleTimer();
    _idleTimedOut = false;

    _flushStudySegment();
    _flushTtsSegment();

    final started = _startedAtUtc ?? DateTime.now().toUtc();
    final ended = DateTime.now().toUtc();
    final durationSec = (_studyMs / 1000).round();
    final ttsSec = (_ttsMs / 1000).round();

    final endedIso = ended.toIso8601String();
    final learnerId = Supabase.instance.client.auth.currentUser?.id ?? '';
    final row = <String, Object?>{
      'dirty': 1,
      'deleted': 0,
      'updated_at': endedIso,
      'learner_id': learnerId,
      'session_type': _sessionType,
      'content_id': _contentId,
      'content_title': _contentTitle,
      'unit': _unit,
      'subject_id': _subjectId,
      'subject_name': _subjectName,
      'tts_sec': ttsSec,
      'started_at': started.toIso8601String(),
      'ended_at': endedIso,
      'duration_sec': durationSec,
      'created_at': endedIso,
    };

    _hasSession = false;
    _sessionType = '';
    _contentId = null;
    _contentTitle = null;
    _unit = null;
    _subjectId = null;
    _subjectName = null;
    _startedAtUtc = null;
    _studyMs = 0;
    _ttsMs = 0;

    try {
      await _db!.insert('study_sessions', row);
      if (SyncEngine.isInitialized) {
        unawaited(SyncEngine.instance.pushDirtyStudySessionsIfOnline());
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('StudyTimerService: insert failed: $e');
        debugPrint('$st');
      }
    }
  }

  Future<void> _cleanupOrphanSessions() async {
    final db = _db;
    if (db == null) return;
    try {
      await db.delete(
        'study_sessions',
        where: 'ended_at IS NULL',
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('StudyTimerService: orphan cleanup failed: $e');
      }
    }
  }
}
