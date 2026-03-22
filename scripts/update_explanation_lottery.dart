// 「If I _____ win the lottery...」の解説文だけを Supabase で更新する（1回限り実行可）
// 実行: dart run scripts/update_explanation_lottery.dart

import 'dart:convert';
import 'dart:io';

const baseUrl = 'https://wnufzrehvhcwclnwxwim.supabase.co/rest/v1';
const anonKey = 'sb_publishable_6ZOloNwIgIFjF9SKRLGgmA_Yc55g0es';

const questionText = r'If I _____ win the lottery, I would quit my job.';
const newExplanation = '穴のあとに動詞の原形 **win** が続いているので、「空欄＋原形」がひとかたまりのパターンかどうかを見る。'
    '仮定法**過去**なら if 節は **過去形**（won / were など）で止まり、いきなり別の原形は続けない。'
    'だから **If I won** のあとに **win** は来られない。'
    '一方、仮定法**未来**では **were to ＋ 原形** か **should ＋ 原形** が使える。**were to win** なら文として成立する。'
    'したがって (C) were to。will / would はこの位置では if 節の形にならない。am to もここでの仮定法の型ではない。';

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

Future<void> httpPatch(String path, Map<String, dynamic> body) async {
  final uri = Uri.parse('$baseUrl$path');
  final req = await HttpClient().openUrl('PATCH', uri);
  req.headers.add('apikey', anonKey);
  req.headers.add('Authorization', 'Bearer $anonKey');
  req.headers.add('Content-Type', 'application/json');
  req.add(utf8.encode(jsonEncode(body)));
  final res = await req.close();
  if (res.statusCode >= 400) {
    final resBody = await res.transform(utf8.decoder).join();
    throw Exception('PATCH $path: ${res.statusCode} $resBody');
  }
}

void main() async {
  try {
    final encoded = Uri.encodeComponent(questionText);
    final list = await httpGet('/questions?select=id,question_text&question_text=eq.$encoded');
    if (list is! List || list.isEmpty) {
      print('該当する問題が見つかりませんでした。');
      exit(1);
    }
    final id = (list.first as Map<String, dynamic>)['id'] as String?;
    if (id == null) {
      print('問題IDを取得できませんでした。');
      exit(1);
    }
    await httpPatch('/questions?id=eq.$id', {'explanation': newExplanation});
    print('解説を更新しました。question_id=$id');
  } catch (e) {
    print('エラー: $e');
    exit(1);
  }
}
