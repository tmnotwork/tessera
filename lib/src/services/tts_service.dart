import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'loop_mode.dart';

export 'loop_mode.dart';

/// 音声読み上げサービス（flutter_tts ラッパー）
///
/// 設定は shared_preferences で永続化する。
/// 旧アプリ（`docs/yomiage_lib/services/tts_service.dart`）と同等の項目を保持する。
/// 英語例文の出題（[EnglishExampleSolveScreen]）や設定画面から利用する。
class TtsService {
  static final FlutterTts _flutterTts = FlutterTts();
  static bool _initialized = false;

  /// 勉強時間計測用（任意）。再生開始/終了時に通知する。
  static void Function(bool isPlaying)? _studyTimerTtsPlayingCallback;

  static void setStudyTimerTtsPlayingCallback(void Function(bool isPlaying)? cb) {
    _studyTimerTtsPlayingCallback = cb;
  }

  /// 日本語用の速度（yomiage 既定 0.9）
  static double _speechRateJa = 0.9;

  /// 英語用の速度（デフォルト 0.4）
  static double _speechRateEn = 0.4;

  /// 回答の読み上げ回数（yomiage 既定 3）
  static int _answerRepeatCount = 3;

  /// 質問読み上げ後〜答え表示までの秒数（デフォルト 3 秒）
  static int _answerPauseSeconds = 3;

  /// ランダム読み上げ（デフォルト OFF）
  static bool _randomPlayback = false;

  static LoopMode _loopMode = LoopMode.none;

  /// 逆出題（表裏を入れ替えて読み上げ）
  static bool _reversePlayback = false;

  /// 集中暗記（repetitions <= 1 のカードのみ）
  static bool _focusedMemorization = false;

  static double get speechRateJa => _speechRateJa;
  static double get speechRateEn => _speechRateEn;
  static int get answerRepeatCount => _answerRepeatCount;
  static int get answerPauseSeconds => _answerPauseSeconds;
  static bool get randomPlayback => _randomPlayback;
  static LoopMode get loopMode => _loopMode;
  static bool get reversePlayback => _reversePlayback;
  static bool get focusedMemorization => _focusedMemorization;

  static void _applyPrefs(SharedPreferences prefs) {
    _speechRateJa = prefs.getDouble('ttsSpeedJa') ?? 0.9;
    _speechRateEn = prefs.getDouble('ttsSpeedEn') ?? 0.4;
    _answerRepeatCount = prefs.getInt('ttsAnswerRepeatCount') ?? 3;
    _answerPauseSeconds = prefs.getInt('ttsAnswerPauseSeconds') ?? 3;
    _randomPlayback = prefs.getBool('ttsRandomPlayback') ?? false;
    final loopIdx = prefs.getInt('ttsLoopMode');
    _loopMode = loopIdx != null && loopIdx >= 0 && loopIdx < LoopMode.values.length
        ? LoopMode.values[loopIdx]
        : LoopMode.none;
    _reversePlayback = prefs.getBool('ttsReversePlayback') ?? false;
    _focusedMemorization = prefs.getBool('ttsFocusedMemorization') ?? false;
  }

  /// 設定画面などから戻ったあとに最新の shared_preferences を再読込する。
  static Future<void> refreshPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    _applyPrefs(prefs);
  }

  static Future<void> initTts() async {
    if (_initialized) return;

    await _flutterTts.awaitSpeakCompletion(true);

    final prefs = await SharedPreferences.getInstance();
    _applyPrefs(prefs);

    _initialized = true;
  }

  static Future<void> setSpeechRateJa(double rate) async {
    _speechRateJa = rate.clamp(0.1, 2.0);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('ttsSpeedJa', _speechRateJa);
  }

  static Future<void> setSpeechRateEn(double rate) async {
    _speechRateEn = rate.clamp(0.1, 2.0);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('ttsSpeedEn', _speechRateEn);
  }

  static Future<void> setAnswerRepeatCount(int count) async {
    _answerRepeatCount = count.clamp(1, 5);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('ttsAnswerRepeatCount', _answerRepeatCount);
  }

  static Future<void> setAnswerPauseSeconds(int seconds) async {
    _answerPauseSeconds = seconds.clamp(1, 10);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('ttsAnswerPauseSeconds', _answerPauseSeconds);
  }

  static Future<void> setRandomPlayback(bool value) async {
    _randomPlayback = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('ttsRandomPlayback', _randomPlayback);
  }

  static Future<void> setLoopMode(LoopMode mode) async {
    _loopMode = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('ttsLoopMode', _loopMode.index);
  }

  static Future<void> setReversePlayback(bool value) async {
    _reversePlayback = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('ttsReversePlayback', _reversePlayback);
  }

  static Future<void> setFocusedMemorization(bool value) async {
    _focusedMemorization = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('ttsFocusedMemorization', _focusedMemorization);
  }

  /// [isEnglish] が true なら英語速度・言語、false なら日本語速度・言語で読み上げる。
  static Future<void> speak(String text, {required bool isEnglish}) async {
    if (!_initialized) await initTts();
    if (text.trim().isEmpty) return;

    if (isEnglish) {
      await _flutterTts.setLanguage('en-US');
      await _flutterTts.setSpeechRate(_speechRateEn);
    } else {
      await _flutterTts.setLanguage('ja-JP');
      await _flutterTts.setSpeechRate(_speechRateJa);
    }

    _studyTimerTtsPlayingCallback?.call(true);
    try {
      await _flutterTts.speak(text);
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('TtsService.speak failed: $e');
        debugPrint('$st');
      }
    } finally {
      _studyTimerTtsPlayingCallback?.call(false);
    }
  }

  static Future<void> stop() async {
    await _flutterTts.stop();
    _studyTimerTtsPlayingCallback?.call(false);
  }
}
