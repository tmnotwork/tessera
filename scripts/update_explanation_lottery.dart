// 「If I _____ win the lottery...」の解説文だけを Supabase で更新する（1回限り実行可）
// 実行: dart run scripts/update_explanation_lottery.dart

import 'dart:convert';
import 'dart:io';

const baseUrl = 'https://wnufzrehvhcwclnwxwim.supabase.co/rest/v1';
const anonKey = 'sb_publishable_6ZOloNwIgIFjF9SKRLGgmA_Yc55g0es';

const questionText = r'If I _____ win the lottery, I would quit my job.';
const newExplanation = '主節に would があるので仮定法と判断する。'
    'まず仮定法過去（if ＋ 過去形）を考えるが、空欄の直後に動詞の原形 win がある。'
    '仮定法過去なら if 節は過去形1語で終わるので、原形が続く形ではない。'
    'そこで「仮定法未来」（if 節で were to ＋ 原形 または should ＋ 原形）を考える。'
    'したがって (C) were to。will / am to は仮定法の形ではない。would は主節で使う。';

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
