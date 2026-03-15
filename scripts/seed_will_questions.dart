// will 関連の四択問題・暗記カードを Supabase に投入
// 実行: dart run scripts/seed_will_questions.dart
// 前提: 知識カード will(1)〜(5) が既に存在すること（assets/knowledge.json から seed_supabase で投入済み想定）

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
  if (res.statusCode >= 400) throw Exception('POST $path: ${res.statusCode} $resBody');
  return resBody.isEmpty ? null : jsonDecode(resBody);
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

Future<void> httpDelete(String path) async {
  final uri = Uri.parse('$baseUrl$path');
  final req = await HttpClient().openUrl('DELETE', uri);
  req.headers.add('apikey', anonKey);
  req.headers.add('Authorization', 'Bearer $anonKey');
  final res = await req.close();
  if (res.statusCode >= 400) {
    final body = await res.transform(utf8.decoder).join();
    throw Exception('DELETE $path: ${res.statusCode} $body');
  }
}

Future<String?> getKnowledgeIdByContent(String content) async {
  final encoded = Uri.encodeComponent(content);
  final list = await httpGet('/knowledge?select=id&content=eq.$encoded');
  if (list is! List || list.isEmpty) return null;
  return (list.first as Map<String, dynamic>)['id'] as String?;
}

Future<void> deleteExistingQuestionsForKnowledge(String knowledgeId) async {
  List<String> questionIds = [];
  try {
    final qkList = await httpGet('/question_knowledge?knowledge_id=eq.$knowledgeId&select=question_id');
    if (qkList is List && qkList.isNotEmpty) {
      for (final row in qkList) {
        final qid = (row as Map<String, dynamic>)['question_id'] as String?;
        if (qid != null) questionIds.add(qid);
      }
    }
  } catch (_) {
    final qList = await httpGet('/questions?knowledge_id=eq.$knowledgeId&select=id');
    if (qList is List && qList.isNotEmpty) {
      for (final row in qList) {
        final qid = (row as Map<String, dynamic>)['id'] as String?;
        if (qid != null) questionIds.add(qid);
      }
    }
  }
  for (final qid in questionIds) {
    try { await httpDelete('/question_choices?question_id=eq.$qid'); } catch (_) {}
    try { await httpDelete('/question_knowledge?question_id=eq.$qid'); } catch (_) {}
    await httpDelete('/questions?id=eq.$qid');
  }
}

/// question_choices テーブルが無い環境では questions.choices (JSONB) に保存する
Future<void> insertFourChoice(
  String knowledgeId,
  String questionText,
  List<String> choices,
  int correctIndex,
  String explanation,
) async {
  final res = await httpPost('/questions', {
    'knowledge_id': knowledgeId,
    'question_type': 'multiple_choice',
    'question_text': questionText,
    'correct_answer': choices[correctIndex],
    'explanation': explanation,
  });
  final list = res is List && res.isNotEmpty ? res : [res];
  final questionId = (list.first as Map<String, dynamic>)['id'] as String?;
  if (questionId == null) throw Exception('Failed to insert question');

  bool useChoicesTable = false;
  try {
    await httpPost('/question_choices', {
      'question_id': questionId,
      'position': 1,
      'choice_text': choices[0],
      'is_correct': correctIndex == 0,
    });
    useChoicesTable = true;
  } catch (e) {
    if (e.toString().contains('404') || e.toString().contains('question_choices')) {
      await httpPatch('/questions?id=eq.$questionId', {'choices': choices});
    } else {
      rethrow;
    }
  }
  if (useChoicesTable) {
    for (var i = 1; i < choices.length; i++) {
      await httpPost('/question_choices', {
        'question_id': questionId,
        'position': i + 1,
        'choice_text': choices[i],
        'is_correct': i == correctIndex,
      });
    }
  }

  try {
    await httpPost('/question_knowledge', {'question_id': questionId, 'knowledge_id': knowledgeId});
  } catch (_) {}
}

/// memorization_cards テーブルが無い環境では何もしない
Future<void> deleteExistingMemorizationForKnowledge(String knowledgeId) async {
  try {
    final list = await httpGet('/memorization_cards?knowledge_id=eq.$knowledgeId&select=id');
    if (list is! List || list.isEmpty) return;
    for (final row in list) {
      final id = (row as Map<String, dynamic>)['id'] as String?;
      if (id != null) await httpDelete('/memorization_cards?id=eq.$id');
    }
  } catch (_) {}
}

/// memorization_cards テーブルが無い環境ではスキップ（false を返す）
Future<bool> insertMemorizationCard(String knowledgeId, String front, String back) async {
  try {
    await httpPost('/memorization_cards', {
      'knowledge_id': knowledgeId,
      'front_content': front,
      'back_content': back,
    });
    return true;
  } catch (e) {
    if (e.toString().contains('404') || e.toString().contains('memorization_cards')) {
      return false;
    }
    rethrow;
  }
}

void main() async {
  const knowledgeTitles = [
    'will(1)単純未来',
    'will(2)推量',
    'will(3)強い意思',
    'will(4)拒絶',
    'will(5)習性',
  ];
  print('0) 知識カード ID を取得...');
  final ids = <String, String>{};
  for (final title in knowledgeTitles) {
    final id = await getKnowledgeIdByContent(title);
    if (id == null) {
      print('エラー: 知識カード「$title」が見つかりません。');
      exit(1);
    }
    ids[title] = id;
    print('   $title => $id');
  }

  // ----- will(3)強い意思: 四択 2 問 (Q1, Q4) -----
  final strongWillId = ids['will(3)強い意思']!;
  print('1) will(3)強い意思: 既存問題削除 → 四択2問登録...');
  await deleteExistingQuestionsForKnowledge(strongWillId);

  await insertFourChoice(
    strongWillId,
    r'I promise: no matter what happens, I _____ stand by you.',
    ['will', 'would', 'can', 'may'],
    0,
    '「I promise」の後では「必ず〜する」という意志の約束に will が使われる。would は仮定、can は能力、may は可能性で、ここでは意志の will のみが自然。',
  );
  await insertFourChoice(
    strongWillId,
    r"Don't worry. I _____ help you with the report. I promise.",
    ['will', 'would', 'can', 'may'],
    0,
    '「I promise」と続くので、ここでは「必ず手伝う」という意志の約束が求められる。would は仮定、can は能力、may は可能性で、約束の宣言として適切なのは意志の will のみ。',
  );
  print('   四択2問を登録しました。');

  // ----- will(1)単純未来: 四択 1 問 (Q2) -----
  final simpleFutureId = ids['will(1)単純未来']!;
  print('2) will(1)単純未来: 既存問題削除 → 四択1問登録...');
  await deleteExistingQuestionsForKnowledge(simpleFutureId);
  await insertFourChoice(
    simpleFutureId,
    r'The conference _____ at 9 a.m. tomorrow.',
    ['will start', 'would have started', 'started', 'has started'],
    0,
    'tomorrow があるので未来の出来事を述べる形が必要。would have started / started / has started は過去・完了で tomorrow と矛盾する。単純未来の will start のみ適切。',
  );
  print('   四択1問を登録しました。');

  // ----- will(2)推量: 四択 1 問 -----
  final guessId = ids['will(2)推量']!;
  print('3) will(2)推量: 既存問題削除 → 四択1問登録...');
  await deleteExistingQuestionsForKnowledge(guessId);
  await insertFourChoice(
    guessId,
    '「Who is the man talking to the teacher?」\n「Oh, that _____ be Mr. Harrison, the new English teacher.」',
    ['will', 'had better', 'would rather', 'shall'],
    0,
    '「誰？」への「あれはハリソン先生だろう」は That will be ～ の推量。had better は勧告、would rather は希望、shall は That 主語では使わない。',
  );
  print('   四択1問を登録しました。');

  // ----- will(4)拒絶: 暗記カード 1 枚（和文英訳） -----
  final refusalId = ids['will(4)拒絶']!;
  print('4) will(4)拒絶: 既存暗記カード削除 → 1枚登録（和文英訳）...');
  await deleteExistingMemorizationForKnowledge(refusalId);
  final ok4 = await insertMemorizationCard(
    refusalId,
    'その子は野菜を食べようとしない。',
    'The child won\'t eat the vegetables.',
  );
  if (ok4) {
    print('   暗記カード1枚を登録しました。');
  } else {
    print('   スキップ（memorization_cards テーブルがありません）。');
  }

  // ----- will(5)習性: 四択 1 問 (Q6) -----
  final habitId = ids['will(5)習性']!;
  print('5) will(5)習性: 既存問題削除 → 四択1問登録...');
  await deleteExistingQuestionsForKnowledge(habitId);
  await insertFourChoice(
    habitId,
    r"She _____ often sit there for hours when she has time—it's a habit of hers.",
    ['will', 'would', 'can', 'may'],
    0,
    '「習慣だ」と続くので、ここでは習慣・傾向を表す習性の will が適切。would は過去の習慣で when she has time と時制が合わず、can は能力、may は可能性で習慣の意味にならない。',
  );
  print('   四択1問を登録しました。');

  print('');
  print('完了。will 関連の四択4問・暗記カード2枚を Supabase に反映しました。');
}
