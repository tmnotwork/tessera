import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/inbox_task.dart' as inbox;
import '../../providers/task_provider.dart';
import '../../utils/input_method_guard.dart';
import '../../utils/ime_safe_dialog.dart';

// NOTE: Dartでは enum 宣言を関数内に置けないため、ファイルスコープに置く。
enum _MemoEditorCloseChoice { cancel, discard, save }

EdgeInsets _commentEditorScrollPadding(BuildContext context) {
  // IME候補ウィンドウは viewInsets に反映されないことがある（特にDesktop/Web）。
  // その場合でもキャレット行が候補に隠れないよう、下側に十分な余白を確保する。
  final bottomInset = MediaQuery.of(context).viewInsets.bottom;
  final extra = bottomInset > 0 ? 80.0 : 260.0;
  return EdgeInsets.fromLTRB(24, 24, 24, bottomInset + extra);
}

/// 汎用的なメモ編集ダイアログを表示します。
/// タイムラインやインボックスなど、様々な場所で使用できます。
Future<void> showMemoEditorDialog({
  required BuildContext context,
  required String? initialValue,
  required Future<void> Function(String?) onSave,
  bool autofocus = true,
}) async {
  final controller = TextEditingController(text: initialValue ?? '');
  String lastSavedText = controller.text;

  bool isSaving = false;
  String? feedbackMessage;
  bool feedbackIsError = false;
  bool isClosing = false;

  Future<_MemoEditorCloseChoice> confirmCloseChoice(BuildContext dialogCtx) async {
    final result = await showImeSafeDialog<String>(
      context: dialogCtx,
      barrierDismissible: false,
      builder: (confirmCtx) => AlertDialog(
        title: const Text('確認'),
        content: const Text('編集中です。内容を破棄しますか。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(confirmCtx).pop('cancel'),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.of(confirmCtx).pop('discard'),
            child: Text(
              '破棄する',
              style: TextStyle(color: Theme.of(confirmCtx).colorScheme.error),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.of(confirmCtx).pop('save'),
            child: const Text('保存して閉じる'),
          ),
        ],
      ),
    );
    switch (result) {
      case 'discard':
        return _MemoEditorCloseChoice.discard;
      case 'save':
        return _MemoEditorCloseChoice.save;
      default:
        return _MemoEditorCloseChoice.cancel;
    }
  }

  Future<void> handleSave({
    required bool closeAfter,
    required VoidCallback setSaving,
    required void Function({
      required bool isError,
      required String? message,
    }) setFeedback,
    required BuildContext dialogContext,
  }) async {
    if (isSaving) return;
    setSaving();

    final memoText = controller.text.trim();
    final memoValue = memoText.isEmpty ? null : memoText;

    try {
      await onSave(memoValue);
      if (closeAfter) {
        if (dialogContext.mounted) {
          Navigator.of(dialogContext).pop(true);
        }
        return;
      }
      // 保存したので「破棄確認」の基準を更新する
      lastSavedText = controller.text;
      setFeedback(isError: false, message: '保存しました');
    } catch (e) {
      setFeedback(isError: true, message: '保存に失敗しました');
    } finally {
      isSaving = false;
    }
  }

  Widget buildDialog(BuildContext dialogCtx) {
    return StatefulBuilder(
      builder: (ctx, setStateDialog) {
        bool isDirty() => controller.text != lastSavedText;

        void setSaving() {
          setStateDialog(() {
            isSaving = true;
            feedbackMessage = null;
          });
        }

        void setFeedback({
          required bool isError,
          required String? message,
        }) {
          setStateDialog(() {
            feedbackIsError = isError;
            feedbackMessage = message;
            isSaving = false;
          });
        }

        Future<void> save({required bool closeAfter}) async {
          await handleSave(
            closeAfter: closeAfter,
            setSaving: setSaving,
            setFeedback: setFeedback,
            dialogContext: dialogCtx,
          );
        }

        void saveAndContinue() {
          if (isImeComposing(controller)) {
            return;
          }
          unawaited(save(closeAfter: false));
        }

        Future<bool> handleCloseRequest() async {
          if (isSaving) return false;
          if (isClosing) return false;
          if (!isDirty()) return true;
          isClosing = true;
          try {
            final choice = await confirmCloseChoice(dialogCtx);
            if (choice == _MemoEditorCloseChoice.cancel) return false;
            if (choice == _MemoEditorCloseChoice.discard) return true;
            // save
            await handleSave(
              closeAfter: true,
              setSaving: setSaving,
              setFeedback: setFeedback,
              dialogContext: dialogCtx,
            );
            return false;
          } finally {
            isClosing = false;
          }
        }

        return CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            const SingleActivator(LogicalKeyboardKey.keyS, control: true):
                saveAndContinue,
            const SingleActivator(LogicalKeyboardKey.keyS, meta: true):
                saveAndContinue,
          },
          child: Focus(
            autofocus: autofocus,
            child: WillPopScope(
              onWillPop: () async {
                final ok = await handleCloseRequest();
                return ok;
              },
              child: AlertDialog(
                insetPadding:
                    const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
                title: const Text('コメント'),
                content: SizedBox(
                  width: 900,
                  child: Builder(
                    builder: (contentCtx) {
                      // 画面の高さが小さい場合でも、actions（保存/キャンセル）が
                      // TextFieldにかぶらないよう、content側の最大高さを制限して
                      // TextFieldを可変高（Expanded）で収める。
                      //
                      // NOTE:
                      // - IME候補位置ズレ対策（Transform回避）は showImeSafeDialog 側で担保している。
                      // - ここでは TextField 自体のTransform等は行わず、レイアウト制約のみ調整する。
                      final mq = MediaQuery.of(contentCtx);
                      final availableHeight =
                          mq.size.height - mq.viewInsets.bottom;
                      // insetPadding(vertical)=24*2 は AlertDialog 側で適用済みだが、
                      // contentが過剰に大きいと結果としてactionsが見切れ/重なりに見えるため、
                      // title/actions等の“chrome”分を見込んで余裕を取る。
                      const double estimatedChromeHeight = 180.0;
                      final maxContentHeight =
                          (availableHeight - estimatedChromeHeight)
                              .clamp(240.0, 720.0);

                      return ConstrainedBox(
                        constraints:
                            BoxConstraints(maxHeight: maxContentHeight),
                        child: Column(
                          mainAxisSize: MainAxisSize.max,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: TextField(
                                controller: controller,
                                // Web + ダイアログ + IME で候補ウィンドウが重なるケースの調整。
                                // expands:true を有効にし、可変高の“編集枠”を常に確保する。
                                expands: true,
                                maxLines: null,
                                minLines: null,
                                textAlignVertical: TextAlignVertical.top,
                                keyboardType: TextInputType.multiline,
                                // WebのIME候補位置は、隠しtextarea側の行高/メトリクスに影響されるため、
                                // 表示側も行高を固定してズレを最小化する。
                                style: const TextStyle(height: 1.0),
                                scrollPadding:
                                    _commentEditorScrollPadding(dialogCtx),
                                decoration: const InputDecoration(
                                  hintText: 'コメントを入力...',
                                  border: OutlineInputBorder(),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Ctrl+S / Cmd+S でダイアログを閉じずに保存できます',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.color
                                        ?.withOpacity(0.7),
                                  ),
                            ),
                            if (feedbackMessage != null) ...[
                              const SizedBox(height: 12),
                              Text(
                                feedbackMessage!,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: feedbackIsError
                                      ? Theme.of(context).colorScheme.error
                                      : Theme.of(context).colorScheme.primary,
                                ),
                              ),
                            ],
                          ],
                        ),
                      );
                    },
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: isSaving
                        ? null
                        : () async {
                            final ok = await handleCloseRequest();
                            if (!ok) return;
                            if (dialogCtx.mounted) {
                              Navigator.of(dialogCtx).pop();
                            }
                          },
                    child: const Text('キャンセル'),
                  ),
                  FilledButton(
                    onPressed: isSaving
                        ? null
                        : () => unawaited(save(closeAfter: true)),
                    child: isSaving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('保存'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // 外側タップでも「破棄確認→OKで閉じる」を実現するため、
  // ダイアログの barrierDismissible=true にはせず、外側タップ検知レイヤーで自前処理する。
  //
  // NOTE:
  // showDialog の barrierDismissible=true だと、外側タップ時に即 pop されて
  // 破棄確認を挟めないため（フレームワーク側で完結してしまう）。
  final navigator = Navigator.of(context, rootNavigator: true);
  await navigator.push<bool>(
    PageRouteBuilder<bool>(
      opaque: false,
      barrierDismissible: false,
      transitionDuration: const Duration(milliseconds: 150),
      reverseTransitionDuration: const Duration(milliseconds: 150),
      pageBuilder: (routeCtx, animation, secondaryAnimation) {
        Future<void> handleOuterTap() async {
          if (isSaving) return;
          if (isClosing) return;
          final dirty = controller.text != lastSavedText;
          if (!dirty) {
            if (routeCtx.mounted) Navigator.of(routeCtx).pop(false);
            return;
          }
          isClosing = true;
          try {
            final choice = await confirmCloseChoice(routeCtx);
            if (!routeCtx.mounted) return;
            if (choice == _MemoEditorCloseChoice.cancel) return;
            if (choice == _MemoEditorCloseChoice.discard) {
              Navigator.of(routeCtx).pop(false);
              return;
            }
            // save
            await onSave(controller.text.trim().isEmpty
                ? null
                : controller.text.trim());
            if (!routeCtx.mounted) return;
            Navigator.of(routeCtx).pop(true);
          } finally {
            isClosing = false;
          }
        }

        return SafeArea(
          child: Material(
            type: MaterialType.transparency,
            child: Stack(
              children: [
                // Dark overlay + outside tap detector
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => unawaited(handleOuterTap()),
                    child: const ColoredBox(color: Colors.black54),
                  ),
                ),
                Center(
                  child: InheritedTheme.captureAll(
                    context,
                    Builder(builder: (dialogCtx) => buildDialog(dialogCtx)),
                  ),
                ),
              ],
            ),
          ),
        );
      },
      transitionsBuilder: (ctx, animation, secondaryAnimation, child) {
        return FadeTransition(opacity: animation, child: child);
      },
    ),
  );

  controller.dispose();
}

/// PC版の編集体験（大きい入力欄 + Ctrl/Cmd+Sで保存継続）を保ったまま、
/// モバイル向けにメモ編集画面をフルスクリーン表示します。
Future<void> showMemoEditorFullScreen({
  required BuildContext context,
  required String? initialValue,
  required Future<void> Function(String?) onSave,
  bool autofocus = true,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  await navigator.push<void>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _MemoEditorFullScreenPage(
        initialValue: initialValue,
        onSave: onSave,
        autofocus: autofocus,
      ),
    ),
  );
}

class _MemoEditorFullScreenPage extends StatefulWidget {
  final String? initialValue;
  final Future<void> Function(String?) onSave;
  final bool autofocus;

  const _MemoEditorFullScreenPage({
    required this.initialValue,
    required this.onSave,
    required this.autofocus,
  });

  @override
  State<_MemoEditorFullScreenPage> createState() =>
      _MemoEditorFullScreenPageState();
}

class _MemoEditorFullScreenPageState extends State<_MemoEditorFullScreenPage> {
  late final TextEditingController _controller;
  bool _isSaving = false;
  String? _feedbackMessage;
  bool _feedbackIsError = false;
  late String _lastSavedText;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue ?? '');
    _lastSavedText = _controller.text;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _handleSave({required bool closeAfter}) async {
    if (_isSaving) return;
    setState(() {
      _isSaving = true;
      _feedbackMessage = null;
    });

    final memoText = _controller.text.trim();
    final memoValue = memoText.isEmpty ? null : memoText;

    try {
      await widget.onSave(memoValue);
      if (!mounted) return;
      if (closeAfter) {
        Navigator.of(context).pop();
        return;
      }
      setState(() {
        _lastSavedText = _controller.text;
        _feedbackIsError = false;
        _feedbackMessage = '保存しました';
        _isSaving = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _feedbackIsError = true;
        _feedbackMessage = '保存に失敗しました';
        _isSaving = false;
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    void saveAndContinue() {
      if (isImeComposing(_controller)) {
        return;
      }
      unawaited(_handleSave(closeAfter: false));
    }

    Future<String?> confirmCloseChoice() async {
      return await showImeSafeDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (confirmCtx) => AlertDialog(
          title: const Text('確認'),
          content: const Text('編集中です。内容を破棄しますか。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(confirmCtx).pop('cancel'),
              child: const Text('キャンセル'),
            ),
            TextButton(
              onPressed: () => Navigator.of(confirmCtx).pop('discard'),
              child: Text(
                '破棄する',
                style: TextStyle(color: Theme.of(confirmCtx).colorScheme.error),
              ),
            ),
            FilledButton(
              onPressed: () => Navigator.of(confirmCtx).pop('save'),
              child: const Text('保存して閉じる'),
            ),
          ],
        ),
      );
    }

    bool isDirty() => _controller.text != _lastSavedText;

    Future<void> handleCloseRequest() async {
      if (_isSaving) return;
      if (_closing) return;
      _closing = true;
      if (!isDirty()) {
        Navigator.of(context).pop();
        _closing = false;
        return;
      }
      final choice = await confirmCloseChoice();
      if (!mounted) return;
      if (choice == 'discard') {
        Navigator.of(context).pop();
      } else if (choice == 'save') {
        await _handleSave(closeAfter: true);
      } else {
        // cancel -> stay
      }
      _closing = false;
    }

    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) {
        if (didPop) return;
        // ignore: unawaited_futures
        handleCloseRequest();
      },
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.keyS, control: true):
              saveAndContinue,
          const SingleActivator(LogicalKeyboardKey.keyS, meta: true):
              saveAndContinue,
        },
        child: Focus(
          autofocus: widget.autofocus,
          child: Scaffold(
            appBar: AppBar(
              title: const Text('コメント'),
              leading: IconButton(
                icon: const Icon(Icons.close),
                tooltip: '閉じる',
                onPressed:
                    _isSaving ? null : () => unawaited(handleCloseRequest()),
              ),
              actions: [
                TextButton(
                  onPressed: _isSaving
                      ? null
                      : () => unawaited(_handleSave(closeAfter: true)),
                  child: _isSaving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('保存'),
                ),
              ],
            ),
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        expands: true,
                        maxLines: null,
                        minLines: null,
                        textAlignVertical: TextAlignVertical.top,
                        keyboardType: TextInputType.multiline,
                        style: const TextStyle(height: 1.0),
                        scrollPadding: _commentEditorScrollPadding(context),
                        decoration: const InputDecoration(
                          hintText: 'コメントを入力...',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Ctrl+S / Cmd+S で画面を閉じずに保存できます',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.color
                                ?.withOpacity(0.7),
                          ),
                    ),
                    if (_feedbackMessage != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _feedbackMessage!,
                        style: TextStyle(
                          fontSize: 12,
                          color: _feedbackIsError
                              ? Theme.of(context).colorScheme.error
                              : Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// インボックスタスク用のメモ編集ダイアログを表示します。
/// 後方互換性のため、内部で汎用のshowMemoEditorDialogを使用します。
Future<void> showInboxMemoEditorDialog(
  BuildContext context,
  inbox.InboxTask task, {
  bool autofocus = true,
}) async {
  final provider = context.read<TaskProvider>();
  
  await showMemoEditorDialog(
    context: context,
    initialValue: task.memo,
    onSave: (memoValue) async {
      final updated = task.copyWith(
        memo: memoValue,
        lastModified: DateTime.now(),
        version: task.version + 1,
      );
      await provider.updateInboxTask(updated);
    },
    autofocus: autofocus,
  );
}
