import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../services/app_settings_service.dart';
import '../services/widget_service.dart';
import 'package:provider/provider.dart';
import '../providers/task_provider.dart';
import 'app_theme.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// テーマ変更時にホームウィジェット（Android）へ配色を再同期する。
class _WidgetThemePaletteSync extends StatefulWidget {
  final Widget child;

  const _WidgetThemePaletteSync({required this.child});

  @override
  State<_WidgetThemePaletteSync> createState() =>
      _WidgetThemePaletteSyncState();
}

class _WidgetThemePaletteSyncState extends State<_WidgetThemePaletteSync> {
  @override
  void initState() {
    super.initState();
    AppSettingsService.themeModeKeyNotifier.addListener(_onThemeKeyChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(WidgetService.syncWidgetThemePaletteToNative());
    });
  }

  @override
  void dispose() {
    AppSettingsService.themeModeKeyNotifier.removeListener(_onThemeKeyChanged);
    super.dispose();
  }

  void _onThemeKeyChanged() {
    unawaited(WidgetService.syncWidgetThemePaletteToNative());
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class MyApp extends StatelessWidget {
  final bool hiveInitialized;
  final Widget home;

  const MyApp({super.key, required this.hiveInitialized, required this.home});

  @override
  Widget build(BuildContext context) {
    if (!hiveInitialized) {
      return MaterialApp(
        title: 'Kant Routine - Recovery Mode',
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [Locale('en', 'US'), Locale('ja', 'JP')],
        theme: buildLightTheme(),
        home: Scaffold(
          appBar: AppBar(
            title: const Text('KANT - データベース復旧モード'),
            backgroundColor: Theme.of(context).appBarTheme.backgroundColor,
            foregroundColor: Theme.of(context).appBarTheme.foregroundColor,
          ),
          body: _buildRecoveryBody(context),
        ),
      );
    }

    return ValueListenableBuilder<String>(
      valueListenable: AppSettingsService.themeModeKeyNotifier,
      builder: (context, themeKey, _) {
        final themeMode = AppSettingsService.themeModeFromString(themeKey);
        final lightTheme = switch (themeKey) {
          'gray_light' => buildGrayLightTheme(),
          'wine_light' => buildWineLightTheme(),
          'teal_light' => buildTealLightTheme(),
          'black_minimal_light' => buildBlackMinimalLightTheme(),
          _ => buildLightTheme(),
        };
        final darkTheme = switch (themeKey) {
          'wine' => buildWineDarkTheme(),
          'teal' => buildTealDarkTheme(),
          'orange' => buildOrangeDarkTheme(),
          'black_minimal' => buildBlackMinimalDarkTheme(),
          _ => buildDarkTheme(),
        };
        return MaterialApp(
          key: ValueKey(themeKey),
          navigatorKey: navigatorKey,
          title: 'Kant Routine',
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: const [Locale('en', 'US'), Locale('ja', 'JP')],
          theme: lightTheme,
          darkTheme: darkTheme,
          themeMode: themeMode,
          builder: (context, child) {
            return MultiProvider(
              providers: [
                ChangeNotifierProvider(create: (_) => TaskProvider()),
              ],
              child: child ?? const SizedBox.shrink(),
            );
          },
          home: _WidgetThemePaletteSync(child: home),
        );
      },
    );
  }

  Widget _buildRecoveryBody(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.warning,
                size: 64, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 16),
            Text(
              'データベース初期化エラー',
              style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.error),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              'ブラウザの IndexedDB で Hive ボックス削除エラーが発生しています',
              style: TextStyle(
                  fontSize: 14,
                  color: Theme.of(context).textTheme.bodySmall?.color),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color:
                    Theme.of(context).colorScheme.error.withOpacity( 0.06),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: Theme.of(context)
                        .colorScheme
                        .error
                        .withOpacity( 0.4)),
              ),
              child: Text(
                'エラー詳細: Could not delete box from disk: Instance of \'minified:bg\'',
                style: TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    color: Theme.of(context).colorScheme.error),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .primary
                    .withOpacity( 0.06),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: Theme.of(context)
                        .colorScheme
                        .primary
                        .withOpacity( 0.4)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.info,
                        color: Theme.of(context).colorScheme.primary, size: 20),
                    const SizedBox(width: 8),
                    Text('解決方法（推奨）',
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Theme.of(context).colorScheme.primary)),
                  ]),
                  const SizedBox(height: 12),
                  const Text('1. F12 を押して開発者ツールを開く',
                      style: TextStyle(fontSize: 14)),
                  const SizedBox(height: 4),
                  const Text('2. Application タブを選択',
                      style: TextStyle(fontSize: 14)),
                  const SizedBox(height: 4),
                  const Text('3. Storage → IndexedDB → このサイト を選択',
                      style: TextStyle(fontSize: 14)),
                  const SizedBox(height: 4),
                  const Text('4. 全てのデータベースを右クリック → Delete',
                      style: TextStyle(fontSize: 14)),
                  const SizedBox(height: 4),
                  const Text('5. ページを更新 (Ctrl+R または F5)',
                      style:
                          TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .tertiary
                    .withOpacity( 0.06),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: Theme.of(context)
                        .colorScheme
                        .tertiary
                        .withOpacity( 0.4)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.refresh,
                        color: Theme.of(context).colorScheme.tertiary,
                        size: 20),
                    const SizedBox(width: 8),
                    Text('簡単な方法',
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Theme.of(context).colorScheme.tertiary)),
                  ]),
                  const SizedBox(height: 8),
                  const Text('Ctrl+Shift+Delete でブラウザデータをクリア',
                      style: TextStyle(fontSize: 14)),
                  const SizedBox(height: 4),
                  Text('（すべてのサイトデータが削除されます）',
                      style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).textTheme.bodySmall?.color)),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .secondary
                    .withOpacity( 0.06),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: Theme.of(context)
                        .colorScheme
                        .secondary
                        .withOpacity( 0.4)),
              ),
              child: Row(children: [
                Icon(Icons.cloud,
                    color: Theme.of(context).colorScheme.secondary, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'ローカルデータは削除されますが、クラウド同期により自動復元されます',
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.secondary),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton.icon(
                  onPressed: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: const Text('Ctrl+R または F5 を押してページを更新してください'),
                        backgroundColor: Theme.of(context).colorScheme.primary,
                        duration: const Duration(seconds: 5),
                      ),
                    );
                  },
                  icon: const Icon(Icons.refresh),
                  label: const Text('更新方法'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    foregroundColor: Theme.of(context).colorScheme.onPrimary,
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: const Text(
                            'F12 → Application → Storage → IndexedDB → Delete all'),
                        backgroundColor: Theme.of(context).colorScheme.tertiary,
                        duration: const Duration(seconds: 7),
                      ),
                    );
                  },
                  icon: const Icon(Icons.delete_forever),
                  label: const Text('削除手順'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.tertiary,
                    foregroundColor: Theme.of(context).colorScheme.onTertiary,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
