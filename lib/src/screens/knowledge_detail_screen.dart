import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app_scope.dart';
import '../database/local_database.dart';
import '../models/english_example.dart';
import '../models/knowledge.dart';
import '../repositories/knowledge_repository.dart';
import '../sync/ensure_synced_for_local_read.dart';
import '../services/knowledge_delete_flow.dart';
import '../services/study_timer_service.dart';
import '../sync/knowledge_save_remote_status.dart';
import '../utils/platform_utils.dart';
import '../widgets/dev_completion_segmented.dart';
import '../widgets/edit_intents.dart';
import '../widgets/explanation_text.dart';
import '../sync/english_example_state_sync.dart';
import '../sync/sync_engine.dart';
import '../utils/knowledge_learner_mem_status.dart';
import 'english_example_list_screen.dart';
import 'english_example_composition_screen.dart';
import 'four_choice_create_screen.dart';
import 'knowledge_edit_screen.dart';
import 'question_solve_screen.dart';

/// 知識カード詳細画面
///
/// 閲覧モード：PageView でスワイプ移動
/// 編集モード（デスクトップ）：左ペイン編集 / 右ペインプレビューの分割表示
/// 編集モード（モバイル）：KnowledgeEditScreen へ遷移
class KnowledgeDetailScreen extends StatefulWidget {
  const KnowledgeDetailScreen({
    super.key,
    required this.allKnowledge,
    required this.initialIndex,
    this.initialEditing = false,
    this.isLearnerMode = false,
    this.localDatabase,
    this.subjectId,
    this.subjectName,
  });

  final List<Knowledge> allKnowledge;
  final int initialIndex;
  final bool initialEditing;
  /// 学習者向け：編集不可・執筆者コメント非表示・本文下に例文・問題リンク
  final bool isLearnerMode;
  /// ローカルDB使用時：保存を Repository 経由にして永続化を確実にする
  final LocalDatabase? localDatabase;
  final String? subjectId;
  final String? subjectName;

  @override
  State<KnowledgeDetailScreen> createState() => _KnowledgeDetailScreenState();
}

class _KnowledgeDetailScreenState extends State<KnowledgeDetailScreen> {
  bool _isEditing = false;
  late PageController _pageController;
  late int _currentIndex;
  late List<Knowledge> _allKnowledge;

  // 編集フォーム用コントローラー
  late TextEditingController _explanationController;
  late TextEditingController _titleController;
  late TextEditingController _customTagController;
  late TextEditingController _authorCommentController;
  late TextEditingController _topicController;
  bool _construction = false;
  bool _devCompleted = false;
  List<String> _tags = [];
  bool _saving = false;

  // ページ閲覧時の一時保存（保存前プレビュー）
  final Map<String, String> _savedExplanations = {};
  final Map<String, String> _savedTitles = {};
  final Map<String, bool> _savedConstruction = {};
  final Map<String, bool> _savedDevCompleted = {};
  final Map<String, List<String>> _savedTags = {};
  final Map<String, String> _savedAuthorComments = {};
  final Map<String, String?> _savedTopic = {};

  bool _isLeftHovering = false;
  bool _isRightHovering = false;

  /// 各知識に紐づく問題ID（knowledgeId -> [questionId, ...]）
  final Map<String, List<String>> _linkedQuestions = {};
  /// 問題がコアかどうか（questionId -> isCore）。question_knowledge の is_core を反映
  final Map<String, bool> _questionIsCore = {};
  /// 学習者向け：knowledge_id -> 英語例文
  final Map<String, List<EnglishExample>> _englishExamplesByKnowledgeId = {};
  /// 学習者向け：example_id -> SM-2 行（読み上げ・四択で共有）
  final Map<String, Map<String, dynamic>> _englishExampleLearningStates = {};
  /// 学習者向け：example_id -> 英作文モードの記録（読み上げとは別集計）
  final Map<String, Map<String, dynamic>> _englishExampleCompositionStates = {};
  /// 学習者向け：question_id -> 四択などの学習状態
  final Map<String, Map<String, dynamic>> _questionLearningStates = {};
  /// questions.id -> question_type（四択判定用）
  final Map<String, String> _questionTypeById = {};
  bool _showManageEdit = false;
  /// 勉強時間セッションと同期済みの PageView インデックス（初回 onPageChanged の二重開始防止）
  int _studySyncedPageIndex = -1;

  @override
  void initState() {
    super.initState();
    _allKnowledge = List.from(widget.allKnowledge);
    _currentIndex = widget.initialIndex.clamp(0, _allKnowledge.length - 1);
    _pageController = PageController(initialPage: _currentIndex);
    _isEditing = isDesktop && widget.initialEditing;
    _initControllersFromCurrent();
    _loadLinkedQuestions();
    _loadEnglishExamplesForLearner();
    if (widget.isLearnerMode) {
      _studySyncedPageIndex = _currentIndex;
      unawaited(_syncLearnerStudySession());
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        if (await shouldShowLearnerFlowManageShortcut()) {
          setState(() => _showManageEdit = true);
        }
      });
    }
  }

  Future<void> _syncLearnerStudySession() async {
    if (!widget.isLearnerMode || _allKnowledge.isEmpty) return;
    await StudyTimerService.instance.endSession();
    if (!mounted || !widget.isLearnerMode) return;
    final k = _allKnowledge[_currentIndex];
    final subjectId = widget.subjectId ?? k.subjectId;
    final subjectName = widget.subjectName ?? k.subject;
    await StudyTimerService.instance.startSession(
      sessionType: 'knowledge',
      contentId: k.id,
      contentTitle: k.content,
      unit: k.unit,
      subjectId: subjectId,
      subjectName: subjectName,
    );
  }

  /// 画面の Knowledge.id（`local_*` 可）→ Supabase `knowledge.id`（UUID）
  Future<Map<String, String>> _displayKnowledgeIdToSupabaseId() async {
    final out = <String, String>{};
    final pendingLocal = <int, String>{};

    for (final k in _allKnowledge) {
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

  /// Supabase 照合用の UUID 一覧と、UUID（正規化）→ 画面の knowledge.id へのマップ
  Future<({List<String> queryIds, Map<String, String> remoteNormToDisplayId})>
      _knowledgeSupabaseQueryContext() async {
    final displayToRemote = await _displayKnowledgeIdToSupabaseId();
    final queryIds = <String>{};
    final remoteNormToDisplayId = <String, String>{};

    for (final k in _allKnowledge) {
      final remote = displayToRemote[k.id];
      if (remote != null && remote.isNotEmpty) {
        queryIds.add(remote);
        remoteNormToDisplayId[remote.trim().toLowerCase()] = k.id;
      }
    }

    return (queryIds: queryIds.toList(), remoteNormToDisplayId: remoteNormToDisplayId);
  }

  Future<void> _loadEnglishExamplesForLearner() async {
    if (!widget.isLearnerMode || _allKnowledge.isEmpty) return;
    try {
      final client = Supabase.instance.client;
      final ctx = await _knowledgeSupabaseQueryContext();
      if (ctx.queryIds.isEmpty) {
        if (!mounted) return;
        setState(() {
          _englishExamplesByKnowledgeId.clear();
          _englishExampleLearningStates.clear();
          _englishExampleCompositionStates.clear();
        });
        return;
      }

      final rows = await client
          .from('english_examples')
          .select('id, knowledge_id, front_ja, back_en, explanation, supplement, prompt_supplement, display_order')
          .inFilter('knowledge_id', ctx.queryIds);
      final byKnowledge = <String, List<Map<String, dynamic>>>{
        for (final k in _allKnowledge) k.id: [],
      };
      for (final row in rows as List) {
        final r = row as Map<String, dynamic>;
        final rawKid = r['knowledge_id']?.toString();
        final n = rawKid != null ? rawKid.trim().toLowerCase() : '';
        final displayId = n.isNotEmpty ? ctx.remoteNormToDisplayId[n] : null;
        if (displayId != null && byKnowledge.containsKey(displayId)) {
          byKnowledge[displayId]!.add(r);
        }
      }
      final map = <String, List<EnglishExample>>{};
      for (final e in byKnowledge.entries) {
        e.value.sort((a, b) {
          final da = a['display_order'] as int?;
          final db = b['display_order'] as int?;
          if (da != null && db != null) return da.compareTo(db);
          if (da != null) return -1;
          if (db != null) return 1;
          return 0;
        });
        map[e.key] = e.value.map(EnglishExample.fromRow).toList();
      }
      final learnerId = client.auth.currentUser?.id;
      var states = <String, Map<String, dynamic>>{};
      var compStates = <String, Map<String, dynamic>>{};
      if (learnerId != null) {
        final exampleIds = <String>[];
        for (final list in map.values) {
          for (final ex in list) {
            exampleIds.add(ex.id);
          }
        }
        if (exampleIds.isNotEmpty) {
          final localDb = widget.localDatabase ?? SyncEngine.maybeLocalDb;
          states = await EnglishExampleStateSync.fetchLearningStatesHybrid(
            client: client,
            learnerId: learnerId,
            exampleIds: exampleIds,
            localDb: localDb,
          );
          compStates = await EnglishExampleStateSync.fetchCompositionStatesHybrid(
            client: client,
            learnerId: learnerId,
            exampleIds: exampleIds,
            localDb: localDb,
          );
        }
      }
      if (!mounted) return;
      setState(() {
        _englishExamplesByKnowledgeId
          ..clear()
          ..addAll(map);
        _englishExampleLearningStates
          ..clear()
          ..addAll(states);
        _englishExampleCompositionStates
          ..clear()
          ..addAll(compStates);
      });
    } catch (_) {}
  }

  /// 知識に紐づく問題を取得（四択・テキスト入力など全形式）
  /// API の knowledge_id は大文字小文字の差がある場合があるので正規化して照合する。
  Future<void> _loadLinkedQuestions() async {
    if (_allKnowledge.isEmpty) return;
    try {
      await triggerBackgroundSyncWithThrottle();
      if (!mounted) return;
      final client = Supabase.instance.client;
      final ctx = await _knowledgeSupabaseQueryContext();
      final normalizedToOriginal = <String, String>{};
      final byKnowledge = <String, List<String>>{};
      final isCoreMap = <String, bool>{};
      for (final k in _allKnowledge) {
        byKnowledge[k.id] = [];
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
          _linkedQuestions.clear();
          _linkedQuestions.addAll(byKnowledge);
          _questionIsCore.clear();
          _questionTypeById.clear();
          _questionLearningStates.clear();
        });
        return;
      }

      try {
        final fromDirect =
            await client.from('questions').select('id, knowledge_id').inFilter('knowledge_id', ctx.queryIds);
        for (final row in fromDirect as List) {
          final r = row as Map<String, dynamic>;
          final qId = r['id']?.toString();
          final kId = resolveDisplayKnowledgeId(r['knowledge_id']?.toString());
          if (qId != null && kId != null && !byKnowledge[kId]!.contains(qId)) {
            byKnowledge[kId]!.add(qId);
          }
        }
      } catch (_) {}
      try {
        final junc = await client
            .from('question_knowledge')
            .select('question_id, knowledge_id, is_core')
            .inFilter('knowledge_id', ctx.queryIds);
        for (final row in junc as List) {
          final r = row as Map<String, dynamic>;
          final qId = r['question_id']?.toString();
          final kId = resolveDisplayKnowledgeId(r['knowledge_id']?.toString());
          if (qId != null && kId != null && !byKnowledge[kId]!.contains(qId)) {
            byKnowledge[kId]!.add(qId);
          }
          if (qId != null) {
            isCoreMap[qId] = r['is_core'] == true;
          }
        }
      } catch (_) {}

      // DB に存在する問題だけに絞る（削除済み問題の question_knowledge 残骸で件数が膨らまないように）
      final allQIds = byKnowledge.values.expand((l) => l).toSet().toList();
      if (allQIds.isNotEmpty) {
        try {
          final existingRows = await client.from('questions').select('id').inFilter('id', allQIds);
          final existingIds = (existingRows as List).map((r) => (r as Map<String, dynamic>)['id']?.toString()).where((id) => id != null && id.isNotEmpty).cast<String>().toSet();
          for (final k in byKnowledge.keys.toList()) {
            byKnowledge[k] = byKnowledge[k]!.where((id) => existingIds.contains(id)).toList();
          }
        } catch (_) {}
      }

      final questionTypeById = <String, String>{};
      final filteredQIds = byKnowledge.values.expand((l) => l).toSet().toList();
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
      if (widget.isLearnerMode && filteredQIds.isNotEmpty) {
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

      if (!mounted) return;
      setState(() {
        _linkedQuestions.clear();
        _linkedQuestions.addAll(byKnowledge);
        _questionIsCore.clear();
        _questionIsCore.addAll(isCoreMap);
        _questionTypeById
          ..clear()
          ..addAll(questionTypeById);
        _questionLearningStates
          ..clear()
          ..addAll(qStates);
      });
    } catch (_) {}
  }

  void _initControllersFromCurrent() {
    final k = _allKnowledge[_currentIndex];
    _explanationController = TextEditingController(text: k.explanation);
    _titleController = TextEditingController(text: k.title);
    _customTagController = TextEditingController();
    _authorCommentController = TextEditingController(text: k.authorComment ?? '');
    _topicController = TextEditingController(text: k.unit ?? '');
    _construction = k.construction;
    _devCompleted = _savedDevCompleted[k.id] ?? k.devCompleted;
    _tags = List.from(k.tags);
  }

  @override
  void dispose() {
    if (widget.isLearnerMode) {
      unawaited(StudyTimerService.instance.endSession());
    }
    _pageController.dispose();
    _explanationController.dispose();
    _titleController.dispose();
    _customTagController.dispose();
    _authorCommentController.dispose();
    _topicController.dispose();
    super.dispose();
  }

  void _onPageChanged(int index) {
    setState(() {
      _currentIndex = index;
      final k = _allKnowledge[index];
      _explanationController.text = _savedExplanations[k.id] ?? k.explanation;
      _titleController.text = _savedTitles[k.id] ?? k.title;
      _authorCommentController.text = _savedAuthorComments[k.id] ?? k.authorComment ?? '';
      _topicController.text = _savedTopic[k.id] ?? k.unit ?? '';
      _construction = _savedConstruction[k.id] ?? k.construction;
      _devCompleted = _savedDevCompleted[k.id] ?? k.devCompleted;
      _tags = List.from(_savedTags[k.id] ?? k.tags);
    });
    if (widget.isLearnerMode && index != _studySyncedPageIndex) {
      _studySyncedPageIndex = index;
      unawaited(_syncLearnerStudySession());
    }
  }

  void _goToIndex(int index) {
    if (index < 0 || index >= _allKnowledge.length) return;
    if (_pageController.hasClients) {
      _pageController.jumpToPage(index);
    } else {
      _onPageChanged(index);
    }
  }

  static const _knowledgeSwipeVelocity = 320.0;

  void _onHorizontalFlingEnd(DragEndDetails details) {
    if (_allKnowledge.length < 2) return;
    final v = details.primaryVelocity;
    if (v == null || v.abs() < _knowledgeSwipeVelocity) return;
    if (v < 0 && _currentIndex < _allKnowledge.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else if (v > 0 && _currentIndex > 0) {
      _pageController.previousPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  /// モバイルで縦スクロールと競合しても横スワイプで前後カードへ行けるようにする
  Widget _wrapMobileSwipeTarget(Widget child) {
    if (isDesktop) return child;
    return GestureDetector(
      onHorizontalDragEnd: _onHorizontalFlingEnd,
      behavior: HitTestBehavior.deferToChild,
      child: child,
    );
  }

  Future<void> _saveChanges({bool exitEditMode = false}) async {
    setState(() => _saving = true);
    try {
      final currentKnowledge = _allKnowledge[_currentIndex];
      final title = _titleController.text;
      final text = _explanationController.text;
      final authorComment = _authorCommentController.text;
      final topic = _topicController.text;

      late final String saveStatusMessage;
      if (widget.localDatabase != null &&
          widget.subjectId != null &&
          widget.subjectName != null) {
        final repo = createKnowledgeRepository(widget.localDatabase);
        final updated = Knowledge(
          id: currentKnowledge.id,
          subjectId: widget.subjectId,
          subject: widget.subjectName,
          unit: topic.trim().isEmpty ? null : topic.trim(),
          content: title,
          description: text.isEmpty ? null : text,
          displayOrder: currentKnowledge.displayOrder,
          construction: _construction,
          tags: List.from(_tags),
          authorComment: authorComment.trim().isEmpty ? null : authorComment.trim(),
          devCompleted: _devCompleted,
        );
        final saved = await repo.save(updated, subjectId: widget.subjectId!, subjectName: widget.subjectName!);
        saveStatusMessage = await knowledgeSaveRemoteStatusAfterLocalPersist(
          localDb: widget.localDatabase!,
          knowledgeId: saved.id,
        );
      } else {
        final client = Supabase.instance.client;
        await client.from('knowledge').update(
          Knowledge.toUpdatePayload(
            title: title,
            explanation: text,
            topic: topic,
            construction: _construction,
            authorComment: authorComment,
            devCompleted: _devCompleted,
          ),
        ).eq('id', currentKnowledge.id);
        await Knowledge.syncTags(client, currentKnowledge.id, _tags);
        saveStatusMessage = 'Supabaseに反映しました';
      }

      if (mounted) {
        setState(() {
          _savedTitles[currentKnowledge.id] = title;
          _savedExplanations[currentKnowledge.id] = text;
          _savedAuthorComments[currentKnowledge.id] = authorComment;
          _savedTopic[currentKnowledge.id] = topic.trim().isEmpty ? null : topic.trim();
          _savedConstruction[currentKnowledge.id] = _construction;
          _savedDevCompleted[currentKnowledge.id] = _devCompleted;
          _savedTags[currentKnowledge.id] = List.from(_tags);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(saveStatusMessage)),
        );
        if (exitEditMode) {
          Navigator.of(context).pop(true);
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存エラー: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _deleteCard() async {
    final currentKnowledge = _allKnowledge[_currentIndex];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('カードを削除'),
        content: Text('「${currentKnowledge.title}」を削除しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _saving = true);
    try {
      final messenger = ScaffoldMessenger.of(context);
      final msg = await runKnowledgeDeleteWithSupabaseReport(
        knowledgeId: currentKnowledge.id,
        localDatabase: widget.localDatabase,
        subjectSupabaseId: widget.subjectId ?? currentKnowledge.subjectId,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
      messenger.showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 8),
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('削除エラー: $e'),
            duration: const Duration(seconds: 10),
            backgroundColor: Theme.of(context).colorScheme.errorContainer,
          ),
        );
      }
    }
  }

  Future<void> _openCreateFourChoiceForCurrentKnowledge() async {
    final k = _allKnowledge[_currentIndex];
    final remoteMap = await _displayKnowledgeIdToSupabaseId();
    final remoteKnowledgeId = remoteMap[k.id];
    if (remoteKnowledgeId == null || remoteKnowledgeId.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('この知識カードはまだ同期されていません。先に保存/同期してください。')),
      );
      return;
    }
    String? subjectId = k.subjectId;
    if (subjectId != null && subjectId.startsWith('local_')) {
      subjectId = null;
    }
    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (context) => FourChoiceCreateScreen(
          initialSubjectId: subjectId,
          initialKnowledgeId: remoteKnowledgeId,
        ),
      ),
    );
    if (mounted) await _loadLinkedQuestions();
  }

  Future<void> _openCreateEnglishExampleForCurrentKnowledge() async {
    final k = _allKnowledge[_currentIndex];
    final remoteMap = await _displayKnowledgeIdToSupabaseId();
    final remoteKnowledgeId = remoteMap[k.id];
    if (remoteKnowledgeId == null || remoteKnowledgeId.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('この知識カードはまだ同期されていません。先に保存/同期してください。')),
      );
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => EnglishExampleListScreen(
          initialCreateKnowledgeId: remoteKnowledgeId,
        ),
      ),
    );
    if (mounted) {
      await _loadLinkedQuestions();
      await _loadEnglishExamplesForLearner();
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentKnowledge = _allKnowledge[_currentIndex];
    final hasPrevious = _currentIndex > 0;
    final hasNext = _currentIndex < _allKnowledge.length - 1;

    final scaffold = Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _savedTitles[currentKnowledge.id] ?? currentKnowledge.title,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              '${_currentIndex + 1} / ${_allKnowledge.length}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          if (!_isEditing && widget.isLearnerMode && _showManageEdit)
            IconButton(
              icon: const Icon(Icons.edit),
              tooltip: '教材を編集',
              onPressed: () => openManageNotifier.openManage?.call(context),
            ),
          if (hasPrevious)
            IconButton(
              icon: const Icon(Icons.chevron_left),
              onPressed: () {
                if (_isEditing) {
                  _goToIndex(_currentIndex - 1);
                } else {
                  _pageController.previousPage(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeInOut,
                  );
                }
              },
              tooltip: '前のカード',
            ),
          if (hasNext)
            IconButton(
              icon: const Icon(Icons.chevron_right),
              onPressed: () {
                if (_isEditing) {
                  _goToIndex(_currentIndex + 1);
                } else {
                  _pageController.nextPage(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeInOut,
                  );
                }
              },
              tooltip: '次のカード',
            ),
          if (!_isEditing && !widget.isLearnerMode)
            IconButton(
              icon: const Icon(Icons.edit),
              onPressed: _saving
                  ? null
                  : () async {
                      if (isAndroid) {
                        final saved = await Navigator.of(context).push<bool>(
                          MaterialPageRoute<bool>(
                            builder: (context) => KnowledgeEditScreen(
                              currentKnowledge: currentKnowledge,
                              initialTitle: _titleController.text,
                              initialExplanation: _explanationController.text,
                              initialConstruction: _construction,
                              initialTags: List.from(_tags),
                              initialAuthorComment: _authorCommentController.text,
                              initialDevCompleted:
                                  _savedDevCompleted[currentKnowledge.id] ?? currentKnowledge.devCompleted,
                              initialTopic: _topicController.text.trim().isEmpty
                                  ? null
                                  : _topicController.text.trim(),
                              localDatabase: widget.localDatabase,
                              subjectId: widget.subjectId,
                              subjectName: widget.subjectName,
                            ),
                          ),
                        );
                        if (saved == true && mounted) {
                          Navigator.of(context).pop(true);
                        }
                      } else {
                        setState(() => _isEditing = true);
                      }
                    },
              tooltip: '編集',
            ),
          if (_isEditing) ...[
            if (_saving)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else ...[
              TextButton.icon(
                onPressed: () => _saveChanges(exitEditMode: true),
                icon: const Icon(Icons.save),
                label: const Text('保存'),
              ),
              IconButton(
                icon: Icon(
                  Icons.delete_outline,
                  color: Theme.of(context).colorScheme.error,
                ),
                onPressed: _deleteCard,
                tooltip: 'カードを削除',
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => _saveChanges(exitEditMode: true),
                tooltip: '保存して一覧に戻る（Ctrl+W）',
              ),
            ],
          ],
        ],
      ),
      body: _isEditing ? _buildEditView(context) : _buildPageView(context),
    );

    if (!_isEditing) return scaffold;

    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.keyS, control: true): SaveIntent(),
        SingleActivator(LogicalKeyboardKey.keyS, meta: true): SaveIntent(),
        SingleActivator(LogicalKeyboardKey.keyW, control: true): CloseEditIntent(),
        SingleActivator(LogicalKeyboardKey.keyW, meta: true): CloseEditIntent(),
      },
      child: Actions(
        actions: {
          SaveIntent: CallbackAction<SaveIntent>(
            onInvoke: (_) async {
              await _saveChanges(exitEditMode: false);
              return null;
            },
          ),
          CloseEditIntent: CallbackAction<CloseEditIntent>(
            onInvoke: (_) async {
              await _saveChanges(exitEditMode: true);
              return null;
            },
          ),
        },
        child: scaffold,
      ),
    );
  }

  Widget _buildEditView(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: _buildEditPane(context)),
        const VerticalDivider(width: 1),
        Expanded(child: _buildPreviewPane(context)),
      ],
    );
  }

  Widget _buildEditPane(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '編集',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: scheme.primary,
                ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _saving ? null : () => unawaited(_openCreateFourChoiceForCurrentKnowledge()),
                icon: const Icon(Icons.quiz_outlined),
                label: const Text('四択問題を作成'),
              ),
              OutlinedButton.icon(
                onPressed: _saving ? null : () => unawaited(_openCreateEnglishExampleForCurrentKnowledge()),
                icon: const Icon(Icons.edit_note_outlined),
                label: const Text('英作文を作成'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _titleController,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'タイトル',
              border: OutlineInputBorder(),
            ),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8.0, bottom: 4.0),
            child: Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 140,
                  child: TextField(
                    controller: _topicController,
                    decoration: const InputDecoration(
                      labelText: 'チャプター',
                      hintText: '例：仮定法',
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    ),
                  ),
                ),
                FilterChip(
                  label: const Text('構文'),
                  selected: _construction,
                  onSelected: (value) async {
                    setState(() => _construction = value);
                    await _saveChanges(exitEditMode: false);
                  },
                  selectedColor: scheme.surfaceContainerHighest,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8.0, bottom: 4.0),
            child: DevCompletionSegmented(
              value: _devCompleted,
              onChanged: (v) async {
                setState(() => _devCompleted = v);
                await _saveChanges(exitEditMode: false);
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4.0, bottom: 8.0),
            child: Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ..._tags.map((t) => Chip(
                      label: Text(t),
                      deleteIcon: const Icon(Icons.close, size: 18),
                      onDeleted: () async {
                        setState(() => _tags = _tags.where((x) => x != t).toList());
                        await _saveChanges(exitEditMode: false);
                      },
                      backgroundColor: scheme.surfaceContainerHighest,
                    )),
                SizedBox(
                  width: 100,
                  child: TextField(
                    controller: _customTagController,
                    decoration: const InputDecoration(
                      hintText: 'タグを入力して追加',
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    ),
                    onSubmitted: (value) async {
                      final t = value.trim();
                      if (t.isNotEmpty && !_tags.contains(t)) {
                        setState(() {
                          _tags = [..._tags, t]..sort();
                          _customTagController.clear();
                        });
                        await _saveChanges(exitEditMode: false);
                      }
                    },
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: () async {
                    final t = _customTagController.text.trim();
                    if (t.isNotEmpty && !_tags.contains(t)) {
                      setState(() {
                        _tags = [..._tags, t]..sort();
                        _customTagController.clear();
                      });
                      await _saveChanges(exitEditMode: false);
                    }
                  },
                  tooltip: 'タグを追加',
                ),
              ],
            ),
          ),
          Expanded(
            child: TextField(
              controller: _explanationController,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '説明を入力...（Ctrl+S 保存 / Ctrl+W 編集終了）',
                contentPadding: EdgeInsets.fromLTRB(12, 12, 12, 12),
                alignLabelWithHint: true,
              ),
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '執筆者用コメント',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 4),
          TextField(
            controller: _authorCommentController,
            maxLines: 2,
            minLines: 1,
            textAlignVertical: TextAlignVertical.top,
            decoration: const InputDecoration(
              hintText: '参考書には出しません。メモ用です。',
              border: OutlineInputBorder(),
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              alignLabelWithHint: true,
            ),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewPane(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_explanationController, _titleController]),
      builder: (context, _) {
        return Container(
          color: Theme.of(context).colorScheme.surface,
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'プレビュー',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                _titleController.text,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8.0, bottom: 4.0),
                child: Wrap(
                  spacing: 8,
                  children: [
                    if (_topicController.text.trim().isNotEmpty)
                      Chip(
                        label: Text(_topicController.text.trim()),
                        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                      ),
                    if (_construction)
                      Chip(
                        label: const Text('構文'),
                        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                      ),
                    Chip(
                      label: Text(_devCompleted ? '完成' : '要確認'),
                      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 4.0, bottom: 8.0),
                child: Wrap(
                  spacing: 8,
                  children: _tags
                      .map((t) => Chip(
                            label: Text(t),
                            backgroundColor:
                                Theme.of(context).colorScheme.surfaceContainerHighest,
                          ))
                      .toList(),
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  child: SelectionArea(
                    child: ExplanationText(text: _explanationController.text),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildLearnerMemorizationBadges(BuildContext context, Knowledge knowledge) {
    final qids = _linkedQuestions[knowledge.id] ?? [];
    final mcqIds =
        qids.where((id) => _questionTypeById[id] == 'multiple_choice').toList();
    final examples = _englishExamplesByKnowledgeId[knowledge.id] ?? [];

    if (mcqIds.isEmpty && examples.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: KnowledgeLearnerMemStatus.combinedMark(
          context,
          mcqIds: mcqIds,
          examples: examples,
          questionStates: _questionLearningStates,
          exampleStates: _englishExampleLearningStates,
          exampleCompositionStates: _englishExampleCompositionStates,
          size: 28,
        ),
      ),
    );
  }

  /// 学習者向け：本文の直後に、例文・問題へのリンクのみ（アイコンサイズ統一）
  Widget _buildLearnerPracticeLinks(BuildContext context, Knowledge knowledge) {
    final examples = _englishExamplesByKnowledgeId[knowledge.id];
    final hasExamples = examples != null && examples.isNotEmpty;
    final exList = hasExamples ? examples : null;
    final ids = _linkedQuestions[knowledge.id];
    final hasQuestions = ids != null && ids.isNotEmpty;
    if (!hasExamples && !hasQuestions) return const SizedBox.shrink();

    List<String>? orderedQuestionIds;
    if (hasQuestions) {
      final coreIds = ids.where((id) => _questionIsCore[id] != false).toList();
      final suppIds = ids.where((id) => _questionIsCore[id] == false).toList();
      orderedQuestionIds = [...coreIds, ...suppIds];
    }

    const iconSize = 24.0;
    final linkStyle = TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      minimumSize: Size.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );

    return Padding(
      padding: const EdgeInsets.only(top: 16.0),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (hasQuestions)
            TextButton.icon(
              style: linkStyle,
              icon: const Icon(Icons.fact_check_outlined, size: iconSize),
              label: const Text('練習問題'),
              onPressed: () {
                Navigator.of(context)
                    .push<void>(
                  MaterialPageRoute<void>(
                    builder: (context) => QuestionSolveScreen(
                      questionIds: orderedQuestionIds!,
                      knowledgeTitle: knowledge.title,
                      isLearnerMode: widget.isLearnerMode,
                    ),
                  ),
                )
                    .then((_) {
                  if (mounted) _loadLinkedQuestions();
                });
              },
            ),
          if (hasExamples) ...[
            TextButton.icon(
              style: linkStyle,
              icon: const Icon(Icons.edit_note, size: iconSize),
              label: const Text('英作文'),
              onPressed: () {
                Navigator.of(context)
                    .push<void>(
                  MaterialPageRoute<void>(
                    builder: (context) => EnglishExampleCompositionScreen(
                      examples: exList!,
                      subjectName: widget.subjectName ?? knowledge.title,
                      sessionDescriptor: knowledge.title,
                    ),
                  ),
                )
                    .then((_) {
                  if (mounted) _loadEnglishExamplesForLearner();
                });
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPageView(BuildContext context) {
    final pageView = PageView.builder(
      controller: _pageController,
      onPageChanged: _onPageChanged,
      itemCount: _allKnowledge.length,
      scrollBehavior: ScrollConfiguration.of(context).copyWith(
        dragDevices: {
          PointerDeviceKind.touch,
          PointerDeviceKind.mouse,
          PointerDeviceKind.stylus,
          PointerDeviceKind.trackpad,
        },
      ),
      itemBuilder: (context, index) {
        final knowledge = _allKnowledge[index];
        final explanation = _savedExplanations[knowledge.id] ?? knowledge.explanation;
        final construction = _savedConstruction[knowledge.id] ?? knowledge.construction;
        final devCompleted = _savedDevCompleted[knowledge.id] ?? knowledge.devCompleted;
        final tags = _savedTags[knowledge.id] ?? knowledge.tags;
        final topic = _savedTopic[knowledge.id] ?? knowledge.unit;
        final authorComment =
            _savedAuthorComments[knowledge.id] ?? knowledge.authorComment ?? '';

        return _wrapMobileSwipeTarget(
          Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.isLearnerMode)
                  _buildLearnerMemorizationBadges(context, knowledge)
                else if (!widget.isLearnerMode)
                  Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Wrap(
                      spacing: 8,
                      children: [
                        if (topic != null)
                          Chip(
                            label: Text(topic),
                            backgroundColor:
                                Theme.of(context).colorScheme.surfaceContainerHighest,
                          ),
                        if (construction)
                          Chip(
                            label: const Text('構文'),
                            backgroundColor:
                                Theme.of(context).colorScheme.surfaceContainerHighest,
                          ),
                        Chip(
                          label: Text(devCompleted ? '完成' : '要確認'),
                          backgroundColor:
                              Theme.of(context).colorScheme.surfaceContainerHighest,
                        ),
                        ...tags.map((t) => Chip(
                              label: Text(t),
                              backgroundColor:
                                  Theme.of(context).colorScheme.surfaceContainerHighest,
                            )),
                      ],
                    ),
                  ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SelectionArea(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              ExplanationText(text: explanation),
                              if (!widget.isLearnerMode && authorComment.isNotEmpty) ...[
                                const SizedBox(height: 24),
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .surfaceContainerHighest
                                        .withOpacity(0.7),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .outlineVariant
                                          .withOpacity(0.5),
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '執筆者用コメント（参考書には出しません）',
                                        style:
                                            Theme.of(context).textTheme.labelSmall?.copyWith(
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .onSurfaceVariant,
                                                ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        authorComment,
                                        style: Theme.of(context).textTheme.bodySmall,
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (widget.isLearnerMode)
                          _buildLearnerPracticeLinks(context, knowledge),
                      ],
                    ),
                  ),
                ),
              ],
            ),
        );
      },
    );

    return Stack(
      children: [
        pageView,
        if (_allKnowledge.length > 1 && isDesktop) ...[
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: MouseRegion(
              onEnter: (_) => setState(() => _isLeftHovering = true),
              onExit: (_) => setState(() => _isLeftHovering = false),
              child: GestureDetector(
                onTap: _currentIndex > 0
                    ? () => _pageController.previousPage(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeInOut,
                        )
                    : null,
                child: Container(
                  width: 100,
                  color: _isLeftHovering && _currentIndex > 0
                      ? Theme.of(context).colorScheme.outline.withOpacity(0.08)
                      : Colors.transparent,
                  child: Center(
                    child: AnimatedOpacity(
                      opacity: _isLeftHovering && _currentIndex > 0 ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 200),
                      child: Icon(
                        Icons.chevron_left,
                        size: 48,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            child: MouseRegion(
              onEnter: (_) => setState(() => _isRightHovering = true),
              onExit: (_) => setState(() => _isRightHovering = false),
              child: GestureDetector(
                onTap: _currentIndex < _allKnowledge.length - 1
                    ? () => _pageController.nextPage(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeInOut,
                        )
                    : null,
                child: Container(
                  width: 100,
                  color: _isRightHovering && _currentIndex < _allKnowledge.length - 1
                      ? Theme.of(context).colorScheme.outline.withOpacity(0.08)
                      : Colors.transparent,
                  child: Center(
                    child: AnimatedOpacity(
                      opacity: _isRightHovering && _currentIndex < _allKnowledge.length - 1
                          ? 1.0
                          : 0.0,
                      duration: const Duration(milliseconds: 200),
                      child: Icon(
                        Icons.chevron_right,
                        size: 48,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
