import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../widgets/block_editor/block_editor_form.dart';

/// `BlockEditorForm` を「タイムライン準拠の見た目（AppBar + Close + FAB）」で包む共通ページ。
///
/// 入口（カレンダー/タイムライン）に依存せず、見た目を完全一致させるためのラッパー。
class BlockEditorPage extends StatefulWidget {
  final String title;
  final String primaryActionLabel;
  final String? deleteConfirmMessage;
  final Future<void> Function(BlockEditorResult result) onPrimary;
  final Future<void> Function()? onDelete;

  // Form initial values
  final DateTime initialStartDate;
  final TimeOfDay initialStartTime;
  final DateTime initialEndDate;
  final TimeOfDay initialEndTime;
  final int initialBreakMinutes;
  final bool initialIsEvent;
  final bool initialAllDay;
  final bool allowAllDay;
  final bool initialExcludeFromReport;
  final String initialTitle;
  final bool allowEditTitle;
  final String? initialBlockName;
  final String? initialMemo;
  final String? initialLocation;
  final String? initialProjectId;
  final String? initialProjectName;
  final String? initialSubProjectId;
  final String? initialSubProjectName;
  final String? initialModeId;
  final String? initialModeName;

  /// true の場合、表示直後に「ブロック名」へフォーカスする。
  final bool autofocusBlockName;

  const BlockEditorPage({
    super.key,
    required this.title,
    required this.primaryActionLabel,
    required this.onPrimary,
    this.onDelete,
    this.deleteConfirmMessage,
    required this.initialStartDate,
    required this.initialStartTime,
    required this.initialEndDate,
    required this.initialEndTime,
    required this.initialBreakMinutes,
    required this.initialIsEvent,
    required this.initialAllDay,
    this.allowAllDay = true,
    this.initialExcludeFromReport = false,
    required this.initialTitle,
    required this.allowEditTitle,
    this.initialBlockName,
    this.initialMemo,
    this.initialLocation,
    this.initialProjectId,
    this.initialProjectName,
    this.initialSubProjectId,
    this.initialSubProjectName,
    this.initialModeId,
    this.initialModeName,
    this.autofocusBlockName = false,
  });

  @override
  State<BlockEditorPage> createState() => _BlockEditorPageState();
}

class _BlockEditorPageState extends State<BlockEditorPage> {
  final GlobalKey<BlockEditorFormState> _formKey =
      GlobalKey<BlockEditorFormState>();

  Future<void> _confirmAndDelete(BuildContext context) async {
    if (widget.onDelete == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('削除の確認'),
        content: Text(widget.deleteConfirmMessage ?? 'このブロックを削除しますか？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('キャンセル')),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.onDelete!.call();
    if (context.mounted) {
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _handlePrimary(BuildContext context) async {
    final r = _formKey.currentState?.buildResultOrShowError(context);
    if (r == null) return;
    await widget.onPrimary(r);
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        SingleActivator(LogicalKeyboardKey.keyS, control: true): () {
          _handlePrimary(context);
        },
      },
      child: Focus(
          autofocus: true,
          child: Scaffold(
            appBar: AppBar(
              title: Text(widget.title),
              leading: IconButton(
                tooltip: '閉じる',
                icon: const Icon(Icons.close),
                // 呼び出し元が `push<T>()` しているケースがあるため、
                // 型不一致を避けるために cancel は常に null を返す。
                onPressed: () => Navigator.of(context).pop(null),
              ),
              actions: [
                if (widget.onDelete != null)
                  IconButton(
                    tooltip: '削除',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _confirmAndDelete(context),
                  ),
              ],
            ),
            body: SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
                    child: BlockEditorForm(
                      key: _formKey,
                      initialStartDate: widget.initialStartDate,
                      initialStartTime: widget.initialStartTime,
                      initialEndDate: widget.initialEndDate,
                      initialEndTime: widget.initialEndTime,
                      initialBreakMinutes: widget.initialBreakMinutes,
                      initialIsEvent: widget.initialIsEvent,
                      initialAllDay:
                          widget.allowAllDay ? widget.initialAllDay : false,
                      allowAllDay: widget.allowAllDay,
                      initialExcludeFromReport: widget.initialExcludeFromReport,
                      initialTitle: widget.initialTitle,
                      allowEditTitle: widget.allowEditTitle,
                      initialBlockName: widget.initialBlockName,
                      initialMemo: widget.initialMemo,
                      initialLocation: widget.initialLocation,
                      initialProjectId: widget.initialProjectId,
                      initialProjectName: widget.initialProjectName,
                      initialSubProjectId: widget.initialSubProjectId,
                      initialSubProjectName: widget.initialSubProjectName,
                      initialModeId: widget.initialModeId,
                      initialModeName: widget.initialModeName,
                      autofocusBlockName: widget.autofocusBlockName,
                    ),
                  ),
                ),
              ),
            ),
            floatingActionButton: FloatingActionButton.extended(
              onPressed: () async {
                await _handlePrimary(context);
              },
              icon: const Icon(Icons.save),
              label: Text(widget.primaryActionLabel),
            ),
          ),
        ),
    );
  }
}

