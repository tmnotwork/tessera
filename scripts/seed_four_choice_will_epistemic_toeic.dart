// 「will(2)推量」の知識カード向け・TOEIC Part 5 風の四択問題を登録
// 実行: dart run scripts/seed_four_choice_will_epistemic_toeic.dart
//
// 正解一意・推量の will（特に will have + 過去分詞）を知っていないと解けないようにする。

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
      knowledgeTitle: 'will(2)推量',
      questionText:
          r'By now you _____ the revised schedule we posted on the intranet this morning.',
      choices: [
        'will have seen',
        'see',
        'are seeing',
        'saw',
      ],
      correctIndex: 0,
      explanation: '**By now**（いまごろにはもう）と「朝に投稿した」とあるので、「相手はすでに～している**だろう**」という**話し手の推測**を表す。'
          'ここで学ぶ推量の will のかたちは **will have + 過去分詞**（教材の *You will have heard the news.* と同型）。'
          'したがって (A) will have seen。**see** は単純現在で時制が合わない。**are seeing** は「見ている最中」で、すでに目を通したという完了の推測にならない。**saw** だけでは by now と結びつきにくく、かつここでは推量の定型ではない。',
    ),
    (
      knowledgeTitle: 'will(2)推量',
      questionText:
          r'By the time you read this memo, the maintenance team _____ the server issue.',
      choices: [
        'will have fixed',
        'will fix',
        'fixes',
        'is fixing',
      ],
      correctIndex: 0,
      explanation: '**By the time you read this**（あなたがこれを読むころには）は「その時点までにすでに～している**だろう**」という見込み・推量に **will have + 過去分詞** を使う。'
          '単純未来の **will fix** や現在の **fixes** では、「読むころには**もう直し終えている**」という**完了＋推測**が表せない。**is fixing** は進行中だけで、完了の見込みにならない。したがって (A) will have fixed。',
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
  }

  print('');
  print('完了。${items.length} 問を登録しました（同一知識タイトルに複数問）。');
}
