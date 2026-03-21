import 'package:flutter/material.dart';
import 'package:yomiage/models/flashcard.dart';
import 'package:yomiage/services/firebase_service.dart';
import 'package:yomiage/services/sync_service.dart';
import 'package:flutter/services.dart';

class WebCardEditor {
  final TextEditingController editingController = TextEditingController();
  final FocusNode editingFocusNode = FocusNode();
  dynamic editingCardKey;
  String? editingColumn;
  VoidCallback? _setStateCallback; // 保存・キャンセル時の再描画用

  void dispose() {
    editingController.dispose();
    editingFocusNode.dispose();
  }

  // 表示用セル
  Widget buildDisplayCell(
      BuildContext context, String? text, VoidCallback onDoubleTap,
      {bool allowMultiline = false,
      String displayEmptyAs = '-',
      double? width}) {
    final displayText = (text == null || text.isEmpty) ? displayEmptyAs : text;
    return GestureDetector(
      onDoubleTap: onDoubleTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: width,
        constraints: const BoxConstraints(minHeight: 40.0),
        padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 8.0),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: Colors.transparent,
          border: Border.all(
            color: Colors.transparent,
            width: 1.0,
          ),
        ),
        child: SelectableText(
          displayText,
          style: TextStyle(
            color: Theme.of(context).textTheme.bodyLarge?.color,
          ),
          maxLines: allowMultiline ? null : 1,
        ),
      ),
    );
  }

  // 編集用セル
  Widget buildEditingCell(
      BuildContext context, FlashCard card, String column, double columnWidth) {
    final bool isSingleLine = (column == 'chapter' || column == 'headline');
    final textField = Container(
      width: columnWidth,
      padding: const EdgeInsets.symmetric(vertical: 6.0, horizontal: 0),
      child: TextField(
        key: ValueKey('${card.key}_$column'),
        controller: editingController,
        focusNode: editingFocusNode,
        maxLines: isSingleLine ? 1 : null,
        textInputAction:
            isSingleLine ? TextInputAction.done : TextInputAction.newline,
        style: TextStyle(
          color: Theme.of(context).textTheme.bodyLarge?.color,
          fontSize: 14,
        ),
        decoration: InputDecoration(
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4.0),
          filled: true,
          fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
          border: OutlineInputBorder(
              borderSide: BorderSide(color: Theme.of(context).dividerColor)),
          focusedBorder: OutlineInputBorder(
              borderSide: BorderSide(
                  color: Theme.of(context).colorScheme.primary, width: 2)),
          enabledBorder: OutlineInputBorder(
              borderSide: BorderSide(color: Theme.of(context).dividerColor)),
        ),
        onSubmitted: (value) => saveEdit(card, column, value),
        // 単一行編集時の確定イベント重複を避けるため、onEditingCompleteは未使用
        onEditingComplete: null,
        onTapOutside: (event) {
          // IME確定直後のフォーカス移動と衝突しにくいよう、
          // すでに保存が走っている可能性を考慮して二重呼び出しを最小化
          if (editingCardKey != null) {
            saveEdit(card, column, editingController.text);
          }
        },
      ),
    );

    if (isSingleLine) {
      return textField;
    }

    // 複数行フィールド: Enter=確定、Shift+Enter=改行
    return Shortcuts(
      shortcuts: <LogicalKeySet, Intent>{
        LogicalKeySet(LogicalKeyboardKey.enter): const _ConfirmEditIntent(),
        LogicalKeySet(LogicalKeyboardKey.shift, LogicalKeyboardKey.enter):
            const _InsertNewlineIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _ConfirmEditIntent: CallbackAction<_ConfirmEditIntent>(
            onInvoke: (intent) {
              // IME変換中(合成中)は確定せずにスルー
              final composing = editingController.value.composing;
              if (composing.isValid) {
                return null;
              }
              saveEdit(card, column, editingController.text);
              return null;
            },
          ),
          _InsertNewlineIntent: CallbackAction<_InsertNewlineIntent>(
            onInvoke: (intent) {
              final value = editingController.value;
              final selection = value.selection;
              final text = value.text;
              String newText;
              int newOffset;
              if (selection.isValid) {
                newText = text.replaceRange(selection.start, selection.end, '\n');
                newOffset = selection.start + 1;
              } else {
                newText = text + '\n';
                newOffset = newText.length;
              }
              editingController.value = value.copyWith(
                text: newText,
                selection: TextSelection.collapsed(offset: newOffset),
                composing: TextRange.empty,
              );
              return null;
            },
          ),
        },
        child: Focus(
          // ShortcutsがTextFieldより先にキーを受け取るよう確実にフォーカス
          autofocus: true,
          child: textField,
        ),
      ),
    );
  }

  // 編集開始
  void startEditing(
      FlashCard card, String column, VoidCallback setStateCallback) {
    if (editingCardKey == card.key && editingColumn == column) {
      return;
    }
    if (editingCardKey != null) {
      cancelEditing(setStateCallback);
    }

    setStateCallback();
    _setStateCallback = setStateCallback;
    editingCardKey = card.key;
    editingColumn = column;
    switch (column) {
      case 'question':
        editingController.text = card.question;
        break;
      case 'answer':
        editingController.text = card.answer;
        break;
      case 'explanation':
        editingController.text = card.explanation;
        break;
      case 'chapter':
        editingController.text = card.chapter;
        break;
      case 'headline':
        editingController.text = card.headline;
        break;
      case 'supplement':
        editingController.text = card.supplement ?? '';
        break;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      editingFocusNode.requestFocus();
      editingController.selection = TextSelection.fromPosition(
          TextPosition(offset: editingController.text.length));
    });
  }

  // 編集内容を保存
  Future<void> saveEdit(FlashCard card, String column, String newValue) async {
    bool changed = false;

    switch (column) {
      case 'question':
        if (newValue != card.question) {
          card.question = newValue;
          changed = true;
        }
        break;
      case 'answer':
        if (newValue != card.answer) {
          card.answer = newValue;
          changed = true;
        }
        break;
      case 'explanation':
        if (newValue != card.explanation) {
          card.explanation = newValue;
          changed = true;
        }
        break;
      case 'chapter':
        if (newValue != card.chapter) {
          card.chapter = newValue;
          changed = true;
        }
        break;
      case 'headline':
        if (newValue != card.headline) {
          card.headline = newValue;
          changed = true;
        }
        break;
      case 'supplement':
        if (newValue != card.supplement) {
          card.supplement = newValue;
          changed = true;
        }
        break;
    }

    if (changed && card.isInBox) {
      try {
        card.updatedAt = DateTime.now().millisecondsSinceEpoch;
        await card.save();

        // 2) Firebase へ同期
        try {
          final userId = FirebaseService.getUserId();
          if (userId != null) {
            await SyncService.syncOperationToCloud(
              'update_card',
              {'card': card},
            );
          } else {}
        } catch (e) {
          // Firebase同期エラーは無視（ローカル保存は成功しているため）
        }
      } catch (e) {
        // 保存エラーの場合は例外を投げる
        throw Exception('カードの保存に失敗しました: $e');
      }
    }
    // 保存後に必ず再描画して表示セルへ戻す
    cancelEditing(_setStateCallback ?? () {});
  }

  // 編集キャンセル
  void cancelEditing(VoidCallback setStateCallback) {
    if (editingCardKey == null && editingColumn == null) {
      return;
    }
    setStateCallback();
    editingCardKey = null;
    editingColumn = null;
    editingController.clear();
    editingFocusNode.unfocus();
    _setStateCallback = null;
  }

  // カラム名から幅を取得するヘルパーメソッド
  double getColumnWidth(String column) {
    switch (column) {
      case 'question':
        return 220.0;
      case 'answer':
        return 220.0;
      case 'explanation':
        return 220.0;
      case 'chapter':
        return 150.0;
      case 'headline':
        return 150.0;
      case 'supplement':
        return 220.0;
      default:
        return 100.0;
    }
  }

  // 編集状態をチェック
  bool isEditing(FlashCard card, String column) {
    return editingCardKey == card.key && editingColumn == column;
  }
}

// キー操作用のIntent（内部用）
class _ConfirmEditIntent extends Intent {
  const _ConfirmEditIntent();
}

class _InsertNewlineIntent extends Intent {
  const _InsertNewlineIntent();
}
