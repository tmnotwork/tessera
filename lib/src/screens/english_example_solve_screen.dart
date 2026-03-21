import 'package:flutter/material.dart';

import '../models/english_example.dart';
import '../services/tts_service.dart';

/// 英語例文の出題。表=日本語 → 裏=英語 → 解説・補足 → 自己申告
///
/// TTS 動作:
///   - カードが表示されると日本語（表）を自動読み上げ
///   - 「英語（裏）を見る」を押すと英語を自動読み上げ
///   - 各カードのスピーカーボタンで手動再生
class EnglishExampleSolveScreen extends StatefulWidget {
  const EnglishExampleSolveScreen({
    super.key,
    required this.examples,
    this.subjectName,
  });

  final List<EnglishExample> examples;
  final String? subjectName;

  @override
  State<EnglishExampleSolveScreen> createState() => _EnglishExampleSolveScreenState();
}

class _EnglishExampleSolveScreenState extends State<EnglishExampleSolveScreen> {
  int _index = 0;
  bool _showBack = false;
  bool _ttsPlaying = false;

  EnglishExample get _current => widget.examples[_index];
  bool get _hasNext => _index + 1 < widget.examples.length;
  bool get _hasEn => _current.backEn.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    TtsService.initTts().then((_) => _speakFront());
  }

  @override
  void dispose() {
    TtsService.stop();
    super.dispose();
  }

  Future<void> _speakFront() async {
    if (!mounted) return;
    setState(() => _ttsPlaying = true);
    await TtsService.speak(_current.frontJa, isEnglish: false);
    if (mounted) setState(() => _ttsPlaying = false);
  }

  Future<void> _speakBack() async {
    if (!mounted || !_hasEn) return;
    setState(() => _ttsPlaying = true);
    for (int i = 0; i < TtsService.answerRepeatCount; i++) {
      if (!mounted) break;
      await TtsService.speak(_current.backEn, isEnglish: true);
    }
    if (mounted) setState(() => _ttsPlaying = false);
  }

  Future<void> _onRevealBack() async {
    setState(() => _showBack = true);
    await _speakBack();
  }

  void _onSelfReport(bool correct) {
    TtsService.stop();
    if (_hasNext) {
      setState(() {
        _index += 1;
        _showBack = false;
        _ttsPlaying = false;
      });
      _speakFront();
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.examples.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.subjectName ?? '英語例文')),
        body: const Center(child: Text('出題する例文がありません')),
      );
    }

    final theme = Theme.of(context);
    final ex = _current;
    final exp = ex.explanation?.trim();
    final sup = ex.supplement?.trim();

    return Scaffold(
      appBar: AppBar(
        title: widget.examples.length > 1
            ? Text('${widget.subjectName ?? '英語例文'}（${_index + 1} / ${widget.examples.length}）')
            : Text(widget.subjectName ?? '英語例文'),
        actions: [
          if (_ttsPlaying)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '日本語（表）',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: _ttsPlaying ? null : _speakFront,
                  icon: const Icon(Icons.volume_up),
                  tooltip: '日本語を読み上げ',
                  color: theme.colorScheme.primary,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SelectableText(
                  ex.frontJa.isEmpty ? '（未設定）' : ex.frontJa,
                  style: theme.textTheme.titleMedium,
                ),
              ),
            ),
            const SizedBox(height: 24),
            if (!_showBack) ...[
              if (_hasEn)
                FilledButton.icon(
                  onPressed: _ttsPlaying ? null : _onRevealBack,
                  icon: const Icon(Icons.translate),
                  label: const Text('英語（裏）を見る'),
                )
              else
                Text(
                  '英語の本文がありません',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ] else ...[
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '英語（裏）',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _ttsPlaying ? null : _speakBack,
                    icon: const Icon(Icons.volume_up),
                    tooltip: '英語を読み上げ',
                    color: theme.colorScheme.primary,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Card(
                margin: EdgeInsets.zero,
                color: theme.colorScheme.surfaceContainerHighest,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(
                    ex.backEn,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ),
              if (exp != null && exp.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text(
                  '解説',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: SelectableText(exp, style: theme.textTheme.bodyLarge),
                  ),
                ),
              ],
              if (sup != null && sup.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  '補足',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: SelectableText(sup, style: theme.textTheme.bodyMedium),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              Text(
                '英訳は合っていましたか？',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonal(
                      onPressed: () => _onSelfReport(false),
                      style: FilledButton.styleFrom(
                        backgroundColor: theme.colorScheme.errorContainer,
                        foregroundColor: theme.colorScheme.onErrorContainer,
                      ),
                      child: const Text('違う'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => _onSelfReport(true),
                      child: const Text('合っている'),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
