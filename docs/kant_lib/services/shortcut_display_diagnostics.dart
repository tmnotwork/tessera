import '../models/routine_task_v2.dart';
import 'auth_service.dart';
import 'routine_block_v2_service.dart';
import 'routine_task_v2_service.dart';
import 'routine_template_v2_service.dart';

/// ショートカットが「FABでは見える／編集では見えない」等のとき、原因を切り分けるための診断。
///
/// [RoutineTaskV2Service.getByBlock] は **現在ユーザーの userId でフィルタ**するため、
/// 生データ上は存在しても表示件数 0 になり得る点を集計する。
class ShortcutDisplayDiagnostics {
  ShortcutDisplayDiagnostics._();

  static const String canonicalTemplateId = 'shortcut';
  static const String canonicalBlockId = 'v2blk_shortcut_0';

  /// 人間が読めるレポート文字列（開発者メニュー表示用）
  static Future<String> buildReport() async {
    await RoutineTaskV2Service.ensureOpen();
    await RoutineBlockV2Service.ensureOpen();
    await RoutineTemplateV2Service.ensureOpen();

    final uid = AuthService.getCurrentUserId();
    final uidEmpty = uid == null || uid.isEmpty;
    final uidLabel = uidEmpty ? '(null/empty)' : uid;

    final buf = StringBuffer()
      ..writeln('=== ショートカット表示診断 ===')
      ..writeln('時刻(ローカル): ${DateTime.now().toIso8601String()}')
      ..writeln('AuthService.getCurrentUserId(): $uidLabel')
      ..writeln();

    if (uidEmpty) {
      buf
        ..writeln('【結論候補】userId が取得できないため、getByBlock/getByTemplate は常に 0 件です。')
        ..writeln('（未ログイン・認証初期化前に該当画面だけ開いている等）')
        ..writeln();
    }

    // --- テンプレ shortcut ---
    final tplVisible = RoutineTemplateV2Service.getById(canonicalTemplateId);
    final tplRaw = RoutineTemplateV2Service.debugGetAllRaw()
        .where((t) => t.id == canonicalTemplateId || t.cloudId == canonicalTemplateId)
        .toList();
    buf
      ..writeln('--- テンプレ ($canonicalTemplateId) ---')
      ..writeln(
        'getById(表示用・uid一致): ${tplVisible == null ? "なし" : "あり (isShortcut=${tplVisible.isShortcut}, isDeleted=${tplVisible.isDeleted}, userId=${tplVisible.userId})"}',
      )
      ..writeln('debugGetAllRaw 該当件数: ${tplRaw.length}');
    if (tplRaw.isNotEmpty) {
      for (final t in tplRaw) {
        buf.writeln(
          '  raw id=${t.id} cloudId=${t.cloudId} isShortcut=${t.isShortcut} isDeleted=${t.isDeleted} userId=${t.userId}',
        );
      }
    }
    buf.writeln();

    // --- ブロック v2blk_shortcut_0 ---
    final blkVisible = RoutineBlockV2Service.getById(canonicalBlockId);
    final blkRaw = RoutineBlockV2Service.debugGetAllRaw()
        .where((b) => b.id == canonicalBlockId)
        .toList();
    buf
      ..writeln('--- ブロック ($canonicalBlockId) ---')
      ..writeln(
        'getById(表示用・uid一致): ${blkVisible == null ? "なし" : "あり (routineTemplateId=${blkVisible.routineTemplateId}, isDeleted=${blkVisible.isDeleted}, userId=${blkVisible.userId})"}',
      )
      ..writeln('debugGetAllRaw 該当件数: ${blkRaw.length}');
    if (blkRaw.isNotEmpty) {
      for (final b in blkRaw) {
        buf.writeln(
          '  raw routineTemplateId=${b.routineTemplateId} isDeleted=${b.isDeleted} userId=${b.userId}',
        );
      }
    }
    buf.writeln();

    // --- FAB / 編集と同一クエリ ---
    final fabSameAsEditor = _fabOrEditorVisibleTasks();
    buf
      ..writeln('--- FAB・編集画面と同条件（getByBlock + template + !deleted）---')
      ..writeln('件数: ${fabSameAsEditor.length}')
      ..writeln(_sampleIds(fabSameAsEditor))
      ..writeln();

    // --- 生タスクの切り分け ---
    final allRaw = RoutineTaskV2Service.debugGetAllRaw();
    final related = allRaw.where(_isShortcutRelatedTask).toList();
    buf
      ..writeln('--- routine_tasks_v2 生データ（ショートカット関連候補）---')
      ..writeln('全タスク件数: ${allRaw.length}')
      ..writeln('関連候補件数: ${related.length}');

    if (!uidEmpty) {
      final canonicalOk = related
          .where(
            (t) =>
                !t.isDeleted &&
                t.routineBlockId == canonicalBlockId &&
                t.routineTemplateId == canonicalTemplateId &&
                t.userId == uid,
          )
          .length;
      final canonicalWrongUser = related
          .where(
            (t) =>
                !t.isDeleted &&
                t.routineBlockId == canonicalBlockId &&
                t.routineTemplateId == canonicalTemplateId &&
                t.userId != uid,
          )
          .length;
      final wrongTemplateSameBlock = related
          .where(
            (t) =>
                !t.isDeleted &&
                t.routineBlockId == canonicalBlockId &&
                t.routineTemplateId != canonicalTemplateId,
          )
          .length;
      final wrongBlockSameTemplate = related
          .where(
            (t) =>
                !t.isDeleted &&
                t.routineBlockId != canonicalBlockId &&
                t.routineTemplateId == canonicalTemplateId,
          )
          .length;
      final deletedCanonical = related
          .where(
            (t) =>
                t.isDeleted &&
                t.routineBlockId == canonicalBlockId &&
                t.routineTemplateId == canonicalTemplateId,
          )
          .length;

      buf
        ..writeln('  正規+未削除+uid一致: $canonicalOk')
        ..writeln('  正規+未削除+uid不一致: $canonicalWrongUser')
        ..writeln('  正規ブロックだがtemplate不一致(未削除): $wrongTemplateSameBlock')
        ..writeln('  正規templateだがblock不一致(未削除): $wrongBlockSameTemplate')
        ..writeln('  正規だがisDeleted: $deletedCanonical');
    }

    if (related.isNotEmpty) {
      buf.writeln('  先頭最大8件:');
      for (final t in related.take(8)) {
        buf.writeln(
          '    id=${t.id} block=${t.routineBlockId} tpl=${t.routineTemplateId} del=${t.isDeleted} uid=${t.userId}',
        );
      }
    }
    buf.writeln();

    // --- 結論（機械的な候補）---
    buf.writeln('--- 推定（上記数値からの候補）---');
    if (uidEmpty) {
      buf.writeln('1) userId 未取得 → 表示クエリは常に0件。');
    } else if (fabSameAsEditor.isNotEmpty) {
      buf.writeln(
        '1) データ上は FAB・編集と同条件で ${fabSameAsEditor.length} 件ある → 「空」ならUI/ビルド/別ルート表示の疑い。',
      );
    } else {
      final wrongUser = related
          .where(
            (t) =>
                !t.isDeleted &&
                t.routineBlockId == canonicalBlockId &&
                t.routineTemplateId == canonicalTemplateId &&
                t.userId != uid,
          )
          .length;
      if (wrongUser > 0) {
        buf.writeln(
          '1) 正規IDのタスクはあるが userId が現在ユーザーと不一致 ($wrongUser 件) → 開発者メニュー「ショートカットタスク userId 強制修正」等。',
        );
      }
      final wt = related
          .where(
            (t) =>
                !t.isDeleted &&
                t.routineBlockId == canonicalBlockId &&
                t.routineTemplateId != canonicalTemplateId,
          )
          .length;
      if (wt > 0) {
        buf.writeln(
          '2) 正規ブロック上で routineTemplateId が shortcut 以外 ($wt 件) → 「ショートカットID整合」や永続化層の正規化経路を確認。',
        );
      }
      if (related.isEmpty ||
          related.every(
            (t) =>
                t.isDeleted ||
                t.routineBlockId != canonicalBlockId ||
                t.routineTemplateId != canonicalTemplateId,
          )) {
        buf.writeln(
          '3) ローカルに正規ショートカットタスクが無い、または全て削除済み → 同期未実行・別アカウント・クラウド未配置。',
        );
      }
    }

    return buf.toString();
  }

  static bool _isShortcutRelatedTask(RoutineTaskV2 t) {
    if (t.routineBlockId == canonicalBlockId) return true;
    if (t.routineTemplateId == canonicalTemplateId) return true;
    if (t.routineTemplateId.startsWith('shortcut')) return true;
    return false;
  }

  static List<RoutineTaskV2> _fabOrEditorVisibleTasks() {
    return RoutineTaskV2Service.getByBlock(canonicalBlockId)
        .where(
          (t) => t.routineTemplateId == canonicalTemplateId && !t.isDeleted,
        )
        .toList()
      ..sort((a, b) => a.order.compareTo(b.order));
  }

  static String _sampleIds(List<RoutineTaskV2> list) {
    if (list.isEmpty) return 'idサンプル: (なし)';
    final ids = list.take(5).map((e) => e.id).join(', ');
    return 'idサンプル(最大5): $ids';
  }
}
