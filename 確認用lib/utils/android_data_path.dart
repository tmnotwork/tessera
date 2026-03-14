import 'dart:io' show Directory, File;

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Android で編集可能なデータフォルダを用意する。
/// アプリのドキュメントディレクトリ下に knowledge_data を作り、
/// アセットの JSON をコピーする（既存ファイルは上書きしない）。
Future<String?> ensureAndroidDataPath() async {
  final dir = await getApplicationDocumentsDirectory();
  final dataDir = Directory(p.join(dir.path, 'knowledge_data'));
  if (!await dataDir.exists()) {
    await dataDir.create(recursive: true);
  }

  const assetFiles = ['books.json', 'knowledge.json', 'questions.json'];
  for (final name in assetFiles) {
    final dest = File(p.join(dataDir.path, name));
    if (await dest.exists()) continue;
    try {
      final content = await rootBundle.loadString('assets/data/$name');
      await dest.writeAsString(content, flush: true);
    } catch (_) {
      // アセットにないファイルは無視
    }
  }

  return dataDir.path;
}
