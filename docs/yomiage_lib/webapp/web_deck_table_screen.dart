// ignore_for_file: library_private_types_in_public_api, avoid_print, deprecated_member_use

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:yomiage/models/deck.dart';
import 'package:yomiage/services/hive_service.dart';
import 'package:yomiage/webapp/web_deck_cards_screen.dart';
import 'package:yomiage/webapp/web_study_mode_screen.dart';
import 'package:yomiage/services/firebase_service.dart';
import 'package:yomiage/screens/deck_edit_screen.dart';

class WebDeckTableScreen extends StatefulWidget {
  const WebDeckTableScreen({super.key});

  @override
  _WebDeckTableScreenState createState() => _WebDeckTableScreenState();
}

class _WebDeckTableScreenState extends State<WebDeckTableScreen> {
  List<String> columns = [
    'デッキ名',
    'アーカイブ',
    'カード数',
    '今日の復習',
    '学習',
    'カード一覧',
    'デッキ設定'
  ];

  @override
  Widget build(BuildContext context) {
    print("[WebDeckTableScreen] Build method called");
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: SafeArea(
            child: Scaffold(
              appBar: AppBar(
                title: const Text('デッキ一覧'),
              ),
              body: ValueListenableBuilder(
                valueListenable:
                    Hive.box<Deck>(HiveService.deckBoxName).listenable(),
                builder: (context, Box<Deck> box, _) {
                  try {
                    final decks = box.values.toList();
                    print("  - Hive decks count: ${decks.length}");
                    decks.sort((a, b) => a.deckName.compareTo(b.deckName));
                    print("  - Decks sorted.");

                    // ★★★ カード数と復習数を事前に計算 ★★★
                    print("  - Pre-calculating card counts...");
                    final cardBox = HiveService.getCardBox();
                    final allCards = cardBox.values.toList(); // 全カードを一度だけ取得
                    final cardCounts = <dynamic, int>{}; // deck.key をキーとするMap
                    final dueCounts = <dynamic, int>{}; // deck.key をキーとするMap
                    final now = DateTime.now();
                    final todayEnd =
                        DateTime(now.year, now.month, now.day, 23, 59, 59);

                    for (final deck in decks) {
                      try {
                        final deckCards = allCards
                            .where((c) => c.deckName == deck.deckName)
                            .toList();
                        cardCounts[deck.key] = deckCards.length;
                        dueCounts[deck.key] = deckCards
                            .where((c) =>
                                c.nextReview == null ||
                                c.nextReview!.isBefore(todayEnd) ||
                                c.nextReview!.isAtSameMomentAs(todayEnd))
                            .length;
                      } catch (e) {
                        print(
                            "      - Error pre-calculating counts for ${deck.deckName}: $e");
                        cardCounts[deck.key] = 0; // エラー時は0に
                        dueCounts[deck.key] = 0; // エラー時は0に
                      }
                    }
                    print("  - Pre-calculation complete.");
                    // ★★★ ここまで追加 ★★★

                    if (decks.isEmpty) {
                      print("  - No decks found in Hive.");
                      return Padding(
                        padding: const EdgeInsets.only(top: 24.0),
                        child: Text(
                          'デッキがありません。新しいデッキを作成するか、CSVをインポートしてください。',
                          style: TextStyle(
                              color: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.color
                                  ?.withOpacity(0.7),
                              fontSize: 16),
                          textAlign: TextAlign.center,
                        ),
                      );
                    }

                    print("  - Building DataTable for ${decks.length} decks.");
                    return Align(
                      alignment: Alignment.topCenter,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 16.0),
                        child: SingleChildScrollView(
                          scrollDirection: Axis.vertical,
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              return SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                      minWidth: constraints.maxWidth),
                                  child: DataTable(
                                    headingRowColor: WidgetStateProperty.all(
                                        Theme.of(context).cardColor),
                                    dataRowColor: WidgetStateProperty.all(
                                        Theme.of(context).cardColor),
                                    columnSpacing: 16,
                                    columns: [
                                      DataColumn(
                                        label: Text('デッキ名',
                                            style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                                color: Theme.of(context)
                                                    .textTheme
                                                    .headlineSmall
                                                    ?.color)),
                                      ),
                                      DataColumn(
                                        label: Text('アーカイブ',
                                            style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                                color: Theme.of(context)
                                                    .textTheme
                                                    .headlineSmall
                                                    ?.color)),
                                      ),
                                      DataColumn(
                                        label: Text('カード数',
                                            style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                                color: Theme.of(context)
                                                    .textTheme
                                                    .headlineSmall
                                                    ?.color)),
                                      ),
                                      DataColumn(
                                        label: Text('今日の復習',
                                            style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                                color: Theme.of(context)
                                                    .textTheme
                                                    .headlineSmall
                                                    ?.color)),
                                      ),
                                      DataColumn(
                                        label: Text('学習',
                                            style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                                color: Theme.of(context)
                                                    .textTheme
                                                    .headlineSmall
                                                    ?.color)),
                                      ),
                                      DataColumn(
                                        label: Text('カード一覧',
                                            style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                                color: Theme.of(context)
                                                    .textTheme
                                                    .headlineSmall
                                                    ?.color)),
                                      ),
                                      DataColumn(
                                        label: Text('デッキ設定',
                                            style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                                color: Theme.of(context)
                                                    .textTheme
                                                    .headlineSmall
                                                    ?.color)),
                                      ),
                                    ],
                                    rows: decks.map((deck) {
                                      print(
                                          "    - Processing deck: ${deck.deckName} (Hive: ${deck.key}, FB: ${deck.id})");
                                      // int cardCount = 0; // 事前計算したので削除
                                      // int dueCount = 0; // 事前計算したので削除
                                      // try { // 事前計算したので削除
                                      //   final cardBox = HiveService.getCardBox(); // 事前計算したので削除
                                      //   final deckCards = cardBox.values // 事前計算したので削除
                                      //       .where((c) => c.deckName == deck.deckName) // 事前計算したので削除
                                      //       .toList(); // 事前計算したので削除
                                      //   cardCount = deckCards.length; // 事前計算したので削除

                                      //   final now = DateTime.now(); // 事前計算したので削除
                                      //   final todayEnd = DateTime(now.year, now.month, now.day, 23, 59, 59); // 事前計算したので削除

                                      //   dueCount = deckCards // 事前計算したので削除
                                      //       .where((c) => // 事前計算したので削除
                                      //           c.nextReview == null || // 事前計算したので削除
                                      //           c.nextReview!.isBefore(todayEnd) || // 事前計算したので削除
                                      //           c.nextReview!.isAtSameMomentAs(todayEnd)) // 事前計算したので削除
                                      //       .length; // 事前計算したので削除
                                      //   print("      - Card count: $cardCount, Due count: $dueCount"); // 事前計算したので削除
                                      // } catch (e) { // 事前計算したので削除
                                      //   print("      - Error getting card counts for ${deck.deckName}: $e"); // 事前計算したので削除
                                      // } // 事前計算したので削除

                                      // ★★★ 事前計算した値を使用 ★★★
                                      final cardCount =
                                          cardCounts[deck.key] ?? 0;
                                      final dueCount = dueCounts[deck.key] ?? 0;
                                      print(
                                          "      - Using pre-calculated counts - Card: $cardCount, Due: $dueCount");
                                      // ★★★ ここまで修正 ★★★

                                      return DataRow(
                                        cells: [
                                          DataCell(
                                            Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              children: [
                                                Text(
                                                  deck.deckName,
                                                  style: TextStyle(
                                                      color: Theme.of(context)
                                                          .textTheme
                                                          .bodyLarge
                                                          ?.color),
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ],
                                            ),
                                          ),
                                          DataCell(
                                            Container(
                                              width: 60,
                                              alignment: Alignment.center,
                                              child: Switch(
                                                value: deck.isArchived,
                                                onChanged: (bool value) {
                                                  _toggleArchiveStatus(
                                                      deck, value);
                                                },
                                                activeColor: Theme.of(context)
                                                    .colorScheme
                                                    .primary,
                                                inactiveThumbColor:
                                                    Theme.of(context)
                                                        .colorScheme
                                                        .outline,
                                                activeTrackColor:
                                                    Theme.of(context)
                                                        .colorScheme
                                                        .primaryContainer,
                                                inactiveTrackColor: Theme.of(
                                                        context)
                                                    .colorScheme
                                                    .surfaceContainerHighest,
                                                materialTapTargetSize:
                                                    MaterialTapTargetSize
                                                        .shrinkWrap,
                                                trackOutlineColor:
                                                    WidgetStateProperty.all(
                                                        Colors.transparent),
                                              ),
                                            ),
                                          ),
                                          DataCell(
                                            Container(
                                              width: 60,
                                              alignment: Alignment.center,
                                              child: Text(
                                                '$cardCount',
                                                style: TextStyle(
                                                    color: Theme.of(context)
                                                        .textTheme
                                                        .bodyMedium
                                                        ?.color),
                                              ),
                                            ),
                                          ),
                                          DataCell(
                                            Container(
                                              width: 60,
                                              alignment: Alignment.center,
                                              child: Text(
                                                '$dueCount',
                                                style: TextStyle(
                                                    color: Theme.of(context)
                                                        .textTheme
                                                        .bodyMedium
                                                        ?.color),
                                              ),
                                            ),
                                          ),
                                          DataCell(
                                            Container(
                                              width: 50,
                                              alignment: Alignment.center,
                                              child: IconButton(
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
                                                      builder: (context) =>
                                                          WebStudySessionPage(
                                                              deckKey: deck.key,
                                                              chapter: null,
                                                              filter:
                                                                  StudyModeFilter
                                                                      .dueToday),
                                                    ),
                                                  );
                                                },
                                              ),
                                            ),
                                          ),
                                          DataCell(
                                            Container(
                                              width: 50,
                                              alignment: Alignment.center,
                                              child: IconButton(
                                                icon: Icon(Icons.list,
                                                    color: Theme.of(context)
                                                        .textTheme
                                                        .bodyMedium
                                                        ?.color
                                                        ?.withOpacity(0.7)),
                                                tooltip: 'カード一覧',
                                                onPressed: () {
                                                  Navigator.push(
                                                    context,
                                                    MaterialPageRoute(
                                                      builder: (context) =>
                                                          WebDeckCardsScreen(
                                                              deck: deck),
                                                    ),
                                                  );
                                                },
                                              ),
                                            ),
                                          ),
                                          DataCell(
                                            Container(
                                              width: 50,
                                              alignment: Alignment.center,
                                              child: IconButton(
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
                                                      builder: (context) =>
                                                          DeckEditScreen(
                                                              deckKey:
                                                                  deck.key),
                                                    ),
                                                  );
                                                },
                                              ),
                                            ),
                                          ),
                                        ],
                                      );
                                    }).toList(),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    );
                  } catch (e, stacktrace) {
                    print(
                        "[WebDeckTableScreen] Error in ValueListenableBuilder: $e");
                    print(stacktrace);
                    return Center(
                        child: Text("エラーが発生しました: $e",
                            style: const TextStyle(color: Colors.red)));
                  }
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _toggleArchiveStatus(Deck deck, bool isArchived) async {
    try {
      deck.isArchived = isArchived;
      print(
          '[WebDeckTableScreen] Saving archive status: ${deck.isArchived} for deck key: ${deck.key}');
      await deck.save();
      print('[WebDeckTableScreen] Archive status saved to Hive.');

      if (FirebaseService.getUserId() != null) {
        FirebaseService.saveDeck(deck).then((_) {
          print('[WebDeckTableScreen] Archive status synced to Firebase.');
        }).catchError((e) {
          print(
              '[WebDeckTableScreen] Error syncing archive status to Firebase: $e');
        });
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(isArchived
                ? 'デッキ「${deck.deckName}」をアーカイブしました'
                : 'デッキ「${deck.deckName}」をアーカイブから戻しました'),
            duration: const Duration(seconds: 2),
            backgroundColor: Colors.green,
          ),
        );
        setState(() {});
      }
    } catch (e) {
      print('[WebDeckTableScreen] Error saving archive status: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('アーカイブ状態の保存に失敗: $e'),
            backgroundColor: Colors.red,
          ),
        );
        setState(() {});
      }
    }
  }
}
