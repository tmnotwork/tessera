// 「仮定法未来(1)were to」～「If節のない仮定法：ifの代用になるto不定詞（名詞用法）」の知識カードに対応する四択問題を登録
// 実行: dart run scripts/seed_four_choice_subjunctive_were_to_to_infinitive.dart
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
      knowledgeTitle: '仮定法未来(1)were to',
      questionText: r'If the sun _____ in the west, I would not change my mind.',
      // 誤答に直説法・過去形・過去完了を混ぜない（仮定法未来の形だけにそろえる）
      choices: [
        'were to rise',
        'should rise',
        'were to shine',
        'should shine',
      ],
      correctIndex: 0,
      explanation: '選択肢はすべて仮定法未来（were to / should ＋ 原形）の形にそろえている。'
          '非現実的な「思考実験」には were to が適し、should は万が一の仮定向き。'
          '「太陽が西から昇る」のコロケーションでは動詞は rise。shine は不適。したがって (A) were to rise。',
    ),
    (
      knowledgeTitle: '仮定法未来(2)should',
      questionText: r'If it _____ rain tomorrow, we would cancel the picnic.',
      choices: ['will', 'would', 'should', 'had'],
      correctIndex: 2,
      explanation: '仮定法未来の should は if 節で「万が一～したら」を表す。形は If ＋ 主語 ＋ should ＋ 原形。'
          'したがって (C) should。will は直説法、would は主節で使う、had は仮定法過去完了の形。',
    ),
    (
      knowledgeTitle: '未来の仮定法：were to と should の違い',
      questionText: '「万が一明日雨が降ったら」（可能性は低いが起こりうる）に適する形はどれか。',
      choices: [
        'If it were to rain tomorrow, we would cancel.',
        'If it should rain tomorrow, we would cancel.',
        'If it rained tomorrow, we would cancel.',
        'If it had rained tomorrow, we would cancel.',
      ],
      correctIndex: 1,
      explanation: '万が一・可能性は低いが起こりうる仮定には should を使う。were to はさらに非現実的・思考実験的。'
          'したがって (B)。(A) は were to（きわめて非現実）、(C) は仮定法過去で可だが「万が一」の専用形は should、(D) は過去完了で不適。',
    ),
    (
      knowledgeTitle: '未来の仮定法：should の仮定法・主節の形',
      questionText: "If he should call, _____ him I'm out.",
      choices: ['please tell', 'you would tell', 'you will tell', 'you told'],
      correctIndex: 0,
      explanation: 'If ＋ should ＋ 原形 のとき、主節に命令文が来る形がある。「万が一～したら、…してくれ」という指示。'
          'したがって (A) please tell。would tell / will tell は「伝えてくれ」という依頼にならない。told は時制不整合。',
    ),
    (
      knowledgeTitle: '仮定法：if の省略（倒置）',
      questionText: r'_____ rich, I would travel the world.',
      // If I were も全文なら正しいが、本問は「if なしの倒置」知識のため誤答に含めない（正解の一意性のため）
      choices: ['If I was', 'Were I', 'Had I', 'Was I'],
      correctIndex: 1,
      explanation: '知識カードのポイントは、if を付けずに were と主語を倒置して条件を文頭に置く形（Were I rich = If I were rich）。'
          '空欄に続くのは rich なので、倒置の Were I だけが「金持ちなら」として成立する。'
          'If I was は仮定法では were が標準で、この倒置形の書き方でもない。'
          'Had I のあとに形容詞 rich だけを続ける形は成立しない（完了仮定なら been などが要る）。'
          'Was I を文頭に置いても、この主節 would travel とつながる倒置の条件節にならない。したがって (B) Were I。',
    ),
    (
      knowledgeTitle: 'If節のない仮定法：with / without / but for',
      questionText: r'_____ your help, I would have failed.',
      choices: ['With', 'Without', 'For', 'If'],
      correctIndex: 1,
      explanation: '「～がなければ」は without または but for。主節が would have failed なので過去の妄想。'
          'Without your help = If I had not had your help。したがって (B) Without。With は「あれば」で意味が反対。',
    ),
    (
      knowledgeTitle: 'If節のない仮定法：ifの代用になるto不定詞（副詞用法）',
      questionText: "_____ him speak, you would think he's a native speaker.",
      choices: ['Hearing', 'Hear', 'To hear', 'If you hear'],
      correctIndex: 2,
      explanation: '文頭の to不定詞（副詞用法）が if 節の代用になり「～すれば」の条件を表す。To hear him speak = If you heard him speak。'
          'したがって (C) To hear。Hearing は分詞構文で条件のニュアンスが薄い。Hear / If you hear は主節 would と不整合。',
    ),
    (
      knowledgeTitle: 'If節のない仮定法：ifの代用になるto不定詞（名詞用法）',
      questionText: r'_____ his story would be foolish.',
      choices: ['Believing', 'Believe', 'To believe', 'If we believe'],
      correctIndex: 2,
      explanation: 'to不定詞の名詞用法が主語になり、if の代用として「仮に～したら」のニュアンスを表す。To believe his story = 彼の話を信じること。'
          'したがって (C) To believe。Believing は動名詞でこの構文のポイントではない。Believe は動詞のみで文にならない。If we believe は to不定詞名詞用法の形ではない。',
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
