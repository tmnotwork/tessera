// 「仮定法過去（未来の妄想）」〜「仮定法未来」の知識カードに対応する四択問題を登録
// 実行: dart run scripts/seed_four_choice_subjunctive_range.dart
//
// 注意: 正解が一意・知識理解が前提・解説は正解に至る思考を端的に。

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
  final items = [
    (
      knowledgeTitle: '仮定法過去（未来の妄想）',
      questionText: r'If it _____ tomorrow, we would cancel the picnic.',
      choices: ['rains', 'rained', 'will rain', 'had rained'],
      correctIndex: 1,
      explanation: '主節が would cancel なので仮定法過去。仮定法過去では if 節に過去形を使う。'
          '未来（tomorrow）の話でも形は同じ。したがって (B) rained。'
          'rains / will rain は直説法。had rained は仮定法過去完了で主節 would have とペアになる。',
    ),
    (
      knowledgeTitle: '仮定法のbe動詞',
      questionText: r'If he _____ here now, he would help us.',
      choices: ['was', 'were', 'is', 'had been'],
      correctIndex: 1,
      explanation: '主節が would help なので仮定法過去。仮定法過去の if 節で be 動詞は主語が何でも were。'
          'したがって (B) were。was は直説法、is は直説法現在、had been は仮定法過去完了の形。',
    ),
    (
      knowledgeTitle: '仮定法過去完了（過去の妄想）',
      questionText: r'If she _____ harder, she would have passed the exam.',
      choices: ['studied', 'had studied', 'would study', 'has studied'],
      correctIndex: 1,
      explanation: '主節が would have passed なので「過去の妄想」の仮定法過去完了。'
          'if 節は had ＋ 過去分詞。したがって (B) had studied。'
          'studied は仮定法過去（主節 would pass）。would study / has studied は if 節の形として不適切。',
    ),
    (
      knowledgeTitle: '仮定法未来',
      questionText: r'If I _____ win the lottery, I would quit my job.',
      choices: ['will', 'would', 'were to', 'am to'],
      correctIndex: 2,
      explanation: '主節に would があるので仮定法と判断する。'
          'まず仮定法過去（if ＋ 過去形）を考えるが、空欄の直後に動詞の原形 win がある。'
          '仮定法過去なら if 節は過去形1語で終わるので、原形が続く形ではない。'
          'そこで「仮定法未来」（if 節で were to ＋ 原形 または should ＋ 原形）を考える。'
          'したがって (C) were to。will / am to は仮定法の形ではない。would は主節で使う。',
    ),
  ];

  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    print('');
    print('=== ${i + 1}/${items.length}: ${item.knowledgeTitle} ===');

    final encoded = Uri.encodeComponent(item.knowledgeTitle);
    final list = await httpGet('/knowledge?select=id,content&content=eq.$encoded');
    if (list is! List || list.isEmpty) {
      print('  スキップ: 知識カード「${item.knowledgeTitle}」が見つかりません。');
      continue;
    }
    final knowledgeId = (list.first as Map<String, dynamic>)['id'] as String?;
    if (knowledgeId == null) {
      print('  スキップ: 知識IDを取得できませんでした。');
      continue;
    }

    final inserted = await httpPost('/questions', {
      'knowledge_id': knowledgeId,
      'question_type': 'multiple_choice',
      'question_text': item.questionText,
      'correct_answer': item.choices[item.correctIndex],
      'explanation': item.explanation,
    });
    final resList = inserted is List && inserted.isNotEmpty ? inserted : [inserted];
    final questionId = (resList.first as Map<String, dynamic>)['id'] as String?;
    if (questionId == null) {
      print('  エラー: 問題の登録に失敗しました。');
      continue;
    }

    try {
      for (var j = 0; j < 4; j++) {
        await httpPost('/question_choices', {
          'question_id': questionId,
          'position': j + 1,
          'choice_text': item.choices[j],
          'is_correct': j == item.correctIndex,
        });
      }
    } catch (_) {
      await httpPatch('/questions?id=eq.$questionId', {'choices': item.choices});
    }
    try {
      await httpPost('/question_knowledge', {
        'question_id': questionId,
        'knowledge_id': knowledgeId,
      });
    } catch (_) {}

    print('  登録済: question_id=$questionId');
    print('  出題: ${item.questionText}');
    print('  正解: (${String.fromCharCode(65 + item.correctIndex)}) ${item.choices[item.correctIndex]}');
  }

  print('');
  print('完了。${items.length} 件の知識カード分の四択問題を登録しました。');
}
