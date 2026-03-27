import 'package:flutter/material.dart';

class WeekHeaderRow extends StatelessWidget {
  final List<DateTime> days;
  final double dayColWidth;
  final int? hoveredIndex;
  final void Function(int) onHoverChanged;
  final void Function(int) onTapDay;

  const WeekHeaderRow({
    super.key,
    required this.days,
    required this.dayColWidth,
    required this.hoveredIndex,
    required this.onHoverChanged,
    required this.onTapDay,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (int d = 0; d < 7; d++)
          MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => onHoverChanged(d),
            onExit: (_) => onHoverChanged(-1),
            child: GestureDetector(
              onTap: () => onTapDay(d),
              child: Container(
                width: dayColWidth,
                height: 36,
                padding: const EdgeInsets.only(top: 2),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      const ['日', '月', '火', '水', '木', '金', '土'][d],
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: hoveredIndex == d
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).textTheme.bodySmall?.color,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${days[d].month}/${days[d].day}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        decoration: hoveredIndex == d ? TextDecoration.underline : TextDecoration.none,
                        color: hoveredIndex == d ? Theme.of(context).colorScheme.primary : null,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}