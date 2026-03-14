import 'package:flutter/material.dart';

import '../widgets/phone_frame.dart';
import 'home_screen.dart';

/// スマホ画面サイズの枠内でアプリをプレビューする画面（Androidエミュレーター風）
class PhonePreviewScreen extends StatelessWidget {
  const PhonePreviewScreen({super.key, this.openDrawer});

  /// スマホでドロワーを開くコールバック（指定時は AppBar にメニューアイコンを表示）
  final VoidCallback? openDrawer;

  static const double _phoneWidth = 360;
  static const double _phoneHeight = 720;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('スマホ画面で確認'),
        leading: openDrawer != null
            ? IconButton(icon: const Icon(Icons.menu), onPressed: openDrawer, tooltip: 'メニュー')
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.of(context).pop(),
                tooltip: '戻る',
              ),
      ),
      body: Center(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: PhoneFrame(
              width: _phoneWidth,
              height: _phoneHeight,
              child: Navigator(
                initialRoute: '/',
                onGenerateRoute: (settings) {
                  return MaterialPageRoute(
                    builder: (_) => const HomeScreen(),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
