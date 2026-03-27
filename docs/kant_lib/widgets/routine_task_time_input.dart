import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/routine_shortcut_task_row.dart';

class RoutineTaskTimeInput extends StatefulWidget {
  final RoutineShortcutTaskRow task;
  final void Function() onTimeChanged;

  const RoutineTaskTimeInput({
    super.key,
    required this.task,
    required this.onTimeChanged,
  });

  @override
  State<RoutineTaskTimeInput> createState() => _RoutineTaskTimeInputState();
}

class _RoutineTaskTimeInputState extends State<RoutineTaskTimeInput> {
  final FocusNode _startTimeFocusNode = FocusNode();
  final FocusNode _endTimeFocusNode = FocusNode();
  final TextEditingController _startTimeController = TextEditingController();
  final TextEditingController _endTimeController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _updateTimeControllers();

    // フォーカスリスナーを設定
    _startTimeFocusNode.addListener(() {
      if (_startTimeFocusNode.hasFocus) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_startTimeController.text.isNotEmpty) {
            _startTimeController.selection = TextSelection(
              baseOffset: 0,
              extentOffset: _startTimeController.text.length,
            );
          }
        });
      }
    });

    _endTimeFocusNode.addListener(() {
      if (_endTimeFocusNode.hasFocus) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_endTimeController.text.isNotEmpty) {
            _endTimeController.selection = TextSelection(
              baseOffset: 0,
              extentOffset: _endTimeController.text.length,
            );
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _startTimeFocusNode.dispose();
    _endTimeFocusNode.dispose();
    _startTimeController.dispose();
    _endTimeController.dispose();
    super.dispose();
  }

  void _updateTimeControllers() {
    _startTimeController.text =
        '${widget.task.startTime.hour.toString().padLeft(2, '0')}:${widget.task.startTime.minute.toString().padLeft(2, '0')}';
    _endTimeController.text =
        '${widget.task.endTime.hour.toString().padLeft(2, '0')}:${widget.task.endTime.minute.toString().padLeft(2, '0')}';
  }

  String _formatTime(String digits) {
    String formatted = '';
    if (digits.isNotEmpty) {
      formatted += digits[0];
    }
    if (digits.length >= 2) {
      formatted += digits[1];
      if (digits.length >= 3) {
        formatted += ':';
        formatted += digits[2];
      }
    }
    if (digits.length >= 4) {
      formatted += digits[3];
    }
    return formatted;
  }

  void _handleStartTimeChanged(String value) {
    final digitsOnly = value.replaceAll(RegExp(r'[^0-9]'), '');

    if (digitsOnly.length > 4) {
      final newDigits = digitsOnly.substring(digitsOnly.length - 4);
      _startTimeController.text = _formatTime(newDigits);
      _startTimeController.selection = TextSelection(
        baseOffset: _startTimeController.text.length,
        extentOffset: _startTimeController.text.length,
      );
      return;
    }

    if (digitsOnly.length <= 4) {
      final formatted = _formatTime(digitsOnly);
      if (formatted != _startTimeController.text) {
        _startTimeController.text = formatted;
        _startTimeController.selection = TextSelection(
          baseOffset: _startTimeController.text.length,
          extentOffset: _startTimeController.text.length,
        );
      }

      if (digitsOnly.length == 4) {
        final hour = int.tryParse(digitsOnly.substring(0, 2));
        final minute = int.tryParse(digitsOnly.substring(2, 4));
        if (hour != null &&
            minute != null &&
            hour >= 0 &&
            hour <= 23 &&
            minute >= 0 &&
            minute <= 59) {
          final time = TimeOfDay(hour: hour, minute: minute);
          widget.task.startTime = time;
          _endTimeFocusNode.requestFocus();
          setState(() {});
          widget.onTimeChanged();
        }
      }
    }
  }

  void _handleEndTimeChanged(String value) {
    final digitsOnly = value.replaceAll(RegExp(r'[^0-9]'), '');

    if (digitsOnly.length > 4) {
      final newDigits = digitsOnly.substring(digitsOnly.length - 4);
      _endTimeController.text = _formatTime(newDigits);
      _endTimeController.selection = TextSelection(
        baseOffset: _endTimeController.text.length,
        extentOffset: _endTimeController.text.length,
      );
      return;
    }

    if (digitsOnly.length <= 4) {
      final formatted = _formatTime(digitsOnly);
      if (formatted != _endTimeController.text) {
        _endTimeController.text = formatted;
        _endTimeController.selection = TextSelection(
          baseOffset: _endTimeController.text.length,
          extentOffset: _endTimeController.text.length,
        );
      }

      if (digitsOnly.length == 4) {
        final hour = int.tryParse(digitsOnly.substring(0, 2));
        final minute = int.tryParse(digitsOnly.substring(2, 4));
        if (hour != null &&
            minute != null &&
            hour >= 0 &&
            hour <= 23 &&
            minute >= 0 &&
            minute <= 59) {
          final time = TimeOfDay(hour: hour, minute: minute);
          widget.task.endTime = time;
          setState(() {});
          widget.onTimeChanged();
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 36,
      child: Container(
        height: 36,
        child: Row(
          children: [
            FocusTraversalOrder(
              order: const NumericFocusOrder(1.1),
              child: Expanded(
                child: Container(
                  height: 36,
                  child: TextField(
                    controller: _startTimeController,
                    focusNode: _startTimeFocusNode,
                    style: const TextStyle(fontSize: 12, height: 1.0),
                    textAlign: TextAlign.center,
                    textAlignVertical: TextAlignVertical.center,
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      isCollapsed: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 4.0, vertical: 16.0),
                      filled: true,
                      fillColor:
                          Theme.of(context).inputDecorationTheme.fillColor ??
                              Theme.of(context).colorScheme.surface,
                      constraints:
                          const BoxConstraints(minHeight: 36, maxHeight: 36),
                      hintText: 'HH:MM',
                      hintStyle: TextStyle(
                          fontSize: 12, color: Theme.of(context).hintColor),
                    ),
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.next,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(4),
                    ],
                    onChanged: _handleStartTimeChanged,
                    onSubmitted: (_) {
                      // 終了時刻フィールドにフォーカスを移動
                      _endTimeFocusNode.requestFocus();
                    },
                  ),
                ),
              ),
            ),
            SizedBox(
              width: 16,
              child: Container(
                height: 36,
                color: Theme.of(context).inputDecorationTheme.fillColor ??
                    Theme.of(context).colorScheme.surface,
                alignment: Alignment.center,
                child: Text('～',
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).textTheme.bodySmall?.color)),
              ),
            ),
            FocusTraversalOrder(
              order: const NumericFocusOrder(1.2),
              child: Expanded(
                child: Container(
                  height: 36,
                  child: TextField(
                    controller: _endTimeController,
                    focusNode: _endTimeFocusNode,
                    style: const TextStyle(fontSize: 12, height: 1.0),
                    textAlign: TextAlign.center,
                    textAlignVertical: TextAlignVertical.center,
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      isCollapsed: true,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 4.0, vertical: 16.0),
                      filled: true,
                      fillColor:
                          Theme.of(context).inputDecorationTheme.fillColor ??
                              Theme.of(context).colorScheme.surface,
                      constraints: const BoxConstraints(minHeight: 36, maxHeight: 36),
                      hintText: 'HH:MM',
                      hintStyle: TextStyle(
                          fontSize: 12, color: Theme.of(context).hintColor),
                    ),
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.next,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(4),
                    ],
                    onChanged: _handleEndTimeChanged,
                    onSubmitted: (_) {
                      // 次のフィールド（ブロック名）にフォーカスを移動
                      FocusScope.of(context).nextFocus();
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
