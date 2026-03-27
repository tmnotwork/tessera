import 'package:flutter/widgets.dart';
import '../models/routine_template_v2.dart';
import '../models/project.dart';

class RoutineSelectedNotification extends Notification {
  final RoutineTemplateV2 routine;
  RoutineSelectedNotification(this.routine);
}

class ProjectSelectedNotification extends Notification {
  final Project project;
  ProjectSelectedNotification(this.project);
}

class ProjectUpdatedNotification extends Notification {
  final Project project;
  ProjectUpdatedNotification(this.project);
}

/// タイムラインで指定ブロックを展開するよう依頼（例: 今の時間帯に追加したブロック）
class TimelineExpandBlockRequestNotification extends Notification {
  final String blockId;
  final DateTime date;
  TimelineExpandBlockRequestNotification({
    required this.blockId,
    required this.date,
  });
}
