import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../providers/task_provider.dart';
import '../../utils/ime_safe_dialog.dart';

class AddTaskDialog extends StatefulWidget {
  final DateTime selectedDate;
  final TaskProvider taskProvider;

  const AddTaskDialog({
    super.key,
    required this.selectedDate,
    required this.taskProvider,
  });

  @override
  State<AddTaskDialog> createState() => _AddTaskDialogState();
}

class _AddTaskDialogState extends State<AddTaskDialog> {
  final _titleController = TextEditingController();
  final _memoController = TextEditingController();
  final _titleFocusNode = FocusNode(debugLabel: 'add_task_title');
  DateTime? _selectedDueDate;
  String? _selectedProjectId;

  bool get _isDirty {
    return _titleController.text.trim().isNotEmpty ||
        _memoController.text.trim().isNotEmpty ||
        _selectedDueDate != null ||
        (_selectedProjectId != null && _selectedProjectId!.isNotEmpty);
  }

  Future<bool> _confirmDiscardIfNeeded() async {
    if (!_isDirty) return true;
    final result = await showImeSafeDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('確認'),
        content: const Text('編集中です。内容を破棄しますか。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('破棄する'),
          ),
        ],
      ),
    );
    return result == true;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      FocusScope.of(context).requestFocus(_titleFocusNode);
    });
  }

  @override
  void dispose() {
    _titleController.dispose();
    _memoController.dispose();
    _titleFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // AlertDialog は中身の“文章幅”に引っ張られて極端に細くなることがあるため、
    // ここで明示的に幅を与えて編集欄を常に広く表示する。
    final mq = MediaQuery.of(context);
    final screenWidth = mq.size.width;
    final screenHeight = mq.size.height;
    final isPhoneLike = mq.size.shortestSide < 600;
    final available = (screenWidth - 48).clamp(0.0, double.infinity);
    double targetWidth = screenWidth >= 1200 ? 720 : 600;
    if (targetWidth > available) targetWidth = available;
    if (targetWidth < 360) targetWidth = 360;

    return CallbackShortcuts(
      bindings: {
        SingleActivator(LogicalKeyboardKey.keyS, control: true): _addTask,
      },
      child: Focus(
        autofocus: true,
        child: WillPopScope(
          onWillPop: () async {
            return await _confirmDiscardIfNeeded();
          },
          child: AlertDialog(
            title: const Text('新しいタスクを追加'),
            // スマホでは「ダイアログだがほぼフル画面」に寄せる（余白を最小化）
            insetPadding: isPhoneLike
                ? const EdgeInsets.symmetric(horizontal: 8, vertical: 8)
                : const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
            content: SizedBox(
              width: targetWidth,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  // スマホでは高さも大きく確保して「ほぼフル画面」感を出す
                  maxHeight: isPhoneLike
                      ? (screenHeight - 200).clamp(260.0, double.infinity)
                      : double.infinity,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: _titleController,
                        focusNode: _titleFocusNode,
                        decoration: const InputDecoration(
                          labelText: 'タスク名',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _memoController,
                        decoration: const InputDecoration(
                          labelText: 'メモ',
                          border: OutlineInputBorder(),
                        ),
                        maxLines: 2,
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: TextButton.icon(
                              onPressed: () async {
                                final picked = await showDatePicker(
                                  context: context,
                                  initialDate: _selectedDueDate ?? DateTime.now(),
                                  firstDate: DateTime.now(),
                                  lastDate: DateTime.now()
                                      .add(const Duration(days: 365)),
                                );
                                if (picked != null) {
                                  setState(() {
                                    _selectedDueDate = picked;
                                  });
                                }
                              },
                              icon: const Icon(Icons.calendar_today),
                              label: Text(
                                _selectedDueDate != null
                                    ? '期限: ${_selectedDueDate!.month}/${_selectedDueDate!.day}'
                                    : '期限を設定',
                              ),
                            ),
                          ),
                          if (_selectedDueDate != null)
                            IconButton(
                              onPressed: () {
                                setState(() {
                                  _selectedDueDate = null;
                                });
                              },
                              icon: const Icon(Icons.clear),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () async {
                  final ok = await _confirmDiscardIfNeeded();
                  if (!ok) return;
                  if (!mounted) return;
                  Navigator.of(context).pop();
                },
                child: const Text('キャンセル'),
              ),
              ElevatedButton(onPressed: _addTask, child: const Text('追加')),
            ],
          ),
        ),
      ),
    );
  }

  void _addTask() async {
    if (_titleController.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('タスク名を入力してください')));
      return;
    }

    try {
      // タイムラインから追加したタスクは「今日の現時刻」を開始時刻として持たせ、
      // そのままタイムラインに表示される（時間ありInbox）ようにする。
      //
      // NOTE: インボックス側の追加は従来通り「開始時刻は後で選ぶ」ため、
      // ここ（タイムライン追加の導線）でのみ startHour/startMinute を入れる。
      final now = DateTime.now();

      // インボックスタスクとして追加
      await widget.taskProvider.createTaskForInbox(
        title: _titleController.text.trim(),
        memo: _memoController.text.trim().isEmpty
            ? null
            : _memoController.text.trim(),
        dueDate: _selectedDueDate,
        projectId: _selectedProjectId,
        executionDate: now,
        startHour: now.hour,
        startMinute: now.minute,
      );

      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('タスクを追加しました')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('タスク追加エラー: $e')));
      }
    }
  }
}
