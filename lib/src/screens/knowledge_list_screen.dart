import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app_scope.dart';
import '../database/local_database.dart';
import '../models/english_example.dart';
import '../models/knowledge.dart';
import '../repositories/knowledge_repository.dart';
import '../sync/english_example_state_sync.dart';
import '../sync/ensure_synced_for_local_read.dart';
import '../sync/sync_engine.dart';
import '../utils/knowledge_learner_mem_status.dart';
import '../utils/knowledge_sort.dart';
import '../utils/platform_utils.dart';
import 'knowledge_detail_screen.dart';

bool _rowNotSoftDeleted(Map<String, dynamic> row) {
  final v = row['deleted_at'];
  if (v == null) return true;
  return v.toString().trim().isEmpty;
}

/// 指定した科目（subject）の knowledge カード一覧画面
class KnowledgeListScreen extends StatefulWidget {
  const KnowledgeListScreen({
    super.key,
    required this.subjectId,
    required this.subjectName,
    this.localDatabase,
    this.isLearnerMode = false,
  });

  final String subjectId;
  final String subjectName;
  final LocalDatabase? localDatabase;
  /// true: 学習メニューから開いた場合。閲覧のみ・編集不可・問題リンク表示。
  final bool isLearnerMode;

  @override
  State<KnowledgeListScreen> createState() => _KnowledgeListScreenState();
}

class _KnowledgeListScreenState extends State<KnowledgeListScreen> {
  List<Knowledge> _items = [];
  bool _isLoading = true;
  String? _error;
  String? _filterTag;
  bool _isLoadInFlight = false;

  /// 学習者一覧：各知識に紐づく問題ID（表示用 knowledge.id キー）
  final Map<String, List<String>> _learnerLinkedQuestionIds = {};
  final Map<String, String> _learnerQuestionTypeById = {};
  final Map<String, Map<String, dynamic>> _learnerQuestionStates = {};
  final Map<String, List<EnglishExample>> _learnerExamplesByKnowledge = {};
  final Map<String, Map<String, dynamic>> _learnerExampleStates = {};
  final Map<String, Map<String, dynamic>> _learnerExampleCompositionStates = {};

  List<Knowledge> get _filteredItems {
    if (_filterTag == null) return _items;
    return _items.where((k) => k.tags.contains(_filterTag)).toList();
  }

  List<String> get _allTags {
    final set = <String>{};
    for (final k in _items) {
      set.addAll(k.tags);
    }
    return set.toList()..sort();
  }

  bool _showManageEdit = false;

  @override
  void initState() {
    super.initState();
    _load();
    if (widget.isLearnerMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        if (await shouldShowLearnerFlowManageShortcut()) {
          setState(() => _showManageEdit = true);
        }
      });
    }
  }

  List<Widget> _learnerModeAppBarActions({required bool includeRefresh}) {
    final actions = <Widget>[];
    if (widget.isLearnerMode && _showManageEdit) {
      actions.add(
        IconButton(
          icon: const Icon(Icons.edit),
          tooltip: '教材を編集',
          onPressed: () => openManageNotifier.openManage?.call(context),
        ),
      );
    }
    if (includeRefresh) {
      actions.add(
        IconButton(
          icon: const Icon(Icons.refresh),
          onPressed: _load,
          tooltip: '再読み込み',
        ),
      );
    }
    return actions;
  }

  /// Supabase から knowledge を subject_id で取得。join 失敗時は select のみでリトライ。
  Future<List<Knowledge>> _fetchKnowledgeFromSupabase() async {
    final client = Supabase.instance.client;
    List<dynamic> rows;
    try {
      if (kDebugMode) debugPrint('[KnowledgeListScreen] Supabase try1: select with knowledge_card_tags join');
      rows = await client
          .from('knowledge')
          .select('*, knowledge_card_tags(tag_id, knowledge_tags(name))')
          .eq('subject_id', widget.subjectId)
          .order('display_order', ascending: true)
          .order('created_at', ascending: true);
      if (kDebugMode) debugPrint('[KnowledgeListScreen] Supabase try1 ok: count=${rows.length}');
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[KnowledgeListScreen] Supabase try1 FAILED: $e');
        debugPrint('[KnowledgeListScreen] try1 stack: $st');
      }
      final msg = e.toString();
      if (msg.contains('knowledge_card_tags') ||
          msg.contains('PGRST200') ||
          msg.contains('relationship')) {
        if (kDebugMode) debugPrint('[KnowledgeListScreen] Supabase try2: select() only (no join)');
        rows = await client
            .from('knowledge')
            .select()
            .eq('subject_id', widget.subjectId)
            .order('display_order', ascending: true)
            .order('created_at', ascending: true);
        if (kDebugMode) debugPrint('[KnowledgeListScreen] Supabase try2 ok: count=${rows.length}');
      } else {
        rethrow;
      }
    }
    final maps = (rows as List<Map<String, dynamic>>).where(_rowNotSoftDeleted).toList();
    return maps.map(Knowledge.fromSupabase).toList();
  }

  /// ローカルに一部の行しか無いとき、Supabase 上にだけあるカードを足して欠損を防ぐ。
  Future<List<Knowledge>> _mergeLocalWithSupabase(List<Knowledge> local) async {
    try {
      final locallyDeletedRemoteIds = widget.localDatabase == null
          ? <String>{}
          : await widget.localDatabase!.allDeletedKnowledgeRemoteIds();
      final remote = await _fetchKnowledgeFromSupabase();
      if (remote.isEmpty) {
        sortKnowledgeByChapterBlocks(local);
        return local;
      }
      final seen = <String, Knowledge>{for (final k in local) k.id: k};
      var added = 0;
      var constructionOverlay = 0;
      for (final k in remote) {
        if (locallyDeletedRemoteIds.contains(k.id)) continue;
        final existing = seen[k.id];
        if (existing == null) {
          seen[k.id] = k;
          added++;
          continue;
        }
        // ローカル行が優先されるが、construction は Supabase 正とする（Pull 前の SQLite が false のままだと「構文」チップが消えたように見える）
        if (existing.construction != k.construction) {
          seen[k.id] = Knowledge(
            id: existing.id,
            subjectId: existing.subjectId,
            subject: existing.subject,
            unit: existing.unit,
            content: existing.content,
            description: existing.description,
            type: existing.type,
            displayOrder: existing.displayOrder,
            construction: k.construction,
            tags: existing.tags,
            authorComment: existing.authorComment,
            devCompleted: existing.devCompleted,
          );
          constructionOverlay++;
        }
      }
      if (kDebugMode && (added > 0 || constructionOverlay > 0)) {
        debugPrint(
          '[KnowledgeListScreen] merge: local=${local.length}, +$added new ids, '
          'construction overlay from remote=$constructionOverlay → ${seen.length} total',
        );
      }
      final merged = seen.values
          .where((k) => !locallyDeletedRemoteIds.contains(k.id))
          .toList();
      sortKnowledgeByChapterBlocks(merged);
      return merged;
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[KnowledgeListScreen] merge skipped: $e\n$st');
      }
      sortKnowledgeByChapterBlocks(local);
      return local;
    }
  }

  Future<void> _load() async {
    if (_isLoadInFlight) return;
    _isLoadInFlight = true;
    if (mounted) {
      setState(() {
        _isLoading = _items.isEmpty;
        _error = null;
      });
    }

    final dataSource = widget.localDatabase != null ? 'LocalDB' : 'Supabase';
    if (kDebugMode) {
      debugPrint('[KnowledgeListScreen._load] subjectId=${widget.subjectId}, dataSource=$dataSource');
    }
    try {
      if (widget.localDatabase != null) {
        final repo = createKnowledgeRepository(widget.localDatabase);
        var list = await repo.getBySubject(widget.subjectId);
        if (kDebugMode) debugPrint('[KnowledgeListScreen._load] LocalDB result: count=${list.length}');
        // ローカルに 0 件のときは Supabase から取得する（Sync 未完了やリモートのみのデータ対応）
        if (list.isEmpty) {
          if (kDebugMode) {
            debugPrint('[KnowledgeListScreen._load] LocalDB empty → merge with Supabase (削除除外を維持)');
          }
          list = await _mergeLocalWithSupabase([]);
        } else {
          list = await _mergeLocalWithSupabase(list);
        }
        sortKnowledgeByChapterBlocks(list);
        if (mounted) {
          setState(() {
            _items = list;
            _isLoading = false;
          });
        }
        if (mounted && widget.isLearnerMode) {
          unawaited(_loadLearnerPracticeSidecar());
        }
      } else {
        final list = await _fetchKnowledgeFromSupabase();
        sortKnowledgeByChapterBlocks(list);
        if (mounted) {
          setState(() {
            _items = list;
            _isLoading = false;
          });
        }
        if (mounted && widget.isLearnerMode) {
          unawaited(_loadLearnerPracticeSidecar());
        }
      }

      unawaited(() async {
        await triggerBackgroundSyncWithThrottle();
        if (!mounted) return;
        final repo = widget.localDatabase != null
            ? createKnowledgeRepository(widget.localDatabase)
            : null;
        List<Knowledge> refreshed;
        if (repo != null) {
          refreshed = await repo.getBySubject(widget.subjectId);
          refreshed = await _mergeLocalWithSupabase(refreshed);
        } else {
          refreshed = await _fetchKnowledgeFromSupabase();
        }
        sortKnowledgeByChapterBlocks(refreshed);
        if (!mounted) return;
        final changed = !_sameKnowledgeIds(_items, refreshed);
        if (changed) {
          setState(() => _items = refreshed);
        }
      }());
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[KnowledgeListScreen._load] FAILED: $e');
        debugPrint('[KnowledgeListScreen._load] stack: $st');
      }
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
      _isLoadInFlight = false;
    }
  }

  bool _sameKnowledgeIds(List<Knowledge> a, List<Knowledge> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
      if (a[i].displayOrder != b[i].displayOrder) return false;
      if (a[i].content != b[i].content) return false;
    }
    return true;
  }

  Future<Map<String, String>> _displayKnowledgeIdToSupabaseIdForList() async {
    final out = <String, String>{};
    final pendingLocal = <int, String>{};

    for (final k in _items) {
      if (k.id.startsWith('local_')) {
        final lid = int.tryParse(k.id.replaceFirst('local_', ''));
        if (lid != null) pendingLocal[lid] = k.id;
      } else {
        out[k.id] = k.id;
      }
    }

    if (widget.localDatabase != null && pendingLocal.isNotEmpty) {
      final ids = pendingLocal.keys.toList();
      final placeholders = List.filled(ids.length, '?').join(',');
      final rows = await widget.localDatabase!.db.query(
        LocalTable.knowledge,
        columns: ['local_id', 'supabase_id'],
        where: 'local_id IN ($placeholders) AND deleted = ?',
        whereArgs: [...ids, 0],
      );
      for (final r in rows) {
        final lid = r['local_id'] as int?;
        final sid = r['supabase_id']?.toString().trim();
        if (lid == null || sid == null || sid.isEmpty) continue;
        final disp = pendingLocal[lid];
        if (disp != null) out[disp] = sid;
      }
    }

    return out;
  }

  Future<({List<String> queryIds, Map<String, String> remoteNormToDisplayId})>
      _knowledgeSupabaseQueryContextForList() async {
    final displayToRemote = await _displayKnowledgeIdToSupabaseIdForList();
    final queryIds = <String>{};
    final remoteNormToDisplayId = <String, String>{};

    for (final k in _items) {
      final remote = displayToRemote[k.id];
      if (remote != null && remote.isNotEmpty) {
        queryIds.add(remote);
        remoteNormToDisplayId[remote.trim().toLowerCase()] = k.id;
      }
    }

    return (queryIds: queryIds.toList(), remoteNormToDisplayId: remoteNormToDisplayId);
  }

  /// 学習者一覧の各行用：四択・例文の学習状態を取得
  Future<void> _loadLearnerPracticeSidecar() async {
    if (!widget.isLearnerMode || _items.isEmpty) return;
    try {
      final client = Supabase.instance.client;
      final ctx = await _knowledgeSupabaseQueryContextForList();
      final normalizedToOriginal = <String, String>{};
      final copyByKnowledge = <String, List<String>>{};
      for (final k in _items) {
        copyByKnowledge[k.id] = [];
        normalizedToOriginal[k.id.toString().trim().toLowerCase()] = k.id;
      }

      String? resolveDisplayKnowledgeId(String? raw) {
        if (raw == null) return null;
        final n = raw.trim().toLowerCase();
        return ctx.remoteNormToDisplayId[n] ?? normalizedToOriginal[n];
      }

      if (ctx.queryIds.isEmpty) {
        if (!mounted) return;
        setState(() {
          _learnerLinkedQuestionIds.clear();
          _learnerQuestionTypeById.clear();
          _learnerQuestionStates.clear();
          _learnerExamplesByKnowledge.clear();
          _learnerExampleStates.clear();
        });
        return;
      }

      try {
        final fromDirect = await client
            .from('questions')
            .select('id, knowledge_id')
            .inFilter('knowledge_id', ctx.queryIds);
        for (final row in fromDirect as List) {
          final r = row as Map<String, dynamic>;
          final qId = r['id']?.toString();
          final kId = resolveDisplayKnowledgeId(r['knowledge_id']?.toString());
          if (qId != null &&
              kId != null &&
              copyByKnowledge.containsKey(kId) &&
              !copyByKnowledge[kId]!.contains(qId)) {
            copyByKnowledge[kId]!.add(qId);
          }
        }
      } catch (_) {}

      try {
        final junc = await client
            .from('question_knowledge')
            .select('question_id, knowledge_id')
            .inFilter('knowledge_id', ctx.queryIds);
        for (final row in junc as List) {
          final r = row as Map<String, dynamic>;
          final qId = r['question_id']?.toString();
          final kId = resolveDisplayKnowledgeId(r['knowledge_id']?.toString());
          if (qId != null &&
              kId != null &&
              copyByKnowledge.containsKey(kId) &&
              !copyByKnowledge[kId]!.contains(qId)) {
            copyByKnowledge[kId]!.add(qId);
          }
        }
      } catch (_) {}

      final allQIds = copyByKnowledge.values.expand((l) => l).toSet().toList();
      if (allQIds.isNotEmpty) {
        try {
          final existingRows = await client.from('questions').select('id').inFilter('id', allQIds);
          final existingIds = (existingRows as List)
              .map((r) => (r as Map<String, dynamic>)['id']?.toString())
              .where((id) => id != null && id.isNotEmpty)
              .cast<String>()
              .toSet();
          for (final k in copyByKnowledge.keys.toList()) {
            copyByKnowledge[k] = copyByKnowledge[k]!.where((id) => existingIds.contains(id)).toList();
          }
        } catch (_) {}
      }

      final filteredQIds = copyByKnowledge.values.expand((l) => l).toSet().toList();
      final questionTypeById = <String, String>{};
      if (filteredQIds.isNotEmpty) {
        try {
          final typeRows =
              await client.from('questions').select('id, question_type').inFilter('id', filteredQIds);
          for (final raw in typeRows as List) {
            final r = raw as Map<String, dynamic>;
            final id = r['id']?.toString();
            if (id != null && id.isNotEmpty) {
              questionTypeById[id] = r['question_type']?.toString() ?? '';
            }
          }
        } catch (_) {}
      }

      var qStates = <String, Map<String, dynamic>>{};
      if (filteredQIds.isNotEmpty) {
        final uid = client.auth.currentUser?.id;
        if (uid != null) {
          try {
            final stateRows = await client
                .from('question_learning_states')
                .select('question_id, last_is_correct, reviewed_count, lapse_count, next_review_at')
                .eq('learner_id', uid)
                .inFilter('question_id', filteredQIds);
            for (final raw in stateRows as List) {
              final r = raw as Map<String, dynamic>;
              final qid = r['question_id']?.toString();
              if (qid != null && qid.isNotEmpty) {
                qStates[qid] = Map<String, dynamic>.from(r);
              }
            }
          } catch (_) {}
        }
      }

      final exMap = <String, List<EnglishExample>>{};
      var exStates = <String, Map<String, dynamic>>{};
      var exComp = <String, Map<String, dynamic>>{};
      try {
        final rows = await client
            .from('english_examples')
            .select('id, knowledge_id, front_ja, back_en, explanation, supplement, prompt_supplement, display_order')
            .inFilter('knowledge_id', ctx.queryIds);
        final byKnowledgeRows = <String, List<Map<String, dynamic>>>{
          for (final k in _items) k.id: [],
        };
        for (final row in rows as List) {
          final r = row as Map<String, dynamic>;
          final rawKid = r['knowledge_id']?.toString();
          final n = rawKid != null ? rawKid.trim().toLowerCase() : '';
          final displayId = n.isNotEmpty ? ctx.remoteNormToDisplayId[n] : null;
          if (displayId != null && byKnowledgeRows.containsKey(displayId)) {
            byKnowledgeRows[displayId]!.add(r);
          }
        }
        for (final e in byKnowledgeRows.entries) {
          e.value.sort((a, b) {
            final da = a['display_order'] as int?;
            final db = b['display_order'] as int?;
            if (da != null && db != null) return da.compareTo(db);
            if (da != null) return -1;
            if (db != null) return 1;
            return 0;
          });
          exMap[e.key] = e.value.map(EnglishExample.fromRow).toList();
        }

        final learnerId = client.auth.currentUser?.id;
        if (learnerId != null) {
          final exampleIds = <String>[];
          for (final list in exMap.values) {
            for (final ex in list) {
              exampleIds.add(ex.id);
            }
          }
          if (exampleIds.isNotEmpty) {
            final localDb = widget.localDatabase ?? SyncEngine.maybeLocalDb;
            exStates = await EnglishExampleStateSync.fetchLearningStatesHybrid(
              client: client,
              learnerId: learnerId,
              exampleIds: exampleIds,
              localDb: localDb,
            );
            exComp = await EnglishExampleStateSync.fetchCompositionStatesHybrid(
              client: client,
              learnerId: learnerId,
              exampleIds: exampleIds,
              localDb: localDb,
            );
          }
        }
      } catch (_) {}

      if (!mounted) return;
      setState(() {
        _learnerLinkedQuestionIds
          ..clear()
          ..addAll(copyByKnowledge);
        _learnerQuestionTypeById
          ..clear()
          ..addAll(questionTypeById);
        _learnerQuestionStates
          ..clear()
          ..addAll(qStates);
        _learnerExamplesByKnowledge
          ..clear()
          ..addAll(exMap);
        _learnerExampleStates
          ..clear()
          ..addAll(exStates);
        _learnerExampleCompositionStates
          ..clear()
          ..addAll(exComp);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _learnerLinkedQuestionIds.clear();
        _learnerQuestionTypeById.clear();
        _learnerQuestionStates.clear();
        _learnerExamplesByKnowledge.clear();
        _learnerExampleStates.clear();
        _learnerExampleCompositionStates.clear();
      });
    }
  }

  Future<void> _addCard() async {
    try {
      final maxOrder = _items.isEmpty
          ? 0
          : _items.map((e) => e.displayOrder ?? 0).reduce((a, b) => a > b ? a : b);

      if (widget.localDatabase != null) {
        final repo = createKnowledgeRepository(widget.localDatabase);
        final newCard = Knowledge(
          id: 'local_0',
          content: '',
          subjectId: widget.subjectId,
          subject: widget.subjectName,
          displayOrder: maxOrder + 1,
        );
        final saved = await repo.save(newCard, subjectId: widget.subjectId, subjectName: widget.subjectName);
        if (SyncEngine.isInitialized) SyncEngine.instance.syncIfOnline();
        await _load();
        if (mounted) {
          final newIndex = _items.indexWhere((e) => e.id == saved.id);
          if (newIndex >= 0) {
            await Navigator.of(context).push<bool>(
              MaterialPageRoute<bool>(
                builder: (context) => KnowledgeDetailScreen(
                  allKnowledge: _items,
                  initialIndex: newIndex,
                  initialEditing: true,
                  isLearnerMode: widget.isLearnerMode,
                  localDatabase: widget.localDatabase,
                  subjectId: widget.subjectId,
                  subjectName: widget.subjectName,
                ),
              ),
            );
            if (mounted) await _load();
          }
        }
      } else {
        final client = Supabase.instance.client;
        final inserted = await client.from('knowledge').insert({
          'subject_id': widget.subjectId,
          'subject': widget.subjectName,
          'content': '',
          'type': 'grammar',
          'construction': false,
          'display_order': maxOrder + 1,
        }).select().single();

        final newCard = Knowledge.fromSupabase(inserted);
        await _load();

        if (mounted) {
          final newIndex = _items.indexWhere((e) => e.id == newCard.id);
          if (newIndex >= 0) {
            await Navigator.of(context).push<bool>(
              MaterialPageRoute<bool>(
                builder: (context) => KnowledgeDetailScreen(
                  allKnowledge: _items,
                  initialIndex: newIndex,
                  initialEditing: true,
                  isLearnerMode: widget.isLearnerMode,
                  localDatabase: widget.localDatabase,
                  subjectId: widget.subjectId,
                  subjectName: widget.subjectName,
                ),
              ),
            );
            if (mounted) await _load();
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('追加エラー: $e')),
        );
      }
    }
  }

  Future<void> _openDetail(int index) async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (context) => KnowledgeDetailScreen(
          allKnowledge: _items,
          initialIndex: index,
          initialEditing: widget.isLearnerMode ? false : isDesktop,
          isLearnerMode: widget.isLearnerMode,
          localDatabase: widget.localDatabase,
          subjectId: widget.subjectId,
          subjectName: widget.subjectName,
        ),
      ),
    );
    // OS/AppBar の戻るは pop(true) にならない。手動「再読み込み」と同様、戻ったら常に再取得する。
    if (mounted) await _load();
  }

  /// ドラッグ後の並びを保持する。ここでチャプターソートしない（即座に元位置へ戻る原因になる）。
  List<Knowledge> _withSequentialDisplayOrder(List<Knowledge> ordered) {
    return [
      for (var i = 0; i < ordered.length; i++)
        Knowledge(
          id: ordered[i].id,
          subjectId: ordered[i].subjectId,
          subject: ordered[i].subject,
          unit: ordered[i].unit,
          content: ordered[i].content,
          description: ordered[i].description,
          type: ordered[i].type,
          displayOrder: i + 1,
          construction: ordered[i].construction,
          tags: ordered[i].tags,
          authorComment: ordered[i].authorComment,
          devCompleted: ordered[i].devCompleted,
        ),
    ];
  }

  Future<void> _persistDisplayOrdersAfterReorder(List<Knowledge> ordered) async {
    if (widget.localDatabase != null) {
      final db = widget.localDatabase!;
      for (var i = 0; i < ordered.length; i++) {
        final k = ordered[i];
        final order = i + 1;
        if (k.id.startsWith('local_')) {
          final lid = int.tryParse(k.id.substring(6));
          if (lid != null && lid > 0) {
            await db.updateWithSync(
              LocalTable.knowledge,
              {'display_order': order},
              where: 'local_id = ?',
              whereArgs: [lid],
            );
          }
        } else {
          final row = await db.getBySupabaseId(LocalTable.knowledge, k.id);
          if (row != null) {
            await db.updateWithSync(
              LocalTable.knowledge,
              {'display_order': order},
              where: 'local_id = ?',
              whereArgs: [row['local_id'] as int],
            );
          } else {
            await Supabase.instance.client
                .from('knowledge')
                .update({'display_order': order})
                .eq('id', k.id);
          }
        }
      }
      if (SyncEngine.isInitialized) {
        await SyncEngine.instance.syncIfOnline();
      }
    } else {
      final client = Supabase.instance.client;
      for (var i = 0; i < ordered.length; i++) {
        await client
            .from('knowledge')
            .update({'display_order': i + 1})
            .eq('id', ordered[i].id);
      }
    }
  }

  /// [list] の並びを保ったまま、隣接同一 unit をまとめたチャプターブロックに分割する。
  List<(String title, List<Knowledge> items)> _chapterBlocks(List<Knowledge> list) {
    final out = <(String, List<Knowledge>)>[];
    for (final k in list) {
      final u = k.unit ?? 'その他';
      if (out.isEmpty || out.last.$1 != u) {
        out.add((u, [k]));
      } else {
        out.last.$2.add(k);
      }
    }
    return out;
  }

  /// 同一チャプター（連続ブロック）内の並べ替え。表示は折りたたみ時は行わない。
  Future<void> _reorderCardsInChapter(String chapterTitle, int oldIndex, int newIndex) async {
    if (newIndex > oldIndex) newIndex--;
    var start = -1;
    var end = -1;
    for (var i = 0; i < _items.length; i++) {
      final u = _items[i].unit ?? 'その他';
      if (u == chapterTitle) {
        if (start < 0) start = i;
        end = i;
      } else if (start >= 0) {
        break;
      }
    }
    if (start < 0 || end < start) return;
    final sub = List<Knowledge>.from(_items.sublist(start, end + 1));
    if (oldIndex < 0 || oldIndex >= sub.length) return;
    final item = sub.removeAt(oldIndex);
    sub.insert(newIndex.clamp(0, sub.length), item);
    final newFull = [
      ..._items.sublist(0, start),
      ...sub,
      ..._items.sublist(end + 1),
    ];
    final withOrders = _withSequentialDisplayOrder(newFull);
    setState(() => _items = withOrders);
    try {
      await _persistDisplayOrdersAfterReorder(withOrders);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('並び替えエラー: $e')),
        );
        await _load();
      }
    }
  }

  Widget _buildTagFilter(BuildContext context) {
    if (widget.isLearnerMode) return const SizedBox.shrink();
    final tags = _allTags;
    if (tags.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: FilterChip(
              label: const Text('すべて'),
              selected: _filterTag == null,
              onSelected: (_) => setState(() => _filterTag = null),
              selectedColor: scheme.primaryContainer,
              checkmarkColor: scheme.primary,
            ),
          ),
          ...tags.map((tag) => Padding(
                padding: const EdgeInsets.only(right: 8.0),
                child: FilterChip(
                  label: Text(tag),
                  selected: _filterTag == tag,
                  onSelected: (_) => setState(() => _filterTag = tag),
                  selectedColor: scheme.primaryContainer,
                  checkmarkColor: scheme.primary,
                ),
              )),
        ],
      ),
    );
  }

  /// 教師・タグなし一覧。[ExpansionTile] 内に [ReorderableListView] を置くと
  /// Windows 等で子が描画されず展開部が無地のグレーになるため、通常の行リストとし、
  /// チャプター内の並べ替えは ↑↓ で行う。
  Widget _buildTeacherChapterList(BuildContext context) {
    final blocks = _chapterBlocks(_items);
    final scheme = Theme.of(context).colorScheme;
    final titleStyle = Theme.of(context).textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.bold,
        );
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: blocks.length,
      itemBuilder: (context, blockIndex) {
        final (title, chapterItems) = blocks[blockIndex];
        return ExpansionTile(
          key: PageStorageKey<String>('knowledge_chapter_teacher_${title}_$blockIndex'),
          initiallyExpanded: false,
          collapsedBackgroundColor: scheme.surface,
          backgroundColor: scheme.surface,
          title: Text(title, style: titleStyle),
          childrenPadding: EdgeInsets.zero,
          children: [
            for (var i = 0; i < chapterItems.length; i++)
              _buildListTile(
                context,
                chapterItems[i],
                _items.indexWhere((e) => e.id == chapterItems[i].id),
                draggable: false,
                onMoveUp: i > 0 ? () => _reorderCardsInChapter(title, i, i - 1) : null,
                onMoveDown: i < chapterItems.length - 1
                    ? () => _reorderCardsInChapter(title, i, i + 2)
                    : null,
              ),
          ],
        );
      },
    );
  }

  Widget _buildPlainList(BuildContext context) {
    final list = _filteredItems;
    if (list.isEmpty) {
      return Center(
        child: Text(
          _filterTag != null ? '「$_filterTag」のカードはありません' : 'データがありません',
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      );
    }
    final blocks = _chapterBlocks(list);
    final titleStyle = Theme.of(context).textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.bold,
        );
    final scheme = Theme.of(context).colorScheme;
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: blocks.length,
      itemBuilder: (context, blockIndex) {
        final (title, chapterItems) = blocks[blockIndex];
        return ExpansionTile(
          key: PageStorageKey<String>('knowledge_chapter_plain_${title}_$blockIndex'),
          initiallyExpanded: false,
          collapsedBackgroundColor: scheme.surface,
          backgroundColor: scheme.surface,
          title: Text(title, style: titleStyle),
          childrenPadding: EdgeInsets.zero,
          children: [
            for (final item in chapterItems)
              _buildListTile(
                context,
                item,
                _items.indexWhere((e) => e.id == item.id),
                draggable: false,
              ),
          ],
        );
      },
    );
  }

  /// 教師用一覧のみ：左に「完成」（dev_completed）の有無を示すマーク
  Widget? _devCompletedLeading(BuildContext context, Knowledge item) {
    if (widget.isLearnerMode) return null;
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: item.devCompleted ? '完成（開発者確認済み）' : '未完成',
      child: Icon(
        item.devCompleted ? Icons.check_circle : Icons.circle_outlined,
        color: item.devCompleted ? scheme.primary : scheme.outline,
        size: 22,
      ),
    );
  }

  /// 学習者一覧：四択・例文をまとめた1アイコン（チェック系3択）。> は付けない。
  Widget _learnerPracticeTrailing(BuildContext context, Knowledge item) {
    final qids = _learnerLinkedQuestionIds[item.id] ?? [];
    final mcqIds =
        qids.where((id) => _learnerQuestionTypeById[id] == 'multiple_choice').toList();
    final examples = _learnerExamplesByKnowledge[item.id] ?? [];

    return KnowledgeLearnerMemStatus.combinedMark(
      context,
      mcqIds: mcqIds,
      examples: examples,
      questionStates: _learnerQuestionStates,
      exampleStates: _learnerExampleStates,
      exampleCompositionStates: _learnerExampleCompositionStates,
      size: 26,
    );
  }

  Widget _buildListTile(
    BuildContext context,
    Knowledge item,
    int index, {
    required bool draggable,
    VoidCallback? onMoveUp,
    VoidCallback? onMoveDown,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: _devCompletedLeading(context, item),
      title: Text(item.title.isEmpty ? '（タイトル未設定）' : item.title),
      trailing: widget.isLearnerMode
          ? _learnerPracticeTrailing(context, item)
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (onMoveUp != null || onMoveDown != null)
                  PopupMenuButton<int>(
                    tooltip: 'このチャプター内で並べ替え',
                    padding: EdgeInsets.zero,
                    child: Icon(Icons.reorder, size: 22, color: scheme.onSurfaceVariant),
                    onSelected: (v) {
                      if (v < 0) onMoveUp?.call();
                      if (v > 0) onMoveDown?.call();
                    },
                    itemBuilder: (context) => [
                      if (onMoveUp != null)
                        const PopupMenuItem<int>(
                          value: -1,
                          child: Text('ひとつ前へ'),
                        ),
                      if (onMoveDown != null)
                        const PopupMenuItem<int>(
                          value: 1,
                          child: Text('ひとつ次へ'),
                        ),
                    ],
                  ),
                if (item.construction)
                  Padding(
                    padding: const EdgeInsets.only(right: 8.0),
                    child: Chip(
                      label: Text(
                        '構文',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                      backgroundColor: scheme.surfaceContainerHighest,
                    ),
                  ),
                ...item.tags.map((t) => Padding(
                      padding: const EdgeInsets.only(right: 8.0),
                      child: Chip(
                        label: Text(t, style: Theme.of(context).textTheme.labelSmall),
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                        backgroundColor: scheme.surfaceContainerHighest,
                      ),
                    )),
                if (draggable)
                  Icon(Icons.drag_handle, color: scheme.onSurfaceVariant)
                else if (onMoveUp == null && onMoveDown == null)
                  const Icon(Icons.chevron_right),
              ],
            ),
      onTap: () => _openDetail(index),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(
          title: Text(widget.subjectName),
          actions: _learnerModeAppBarActions(includeRefresh: false),
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null) {
      return Scaffold(
        appBar: AppBar(
          title: Text(widget.subjectName),
          actions: _learnerModeAppBarActions(includeRefresh: false),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.error_outline,
                    size: 48, color: Theme.of(context).colorScheme.error),
                const SizedBox(height: 16),
                Text('読み込みエラー: $_error', textAlign: TextAlign.center),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _load,
                  icon: const Icon(Icons.refresh),
                  label: const Text('再試行'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.subjectName),
        actions: _learnerModeAppBarActions(includeRefresh: true),
      ),
      body: _items.isEmpty
          ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text('カードがありません'),
                    if (!widget.isLearnerMode) ...[
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _addCard,
                        icon: const Icon(Icons.add),
                        label: const Text('最初のカードを追加'),
                      ),
                    ],
                  ],
                ),
              )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildTagFilter(context),
                Expanded(
                  child: _filterTag == null && !widget.isLearnerMode
                      ? _buildTeacherChapterList(context)
                      : _buildPlainList(context),
                ),
              ],
            ),
      floatingActionButton: !widget.isLearnerMode && _items.isNotEmpty
          ? FloatingActionButton(
              onPressed: _addCard,
              tooltip: 'カードを追加',
              child: const Icon(Icons.add),
            )
          : null,
    );
  }
}
