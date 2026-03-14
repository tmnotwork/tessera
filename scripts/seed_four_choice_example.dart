// 「仮定法過去（現在の妄想）」の四択問題を作り直し＋主節穴埋め1問追加
// 実行: dart run scripts/seed_four_choice_example.dart
//
// 注意: 正解が一意・知識理解が前提・解説は正解に至る思考を端的に。

import 'dart:convert';
import 'dart:io';

const baseUrl = 'https://wnufzrehvhcwclnwxwim.supabase.co/rest/v1';
const anonKey = 'sb_publishable_6ZOloNwIgIFjF9SKRLGgmA_Yc55g0es';
const knowledgeTitle = '仮定法過去（現在の妄想）';

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
  final resBody = await res.transform(utf8.decoder).join();
  if (res.statusCode >= 400) {
    throw Exception('PATCH $path: ${res.statusCode} $resBody');
  }
}

Future<void> httpDelete(String path) async {
  final uri = Uri.parse('$baseUrl$path');
  final req = await HttpClient().openUrl('DELETE', uri);
  req.headers.add('apikey', anonKey);
  req.headers.add('Authorization', 'Bearer $anonKey');
  final res = await req.close();
  final resBody = await res.transform(utf8.decoder).join();
  if (res.statusCode >= 400) {
    throw Exception('DELETE $path: ${res.statusCode} $resBody');
  }
}

void main() async {
  print('0) 知識カード「$knowledgeTitle」の ID を取得...');
  final encoded = Uri.encodeComponent(knowledgeTitle);
  final list = await httpGet('/knowledge?select=id,content&content=eq.$encoded');
  if (list is! List || list.isEmpty) {
    print('エラー: 知識カード「$knowledgeTitle」が見つかりません。');
    print('アプリの知識DBで該当カードが存在するか確認してください。');
    exit(1);
  }
  final knowledgeId = (list.first as Map<String, dynamic>)['id'] as String?;
  if (knowledgeId == null) {
    print('エラー: 知識IDを取得できませんでした。');
    exit(1);
  }
  print('   knowledge_id: $knowledgeId');

  // 既存の「仮定法過去（現在の妄想）」紐づけ問題を削除（作り直しのため）
  print('0.5) 同一知識に紐づく既存の四択問題を削除...');
  List<String> existingQuestionIds = [];
  try {
    final qkList = await httpGet('/question_knowledge?knowledge_id=eq.$knowledgeId&select=question_id');
    if (qkList is List && qkList.isNotEmpty) {
      for (final row in qkList) {
        final qid = (row as Map<String, dynamic>)['question_id'] as String?;
        if (qid != null) existingQuestionIds.add(qid);
      }
    }
  } catch (_) {
    // question_knowledge が無いスキーマ: knowledge_id で直接検索
    final qList = await httpGet('/questions?knowledge_id=eq.$knowledgeId&select=id');
    if (qList is List && qList.isNotEmpty) {
      for (final row in qList) {
        final qid = (row as Map<String, dynamic>)['id'] as String?;
        if (qid != null) existingQuestionIds.add(qid);
      }
    }
  }
  for (final qid in existingQuestionIds) {
    try { await httpDelete('/question_choices?question_id=eq.$qid'); } catch (_) {}
    try { await httpDelete('/question_knowledge?question_id=eq.$qid&knowledge_id=eq.$knowledgeId'); } catch (_) {}
    await httpDelete('/questions?id=eq.$qid');
  }
  if (existingQuestionIds.isNotEmpty) {
    print('   既存問題を ${existingQuestionIds.length} 件削除しました。');
  } else {
    print('   削除対象の既存問題はありません。');
  }

  // --- 問1: if 節穴埋め（仮定法過去の if 節は過去形）---
  const q1Text = r'If the manager _____ more staff, the project would be completed on schedule.';
  const q1Choices = ['has', 'had', 'would have', 'had had'];
  const q1CorrectIndex = 1; // had
  const q1Explanation = '主節が would be completed なので「現在の妄想」の仮定法過去。'
      '仮定法過去では if 節に過去形を置く。したがって (B) had。'
      'has は直説法、would have / had had は if 節の形として不適切。';

  print('1) 四択問題（if 節穴埋め）を登録...');
  final inserted1 = await httpPost('/questions', {
    'knowledge_id': knowledgeId,
    'question_type': 'multiple_choice',
    'question_text': q1Text,
    'correct_answer': q1Choices[q1CorrectIndex],
    'explanation': q1Explanation,
  });
  final resList1 = inserted1 is List && inserted1.isNotEmpty ? inserted1 : [inserted1];
  final questionId1 = (resList1.first as Map<String, dynamic>)['id'] as String?;
  if (questionId1 == null) {
    print('エラー: 問題1の登録に失敗しました。');
    exit(1);
  }
  try {
    for (var i = 0; i < 4; i++) {
      await httpPost('/question_choices', {
        'question_id': questionId1,
        'position': i + 1,
        'choice_text': q1Choices[i],
        'is_correct': i == q1CorrectIndex,
      });
    }
  } catch (_) {
    await httpPatch('/questions?id=eq.$questionId1', {'choices': q1Choices});
  }
  try {
    await httpPost('/question_knowledge', {
      'question_id': questionId1,
      'knowledge_id': knowledgeId,
    });
  } catch (_) {}
  print('   question_id: $questionId1');

  // --- 問2: 主節穴埋め（仮定法過去の主節は would + 原形）---
  const q2Text = r'If she were here now, she _____ us with the preparation.';
  const q2Choices = ['helps', 'helped', 'would help', 'would have helped'];
  const q2CorrectIndex = 2; // would help
  const q2Explanation = 'if 節が were here now なので「現在の妄想」の仮定法過去。'
      '主節は would + 動詞の原形になる。したがって (C) would help。'
      'helps / helped は仮定法の形ではない。would have helped は過去の妄想の主節なので不適切。';

  print('2) 四択問題（主節穴埋め）を登録...');
  final inserted2 = await httpPost('/questions', {
    'knowledge_id': knowledgeId,
    'question_type': 'multiple_choice',
    'question_text': q2Text,
    'correct_answer': q2Choices[q2CorrectIndex],
    'explanation': q2Explanation,
  });
  final resList2 = inserted2 is List && inserted2.isNotEmpty ? inserted2 : [inserted2];
  final questionId2 = (resList2.first as Map<String, dynamic>)['id'] as String?;
  if (questionId2 == null) {
    print('エラー: 問題2の登録に失敗しました。');
    exit(1);
  }
  try {
    for (var i = 0; i < 4; i++) {
      await httpPost('/question_choices', {
        'question_id': questionId2,
        'position': i + 1,
        'choice_text': q2Choices[i],
        'is_correct': i == q2CorrectIndex,
      });
    }
  } catch (_) {
    await httpPatch('/questions?id=eq.$questionId2', {'choices': q2Choices});
  }
  try {
    await httpPost('/question_knowledge', {
      'question_id': questionId2,
      'knowledge_id': knowledgeId,
    });
  } catch (_) {}
  print('   question_id: $questionId2');

  print('');
  print('完了。四択問題を2件登録しました。');
  print('');
  print('【問1: if 節穴埋め】');
  print(q1Text);
  print('(A) ${q1Choices[0]}  (B) ${q1Choices[1]}  (C) ${q1Choices[2]}  (D) ${q1Choices[3]}');
  print('正解: (${String.fromCharCode(65 + q1CorrectIndex)}) ${q1Choices[q1CorrectIndex]}');
  print('');
  print('【問2: 主節穴埋め】');
  print(q2Text);
  print('(A) ${q2Choices[0]}  (B) ${q2Choices[1]}  (C) ${q2Choices[2]}  (D) ${q2Choices[3]}');
  print('正解: (${String.fromCharCode(65 + q2CorrectIndex)}) ${q2Choices[q2CorrectIndex]}');
}
