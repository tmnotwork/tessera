import 'package:flutter/material.dart';

/// App-specific color tokens that aren't well represented by Material's
/// built-in [ColorScheme] slots.
///
/// Keep this minimal: only add tokens that are reused across screens/widgets.
@immutable
class AppColorTokens extends ThemeExtension<AppColorTokens> {
  final Color dangerTint;
  final Color infoTint;
  final Color warningTint;
  final Color warning;
  final Color selectionBorder;
  final Color separatorSubtle;

  const AppColorTokens({
    required this.dangerTint,
    required this.infoTint,
    required this.warningTint,
    required this.warning,
    required this.selectionBorder,
    required this.separatorSubtle,
  });

  factory AppColorTokens.fromScheme(ColorScheme scheme) {
    // Keep contrast safe in both light/dark.
    final selection = scheme.onSurface.withOpacity(0.75);
    return AppColorTokens(
      dangerTint: scheme.error.withOpacity(0.08),
      infoTint: scheme.primary.withOpacity(0.08),
      warningTint: scheme.tertiary.withOpacity(0.10),
      warning: scheme.tertiary,
      selectionBorder: selection,
      separatorSubtle: scheme.outlineVariant.withOpacity(0.6),
    );
  }

  static AppColorTokens of(BuildContext context) {
    final tokens = Theme.of(context).extension<AppColorTokens>();
    assert(tokens != null, 'AppColorTokens is not registered in ThemeData.');
    return tokens!;
  }

  @override
  AppColorTokens copyWith({
    Color? dangerTint,
    Color? infoTint,
    Color? warningTint,
    Color? warning,
    Color? selectionBorder,
    Color? separatorSubtle,
  }) {
    return AppColorTokens(
      dangerTint: dangerTint ?? this.dangerTint,
      infoTint: infoTint ?? this.infoTint,
      warningTint: warningTint ?? this.warningTint,
      warning: warning ?? this.warning,
      selectionBorder: selectionBorder ?? this.selectionBorder,
      separatorSubtle: separatorSubtle ?? this.separatorSubtle,
    );
  }

  @override
  AppColorTokens lerp(ThemeExtension<AppColorTokens>? other, double t) {
    if (other is! AppColorTokens) return this;
    return AppColorTokens(
      dangerTint: Color.lerp(dangerTint, other.dangerTint, t) ?? dangerTint,
      infoTint: Color.lerp(infoTint, other.infoTint, t) ?? infoTint,
      warningTint:
          Color.lerp(warningTint, other.warningTint, t) ?? warningTint,
      warning: Color.lerp(warning, other.warning, t) ?? warning,
      selectionBorder:
          Color.lerp(selectionBorder, other.selectionBorder, t) ??
              selectionBorder,
      separatorSubtle:
          Color.lerp(separatorSubtle, other.separatorSubtle, t) ??
              separatorSubtle,
    );
  }
}

