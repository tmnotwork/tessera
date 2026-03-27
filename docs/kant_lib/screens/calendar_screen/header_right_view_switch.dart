import 'package:flutter/material.dart';
import '../../widgets/calendar_settings.dart';
import 'view_type_button.dart';

class CalendarHeaderRightViewSwitch extends StatelessWidget {
  final CalendarViewType currentViewType;
  final bool hasSelectedDateInDay;
  final Future<void> Function(CalendarViewType next) onChangeView;

  const CalendarHeaderRightViewSwitch({
    super.key,
    required this.currentViewType,
    required this.hasSelectedDateInDay,
    required this.onChangeView,
  });

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 800;
    if (isMobile) {
      // モバイルではAppBarに移動するためヘッダー側は非表示
      return const SizedBox.shrink();
    }
    // PCでは従来のボタン群
    return Row(
      children: [
        ViewTypeButton(
          label: '日',
          isSelected: currentViewType == CalendarViewType.day,
          onTap: () => onChangeView(CalendarViewType.day),
        ),
        const SizedBox(width: 8),
        ViewTypeButton(
          label: '週',
          isSelected: currentViewType == CalendarViewType.week,
          onTap: () => onChangeView(CalendarViewType.week),
        ),
        const SizedBox(width: 8),
        ViewTypeButton(
          label: '月',
          isSelected: currentViewType == CalendarViewType.month,
          onTap: () => onChangeView(CalendarViewType.month),
        ),
        const SizedBox(width: 8),
        ViewTypeButton(
          label: '年',
          isSelected: currentViewType == CalendarViewType.year,
          onTap: () => onChangeView(CalendarViewType.year),
        ),
        const SizedBox(width: 16),
      ],
    );
  }
}

