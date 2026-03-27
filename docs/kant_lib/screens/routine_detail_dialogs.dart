import 'package:flutter/material.dart';

import '../app/theme/app_color_tokens.dart';
import '../app/theme/domain_colors.dart';

class RoutineDetailDialogs {
  static void showApplyDayTypeSelectionDialog(
    BuildContext context,
    String currentApplyDayType,
    Function(String) onApplyDayTypeSelected,
  ) {
    showDialog(
      context: context,
      builder: (context) => _ApplyDayTypeSelectionDialog(
        initialApplyDayType: currentApplyDayType,
        onApplyDayTypeSelected: onApplyDayTypeSelected,
      ),
    );
  }

  static void showColorSelectionDialog(
    BuildContext context,
    Color currentColor,
    Function(Color) onColorSelected,
  ) {
    const List<Color> colors = DomainColors.routineChoices;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('色を選択'),
        content: SizedBox(
          width: double.maxFinite,
          child: GridView.builder(
            shrinkWrap: true,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            itemCount: colors.length,
            itemBuilder: (context, index) {
              final color = colors[index];
              final isSelected = color == currentColor;
              return GestureDetector(
                onTap: () {
                  onColorSelected(color);
                  Navigator.pop(context);
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: isSelected
                        ? Border.all(
                            color: AppColorTokens.of(context).selectionBorder,
                            width: 3,
                          )
                        : null,
                  ),
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('キャンセル'),
          ),
        ],
      ),
    );
  }

  static String getApplyDayTypeText(String applyDayType) {
    switch (applyDayType) {
      case 'weekday':
        return '平日';
      case 'holiday':
        return '休日';
      case 'both':
        return '平日・休日';
      default:
        return '平日・休日';
    }
  }
}

/// 適用日選択ダイアログ（選択状態を State で保持し、再ビルドでリセットされないようにする）
class _ApplyDayTypeSelectionDialog extends StatefulWidget {
  final String initialApplyDayType;
  final void Function(String) onApplyDayTypeSelected;

  const _ApplyDayTypeSelectionDialog({
    required this.initialApplyDayType,
    required this.onApplyDayTypeSelected,
  });

  @override
  State<_ApplyDayTypeSelectionDialog> createState() =>
      _ApplyDayTypeSelectionDialogState();
}

class _ApplyDayTypeSelectionDialogState
    extends State<_ApplyDayTypeSelectionDialog> {
  late String _selectedApplyDayType;

  @override
  void initState() {
    super.initState();
    _selectedApplyDayType = widget.initialApplyDayType;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('適用日を選択'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          RadioListTile<String>(
            title: const Text('平日'),
            subtitle: const Text('カレンダー設定の平日を参照（土日祝日以外）'),
            value: 'weekday',
            groupValue: _selectedApplyDayType,
            onChanged: (value) {
              if (value != null) {
                setState(() => _selectedApplyDayType = value);
              }
            },
          ),
          RadioListTile<String>(
            title: const Text('休日'),
            subtitle: const Text('カレンダー設定の休日を参照（土日祝日）'),
            value: 'holiday',
            groupValue: _selectedApplyDayType,
            onChanged: (value) {
              if (value != null) {
                setState(() => _selectedApplyDayType = value);
              }
            },
          ),
          RadioListTile<String>(
            title: const Text('平日・休日'),
            subtitle: const Text('毎日'),
            value: 'both',
            groupValue: _selectedApplyDayType,
            onChanged: (value) {
              if (value != null) {
                setState(() => _selectedApplyDayType = value);
              }
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        ElevatedButton(
          onPressed: () {
            widget.onApplyDayTypeSelected(_selectedApplyDayType);
            Navigator.pop(context);
          },
          child: const Text('OK'),
        ),
      ],
    );
  }
}
