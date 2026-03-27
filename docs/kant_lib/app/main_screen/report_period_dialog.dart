// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'report_period.dart';

Widget buildPeriodMenuItem({
  required ReportPeriod period,
  required ReportPeriod groupValue,
  required ValueChanged<ReportPeriod> onChanged,
  required Widget dateSelector,
}) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    child: Row(
      children: [
        Expanded(
          flex: 2,
          child: Row(
            children: [
              Radio<ReportPeriod>(
                value: period,
                groupValue: groupValue,
                onChanged: (val) {
                  if (val != null) onChanged(val);
                },
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      period.label,
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(flex: 3, child: dateSelector),
      ],
    ),
  );
}

Widget buildDateSelectorButton({
  required IconData icon,
  required String label,
  required VoidCallback onPressed,
}) {
  return OutlinedButton.icon(
    onPressed: onPressed,
    icon: Icon(icon, size: 16),
    label: Text(
      label,
      style: const TextStyle(fontSize: 12),
      overflow: TextOverflow.ellipsis,
    ),
    style: OutlinedButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      minimumSize: const Size(0, 32),
    ),
  );
}
