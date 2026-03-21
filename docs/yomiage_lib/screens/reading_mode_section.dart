import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:yomiage/models/deck.dart';
import 'package:yomiage/screens/review_mode_screen.dart';
import 'package:yomiage/screens/deck_screen.dart';
import 'package:yomiage/services/hive_service.dart';
import 'package:yomiage/screens/study_mode_filter.dart';

typedef ReviewScreenBuilder = Widget Function(
  Deck deck, {
  String? chapterName,
  StudyModeFilter? filter,
});

class ReadingModeSection extends StatefulWidget {
  final Map<dynamic, bool> deckExpansionState;
  final Map<dynamic, List<String>> deckChapters;
  final StudyModeFilter studyModeFilter;
  final bool isResolvingDiscrepancy;
  final Function(dynamic) onDeckExpansionToggle;
  final ReviewScreenBuilder reviewScreenBuilder;

  const ReadingModeSection({
    Key? key,
    required this.deckExpansionState,
    required this.deckChapters,
    required this.studyModeFilter,
    required this.isResolvingDiscrepancy,
    required this.onDeckExpansionToggle,
    ReviewScreenBuilder? reviewScreenBuilder,
  })  : reviewScreenBuilder =
            reviewScreenBuilder ?? _defaultReviewScreenBuilder,
        super(key: key);

  @override
  State<ReadingModeSection> createState() => _ReadingModeSectionState();

  static Widget _defaultReviewScreenBuilder(
    Deck deck, {
    String? chapterName,
    StudyModeFilter? filter,
  }) {
    return ReviewModeScreen(
      deck: deck,
      chapterName: chapterName,
      filter: filter,
    );
  }
}

class _ReadingModeSectionState extends State<ReadingModeSection> {
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: Hive.box<Deck>(HiveService.deckBoxName).listenable(),
      builder: (context, Box<Deck> box, _) {
        final decks = box.values.where((d) => !d.isDeleted).toList()
          ..sort((a, b) => a.deckName.compareTo(b.deckName));

        // アーカイブ済みでなく、かつデッキ名が「後で調べる」でないものを抽出
        final activeDecks = decks
            .where((deck) => !deck.isArchived && deck.deckName != "後で調べる")
            .toList();

        if (activeDecks.isEmpty && !widget.isResolvingDiscrepancy) {
          return _buildEmptyState(context);
        }

        final now = DateTime.now();
        final todayEnd =
            DateTime(now.year, now.month, now.day, 23, 59, 59, 999);

        final cardBox = HiveService.getCardBox();

        return ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: activeDecks.length,
          itemBuilder: (context, index) {
            final deck = activeDecks[index];
            final chapters = widget.deckChapters[deck.key] ?? [];
            // チャプターが2つ以上ある場合のみ展開可能にする
            // （未分類と1つのチャプターの場合は展開しない）
            final hasMultipleChapters = chapters.length >= 2;
            final isExpanded = widget.deckExpansionState[deck.key] ?? false;

            final deckCards = cardBox.values
                .where((card) => !card.isDeleted && card.deckName == deck.deckName)
                .toList();
            final dueCount = deckCards
                .where((c) =>
                    c.nextReview == null ||
                    c.nextReview!.isBefore(todayEnd) ||
                    c.nextReview!.isAtSameMomentAs(todayEnd))
                .length;
            final notDueCount = deckCards.length - dueCount;

            if (dueCount == 0) {
              return const SizedBox.shrink();
            }

            return _buildDeckTile(
              context,
              deck,
              chapters,
              hasMultipleChapters,
              isExpanded,
              dueCount,
              notDueCount,
              deckCards,
              todayEnd,
            );
          },
        );
      },
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '表示するデッキがありません。',
              style: TextStyle(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.7),
                  fontSize: 16),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              icon: const Icon(Icons.archive_outlined),
              label: const Text('アーカイブ済みデッキの管理'),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const DeckScreen()),
                );
              },
            ),
            const SizedBox(height: 8),
            Text(
              'または、右下の「+」ボタンからカードを追加するか、\nメニューからCSVをインポートしてください。',
              style: TextStyle(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.7),
                  fontSize: 14),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeckTile(
    BuildContext context,
    Deck deck,
    List<String> chapters,
    bool hasMultipleChapters,
    bool isExpanded,
    int dueCount,
    int notDueCount,
    List<dynamic> deckCards,
    DateTime todayEnd,
  ) {
    return Column(
      children: [
        ListTile(
          contentPadding: const EdgeInsets.only(left: 16.0, right: 8.0),
          leading:
              Icon(Icons.style, color: Theme.of(context).colorScheme.onSurface),
          title: Text(
            deck.deckName,
            style: TextStyle(
              fontSize: 20,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
          trailing: InkWell(
            onTap: hasMultipleChapters
                ? () {
                    widget.onDeckExpansionToggle(deck.key);
                  }
                : null,
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('$dueCount',
                      style: const TextStyle(color: Colors.red, fontSize: 16)),
                  const SizedBox(width: 4),
                  Text('$notDueCount',
                      style:
                          const TextStyle(color: Colors.green, fontSize: 16)),
                  if (hasMultipleChapters)
                    Padding(
                      padding: const EdgeInsets.only(left: 8.0),
                      child: Icon(
                        isExpanded ? Icons.expand_less : Icons.expand_more,
                        color: Theme.of(context).colorScheme.onSurface,
                        size: 20,
                      ),
                    )
                  else
                    const Padding(
                      padding: EdgeInsets.only(left: 8.0),
                      child: SizedBox(width: 20),
                    ),
                ],
              ),
            ),
          ),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => widget.reviewScreenBuilder(
                  deck,
                  filter: widget.studyModeFilter,
                ),
              ),
            );
          },
        ),
        if (hasMultipleChapters && isExpanded)
          _buildChapterList(
            context,
            deck,
            chapters,
            deckCards,
            todayEnd,
          ),
      ],
    );
  }

  Widget _buildChapterList(
    BuildContext context,
    Deck deck,
    List<String> chapters,
    List<dynamic> deckCards,
    DateTime todayEnd,
  ) {
    return Padding(
      padding: const EdgeInsets.only(left: 48.0, right: 16.0),
      child: Column(
        children: [
          ListTile(
            dense: true,
            visualDensity: const VisualDensity(vertical: -2),
            leading: Icon(Icons.play_circle_outline,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.6),
                size: 20),
            title: Text('すべてのチャプター (${deckCards.length}枚)',
                style: TextStyle(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.6),
                    fontSize: 14,
                    fontStyle: FontStyle.italic)),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => widget.reviewScreenBuilder(
                    deck,
                    filter: widget.studyModeFilter,
                  ),
                ),
              );
            },
          ),
          Divider(
              height: 1,
              color: Theme.of(context).dividerColor,
              indent: 16,
              endIndent: 0),
          ...chapters.map((chapter) {
            final chapterCards = deckCards.where((c) {
              if (chapter == '未分類') {
                return c.chapter.isEmpty;
              }
              return c.chapter == chapter;
            }).toList();
            final chapterDueCount = chapterCards
                .where((c) =>
                    c.nextReview == null ||
                    c.nextReview!.isBefore(todayEnd) ||
                    c.nextReview!.isAtSameMomentAs(todayEnd))
                .length;
            final chapterNotDueCount = chapterCards.length - chapterDueCount;
            return ListTile(
              dense: true,
              visualDensity: const VisualDensity(vertical: -2),
              leading: Icon(Icons.label_outline,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.7),
                  size: 20),
              title: Text(chapter,
                  style: TextStyle(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.7),
                      fontSize: 14)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('$chapterDueCount',
                      style: const TextStyle(color: Colors.red, fontSize: 12)),
                  const SizedBox(width: 4),
                  Text('$chapterNotDueCount',
                      style:
                          const TextStyle(color: Colors.green, fontSize: 12)),
                ],
              ),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => widget.reviewScreenBuilder(
                      deck,
                      chapterName: chapter == '未分類' ? '' : chapter,
                      filter: widget.studyModeFilter,
                    ),
                  ),
                );
              },
            );
          }).toList(),
        ],
      ),
    );
  }
}
