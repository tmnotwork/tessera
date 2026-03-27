import 'package:flutter/material.dart';
import '../services/calendar_service.dart';

class CalendarSettingsDialog extends StatefulWidget {
  const CalendarSettingsDialog({super.key});

  @override
  State<CalendarSettingsDialog> createState() => _CalendarSettingsDialogState();
}

class _CalendarSettingsDialogState extends State<CalendarSettingsDialog> {
  DateTime _selectedDate = DateTime.now();
  bool _isLoading = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('カレンダー設定'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('休日をカスタマイズ'),
          const SizedBox(height: 16),
          
          // 日付選択
          ListTile(
            title: Text('日付: ${_selectedDate.toIso8601String().substring(0, 10)}'),
            trailing: const Icon(Icons.calendar_today),
            onTap: () async {
              final date = await showDatePicker(
                context: context,
                initialDate: _selectedDate,
                firstDate: DateTime(2020),
                lastDate: DateTime(2030),
              );
              if (date != null) {
                setState(() {
                  _selectedDate = date;
                });
              }
            },
          ),
          
          const SizedBox(height: 16),
          
          // 休日設定ボタン
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: _isLoading ? null : () => _customizeHoliday(true),
                  child: const Text('休日に設定'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton(
                  onPressed: _isLoading ? null : () => _customizeHoliday(false),
                  child: const Text('平日に設定'),
                ),
              ),
            ],
          ),
          
          if (_isLoading)
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: CircularProgressIndicator(),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('閉じる'),
        ),
      ],
    );
  }

  Future<void> _customizeHoliday(bool isHoliday) async {
    setState(() {
      _isLoading = true;
    });

    try {
      await CalendarService.customizeHoliday(_selectedDate, isHoliday);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${_selectedDate.toIso8601String().substring(0, 10)} を${isHoliday ? '休日' : '平日'}に設定しました'
            ),
            backgroundColor: Theme.of(context).colorScheme.secondary,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('設定に失敗しました: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }
}
