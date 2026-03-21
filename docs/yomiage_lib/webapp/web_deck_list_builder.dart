// ignore_for_file: deprecated_member_use

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:yomiage/models/deck.dart';
import 'package:yomiage/services/hive_service.dart';
import 'package:yomiage/services/sync_service.dart';
import 'package:yomiage/services/sync/notification_service.dart';
import 'package:yomiage/webapp/web_study_mode_screen.dart';
import 'package:yomiage/webapp/web_deck_cards_screen.dart';
import 'package:yomiage/screens/deck_edit_screen.dart';

class WebDeckListBuilder {
  // デバッグログの制御
  static const bool _enableDebugLogs = false;

  static void _debugPrint(String message) {
    if (_enableDebugLogs) {}
  }

  // デッキリストを構築する
  static Widget buildDeckList(
    BuildContext context,
    SyncStatus syncStatus,
    bool isUserLoggedIn,
    Map<dynamic, bool> deckExpansionState,
    Map<dynamic, List<String>> deckChapters,
    StudyModeFilter studyModeFilter,
    VoidCallback setStateCallback,
  ) {
    if (syncStatus == SyncStatus.error && isUserLoggedIn) {
      return Container(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'データの同期に失敗しました。\nネットワーク接続を確認してください。',
                  style: TextStyle(color: Colors.red),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () async {
                    setStateCallback();
                    await SyncService.forceCloudSync();
                  },
                  child: const Text('再試行'),
                )
              ],
            ),
          ),
        ),
      );
    }

    return ValueListenableBuilder(
      valueListenable: Hive.box<Deck>(HiveService.deckBoxName).listenable(),
      builder: (context, Box<Deck> box, _) {
        // デバッグログ追加
        _debugPrint(
            '🔄 [WebDeckListBuilder.buildDeckList] ValueListenableBuilder rebuilding...');
        final cardBoxForDebug = HiveService.getCardBox();
        _debugPrint('  - CardBox length: ${cardBoxForDebug.length}');

        // 重複チェック
        final allCardIds = cardBoxForDebug.values
            .map((c) => c.firestoreId)
            .where((id) => id != null && id.isNotEmpty)
            .toList();
        final uniqueCardIds = allCardIds.toSet();
        if (allCardIds.length != uniqueCardIds.length) {
          _debugPrint('  ⚠️ 重複 Firestore ID が検出されました！');
          final counts = <String, int>{};
          for (var id in allCardIds) {
            counts[id!] = (counts[id] ?? 0) + 1;
          }
          counts.removeWhere((key, value) => value <= 1);
          _debugPrint('    - 重複ID詳細: $counts');
        }

        final decks = box.values.toList()
          ..sort((a, b) => a.deckName.compareTo(b.deckName));

        final activeDecks = decks.where((deck) => !deck.isArchived).toList();

        for (final deck in activeDecks) {
          if (!deckExpansionState.containsKey(deck.key)) {
            deckExpansionState[deck.key] = false;
          }
        }

        if (activeDecks.isEmpty) {
          return Container(
            color: Theme.of(context).scaffoldBackgroundColor,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Text(
                  '表示するデッキがありません。\nアーカイブされたデッキを表示するには、\nデッキ編集画面で設定を変更してください。\nもしくは、右下の「+」ボタンからカードを追加するか、\nメニューからCSVをインポートしてください。',
                  style: TextStyle(
                      color: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.color
                          ?.withOpacity(0.7),
                      fontSize: 16),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          );
        }

        final now = DateTime.now();
        final todayEnd =
            DateTime(now.year, now.month, now.day, 23, 59, 59, 999);
        final cardBox = HiveService.getCardBox();

        return Container(
          color: Theme.of(context).scaffoldBackgroundColor,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: activeDecks.length,
            itemBuilder: (context, index) {
              final deck = activeDecks[index];
              final deckCards = cardBox.values
                  .where((c) => c.deckName == deck.deckName)
                  .toList();
              return _buildDeckCard(
                context,
                deck,
                deckCards,
                todayEnd,
                deckExpansionState,
                deckChapters,
                studyModeFilter,
                setStateCallback,
              );
            },
          ),
        );
      },
    );
  }

  // デッキカードを構築する
  static Widget _buildDeckCard(
    BuildContext context,
    Deck deck,
    List<dynamic> deckCards,
    DateTime todayEnd,
    Map<dynamic, bool> deckExpansionState,
    Map<dynamic, List<String>> deckChapters,
    StudyModeFilter studyModeFilter,
    VoidCallback setStateCallback,
  ) {
    // 本日出題予定のカード数は、常にフラグに基づいて計算
    final dueCount = deckCards
        .where((c) =>
            c.nextReview == null ||
            c.nextReview!.isBefore(todayEnd) ||
            c.nextReview!.isAtSameMomentAs(todayEnd))
        .length;

    final notDueCount = deckCards.length - dueCount; // 修正：常に全カード数 - 本日分

    final List<String> chapters = deckChapters[deck.key] ?? [];
    final bool hasUncategorized = deckCards.any((card) => card.chapter.isEmpty);
    final List<String> displayChapters = [...chapters];
    if (hasUncategorized) {
      displayChapters.add('未分類');
    }

    final bool canExpand = chapters.isNotEmpty;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 0, vertical: 4.0),
      color: Theme.of(context).cardColor,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            key: PageStorageKey(deck.key),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => WebDeckCardsScreen(
                    deck: deck,
                    chapter: null,
                  ),
                ),
              );
            },
            leading: Icon(Icons.folder_copy_outlined,
                color: Theme.of(context).textTheme.bodyLarge?.color),
            title: Text(deck.deckName,
                overflow: TextOverflow.ellipsis, // はみ出した場合は省略記号
                style: TextStyle(
                    fontSize: 18,
                    color: Theme.of(context).textTheme.bodyLarge?.color)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 展開ボタンをカウントの左側へ移動
                IconButton(
                  icon: Icon(
                    (deckExpansionState[deck.key] ?? false)
                        ? Icons.expand_less
                        : Icons.expand_more,
                    color: canExpand
                        ? Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.color
                            ?.withOpacity(0.7)
                        : Colors.transparent,
                  ),
                  tooltip: canExpand
                      ? ((deckExpansionState[deck.key] ?? false)
                          ? 'チャプターを閉じる'
                          : 'チャプターを開く')
                      : null,
                  onPressed: canExpand
                      ? () {
                          // 展開状態をトグルしてから再描画
                          deckExpansionState[deck.key] =
                              !(deckExpansionState[deck.key] ?? false);
                          setStateCallback();
                        }
                      : null,
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 60,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text('$dueCount',
                          style:
                              const TextStyle(color: Colors.red, fontSize: 16)),
                      const SizedBox(width: 4),
                      Text('$notDueCount',
                          style: const TextStyle(
                              color: Colors.green, fontSize: 16)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: Icon(Icons.edit,
                      color: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.color
                          ?.withOpacity(0.7)),
                  tooltip: 'デッキ全体のカード一覧・編集',
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) =>
                            WebDeckCardsScreen(deck: deck, chapter: null),
                      ),
                    );
                  },
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: Icon(Icons.play_arrow,
                      color: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.color
                          ?.withOpacity(0.7)),
                  tooltip: '学習開始',
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => WebStudySessionPage(
                          deckKey: deck.key,
                          filter: studyModeFilter,
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: Icon(Icons.settings,
                      color: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.color
                          ?.withOpacity(0.7)),
                  tooltip: 'デッキ設定',
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => DeckEditScreen(deckKey: deck.key),
                      ),
                    );
                  },
                ),
                const SizedBox(width: 8),
              ],
            ),
          ),
          if ((deckExpansionState[deck.key] ?? false) &&
              displayChapters.isNotEmpty)
            Column(
              children: displayChapters.map((chapterName) {
                final chapterCards = deckCards.where((c) {
                  final chap =
                      c.chapter.trim().isEmpty ? '未分類' : c.chapter.trim();
                  return chap == chapterName;
                }).toList();

                final dueCountChap = studyModeFilter == StudyModeFilter.allCards
                    ? chapterCards.length
                    : chapterCards
                        .where((c) =>
                            c.nextReview == null ||
                            c.nextReview!.isBefore(todayEnd) ||
                            c.nextReview!.isAtSameMomentAs(todayEnd))
                        .length;
                final notDueCountChap =
                    chapterCards.length - dueCountChap; // 修正

                return Padding(
                  padding: const EdgeInsets.only(left: 32.0),
                  child: ListTile(
                    leading: Icon(Icons.book,
                        color: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.color
                            ?.withOpacity(0.7),
                        size: 20),
                    title: Text(chapterName,
                        style: TextStyle(
                            fontSize: 16,
                            color: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.color
                                ?.withOpacity(0.7))),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 60,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              Text('$dueCountChap',
                                  style: const TextStyle(
                                      color: Colors.red, fontSize: 14)),
                              const SizedBox(width: 4),
                              Text('$notDueCountChap',
                                  style: const TextStyle(
                                      color: Colors.green, fontSize: 14)),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        const IconButton(
                          icon: Icon(Icons.edit),
                          onPressed: null,
                        ),
                        IconButton(
                          icon: Icon(Icons.play_arrow,
                              color: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.color
                                  ?.withOpacity(0.5)),
                          tooltip: 'チャプターを学習',
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => WebStudySessionPage(
                                  deckKey: deck.key,
                                  filter: studyModeFilter,
                                ),
                              ),
                            );
                          },
                        ),
                        const Opacity(
                          opacity: 0,
                          child: IconButton(
                            icon: Icon(Icons.settings),
                            onPressed: null,
                          ),
                        ),
                        const Opacity(
                          opacity: 0,
                          child: IconButton(
                            icon: Icon(Icons.expand_more),
                            onPressed: null,
                          ),
                        ),
                      ],
                    ),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => WebDeckCardsScreen(
                            deck: deck,
                            chapter: chapterName == '未分類' ? '' : chapterName,
                          ),
                        ),
                      );
                    },
                  ),
                );
              }).toList(),
            ),
        ],
      ),
    );
  }
}
