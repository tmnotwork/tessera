import 'package:flutter/material.dart';

import '../services/tts_service.dart';

/// 読み上げ設定画面
///
/// yomiage_lib の TtsSettingScreen を tessera 向けに移植。
/// 設定は TtsService 経由で shared_preferences に永続化される。
class TtsSettingScreen extends StatefulWidget {
  const TtsSettingScreen({super.key});

  @override
  State<TtsSettingScreen> createState() => _TtsSettingScreenState();
}

class _TtsSettingScreenState extends State<TtsSettingScreen> {
  double _jaSpeed = 0.9;
  double _enSpeed = 0.4;
  int _answerRepeatCount = 3;
  int _answerPauseSeconds = 3;
  bool _randomPlayback = false;
  LoopMode _loopMode = LoopMode.none;
  bool _reversePlayback = false;
  bool _focusedMemorization = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    TtsService.initTts().then((_) {
      if (!mounted) return;
      setState(() {
        _jaSpeed = TtsService.speechRateJa;
        _enSpeed = TtsService.speechRateEn;
        _answerRepeatCount = TtsService.answerRepeatCount;
        _answerPauseSeconds = TtsService.answerPauseSeconds;
        _randomPlayback = TtsService.randomPlayback;
        _loopMode = TtsService.loopMode;
        _reversePlayback = TtsService.reversePlayback;
        _focusedMemorization = TtsService.focusedMemorization;
        _loaded = true;
      });
    });
  }

  String _loopModeLabel(LoopMode m) {
    switch (m) {
      case LoopMode.none:
        return 'ループなし';
      case LoopMode.once:
        return '一周ループ';
      case LoopMode.all:
        return '全てループ';
      case LoopMode.single:
        return '単一カードループ';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('読み上げ設定')),
      body: _loaded
          ? ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _SectionHeader('速度'),
                const SizedBox(height: 8),
                _SpeedTile(
                  label: '日本語の速度',
                  value: _jaSpeed,
                  onChanged: (v) {
                    setState(() => _jaSpeed = v);
                    TtsService.setSpeechRateJa(v);
                  },
                ),
                const SizedBox(height: 4),
                _SpeedTile(
                  label: '英語の速度',
                  value: _enSpeed,
                  onChanged: (v) {
                    setState(() => _enSpeed = v);
                    TtsService.setSpeechRateEn(v);
                  },
                ),
                const SizedBox(height: 20),
                _SectionHeader('出題'),
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('英語の繰り返し回数'),
                  subtitle: Text('$_answerRepeatCount 回'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.remove),
                        onPressed: _answerRepeatCount <= 1
                            ? null
                            : () {
                                setState(() => _answerRepeatCount--);
                                TtsService.setAnswerRepeatCount(_answerRepeatCount);
                              },
                      ),
                      SizedBox(
                        width: 32,
                        child: Text(
                          '$_answerRepeatCount',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.add),
                        onPressed: _answerRepeatCount >= 5
                            ? null
                            : () {
                                setState(() => _answerRepeatCount++);
                                TtsService.setAnswerRepeatCount(_answerRepeatCount);
                              },
                      ),
                    ],
                  ),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('読み上げ回答時間'),
                  subtitle: Text('質問読み上げ後、答えを表示するまで $_answerPauseSeconds 秒待ちます'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.remove),
                        onPressed: _answerPauseSeconds <= 1
                            ? null
                            : () {
                                setState(() => _answerPauseSeconds--);
                                TtsService.setAnswerPauseSeconds(_answerPauseSeconds);
                              },
                      ),
                      SizedBox(
                        width: 32,
                        child: Text(
                          '$_answerPauseSeconds',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.add),
                        onPressed: _answerPauseSeconds >= 10
                            ? null
                            : () {
                                setState(() => _answerPauseSeconds++);
                                TtsService.setAnswerPauseSeconds(_answerPauseSeconds);
                              },
                      ),
                    ],
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('ランダム読み上げ'),
                  subtitle: const Text('出題順をランダムにする'),
                  value: _randomPlayback,
                  onChanged: (v) {
                    setState(() => _randomPlayback = v);
                    TtsService.setRandomPlayback(v);
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('ループモード'),
                  subtitle: Text(_loopModeLabel(_loopMode)),
                  trailing: SizedBox(
                    width: 168,
                    child: DropdownButton<LoopMode>(
                      isExpanded: true,
                      value: _loopMode,
                      items: LoopMode.values
                          .map(
                            (m) => DropdownMenuItem(
                              value: m,
                              child: Text(_loopModeLabel(m)),
                            ),
                          )
                          .toList(),
                      onChanged: (m) {
                        if (m == null) return;
                        setState(() => _loopMode = m);
                        TtsService.setLoopMode(m);
                      },
                    ),
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('逆出題'),
                  subtitle: const Text('英語を先に読み、日本語を答えとして読み上げます'),
                  value: _reversePlayback,
                  onChanged: (v) {
                    setState(() => _reversePlayback = v);
                    TtsService.setReversePlayback(v);
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('集中暗記'),
                  subtitle: const Text('連続正解回数が1以下の例文のみ出題します'),
                  value: _focusedMemorization,
                  onChanged: (v) {
                    setState(() => _focusedMemorization = v);
                    TtsService.setFocusedMemorization(v);
                  },
                ),
                const SizedBox(height: 16),
                Text(
                  '* 速度は端末のTTSエンジンに依存します。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            )
          : const Center(child: CircularProgressIndicator()),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: Colors.grey[600],
      ),
    );
  }
}

class _SpeedTile extends StatelessWidget {
  const _SpeedTile({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$label: ${value.toStringAsFixed(1)}'),
        Slider(
          value: value,
          min: 0.1,
          max: 2.0,
          divisions: 19,
          label: value.toStringAsFixed(1),
          onChanged: onChanged,
        ),
      ],
    );
  }
}
