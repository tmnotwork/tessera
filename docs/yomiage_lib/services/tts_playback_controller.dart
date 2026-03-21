import 'cloud_tts_service.dart';
import 'tts_service.dart';

abstract class TtsPlaybackController {
  const TtsPlaybackController();

  Future<void> init();

  LoopMode get loopMode;
  Future<void> setLoopMode(LoopMode mode);

  bool get randomPlayback;
  Future<void> setRandomPlayback(bool value);

  bool get reversePlayback;
  Future<void> setReversePlayback(bool value);

  bool get focusedMemorization;
  Future<void> setFocusedMemorization(bool value);

  int get answerRepeatCount;
  Future<void> setAnswerRepeatCount(int count);

  int get answerPauseSeconds;
  Future<void> setAnswerPauseSeconds(int seconds);

  Future<void> speak(String text, bool isEnglish);
  Future<void> stop();
}

class LocalTtsPlaybackController extends TtsPlaybackController {
  const LocalTtsPlaybackController();

  @override
  Future<void> init() => TtsService.initTts();

  @override
  LoopMode get loopMode => TtsService.loopMode;

  @override
  Future<void> setLoopMode(LoopMode mode) => TtsService.setLoopMode(mode);

  @override
  bool get randomPlayback => TtsService.randomPlayback;

  @override
  Future<void> setRandomPlayback(bool value) =>
      TtsService.setRandomPlayback(value);

  @override
  bool get reversePlayback => TtsService.reversePlayback;

  @override
  Future<void> setReversePlayback(bool value) =>
      TtsService.setReversePlayback(value);

  @override
  bool get focusedMemorization => TtsService.focusedMemorization;

  @override
  Future<void> setFocusedMemorization(bool value) =>
      TtsService.setFocusedMemorization(value);

  @override
  int get answerRepeatCount => TtsService.answerRepeatCount;

  @override
  Future<void> setAnswerRepeatCount(int count) =>
      TtsService.setAnswerRepeatCount(count);

  @override
  int get answerPauseSeconds => TtsService.answerPauseSeconds;

  @override
  Future<void> setAnswerPauseSeconds(int seconds) =>
      TtsService.setAnswerPauseSeconds(seconds);

  @override
  Future<void> speak(String text, bool isEnglish) =>
      TtsService.speak(text, isEnglish);

  @override
  Future<void> stop() => TtsService.stop();
}

class CloudTtsPlaybackController extends TtsPlaybackController {
  const CloudTtsPlaybackController();

  @override
  Future<void> init() => CloudTtsService.init();

  @override
  LoopMode get loopMode => CloudTtsService.loopMode;

  @override
  Future<void> setLoopMode(LoopMode mode) =>
      CloudTtsService.setLoopMode(mode);

  @override
  bool get randomPlayback => CloudTtsService.randomPlayback;

  @override
  Future<void> setRandomPlayback(bool value) =>
      CloudTtsService.setRandomPlayback(value);

  @override
  bool get reversePlayback => CloudTtsService.reversePlayback;

  @override
  Future<void> setReversePlayback(bool value) =>
      CloudTtsService.setReversePlayback(value);

  @override
  bool get focusedMemorization => CloudTtsService.focusedMemorization;

  @override
  Future<void> setFocusedMemorization(bool value) =>
      CloudTtsService.setFocusedMemorization(value);

  @override
  int get answerRepeatCount => CloudTtsService.answerRepeatCount;

  @override
  Future<void> setAnswerRepeatCount(int count) =>
      CloudTtsService.setAnswerRepeatCount(count);

  @override
  int get answerPauseSeconds => CloudTtsService.answerPauseSeconds;

  @override
  Future<void> setAnswerPauseSeconds(int seconds) =>
      CloudTtsService.setAnswerPauseSeconds(seconds);

  @override
  Future<void> speak(String text, bool isEnglish) =>
      CloudTtsService.speak(text, isEnglish);

  @override
  Future<void> stop() => CloudTtsService.stop();
}
