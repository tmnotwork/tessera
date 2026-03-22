import 'package:flutter/material.dart';

import '../models/english_example.dart';
import 'english_example_review_filter.dart';

/// 四択・例文の学習状況（一覧・詳細で共通の3択）
///
/// - [notAttempted]: まだ取り組んでいない項目がある
/// - [incorrectOrNeedsWork]: 取り組んだが不正解、または要復習
/// - [correct]: 対象項目はいずれも正解の状態（復習期限も問題なし）
enum KnowledgePracticeTriState {
  notAttempted,
  incorrectOrNeedsWork,
  correct,
}

class KnowledgeLearnerMemStatus {
  KnowledgeLearnerMemStatus._();

  /// 単一の四択問題の状態
  static KnowledgePracticeTriState triForMcqItem(Map<String, dynamic>? state) {
    if (state == null) return KnowledgePracticeTriState.notAttempted;
    if (state['last_is_correct'] != true) {
      return KnowledgePracticeTriState.incorrectOrNeedsWork;
    }
    if (!_mcqInGoodStanding(state)) {
      return KnowledgePracticeTriState.incorrectOrNeedsWork;
    }
    return KnowledgePracticeTriState.correct;
  }

  static bool _mcqInGoodStanding(Map<String, dynamic> state) {
    final reviewed = (state['reviewed_count'] as num?)?.toInt() ?? 0;
    final lapse = (state['lapse_count'] as num?)?.toInt() ?? 0;
    final isInitialKnown = reviewed <= 1 && lapse == 0;
    if (isInitialKnown) return true;

    final nextReviewRaw = state['next_review_at']?.toString();
    if (nextReviewRaw == null || nextReviewRaw.isEmpty) return true;
    DateTime? nextReviewAt;
    try {
      nextReviewAt = DateTime.parse(nextReviewRaw).toUtc();
    } catch (_) {
      nextReviewAt = null;
    }
    if (nextReviewAt == null) return true;
    final now = DateTime.now().toUtc();
    return !now.isAfter(nextReviewAt);
  }

  static KnowledgePracticeTriState aggregateMcqTri(
    List<String> mcqIds,
    Map<String, Map<String, dynamic>> questionStates,
  ) {
    if (mcqIds.isEmpty) {
      return KnowledgePracticeTriState.correct;
    }
    var anyNotAttempted = false;
    for (final id in mcqIds) {
      final t = triForMcqItem(questionStates[id]);
      if (t == KnowledgePracticeTriState.incorrectOrNeedsWork) {
        return KnowledgePracticeTriState.incorrectOrNeedsWork;
      }
      if (t == KnowledgePracticeTriState.notAttempted) anyNotAttempted = true;
    }
    if (anyNotAttempted) return KnowledgePracticeTriState.notAttempted;
    return KnowledgePracticeTriState.correct;
  }

  /// 単一例文の状態（状態なし = 未挑戦）
  static KnowledgePracticeTriState triForExampleItem(Map<String, dynamic>? state) {
    if (state == null) return KnowledgePracticeTriState.notAttempted;
    if (EnglishExampleReviewFilter.needsReview(state)) {
      return KnowledgePracticeTriState.incorrectOrNeedsWork;
    }
    return KnowledgePracticeTriState.correct;
  }

  static KnowledgePracticeTriState aggregateExamplesTri(
    List<EnglishExample> examples,
    Map<String, Map<String, dynamic>> exampleStates,
  ) {
    if (examples.isEmpty) return KnowledgePracticeTriState.correct;
    var anyNotAttempted = false;
    for (final ex in examples) {
      final t = triForExampleItem(exampleStates[ex.id]);
      if (t == KnowledgePracticeTriState.incorrectOrNeedsWork) {
        return KnowledgePracticeTriState.incorrectOrNeedsWork;
      }
      if (t == KnowledgePracticeTriState.notAttempted) anyNotAttempted = true;
    }
    if (anyNotAttempted) return KnowledgePracticeTriState.notAttempted;
    return KnowledgePracticeTriState.correct;
  }

  /// 四択・例文をまとめた1つの3択（悪い方を優先）
  static KnowledgePracticeTriState combineTracks({
    required bool hasMcq,
    required bool hasExamples,
    required KnowledgePracticeTriState mcqTri,
    required KnowledgePracticeTriState examplesTri,
  }) {
    if (!hasMcq && !hasExamples) {
      return KnowledgePracticeTriState.correct;
    }
    final parts = <KnowledgePracticeTriState>[
      if (hasMcq) mcqTri,
      if (hasExamples) examplesTri,
    ];
    if (parts.any((p) => p == KnowledgePracticeTriState.incorrectOrNeedsWork)) {
      return KnowledgePracticeTriState.incorrectOrNeedsWork;
    }
    if (parts.any((p) => p == KnowledgePracticeTriState.notAttempted)) {
      return KnowledgePracticeTriState.notAttempted;
    }
    return KnowledgePracticeTriState.correct;
  }

  static String _triStateJa(KnowledgePracticeTriState t) {
    return switch (t) {
      KnowledgePracticeTriState.notAttempted => '取り組んでいない',
      KnowledgePracticeTriState.incorrectOrNeedsWork => '間違い・要復習',
      KnowledgePracticeTriState.correct => '正解の状態',
    };
  }

  static String combinedTooltip({
    required KnowledgePracticeTriState combined,
    required bool hasMcq,
    required bool hasExamples,
    KnowledgePracticeTriState? mcqTri,
    KnowledgePracticeTriState? examplesTri,
  }) {
    final lines = <String>['全体: ${_triStateJa(combined)}'];
    if (hasMcq && mcqTri != null) {
      lines.add('四択: ${_triStateJa(mcqTri)}');
    }
    if (hasExamples && examplesTri != null) {
      lines.add('例文: ${_triStateJa(examplesTri)}');
    }
    return lines.join('\n');
  }

  /// チェック系アイコン1つで3択を表示（> は付けない）
  static Widget combinedMark(
    BuildContext context, {
    required List<String> mcqIds,
    required List<EnglishExample> examples,
    required Map<String, Map<String, dynamic>> questionStates,
    required Map<String, Map<String, dynamic>> exampleStates,
    double size = 24,
  }) {
    final hasMcq = mcqIds.isNotEmpty;
    final hasEx = examples.isNotEmpty;
    if (!hasMcq && !hasEx) return const SizedBox.shrink();

    final mcqTri = aggregateMcqTri(mcqIds, questionStates);
    final exTri = aggregateExamplesTri(examples, exampleStates);
    final combined = combineTracks(
      hasMcq: hasMcq,
      hasExamples: hasEx,
      mcqTri: mcqTri,
      examplesTri: exTri,
    );

    final scheme = Theme.of(context).colorScheme;
    final IconData icon;
    final Color color;
    switch (combined) {
      case KnowledgePracticeTriState.correct:
        icon = Icons.check_circle;
        color = Colors.green.shade700;
      case KnowledgePracticeTriState.notAttempted:
        icon = Icons.check_circle_outline;
        color = scheme.outline;
      case KnowledgePracticeTriState.incorrectOrNeedsWork:
        icon = Icons.cancel;
        color = scheme.error;
    }

    return Tooltip(
      message: combinedTooltip(
        combined: combined,
        hasMcq: hasMcq,
        hasExamples: hasEx,
        mcqTri: hasMcq ? mcqTri : null,
        examplesTri: hasEx ? exTri : null,
      ),
      child: Icon(icon, size: size, color: color),
    );
  }
}
