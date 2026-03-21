// ignore_for_file: deprecated_member_use

import 'package:flutter/material.dart';
// ignore: unused_import
import 'package:hive/hive.dart';
import 'package:yomiage/models/deck.dart';
import 'package:yomiage/models/flashcard.dart';
import 'package:yomiage/services/hive_service.dart';
// 日付フォーマット用
import 'dart:ui' as ui;
import 'package:yomiage/screens/card_edit_screen.dart';
import 'package:yomiage/screens/deck_edit_screen.dart';
import 'package:yomiage/webapp/web_card_editor.dart';
import 'package:yomiage/webapp/web_csv_exporter.dart';
import 'package:yomiage/webapp/web_card_deleter.dart';
import 'package:yomiage/webapp/web_table_widgets.dart';

class WebDeckCardsScreen extends StatefulWidget {
  final Deck? deck;
  final String? chapter; // null 許容

  const WebDeckCardsScreen({Key? key, this.deck, this.chapter})
      : super(key: key);

  @override
  WebDeckCardsScreenState createState() => WebDeckCardsScreenState();
}

class WebDeckCardsScreenState extends State<WebDeckCardsScreen> {
  List<FlashCard> _cards = [];
  bool _isLoading = true;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  List<Deck> _allDecks = [];
  Deck? _selectedDeck;

  // テーブル全体の横スクロール用コントローラー
  final ScrollController _horizontalController = ScrollController();

  // 編集機能用 State
  final WebCardEditor _cardEditor = WebCardEditor();

  double _deckDropdownWidth = 120.0;

  // 並び替え状態（フェーズ1）
  String _sortField = 'default'; // default / chapter / headline / question / answer / nextReview / repetitions / updatedAt
  bool _sortAsc = true;

  @override
  void initState() {
    super.initState();
    _restoreSortPreference();
    _loadDecksAndCards();
  }

  @override
  void dispose() {
    _horizontalController.dispose();
    _cardEditor.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _restoreSortPreference() {
    try {
      final prefs = HiveService.getSettingsBox();
      final deckName = widget.deck?.deckName ?? '';
      final chapter = widget.chapter ?? '';
      final savedField = prefs.get('cardSort.deck.$deckName.chapter.$chapter.field');
      final savedAsc = prefs.get('cardSort.deck.$deckName.chapter.$chapter.asc');
      if (savedField is String && savedField.isNotEmpty) {
        _sortField = savedField;
      }
      if (savedAsc is bool) {
        _sortAsc = savedAsc;
      }
    } catch (_) {}
  }

  Future<void> _loadDecksAndCards({Deck? selectDeck}) async {
    setState(() {
      _isLoading = true;
    });
    try {
      final deckBox = HiveService.getDeckBox();
      final cardBox = HiveService.getCardBox();
      final decks = deckBox.values.cast<Deck>().toList();
      decks.sort((a, b) => a.deckName.compareTo(b.deckName));
      Deck? deckToShow =
          selectDeck ?? widget.deck ?? (decks.isNotEmpty ? decks.first : null);

      List<FlashCard> cards = [];
      if (deckToShow != null) {
        cards = cardBox.values
            .where((card) => card.deckName == deckToShow.deckName)
            .cast<FlashCard>()
            .toList();

        if (widget.chapter != null) {
          cards =
              cards.where((card) => card.chapter == widget.chapter).toList();
        }
        // 保存された並び替え設定を適用
        _applySort(cards);
      }

      if (mounted) {
        setState(() {
          _allDecks = decks;
          _selectedDeck = deckToShow;
          _cards = cards;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('デッキまたはカードの読み込みに失敗しました: $e')),
        );
      }
    }
  }

  // 固定部分の幅を計算
  double _calculateFixedWidth() {
    return WebTableWidgets.calculateFixedWidth();
  }

  // スクロール部分の幅を計算
  double _calculateScrollableWidth() {
    return WebTableWidgets.calculateScrollableWidth();
  }

  // ヘッダー行
  Widget _buildHeaderRow() {
    return WebTableWidgets.buildHeaderRow(
      context,
      onSort: (field) => _changeSort(field),
      activeField: _sortField,
      asc: _sortAsc,
    );
  }

  // データ行
  Widget _buildCardRow(FlashCard card) {
    return WebTableWidgets.buildCardRow(
      context,
      card,
      _allDecks,
      _cardEditor,
      () => setState(() {}),
      () => _loadDecksAndCards(selectDeck: _selectedDeck),
      () => _showDeleteConfirmDialog(card),
    );
  }

  // 検索フィルタリング関数を追加
  List<FlashCard> get _filteredCards {
    if (_searchQuery.isEmpty) return _cards;
    final query = _searchQuery.toLowerCase();
    return _cards.where((card) {
      return card.question.toLowerCase().contains(query) ||
          card.answer.toLowerCase().contains(query) ||
          card.explanation.toLowerCase().contains(query) ||
          card.chapter.toLowerCase().contains(query) ||
          card.headline.toLowerCase().contains(query) ||
          (card.supplement?.toLowerCase().contains(query) ?? false);
    }).toList();
  }

  // --- 並び替え適用（フェーズ1） ---
  void _applySort(List<FlashCard> list) {
    int compareString(String a, String b) => a.compareTo(b);
    int compareInt(int a, int b) => a.compareTo(b);
    int compareDate(DateTime? a, DateTime? b) {
      if (a == null && b == null) return 0;
      if (a == null) return -1;
      if (b == null) return 1;
      return a.compareTo(b);
    }

    int orderSign = _sortAsc ? 1 : -1;

    switch (_sortField) {
      case 'chapter':
        list.sort((a, b) => orderSign * compareString(a.chapter, b.chapter));
        break;
      case 'headline':
        list.sort((a, b) => orderSign * compareString(a.headline, b.headline));
        break;
      case 'question':
        list.sort((a, b) => orderSign * compareString(a.question, b.question));
        break;
      case 'answer':
        list.sort((a, b) => orderSign * compareString(a.answer, b.answer));
        break;
      case 'nextReview':
        list.sort((a, b) => orderSign * compareDate(a.nextReview, b.nextReview));
        break;
      case 'repetitions':
        list.sort((a, b) => orderSign * compareInt(a.repetitions, b.repetitions));
        break;
      case 'updatedAt':
        list.sort((a, b) => orderSign * compareInt((a.updatedAt ?? 0), (b.updatedAt ?? 0)));
        break;
      case 'default':
      default:
        // 既定: チャプター→見出し→質問
        list.sort((a, b) {
          final c1 = compareString(a.chapter, b.chapter);
          if (c1 != 0) return _sortAsc ? c1 : -c1;
          final h1 = compareString(a.headline.isNotEmpty ? a.headline : '', b.headline.isNotEmpty ? b.headline : '');
          if (h1 != 0) return _sortAsc ? h1 : -h1;
          final q1 = compareString(a.question, b.question);
          return _sortAsc ? q1 : -q1;
        });
    }
  }

  void _changeSort(String field) {
    setState(() {
      if (_sortField == field) {
        _sortAsc = !_sortAsc; // 同じ列なら昇降反転
      } else {
        _sortField = field;
        _sortAsc = true; // 新しい列は昇順から
      }
      // 永続化
      final prefs = HiveService.getSettingsBox();
      final deckName = _selectedDeck?.deckName ?? '';
      final chapter = widget.chapter ?? '';
      prefs.put('cardSort.deck.$deckName.chapter.$chapter.field', _sortField);
      prefs.put('cardSort.deck.$deckName.chapter.$chapter.asc', _sortAsc);
      // 表示に反映
      _applySort(_cards);
    });
  }

  @override
  Widget build(BuildContext context) {
    final fixedWidth = _calculateFixedWidth();
    final scrollableWidth = _calculateScrollableWidth();

    // 全体の幅を計算（左右のパディングも追加） - 編集ボタン削除分(76.0)を引く
    final totalWidth = fixedWidth +
        scrollableWidth +
        150.0 -
        76.0 +
        (WebTableWidgets.tableSidePaddingWidth * 2);

    final TextStyle deckTextStyle =
        Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
    double maxDeckNameWidth = 0;
    final textPainter = TextPainter(
      textDirection: ui.TextDirection.ltr,
      maxLines: 1,
    );
    for (final deck in _allDecks) {
      textPainter.text = TextSpan(text: deck.deckName, style: deckTextStyle);
      textPainter.layout();
      if (textPainter.width > maxDeckNameWidth) {
        maxDeckNameWidth = textPainter.width;
      }
    }

    _deckDropdownWidth = maxDeckNameWidth + 50.0;
    if (_deckDropdownWidth < 120.0) _deckDropdownWidth = 120.0;

    return Scaffold(
      appBar: AppBar(
        title: Text(_selectedDeck != null
            ? 'デッキ: ${_selectedDeck!.deckName} - カード一覧'
            : 'カード一覧'),
        actions: [
          // 検索フィールドを追加
          Container(
            width: 200,
            margin: const EdgeInsets.symmetric(vertical: 8),
            child: TextField(
              controller: _searchController,
              style: TextStyle(
                  color: Theme.of(context).textTheme.bodyMedium?.color),
              decoration: InputDecoration(
                hintText: '検索...',
                hintStyle: TextStyle(
                    color: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.color
                        ?.withOpacity(0.7)),
                prefixIcon: Icon(Icons.search,
                    color: Theme.of(context).iconTheme.color?.withOpacity(0.7)),
                filled: true,
                fillColor: Theme.of(context).colorScheme.surfaceVariant,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              ),
              onChanged: (value) {
                setState(() {
                  _searchQuery = value;
                });
              },
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'デッキ編集',
            onPressed: _selectedDeck == null
                ? null
                : () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) =>
                            DeckEditScreen(deckKey: _selectedDeck!.key),
                      ),
                    ).then((result) {
                      if (result == true) {
                        _loadDecksAndCards(selectDeck: _selectedDeck);
                      }
                    });
                  },
          ),
          IconButton(
            icon: const Icon(Icons.file_download),
            tooltip: 'CSVエクスポート',
            onPressed: () => WebCsvExporter.downloadCsvWeb(context),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _cards.isEmpty
              ? Center(
                  child: Text('このデッキにはカードがありません。',
                      style: TextStyle(
                          fontSize: 16,
                          color:
                              Theme.of(context).textTheme.bodyMedium?.color)))
              : RawScrollbar(
                  controller: _horizontalController,
                  thumbVisibility: true,
                  thickness: 8.0,
                  thumbColor:
                      Theme.of(context).colorScheme.outline.withOpacity(0.6),
                  radius: const Radius.circular(4.0),
                  child: SingleChildScrollView(
                    controller: _horizontalController,
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: totalWidth,
                      child: ListView.builder(
                        itemCount: _filteredCards.length +
                            1, // _cardsを_filteredCardsに変更
                        padding: const EdgeInsets.only(bottom: 72.0),
                        itemBuilder: (context, index) {
                          if (index == 0) {
                            return Column(
                              children: [
                                _buildHeaderRow(),
                                Divider(
                                    height: 1,
                                    thickness: 1,
                                    color: Theme.of(context).dividerColor),
                              ],
                            );
                          } else {
                            return Column(
                              children: [
                                _buildCardRow(_filteredCards[
                                    index - 1]), // _cardsを_filteredCardsに変更
                                Divider(
                                    height: 1,
                                    thickness: 1,
                                    color: Theme.of(context).dividerColor),
                              ],
                            );
                          }
                        },
                      ),
                    ),
                  ),
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => CardEditScreen(
                initialDeckName: _selectedDeck?.deckName,
              ),
            ),
          ).then((_) {
            _loadDecksAndCards(selectDeck: _selectedDeck);
          });
        },
        tooltip: 'カードを新規作成',
        backgroundColor: Theme.of(context).colorScheme.primary,
        child: Icon(
          Icons.edit,
          color: Theme.of(context).colorScheme.onPrimary,
        ),
      ),
    );
  }

  // 削除確認ダイアログを表示
  void _showDeleteConfirmDialog(FlashCard card) {
    WebCardDeleter.showDeleteConfirmDialog(
      context,
      card,
      () async {
        try {
          await WebCardDeleter.deleteCard(card, () async {
            await _loadDecksAndCards(selectDeck: _selectedDeck);
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('カード「${card.question}」を削除しました'),
                  backgroundColor: Colors.green,
                ),
              );
            }
          });
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('カードの削除に失敗しました: $e'),
                backgroundColor: Colors.red,
              ),
            );
          }
        }
      },
    );
  }
}
