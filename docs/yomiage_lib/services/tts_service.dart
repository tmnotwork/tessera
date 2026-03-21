import 'package:flutter_tts/flutter_tts.dart';
import 'package:yomiage/services/hive_service.dart';

import 'loop_mode.dart';

export 'loop_mode.dart';

class TtsService {
  static final FlutterTts _flutterTts = FlutterTts();
  static bool _initialized = false;

  // 日本語用の速度
  static double _speechRateJa = 0.9;
  // 英語用の速度
  static double _speechRateEn = 0.4;
  // 回答の読み上げ回数（デフォルトは3回）
  static int _answerRepeatCount = 3;
  // ループモード設定
  static LoopMode _loopMode = LoopMode.none;
  // ランダム読み上げ設定
  static bool _randomPlayback = false;
  // 逆出題モード設定
  static bool _reversePlayback = false;
  // 集中暗記モード設定
  static bool _focusedMemorization = false;
  // 読み上げ回答時間（デフォルトは3秒）
  static int _answerPauseSeconds = 3;

  static Future<void> initTts() async {
    if (!_initialized) {
      await _flutterTts.awaitSpeakCompletion(true);

      // Hiveの設定Boxから読み込み
      final settingsBox = HiveService.getSettingsBox();

      // もし保存してあれば使う、なければデフォルト
      double? savedJa = settingsBox.get('ttsSpeedJa');
      double? savedEn = settingsBox.get('ttsSpeedEn');
      int? savedRepeatCount = settingsBox.get('ttsAnswerRepeatCount');
      int? savedLoopMode = settingsBox.get('ttsLoopMode');
      bool? savedRandomPlayback = settingsBox.get('ttsRandomPlayback');
      int? savedAnswerPauseSeconds = settingsBox.get('ttsAnswerPauseSeconds');
      bool? savedReversePlayback = settingsBox.get('ttsReversePlayback');
      bool? savedFocusedMemorization =
          settingsBox.get('ttsFocusedMemorization');

      _speechRateJa = savedJa ?? 0.9;
      _speechRateEn = savedEn ?? 0.4;
      _answerRepeatCount = savedRepeatCount ?? 3;
      _loopMode = savedLoopMode != null
          ? LoopMode.values[savedLoopMode]
          : LoopMode.none;
      _randomPlayback = savedRandomPlayback ?? false;
      _answerPauseSeconds = savedAnswerPauseSeconds ?? 3;
      _reversePlayback = savedReversePlayback ?? false;
      _focusedMemorization = savedFocusedMemorization ?? false;

      _initialized = true;
    }
  }

  static double get speechRateJa => _speechRateJa;
  static double get speechRateEn => _speechRateEn;
  static int get answerRepeatCount => _answerRepeatCount;
  static LoopMode get loopMode => _loopMode;
  static bool get randomPlayback => _randomPlayback;
  static bool get reversePlayback => _reversePlayback;
  static bool get focusedMemorization => _focusedMemorization;
  static int get answerPauseSeconds => _answerPauseSeconds;

  static Future<void> setSpeechRateJa(double rate) async {
    if (rate < 0.1) rate = 0.1;
    if (rate > 2.0) rate = 2.0;
    _speechRateJa = rate;

    // Hiveに保存
    final settingsBox = HiveService.getSettingsBox();
    settingsBox.put('ttsSpeedJa', _speechRateJa);
  }

  static Future<void> setSpeechRateEn(double rate) async {
    if (rate < 0.1) rate = 0.1;
    if (rate > 2.0) rate = 2.0;
    _speechRateEn = rate;

    // Hiveに保存
    final settingsBox = HiveService.getSettingsBox();
    settingsBox.put('ttsSpeedEn', _speechRateEn);
  }

  static Future<void> setAnswerRepeatCount(int count) async {
    if (count < 1) count = 1;
    if (count > 5) count = 5;
    _answerRepeatCount = count;

    // Hiveに保存
    final settingsBox = HiveService.getSettingsBox();
    settingsBox.put('ttsAnswerRepeatCount', _answerRepeatCount);
  }

  static Future<void> setLoopMode(LoopMode mode) async {
    _loopMode = mode;

    // Hiveに保存（列挙型のインデックスを保存）
    final settingsBox = HiveService.getSettingsBox();
    settingsBox.put('ttsLoopMode', _loopMode.index);
  }

  static Future<void> setRandomPlayback(bool randomPlayback) async {
    _randomPlayback = randomPlayback;

    // Hiveに保存
    final settingsBox = HiveService.getSettingsBox();
    settingsBox.put('ttsRandomPlayback', _randomPlayback);
  }

  static Future<void> setReversePlayback(bool reversePlayback) async {
    _reversePlayback = reversePlayback;
    // Hiveに保存
    final settingsBox = HiveService.getSettingsBox();
    settingsBox.put('ttsReversePlayback', _reversePlayback);
  }

  static Future<void> setFocusedMemorization(bool focused) async {
    _focusedMemorization = focused;
    // Hiveに保存
    final settingsBox = HiveService.getSettingsBox();
    settingsBox.put('ttsFocusedMemorization', _focusedMemorization);
  }

  static Future<void> setAnswerPauseSeconds(int seconds) async {
    if (seconds < 1) seconds = 1;
    if (seconds > 10) seconds = 10;
    _answerPauseSeconds = seconds;

    // Hiveに保存
    final settingsBox = HiveService.getSettingsBox();
    settingsBox.put('ttsAnswerPauseSeconds', _answerPauseSeconds);
  }

  // isEnglish==true → 英語速度, false → 日本語速度
  static Future<void> speak(String text, bool isEnglish) async {
    if (!_initialized) {
      await initTts();
    }

    if (isEnglish) {
      await _flutterTts.setLanguage("en-US");
      await _flutterTts.setSpeechRate(_speechRateEn);
    } else {
      await _flutterTts.setLanguage("ja-JP");
      await _flutterTts.setSpeechRate(_speechRateJa);
    }

    await _flutterTts.speak(text);
  }

  static Future<void> stop() async {
    await _flutterTts.stop();
  }
}
