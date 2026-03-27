import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class RoutineTaskTimeCell extends StatelessWidget {
  final TextEditingController startTimeController;
  final TextEditingController endTimeController;
  final FocusNode startTimeFocusNode;
  final FocusNode endTimeFocusNode;
  final void Function(String) onStartTimeChanged;
  final void Function(String) onEndTimeChanged;
  final void Function() onStartTimeTap;
  final void Function() onEndTimeTap;

  const RoutineTaskTimeCell({
    super.key,
    required this.startTimeController,
    required this.endTimeController,
    required this.startTimeFocusNode,
    required this.endTimeFocusNode,
    required this.onStartTimeChanged,
    required this.onEndTimeChanged,
    required this.onStartTimeTap,
    required this.onEndTimeTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 120,
      child: Container(
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          border: Border(right: BorderSide(color: Theme.of(context).dividerColor)),
        ),
        child: Row(
          children: [
            // 開始時刻
            Expanded(
              child: TextField(
                controller: startTimeController,
                focusNode: startTimeFocusNode,
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 8,
                  ),
                  border: InputBorder.none,
                  filled: true,
                  fillColor: Theme.of(context).inputDecorationTheme.fillColor ?? Theme.of(context).colorScheme.surface,
                  hintText: 'HH:MM',
                  hintStyle: TextStyle(fontSize: 10, color: Theme.of(context).hintColor),
                ),
                style: const TextStyle(fontSize: 12),
                textAlign: TextAlign.center,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.done,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(4),
                ],
                onChanged: onStartTimeChanged,
                onTap: onStartTimeTap,
              ),
            ),
            Text('~', style: TextStyle(fontSize: 12, color: Theme.of(context).textTheme.bodySmall?.color)),
            // 終了時刻
            Expanded(
              child: TextField(
                controller: endTimeController,
                focusNode: endTimeFocusNode,
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 8,
                  ),
                  border: InputBorder.none,
                  filled: true,
                  fillColor: Theme.of(context).inputDecorationTheme.fillColor ?? Theme.of(context).colorScheme.surface,
                  hintText: 'HH:MM',
                  hintStyle: TextStyle(fontSize: 10, color: Theme.of(context).hintColor),
                ),
                style: const TextStyle(fontSize: 12),
                textAlign: TextAlign.center,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.done,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(4),
                ],
                onChanged: onEndTimeChanged,
                onTap: onEndTimeTap,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
