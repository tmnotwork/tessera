import 'package:flutter/material.dart';
import 'package:flex_color_scheme/flex_color_scheme.dart';

/// アプリ全体で使用する統一テーマ定義
class AppTheme {
  // プライベートコンストラクタ（静的クラスとして使用）
  AppTheme._();

  /// ライトテーマ
  static ThemeData get lightTheme {
    // 既存のFlexColorSchemeを使用してベースカラースキームを生成
    final ColorScheme? lightScheme = FlexColorScheme.light(
      scheme: FlexScheme.indigo,
    ).colorScheme;

    // ライトモードでの可読性向上のため、主要アクセント色をやや濃く調整
    final ColorScheme adjustedLightScheme = lightScheme!.copyWith(
      primary: Colors.indigo.shade700,
      secondary: const Color(0xFF004D40), // 正解: teal系の最濃クラス相当
      tertiary: const Color(0xFFBF360C), // 難しい: deep orange系の最濃クラス相当
      error: Colors.red.shade800,
      outline: Colors.grey.shade700,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: adjustedLightScheme,
      fontFamily: 'NotoSansJP',

      // AppBarテーマ（ライトモード用：明るい背景 + 暗い文字・アイコン）
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        iconTheme: IconThemeData(color: Colors.black87),
        titleTextStyle: TextStyle(
          color: Colors.black87,
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
      ),

      // Scaffoldテーマ（目に優しいライトグレー背景）
      scaffoldBackgroundColor: Colors.grey[50],

      // Cardテーマ
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),

      // ダイアログテーマ
      dialogTheme: const DialogThemeData(
        backgroundColor: Colors.white,
        titleTextStyle: TextStyle(
          color: Colors.black,
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
        contentTextStyle: TextStyle(
          color: Colors.black87,
          fontSize: 16,
        ),
      ),

      // SnackBarテーマ
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: Colors.black87,
        contentTextStyle: TextStyle(color: Colors.white),
      ),
    );
  }

  /// ダークテーマ
  static ThemeData get darkTheme {
    // 既存のFlexColorSchemeを使用してベースカラースキームを生成
    final ColorScheme? darkScheme = FlexColorScheme.dark(
      scheme: FlexScheme.indigo,
    ).colorScheme;

    // ダークモードでの可読性向上のため、主要アクセント色をやや明るく調整
    final ColorScheme adjustedDarkScheme = darkScheme!.copyWith(
      primary: Colors.indigo.shade200,
      secondary: Colors.teal.shade200,
      tertiary: Colors.orange.shade300,
      error: Colors.red.shade300,
      outline: Colors.grey.shade400,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: adjustedDarkScheme,
      fontFamily: 'NotoSansJP',

      // AppBarテーマ（ダークモード用：黒背景 + 白文字）
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        iconTheme: IconThemeData(color: Colors.white),
        titleTextStyle: TextStyle(
          color: Colors.white,
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
      ),

      // Scaffoldテーマ（ダーク背景）
      scaffoldBackgroundColor: Colors.grey[900],

      // Cardテーマ（ダークモード用：明るめの灰色）
      cardTheme: CardThemeData(
        color: Colors.grey[700],
        elevation: 4,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),

      // ダイアログテーマ
      dialogTheme: DialogThemeData(
        backgroundColor: Colors.grey[800],
        titleTextStyle: const TextStyle(
          color: Colors.white,
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
        contentTextStyle: const TextStyle(
          color: Colors.white70,
          fontSize: 16,
        ),
      ),

      // SnackBarテーマ
      snackBarTheme: SnackBarThemeData(
        backgroundColor: Colors.grey[700],
        contentTextStyle: const TextStyle(color: Colors.white),
      ),

      // ListTileテーマ
      listTileTheme: const ListTileThemeData(
        textColor: Colors.white,
        iconColor: Colors.white70,
      ),

      // TextTheme（ダークモード用のテキスト色）
      textTheme: const TextTheme(
        bodyLarge: TextStyle(color: Colors.white),
        bodyMedium: TextStyle(color: Colors.white),
        bodySmall: TextStyle(color: Colors.white70),
        headlineLarge: TextStyle(color: Colors.white),
        headlineMedium: TextStyle(color: Colors.white),
        headlineSmall: TextStyle(color: Colors.white),
        titleLarge: TextStyle(color: Colors.white),
        titleMedium: TextStyle(color: Colors.white),
        titleSmall: TextStyle(color: Colors.white70),
        labelLarge: TextStyle(color: Colors.white),
        labelMedium: TextStyle(color: Colors.white70),
        labelSmall: TextStyle(color: Colors.white70),
      ),
    );
  }
}

/// カスタムカラー定義（テーマに依存しない色）
class CustomColors {
  static const Color success = Colors.green;
  static const Color error = Colors.red;
  static const Color warning = Colors.orange;
  static const Color info = Colors.blue;

  // 評価ボタン用の見やすい色
  static const Color difficult = Colors.orange; // 難しい - オレンジ
  static const Color correct = Colors.green; // 正解 - 緑
  static const Color easy = Colors.blue; // 簡単 - 青
  static const Color today = Colors.red; // 当日中 - 赤

  // テーマに依存する色の定義
  static Color getTextColor(ThemeData theme) {
    return theme.brightness == Brightness.light ? Colors.black87 : Colors.white;
  }

  static Color getSecondaryTextColor(ThemeData theme) {
    return theme.brightness == Brightness.light
        ? Colors.black54
        : Colors.white70;
  }

  static Color getBackgroundColor(ThemeData theme) {
    return theme.brightness == Brightness.light
        ? Colors.white
        : Colors.grey[800]!;
  }

  static Color getCardBackgroundColor(ThemeData theme) {
    return theme.brightness == Brightness.light
        ? Colors.white
        : Colors.grey[700]!;
  }

  static Color getSnackBarBackgroundColor(ThemeData theme) {
    return theme.brightness == Brightness.light
        ? Colors.black87
        : Colors.grey[700]!;
  }

  static Color getDialogBackgroundColor(ThemeData theme) {
    return theme.brightness == Brightness.light
        ? Colors.white
        : Colors.grey[800]!;
  }
}
