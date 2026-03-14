import 'package:flutter/material.dart';

import 'screens/mobile_shell_screen.dart';
import 'screens/reference_books_list_screen.dart';
import 'screens/settings_screen.dart';
import 'utils/platform_utils.dart';

/// 白・グレー基調、黒を強調色にしたミニマルなライト用カラースキーム
final _minimalLightScheme = ColorScheme.light(
  primary: const Color(0xFF1C1C1C),
  onPrimary: Colors.white,
  primaryContainer: const Color(0xFFEEEEEE),
  onPrimaryContainer: const Color(0xFF1C1C1C),
  secondary: const Color(0xFF424242),
  onSecondary: Colors.white,
  secondaryContainer: const Color(0xFFF5F5F5),
  onSecondaryContainer: const Color(0xFF1C1C1C),
  surface: Colors.white,
  onSurface: const Color(0xFF1C1C1C),
  onSurfaceVariant: const Color(0xFF616161),
  surfaceContainerHighest: const Color(0xFFF5F5F5),
  surfaceContainerHigh: const Color(0xFFFAFAFA),
  surfaceContainer: const Color(0xFFF5F5F5),
  surfaceContainerLow: const Color(0xFFFAFAFA),
  outline: const Color(0xFF9E9E9E),
  outlineVariant: const Color(0xFFE0E0E0),
  error: const Color(0xFFB00020),
  onError: Colors.white,
  inverseSurface: const Color(0xFF303030),
  onInverseSurface: const Color(0xFFF5F5F5),
  inversePrimary: const Color(0xFFE0E0E0),
);

/// ダーク用カラースキーム
final _minimalDarkScheme = ColorScheme.dark(
  primary: const Color(0xFFE0E0E0),
  onPrimary: const Color(0xFF1C1C1C),
  primaryContainer: const Color(0xFF424242),
  onPrimaryContainer: const Color(0xFFE0E0E0),
  secondary: const Color(0xFFB0B0B0),
  onSecondary: const Color(0xFF1C1C1C),
  secondaryContainer: const Color(0xFF383838),
  onSecondaryContainer: const Color(0xFFE0E0E0),
  surface: const Color(0xFF121212),
  onSurface: const Color(0xFFE5E5E5),
  onSurfaceVariant: const Color(0xFFB0B0B0),
  surfaceContainerHighest: const Color(0xFF2C2C2C),
  surfaceContainerHigh: const Color(0xFF262626),
  surfaceContainer: const Color(0xFF1E1E1E),
  surfaceContainerLow: const Color(0xFF1A1A1A),
  outline: const Color(0xFF6E6E6E),
  outlineVariant: const Color(0xFF424242),
  error: const Color(0xFFCF6679),
  onError: const Color(0xFF1C1C1C),
  inverseSurface: const Color(0xFFE5E5E5),
  onInverseSurface: const Color(0xFF1C1C1C),
  inversePrimary: const Color(0xFF424242),
);

class KnowledgeViewerApp extends StatefulWidget {
  const KnowledgeViewerApp({super.key});

  @override
  State<KnowledgeViewerApp> createState() => _KnowledgeViewerAppState();
}

class _KnowledgeViewerAppState extends State<KnowledgeViewerApp> {
  ThemeMode _themeMode = ThemeMode.light;

  @override
  void initState() {
    super.initState();
    _loadThemeMode();
  }

  Future<void> _loadThemeMode() async {
    final mode = await loadThemeMode();
    if (mounted) setState(() => _themeMode = mode);
  }

  Future<void> _setThemeMode(ThemeMode mode) async {
    await saveThemeMode(mode);
    if (mounted) setState(() => _themeMode = mode);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Knowledge Viewer',
      themeMode: _themeMode,
      theme: _buildTheme(_minimalLightScheme),
      darkTheme: _buildTheme(_minimalDarkScheme),
      home: isMobile
          ? MobileShellScreen(
              themeMode: _themeMode,
              onThemeModeChanged: _setThemeMode,
            )
          : ReferenceBooksListScreen(
              onOpenSettings: (navContext) {
                Navigator.of(navContext).push(
                  MaterialPageRoute<void>(
                    builder: (context) => SettingsScreen(
                      initialThemeMode: _themeMode,
                      onThemeModeChanged: (mode) {
                        _setThemeMode(mode);
                        Navigator.of(context).pop();
                      },
                    ),
                  ),
                );
              },
            ),
    );
  }

  ThemeData _buildTheme(ColorScheme scheme) {
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      fontFamily: 'NotoSansJP',
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        surfaceTintColor: Colors.transparent,
        iconTheme: IconThemeData(color: scheme.onSurface),
        titleTextStyle: TextStyle(
          fontFamily: 'NotoSansJP',
          color: scheme.onSurface,
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
      ),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainerHighest,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          elevation: 0,
        ),
      ),
      scaffoldBackgroundColor: scheme.surface,
    );
  }
}
