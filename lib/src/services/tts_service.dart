import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 音声読み上げサービス（flutter_tts ラッパー）
///
/// 設定は shared_preferences で永続化する。
/// yomiage_lib の TtsService を tessera 向けに移植したもの。
class TtsService {
  static final FlutterTts _flutterTts = FlutterTts();
  static bool _initialized = false;

  /// 日本語用の速度（デフォルト 0.5）
  static double _speechRateJa = 0.5;

  /// 英語用の速度（デフォルト 0.4）
  static double _speechRateEn = 0.4;

  /// 回答の読み上げ回数（デフォルト 1 回）
  static int _answerRepeatCount = 1;

  /// 読み上げ後の回答ポーズ秒数（デフォルト 3 秒）
  static int _answerPauseSeconds = 3;

  /// ランダム読み上げ（デフォルト OFF）
  static bool _randomPlayback = false;

  static double get speechRateJa => _speechRateJa;
  static double get speechRateEn => _speechRateEn;
  static int get answerRepeatCount => _answerRepeatCount;
  static int get answerPauseSeconds => _answerPauseSeconds;
  static bool get randomPlayback => _randomPlayback;

  static Future<void> initTts() async {
    if (_initialized) return;

    await _flutterTts.awaitSpeakCompletion(true);

    final prefs = await SharedPreferences.getInstance();
    _speechRateJa = prefs.getDouble('ttsSpeedJa') ?? 0.5;
    _speechRateEn = prefs.getDouble('ttsSpeedEn') ?? 0.4;
    _answerRepeatCount = prefs.getInt('ttsAnswerRepeatCount') ?? 1;
    _answerPauseSeconds = prefs.getInt('ttsAnswerPauseSeconds') ?? 3;
    _randomPlayback = prefs.getBool('ttsRandomPlayback') ?? false;

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

    await _flutterTts.speak(text);
  }

  static Future<void> stop() async {
    await _flutterTts.stop();
  }
}
