// 知識カード一覧と同じ基準（knowledge.display_order → created_at → 例文 display_order）で並べ替え。
// PostgREST の knowledge:knowledge_id 埋め込み付き english_examples 行向け。

int compareEnglishExampleRowsByKnowledgeOrder(
  Map<String, dynamic> a,
  Map<String, dynamic> b,
) {
  final orderA = knowledgeDisplayOrder(a['knowledge']);
  final orderB = knowledgeDisplayOrder(b['knowledge']);
  if (orderA != orderB) return orderA.compareTo(orderB);

  final createdA = knowledgeCreatedAtIso(a['knowledge']);
  final createdB = knowledgeCreatedAtIso(b['knowledge']);
  final c = createdA.compareTo(createdB);
  if (c != 0) return c;

  final exA = exampleDisplayOrder(a);
  final exB = exampleDisplayOrder(b);
  if (exA != exB) return exA.compareTo(exB);

  final ac = a['created_at']?.toString() ?? '';
  final bc = b['created_at']?.toString() ?? '';
  return ac.compareTo(bc);
}

void sortEnglishExampleRowsLikeKnowledgeList(List<Map<String, dynamic>> rows) {
  rows.sort(compareEnglishExampleRowsByKnowledgeOrder);
}

int knowledgeDisplayOrder(dynamic k) {
  if (k is! Map<String, dynamic>) return 1 << 30;
  return (k['display_order'] as num?)?.toInt() ?? (1 << 29);
}

String knowledgeCreatedAtIso(dynamic k) {
  if (k is! Map<String, dynamic>) return '';
  return k['created_at']?.toString() ?? '';
}

int exampleDisplayOrder(Map<String, dynamic> row) {
  return (row['display_order'] as num?)?.toInt() ?? (1 << 29);
}

/// 単元（チャプター）の並び：その単元に含まれる例文のうち、最も早い知識カード順。
int minKnowledgeDisplayOrderInChapter(Iterable<Map<String, dynamic>> rows) {
  var m = 1 << 30;
  for (final e in rows) {
    final o = knowledgeDisplayOrder(e['knowledge']);
    if (o < m) m = o;
  }
  return m;
}

/// [english_examples] 行（knowledge 埋め込み付き）のチャプター名。知識一覧の unit と同じ。
String englishExampleChapterKeyFromRow(Map<String, dynamic> item) {
  final k = item['knowledge'];
  if (k is Map<String, dynamic>) {
    final u = k['unit']?.toString().trim();
    if (u != null && u.isNotEmpty) return u;
  }
  return '（単元なし）';
}

/// 例文をチャプターごとにまとめ、知識の display_order が早いチャプターを先に並べる。
List<MapEntry<String, List<Map<String, dynamic>>>> groupEnglishExampleRowsByChapter(
  List<Map<String, dynamic>> items,
) {
  final map = <String, List<Map<String, dynamic>>>{};
  for (final item in items) {
    final u = englishExampleChapterKeyFromRow(item);
    map.putIfAbsent(u, () => []).add(item);
  }
  final entries = map.entries.toList()
    ..sort((a, b) {
      final c = minKnowledgeDisplayOrderInChapter(a.value)
          .compareTo(minKnowledgeDisplayOrderInChapter(b.value));
      if (c != 0) return c;
      return a.key.compareTo(b.key);
    });
  return entries;
}
