import 'dart:async';
import 'dart:convert';
import 'dart:io' show File;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/question.dart';
import '../utils/platform_utils.dart' show dataFolderKey;

/// 問題を暗記カード風に確認する画面
class QuestionFlashcardScreen extends StatefulWidget {
  const QuestionFlashcardScreen({super.key, this.openDrawer});

  /// スマホでドロワーを開くコールバック（指定時は AppBar にメニューアイコンを表示）
  final VoidCallback? openDrawer;

  @override
  State<QuestionFlashcardScreen> createState() => _QuestionFlashcardScreenState();
}

class _QuestionFlashcardScreenState extends State<QuestionFlashcardScreen> {
  List<Question> _questions = [];
  String? _error;
  String? _loadedFolderPath;
  bool _isLoading = true;
  int _currentIndex = 0;
  bool _showAnswer = false;
  StreamSubscription? _fileWatchSubscription;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    _fileWatchSubscription?.cancel();
    super.dispose();
  }

  Future<void> _initialize() async {
    final prefs = await SharedPreferences.getInstance();
    final savedPath = prefs.getString(dataFolderKey);
    if (savedPath != null && savedPath.isNotEmpty) {
      await _loadFromFolder(savedPath);
    } else {
      await _loadFromAssets();
    }
    setState(() => _isLoading = false);
  }

  List<Question> _parseJson(String jsonString) {
    final list = jsonDecode(jsonString) as List<dynamic>;
    final items = list
        .map((e) => Question.fromJson(e as Map<String, dynamic>))
        .toList();
    items.sort((a, b) => (a.order ?? 0).compareTo(b.order ?? 0));
    return items;
  }

  Future<void> _loadFromAssets() async {
    try {
      final jsonString =
          await rootBundle.loadString('assets/data/questions.json');
      setState(() {
        _questions = _parseJson(jsonString);
        _error = null;
        _loadedFolderPath = null;
        _currentIndex = 0;
        _showAnswer = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _questions = [];
      });
    }
  }

  Future<void> _loadFromFolder(String folderPath) async {
    _fileWatchSubscription?.cancel();
    try {
      final file = File(p.join(folderPath, 'questions.json'));
      if (!await file.exists()) {
        setState(() {
          _error = 'questions.json が見つかりません: $folderPath';
          _questions = [];
        });
        return;
      }
      final jsonString = await file.readAsString();
      setState(() {
        _questions = _parseJson(jsonString);
        _loadedFolderPath = folderPath;
        _error = null;
        _currentIndex = 0;
        _showAnswer = false;
      });

      _fileWatchSubscription = file.watch().listen((event) {
        if (mounted) {
          _loadFromFolder(folderPath);
        }
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _questions = [];
      });
    }
  }

  void _flipCard() {
    setState(() => _showAnswer = !_showAnswer);
  }

  void _nextCard() {
    if (_currentIndex < _questions.length - 1) {
      setState(() {
        _currentIndex++;
        _showAnswer = false;
      });
    }
  }

  void _prevCard() {
    if (_currentIndex > 0) {
      setState(() {
        _currentIndex--;
        _showAnswer = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('問題確認'),
          leading: widget.openDrawer != null
              ? IconButton(icon: const Icon(Icons.menu), onPressed: widget.openDrawer, tooltip: 'メニュー')
              : null,
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('問題確認'),
          leading: widget.openDrawer != null
              ? IconButton(icon: const Icon(Icons.menu), onPressed: widget.openDrawer, tooltip: 'メニュー')
              : null,
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.error_outline, size: 48, color: Theme.of(context).colorScheme.error),
                const SizedBox(height: 16),
                Text('読み込みエラー: $_error', textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      );
    }

    if (_questions.isEmpty) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('問題確認'),
          leading: widget.openDrawer != null
              ? IconButton(icon: const Icon(Icons.menu), onPressed: widget.openDrawer, tooltip: 'メニュー')
              : null,
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.quiz, size: 64, color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.6)),
              const SizedBox(height: 16),
              Text(
                '問題がありません',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'questions.json に問題を追加してください',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final question = _questions[_currentIndex];
    final hasPrev = _currentIndex > 0;
    final hasNext = _currentIndex < _questions.length - 1;

    return Scaffold(
      appBar: AppBar(
        title: Text('問題確認 (${_currentIndex + 1} / ${_questions.length})'),
        leading: widget.openDrawer != null
            ? IconButton(icon: const Icon(Icons.menu), onPressed: widget.openDrawer, tooltip: 'メニュー')
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.of(context).pop(),
                tooltip: 'ホームに戻る',
              ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: GestureDetector(
                onTap: _flipCard,
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    transitionBuilder: (child, animation) {
                      return FadeTransition(
                        opacity: animation,
                        child: ScaleTransition(
                          scale: animation,
                          child: child,
                        ),
                      );
                    },
                    child: Container(
                      key: ValueKey('$_currentIndex-$_showAnswer'),
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: Theme.of(context).colorScheme.shadow.withOpacity(0.15),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: Padding(
                          padding: const EdgeInsets.all(24.0),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    'タップして答えを表示',
                                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                      color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.8),
                                    ),
                                  ),
                                  ...question.tags.map((t) => Padding(
                                    padding: const EdgeInsets.only(left: 8.0),
                                    child: Chip(
                                      label: Text(t, style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                        color: Theme.of(context).colorScheme.onSurface,
                                      )),
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                      visualDensity: VisualDensity.compact,
                                      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                                    ),
                                  )),
                                ],
                              ),
                              const SizedBox(height: 16),
                              if (!_showAnswer) ...[
                                Text(
                                  question.question,
                                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                    height: 1.5,
                                    fontWeight: FontWeight.w500,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ] else ...[
                                Text(
                                  question.answer,
                                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                    height: 1.5,
                                    fontWeight: FontWeight.w500,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                                if (question.explanation != null &&
                                    question.explanation!.isNotEmpty) ...[
                                  const SizedBox(height: 20),
                                  const Divider(),
                                  const SizedBox(height: 12),
                                  Text(
                                    question.explanation!,
                                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                                    ),
                                    textAlign: TextAlign.start,
                                  ),
                                ],
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton.filled(
                    onPressed: hasPrev ? _prevCard : null,
                    icon: const Icon(Icons.chevron_left),
                    tooltip: '前の問題',
                  ),
                  FilledButton.icon(
                    onPressed: _flipCard,
                    icon: Icon(_showAnswer ? Icons.refresh : Icons.visibility),
                    label: Text(_showAnswer ? '問題に戻る' : '答えを見る'),
                  ),
                  IconButton.filled(
                    onPressed: hasNext ? _nextCard : null,
                    icon: const Icon(Icons.chevron_right),
                    tooltip: '次の問題',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
