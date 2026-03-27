import 'package:flutter/material.dart';

class AppBottomNavigationBar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;

  const AppBottomNavigationBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return BottomNavigationBar(
      backgroundColor: Theme.of(context).bottomNavigationBarTheme.backgroundColor,
      selectedItemColor: Theme.of(context).bottomNavigationBarTheme.selectedItemColor,
      unselectedItemColor: Theme.of(context).bottomNavigationBarTheme.unselectedItemColor,
      currentIndex: currentIndex,
      onTap: onTap,
      type: BottomNavigationBarType.fixed,
      items: const [
        BottomNavigationBarItem(icon: Icon(Icons.timeline), label: 'タイムライン'),
        BottomNavigationBarItem(icon: Icon(Icons.inbox), label: 'インボックス'),
        BottomNavigationBarItem(
          icon: Icon(Icons.calendar_month),
          label: 'カレンダー',
        ),
        BottomNavigationBarItem(icon: Icon(Icons.schedule), label: 'ルーティン'),
        BottomNavigationBarItem(icon: Icon(Icons.folder), label: 'プロジェクト'),
      ],
    );
  }
}
