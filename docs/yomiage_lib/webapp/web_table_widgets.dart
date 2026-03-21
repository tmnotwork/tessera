import 'package:flutter/material.dart';
import 'package:yomiage/models/deck.dart';
import 'package:yomiage/models/flashcard.dart';
import 'package:yomiage/webapp/web_card_editor.dart';
import 'package:yomiage/services/hive_service.dart';
import 'package:yomiage/services/firebase_service.dart';
import 'package:intl/intl.dart';

class WebTableWidgets {
  // 固定部分の列幅
  static const double questionWidth = 220.0;
  static const double answerWidth = 220.0;
  static const double explanationWidth = 220.0;
  static const double qEngWidth = 40.0; // 質英
  static const double aEngWidth = 40.0; // 回英
  static const double deckColumnWidth = 180.0; // デッキ
  static const double chapterWidth = 150.0; // ▼▼▼ チャプター ▼▼▼
  static const double headlineWidth = 150.0; // ★ headline 幅を追加
  static const double supplementWidth = 220.0; // ★★★ supplement 幅を追加 (解説と同じ)

  // スクロール部分の幅を計算
  static const double nextReviewWidth = 140.0;
  static const double repetitionsWidth = 80.0;

  // テーブル左右のパディング幅
  static const double tableSidePaddingWidth = 16.0;

  // 固定部分の幅を計算
  static double calculateFixedWidth() {
    return questionWidth +
        answerWidth +
        explanationWidth +
        qEngWidth +
        aEngWidth +
        chapterWidth +
        headlineWidth +
        supplementWidth;
  }

  // スクロール部分の幅を計算
  static double calculateScrollableWidth() {
    return deckColumnWidth + nextReviewWidth + repetitionsWidth;
  }

  // ヘッダー行
  static Widget buildHeaderRow(BuildContext context, {void Function(String field)? onSort, String? activeField, bool asc = true}) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      width: double.infinity, // 幅を最大にして背景色を統一
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(width: tableSidePaddingWidth),
          _sortableHeader(context, 'デッキ', 'deckName', width: deckColumnWidth, onSort: onSort, activeField: activeField, asc: asc),
          _sortableHeader(context, 'チャプター', 'chapter', width: chapterWidth, onSort: onSort, activeField: activeField, asc: asc),
          _sortableHeader(context, '見出し', 'headline', width: headlineWidth, onSort: onSort, activeField: activeField, asc: asc),
          _sortableHeader(context, '問題', 'question', width: questionWidth, onSort: onSort, activeField: activeField, asc: asc),
          _sortableHeader(context, '回答', 'answer', width: answerWidth, onSort: onSort, activeField: activeField, asc: asc),
          _sortableHeader(context, '解説', 'explanation', width: explanationWidth, onSort: onSort, activeField: activeField, asc: asc),
          _headerCell(context, '補足', width: supplementWidth),
          _headerCell(context, '質英', width: qEngWidth, alignment: Alignment.center),
          const SizedBox(width: 8.0),
          _headerCell(context, '回英', width: aEngWidth, alignment: Alignment.center),
          _sortableHeader(context, '次回レビュー', 'nextReview', width: nextReviewWidth, onSort: onSort, activeField: activeField, asc: asc),
          _sortableHeader(context, '連続正解', 'repetitions', width: repetitionsWidth, alignment: Alignment.centerRight, onSort: onSort, activeField: activeField, asc: asc),
          const SizedBox(width: tableSidePaddingWidth),
          _headerCell(context, '削除', width: 60.0, alignment: Alignment.center),
        ],
      ),
    );
  }

  // データ行
  static Widget buildCardRow(
    BuildContext context,
    FlashCard card,
    List<Deck> allDecks,
    WebCardEditor editor,
    VoidCallback setStateCallback,
    VoidCallback loadDecksAndCards,
    VoidCallback showDeleteConfirm,
  ) {
    final cellBgColor = Theme.of(context).colorScheme.surface;
    final bool isEditingQuestion = editor.isEditing(card, 'question');
    final bool isEditingAnswer = editor.isEditing(card, 'answer');
    final bool isEditingExplanation = editor.isEditing(card, 'explanation');
    final bool isEditingChapter = editor.isEditing(card, 'chapter');
    final bool isEditingHeadline = editor.isEditing(card, 'headline');
    final bool isEditingSupplement = editor.isEditing(card, 'supplement');

    return Container(
      color: cellBgColor,
      width: double.infinity, // 幅を最大にして背景色を統一
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(width: tableSidePaddingWidth),
          _buildDeckDropdown(card, allDecks, loadDecksAndCards),
          isEditingChapter
              ? editor.buildEditingCell(context, card, 'chapter', chapterWidth)
              : editor.buildDisplayCell(
                  context,
                  card.chapter,
                  () => editor.startEditing(card, 'chapter', setStateCallback),
                  width: chapterWidth,
                  allowMultiline: true,
                  displayEmptyAs: '',
                ),
          isEditingHeadline
              ? editor.buildEditingCell(context, card, 'headline', headlineWidth)
              : editor.buildDisplayCell(
                  context,
                  card.headline,
                  () => editor.startEditing(card, 'headline', setStateCallback),
                  width: headlineWidth,
                  allowMultiline: true,
                  displayEmptyAs: '',
                ),
          isEditingQuestion
              ? editor.buildEditingCell(context, card, 'question', questionWidth)
              : editor.buildDisplayCell(
                  context,
                  card.question,
                  () => editor.startEditing(card, 'question', setStateCallback),
                  width: questionWidth,
                  allowMultiline: true,
                ),
          isEditingAnswer
              ? editor.buildEditingCell(context, card, 'answer', answerWidth)
              : editor.buildDisplayCell(
                  context,
                  card.answer,
                  () => editor.startEditing(card, 'answer', setStateCallback),
                  width: answerWidth,
                  allowMultiline: true,
                ),
          isEditingExplanation
              ? editor.buildEditingCell(context, card, 'explanation', explanationWidth)
              : editor.buildDisplayCell(
                  context,
                  card.explanation,
                  () => editor.startEditing(
                      card, 'explanation', setStateCallback),
                  width: explanationWidth,
                  allowMultiline: true,
                  displayEmptyAs: '',
                ),
          isEditingSupplement
              ? editor.buildEditingCell(context, card, 'supplement', supplementWidth)
              : editor.buildDisplayCell(
                  context,
                  card.supplement ?? '',
                  () =>
                      editor.startEditing(card, 'supplement', setStateCallback),
                  width: supplementWidth,
                  allowMultiline: true,
                  displayEmptyAs: '',
                ),
          _buildEnglishFlagCell(
            context,
            card,
            'question',
            qEngWidth,
            setStateCallback,
          ),
          const SizedBox(width: 8.0),
          _buildEnglishFlagCell(
            context,
            card,
            'answer',
            aEngWidth,
            setStateCallback,
          ),
          _dataCell(
            context,
            _formatDateTime(card.nextReview?.millisecondsSinceEpoch),
            width: nextReviewWidth,
            displayEmptyAs: '',
          ),
          _dataCell(
            context,
            card.repetitions.toString(),
            width: repetitionsWidth,
            alignment: Alignment.centerRight,
          ),
          const SizedBox(width: tableSidePaddingWidth),
          Container(
            width: 60.0,
            alignment: Alignment.center,
            child: IconButton(
              icon: Icon(Icons.delete, color: Theme.of(context).colorScheme.error),
              tooltip: 'カード削除',
              onPressed: () => showDeleteConfirm(),
            ),
          ),
        ],
      ),
    );
  }

  // --- セル構築メソッド ---
  static Widget _headerCell(BuildContext context, String title,
      {double? width, Alignment? alignment}) {
    return Container(
      width: width,
      height: 40.0,
      padding: const EdgeInsets.symmetric(horizontal: 4.0),
      alignment: alignment ?? Alignment.centerLeft,
      child: Text(
        title,
        style: TextStyle(
          fontWeight: FontWeight.bold,
          color: Theme.of(context).textTheme.titleSmall?.color,
        ),
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  static Widget _sortableHeader(
    BuildContext context,
    String title,
    String field, {
    double? width,
    Alignment? alignment,
    void Function(String field)? onSort,
    String? activeField,
    bool asc = true,
  }) {
    final isActive = activeField == field;
    final icon = isActive
        ? (asc ? Icons.arrow_upward : Icons.arrow_downward)
        : null;
    return InkWell(
      onTap: onSort == null ? null : () => onSort(field),
      child: Container(
        width: width,
        height: 40.0,
        padding: const EdgeInsets.symmetric(horizontal: 4.0),
        alignment: alignment ?? Alignment.centerLeft,
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).textTheme.titleSmall?.color,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (icon != null)
              Icon(icon, size: 14, color: Theme.of(context).iconTheme.color),
          ],
        ),
      ),
    );
  }

  static Widget _dataCell(BuildContext context, String? text,
      {double? width, Alignment? alignment, String displayEmptyAs = '-'}) {
    final displayText = (text == null || text.isEmpty) ? displayEmptyAs : text;
    return Container(
      width: width,
      constraints: const BoxConstraints(minHeight: 40.0),
      padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 8.0),
      alignment: alignment ?? Alignment.centerLeft,
      child: SelectableText(
        displayText,
        maxLines: 1,
        style: TextStyle(
          color: Theme.of(context).textTheme.bodyLarge?.color,
        ),
      ),
    );
  }

  static Widget _buildEnglishFlagCell(
    BuildContext context,
    FlashCard card,
    String flagType,
    double width,
    VoidCallback setStateCallback,
  ) {
    final isQuestion = flagType == 'question';
    final flag = isQuestion ? card.questionEnglishFlag : card.answerEnglishFlag;
    onTap() async {
      setStateCallback();
      if (isQuestion) {
        card.questionEnglishFlag = !card.questionEnglishFlag;
      } else {
        card.answerEnglishFlag = !card.answerEnglishFlag;
      }
      await card.save();
    }

    return Container(
      width: width,
      alignment: Alignment.center,
      child: Tooltip(
        message: 'クリックで英⇔日を切り替え',
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(4),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 6.0),
            decoration: BoxDecoration(
              color: Colors.transparent,
              border: Border.all(
                color: Colors.transparent,
                width: 1.0,
              ),
            ),
            child: Text(
              flag ? '英' : '日',
              style: TextStyle(color: Theme.of(context).textTheme.bodyLarge?.color),
            ),
          ),
        ),
      ),
    );
  }

  static Widget _buildDeckDropdown(
    FlashCard card,
    List<Deck> allDecks,
    VoidCallback loadDecksAndCards,
  ) {
    // 現在のカードが属するデッキオブジェクトを探す
    Deck? currentDeck = _findDeckByName(card.deckName, allDecks);

    return Container(
      width: deckColumnWidth,
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 0),
      decoration: const BoxDecoration(),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<Deck?>(
          isExpanded: true,
          value: currentDeck,
          icon: const Icon(Icons.arrow_drop_down, size: 20),
          style: const TextStyle(
            fontSize: 13,
            color: Colors.white,
          ),
          items: allDecks.map<DropdownMenuItem<Deck>>((Deck deck) {
            return DropdownMenuItem<Deck>(
              value: deck,
              child: Text(
                deck.deckName,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white),
              ),
            );
          }).toList(),
          onChanged: (Deck? newSelectedDeck) async {
            if (newSelectedDeck != null &&
                newSelectedDeck.deckName != card.deckName) {
              final originalDeckName = card.deckName;
              card.deckName = newSelectedDeck.deckName;
              card.updateTimestamp();
              try {
                await HiveService.getCardBox().put(card.key, card);
                await FirebaseService.saveCard(
                    card, FirebaseService.getUserId()!);
                loadDecksAndCards();
              } catch (e) {
                card.deckName = originalDeckName;
                throw Exception('デッキ変更エラー: $e');
              }
            }
          },
        ),
      ),
    );
  }

  // ヘルパー関数: デッキ名でデッキを検索（見つからなければnull）
  static Deck? _findDeckByName(String name, List<Deck> allDecks) {
    try {
      return allDecks.firstWhere((deck) => deck.deckName == name);
    } catch (e) {
      return null;
    }
  }

  static String _formatDateTime(int? timestamp) {
    if (timestamp == null) return '-';
    try {
      final dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
      return DateFormat('yyyy/MM/dd HH:mm').format(dt.toLocal());
    } catch (e) {
      return '無効な日付';
    }
  }
}
