import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// asset 内の参考書データ（knowledge.json / questions.json）を
/// アプリの DB（Supabase + 任意でローカル）に投入する
class AssetImport {
  AssetImport({required this.localDb});

  final Database? localDb;

  /// インポート結果
  int get knowledgeCount => _knowledgeCount;
  int get questionCount => _questionCount;
  String? get message => _message;

  int _knowledgeCount = 0;
  int _questionCount = 0;
  String? _message;

  /// 参考書データを Supabase（とローカル）に投入する
  Future<void> run() async {
    _knowledgeCount = 0;
    _questionCount = 0;
    _message = null;

    final client = Supabase.instance.client;

    // 1) 科目「英文法」を取得または作成（apply_schema.sql 実行済みであること）
    String? subjectId;
    try {
      final subjectRows = await client
          .from('subjects')
          .select('id')
          .eq('name', '英文法')
          .limit(1);
      if (subjectRows.isNotEmpty) {
        subjectId = subjectRows.first['id']?.toString().trim();
      } else {
        final inserted = await client
            .from('subjects')
            .insert({'name': '英文法', 'display_order': 1})
            .select('id')
            .maybeSingle();
        subjectId = inserted?['id']?.toString().trim();
      }
    } catch (e) {
      throw Exception(
        '科目の取得に失敗しました。'
        ' 先に Supabase の SQL エディタで supabase/apply_schema.sql を実行してデータベースを整えてください。\n$e',
      );
    }
    if (subjectId == null || subjectId.isEmpty) {
      throw Exception(
        '科目「英文法」が取得できません。'
        ' Supabase の SQL エディタで supabase/apply_schema.sql を実行してデータベースを整えてください。',
      );
    }

    // 2) asset から JSON 読み込み
    String knowledgeJson;
    String questionsJson;
    try {
      knowledgeJson = await rootBundle.loadString('asset/knowledge.json');
      questionsJson = await rootBundle.loadString('asset/questions.json');
    } catch (e) {
      throw Exception(
        'アセットの読み込みに失敗しました。'
        ' pubspec.yaml の assets に asset/knowledge.json と asset/questions.json が含まれているか確認してください。\n$e',
      );
    }

    final knowledgeList = jsonDecode(knowledgeJson) as List<dynamic>;
    final questionsList = jsonDecode(questionsJson) as List<dynamic>;

    // 3) 知識を Supabase に投入し、asset id -> supabase id のマップを作る
    final idMap = <String, String>{};
    final now = DateTime.now().toIso8601String();

    for (final raw in knowledgeList) {
      final m = raw as Map<String, dynamic>;
      final assetId = m['id']?.toString();
      final topic = m['topic']?.toString() ?? '';
      final title = m['title']?.toString() ?? '';
      final explanation = m['explanation']?.toString();

      if (assetId == null || title.isEmpty) continue;

      try {
        final inserted = await client.from('knowledge').insert({
          'subject_id': subjectId,
          'subject': '英文法',
          'unit': topic.isEmpty ? null : topic.trim(),
          'content': title.trim(),
          'description': explanation?.trim(),
        }).select('id').maybeSingle();

        final newId = inserted?['id']?.toString();
        if (newId != null) {
          idMap[assetId] = newId;
          _knowledgeCount++;
        }

        // ローカル DB にも同じ内容を投入（同期済みとして）
        if (localDb != null && newId != null) {
          await localDb!.insert('knowledge_local', {
            'subject': '英文法',
            'subject_id': subjectId,
            'unit': topic.isEmpty ? null : topic,
            'content': title,
            'description': explanation,
            'supabase_id': newId,
            'synced': 1,
            'created_at': now,
            'updated_at': now,
          });
        }
      } catch (e, stack) {
        final err = '知識 $assetId 投入エラー: $e';
        _message = (_message ?? '') + '$err\n';
        if (_knowledgeCount == 0) {
          throw Exception(
            '$err\n\n'
            'subject_id が見つからない場合は、Supabase の SQL エディタで '
            'supabase/apply_schema.sql を実行してデータベースを整えてから再度お試しください。\n\n$stack',
          );
        }
      }
    }

    // 4) 問題を Supabase に投入（knowledge_ids の先頭で紐づけ）
    for (final raw in questionsList) {
      final m = raw as Map<String, dynamic>;
      final knowledgeIds = m['knowledge_ids'];
      final kid = (knowledgeIds is List && knowledgeIds.isNotEmpty)
          ? knowledgeIds.first?.toString()
          : null;
      final questionText = m['question']?.toString() ?? '';
      final correctAnswer = m['answer']?.toString() ?? '';
      final explanation = m['explanation']?.toString();

      if (questionText.isEmpty || correctAnswer.isEmpty) continue;

      final targetKnowledgeId = kid != null ? idMap[kid] : null;
      if (targetKnowledgeId == null) continue; // 紐づく知識が無い問題はスキップ

      try {
        await client.from('questions').insert({
          'knowledge_id': targetKnowledgeId,
          'question_type': 'text_input',
          'question_text': questionText,
          'correct_answer': correctAnswer,
          'explanation': explanation,
        });
        _questionCount++;
      } catch (e) {
        _message = (_message ?? '') + '問題 ${m['id']} 投入エラー: $e\n';
      }
    }

    if (_knowledgeCount == 0 && _message != null && _message!.isNotEmpty) {
      throw Exception('知識が1件も投入されませんでした。\n$_message');
    }
  }
}
