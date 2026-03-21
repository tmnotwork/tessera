import 'dart:convert';
import 'dart:io';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart';
import 'package:just_audio/just_audio.dart' as just_audio;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:yomiage/services/tts_service.dart';

/// Google Cloud Text-to-Speech ??????????????
///
/// ??? [TtsService] ??????????????
/// ??????????????????
class CloudTtsService {
  static final just_audio.AudioPlayer _audioPlayer = just_audio.AudioPlayer();
  static bool _initialized = false;

  static const String _cacheDirectoryName = 'cloud_tts_cache';

  static const String _defaultJapaneseVoice = 'ja-JP-Neural2-B';
  static const String _defaultEnglishVoice = 'en-US-Neural2-C';

  static Future<void> init() async {
    if (_initialized) {
      return;
    }

    await TtsService.initTts();
    _initialized = true;
  }

  static LoopMode get loopMode => TtsService.loopMode;

  static Future<void> setLoopMode(LoopMode mode) => TtsService.setLoopMode(mode);

  static bool get randomPlayback => TtsService.randomPlayback;

  static Future<void> setRandomPlayback(bool randomPlayback) =>
      TtsService.setRandomPlayback(randomPlayback);

  static bool get reversePlayback => TtsService.reversePlayback;

  static Future<void> setReversePlayback(bool value) =>
      TtsService.setReversePlayback(value);

  static bool get focusedMemorization => TtsService.focusedMemorization;

  static Future<void> setFocusedMemorization(bool value) =>
      TtsService.setFocusedMemorization(value);

  static int get answerRepeatCount => TtsService.answerRepeatCount;

  static Future<void> setAnswerRepeatCount(int count) =>
      TtsService.setAnswerRepeatCount(count);

  static int get answerPauseSeconds => TtsService.answerPauseSeconds;

  static Future<void> setAnswerPauseSeconds(int seconds) =>
      TtsService.setAnswerPauseSeconds(seconds);

  static double get speechRateJa => TtsService.speechRateJa;

  static Future<void> setSpeechRateJa(double rate) =>
      TtsService.setSpeechRateJa(rate);

  static double get speechRateEn => TtsService.speechRateEn;

  static Future<void> setSpeechRateEn(double rate) =>
      TtsService.setSpeechRateEn(rate);

  static Future<void> speak(String text, bool isEnglish) async {
    await init();

    if (text.trim().isEmpty) {
      return;
    }

    final File audioFile = await _obtainAudio(text, isEnglish);

    await _audioPlayer.stop();
    await _audioPlayer.setFilePath(audioFile.path);
    await _audioPlayer.play();
  }

  static Future<void> stop() async {
    await _audioPlayer.stop();
  }

  static Future<File> _obtainAudio(String text, bool isEnglish) async {
    final Directory dir = await _cacheDirectory();
    final String hash = _buildCacheKey(text, isEnglish);
    final File file = File(p.join(dir.path, '$hash.mp3'));

    if (await file.exists()) {
      return file;
    }

    final List<int> bytes = await _synthesize(text, isEnglish);
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  static Future<Directory> _cacheDirectory() async {
    final Directory baseDir = await getApplicationSupportDirectory();
    final Directory dir = Directory(p.join(baseDir.path, _cacheDirectoryName));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static String _buildCacheKey(String text, bool isEnglish) {
    final String languageCode = isEnglish ? 'en-US' : 'ja-JP';
    final String voiceName = isEnglish ? _defaultEnglishVoice : _defaultJapaneseVoice;
    final double baseRate = isEnglish ? speechRateEn : speechRateJa;
    final double mapped = _mapRate(isEnglish: isEnglish, baseRate: baseRate);
    final String payload = '$languageCode|$voiceName|${mapped.toStringAsFixed(3)}|$text';

    final Digest digest = sha256.convert(utf8.encode(payload));
    return digest.toString();
  }

  static Future<List<int>> _synthesize(String text, bool isEnglish) async {
    // 認証トークンを必ず付与（未ログイン時は匿名でフォールバック）
    final auth = FirebaseAuth.instance;
    if (auth.currentUser == null) {
      try {
        await auth.signInAnonymously();
      } catch (_) {}
    }

    final FirebaseFunctions functions = FirebaseFunctions.instanceFor(region: 'us-central1');
    final HttpsCallable callable = functions.httpsCallable(
      'generateCloudTts',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
    );

    // 端末設定(0.1~2.0) → Cloud TTS(1.0=標準)へマッピング
    final double baseRate = isEnglish ? speechRateEn : speechRateJa;
    final double mappedRate = _mapRate(isEnglish: isEnglish, baseRate: baseRate);

    final Map<String, dynamic> payload = {
      'text': text,
      'languageCode': isEnglish ? 'en-US' : 'ja-JP',
      'voiceName': isEnglish ? _defaultEnglishVoice : _defaultJapaneseVoice,
      'speakingRate': mappedRate,
      'audioEncoding': 'MP3',
    };

    try {
      final HttpsCallableResult<dynamic> result = await callable.call(payload);
      final dynamic data = result.data;
      if (data is Map<String, dynamic>) {
        final String? audioContent = data['audioContent'] as String?;
        if (audioContent != null && audioContent.isNotEmpty) {
          return base64Decode(audioContent);
        }
      }
      throw Exception('クラウドTTSのレスポンスに audioContent が含まれていません');
    } on FirebaseFunctionsException catch (e) {
      // App Check/認証などでCallableが弾かれる場合にHTTP版へフォールバック
      if (e.code == 'unauthenticated' || e.code == 'failed-precondition') {
        final uri = Uri.parse('https://us-central1-yomiage-1f7fd.cloudfunctions.net/generateCloudTtsHttp');
        final response = await http.post(
          uri,
          headers: { 'Content-Type': 'application/json' },
          body: jsonEncode(payload),
        ).timeout(const Duration(seconds: 30));
        if (response.statusCode == 200) {
          final Map<String, dynamic> data = jsonDecode(response.body) as Map<String, dynamic>;
          final String? audioContent = data['audioContent'] as String?;
          if (audioContent != null && audioContent.isNotEmpty) {
            return base64Decode(audioContent);
          }
        }
        throw Exception('HTTP版クラウドTTSの取得に失敗しました: ${response.statusCode}');
      }
      rethrow;
    }
  }

  // 言語ごとの体感差を吸収する速度マッピング
  static double _mapRate({required bool isEnglish, required double baseRate}) {
    if (isEnglish) {
      double r = baseRate * 2.5; // 英語はやや速め
      if (r < 0.5) r = 0.5;
      if (r > 3.0) r = 3.0;
      return r;
    } else {
      double r = baseRate * 1.25; // 日本語をやや速めに調整
      if (r < 0.5) r = 0.5;
      if (r > 1.8) r = 1.8;
      return r;
    }
  }
}
