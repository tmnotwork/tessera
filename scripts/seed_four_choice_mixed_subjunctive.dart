// 「混合仮定法」の知識カードに対応する四択問題を1問登録
// 実行: dart run scripts/seed_four_choice_mixed_subjunctive.dart

import 'dart:convert';
import 'dart:io';

const baseUrl = 'https://wnufzrehvhcwclnwxwim.supabase.co/rest/v1';
const anonKey = 'sb_publishable_6ZOloNwIgIFjF9SKRLGgmA_Yc55g0es';

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
  if (res.statusCode >= 400) {
    throw Exception('POST $path: ${res.statusCode} $resBody');
  }
  return jsonDecode(resBody);
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
  const knowledgeTitle = '混合仮定法';
  const questionText = r'If I _____ harder in college, I would have a better job now.';
  const choices = ['studied', 'had studied', 'would study', 'have studied'];
  const correctIndex = 1; // had studied
  const explanation = '主節が would have a better job now なので「今の結果」を表す混合仮定法。'
      'if 節は過去の条件だから had ＋ 過去分詞。したがって (B) had studied。'
      'studied は仮定法過去（主節は would ＋ 原形とペア）。would study / have studied は if 節の形として不適切。';

  print('知識カード「$knowledgeTitle」の四択問題を登録します。');

  final encoded = Uri.encodeComponent(knowledgeTitle);
  final list = await httpGet('/knowledge?select=id,content&content=eq.$encoded');
  if (list is! List || list.isEmpty) {
    print('エラー: 知識カード「$knowledgeTitle」が見つかりません。');
    exit(1);
  }
  final knowledgeId = (list.first as Map<String, dynamic>)['id'] as String?;
  if (knowledgeId == null) {
    print('エラー: 知識IDを取得できませんでした。');
    exit(1);
  }

  final inserted = await httpPost('/questions', {
    'knowledge_id': knowledgeId,
    'question_type': 'multiple_choice',
    'question_text': questionText,
    'correct_answer': choices[correctIndex],
    'explanation': explanation,
  });
  final resList = inserted is List && inserted.isNotEmpty ? inserted : [inserted];
  final questionId = (resList.first as Map<String, dynamic>)['id'] as String?;
  if (questionId == null) {
    print('エラー: 問題の登録に失敗しました。');
    exit(1);
  }

  try {
    for (var j = 0; j < 4; j++) {
      await httpPost('/question_choices', {
        'question_id': questionId,
        'position': j + 1,
        'choice_text': choices[j],
        'is_correct': j == correctIndex,
      });
    }
  } catch (_) {
    await httpPatch('/questions?id=eq.$questionId', {'choices': choices});
  }
  try {
    await httpPost('/question_knowledge', {
      'question_id': questionId,
      'knowledge_id': knowledgeId,
    });
  } catch (_) {}

  print('登録済: question_id=$questionId');
  print('出題: $questionText');
  print('正解: (${String.fromCharCode(65 + correctIndex)}) ${choices[correctIndex]}');
  print('');
  print('完了。');
}
