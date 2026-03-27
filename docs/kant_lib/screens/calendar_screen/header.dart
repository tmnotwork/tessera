import 'package:flutter/material.dart';
import '../../widgets/calendar_settings.dart';
import 'header_left_controls.dart';
import 'header_right_view_switch.dart';

class CalendarHeader extends StatelessWidget {
  final CalendarViewType viewType;
  final DateTime focusedDate;
  final bool useDualLaneDayView;
  final bool hasSelectedDateInDay;
  final bool showEventsOnly;
  final Future<void> Function() onPrevPeriod;
  final Future<void> Function() onNextPeriod;
  final Future<void> Function(CalendarViewType next) onChangeView;
  final ValueChanged<bool> onDualLaneChanged;
  final ValueChanged<bool> onShowEventsOnlyChanged;
  /// false のとき「表示切替」（日/週/月/年）を表示しない
  final bool showViewSwitch;

  const CalendarHeader({
    super.key,
    required this.viewType,
    required this.focusedDate,
    required this.useDualLaneDayView,
    required this.hasSelectedDateInDay,
    required this.showEventsOnly,
    required this.onPrevPeriod,
    required this.onNextPeriod,
    required this.onChangeView,
    required this.onDualLaneChanged,
    required this.onShowEventsOnlyChanged,
    this.showViewSwitch = true,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: CalendarHeaderLeftControls(
              viewType: viewType,
              focusedDate: focusedDate,
              useDualLaneDayView: useDualLaneDayView,
              onDualLaneChanged: onDualLaneChanged,
              showEventsOnly: showEventsOnly,
              onShowEventsOnlyChanged: onShowEventsOnlyChanged,
              onPrevPeriod: onPrevPeriod,
              onNextPeriod: onNextPeriod,
            ),
          ),
          if (showViewSwitch) ...[
            const SizedBox(width: 12),
            CalendarHeaderRightViewSwitch(
              currentViewType: viewType,
              hasSelectedDateInDay: hasSelectedDateInDay,
              onChangeView: onChangeView,
            ),
          ],
        ],
      ),
    );
  }
}

