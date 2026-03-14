// 「if節のない仮定法：I wish」を仮定法セクションに表示するよう DB を修正（REST で実行・ダッシュボード不要）
// 実行: dart run scripts/fix_i_wish_card_position.dart

import 'dart:convert';
import 'dart:io';

const baseUrl = 'https://wnufzrehvhcwclnwxwim.supabase.co/rest/v1';
const anonKey = 'sb_publishable_6ZOloNwIgIFjF9SKRLGgmA_Yc55g0es';
const targetContent = 'if節のない仮定法：I wish';

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

Future<dynamic> httpPatch(String path, Map<String, dynamic> body) async {
  final uri = Uri.parse('$baseUrl$path');
  final req = await HttpClient().openUrl('PATCH', uri);
  req.headers.add('apikey', anonKey);
  req.headers.add('Authorization', 'Bearer $anonKey');
  req.headers.add('Content-Type', 'application/json');
  req.headers.add('Prefer', 'return=representation');
  req.add(utf8.encode(jsonEncode(body)));
  final res = await req.close();
  final resBody = await res.transform(utf8.decoder).join();
  if (res.statusCode >= 400) {
    throw Exception('PATCH $path: ${res.statusCode} $resBody');
  }
  return resBody.isEmpty ? null : jsonDecode(resBody);
}

Future<void> main() async {
  print('Fix: "$targetContent" -> unit=仮定法, display_order=16');
  final encoded = Uri.encodeComponent(targetContent);
  final path = '/knowledge?select=id,content,unit&content=eq.$encoded';
  final list = await httpGet(path);
  if (list is! List || list.isEmpty) {
    print('No row found with content="$targetContent".');
    exit(1);
  }
  if (list.length > 1) {
    print('Multiple rows found; updating all.');
  }
  var updated = 0;
  for (final row in list) {
    final id = (row as Map<String, dynamic>)['id']?.toString();
    if (id == null) continue;
    final body = <String, dynamic>{'unit': '仮定法', 'display_order': 16};
    try {
      await httpPatch('/knowledge?id=eq.$id', body);
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('display_order') || msg.contains('column')) {
        await httpPatch('/knowledge?id=eq.$id', {'unit': '仮定法'});
      } else {
        rethrow;
      }
    }
    updated++;
  }
  print('Updated $updated row(s). Done.');
}
