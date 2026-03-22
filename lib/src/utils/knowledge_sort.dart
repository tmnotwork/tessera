import '../models/knowledge.dart';

String _chapterKey(Knowledge k) => (k.unit ?? '').trim();

/// チャプター（[Knowledge.unit]）ごとにまとめ、塊の順序を決めてから塊内で並べる。
///
/// - 塊の順: そのチャプター内の [Knowledge.displayOrder] の最小値が小さいほど先（従来の全体 order の意図を維持）
/// - 最小値が同じチャプター同士: チャプター名で比較（空＝「その他」相当は最後）
/// - チャプター内: [displayOrder] → [id]
void sortKnowledgeByChapterBlocks(List<Knowledge> list) {
  if (list.length <= 1) return;

  final minOrderByChapter = <String, int>{};
  for (final k in list) {
    final key = _chapterKey(k);
    final o = k.displayOrder ?? 0;
    final prev = minOrderByChapter[key];
    if (prev == null || o < prev) minOrderByChapter[key] = o;
  }

  int compareChapterKeys(String a, String b) {
    if (a.isEmpty && b.isNotEmpty) return 1;
    if (a.isNotEmpty && b.isEmpty) return -1;
    return a.compareTo(b);
  }

  list.sort((a, b) {
    final ka = _chapterKey(a);
    final kb = _chapterKey(b);
    final ra = minOrderByChapter[ka] ?? 0;
    final rb = minOrderByChapter[kb] ?? 0;
    if (ra != rb) return ra.compareTo(rb);
    final ck = compareChapterKeys(ka, kb);
    if (ck != 0) return ck;
    final oa = a.displayOrder ?? 0;
    final ob = b.displayOrder ?? 0;
    if (oa != ob) return oa.compareTo(ob);
    return a.id.compareTo(b.id);
  });
}
