import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../database/local_database.dart';
import '../repositories/streak_repository.dart';
import '../sync/ensure_synced_for_local_read.dart';
import 'streak_celebration_dialog.dart';

/// 同一アプリセッション内で起動時ストリーク処理を二度走らせない（タブ切替等でウィジェットが付け替わる対策）。
bool _learnerStreakLaunchSessionDone = false;

/// 学習者シェル：起動時の再計算・[StreakCelebrationDialog]／当日初回 [StreakDailyGreetingDialog]。
/// UI の常時バーは出さない（レイアウトは [SizedBox.shrink]）。
///
/// - [study_sessions] のローカル日付で連続日数を算出する（[StreakRepository]）。
/// - アプリを跨日で開いたままにしても、[AppLifecycleState.resumed] で暦日が変われば再取得する。
class LearnerStreakLaunchEffects extends StatefulWidget {
  const LearnerStreakLaunchEffects({
    super.key,
    this.localDatabase,
    this.offerDailyGreeting = true,
  });

  final LocalDatabase? localDatabase;

  /// 当日初回の連続日数ダイアログ（プレビュー内など二重表示を避けるとき false）
  final bool offerDailyGreeting;

  @override
  State<LearnerStreakLaunchEffects> createState() =>
      _LearnerStreakLaunchEffectsState();
}

class _LearnerStreakLaunchEffectsState extends State<LearnerStreakLaunchEffects>
    with WidgetsBindingObserver {
  bool _ran = false;
  String? _lastKnownLocalDate;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lastKnownLocalDate = StreakRepository.todayKeyLocal();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_runLaunchSequence());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (kIsWeb || widget.localDatabase == null) return;
    unawaited(_onResumeMaybeNewDay());
  }

  /// 日付をまたいでフォアグラウンドに戻ったとき、バッジ更新と「新しい一日」の案内を試みる。
  Future<void> _onResumeMaybeNewDay() async {
    final today = StreakRepository.todayKeyLocal();
    final crossedMidnight =
        _lastKnownLocalDate != null && _lastKnownLocalDate != today;
    _lastKnownLocalDate = today;

    final learnerId = Supabase.instance.client.auth.currentUser?.id;
    if (learnerId == null || learnerId.isEmpty) return;

    try {
      await ensureSyncedForLocalRead();
      if (!mounted) return;
      final repo = StreakRepository(widget.localDatabase!.db);
      // キャッシュではなく DB から再計算（起動直後と同じ連続日数に揃える）
      final info = await repo.recompute(learnerId);
      if (!mounted) return;

      if (crossedMidnight && widget.offerDailyGreeting) {
        await _showFirstLaunchOfDayGreetingIfNeeded(learnerId, info);
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('LearnerStreakLaunchEffects resume: $e\n$st');
      }
    }
  }

  Future<void> _runLaunchSequence() async {
    if (_ran) return;
    if (_learnerStreakLaunchSessionDone) return;
    if (kIsWeb || widget.localDatabase == null) return;

    final learnerId = Supabase.instance.client.auth.currentUser?.id;
    if (learnerId == null || learnerId.isEmpty) return;

    _ran = true;

    try {
      await ensureSyncedForLocalRead();
      if (!mounted) return;
      final repo = StreakRepository(widget.localDatabase!.db);
      final info = await repo.recompute(learnerId);
      if (!mounted) return;

      final m = info.milestoneToCelebrate;
      if (m != null) {
        await StreakCelebrationDialog.show(context, m);
        if (!mounted) return;
        await repo.markMilestoneCelebrated(learnerId, m);
        await StreakRepository.markDailyGreetingShown(learnerId, info.current);
      } else if (widget.offerDailyGreeting) {
        await _showFirstLaunchOfDayGreetingIfNeeded(learnerId, info);
      }
      _learnerStreakLaunchSessionDone = true;
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('LearnerStreakLaunchEffects: $e\n$st');
      }
    }
  }

  Future<void> _showFirstLaunchOfDayGreetingIfNeeded(
    String learnerId,
    StreakInfo info,
  ) async {
    if (!await StreakRepository.shouldShowDailyGreeting(
          learnerId,
          info.current,
        )) {
      return;
    }
    if (!mounted) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    await StreakDailyGreetingDialog.show(
      context,
      currentStreak: info.current,
    );
    if (!mounted) return;
    await StreakRepository.markDailyGreetingShown(learnerId, info.current);
  }

  @override
  Widget build(BuildContext context) {
    return const SizedBox.shrink();
  }
}
