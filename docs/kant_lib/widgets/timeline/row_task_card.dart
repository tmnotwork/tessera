import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../models/block.dart' as block;
import '../../models/actual_task.dart' as actual;
import '../../models/inbox_task.dart' as inbox;
import '../../providers/task_provider.dart';
import '../project_input_field.dart';
import '../sub_project_input_field.dart';
import '../mode_input_field.dart';
import '../../services/project_service.dart';
import '../../services/sub_project_service.dart';
import '../../services/mode_service.dart';
import '../../services/day_key_service.dart';
import '../../services/block_service.dart';
import '../inbox/inbox_memo_dialog.dart' show showInboxMemoEditorDialog, showMemoEditorDialog;
import 'inbox_link_input_field.dart';

class RowTaskCard extends StatefulWidget {
  final dynamic task;
  final TaskProvider taskProvider;
  final void Function(BuildContext)? onLongPress;
  final VoidCallback? onShowDetails;
  final VoidCallback? onStart;
  final VoidCallback? onRestart;
  final VoidCallback? onDelete;
  // display overrides (Phase 5: segment view)
  final DateTime? displayStartTime;
  final DateTime? displayEndTime;
  // ブロック行の折りたたみ制御（任意）
  final bool? collapsed;
  final VoidCallback? onToggleCollapse;
  // 列ごとの表示制御（0.0〜1.0で幅を割合管理）
  final double locationVisibility;
  final double modeVisibility;

  const RowTaskCard({
    super.key,
    required this.task,
    required this.taskProvider,
    this.onLongPress,
    this.onShowDetails,
    this.onStart,
    this.onRestart,
    this.onDelete,
    this.displayStartTime,
    this.displayEndTime,
    this.collapsed,
    this.onToggleCollapse,
    this.locationVisibility = 1,
    this.modeVisibility = 1,
  });

  @override
  State<RowTaskCard> createState() => _RowTaskCardState();
}

class _RowTaskCardState extends State<RowTaskCard>
    with SingleTickerProviderStateMixin {
  static const double _taskTitleMinWidth = 260;
  static const double _locationColumnWidth = 120;
  static const double _modeColumnWidth = 120;
  static const double _locationMinVisibleWidth = 72;
  static const double _modeMinVisibleWidth = 72;
  static const double _projectColumnMaxWidth = 200;
  static const double _subProjectColumnMaxWidth = 200;

  late final AnimationController _animationController;
  late Animation<double> _locationWidthAnim;
  late Animation<double> _modeWidthAnim;

  late final TextEditingController _titleController;
  late final TextEditingController _startController;
  late final TextEditingController _endController;
  late final TextEditingController _projectController;
  late final TextEditingController _subProjectController;
  late final TextEditingController _modeController;
  late final TextEditingController _locationController;

  // Safety: if the State is ever reused for another task (due to missing/changed Keys),
  // force-unfocus and refresh controllers to avoid "writing to the wrong task".
  late String _taskIdentity;

  // Preserve edits while focused
  final FocusNode _titleFocusNode = FocusNode();
  String _lastTitleValue = '';

  // 開始/終了時刻: Enter を押さなくても反映させる（フォーカスアウトで保存）
  final FocusNode _startFocusNode = FocusNode();
  final FocusNode _endFocusNode = FocusNode();
  String _lastStartValue = '';
  String _lastEndValue = '';

  /// コミット直後、widget.task が追いつくまでコントローラを上書きしないための pending 値
  String? _pendingTitle;
  String? _pendingProjectId;
  String? _pendingSubProjectId;
  String? _pendingSubProjectName;
  String? _pendingModeId;
  String? _pendingLocation;

  bool get _isActual => widget.task is actual.ActualTask;
  bool get _isRunning =>
      _isActual && (widget.task as actual.ActualTask).isRunning;
  bool get _isPaused =>
      _isActual && (widget.task as actual.ActualTask).isPaused;
  bool get _isCompleted =>
      _isActual && (widget.task as actual.ActualTask).isCompleted;

  String _identityOf(dynamic task) {
    if (task is actual.ActualTask) return 'actual:${task.id}';
    if (task is inbox.InboxTask) return 'inbox:${task.id}';
    if (task is block.Block) return 'block:${task.id}';
    return 'unknown:${task.runtimeType}:${task.hashCode}';
  }

  double _locationWidth = _locationColumnWidth;
  double _modeWidth = _modeColumnWidth;

  @override
  void initState() {
    super.initState();
    _taskIdentity = _identityOf(widget.task);
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _initAnimations();
    _titleController = TextEditingController(text: _title());
    _startController = TextEditingController(text: _startText());
    _endController = TextEditingController(text: _endText());
    _projectController = TextEditingController(text: _projectName());
    _subProjectController = TextEditingController(text: _subProjectName());
    _modeController = TextEditingController(text: _modeName() ?? '');
    _locationController = TextEditingController(text: _locationText());

    _lastTitleValue = _titleController.text;
    _lastStartValue = _startController.text;
    _lastEndValue = _endController.text;

    // 事実確認用: 初回表示時点のタイトル・プロジェクト
    if (kDebugMode) {
      debugPrint(
        'RowTaskCard init: $_taskIdentity title="${_title()}" project="${_projectName()}" subProject="${_subProjectName()}"',
      );
    }

    _titleFocusNode.addListener(() {
      if (!_titleFocusNode.hasFocus) {
        final v = _titleController.text;
        if (v != _lastTitleValue) {
          _updateTitle(v);
          _lastTitleValue = v;
        }
      } else {
        _lastTitleValue = _titleController.text;
      }
    });

    _startFocusNode.addListener(() {
      if (!_startFocusNode.hasFocus) {
        final v = _startController.text;
        if (v != _lastStartValue) {
          _updateStart(v);
          _lastStartValue = v;
        }
      } else {
        _lastStartValue = _startController.text;
      }
    });

    _endFocusNode.addListener(() {
      if (!_endFocusNode.hasFocus) {
        final v = _endController.text;
        if (v != _lastEndValue) {
          _updateEnd(v);
          _lastEndValue = v;
        }
      } else {
        _lastEndValue = _endController.text;
      }
    });

  }

  void _initAnimations() {
    _locationWidth = _locationColumnWidth * widget.locationVisibility.clamp(0, 1);
    _modeWidth = _modeColumnWidth * widget.modeVisibility.clamp(0, 1);
    _locationWidthAnim =
        Tween<double>(begin: _locationWidth, end: _locationWidth)
            .animate(_animationController);
    _modeWidthAnim = Tween<double>(begin: _modeWidth, end: _modeWidth)
        .animate(_animationController);
  }

  void _animateWidths() {
    final double targetLocationWidth =
        _locationColumnWidth * widget.locationVisibility.clamp(0, 1);
    final double targetModeWidth =
        _modeColumnWidth * widget.modeVisibility.clamp(0, 1);
    _locationWidthAnim = Tween<double>(
      begin: _locationWidth,
      end: targetLocationWidth,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    ));
    _modeWidthAnim = Tween<double>(
      begin: _modeWidth,
      end: targetModeWidth,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    ));
    _animationController.forward(from: 0).then((_) {
      _locationWidth = targetLocationWidth;
      _modeWidth = targetModeWidth;
    });
  }

  @override
  void didUpdateWidget(covariant RowTaskCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newIdentity = _identityOf(widget.task);
    if (newIdentity != _taskIdentity) {
      _taskIdentity = newIdentity;
      _pendingTitle = null;
      _pendingProjectId = null;
      _pendingSubProjectId = null;
      _pendingSubProjectName = null;
      _pendingModeId = null;
      _pendingLocation = null;
      // If we were editing, prevent "commit on blur" from applying to a new task.
      _titleFocusNode.unfocus();
      _startFocusNode.unfocus();
      _endFocusNode.unfocus();
      // Refresh displayed values immediately.
      final newTitle = _title();
      final newStart = _startText();
      final newEnd = _endText();
      _titleController.text = newTitle;
      _startController.text = newStart;
      _endController.text = newEnd;
      _lastTitleValue = newTitle;
      _lastStartValue = newStart;
      _lastEndValue = newEnd;
      _projectController.text = _projectName();
      _subProjectController.text = _subProjectName();
      _modeController.text = _modeName() ?? '';
      _locationController.text = _locationText();
    }

    if (oldWidget.locationVisibility != widget.locationVisibility ||
        oldWidget.modeVisibility != widget.modeVisibility) {
      _animateWidths();
    }
    // タイトル（ブロック名等）: pending 中は上書きしない
    final newTitle = _title();
    if (_pendingTitle != null) {
      if (newTitle == _pendingTitle) {
        _pendingTitle = null;
      } else if (!_titleFocusNode.hasFocus) {
        if (_titleController.text != _pendingTitle) _titleController.text = _pendingTitle!;
        _lastTitleValue = _pendingTitle!;
      }
    } else if (!_titleFocusNode.hasFocus && _titleController.text != newTitle) {
      _titleController.text = newTitle;
      _lastTitleValue = newTitle;
    }
    final newStart = _startText();
    if (!_startFocusNode.hasFocus && _startController.text != newStart) {
      _startController.text = newStart;
      _lastStartValue = newStart;
    }
    final newEnd = _endText();
    if (!_endFocusNode.hasFocus && _endController.text != newEnd) {
      _endController.text = newEnd;
      _lastEndValue = newEnd;
    }
    // プロジェクト: pending 中は widget.task が追いつくまで上書きしない
    final currentProjectId = (widget.task as dynamic).projectId as String?;
    if (_pendingProjectId != null) {
      if (currentProjectId == _pendingProjectId) {
        _pendingProjectId = null;
      } else {
        final display = ProjectService.getProjectById(_pendingProjectId!)?.name ?? '';
        if (_projectController.text != display) _projectController.text = display;
      }
    } else {
      final pn = _projectName();
      if (_projectController.text != pn) _projectController.text = pn;
    }
    // サブプロジェクト: pending 中は上書きしない
    final currentSubProjectId = (widget.task as dynamic).subProjectId as String?;
    if (_pendingSubProjectId != null) {
      if (currentSubProjectId == _pendingSubProjectId) {
        _pendingSubProjectId = null;
        _pendingSubProjectName = null;
      } else {
        final display = _pendingSubProjectName ?? '';
        if (_subProjectController.text != display) _subProjectController.text = display;
      }
    } else {
      final sn = _subProjectName();
      if (_subProjectController.text != sn) _subProjectController.text = sn;
    }
    if (kDebugMode && _isActual) {
      debugPrint(
        'RowTaskCard didUpdate: $_taskIdentity project="${_projectController.text}" subProject="${_subProjectController.text}"',
      );
    }
    // モード: pending 中は上書きしない
    final currentModeId = widget.task is actual.ActualTask
        ? (widget.task as actual.ActualTask).modeId
        : (widget.task is block.Block ? (widget.task as block.Block).modeId : null);
    if (_pendingModeId != null) {
      if (currentModeId == _pendingModeId) {
        _pendingModeId = null;
      } else {
        final display = ModeService.getModeById(_pendingModeId!)?.name ?? '';
        if (_modeController.text != display) _modeController.text = display;
      }
    } else {
      final mn = _modeName() ?? '';
      if (_modeController.text != mn) _modeController.text = mn;
    }
    // 場所: pending 中は上書きしない
    final currentLocation = widget.task is actual.ActualTask
        ? (widget.task as actual.ActualTask).location ?? ''
        : (widget.task is block.Block ? (widget.task as block.Block).location ?? '' : '');
    if (_pendingLocation != null) {
      if (currentLocation == _pendingLocation) {
        _pendingLocation = null;
      } else {
        if (_locationController.text != _pendingLocation!) _locationController.text = _pendingLocation!;
      }
    } else {
      final loc = _locationText();
      if (_locationController.text != loc) _locationController.text = loc;
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    _titleController.dispose();
    _startController.dispose();
    _endController.dispose();
    _projectController.dispose();
    _subProjectController.dispose();
    _modeController.dispose();
    _locationController.dispose();
    _titleFocusNode.dispose();
    _startFocusNode.dispose();
    _endFocusNode.dispose();
    super.dispose();
  }

  IconData _statusIcon() {
    if (_isActual) {
      if (_isPaused) return Icons.pause;
      if (_isCompleted) return Icons.check_circle;
      if (_isRunning) return Icons.stop_circle;
      return Icons.check_circle;
    }
    if (widget.task is inbox.InboxTask) {
      return Icons.play_circle; // インボックスタスクは再生ボタン
    }
    if (widget.task is block.Block &&
        (widget.task as block.Block).isEvent == true) {
      try {
        final b = widget.task as block.Block;
        // 正しい終了判定: 実際の予定日の開始→終了を算出
        final start = DateTime(b.executionDate.year, b.executionDate.month,
            b.executionDate.day, b.startHour, b.startMinute);
        final end = start.add(Duration(minutes: b.estimatedDuration));
        final ended = DateTime.now().isAfter(end);
        return ended ? Icons.check_circle : Icons.event;
      } catch (_) {
        return Icons.event;
      }
    }
    return Icons.play_circle;
  }

  Color? _statusColor(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_isActual) {
      // 実績は「やった/記録済み」なので抑えめ（残タスクの再生を最優先で目立たせる）
      if (_isRunning) return scheme.onSurfaceVariant.withOpacity(0.85);
      if (_isPaused) return scheme.onSurfaceVariant.withOpacity(0.70);
      if (_isCompleted) return scheme.onSurfaceVariant.withOpacity(0.60);
      return scheme.onSurfaceVariant.withOpacity(0.60);
    }
    if (widget.task is inbox.InboxTask) {
      final t = widget.task as inbox.InboxTask;
      if (!t.isCompleted) {
        // Unify hue family: use primary instead of hardcoded green.
        return scheme.primary;
      }
      return scheme.onSurfaceVariant.withOpacity(0.60); // 完了は落ち着いた色
    }
    if (widget.task is block.Block &&
        (widget.task as block.Block).isEvent == true) {
      try {
        final b = widget.task as block.Block;
        // 正しい終了判定: 実際の予定日の開始→終了を算出
        final start = DateTime(b.executionDate.year, b.executionDate.month,
            b.executionDate.day, b.startHour, b.startMinute);
        final end = start.add(Duration(minutes: b.estimatedDuration));
        final ended = DateTime.now().isAfter(end);
        return ended
            ? scheme.onSurfaceVariant.withOpacity(0.60)
            : scheme.tertiary.withOpacity(0.95);
      } catch (_) {
        return scheme.tertiary.withOpacity(0.95);
      }
    }
    return scheme.primary;
  }

  VoidCallback? _statusAction() {
    if (_isActual) {
      if (_isCompleted) return widget.onRestart;
      if (_isPaused) return widget.onRestart;
      if (_isRunning) return null;
      return null;
    }
    if (widget.task is inbox.InboxTask) {
      return widget.onStart; // インボックスタスクは開始可能
    }
    return widget.onStart;
  }

  String _title() {
    if (widget.task is actual.ActualTask) {
      return (widget.task as actual.ActualTask).title;
    }
    if (widget.task is inbox.InboxTask) {
      return (widget.task as inbox.InboxTask).title;
    }
    if (widget.task is block.Block) return (widget.task as block.Block).title;
    return '';
  }

  dynamic get _commentTarget {
    if (widget.task is actual.ActualTask ||
        widget.task is inbox.InboxTask ||
        widget.task is block.Block) {
      return widget.task;
    }
    return null;
  }

  String _projectName() {
    final pid = (widget.task as dynamic).projectId as String?;
    if (pid == null || pid.isEmpty) return '';
    final p = ProjectService.getProjectById(pid);
    return p?.name ?? '';
  }

  String _subProjectName() {
    if (widget.task is actual.ActualTask) {
      return (widget.task as actual.ActualTask).subProject ?? '';
    }
    final spid = (widget.task as dynamic).subProjectId as String?;
    if (spid == null || spid.isEmpty) return '';
    final sp = SubProjectService.getSubProjectById(spid);
    return sp?.name ?? '';
  }

  String? _modeName() {
    String? modeId;
    if (widget.task is actual.ActualTask) {
      modeId = (widget.task as actual.ActualTask).modeId;
    } else if (widget.task is block.Block) {
      modeId = (widget.task as block.Block).modeId;
    }
    if (modeId == null || modeId.isEmpty) return null;
    return ModeService.getModeById(modeId)?.name;
  }

  String _locationText() {
    if (widget.task is actual.ActualTask) {
      return (widget.task as actual.ActualTask).location ?? '';
    }
    if (widget.task is block.Block) {
      return (widget.task as block.Block).location ?? '';
    }
    return '';
  }

  void _updateLocation(String v) {
    final trimmed = v.trim();
    final newLocation = trimmed.isEmpty ? null : trimmed;
    _pendingLocation = newLocation ?? '';
    if (widget.task is actual.ActualTask) {
      final t = widget.task as actual.ActualTask;
      t.location = newLocation;
      widget.taskProvider.updateActualTask(t);
    } else if (widget.task is block.Block) {
      final b = widget.task as block.Block;
      final updated = b.copyWith(
        location: newLocation,
        lastModified: DateTime.now(),
        version: b.version + 1,
      );
      widget.taskProvider.updateBlock(updated);
    }
  }

  String _startText() {
    final override = widget.displayStartTime;
    if (override != null) {
      return '${override.hour.toString().padLeft(2, '0')}:${override.minute.toString().padLeft(2, '0')}';
    }
    if (widget.task is actual.ActualTask) {
      final t = widget.task as actual.ActualTask;
      return '${t.startTime.hour.toString().padLeft(2, '0')}:${t.startTime.minute.toString().padLeft(2, '0')}';
    }
    if (widget.task is inbox.InboxTask) {
      final t = widget.task as inbox.InboxTask;
      if (t.startHour != null && t.startMinute != null) {
        return '${t.startHour!.toString().padLeft(2, '0')}:${t.startMinute!.toString().padLeft(2, '0')}';
      }
      return '';
    }
    if (widget.task is block.Block) {
      final b = widget.task as block.Block;
      return '${b.startHour.toString().padLeft(2, '0')}:${b.startMinute.toString().padLeft(2, '0')}';
    }
    return '';
  }

  String _endText() {
    final override = widget.displayEndTime;
    if (override != null) {
      return '${override.hour.toString().padLeft(2, '0')}:${override.minute.toString().padLeft(2, '0')}';
    }
    if (widget.task is actual.ActualTask) {
      final t = widget.task as actual.ActualTask;
      final et =
          t.endTime ?? t.startTime.add(Duration(minutes: t.actualDuration));
      return '${et.hour.toString().padLeft(2, '0')}:${et.minute.toString().padLeft(2, '0')}';
    }
    if (widget.task is inbox.InboxTask) {
      final t = widget.task as inbox.InboxTask;
      if (t.startHour != null && t.startMinute != null) {
        final start = DateTime(0, 1, 1, t.startHour!, t.startMinute!);
        final end = start.add(Duration(minutes: t.estimatedDuration));
        return '${end.hour.toString().padLeft(2, '0')}:${end.minute.toString().padLeft(2, '0')}';
      }
      return '';
    }
    if (widget.task is block.Block) {
      final b = widget.task as block.Block;
      final end = DateTime(0, 1, 1, b.startHour, b.startMinute)
          .add(Duration(minutes: b.estimatedDuration));
      return '${end.hour.toString().padLeft(2, '0')}:${end.minute.toString().padLeft(2, '0')}';
    }
    return '';
  }

  String _workTimeText() {
    int minutes = 0;
    final ds = widget.displayStartTime;
    final de = widget.displayEndTime;
    if (ds != null && de != null) {
      minutes = de.difference(ds).inMinutes;
      if (minutes < 0) minutes = 0;
      return '${minutes}分';
    }
    if (widget.task is actual.ActualTask) {
      final t = widget.task as actual.ActualTask;
      final end =
          t.endTime ?? t.startTime.add(Duration(minutes: t.actualDuration));
      minutes = end.difference(t.startTime).inMinutes;
    } else if (widget.task is inbox.InboxTask) {
      minutes = (widget.task as inbox.InboxTask).estimatedDuration;
    } else if (widget.task is block.Block) {
      final b = widget.task as block.Block;
      minutes = b.estimatedDuration;
    }
    if (minutes < 0) minutes = 0;
    return '${minutes}分';
  }

  void _updateTitle(String v) {
    _pendingTitle = v;
    if (widget.task is actual.ActualTask) {
      final t = widget.task as actual.ActualTask;
      t.title = v;
      widget.taskProvider.updateActualTask(t);
    } else if (widget.task is inbox.InboxTask) {
      final t = widget.task as inbox.InboxTask;
      t.title = v;
    } else if (widget.task is block.Block) {
      final b = widget.task as block.Block;
      final updated = b.copyWith(
          title: v, lastModified: DateTime.now(), version: b.version + 1);
      widget.taskProvider.updateBlock(updated);
    }
  }

  // 柔軟な時刻パーサ（"HH:mm" / "H:mm" / "HHmm" / "Hmm" を許容）
  List<int>? _parseTimeFlexible(String v) {
    try {
      String s = v.trim();
      if (s.isEmpty) return null;
      // 全角コロン対応
      s = s.replaceAll('：', ':');

      // コロン区切り（H:mm / HH:mm）の場合
      if (s.contains(':')) {
        final parts = s.split(':');
        if (parts.length < 2) return null;
        final hh = int.tryParse(parts[0]) ?? -1;
        final mm = int.tryParse(parts[1]) ?? -1;
        if (hh < 0 || hh > 23 || mm < 0 || mm > 59) return null;
        return [hh, mm];
      }

      // 数字のみ（HHmm / Hmm）を許容
      final digits = s.replaceAll(RegExp(r'[^0-9]'), '');
      if (digits.isEmpty) return null;
      String four = digits;
      if (four.length == 3) {
        // 例: 930 -> 0930
        four = '0$four';
      }
      if (four.length != 4) return null;
      final hh = int.tryParse(four.substring(0, 2)) ?? -1;
      final mm = int.tryParse(four.substring(2, 4)) ?? -1;
      if (hh < 0 || hh > 23 || mm < 0 || mm > 59) return null;
      return [hh, mm];
    } catch (_) {
      return null;
    }
  }

  void _updateStart(String v) {
    // Phase 5: segment view is display-only for time editing (actual は Phase 5b で別導線)
    if ((widget.displayStartTime != null || widget.displayEndTime != null) &&
        widget.task is! actual.ActualTask) {
      return;
    }
    final parsed = _parseTimeFlexible(v);
    if (parsed == null) return;
    final hh = parsed[0];
    final mm = parsed[1];
    if (widget.task is actual.ActualTask) {
      final t = widget.task as actual.ActualTask;
      final newStart = DateTime(t.startTime.year, t.startTime.month, t.startTime.day, hh, mm);
      final newEnd = t.endTime;
      final updated = t.copyWith(
        startTime: newStart,
        endTime: newEnd,
        startAt: newStart.toUtc(),
        endAtExclusive: newEnd?.toUtc(),
        dayKeys: null,
        monthKeys: null,
        lastModified: DateTime.now(),
        version: t.version + 1,
      );
      widget.taskProvider.updateActualTask(updated);
    } else if (widget.task is inbox.InboxTask) {
      final t = widget.task as inbox.InboxTask;
      // Inbox は開始時刻を startHour/startMinute として保持
      final updated = t.copyWith(
        startHour: hh,
        startMinute: mm,
        lastModified: DateTime.now(),
        version: t.version + 1,
      );
      widget.taskProvider.updateInboxTask(updated);
    } else if (widget.task is block.Block) {
      final b = widget.task as block.Block;
      final updatedLegacy = b.copyWith(
        startHour: hh,
        startMinute: mm,
        lastModified: DateTime.now(),
        version: b.version + 1,
      );
      // Prefer canonical range date if present (accountTimeZoneId wall-clock).
      final base = b.startAt != null
          ? DayKeyService.toAccountWallClockFromUtc(b.startAt!)
          : DateTime(b.executionDate.year, b.executionDate.month, b.executionDate.day);
      // IMPORTANT: pass "wall-clock components" (account TZ) into recomputeCanonicalRange.
      final startLocal = DateTime(base.year, base.month, base.day, hh, mm);
      final endLocalExclusive =
          startLocal.add(Duration(minutes: updatedLegacy.estimatedDuration));
      final updated = updatedLegacy.recomputeCanonicalRange(
        startLocalOverride: startLocal,
        endLocalExclusiveOverride: endLocalExclusive,
        allDayOverride: false,
      );
      widget.taskProvider.updateBlock(updated);
    }
  }

  void _updateEnd(String v) {
    // Phase 5: segment view is display-only for time editing (actual は Phase 5b で別導線)
    if ((widget.displayStartTime != null || widget.displayEndTime != null) &&
        widget.task is! actual.ActualTask) {
      return;
    }
    final parsed = _parseTimeFlexible(v);
    if (parsed == null) return;
    final hh = parsed[0];
    final mm = parsed[1];
    if (widget.task is actual.ActualTask) {
      final t = widget.task as actual.ActualTask;
      final base = t.startTime;
      var newEnd = DateTime(base.year, base.month, base.day, hh, mm);
      // 0:20 等、開始より前になる場合は翌日に繰り上げる（24時またぎ対応）
      if (!newEnd.isAfter(base)) {
        newEnd = newEnd.add(const Duration(days: 1));
      }
      final updated = t.copyWith(
        endTime: newEnd,
        startAt: t.startTime.toUtc(),
        endAtExclusive: newEnd.toUtc(),
        dayKeys: null,
        monthKeys: null,
        lastModified: DateTime.now(),
        version: t.version + 1,
      );
      widget.taskProvider.updateActualTask(updated);
    } else if (widget.task is inbox.InboxTask) {
      final t = widget.task as inbox.InboxTask;
      if (t.startHour == null || t.startMinute == null) return;
      final start = DateTime(0, 1, 1, t.startHour!, t.startMinute!);
      final end = DateTime(0, 1, 1, hh, mm);
      final newDur = end.difference(start).inMinutes;
      if (newDur > 0) {
        final updated = t.copyWith(
          estimatedDuration: newDur,
          lastModified: DateTime.now(),
          version: t.version + 1,
        );
        widget.taskProvider.updateInboxTask(updated);
      }
    } else if (widget.task is block.Block) {
      final b = widget.task as block.Block;
      final start = DateTime(0, 1, 1, b.startHour, b.startMinute);
      final end = DateTime(0, 1, 1, hh, mm);
      final newDur = end.difference(start).inMinutes;
      if (newDur > 0) {
        final updatedLegacy = b.copyWith(
          estimatedDuration: newDur,
          lastModified: DateTime.now(),
          version: b.version + 1,
        );
        final base = b.startAt != null
            ? DayKeyService.toAccountWallClockFromUtc(b.startAt!)
            : DateTime(b.executionDate.year, b.executionDate.month, b.executionDate.day);
        final startLocal = DateTime(
          base.year,
          base.month,
          base.day,
          b.startHour,
          b.startMinute,
        );
        final endLocalExclusive =
            startLocal.add(Duration(minutes: updatedLegacy.estimatedDuration));
        final updated = updatedLegacy.recomputeCanonicalRange(
          startLocalOverride: startLocal,
          endLocalExclusiveOverride: endLocalExclusive,
          allDayOverride: false,
        );
        widget.taskProvider.updateBlock(updated);

        // 次のブロックの開始時刻を、変更した終了時刻に合わせる
        final sameDayBlocks = BlockService.getBlocksForDate(b.executionDate)
          ..sort((a, c) =>
              (a.startHour * 60 + a.startMinute)
                  .compareTo(c.startHour * 60 + c.startMinute));
        final idx = sameDayBlocks.indexWhere((x) => x.id == b.id);
        if (idx >= 0 && idx + 1 < sameDayBlocks.length) {
          final nextBlk = sameDayBlocks[idx + 1];
          final nextBase = nextBlk.startAt != null
              ? DayKeyService.toAccountWallClockFromUtc(nextBlk.startAt!)
              : DateTime(nextBlk.executionDate.year, nextBlk.executionDate.month,
                  nextBlk.executionDate.day);
          final nextStartLocal = DateTime(
            nextBase.year,
            nextBase.month,
            nextBase.day,
            hh,
            mm,
          );
          final nextEndLocalExclusive =
              nextStartLocal.add(Duration(minutes: nextBlk.estimatedDuration));
          final nextUpdated = nextBlk.copyWith(
            startHour: hh,
            startMinute: mm,
            lastModified: DateTime.now(),
            version: nextBlk.version + 1,
          ).recomputeCanonicalRange(
            startLocalOverride: nextStartLocal,
            endLocalExclusiveOverride: nextEndLocalExclusive,
            allDayOverride: false,
          );
          widget.taskProvider.updateBlock(nextUpdated);
        }
      }
    }
  }

  Future<void> _clearActualEnd() async {
    if (widget.task is! actual.ActualTask) return;
    final t = widget.task as actual.ActualTask;
    final updated = t.copyWith(
      endTime: null,
      startAt: t.startTime.toUtc(),
      endAtExclusive: null,
      dayKeys: null,
      monthKeys: null,
      lastModified: DateTime.now(),
      version: t.version + 1,
    );
    widget.taskProvider.updateActualTask(updated);
  }

  void _updateProject(String? projectId) {
    _pendingProjectId = projectId;
    if (widget.task is actual.ActualTask) {
      widget.task.projectId = projectId;
      // プロジェクト変更時はサブプロジェクトをクリア
      widget.task.subProjectId = null;
      widget.task.subProject = null;
      widget.taskProvider.updateActualTask(widget.task);
    } else if (widget.task is inbox.InboxTask) {
      widget.task.projectId = projectId;
      // プロジェクト変更時はサブプロジェクトをクリア
      widget.task.subProjectId = null;
      widget.taskProvider.updateInboxTask(widget.task);
    } else if (widget.task is block.Block) {
      final b = widget.task as block.Block;
      final updated = b.copyWith(
          projectId: projectId,
          subProjectId: null,
          subProject: null,
          lastModified: DateTime.now(),
          version: b.version + 1);
      widget.taskProvider.updateBlock(updated);
    }
  }

  void _updateSubProject(String? subProjectId, String? subProjectName) {
    _pendingSubProjectId = subProjectId;
    _pendingSubProjectName = subProjectName ?? '';
    if (widget.task is actual.ActualTask) {
      final t = widget.task as actual.ActualTask;
      t.subProjectId = subProjectId;
      t.subProject = subProjectName;
      widget.taskProvider.updateActualTask(t);
    } else if (widget.task is inbox.InboxTask) {
      final t = widget.task as inbox.InboxTask;
      t.subProjectId = subProjectId;
      widget.taskProvider.updateInboxTask(t);
    } else if (widget.task is block.Block) {
      final b = widget.task as block.Block;
      final updated = b.copyWith(
        subProjectId: subProjectId,
        subProject: subProjectName,
        lastModified: DateTime.now(),
        version: b.version + 1,
      );
      widget.taskProvider.updateBlock(updated);
    }
  }

  void _updateMode(String? modeId) {
    _pendingModeId = modeId;
    if (widget.task is actual.ActualTask) {
      final t = widget.task as actual.ActualTask;
      t.modeId = modeId;
      widget.taskProvider.updateActualTask(t);
      _modeController.text = ModeService.getModeById(modeId ?? '')?.name ?? '';
    } else if (widget.task is block.Block) {
      final b = widget.task as block.Block;
      final updated = b.copyWith(
        modeId: modeId,
        lastModified: DateTime.now(),
        version: b.version + 1,
      );
      widget.taskProvider.updateBlock(updated);
      _modeController.text = ModeService.getModeById(modeId ?? '')?.name ?? '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final isBlock = widget.task is block.Block;
    final showCollapsed = isBlock && (widget.collapsed == true);
    final scheme = Theme.of(context).colorScheme;
    // 入力欄と行背景を必ず同一色にする（タイムラインの色バグ防止）
    final rowBackgroundColor = scheme.surface;
    final neutralIconColor = Theme.of(context).textTheme.bodyMedium?.color ??
        scheme.onSurfaceVariant;
    return InkWell(
      // 背景タップで詳細ダイアログを開かない
      onTap: null,
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: rowBackgroundColor,
          border:
              Border(bottom: BorderSide(color: Theme.of(context).dividerColor)),
        ),
        child: Row(
          children: [
            // 再生/状態ボタン（最左）
            IconButton(
              icon: Icon(_statusIcon(), color: _statusColor(context)),
              iconSize: 20,
              onPressed: _statusAction(),
              tooltip: () {
                if (_isActual) {
                  if (_isRunning) return '実行中';
                  if (_isPaused) return '再開';
                  return '完了';
                }
                if (widget.task is block.Block &&
                    (widget.task as block.Block).isEvent == true) {
                  return 'イベント';
                }
                return '開始';
              }(),
            ),
            if (isBlock && widget.onToggleCollapse != null)
              IconButton(
                icon: Icon(
                    showCollapsed
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_up,
                    size: 18),
                tooltip: showCollapsed ? '展開' : '折りたたむ',
                onPressed: widget.onToggleCollapse,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 24),
              ),
            const SizedBox(width: 8),
            // 時間（開始 - 終了）
            SizedBox(
              width: 136,
              child: Row(
                children: [
                  SizedBox(
                    width: 62,
                    child: TextField(
                      controller: _startController,
                      focusNode: _startFocusNode,
                      textAlign: TextAlign.center,
                      // タイムライン上の開始/終了は「キーボード入力」を基本とする（タップでダイアログを出さない）
                      // セグメント表示中のみ readOnly（=派生表示のため編集不可）
                      readOnly: widget.displayStartTime != null ||
                          widget.displayEndTime != null,
                      decoration: InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(4),
                          borderSide:
                              BorderSide(color: Theme.of(context).dividerColor),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(4),
                          borderSide:
                              BorderSide(color: Theme.of(context).dividerColor),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(4),
                          borderSide: BorderSide(
                              color: Theme.of(context).colorScheme.primary,
                              width: 1.5),
                        ),
                        hintText: '開始',
                        isCollapsed: true,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 6.0, vertical: 16.0),
                        filled: true,
                        fillColor: rowBackgroundColor,
                        constraints:
                            const BoxConstraints(minHeight: 36, maxHeight: 36),
                      ),
                      style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).textTheme.bodySmall?.color,
                          height: 1.0),
                      onSubmitted: (v) => _updateStart(v),
                      onEditingComplete: () => _updateStart(_startController.text),
                    ),
                  ),
                  const Text(' - '),
                  SizedBox(
                    width: 62,
                    child: GestureDetector(
                      onLongPress: _isActual ? _clearActualEnd : null,
                      child: TextField(
                        controller: _endController,
                        focusNode: _endFocusNode,
                        textAlign: TextAlign.center,
                        // タイムライン上の開始/終了は「キーボード入力」を基本とする（タップでダイアログを出さない）
                        // セグメント表示中のみ readOnly（=派生表示のため編集不可）
                        readOnly: widget.displayStartTime != null ||
                            widget.displayEndTime != null,
                        decoration: InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(4),
                          borderSide:
                              BorderSide(color: Theme.of(context).dividerColor),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(4),
                          borderSide:
                              BorderSide(color: Theme.of(context).dividerColor),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(4),
                          borderSide: BorderSide(
                              color: Theme.of(context).colorScheme.primary,
                              width: 1.5),
                        ),
                        hintText: '終了',
                        isCollapsed: true,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 6.0, vertical: 16.0),
                        filled: true,
                        fillColor: rowBackgroundColor,
                        constraints:
                            const BoxConstraints(minHeight: 36, maxHeight: 36),
                      ),
                      style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).textTheme.bodySmall?.color,
                          height: 1.0),
                        onSubmitted: (v) => _updateEnd(v),
                        onEditingComplete: () => _updateEnd(_endController.text),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            // 作業時間
            SizedBox(
              width: 60,
              child: Container(
                constraints: const BoxConstraints(minHeight: 36, maxHeight: 36),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).dividerColor),
                  borderRadius: BorderRadius.circular(4),
                  color: rowBackgroundColor,
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 6.0, vertical: 6.0),
                child: Text(
                  _workTimeText(),
                  style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).textTheme.bodySmall?.color),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              flex: 3,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final double availableWidth = constraints.maxWidth.isFinite
                      ? constraints.maxWidth
                      : _taskTitleMinWidth;
                  final double desiredWidth = availableWidth < _taskTitleMinWidth
                      ? _taskTitleMinWidth
                      : availableWidth;
                  final double targetWidth =
                      constraints.constrainWidth(desiredWidth);
                  Widget titleField;
                  if (widget.task is block.Block) {
                    final blk = widget.task as block.Block;
                    titleField = InboxLinkInputField(
                      controller: _titleController,
                      blockId: blk.id,
                      executionDate: blk.executionDate,
                      projectId: blk.projectId,
                      subProjectId: blk.subProjectId,
                      hintText: 'タスク名',
                      fillColor: rowBackgroundColor,
                      onSubmitText: (v) => _updateTitle(v),
                      onLink: (List<inbox.InboxTask> list) async {
                        for (final selected in list) {
                          await widget.taskProvider
                              .assignInboxToBlockWithScheduling(
                                  selected.id, blk.id);
                        }
                        if (mounted && list.isNotEmpty) {
                          setState(() {
                            _titleController.text = list.length == 1
                                ? list.first.title
                                : '${list.length}件をリンク';
                          });
                        }
                      },
                    );
                  } else {
                    titleField = TextField(
                      controller: _titleController,
                      focusNode: _titleFocusNode,
                      decoration: InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(4),
                          borderSide: BorderSide(
                              color: Theme.of(context).dividerColor),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(4),
                          borderSide: BorderSide(
                              color: Theme.of(context).dividerColor),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(4),
                          borderSide: BorderSide(
                              color: Theme.of(context).colorScheme.primary,
                              width: 1.5),
                        ),
                        hintText: 'タスク名',
                        isCollapsed: true,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10.0, vertical: 16.0),
                        filled: true,
                        fillColor: rowBackgroundColor,
                        constraints:
                            const BoxConstraints(minHeight: 36, maxHeight: 36),
                      ),
                      style: const TextStyle(fontSize: 12, height: 1.0),
                      onSubmitted: (v) => _updateTitle(v),
                    );
                  }
                  return Align(
                    alignment: Alignment.centerLeft,
                    child: SizedBox(
                      width: targetWidth,
                      child: titleField,
                    ),
                  );
                },
              ),
            ),
            const SizedBox(width: 8),
            // コメントボタン（タスク名の右側）
            if (_commentTarget != null)
              IconButton(
                icon: Icon(
                  Icons.comment_outlined,
                  size: 20,
                  // 強調は不要。通常テキストと同じ色に寄せる。
                  color: Theme.of(context).textTheme.bodyMedium?.color,
                ),
                tooltip: 'コメントを編集',
                onPressed: () => _openCommentEditor(context),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 24),
              ),
            const SizedBox(width: 8),
            Flexible(
              flex: 2,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final double targetWidth = constraints.maxWidth.isFinite
                      ? constraints.maxWidth
                      : _projectColumnMaxWidth;
                  return SizedBox(
                    width: constraints.constrainWidth(targetWidth),
                    child: ProjectInputField(
                      controller: _projectController,
                      hintText: 'プロジェクト',
                      onProjectChanged: (pid) {
                        _updateProject(pid);
                      },
                      onAutoSave: () {},
                      withBackground: true,
                      fillColor: rowBackgroundColor,
                    ),
                  );
                },
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              flex: 2,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final double targetWidth = constraints.maxWidth.isFinite
                      ? constraints.maxWidth
                      : _subProjectColumnMaxWidth;
                  return SizedBox(
                    width: constraints.constrainWidth(targetWidth),
                    child: SubProjectInputField(
                      controller: _subProjectController,
                      hintText: 'サブプロジェクト',
                      projectId: (widget.task as dynamic).projectId as String?,
                      currentSubProjectId:
                          (widget.task as dynamic).subProjectId as String?,
                      onSubProjectChanged: (spid, spname) {
                        _updateSubProject(spid, spname);
                      },
                      fillColor: rowBackgroundColor,
                      onAutoSave: () {},
                      withBackground: true,
                    ),
                  );
                },
              ),
            ),
            AnimatedBuilder(
              animation: _modeWidthAnim,
              builder: (context, child) {
                final double width = _modeWidthAnim.value;
                final bool visible = width >= _modeMinVisibleWidth &&
                    widget.modeVisibility > 0;
                final double renderWidth = visible ? width : 0;
                if (visible) {
                  return Row(
                    children: [
                      const SizedBox(width: 8),
                      SizedBox(
                        width: renderWidth,
                        child: Opacity(
                          opacity: widget.modeVisibility.clamp(0, 1),
                          child: child!,
                        ),
                      ),
                    ],
                  );
                }
                return const SizedBox.shrink();
              },
              child: IgnorePointer(
                ignoring: widget.modeVisibility == 0,
                child: ModeInputField(
                  controller: _modeController,
                  hintText: 'モード',
                  onModeChanged: (modeId) => _updateMode(modeId),
                  onAutoSave: () {},
                  fillColor: rowBackgroundColor,
                ),
              ),
            ),
            AnimatedBuilder(
              animation: _locationWidthAnim,
              builder: (context, child) {
                final double width = _locationWidthAnim.value;
                final bool visible =
                    width >= _locationMinVisibleWidth &&
                        widget.locationVisibility > 0;
                final double renderWidth = visible ? width : 0;
                if (visible) {
                  return Row(
                    children: [
                      const SizedBox(width: 8),
                      SizedBox(
                        width: renderWidth,
                        child: Opacity(
                          opacity: widget.locationVisibility.clamp(0, 1),
                          child: child!,
                        ),
                      ),
                    ],
                  );
                }
                return const SizedBox.shrink();
              },
              child: IgnorePointer(
                ignoring: widget.locationVisibility == 0,
                child: TextField(
                  controller: _locationController,
                  decoration: InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(4),
                      borderSide:
                          BorderSide(color: Theme.of(context).dividerColor),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(4),
                      borderSide:
                          BorderSide(color: Theme.of(context).dividerColor),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(4),
                      borderSide: BorderSide(
                          color: Theme.of(context).colorScheme.primary,
                          width: 1.5),
                    ),
                    hintText: '場所',
                    isCollapsed: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10.0, vertical: 16.0),
                    filled: true,
                    fillColor: rowBackgroundColor,
                    constraints:
                        const BoxConstraints(minHeight: 36, maxHeight: 36),
                  ),
                  style: const TextStyle(fontSize: 12, height: 1.0),
                  onSubmitted: (v) => _updateLocation(v),
                  onEditingComplete: () =>
                      _updateLocation(_locationController.text),
                ),
              ),
            ),
            const SizedBox(width: 8),
              // PC版: メニュー操作ボタン
              Builder(
                builder: (menuContext) => IconButton(
                  icon: const Icon(Icons.more_vert, size: 20),
                  tooltip: 'メニュー',
                  onPressed: widget.onLongPress != null
                      ? () => widget.onLongPress!(menuContext)
                      : null,
                  color: neutralIconColor,
                  disabledColor: neutralIconColor.withOpacity(0.5),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 24),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _openCommentEditor(BuildContext context) async {
    final target = _commentTarget;
    if (target == null) return;
    if (target is inbox.InboxTask) {
      await showInboxMemoEditorDialog(context, target);
      if (mounted) setState(() {});
      return;
    }
    if (target is actual.ActualTask) {
      await showMemoEditorDialog(
        context: context,
        initialValue: target.memo,
        onSave: (value) async {
          target.memo = value;
          await widget.taskProvider.updateActualTask(target);
        },
      );
      if (mounted) setState(() {});
      return;
    }
    if (target is block.Block) {
      await showMemoEditorDialog(
        context: context,
        initialValue: target.memo,
        onSave: (value) async {
          final updated = target.copyWith(
            memo: value,
            lastModified: DateTime.now(),
            version: target.version + 1,
          );
          await widget.taskProvider.updateBlock(updated);
        },
      );
      if (mounted) setState(() {});
    }
  }
}
