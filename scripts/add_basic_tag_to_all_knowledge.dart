// 既存の全知識カードに「基本」タグを付与する（Supabase 用）
// 実行: dart run scripts/add_basic_tag_to_all_knowledge.dart
// ※ knowledge_tags / knowledge_card_tags が存在する場合のみ有効です。

import 'dart:convert';
import 'dart:io';

const baseUrl = 'https://wnufzrehvhcwclnwxwim.supabase.co/rest/v1';
const anonKey = 'sb_publishable_6ZOloNwIgIFjF9SKRLGgmA_Yc55g0es';
const tagName = '基本';

Future<dynamic> httpGet(String path) async {
  final uri = Uri.parse('$baseUrl$path');
  final req = await HttpClient().getUrl(uri);
  req.headers.add('apikey', anonKey);
  req.headers.add('Authorization', 'Bearer $anonKey');
  final res = await req.close();
  final body = await res.transform(utf8.decoder).join();
  if (res.statusCode >= 400) throw Exception('GET $path: ${res.statusCode} $body');
  return body.isEmpty ? null : jsonDecode(body);
}

Future<dynamic> httpPost(String path, Map<String, dynamic> body) async {
  final uri = Uri.parse('$baseUrl$path');
  final req = await HttpClient().postUrl(uri);
  req.headers.add('apikey', anonKey);
  req.headers.add('Authorization', 'Bearer $anonKey');
  req.headers.add('Content-Type', 'application/json');
  req.headers.add('Prefer', 'return=representation');
  req.add(utf8.encode(jsonEncode(body)));
  final res = await req.close();
  final resBody = await res.transform(utf8.decoder).join();
  if (res.statusCode >= 400) throw Exception('POST $path: ${res.statusCode} $resBody');
  return jsonDecode(resBody);
}

void main() async {
  print('全知識カードに「$tagName」タグを付与します。');
  try {
    // 1) タグ「基本」の ID を取得 or 作成
    final encoded = Uri.encodeComponent(tagName);
    var tagList = await httpGet('/knowledge_tags?name=eq.$encoded&select=id');
    if (tagList is! List || tagList.isEmpty) {
      final inserted = await httpPost('/knowledge_tags', {'name': tagName});
      final row = inserted is List && inserted.isNotEmpty ? inserted.first : inserted;
      tagList = [row];
    }
    final tagId = (tagList.first as Map<String, dynamic>)['id'] as String?;
    if (tagId == null) {
      print('エラー: タグIDを取得できませんでした。');
      exit(1);
    }
    print('タグ「$tagName」 id=$tagId');

    // 2) 全知識 ID を取得
    final knowledgeRows = await httpGet('/knowledge?select=id');
    if (knowledgeRows is! List || knowledgeRows.isEmpty) {
      print('知識カードが0件です。');
      exit(0);
    }
    final ids = knowledgeRows.map((r) => (r as Map<String, dynamic>)['id'] as String?).whereType<String>().toList();
    print('知識カード ${ids.length} 件');

    // 3) 既に「基本」が付いている knowledge_id を取得
    final existing = await httpGet('/knowledge_card_tags?tag_id=eq.$tagId&select=knowledge_id');
    final existingIds = <String>{};
    if (existing is List) {
      for (final r in existing) {
        final kid = (r as Map<String, dynamic>)['knowledge_id']?.toString();
        if (kid != null) existingIds.add(kid);
      }
    }

    // 4) 付いていないカードにだけ挿入
    int added = 0;
    for (final kid in ids) {
      if (existingIds.contains(kid)) continue;
      await httpPost('/knowledge_card_tags', {'knowledge_id': kid, 'tag_id': tagId});
      added++;
    }
    print('「$tagName」を $added 件のカードに付与しました。');
  } catch (e) {
    final msg = e.toString();
    if (msg.contains('knowledge_tags') ||
        msg.contains('knowledge_card_tags') ||
        msg.contains('PGRST204') ||
        msg.contains('relation') ||
        msg.contains('does not exist')) {
      print('knowledge_tags / knowledge_card_tags テーブルが存在しないためスキップしました。');
      print('（assets/knowledge.json のタグは既に「基本」に更新済みです）');
      exit(0);
    }
    rethrow;
  }
}
