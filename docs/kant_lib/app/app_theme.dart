import 'package:flutter/material.dart';

import 'theme/app_color_tokens.dart';

ThemeData buildLightTheme() {
  // Default light theme accent (used by AppBar / BottomBar / FAB etc.)
  // Previously: blue-ish. Now: deeper navy.
  const seed = Color(0xFF002147);

  // NOTE:
  // `ColorScheme.fromSeed()` (Material 3) may choose a lighter "primary" tone
  // than the seed itself, so to make AppBar/FAB/bars *visibly* navy we pin
  // `primary` to the exact target color.
  final lightScheme = ColorScheme.fromSeed(
    seedColor: seed,
    brightness: Brightness.light,
  ).copyWith(
    primary: seed,
    onPrimary: Colors.white,
    error: Colors.redAccent,
    onError: Colors.white,
  );

  return ThemeData(
    colorScheme: lightScheme,
    useMaterial3: true,
    fontFamily: 'NotoSansJP',
    // Important: don't hardcode text colors here.
    textTheme: Typography.material2021().black.apply(fontFamily: 'NotoSansJP'),
    primaryColor: lightScheme.primary,
    scaffoldBackgroundColor: lightScheme.surface,
    cardColor: lightScheme.surfaceContainerHighest,
    dividerColor: lightScheme.outlineVariant,
    extensions: <ThemeExtension<dynamic>>[
      AppColorTokens.fromScheme(lightScheme),
    ],
    appBarTheme: AppBarTheme(
      backgroundColor: lightScheme.primary,
      foregroundColor: lightScheme.onPrimary,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      titleTextStyle: TextStyle(
        color: lightScheme.onPrimary,
        fontSize: 20,
        fontWeight: FontWeight.w600,
        fontFamily: 'NotoSansJP',
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: lightScheme.primary,
        foregroundColor: lightScheme.onPrimary,
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: lightScheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: lightScheme.primary, width: 2),
      ),
      filled: true,
      fillColor: lightScheme.surface,
    ),
    bottomNavigationBarTheme: BottomNavigationBarThemeData(
      backgroundColor: lightScheme.primary,
      selectedItemColor: lightScheme.onPrimary,
      unselectedItemColor: lightScheme.onPrimary.withOpacity( 0.7),
      selectedLabelStyle: const TextStyle(fontWeight: FontWeight.w600, fontFamily: 'NotoSansJP'),
      unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w400, fontFamily: 'NotoSansJP'),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: lightScheme.primary,
      foregroundColor: lightScheme.onPrimary,
    ),
  );
}

ThemeData buildDarkTheme() {
  // Dark mode base background: blue-tinted near-black.
  // Keep it subtle; avoid pure #000000 for a consistent cool tone.
  // Tweaked darker (less noticeable tint) while keeping a cool tone.
  const blueBlack = Color(0xFF070A12);
  const seed = Color(0xFF1E3A8A);

  final darkSchemeBase = ColorScheme.fromSeed(
    seedColor: seed,
    brightness: Brightness.dark,
  );

  // Force surfaces towards "blue-black" while keeping accents derived from seed.
  final darkScheme = darkSchemeBase.copyWith(
    surface: blueBlack,
    surfaceDim: const Color(0xFF05070D),
    surfaceBright: const Color(0xFF10192E),
    surfaceContainerLowest: const Color(0xFF04060B),
    surfaceContainerLow: const Color(0xFF05070D),
    surfaceContainer: const Color(0xFF070A12),
    surfaceContainerHigh: const Color(0xFF0A0F1C),
    surfaceContainerHighest: const Color(0xFF0D1326),
    surfaceVariant: const Color(0xFF161F37),
    outlineVariant: const Color(0xFF25314D),
    error: Colors.redAccent,
    onError: Colors.white,
  );

  return ThemeData(
    colorScheme: darkScheme,
    useMaterial3: true,
    fontFamily: 'NotoSansJP',
    textTheme: Typography.material2021().white.apply(fontFamily: 'NotoSansJP'),
    scaffoldBackgroundColor: darkScheme.surface,
    cardColor: darkScheme.surfaceContainerHighest,
    dividerColor: darkScheme.outlineVariant,
    extensions: <ThemeExtension<dynamic>>[
      AppColorTokens.fromScheme(darkScheme),
    ],
    appBarTheme: AppBarTheme(
      backgroundColor: darkScheme.surface,
      foregroundColor: darkScheme.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: darkScheme.primary,
        foregroundColor: darkScheme.onPrimary,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: darkScheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: darkScheme.primary),
      ),
      filled: true,
      fillColor: darkScheme.surface,
    ),
    bottomNavigationBarTheme: BottomNavigationBarThemeData(
      backgroundColor: darkScheme.surfaceContainerHighest,
      selectedItemColor: darkScheme.onSurfaceVariant,
      unselectedItemColor: darkScheme.onSurfaceVariant.withOpacity( 0.7),
      selectedLabelStyle: const TextStyle(fontWeight: FontWeight.w600, fontFamily: 'NotoSansJP'),
      unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w400, fontFamily: 'NotoSansJP'),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: darkScheme.primary,
      foregroundColor: darkScheme.onPrimary,
    ),
  );
}

ThemeData buildWineDarkTheme() {
  // Additional dark theme variant:
  // - Accent (primary): wine red (#BD1236)
  // - Background: true black
  const wine = Color(0xFFBD1236);
  const black = Color(0xFF000000);
  // For running task bar etc. Keep it distinct from black, but not bright.
  const winePrimaryContainer = Color(0xFF12070B);

  final schemeBase = ColorScheme.fromSeed(
    seedColor: wine,
    brightness: Brightness.dark,
  );

  final scheme = schemeBase.copyWith(
    primary: wine,
    onPrimary: Colors.white,
    primaryContainer: winePrimaryContainer,
    onPrimaryContainer: Colors.white,
    surface: black,
    surfaceDim: black,
    surfaceBright: const Color(0xFF111111),
    surfaceContainerLowest: black,
    surfaceContainerLow: const Color(0xFF050505),
    surfaceContainer: const Color(0xFF0A0A0A),
    surfaceContainerHigh: const Color(0xFF111111),
    surfaceContainerHighest: const Color(0xFF1A1A1A),
    surfaceVariant: const Color(0xFF1E1E1E),
    outlineVariant: const Color(0xFF3A3A3A),
  );

  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    fontFamily: 'NotoSansJP',
    textTheme: Typography.material2021().white.apply(fontFamily: 'NotoSansJP'),
    scaffoldBackgroundColor: scheme.surface,
    cardColor: scheme.surfaceContainerHighest,
    dividerColor: scheme.outlineVariant,
    extensions: <ThemeExtension<dynamic>>[
      AppColorTokens.fromScheme(scheme),
    ],
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: scheme.primary),
      ),
      filled: true,
      fillColor: scheme.surface,
    ),
    bottomNavigationBarTheme: BottomNavigationBarThemeData(
      backgroundColor: scheme.surface,
      selectedItemColor: scheme.primary,
      unselectedItemColor: scheme.onSurfaceVariant.withOpacity(0.7),
      selectedLabelStyle:
          const TextStyle(fontWeight: FontWeight.w600, fontFamily: 'NotoSansJP'),
      unselectedLabelStyle:
          const TextStyle(fontWeight: FontWeight.w400, fontFamily: 'NotoSansJP'),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
    ),
  );
}

ThemeData buildWineLightTheme() {
  // Light theme variant aligned with Wine Dark:
  // - Accent (primary): wine red (#BD1236)
  // - Background: clean light surface (not pure white everywhere)
  const wine = Color(0xFFBD1236);

  final base = ColorScheme.fromSeed(
    seedColor: wine,
    brightness: Brightness.light,
  );

  // Keep surfaces slightly warm/soft so it feels like the same "wine" family,
  // while maintaining high contrast and readability.
  final scheme = base.copyWith(
    primary: wine,
    onPrimary: Colors.white,
    primaryContainer: const Color(0xFFFFD9DF),
    onPrimaryContainer: const Color(0xFF3A0010),
    surface: const Color(0xFFFFFBFC),
    surfaceDim: const Color(0xFFF7F1F3),
    surfaceBright: const Color(0xFFFFFFFF),
    surfaceContainerLowest: const Color(0xFFFFFFFF),
    surfaceContainerLow: const Color(0xFFFFF5F7),
    surfaceContainer: const Color(0xFFFFEFF2),
    surfaceContainerHigh: const Color(0xFFFFE7EC),
    surfaceContainerHighest: const Color(0xFFFFDEE6),
    surfaceVariant: const Color(0xFFF2DDE2),
    outlineVariant: const Color(0xFFD7C0C6),
    error: Colors.redAccent,
    onError: Colors.white,
  );

  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    fontFamily: 'NotoSansJP',
    textTheme: Typography.material2021().black.apply(fontFamily: 'NotoSansJP'),
    primaryColor: scheme.primary,
    scaffoldBackgroundColor: scheme.surface,
    cardColor: scheme.surfaceContainerHighest,
    dividerColor: scheme.outlineVariant,
    extensions: <ThemeExtension<dynamic>>[
      AppColorTokens.fromScheme(scheme),
    ],
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      titleTextStyle: TextStyle(
        color: scheme.onPrimary,
        fontSize: 20,
        fontWeight: FontWeight.w600,
        fontFamily: 'NotoSansJP',
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
      filled: true,
      fillColor: scheme.surface,
    ),
    bottomNavigationBarTheme: BottomNavigationBarThemeData(
      backgroundColor: scheme.primary,
      selectedItemColor: scheme.onPrimary,
      unselectedItemColor: scheme.onPrimary.withOpacity(0.7),
      selectedLabelStyle:
          const TextStyle(fontWeight: FontWeight.w600, fontFamily: 'NotoSansJP'),
      unselectedLabelStyle:
          const TextStyle(fontWeight: FontWeight.w400, fontFamily: 'NotoSansJP'),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
    ),
  );
}

ThemeData buildGrayLightTheme() {
  // Light theme variant with a simple, neutral gray palette.
  const seed = Color(0xFF6B6B6B);

  final base = ColorScheme.fromSeed(
    seedColor: seed,
    brightness: Brightness.light,
  );

  final scheme = base.copyWith(
    primary: const Color(0xFF4B4B4B),
    onPrimary: Colors.white,
    primaryContainer: const Color(0xFFE2DED7),
    onPrimaryContainer: const Color(0xFF2E2E2E),
    secondary: const Color(0xFF7A6F68),
    onSecondary: Colors.white,
    secondaryContainer: const Color(0xFFE6E1DB),
    onSecondaryContainer: const Color(0xFF2F2A26),
    tertiary: const Color(0xFF8B6F5A),
    onTertiary: Colors.white,
    tertiaryContainer: const Color(0xFFF3E9E0),
    onTertiaryContainer: const Color(0xFF3D2E25),
    surface: const Color(0xFFF7F6F3),
    surfaceDim: const Color(0xFFEDEBE7),
    surfaceBright: const Color(0xFFFFFFFF),
    surfaceContainerLowest: const Color(0xFFFFFFFF),
    surfaceContainerLow: const Color(0xFFF3F1ED),
    surfaceContainer: const Color(0xFFEFEEE9),
    surfaceContainerHigh: const Color(0xFFE9E6E1),
    surfaceContainerHighest: const Color(0xFFE3DFD9),
    surfaceVariant: const Color(0xFFE1DDD6),
    outlineVariant: const Color(0xFFCEC7C0),
    error: Colors.redAccent,
    onError: Colors.white,
  );

  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    fontFamily: 'NotoSansJP',
    textTheme: Typography.material2021().black.apply(fontFamily: 'NotoSansJP'),
    primaryColor: scheme.primary,
    scaffoldBackgroundColor: scheme.surface,
    cardColor: scheme.surfaceContainerHighest,
    dividerColor: scheme.outlineVariant,
    extensions: <ThemeExtension<dynamic>>[
      AppColorTokens.fromScheme(scheme),
    ],
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      iconTheme: IconThemeData(color: scheme.onSurface),
      actionsIconTheme: IconThemeData(color: scheme.onSurface),
      titleTextStyle: TextStyle(
        color: scheme.onSurface,
        fontSize: 20,
        fontWeight: FontWeight.w600,
        fontFamily: 'NotoSansJP',
      ),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        elevation: 1,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
      filled: true,
      fillColor: scheme.surface,
    ),
    bottomNavigationBarTheme: BottomNavigationBarThemeData(
      backgroundColor: scheme.surface,
      selectedItemColor: scheme.primary,
      unselectedItemColor: scheme.onSurfaceVariant.withOpacity(0.7),
      selectedLabelStyle:
          const TextStyle(fontWeight: FontWeight.w600, fontFamily: 'NotoSansJP'),
      unselectedLabelStyle:
          const TextStyle(fontWeight: FontWeight.w400, fontFamily: 'NotoSansJP'),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
    ),
  );
}

ThemeData buildTealDarkTheme() {
  // Additional dark theme variant:
  // - Accent (primary): teal (#48CABE)
  // - Background: near-black with subtle teal tint
  const teal = Color(0xFF48CABE);
  const tealBlack = Color(0xFF050B0B);
  // NOTE:
  // カレンダーの予定ブロック等で *Container 系カラーを背景に使うため、
  // Darkでも「沈んで見えない」ように、少し明るめ＆彩度高めのコンテナ色に寄せる。
  const tealPrimaryContainer = Color(0xFF0F3A35);
  const tealSecondary = Color(0xFF3DE7D2);
  const tealSecondaryContainer = Color(0xFF1B5F56);
  const tealTertiary = Color(0xFF7AA8FF);
  const tealTertiaryContainer = Color(0xFF2A3F78);

  final schemeBase = ColorScheme.fromSeed(
    seedColor: teal,
    brightness: Brightness.dark,
  );

  final scheme = schemeBase.copyWith(
    primary: teal,
    onPrimary: Colors.black,
    primaryContainer: tealPrimaryContainer,
    onPrimaryContainer: Colors.white,
    secondary: tealSecondary,
    onSecondary: const Color(0xFF00201C),
    secondaryContainer: tealSecondaryContainer,
    onSecondaryContainer: const Color(0xFFD7FFF9),
    tertiary: tealTertiary,
    onTertiary: const Color(0xFF001B3A),
    tertiaryContainer: tealTertiaryContainer,
    onTertiaryContainer: const Color(0xFFEAF0FF),
    surface: tealBlack,
    surfaceDim: const Color(0xFF040808),
    surfaceBright: const Color(0xFF101A1A),
    surfaceContainerLowest: const Color(0xFF030606),
    surfaceContainerLow: const Color(0xFF040808),
    surfaceContainer: const Color(0xFF050B0B),
    surfaceContainerHigh: const Color(0xFF081010),
    surfaceContainerHighest: const Color(0xFF0C1615),
    surfaceVariant: const Color(0xFF122120),
    outlineVariant: const Color(0xFF345554),
    error: Colors.redAccent,
    onError: Colors.white,
  );

  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    fontFamily: 'NotoSansJP',
    textTheme: Typography.material2021().white.apply(fontFamily: 'NotoSansJP'),
    scaffoldBackgroundColor: scheme.surface,
    cardColor: scheme.surfaceContainerHighest,
    dividerColor: scheme.outlineVariant,
    iconTheme: IconThemeData(color: scheme.primary),
    extensions: <ThemeExtension<dynamic>>[
      AppColorTokens.fromScheme(scheme),
    ],
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      // AppBarのアイコンは強調色にせず、常に中立色（onSurface）で統一する
      // （アプリ全体の強調色はボトムバー/FAB/選択状態などで表現する）
      iconTheme: IconThemeData(color: scheme.onSurface),
      actionsIconTheme: IconThemeData(color: scheme.onSurface),
      titleTextStyle: TextStyle(
        color: scheme.onSurface,
        fontSize: 20,
        fontWeight: FontWeight.w600,
        fontFamily: 'NotoSansJP',
      ),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: scheme.primary),
      ),
      filled: true,
      fillColor: scheme.surface,
    ),
    bottomNavigationBarTheme: BottomNavigationBarThemeData(
      backgroundColor: scheme.surface,
      selectedItemColor: scheme.primary,
      unselectedItemColor: scheme.onSurfaceVariant.withOpacity(0.7),
      selectedLabelStyle:
          const TextStyle(fontWeight: FontWeight.w600, fontFamily: 'NotoSansJP'),
      unselectedLabelStyle:
          const TextStyle(fontWeight: FontWeight.w400, fontFamily: 'NotoSansJP'),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
    ),
  );
}

ThemeData buildOrangeDarkTheme() {
  // Dark theme variant with orange accent:
  // - Accent (primary): vibrant orange (#FF8C00)
  // - Background: near-black with warm tint
  const orange = Color(0xFFFF8C00);
  const orangeBlack = Color(0xFF0B0906);
  const orangePrimaryContainer = Color(0xFF3A2508);
  const orangeSecondary = Color(0xFFFFB347);
  const orangeSecondaryContainer = Color(0xFF5C3D14);
  // 中断ボタン等のサブアクセント：オレンジと調和する深いオレンジ
  const orangeTertiary = Color(0xFFD84315);
  const orangeTertiaryContainer = Color(0xFF4E1C00);

  final schemeBase = ColorScheme.fromSeed(
    seedColor: orange,
    brightness: Brightness.dark,
  );

  final scheme = schemeBase.copyWith(
    primary: orange,
    onPrimary: Colors.black,
    primaryContainer: orangePrimaryContainer,
    onPrimaryContainer: Colors.white,
    secondary: orangeSecondary,
    onSecondary: const Color(0xFF1A1000),
    secondaryContainer: orangeSecondaryContainer,
    onSecondaryContainer: const Color(0xFFFFF4E6),
    tertiary: orangeTertiary,
    onTertiary: Colors.white,
    tertiaryContainer: orangeTertiaryContainer,
    onTertiaryContainer: const Color(0xFFFFCCBC),
    surface: orangeBlack,
    surfaceDim: const Color(0xFF080604),
    surfaceBright: const Color(0xFF1A1510),
    surfaceContainerLowest: const Color(0xFF050403),
    surfaceContainerLow: const Color(0xFF080604),
    surfaceContainer: const Color(0xFF0B0906),
    surfaceContainerHigh: const Color(0xFF100D0A),
    surfaceContainerHighest: const Color(0xFF16120E),
    surfaceVariant: const Color(0xFF201A14),
    outlineVariant: const Color(0xFF4A3E32),
    error: Colors.redAccent,
    onError: Colors.white,
  );

  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    fontFamily: 'NotoSansJP',
    textTheme: Typography.material2021().white.apply(fontFamily: 'NotoSansJP'),
    scaffoldBackgroundColor: scheme.surface,
    cardColor: scheme.surfaceContainerHighest,
    dividerColor: scheme.outlineVariant,
    iconTheme: IconThemeData(color: scheme.primary),
    extensions: <ThemeExtension<dynamic>>[
      AppColorTokens.fromScheme(scheme),
    ],
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      iconTheme: IconThemeData(color: scheme.onSurface),
      actionsIconTheme: IconThemeData(color: scheme.onSurface),
      titleTextStyle: TextStyle(
        color: scheme.onSurface,
        fontSize: 20,
        fontWeight: FontWeight.w600,
        fontFamily: 'NotoSansJP',
      ),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: scheme.primary),
      ),
      filled: true,
      fillColor: scheme.surface,
    ),
    bottomNavigationBarTheme: BottomNavigationBarThemeData(
      backgroundColor: scheme.surface,
      selectedItemColor: scheme.primary,
      unselectedItemColor: scheme.onSurfaceVariant.withOpacity(0.7),
      selectedLabelStyle:
          const TextStyle(fontWeight: FontWeight.w600, fontFamily: 'NotoSansJP'),
      unselectedLabelStyle:
          const TextStyle(fontWeight: FontWeight.w400, fontFamily: 'NotoSansJP'),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
    ),
  );
}

ThemeData buildBlackMinimalDarkTheme() {
  // ミニマルブラック（ダーク）: 強調色は白・FABなどの上は黒文字
  const black = Color(0xFF000000);
  const white = Color(0xFFFFFFFF);
  const surface = Color(0xFF0A0A0A);
  const surfaceHigh = Color(0xFF141414);

  final schemeBase = ColorScheme.fromSeed(
    seedColor: white,
    brightness: Brightness.dark,
  );

  final scheme = schemeBase.copyWith(
    primary: white,
    onPrimary: black,
    primaryContainer: const Color(0xFF1A1A1A),
    onPrimaryContainer: Colors.white,
    secondary: const Color(0xFF2A2A2A),
    onSecondary: Colors.white,
    tertiary: const Color(0xFF333333),
    onTertiary: Colors.white,
    surface: surface,
    onSurface: const Color(0xFFE5E5E5),
    onSurfaceVariant: const Color(0xFFB3B3B3),
    outline: const Color(0xFF2A2A2A),
    outlineVariant: const Color(0xFF1F1F1F),
    error: Colors.redAccent,
    onError: Colors.white,
    surfaceContainerHighest: surfaceHigh,
  );

  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    fontFamily: 'NotoSansJP',
    textTheme: Typography.material2021().white.apply(fontFamily: 'NotoSansJP'),
    scaffoldBackgroundColor: scheme.surface,
    cardColor: scheme.surfaceContainerHighest,
    dividerColor: scheme.outlineVariant,
    extensions: <ThemeExtension<dynamic>>[
      AppColorTokens.fromScheme(scheme),
    ],
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      titleTextStyle: TextStyle(
        color: scheme.onSurface,
        fontSize: 20,
        fontWeight: FontWeight.w600,
        fontFamily: 'NotoSansJP',
      ),
      iconTheme: IconThemeData(color: scheme.onSurface),
      actionsIconTheme: IconThemeData(color: scheme.onSurface),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: scheme.primary, width: 1),
      ),
      filled: true,
      fillColor: scheme.surface,
    ),
    bottomNavigationBarTheme: BottomNavigationBarThemeData(
      backgroundColor: scheme.surface,
      selectedItemColor: scheme.onSurface,
      unselectedItemColor: scheme.onSurfaceVariant.withOpacity(0.6),
      selectedLabelStyle:
          const TextStyle(fontWeight: FontWeight.w600, fontFamily: 'NotoSansJP'),
      unselectedLabelStyle:
          const TextStyle(fontWeight: FontWeight.w400, fontFamily: 'NotoSansJP'),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      elevation: 0,
    ),
  );
}

ThemeData buildBlackMinimalLightTheme() {
  // 黒を強調色にしたミニマルライトテーマ。白と白に近いグレーのみで構成。
  const black = Color(0xFF000000);
  const white = Color(0xFFFFFFFF);
  const surfaceGray = Color(0xFFFAFAFA); // ページ背景（ほぼ白）

  final schemeBase = ColorScheme.fromSeed(
    seedColor: black,
    brightness: Brightness.light,
  );

  final scheme = schemeBase.copyWith(
    primary: black,
    onPrimary: Colors.white,
    primaryContainer: const Color(0xFFF8F8F8),
    onPrimaryContainer: black,
    secondary: const Color(0xFF2A2A2A),
    onSecondary: Colors.white,
    tertiary: const Color(0xFF404040),
    onTertiary: Colors.white,
    surface: surfaceGray,
    onSurface: black,
    onSurfaceVariant: const Color(0xFF525252),
    outline: const Color(0xFFE8E8E8),
    outlineVariant: const Color(0xFFEEEEEE),
    error: Colors.redAccent,
    onError: Colors.white,
    surfaceContainerLowest: white,
    surfaceContainerLow: white,
    surfaceContainer: white,
    surfaceContainerHigh: white,
    surfaceContainerHighest: white,
  );

  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    fontFamily: 'NotoSansJP',
    textTheme: Typography.material2021().black.apply(fontFamily: 'NotoSansJP'),
    primaryColor: scheme.primary,
    scaffoldBackgroundColor: scheme.surface,
    cardColor: white,
    dividerColor: scheme.outlineVariant,
    extensions: <ThemeExtension<dynamic>>[
      AppColorTokens.fromScheme(scheme),
    ],
    appBarTheme: AppBarTheme(
      backgroundColor: white,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      titleTextStyle: TextStyle(
        color: scheme.onSurface,
        fontSize: 20,
        fontWeight: FontWeight.w600,
        fontFamily: 'NotoSansJP',
      ),
      iconTheme: IconThemeData(color: scheme.onSurface),
      actionsIconTheme: IconThemeData(color: scheme.onSurface),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: scheme.primary, width: 1),
      ),
      filled: true,
      fillColor: white,
    ),
    bottomNavigationBarTheme: BottomNavigationBarThemeData(
      backgroundColor: white,
      selectedItemColor: scheme.primary,
      unselectedItemColor: scheme.onSurfaceVariant.withOpacity(0.7),
      selectedLabelStyle:
          const TextStyle(fontWeight: FontWeight.w600, fontFamily: 'NotoSansJP'),
      unselectedLabelStyle:
          const TextStyle(fontWeight: FontWeight.w400, fontFamily: 'NotoSansJP'),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      elevation: 0,
    ),
  );
}

ThemeData buildTealLightTheme() {
  // Light theme variant aligned with Teal Dark.
  const teal = Color(0xFF48CABE);

  final base = ColorScheme.fromSeed(
    seedColor: teal,
    brightness: Brightness.light,
  );

  final scheme = base.copyWith(
    primary: teal,
    onPrimary: Colors.black,
    primaryContainer: const Color(0xFFBFF6F0),
    onPrimaryContainer: const Color(0xFF00201D),
    surface: const Color(0xFFF5FFFE),
    surfaceDim: const Color(0xFFECF7F6),
    surfaceBright: const Color(0xFFFFFFFF),
    surfaceContainerLowest: const Color(0xFFFFFFFF),
    surfaceContainerLow: const Color(0xFFEFFBFA),
    surfaceContainer: const Color(0xFFE7F6F4),
    surfaceContainerHigh: const Color(0xFFDEF2EF),
    surfaceContainerHighest: const Color(0xFFD6EFEB),
    surfaceVariant: const Color(0xFFD2E6E3),
    outlineVariant: const Color(0xFFB5CBC7),
    error: Colors.redAccent,
    onError: Colors.white,
  );

  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    fontFamily: 'NotoSansJP',
    textTheme: Typography.material2021().black.apply(fontFamily: 'NotoSansJP'),
    primaryColor: scheme.primary,
    scaffoldBackgroundColor: scheme.surface,
    cardColor: scheme.surfaceContainerHighest,
    dividerColor: scheme.outlineVariant,
    extensions: <ThemeExtension<dynamic>>[
      AppColorTokens.fromScheme(scheme),
    ],
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      titleTextStyle: TextStyle(
        color: scheme.onPrimary,
        fontSize: 20,
        fontWeight: FontWeight.w600,
        fontFamily: 'NotoSansJP',
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
      filled: true,
      fillColor: scheme.surface,
    ),
    bottomNavigationBarTheme: BottomNavigationBarThemeData(
      backgroundColor: scheme.primary,
      selectedItemColor: scheme.onPrimary,
      unselectedItemColor: scheme.onPrimary.withOpacity(0.7),
      selectedLabelStyle:
          const TextStyle(fontWeight: FontWeight.w600, fontFamily: 'NotoSansJP'),
      unselectedLabelStyle:
          const TextStyle(fontWeight: FontWeight.w400, fontFamily: 'NotoSansJP'),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
    ),
  );
}