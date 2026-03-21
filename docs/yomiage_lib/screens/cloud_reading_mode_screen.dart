import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:yomiage/models/deck.dart';
import 'package:yomiage/models/flashcard.dart';
import 'package:yomiage/screens/card_edit_screen.dart';
import 'package:yomiage/screens/cloud_review_mode_screen.dart';
import 'package:yomiage/screens/reading_mode_section.dart';
import 'package:yomiage/services/hive_service.dart';
import 'package:yomiage/services/tts_service.dart';
import 'package:yomiage/themes/app_theme.dart';
import 'study_mode_filter.dart';

class CloudReadingModeScreen extends StatefulWidget {
  const CloudReadingModeScreen({super.key});

  @override
  State<CloudReadingModeScreen> createState() => _CloudReadingModeScreenState();
}

class _CloudReadingModeScreenState extends State<CloudReadingModeScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final Map<dynamic, bool> _deckExpansionState = {};
  final Map<dynamic, List<String>> _deckChapters = {};
  StudyModeFilter _studyModeFilter = StudyModeFilter.dueToday;
  bool _isResolvingDiscrepancy = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadDeckChapters();
  }

  void _loadSettings() {
    final settingsBox = HiveService.getSettingsBox();
    final filterString = settingsBox.get('studyModeFilter');
    if (filterString == 'allCards') {
      _studyModeFilter = StudyModeFilter.allCards;
    } else {
      _studyModeFilter = StudyModeFilter.dueToday;
    }
  }

  void _saveSettings() {
    final settingsBox = HiveService.getSettingsBox();
    settingsBox.put(
      'studyModeFilter',
      _studyModeFilter == StudyModeFilter.allCards ? 'allCards' : 'dueToday',
    );
  }

  Future<void> _loadDeckChapters() async {
    final deckBox = HiveService.getDeckBox();
    final cardBox = HiveService.getCardBox();
    final decks = deckBox.values.where((d) => !d.isDeleted).toList();
    final Map<dynamic, List<String>> chaptersMap = {};

    for (final deck in decks) {
      final cardsInDeck = cardBox.values
          .where((card) => !card.isDeleted && card.deckName == deck.deckName)
          .toList();

      final hasUncategorized =
          cardsInDeck.any((FlashCard card) => card.chapter.isEmpty);
      final categorizedCards = cardsInDeck
          .where((FlashCard card) => card.chapter.isNotEmpty)
          .toList();

      final chapters = categorizedCards
          .map((card) => card.chapter)
          .toSet()
          .toList()
        ..sort();

      if (hasUncategorized) {
        chapters.add('未分類');
      }

      chaptersMap[deck.key] = chapters;
    }

    if (mounted) {
      setState(() {
        _deckChapters
          ..clear()
          ..addAll(chaptersMap);
      });
    }
  }

  Future<void> _refreshDatabaseState() async {
    try {
      await HiveService.refreshDatabase();
      await _loadDeckChapters();
      if (mounted) {
        setState(() {});
      }
      } catch (e) {
      debugPrint('クラウド読み上げ: データベース更新中にエラー: $e');
    }
  }

  void _toggleDeckExpansion(dynamic deckKey) {
    setState(() {
      _deckExpansionState[deckKey] = !(_deckExpansionState[deckKey] ?? false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        title: const Text('クラウド読み上げ（β）'),
        actions: [
          if (!kIsWeb)
            IconButton(
              icon: const Icon(Icons.tune),
              tooltip: '出題方法',
              onPressed: () {
                _scaffoldKey.currentState?.openDrawer();
              },
            ),
        ],
      ),
      drawer: _buildStudyModeDrawer(context),
      body: RefreshIndicator(
        onRefresh: _refreshDatabaseState,
        child: ListView(
          children: [
            ReadingModeSection(
              deckExpansionState: _deckExpansionState,
              deckChapters: _deckChapters,
              studyModeFilter: _studyModeFilter,
              isResolvingDiscrepancy: _isResolvingDiscrepancy,
              onDeckExpansionToggle: _toggleDeckExpansion,
              reviewScreenBuilder: (Deck deck,
                      {String? chapterName, StudyModeFilter? filter}) =>
                  CloudReviewModeScreen(
                deck: deck,
                chapterName: chapterName,
                filter: filter,
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const CardEditScreen()),
          );
        },
        backgroundColor: Theme.of(context).colorScheme.primary,
        tooltip: 'カード作成',
        child: Icon(
          Icons.add,
          color: Theme.of(context).colorScheme.onPrimary,
        ),
      ),
    );
  }

  Widget _buildStudyModeDrawer(BuildContext context) {
    if (kIsWeb) return const SizedBox.shrink();

    return FractionallySizedBox(
      widthFactor: 0.75,
      child: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            DrawerHeader(
              decoration: BoxDecoration(color: Theme.of(context).primaryColor),
              child: Align(
                alignment: Alignment.bottomLeft,
                child: Text(
                  '出題モード',
                  style: TextStyle(
                    color: CustomColors.getTextColor(Theme.of(context)),
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            _buildDrawerToggle(
              title: '全問出題',
              subtitle: '既に覚えた問題も含めて、全問を出題します。',
              value: _studyModeFilter == StudyModeFilter.allCards,
              onChanged: (value) {
                setState(() {
                  _studyModeFilter =
                      value ? StudyModeFilter.allCards : StudyModeFilter.dueToday;
                  _saveSettings();
                });
              },
            ),
            _buildDrawerToggle(
              title: 'ランダム出題',
              subtitle: 'ランダムに出題します。',
              value: TtsService.randomPlayback,
              onChanged: (v) {
                setState(() {
                  TtsService.setRandomPlayback(v);
                });
              },
            ),
            _buildDrawerToggle(
              title: '逆出題',
              subtitle: '回答→質問の順番で出題します。',
              value: TtsService.reversePlayback,
              onChanged: (v) {
                setState(() {
                  TtsService.setReversePlayback(v);
                });
              },
            ),
            _buildDrawerToggle(
              title: '集中暗記',
              subtitle: '連続正解回数が0～1の問題のみを出題します。',
              value: TtsService.focusedMemorization,
              onChanged: (v) {
                setState(() {
                  TtsService.setFocusedMemorization(v);
                });
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDrawerToggle({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile.adaptive(
      title: Text(title),
      subtitle: Text(subtitle),
      value: value,
      onChanged: onChanged,
    );
  }
}
