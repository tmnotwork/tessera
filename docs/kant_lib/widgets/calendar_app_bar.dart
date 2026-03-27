// ignore_for_file: deprecated_member_use

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'calendar_settings.dart';

class CalendarAppBar extends StatelessWidget implements PreferredSizeWidget {
  final bool showTimeline;
  final DateTime? selectedDate;
  final DateTime focusedDate;
  final CalendarSettings settings;
  final VoidCallback onBackToCalendar;
  final VoidCallback onGoToToday;
  final VoidCallback onPreviousDay;
  final VoidCallback onNextDay;
  final VoidCallback onShowSettings;
  final GlobalKey<ScaffoldState>? scaffoldKey;

  const CalendarAppBar({
    super.key,
    required this.showTimeline,
    required this.selectedDate,
    required this.focusedDate,
    required this.settings,
    required this.onBackToCalendar,
    required this.onGoToToday,
    required this.onPreviousDay,
    required this.onNextDay,
    required this.onShowSettings,
    this.scaffoldKey,
  });

  @override
  Widget build(BuildContext context) {
    // テーマの primary 色を使用（テーマ切替に追従）
    final bg = Theme.of(context).colorScheme.primary;
    final onBg = ThemeData.estimateBrightnessForColor(bg) == Brightness.dark
        ? Colors.white
        : Colors.black;
    return AppBar(
      title: _buildTitle(context, onBg: onBg),
      backgroundColor: bg,
      foregroundColor: onBg,
      iconTheme: IconThemeData(color: onBg),
      actionsIconTheme: IconThemeData(color: onBg),
      leading: _buildLeading(context),
      actions: _buildActions(),
    );
  }

  Widget _buildTitle(BuildContext context, {required Color onBg}) {
    if (showTimeline) {
      final TextStyle titleStyle =
          (Theme.of(context).textTheme.titleMedium ?? const TextStyle())
              .copyWith(color: onBg, fontWeight: FontWeight.w600);
      // 日付と左右移動はタイムライン本体側へ移動し、AppBarは固定タイトルにする
      return Text('タイムライン', style: titleStyle);
    }

    return Text(
      '${focusedDate.year}年${focusedDate.month}月',
      style: TextStyle(color: onBg),
    );
  }

  Widget? _buildLeading(BuildContext context) {
    if (showTimeline) {
      return IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: onBackToCalendar,
        tooltip: 'カレンダーに戻る',
      );
    } else {
      return IconButton(
        icon: const Icon(Icons.menu),
        onPressed: () {
          scaffoldKey?.currentState?.openDrawer();
        },
        tooltip: 'メニュー',
      );
    }
  }

  List<Widget> _buildActions() {
    if (!showTimeline) {
      return [
        IconButton(icon: const Icon(Icons.today), onPressed: onGoToToday),
        IconButton(icon: const Icon(Icons.settings), onPressed: onShowSettings),
      ];
    }

    return [
      IconButton(
        icon: const Icon(Icons.today),
        onPressed: onGoToToday,
        tooltip: '今日',
      ),
    ];
  }

  Widget _buildTimelineNavButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      icon: Icon(icon),
      tooltip: tooltip,
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
    );
  }

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
}
