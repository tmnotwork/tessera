import 'package:flutter/material.dart';
import '../widgets/app_drawer.dart';

class CommonLayout extends StatelessWidget {
  final Widget child;
  final String title;
  final Widget? titleWidget;
  final List<Widget>? actions;
  final Widget? floatingActionButton;
  final bool showDrawer;
  final bool prependActions; // if true, put actions before sync/settings
  final Widget? leading;
  final bool suppressBaseActions; // 追加: ベースのアクション（同期/設定など）を非表示
  /// AppBarの直下に表示するバー（例: タブナビゲーション）
  final Widget? barBelowAppBar;

  const CommonLayout({
    super.key,
    required this.child,
    required this.title,
    this.titleWidget,
    this.actions,
    this.floatingActionButton,
    this.showDrawer = true,
    this.prependActions = false,
    this.leading,
    this.suppressBaseActions = false,
    this.barBelowAppBar,
  });

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 800;

    final Widget? effectiveLeading =
        leading ??
        (showDrawer
            ? Builder(
                builder: (context) => IconButton(
                  icon: const Icon(Icons.menu),
                  tooltip: 'メニュー',
                  onPressed: () => Scaffold.of(context).openDrawer(),
                ),
              )
            : null);

    return Scaffold(
      appBar: AppBar(
        leading: effectiveLeading,
        title: titleWidget != null
            ? titleWidget
            : Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                ],
              ),
        automaticallyImplyLeading: false, // ドロワーのハンバーガーアイコンを非表示
        actions: actions,
        toolbarHeight: isMobile ? 48 : 48, // スマホ版とPC版で統一
        titleSpacing: 16, // タイトルの余白を調整
        centerTitle: false, // 左揃えでオーバーフローを防ぐ
        bottom: null, // スマホ版でも2行目のアクションバーを非表示
      ),
      drawer: showDrawer ? const AppDrawer() : null,
      body: SafeArea(
        top: false, // AppBar直下のため上部余白は不要（スキマ防止）
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (barBelowAppBar != null) barBelowAppBar!,
            Expanded(child: child),
          ],
        ),
      ),
      floatingActionButton: floatingActionButton,
    );
  }
}
