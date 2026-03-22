// Supabase に英文法の科目＋knowledge＋questions を投入する Dart スクリプト
// 実行: dart run scripts/seed_supabase.dart
// 前提: supabase/apply_schema.sql をダッシュボードで実行済みであること

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
  return resBody.isEmpty ? null : jsonDecode(resBody);
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

Future<void> main() async {
  var projectRoot = Directory.current.path;
  if (projectRoot.endsWith('scripts')) {
    projectRoot = Directory(projectRoot).parent.path;
  }
  final assetPath = Platform.isWindows
      ? '$projectRoot\\assets'
      : '$projectRoot/assets';
  final knowledgePath = Platform.isWindows
      ? '$assetPath\\knowledge.json'
      : '$assetPath/knowledge.json';
  final questionsPath = Platform.isWindows
      ? '$assetPath\\questions.json'
      : '$assetPath/questions.json';

  print('1) Get or create subject 英文法...');
  var subjectId = await getOrCreateSubject();
  print('   Subject id: $subjectId');

  print('2) Delete existing 英文法 knowledge and questions...');
  await deleteEnglishGrammarData(subjectId);

  print('3) Insert knowledge from assets/knowledge.json...');
  final knowledgeJson = await File(knowledgePath).readAsString(encoding: utf8);
  final knowledgeList = jsonDecode(knowledgeJson) as List;
  final idMap = <String, String>{};
  var kCount = 0;
  for (final raw in knowledgeList) {
    final m = raw as Map<String, dynamic>;
    final assetId = m['id']?.toString();
    final topic = m['topic']?.toString()?.trim() ?? '';
    final title = m['title']?.toString()?.trim() ?? '';
    if (title.isEmpty || assetId == null) continue;
    final explanation = m['explanation']?.toString()?.trim();
    final order = m['order'];
    final displayOrder = order is int ? order : (order != null ? int.tryParse(order.toString()) : null);
    final res = await httpPost('/knowledge', {
      'subject_id': subjectId,
      'subject': '英文法',
      'unit': topic.isEmpty ? null : topic,
      'content': title,
      'description': explanation,
      if (displayOrder != null) 'display_order': displayOrder,
    });
    final newId = res is List && res.isNotEmpty
        ? (res.first as Map)['id']?.toString()
        : (res as Map?)?['id']?.toString();
    if (newId != null) {
      idMap[assetId] = newId;
      kCount++;
      final tags = m['tags'];
      if (tags is List) {
        for (final t in tags) {
          final tagName = t?.toString().trim() ?? '';
          if (tagName.isEmpty) continue;
          final tagId = await getOrCreateKnowledgeTag(tagName);
          await httpPost('/knowledge_card_tags', {
            'knowledge_id': newId,
            'tag_id': tagId,
          });
        }
      }
    }
  }
  print('   Inserted knowledge: $kCount');

  print('4) Insert questions from assets/questions.json...');
  final questionsJson = await File(questionsPath).readAsString(encoding: utf8);
  final questionsList = jsonDecode(questionsJson) as List;
  var qCount = 0;
  for (final raw in questionsList) {
    final m = raw as Map<String, dynamic>;
    final questionText = m['question']?.toString()?.trim() ?? '';
    final correctAnswer = m['answer']?.toString()?.trim() ?? '';
    if (questionText.isEmpty || correctAnswer.isEmpty) continue;
    final kidList = m['knowledge_ids'];
    final kid = (kidList is List && kidList.isNotEmpty)
        ? kidList.first?.toString()
        : null;
    final targetKnowledgeId = kid != null ? idMap[kid] : null;
    if (targetKnowledgeId == null) continue;
    final explanation = m['explanation']?.toString()?.trim();
    await httpPost('/questions', {
      'knowledge_id': targetKnowledgeId,
      'question_type': 'text_input',
      'question_text': questionText,
      'correct_answer': correctAnswer,
      'explanation': explanation,
    });
    qCount++;
  }
  print('   Inserted questions: $qCount');

  print('5) Verify...');
  final subCheck = await httpGet('/subjects?select=id,name,display_order');
  final kCheck = await httpGet('/knowledge?subject_id=eq.$subjectId&select=id');
  final qCheck = await httpGet('/questions?select=id');
  final kCountCheck = kCheck is List ? kCheck.length : 0;
  final qCountCheck = qCheck is List ? qCheck.length : 0;
  print('   subjects: ${subCheck is List ? subCheck.length : 0}');
  print('   knowledge(英文法): $kCountCheck');
  print('   questions: $qCountCheck');
  print('Done. Supabase has full 英文法 data.');
}

Future<String> getOrCreateKnowledgeTag(String name) async {
  final encoded = Uri.encodeQueryComponent(name);
  final list = await httpGet('/knowledge_tags?name=eq.$encoded&select=id');
  if (list is List && list.isNotEmpty) {
    return (list.first as Map)['id']?.toString() ?? '';
  }
  final created = await httpPost('/knowledge_tags', {'name': name});
  final id = created is List && created.isNotEmpty
      ? (created.first as Map)['id']?.toString()
      : (created as Map?)?['id']?.toString();
  if (id == null || id.isEmpty) throw Exception('Failed to create knowledge tag: $name');
  return id;
}

Future<String> getOrCreateSubject() async {
  final list = await httpGet('/subjects?name=eq.%E8%8B%B1%E6%96%87%E6%B3%95&select=id');
  if (list is List && list.isNotEmpty) {
    return (list.first as Map)['id']?.toString() ?? '';
  }
  final created = await httpPost('/subjects', {
    'name': '英文法',
    'display_order': 1,
  });
  final id = created is List && created.isNotEmpty
      ? (created.first as Map)['id']?.toString()
      : (created as Map?)?['id']?.toString();
  if (id == null) throw Exception('Failed to create subject');
  return id;
}

Future<void> deleteEnglishGrammarData(String subjectId) async {
  final kList = await httpGet('/knowledge?subject_id=eq.$subjectId&select=id');
  if (kList is! List || kList.isEmpty) return;
  for (final k in kList) {
    final kid = (k as Map)['id']?.toString();
    if (kid == null) continue;
    await httpDelete('/questions?knowledge_id=eq.$kid');
  }
  for (final k in kList) {
    final kid = (k as Map)['id']?.toString();
    if (kid == null) continue;
    await httpDelete('/knowledge?id=eq.$kid');
  }
  print('   Deleted ${kList.length} knowledge rows');
}
