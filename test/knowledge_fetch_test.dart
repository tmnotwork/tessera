// 知識カード取得の検証テスト。
// Supabase REST API を直接叩き、knowledge を subject_id で取得できるか確認する。
// 実行: flutter test test/knowledge_fetch_test.dart
//
// 確実に原因を切り分けるには:
// 1. このテストで anon での取得が通るか確認する。
// 2. アプリを flutter run し、ログインして「学習」→「知識を学ぶ」→「英文法」を開く。
// 3. コンソールの [KnowledgeListScreen._load] / [KnowledgeRepositorySupabase.getBySubject] を確認する。
//    - try1 失敗時のメッセージで join または RLS の原因が分かる。
//    - try2 の count が 0 なら authenticated の RLS で弾かれている可能性。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

const _supabaseUrl = 'https://wnufzrehvhcwclnwxwim.supabase.co';
const _supabaseAnonKey = 'sb_publishable_6ZOloNwIgIFjF9SKRLGgmA_Yc55g0es';

// 英文法の subject_id（DB に存在する値）
const _bunpoSubjectId = '72cba8cc-28b9-41fb-bf72-257a99139831';

void main() {
  group('knowledge fetch by subject_id', () {
    test('anon で knowledge を subject_id で取得できる', () async {
      final uri = Uri.parse(
        '$_supabaseUrl/rest/v1/knowledge?subject_id=eq.$_bunpoSubjectId&order=display_order.asc.nullslast,created_at.asc&select=*',
      );
      final res = await http.get(
        uri,
        headers: {
          'apikey': _supabaseAnonKey,
          'Authorization': 'Bearer $_supabaseAnonKey',
          'Content-Type': 'application/json',
        },
      );
      expect(res.statusCode, 200, reason: 'API が 200 を返すこと。body=${res.body}');
      final list = jsonDecode(res.body) as List;
      expect(list, isNotEmpty, reason: '英文法の知識カードが 1 件以上あること。count=${list.length}');
    });
  });
}
