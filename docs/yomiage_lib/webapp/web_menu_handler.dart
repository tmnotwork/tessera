import 'package:flutter/material.dart';
import 'package:yomiage/screens/deck_screen.dart';
import 'package:yomiage/screens/card_edit_screen.dart';
import 'package:yomiage/screens/csv_import_screen.dart';
import 'package:yomiage/screens/csv_export_screen.dart';
import 'package:yomiage/webapp/web_csv_import_handler.dart';
import 'package:yomiage/webapp/web_settings_manager.dart';

class WebMenuHandler {
  // 編集メニューを表示する
  static Future<void> showEditMenu(
    BuildContext context,
    GlobalKey fabKey,
    VoidCallback setState,
    bool studyExpanded,
    bool sortingExpanded,
    bool readingExpanded,
  ) async {
    final RenderBox fabRenderBox =
        fabKey.currentContext!.findRenderObject() as RenderBox;
    final Offset fabPosition = fabRenderBox.localToGlobal(Offset.zero);
    final Size fabSize = fabRenderBox.size;
    final RenderBox overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    // FAB の上端から、FAB の高さ＋20px分上に表示して、FAB と全く重ならないようにする
    final RelativeRect position = RelativeRect.fromRect(
      Rect.fromLTWH(
        fabPosition.dx,
        fabPosition.dy - fabSize.height - 20,
        fabSize.width,
        fabSize.height,
      ),
      Offset.zero & overlay.size,
    );
    final selected = await showMenu(
      context: context,
      position: position,
      items: [
        const PopupMenuItem(
          value: 'deck',
          child: Row(
            children: [
              Icon(Icons.folder),
              SizedBox(width: 8),
              Text('デッキ作成・編集', style: TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'card',
          child: Text('カード作成', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
      ],
    );
    if (selected != null) {
      switch (selected) {
        case 'deck':
          Navigator.push(
              context, MaterialPageRoute(builder: (_) => const DeckScreen()));
          break;
        case 'card':
          Navigator.push(context,
              MaterialPageRoute(builder: (_) => const CardEditScreen()));
          break;
        case 'csv_import':
          // CSVインポート画面を開き、戻り値を受け取る
          final result = await Navigator.push(context,
              MaterialPageRoute(builder: (_) => const CsvImportScreen()));
          // インポートが成功した場合、ホーム画面を更新
          if (result != null) {
            await WebCsvImportHandler.handleCsvImportResult(
              context,
              result,
              () => setState(),
              () {
                WebSettingsManager.saveExpansionStates(
                  studyExpanded: true,
                  sortingExpanded: true,
                  readingExpanded: true,
                );
              },
            );
          }
          break;
        case 'csv_export':
          Navigator.push(context,
              MaterialPageRoute(builder: (_) => const CsvExportScreen()));
          break;
      }
    }
  }

  // 通常のメニュー項目用 ListTile（出題モード、全問出題、読み上げモードのヘッダー）
  // ヘッダーのテキストは太字、左側アイコンは削除
  static Widget menuHeader(BuildContext context, String title, bool expanded,
      VoidCallback onToggle, VoidCallback onTap) {
    return ListTile(
      title: Text(title,
                          style: TextStyle(
                    fontSize: 20, color: Theme.of(context).textTheme.headlineSmall?.color, fontWeight: FontWeight.bold)),
      trailing: IconButton(
        icon: Icon(
            expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                          color: Theme.of(context).textTheme.bodyLarge?.color),
        onPressed: onToggle,
      ),
      onTap: onTap,
    );
  }
}
