import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../utils/ime_safe_dialog.dart';

class AddEventDialogResult {
  final DateTime selectedDate;
  final TimeOfDay startTime;
  final int estimatedMinutes;
  final String? blockName;
  final String? details;
  final String? memo;
  const AddEventDialogResult({
    required this.selectedDate,
    required this.startTime,
    required this.estimatedMinutes,
    this.blockName,
    this.details,
    this.memo,
  });
}

const int _maxPlannedTimedMinutes = 48 * 60;

Future<AddEventDialogResult?> showAddEventDialog({
  required BuildContext context,
  required DateTime initialDate,
  required TimeOfDay initialStart,
}) async {
  DateTime selectedDate = DateTime(initialDate.year, initialDate.month, initialDate.day);
  TimeOfDay start = initialStart;
  final durationController = TextEditingController(text: '');
  final endTimeController = TextEditingController(text: _fmtHHMM(_calcEndFromDuration(initialStart, 20)));
  final blockNameController = TextEditingController();
  final detailsController = TextEditingController();
  final memoController = TextEditingController();

  DateTime computedStartDateTime() => DateTime(
        selectedDate.year,
        selectedDate.month,
        selectedDate.day,
        start.hour,
        start.minute,
      );

  DateTime computedEndDateTime() {
    final minutes = int.tryParse(durationController.text.trim()) ?? 20;
    final normalized = minutes.clamp(1, _maxPlannedTimedMinutes);
    return computedStartDateTime().add(Duration(minutes: normalized));
  }

  void applyDurationClamp() {
    final minutes = int.tryParse(durationController.text.trim());
    if (minutes == null) return;
    final normalized = minutes.clamp(1, _maxPlannedTimedMinutes);
    if (normalized != minutes) {
      durationController.text = normalized.toString();
    }
  }

  final result = await showImeSafeDialog<bool>(
    context: context,
    builder: (ctx) {
      final screenWidth = MediaQuery.of(ctx).size.width;
      final available = (screenWidth - 48).clamp(0.0, double.infinity);
      double targetWidth = screenWidth >= 1200 ? 720 : 600;
      if (targetWidth > available) targetWidth = available;
      if (targetWidth < 420) targetWidth = 420;

      return CallbackShortcuts(
        bindings: {
          SingleActivator(LogicalKeyboardKey.keyS, control: true): () {
            Navigator.pop(ctx, true);
          },
        },
        child: Focus(
          autofocus: true,
          child: AlertDialog(
        title: const Text('新規イベントを追加'),
        content: SizedBox(
          width: targetWidth,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
              const Row(children: [
                Icon(Icons.event, size: 18),
                SizedBox(width: 8),
                Text('イベント')
              ]),
              const SizedBox(height: 8),
              // ブロック名（最上部に1行で表示）
              TextField(
                controller: blockNameController,
                decoration: const InputDecoration(
                    labelText: 'ブロック名', hintText: '任意', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: ctx,
                          initialDate: selectedDate,
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2030),
                        );
                        if (picked != null) {
                          selectedDate = picked;
                          (ctx as Element).markNeedsBuild();
                        }
                      },
                      child: InputDecorator(
                        decoration: const InputDecoration(labelText: '日付', border: OutlineInputBorder()),
                        child: Text('${selectedDate.year}/${selectedDate.month}/${selectedDate.day}'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: InkWell(
                      onTap: () async {
                        final picked = await showTimePicker(context: ctx, initialTime: start);
                        if (picked != null) {
                          start = picked;
                          (ctx as Element).markNeedsBuild();
                        }
                      },
                      child: InputDecorator(
                        decoration: const InputDecoration(labelText: '開始時刻', border: OutlineInputBorder()),
                        child: Text('${start.hour.toString().padLeft(2, '0')}:${start.minute.toString().padLeft(2, '0')}'),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: durationController,
                      decoration: const InputDecoration(
                          labelText: '所要時間(分)', hintText: '', border: OutlineInputBorder()),
                      keyboardType: TextInputType.number,
                      onChanged: (_) {
                        final mins = int.tryParse(durationController.text.trim());
                        if (mins != null && mins > 0) {
                          applyDurationClamp();
                          final normalized =
                              (int.tryParse(durationController.text.trim()) ?? mins)
                                  .clamp(1, _maxPlannedTimedMinutes);
                          final newEnd = _calcEndFromDuration(start, normalized);
                          endTimeController.text = _fmtHHMM(newEnd);
                        }
                        (ctx as Element).markNeedsBuild();
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: InkWell(
                      onTap: () async {
                        final picked =
                            await showTimePicker(context: ctx, initialTime: _parseHm(endTimeController.text) ?? start);
                        if (picked != null) {
                          endTimeController.text = _fmtHHMM(picked);
                          final diff = _diffMinutesAllowNextDay(start, picked);
                          durationController.text =
                              diff.clamp(1, _maxPlannedTimedMinutes).toString();
                          (ctx as Element).markNeedsBuild();
                        }
                      },
                      child: InputDecorator(
                        decoration: const InputDecoration(
                          labelText: '終了（算出）',
                          border: OutlineInputBorder(),
                        ),
                        child: Text(_fmtYmdHm(computedEndDateTime())),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: detailsController,
                decoration: const InputDecoration(labelText: '詳細', hintText: '', border: OutlineInputBorder()),
                keyboardType: TextInputType.multiline,
                textAlignVertical: TextAlignVertical.top,
                minLines: 4,
                maxLines: 10,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: memoController,
                decoration: const InputDecoration(labelText: 'メモ', hintText: '', border: OutlineInputBorder()),
                keyboardType: TextInputType.multiline,
                textAlignVertical: TextAlignVertical.top,
                minLines: 4,
                maxLines: 10,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('キャンセル')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('追加')),
      ],
          ),
        ),
      );
    },
  );

  if (result == true) {
    final minutes = int.tryParse(durationController.text.trim()) ?? 20;
    return AddEventDialogResult(
      selectedDate: selectedDate,
      startTime: start,
      estimatedMinutes: minutes.clamp(1, _maxPlannedTimedMinutes),
      blockName: blockNameController.text.trim().isEmpty ? null : blockNameController.text.trim(),
      details: detailsController.text.trim().isEmpty ? null : detailsController.text.trim(),
      memo: memoController.text.trim().isEmpty ? null : memoController.text.trim(),
    );
  }
  return null;
}

String _fmtHHMM(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

String _fmtYmdHm(DateTime dt) {
  final d = dt.toLocal();
  final y = d.year.toString().padLeft(4, '0');
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  final hh = d.hour.toString().padLeft(2, '0');
  final mm = d.minute.toString().padLeft(2, '0');
  return '$y/$m/$day $hh:$mm';
}

TimeOfDay _calcEndFromDuration(TimeOfDay start, int minutes) {
  final dt = DateTime(0, 1, 1, start.hour, start.minute).add(Duration(minutes: minutes));
  return TimeOfDay(hour: dt.hour, minute: dt.minute);
}

TimeOfDay? _parseHm(String text) {
  final parts = text.split(':');
  if (parts.length != 2) return null;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (h == null || m == null) return null;
  if (h < 0 || h > 23 || m < 0 || m > 59) return null;
  return TimeOfDay(hour: h, minute: m);
}

int _diffMinutesAllowNextDay(TimeOfDay start, TimeOfDay end) {
  final startMinutes = start.hour * 60 + start.minute;
  final endMinutes = end.hour * 60 + end.minute;
  var diff = endMinutes - startMinutes;
  if (endMinutes < startMinutes) {
    diff += 24 * 60;
  }
  return diff;
}