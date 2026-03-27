import 'package:flutter/material.dart';
import '../services/app_settings_service.dart';
import '../services/calendar_service.dart';

class CalendarSettingsPanel extends StatefulWidget {
  const CalendarSettingsPanel({super.key});

  @override
  State<CalendarSettingsPanel> createState() => _CalendarSettingsPanelState();
}

class _CalendarSettingsPanelState extends State<CalendarSettingsPanel> {
  int _reminderMinutes = 10;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await AppSettingsService.initialize();
    final currentStr = AppSettingsService.getString(
        AppSettingsService.keyCalendarEventReminderMinutes);
    setState(() {
      _reminderMinutes = int.tryParse(currentStr ?? '') ?? 10;
      _initialized = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'カレンダー設定',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
          const SizedBox(height: 16),
          // 週の開始曜日
          const Row(
            children: [
              Icon(Icons.date_range, size: 18),
              SizedBox(width: 8),
              Expanded(
                child: Text('週の開始曜日', style: TextStyle(fontSize: 13)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ValueListenableBuilder<String>(
            valueListenable: AppSettingsService.weekStartNotifier,
            builder: (context, weekStart, _) {
              final String current = weekStart.isEmpty ? 'sunday' : weekStart;
              const options = <Map<String, String>>[
                {'key': 'sunday', 'label': '日'},
                {'key': 'monday', 'label': '月'},
                {'key': 'tuesday', 'label': '火'},
                {'key': 'wednesday', 'label': '水'},
                {'key': 'thursday', 'label': '木'},
                {'key': 'friday', 'label': '金'},
                {'key': 'saturday', 'label': '土'},
              ];
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                children: options.map((opt) {
                  final key = opt['key']!;
                  final label = opt['label']!;
                  return ChoiceChip(
                    label: Text(label),
                    selected: current == key,
                    onSelected: (_) async {
                      await AppSettingsService.setString(
                          AppSettingsService.keyCalendarWeekStart, key);
                    },
                  );
                }).toList(),
              );
            },
          ),
          const SizedBox(height: 16),
          const Row(
            children: [
              Icon(Icons.notifications_active, size: 18),
              SizedBox(width: 8),
              Expanded(
                child: Text('イベント通知タイミング', style: TextStyle(fontSize: 13)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (!_initialized)
            const SizedBox(
                height: 28,
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <int>[0, 5, 10, 15, 30, 60].map((m) {
                return ChoiceChip(
                  label: Text(m == 0 ? '通知なし' : '${m}分前'),
                  selected: _reminderMinutes == m,
                  onSelected: (_) async {
                    await AppSettingsService.setString(
                        AppSettingsService.keyCalendarEventReminderMinutes,
                        m.toString());
                    setState(() => _reminderMinutes = m);
                  },
                );
              }).toList(),
            ),
          const SizedBox(height: 16),
          // デフォルト表示の選択（年/月/週/日）
          const Row(
            children: [
              Icon(Icons.tune, size: 18),
              SizedBox(width: 8),
              Expanded(
                child: Text('デフォルト表示', style: TextStyle(fontSize: 13)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          FutureBuilder<void>(
            future: AppSettingsService.initialize(),
            builder: (context, snapshot) {
              final current = AppSettingsService.getString(
                      AppSettingsService.keyCalendarDefaultViewType) ??
                  'month';
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('年'),
                    selected: current == 'year',
                    onSelected: (_) async {
                      await AppSettingsService.setString(
                          AppSettingsService.keyCalendarDefaultViewType,
                          'year');
                    },
                  ),
                  ChoiceChip(
                    label: const Text('月'),
                    selected: current == 'month',
                    onSelected: (_) async {
                      await AppSettingsService.setString(
                          AppSettingsService.keyCalendarDefaultViewType,
                          'month');
                    },
                  ),
                  ChoiceChip(
                    label: const Text('週'),
                    selected: current == 'week',
                    onSelected: (_) async {
                      await AppSettingsService.setString(
                          AppSettingsService.keyCalendarDefaultViewType,
                          'week');
                    },
                  ),
                  ChoiceChip(
                    label: const Text('日'),
                    selected: current == 'day',
                    onSelected: (_) async {
                      await AppSettingsService.setString(
                          AppSettingsService.keyCalendarDefaultViewType, 'day');
                    },
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 16),
          ValueListenableBuilder<bool>(
            valueListenable: AppSettingsService.mobileDayUseGridNotifier,
            builder: (context, useGrid, _) => Row(
              children: [
                const Text('モバイル日表示: '),
                Switch(
                  value: useGrid,
                  onChanged: (v) async => AppSettingsService.setBool(
                      AppSettingsService.keyMobileDayUseGrid, v),
                ),
                Text(useGrid ? 'グリッド' : 'カード'),
              ],
            ),
          ),
          const SizedBox(height: 12),
          ValueListenableBuilder<int>(
            valueListenable: AppSettingsService.mobileDayGridWhichNotifier,
            builder: (context, which, _) => Row(
              children: [
                const Text('グリッド表示: '),
                const SizedBox(width: 8),
                ChoiceChip(
                  selected: which == 0,
                  label: const Text('予定'),
                  onSelected: (_) => AppSettingsService.setString(
                      AppSettingsService.keyMobileDayGridWhich, '0'),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  selected: which == 1,
                  label: const Text('実績'),
                  onSelected: (_) => AppSettingsService.setString(
                      AppSettingsService.keyMobileDayGridWhich, '1'),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  selected: which == 2,
                  label: const Text('両方'),
                  onSelected: (_) => AppSettingsService.setString(
                      AppSettingsService.keyMobileDayGridWhich, '2'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Icon(Icons.event, size: 18),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('イベントのみ表示', style: TextStyle(fontSize: 13)),
              ),
              ValueListenableBuilder<bool>(
                valueListenable:
                    AppSettingsService.calendarShowEventsOnlyNotifier,
                builder: (context, value, _) => Switch(
                  value: value,
                  onChanged: (v) => AppSettingsService.setBool(
                      AppSettingsService.keyCalendarShowEventsOnly, v),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
              Row(
                children: [
                  const Icon(Icons.calendar_view_month, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('月表示: ルーティン（インボックス未割当）を非表示',
                            style: TextStyle(fontSize: 13)),
                        const SizedBox(height: 2),
                        Text('ルーティン由来かつインボックス未割当の予定を月表示で隠す',
                            style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            )),
                      ],
                    ),
                  ),
                  ValueListenableBuilder<bool>(
                    valueListenable: CalendarService.hideRoutineNotifier,
                    builder: (context, value, _) => Switch(
                      value: value,
                      onChanged: (v) =>
                          CalendarService.setHideRoutineBlocksWithoutInboxInMonth(
                              v),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
