import '../models/routine_task_v2.dart';
import 'auth_service.dart';
import 'routine_mutation_facade.dart';
import 'routine_task_v2_service.dart';

/// V2データの自己回復（主にショートカットID分裂の収束）。
class RoutineV2BackfillService {
  RoutineV2BackfillService._();

  static const String shortcutTemplateId = 'shortcut';
  static const String shortcutBlockId = 'v2blk_shortcut_0';

  /// ショートカット（非定型ショートカット）を、V2の正規IDへ収束させる。
  ///
  /// 目的:
  /// - legacy/過去実装で `shortcut_<timestamp>` 等に分裂したショートカットを、
  ///   `templateId=shortcut` / `blockId=v2blk_shortcut_0` に寄せて表示できるようにする。
  /// - 移動時に userId も現在ユーザーへ付与する（未設定・誤設定の救済）。
  ///
  /// 戻り値: 移動（更新）したタスク件数
  static Future<int> normalizeShortcutTasksToCanonical() async {
    // 厳密に “ショートカット” を確定できる情報だけを使う。
    //
    // - V2正規ショートカット: templateId=shortcut（だが blockId がズレているケースがあり得る）
    // - legacy/過去実装: templateId が `shortcut_<...>` 等に分裂したケース（IDプレフィックスで判定）

    final uid = AuthService.getCurrentUserId();

    // 1) 正規テンプレIDの中で blockId がズレているタスクを寄せる
    final canonicalTemplateTasks = RoutineTaskV2Service.debugGetAllRaw()
        .where((t) => !t.isDeleted)
        .where((t) => t.routineTemplateId == shortcutTemplateId)
        .toList();

    // 2) legacy/過去実装の templateId を使っているタスクを寄せる
    final legacyShortcutTasks = RoutineTaskV2Service.debugGetAllRaw()
        .where((t) => !t.isDeleted)
        .where(
          (t) =>
              t.routineTemplateId != shortcutTemplateId &&
              t.routineTemplateId.startsWith('shortcut'),
        )
        .toList();

    final candidates = <RoutineTaskV2>[
      ...canonicalTemplateTasks,
      ...legacyShortcutTasks,
    ];

    final toMove = candidates
        .where((t) =>
            t.routineTemplateId != shortcutTemplateId ||
            t.routineBlockId != shortcutBlockId)
        .toList();

    if (toMove.isEmpty) return 0;

    // order付け: 既存の正規タスク末尾に追加（見た目が崩れない）
    final existingCanonical = RoutineTaskV2Service.debugGetAllRaw()
        .where((t) =>
            !t.isDeleted &&
            t.routineTemplateId == shortcutTemplateId &&
            t.routineBlockId == shortcutBlockId)
        .toList();
    int nextOrder = 0;
    if (existingCanonical.isNotEmpty) {
      nextOrder =
          existingCanonical.map((t) => t.order).reduce((a, b) => a > b ? a : b) +
              1;
    }

    // Stable order: templateId -> blockId -> order -> createdAt -> id
    toMove.sort((a, b) {
      final c1 = a.routineTemplateId.compareTo(b.routineTemplateId);
      if (c1 != 0) return c1;
      final c2 = a.routineBlockId.compareTo(b.routineBlockId);
      if (c2 != 0) return c2;
      final c3 = a.order.compareTo(b.order);
      if (c3 != 0) return c3;
      final c4 = a.createdAt.compareTo(b.createdAt);
      if (c4 != 0) return c4;
      return a.id.compareTo(b.id);
    });

    int moved = 0;
    for (final t in toMove) {
      final updated = t.copyWith(
        routineTemplateId: shortcutTemplateId,
        routineBlockId: shortcutBlockId,
        order: nextOrder,
        // userId が空・誤りの場合は現在ユーザーへ付与する（正規化と同時に救済）
        userId: (uid != null && uid.isNotEmpty) ? uid : t.userId,
      );
      nextOrder += 1;
      await RoutineMutationFacade.instance.updateTask(updated);
      moved += 1;
    }
    return moved;
  }

  /// ショートカットが表示できない（V2正規ID配下にタスクが存在しない）場合の自己回復。
  ///
  /// - legacyショートカットが存在するなら正規IDへ収束させつつ userId も修正する。
  /// - cutover後でも “表示されない” はUX劣化なので、この1回限りの移行は許容する。
  static Future<void> ensureShortcutBundleBackfilledIfEmpty() async {
    final uid = AuthService.getCurrentUserId();
    if (uid == null || uid.isEmpty) return;

    // 現在ユーザーの正規タスクが既にあれば何もしない
    final hasCanonicalForUser = RoutineTaskV2Service.debugGetAllRaw().any(
      (t) =>
          !t.isDeleted &&
          t.routineTemplateId == shortcutTemplateId &&
          t.routineBlockId == shortcutBlockId &&
          t.userId == uid,
    );
    if (hasCanonicalForUser) return;

    // Step 1: レガシーIDのタスクを正規IDへ収束させる（userId も同時に付与）
    await normalizeShortcutTasksToCanonical();

    // Step 2: 正規IDに存在するが userId が誤っているタスクを現在ユーザーへ修正する
    // （normalization後も含め、全パターンを一括救済）
    final wrongUserCanonical = RoutineTaskV2Service.debugGetAllRaw()
        .where((t) =>
            !t.isDeleted &&
            t.routineTemplateId == shortcutTemplateId &&
            t.routineBlockId == shortcutBlockId &&
            t.userId != uid)
        .toList();
    for (final t in wrongUserCanonical) {
      final updated = t.copyWith(userId: uid);
      await RoutineMutationFacade.instance.updateTask(updated);
    }
  }
}

