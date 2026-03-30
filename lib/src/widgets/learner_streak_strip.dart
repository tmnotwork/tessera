import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../database/local_database.dart';
import '../repositories/streak_repository.dart';
import '../sync/ensure_synced_for_local_read.dart';
import 'streak_celebration_dialog.dart';

/// 同一アプリセッション内で連続学習の起動時処理を二度走らせない（タブ切替でウィジェットが付け替わる対策）。
bool _learnerStreakLaunchSessionDone = false;

/// レイアウトは持たず、マウント時1回だけ同期・連続学習日数の再計算・マイルストーン／当日案内を行う。
///
/// 画面上部の常時バーは出さない（タブ切替や学習後の再読込もしない）。
class LearnerStreakLaunchEffects extends StatefulWidget {
  const LearnerStreakLaunchEffects({
    super.key,
    this.localDatabase,
    this.offerDailyGreeting = true,
  });

  final LocalDatabase? localDatabase;

  /// 当日初回の SnackBar 案内（プレビュー内など二重表示を避けるとき false）
  final bool offerDailyGreeting;

  @override
  State<LearnerStreakLaunchEffects> createState() =>
      _LearnerStreakLaunchEffectsState();
}

class _LearnerStreakLaunchEffectsState extends State<LearnerStreakLaunchEffects> {
  bool _ran = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_runOnce());
    });
  }

  Future<void> _runOnce() async {
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
        await StreakRepository.markDailyGreetingShown(learnerId);
      } else if (widget.offerDailyGreeting) {
        unawaited(_showFirstLaunchOfDayGreetingIfNeeded(learnerId, info));
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
    if (!await StreakRepository.shouldShowDailyGreeting(learnerId)) return;
    if (!mounted) return;
    await StreakRepository.markDailyGreetingShown(learnerId);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger == null) return;
      final msg = info.current > 0
          ? '学習を ${info.current} 日連続で記録しています'
          : '今日の学習を記録すると、連続日数が積み上がります';
      messenger.showSnackBar(
        SnackBar(
          content: Text(msg),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 5),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
