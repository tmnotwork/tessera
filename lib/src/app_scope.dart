import 'package:flutter/material.dart';

/// 教材管理画面へ遷移するコールバックを保持。
/// main の RootScaffold が build 時に set し、QuestionSolveScreen の編集ボタン等が呼び出す。
final openManageNotifier = _OpenManageNotifier();

class _OpenManageNotifier {
  void Function(BuildContext context)? openManage;
}
