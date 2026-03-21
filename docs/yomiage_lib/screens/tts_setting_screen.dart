// ignore_for_file: library_private_types_in_public_api

import 'package:flutter/material.dart';
import 'package:yomiage/services/tts_service.dart';

class TtsSettingScreen extends StatefulWidget {
  const TtsSettingScreen({Key? key}) : super(key: key);

  @override
  _TtsSettingScreenState createState() => _TtsSettingScreenState();
}

class _TtsSettingScreenState extends State<TtsSettingScreen> {
  double _jaSpeed = 0.9;
  double _enSpeed = 1.0;
  bool _randomPlayback = false;
  int _answerPauseSeconds = 3;

  @override
  void initState() {
    super.initState();
    // TTSサービスを初期化し、保存済みの速度設定を取得する
    TtsService.initTts().then((_) {
      setState(() {
        _jaSpeed = TtsService.speechRateJa;
        _enSpeed = TtsService.speechRateEn;
        _randomPlayback = TtsService.randomPlayback;
        _answerPauseSeconds = TtsService.answerPauseSeconds;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('読み上げ設定'),
        backgroundColor: Theme.of(context).appBarTheme.backgroundColor,
      ),
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Text('日本語速度: ${_jaSpeed.toStringAsFixed(1)}',
                style: TextStyle(color: Theme.of(context).textTheme.bodyLarge?.color, fontSize: 20)),
            Slider(
              value: _jaSpeed,
              min: 0.1,
              max: 2.0,
              divisions: 19,
              label: _jaSpeed.toStringAsFixed(1),
              onChanged: (newValue) {
                setState(() {
                  _jaSpeed = newValue;
                });
                TtsService.setSpeechRateJa(newValue);
              },
            ),
            const SizedBox(height: 20),
            Text('英語速度: ${_enSpeed.toStringAsFixed(1)}',
                style: TextStyle(color: Theme.of(context).textTheme.bodyLarge?.color, fontSize: 20)),
            Slider(
              value: _enSpeed,
              min: 0.1,
              max: 2.0,
              divisions: 19,
              label: _enSpeed.toStringAsFixed(1),
              onChanged: (newValue) {
                setState(() {
                  _enSpeed = newValue;
                });
                TtsService.setSpeechRateEn(newValue);
              },
            ),
            const SizedBox(height: 20),
            Text('読み上げ回答時間: $_answerPauseSeconds 秒',
                style: TextStyle(color: Theme.of(context).textTheme.bodyLarge?.color, fontSize: 20)),
            Slider(
              value: _answerPauseSeconds.toDouble(),
              min: 1,
              max: 10,
              divisions: 9,
              label: _answerPauseSeconds.toString(),
              onChanged: (newValue) {
                setState(() {
                  _answerPauseSeconds = newValue.round();
                });
                TtsService.setAnswerPauseSeconds(_answerPauseSeconds);
              },
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('ランダム読み上げをオンにする',
                    style: TextStyle(color: Theme.of(context).textTheme.bodyLarge?.color, fontSize: 20)),
                Switch(
                  value: _randomPlayback,
                  onChanged: (newValue) {
                    setState(() {
                      _randomPlayback = newValue;
                    });
                    TtsService.setRandomPlayback(newValue);
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
