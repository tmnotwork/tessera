import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../asset_import.dart';

/// ローカル DB と Supabase の同期テスト用画面
class LearningSyncPage extends StatefulWidget {
  const LearningSyncPage({super.key, required this.localDb});

  final Database? localDb;

  @override
  State<LearningSyncPage> createState() => _LearningSyncPageState();
}

class _LearningSyncPageState extends State<LearningSyncPage> {
  bool _syncing = false;
  String _status = '未同期';
  List<Map<String, dynamic>> _localKnowledge = [];

  Database get _db => widget.localDb!;

  @override
  void initState() {
    super.initState();
    _loadLocalKnowledge();
  }

  Future<void> _loadLocalKnowledge() async {
    final rows = await _db.query('knowledge_local', orderBy: 'created_at DESC');
    setState(() {
      _localKnowledge = rows;
    });
  }

  Future<void> _insertDummyKnowledge() async {
    String? subjectId;
    try {
      final rows = await Supabase.instance.client
          .from('subjects')
          .select('id')
          .limit(1)
          .order('display_order');
      if (rows.isNotEmpty) {
        subjectId = rows.first['id']?.toString();
      }
    } catch (_) {}
    await _db.insert('knowledge_local', {
      'subject': 'english',
      'subject_id': subjectId,
      'unit': 'TOEIC basic',
      'content': 'apple',
      'description': 'りんご / 基本語彙',
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
      'synced': 0,
    });
    await _loadLocalKnowledge();
    setState(() {
      _status = 'ローカルに 1 件追加しました';
    });
  }

  Future<void> _importAssetData() async {
    setState(() {
      _syncing = true;
      _status = '参考書データをインポート中...';
    });
    try {
      final importer = AssetImport(localDb: _db);
      await importer.run();
      await _loadLocalKnowledge();
      setState(() {
        _status = 'インポート完了: 知識 ${importer.knowledgeCount} 件、問題 ${importer.questionCount} 件';
        if (importer.message != null && importer.message!.isNotEmpty) {
          _status = '$_status\n${importer.message}';
        }
      });
    } catch (e) {
      setState(() => _status = 'インポートエラー: $e');
    } finally {
      setState(() => _syncing = false);
    }
  }

  Future<void> _syncToSupabase() async {
    setState(() {
      _syncing = true;
      _status = 'Supabase と同期中...';
    });

    try {
      final client = Supabase.instance.client;

      final unsynced = await _db.query(
        'knowledge_local',
        where: 'synced = ?',
        whereArgs: [0],
      );

      for (final row in unsynced) {
        final payload = {
          'unit': row['unit'],
          'content': row['content'],
          'description': row['description'],
        };
        if (row['subject_id'] != null && row['subject_id'].toString().isNotEmpty) {
          payload['subject_id'] = row['subject_id'];
        }
        if (row['subject'] != null) payload['subject'] = row['subject'];
        final inserted = await client.from('knowledge').insert(payload).select().maybeSingle();

        if (inserted != null) {
          await _db.update(
            'knowledge_local',
            {
              'synced': 1,
              'supabase_id': inserted['id'],
              'updated_at': DateTime.now().toIso8601String(),
            },
            where: 'id = ?',
            whereArgs: [row['id']],
          );
        }
      }

      await _loadLocalKnowledge();
      setState(() {
        _status = '同期完了 (${unsynced.length} 件同期)';
      });
    } catch (e) {
      setState(() {
        _status = '同期エラー: $e';
      });
    } finally {
      setState(() {
        _syncing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || widget.localDb == null) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('ローカル同期テスト'),
        ),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'このローカルDB同期デモは現在モバイル/デスクトップ用です。\n'
              'Web 版では Supabase へのオンライン学習のみを想定しています。',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('ローカル同期テスト'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('状態:', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 120),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  _status,
                  style: TextStyle(
                    color: _status.contains('エラー') ? Colors.red.shade700 : null,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                ElevatedButton(
                  onPressed: _insertDummyKnowledge,
                  child: const Text('ローカルにダミー知識を追加'),
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  onPressed: _syncing ? null : _syncToSupabase,
                  child: const Text('Supabase へ同期'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _syncing ? null : _importAssetData,
              icon: const Icon(Icons.upload_file),
              label: const Text('参考書データをインポート'),
            ),
            const SizedBox(height: 24),
            const Text(
              'ローカル knowledge 一覧',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: _localKnowledge.length,
                itemBuilder: (context, index) {
                  final row = _localKnowledge[index];
                  final desc = row['description']?.toString() ?? '';
                  final descShort = desc.length > 80 ? '${desc.substring(0, 80)}...' : desc;
                  return ListTile(
                    title: Text(row['content']?.toString() ?? ''),
                    subtitle: Text(
                      '${row['unit'] ?? '-'}${descShort.isNotEmpty ? ' · $descShort' : ''}\n'
                      'subject: ${row['subject']} / synced: ${row['synced'] == 1 ? 'はい' : 'いいえ'}',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
