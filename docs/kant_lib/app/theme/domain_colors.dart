import 'package:flutter/material.dart';

/// Domain (data) colors.
///
/// These are NOT theme colors. They represent user/data-driven identifiers
/// (e.g. routine template colors) that can be persisted as hex strings.
///
/// Design direction:
/// - Unify the overall hue family (blue-ish) for a consistent look.
/// - Keep enough variation (tone/saturation) for distinguishability.
class DomainColors {
  DomainColors._();

  /// Default/fallback domain color (AARRGGBB hex string, with '#').
  static const String defaultHex = '#FF1E3A8A';

  /// Default routine template colors (persisted hex strings).
  ///
  /// Keep these in the same hue family (blue-ish).
  static const String weekdayTemplateHex = '#FF1E3A8A';
  static const String holidayTemplateHex = '#FF0EA5E9';

  /// A curated palette for routine/template color selection.
  ///
  /// Note: keep these within a single hue family as per design direction.
  static const List<Color> routineChoices = <Color>[
    Color(0xFF1E3A8A), // deep blue
    Color(0xFF1D4ED8), // vivid blue
    Color(0xFF2563EB), // blue
    Color(0xFF3B82F6), // light blue
    Color(0xFF0EA5E9), // sky
    Color(0xFF06B6D4), // cyan-ish (still within blue family)
    Color(0xFF4F46E5), // indigo
    Color(0xFF64748B), // blue-gray
    Color(0xFF334155), // slate
    Color(0xFF60A5FA), // pale blue
    Color(0xFF93C5FD), // very light blue
    Color(0xFF1F2937), // near-black slate (for labels)
  ];

  /// Apply day type colors (kept within blue family).
  static const Color applyDayWeekday = Color(0xFF1E3A8A);
  static const Color applyDayHoliday = Color(0xFF0EA5E9);
  static const Color applyDayBoth = Color(0xFF4F46E5);
}

