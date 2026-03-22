import 'dart:convert';

import 'package:flutter/foundation.dart';
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

  /// knowledge / questions を挿入せず、[knowledge.json] の tags と construction を Supabase に反映する。
  Future<void> syncTagsFromAssetsOnly() async {
    _message = null;
    final client = Supabase.instance.client;
    final subjectRows = await client.from('subjects').select('id').eq('name', '英文法').limit(1);
    if (subjectRows.isEmpty) {
      throw Exception('科目「英文法」がありません。先に科目を作成するか、参考書インポートを一度実行してください。');
    }
    final subjectId = subjectRows.first['id']!.toString().trim();
    if (subjectId.isEmpty) {
      throw Exception('科目「英文法」の id が取得できませんでした。');
    }
    final knowledgeJson = await rootBundle.loadString('assets/knowledge.json');
    final knowledgeList = jsonDecode(knowledgeJson) as List<dynamic>;
    await _syncKnowledgeTagsFromJson(client, subjectId, knowledgeList);
    await _syncKnowledgeConstructionFromJson(client, subjectId, knowledgeList);
  }

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
      knowledgeJson = await rootBundle.loadString('assets/knowledge.json');
      questionsJson = await rootBundle.loadString('assets/questions.json');
    } catch (e) {
      throw Exception(
        'アセットの読み込みに失敗しました。'
        ' pubspec.yaml の assets に assets/knowledge.json と assets/questions.json が含まれているか確認してください。\n$e',
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
        final construction = _constructionFromJson(m);
        final insertMap = <String, dynamic>{
          'subject_id': subjectId,
          'subject': '英文法',
          'unit': topic.isEmpty ? null : topic.trim(),
          'content': title.trim(),
          'description': explanation?.trim(),
          'construction': construction,
        };
        final orderRaw = m['order'];
        if (orderRaw is int) {
          insertMap['display_order'] = orderRaw;
        } else if (orderRaw != null) {
          final o = int.tryParse(orderRaw.toString());
          if (o != null) insertMap['display_order'] = o;
        }

        final inserted = await client.from('knowledge').insert(insertMap).select('id').maybeSingle();

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
      } catch (e) {
        final err = '知識 $assetId 投入エラー: $e';
        _message = (_message ?? '') + '$err\n';
      }
    }

    // 3b) knowledge.json の tags を Supabase に反映（新規挿入だけでなく既存行にも紐づく）
    await _syncKnowledgeTagsFromJson(client, subjectId, knowledgeList);

    // 3c) knowledge.json の construction（構文フラグ）を既存行に反映（重複で insert しなかった行も含む）
    await _syncKnowledgeConstructionFromJson(client, subjectId, knowledgeList);

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
  }

  bool _unitMatchesJsonTopic(String jsonTopic, dynamic dbUnit) {
    final a = jsonTopic.trim().isEmpty ? null : jsonTopic.trim();
    final bRaw = dbUnit?.toString().trim();
    final b = (bRaw == null || bRaw.isEmpty) ? null : bRaw;
    return a == b;
  }

  /// JSON の construction（省略時は false）
  static bool _constructionFromJson(Map<String, dynamic> m) {
    final v = m['construction'];
    return v == true || v == 1;
  }

  /// 科目内の knowledge 行（同期・マッチ用）
  Future<List<Map<String, dynamic>>> _fetchKnowledgeRowsForSubject(
    SupabaseClient client,
    String subjectId,
  ) async {
    final rows = await client
        .from('knowledge')
        .select('id,unit,content')
        .eq('subject_id', subjectId);
    return List<Map<String, dynamic>>.from(rows as List);
  }

  /// タグ同期用: 一意に決まるときだけ ID を返す（複数候補は曖昧としてスキップ）
  String? _resolveKnowledgeIdForJsonEntry(
    String jsonTopic,
    String title,
    List<Map<String, dynamic>> subjectRows,
  ) {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return null;
    final strict = subjectRows.where((r) {
      final c = r['content']?.toString().trim() ?? '';
      return c == trimmed && _unitMatchesJsonTopic(jsonTopic, r['unit']);
    }).toList();
    if (strict.length == 1) return strict.first['id']! as String;
    if (strict.isEmpty) {
      final loose = subjectRows.where((r) {
        final c = r['content']?.toString().trim() ?? '';
        return c == trimmed;
      }).toList();
      if (loose.length == 1) return loose.first['id']! as String;
    }
    return null;
  }

  Future<String> _ensureKnowledgeTagId(SupabaseClient client, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw ArgumentError('tag name empty');
    final existing = await client.from('knowledge_tags').select('id').eq('name', trimmed).limit(1);
    if (existing.isNotEmpty) {
      return existing.first['id']! as String;
    }
    final ins = await client.from('knowledge_tags').insert({'name': trimmed}).select('id').maybeSingle();
    final id = ins?['id']?.toString();
    if (id == null || id.isEmpty) {
      throw Exception('knowledge_tags の作成に失敗しました: $trimmed');
    }
    return id;
  }

  /// [knowledge.json] の各要素の tags を、該当 knowledge 行（subject_id + content + unit）に紐づける。
  Future<void> _syncKnowledgeTagsFromJson(
    SupabaseClient client,
    String subjectId,
    List<dynamic> knowledgeList,
  ) async {
    final subjectRows = await _fetchKnowledgeRowsForSubject(client, subjectId);
    for (final raw in knowledgeList) {
      final m = raw as Map<String, dynamic>;
      final topic = m['topic']?.toString() ?? '';
      final title = m['title']?.toString().trim() ?? '';
      final tags = m['tags'];
      if (title.isEmpty || tags is! List || tags.isEmpty) continue;

      final knowledgeId = _resolveKnowledgeIdForJsonEntry(topic, title, subjectRows);
      if (knowledgeId == null) continue;

      for (final t in tags) {
        final tagName = t?.toString().trim() ?? '';
        if (tagName.isEmpty) continue;
        try {
          final tagId = await _ensureKnowledgeTagId(client, tagName);
          await client.from('knowledge_card_tags').upsert(
            {'knowledge_id': knowledgeId, 'tag_id': tagId},
            onConflict: 'knowledge_id,tag_id',
          );
        } catch (e) {
          _message = '${_message ?? ''}タグ同期: 「$title」×「$tagName」→ $e\n';
        }
      }
    }
  }

  /// [knowledge.json] の construction を該当 knowledge 行に書き込む（タイトル一致行のみ）。
  Future<void> _syncKnowledgeConstructionFromJson(
    SupabaseClient client,
    String subjectId,
    List<dynamic> knowledgeList,
  ) async {
    final subjectRows = await _fetchKnowledgeRowsForSubject(client, subjectId);
    var updatedRows = 0;
    var skippedNoMatch = 0;
    var skippedAmbiguous = 0;

    for (final raw in knowledgeList) {
      final m = raw as Map<String, dynamic>;
      final topic = m['topic']?.toString() ?? '';
      final title = m['title']?.toString().trim() ?? '';
      if (title.isEmpty) continue;

      final trimmed = title;
      final strict = subjectRows.where((r) {
        final c = r['content']?.toString().trim() ?? '';
        return c == trimmed && _unitMatchesJsonTopic(topic, r['unit']);
      }).toList();

      late final List<Map<String, dynamic>> targets;
      if (strict.isNotEmpty) {
        targets = strict;
      } else {
        final loose = subjectRows.where((r) {
          final c = r['content']?.toString().trim() ?? '';
          return c == trimmed;
        }).toList();
        if (loose.isEmpty) {
          skippedNoMatch++;
          continue;
        }
        if (loose.length > 1) {
          skippedAmbiguous++;
          continue;
        }
        targets = loose;
      }

      final construction = _constructionFromJson(m);
      for (final row in targets) {
        final id = row['id']?.toString();
        if (id == null || id.isEmpty) continue;
        try {
          await client.from('knowledge').update({'construction': construction}).eq('id', id);
          updatedRows++;
        } catch (e) {
          final hint = e.toString().contains('construction') || e.toString().contains('schema')
              ? '（Supabase に knowledge.construction 列があるか SQL マイグレーション 00021 を確認）'
              : '';
          _message = '${_message ?? ''}構文フラグ同期: 「$title」 id=$id → $e $hint\n';
        }
      }
    }

    if (kDebugMode) {
      debugPrint(
        '[AssetImport] construction 同期: update試行=$updatedRows, '
        'タイトル未一致=$skippedNoMatch, タイトル重複でスキップ=$skippedAmbiguous',
      );
    }
    if (skippedNoMatch > 0) {
      _message =
          '${_message ?? ''}構文フラグ: $skippedNoMatch 件は科目「英文法」内に同じタイトルの行が見つかりませんでした（content が JSON の title と一致しているか確認）。\n';
    }
    if (skippedAmbiguous > 0) {
      _message =
          '${_message ?? ''}構文フラグ: $skippedAmbiguous 件は同一タイトルが複数行あり、チャプター（unit）が JSON の topic と一致する行に絞れませんでした。\n';
    }
  }
}
