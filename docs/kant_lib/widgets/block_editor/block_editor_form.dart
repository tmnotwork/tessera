import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../widgets/mode_input_field.dart';
import '../../widgets/project_input_field.dart';
import '../../widgets/sub_project_input_field.dart';
import '../timeline/timeline_helpers.dart';

/// 予定ブロックの作成/編集で共通利用する入力結果。
///
/// NOTE:
/// - edit 時に title を維持したい場合は、呼び出し元で result.title を無視して既存値を使う。
class BlockEditorResult {
  final DateTime startDate; // date-only (local)
  final TimeOfDay startTime;
  final DateTime endDate; // date-only (local)
  final TimeOfDay endTime;
  /// 終日フラグ（Googleカレンダー同様）
  ///
  /// - true: 開始日〜終了日（含む）の“日付レンジ”として扱う（時刻入力は無視）
  /// - false: 従来どおり開始/終了の時刻を含むレンジとして扱う
  final bool allDay;
  final int estimatedMinutes;
  final int workingMinutes;
  final int breakMinutes;
  final String title;
  final String? blockName;
  final String? projectId;
  final String? subProjectId;
  final String? subProjectName;
  final String? modeId;
  final String? memo;
  final String? location;
  final bool isEvent;
  final bool excludeFromReport;

  const BlockEditorResult({
    required this.startDate,
    required this.startTime,
    required this.endDate,
    required this.endTime,
    required this.allDay,
    required this.estimatedMinutes,
    required this.workingMinutes,
    required this.breakMinutes,
    required this.title,
    required this.blockName,
    required this.projectId,
    required this.subProjectId,
    required this.subProjectName,
    required this.modeId,
    required this.memo,
    required this.location,
    required this.isEvent,
    required this.excludeFromReport,
  });
}

class BlockEditorForm extends StatefulWidget {
  final DateTime initialStartDate; // date-only
  final TimeOfDay initialStartTime;
  final DateTime initialEndDate; // date-only
  final TimeOfDay initialEndTime;
  final int initialBreakMinutes;
  final bool initialIsEvent;
  final bool initialAllDay;
  final bool allowAllDay;
  final bool initialExcludeFromReport;

  final String initialTitle;
  final bool allowEditTitle;

  final String? initialBlockName;
  final String? initialMemo;
  final String? initialLocation;

  final String? initialProjectId;
  final String? initialProjectName;
  final String? initialSubProjectId;
  final String? initialSubProjectName;
  final String? initialModeId;
  final String? initialModeName;

  /// true の場合、表示直後に「ブロック名」へフォーカスする。
  final bool autofocusBlockName;

  const BlockEditorForm({
    super.key,
    required this.initialStartDate,
    required this.initialStartTime,
    required this.initialEndDate,
    required this.initialEndTime,
    required this.initialBreakMinutes,
    required this.initialIsEvent,
    required this.initialAllDay,
    this.allowAllDay = true,
    this.initialExcludeFromReport = false,
    required this.initialTitle,
    required this.allowEditTitle,
    this.initialBlockName,
    this.initialMemo,
    this.initialLocation,
    this.initialProjectId,
    this.initialProjectName,
    this.initialSubProjectId,
    this.initialSubProjectName,
    this.initialModeId,
    this.initialModeName,
    this.autofocusBlockName = false,
  });

  @override
  State<BlockEditorForm> createState() => BlockEditorFormState();
}

class BlockEditorFormState extends State<BlockEditorForm> {
  static const int maxPlannedTimedMinutes = 48 * 60;
  static const int _legacyAllDayEstimatedMinutes = 24 * 60;
  static const int _defaultStickyDurationMinutes = 60;

  late DateTime _startDate;
  late DateTime _endDate;
  late bool _isEvent;
  late bool _allDay;
  late bool _excludeFromReport;

  /// 「開始時刻を変えたら、終了時刻も所要時間分だけ追随」するための保持値。
  ///
  /// - 初期値: 初期 start/end の差分（不正なら 60分）
  /// - end をユーザーが変更したら更新され、次の start 変更でその所要時間を維持する
  int _stickyDurationMinutes = _defaultStickyDurationMinutes;

  bool get isEvent => _isEvent;

  void setIsEvent(bool value) {
    if (_isEvent == value) return;
    setState(() => _isEvent = value);
  }

  void _setExcludeFromReport(bool value) {
    if (_excludeFromReport == value) return;
    FocusScope.of(context).unfocus();
    setState(() => _excludeFromReport = value);
  }

  void _setAllDay(bool value) {
    if (_allDay == value) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _allDay = value;
      // 終日ON: 時刻入力は使わないため 00:00 を入れておく（パース失敗防止）
      if (_allDay) {
        _startCtrl.text = '00:00';
        _endCtrl.text = '00:00';
        // 終了日は開始日以上に揃える（inclusive）
        if (_endDate.isBefore(_startDate)) _endDate = _startDate;
        // break/working は終日では意味が薄いので 0/1440 に固定（保存側で最終決定）
        _breakCtrl.text = '0';
        _workingCtrl.text = _legacyAllDayEstimatedMinutes.toString();
      } else {
        // 終日→時間ありへ戻す時、48h制約を確実に満たすため同日レンジに縮退し、
        // デフォルト時刻を入れる（Google同様にユーザーが時刻を設定して保存できる）。
        _endDate = _startDate;
        _startCtrl.text = '09:00';
        _endCtrl.text = '10:00';
        _syncBreakAndWorking(edited: _lastEdited);
      }
    });
  }

  late final TextEditingController _startCtrl;
  late final TextEditingController _endCtrl;
  late final TextEditingController _breakCtrl;
  late final TextEditingController _workingCtrl;

  late final TextEditingController _titleCtrl;
  late final TextEditingController _blockNameCtrl;
  late final TextEditingController _memoCtrl;
  late final TextEditingController _locationCtrl;

  // 「枠線側がフォーカスで変化する」見た目に合わせるため、
  // InputDecorator へフォーカス状態を伝搬する。
  late final FocusNode _titleFocus;
  late final FocusNode _blockNameFocus;
  late final FocusNode _startTimeFocus;
  late final FocusNode _endTimeFocus;
  late final FocusNode _breakFocus;
  late final FocusNode _workingFocus;
  late final FocusNode _memoFocus;
  late final FocusNode _locationFocus;

  late final TextEditingController _projectCtrl;
  late final TextEditingController _subProjectCtrl;
  late final TextEditingController _modeCtrl;

  bool _updatingWorkBreak = false;

  // どちらの入力をユーザーが最後に触ったか（整合性解決用）
  _WorkBreakLastEdited _lastEdited = _WorkBreakLastEdited.breakMinutes;

  String? _selectedProjectId;
  String? _selectedSubProjectId;
  String? _selectedSubProjectName;
  String? _selectedModeId;

  @override
  void initState() {
    super.initState();
    _startDate = DateTime(
      widget.initialStartDate.year,
      widget.initialStartDate.month,
      widget.initialStartDate.day,
    );
    _endDate = DateTime(
      widget.initialEndDate.year,
      widget.initialEndDate.month,
      widget.initialEndDate.day,
    );
    _isEvent = widget.initialIsEvent;
    _allDay = widget.allowAllDay ? widget.initialAllDay : false;
    _excludeFromReport = widget.initialExcludeFromReport;

    _startCtrl = TextEditingController(
      text: TimelineHelpers.formatTimeForInput(
        DateTime(0, 1, 1, widget.initialStartTime.hour,
            widget.initialStartTime.minute),
      ),
    );
    // 24:00 表示判定: 終了日が開始日の翌日かつ終了時刻が 0:00 の場合
    final bool shouldShow24 = _is24EndTime(
      startDate: _startDate,
      endDate: _endDate,
      endTime: widget.initialEndTime,
    );
    if (shouldShow24) {
      // 24:00 表示のため、_endDate を startDate に戻す
      _endDate = _startDate;
      _endCtrl = TextEditingController(text: '24:00');
    } else {
      _endCtrl = TextEditingController(
        text: TimelineHelpers.formatTimeForInput(
          DateTime(0, 1, 1, widget.initialEndTime.hour, widget.initialEndTime.minute),
        ),
      );
    }
    _breakCtrl = TextEditingController(text: widget.initialBreakMinutes.toString());
    // working は duration - break を初期値にする（後続の整合化でクランプも行う）
    final initialDuration = _currentDurationMinutes();
    final initialBreak = widget.initialBreakMinutes.clamp(0, initialDuration);
    final initialWorking = (initialDuration - initialBreak).clamp(0, initialDuration);
    _workingCtrl = TextEditingController(text: initialWorking.toString());

    _titleCtrl = TextEditingController(text: widget.initialTitle);
    _blockNameCtrl = TextEditingController(text: widget.initialBlockName ?? '');
    _memoCtrl = TextEditingController(text: widget.initialMemo ?? '');
    _locationCtrl = TextEditingController(text: widget.initialLocation ?? '');

    _titleFocus = FocusNode(debugLabel: 'block_editor_title');
    _blockNameFocus = FocusNode(debugLabel: 'block_editor_block_name');
    _startTimeFocus = FocusNode(debugLabel: 'block_editor_start_time');
    _endTimeFocus = FocusNode(debugLabel: 'block_editor_end_time');
    _breakFocus = FocusNode(debugLabel: 'block_editor_break_minutes');
    _workingFocus = FocusNode(debugLabel: 'block_editor_working_minutes');
    _memoFocus = FocusNode(debugLabel: 'block_editor_memo');
    _locationFocus = FocusNode(debugLabel: 'block_editor_location');
    // 枠線の見た目を即時更新するため、フォーカス変化で再描画する
    _titleFocus.addListener(() {
      if (!mounted) return;
      setState(() {});
    });
    _blockNameFocus.addListener(() {
      if (!mounted) return;
      setState(() {});
    });
    _startTimeFocus.addListener(() {
      if (!mounted) return;
      setState(() {});
    });
    _endTimeFocus.addListener(() {
      if (!mounted) return;
      setState(() {});
    });
    _breakFocus.addListener(() {
      if (!mounted) return;
      setState(() {});
    });
    _workingFocus.addListener(() {
      if (!mounted) return;
      setState(() {});
    });
    _memoFocus.addListener(() {
      if (!mounted) return;
      setState(() {});
    });
    _locationFocus.addListener(() {
      if (!mounted) return;
      setState(() {});
    });

    _selectedProjectId = widget.initialProjectId;
    _selectedSubProjectId = widget.initialSubProjectId;
    _selectedSubProjectName = widget.initialSubProjectName;
    _selectedModeId = widget.initialModeId;

    _projectCtrl = TextEditingController(text: widget.initialProjectName ?? '');
    _subProjectCtrl = TextEditingController(text: widget.initialSubProjectName ?? '');
    _modeCtrl = TextEditingController(text: widget.initialModeName ?? '');

    // 初期値が終日の場合は、時刻/休憩を終日向けに整合させる（フォーム内の一貫性のため）
    if (_allDay) {
      _startCtrl.text = '00:00';
      _endCtrl.text = '00:00';
      _breakCtrl.text = '0';
      _workingCtrl.text = _legacyAllDayEstimatedMinutes.toString();
    }

    // 初期所要時間（開始変更時の終了追随に使う）
    final start0 = _startDateTime();
    final end0 = _endDateTime(allowAutoNextDay: true);
    if (start0 != null && end0 != null) {
      final diff = end0.difference(start0).inMinutes;
      if (diff > 0) {
        _stickyDurationMinutes = diff.clamp(1, maxPlannedTimedMinutes);
      }
    }

    if (widget.autofocusBlockName) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _blockNameFocus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _startCtrl.dispose();
    _endCtrl.dispose();
    _breakCtrl.dispose();
    _workingCtrl.dispose();
    _titleCtrl.dispose();
    _blockNameCtrl.dispose();
    _memoCtrl.dispose();
    _locationCtrl.dispose();
    _titleFocus.dispose();
    _blockNameFocus.dispose();
    _startTimeFocus.dispose();
    _endTimeFocus.dispose();
    _breakFocus.dispose();
    _workingFocus.dispose();
    _memoFocus.dispose();
    _locationFocus.dispose();
    _projectCtrl.dispose();
    _subProjectCtrl.dispose();
    _modeCtrl.dispose();
    super.dispose();
  }

  TimeOfDay? _parseTime(String s) {
    final t = TimelineHelpers.parseTimeInput(s);
    if (t == null) return null;
    return TimeOfDay(hour: t.hour, minute: t.minute);
  }

  /// 終了時刻用パース: 24:00 を許可
  /// 戻り値は (hour, minute) で、hour=24 の場合あり
  ({int hour, int minute})? _parseEndTime(String s) {
    final t = TimelineHelpers.parseEndTimeInput(s);
    if (t == null) return null;
    return (hour: t.hour, minute: t.minute);
  }

  TimeOfDay _initialTimeForPicker(
    TextEditingController controller,
    TimeOfDay fallback,
  ) {
    final parsed = _parseTime(controller.text.trim());
    return parsed ?? fallback;
  }

  Future<void> _pickStartTime() async {
    FocusScope.of(context).unfocus();
    final initial = _initialTimeForPicker(_startCtrl, widget.initialStartTime);
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (!mounted || picked == null) return;
    _startCtrl.text = TimelineHelpers.formatTimeForInput(
      DateTime(0, 1, 1, picked.hour, picked.minute),
    );
    final start = _startDateTime();
    if (start != null) {
      _syncEndWithStartKeepingDuration(newStart: start);
    } else {
      setState(() {});
    }
    _syncWorkBreakForRangeChangePreferBreakAdjustment();
  }

  Future<void> _pickEndTime() async {
    FocusScope.of(context).unfocus();
    final initial = _initialTimeForPicker(_endCtrl, widget.initialEndTime);
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (!mounted || picked == null) return;
    _endCtrl.text = TimelineHelpers.formatTimeForInput(
      DateTime(0, 1, 1, picked.hour, picked.minute),
    );
    setState(() {});
    _updateStickyDurationFromCurrentRange();
    _syncWorkBreakForRangeChangePreferBreakAdjustment();
  }

  DateTime? _startDateTime() {
    final t = _parseTime(_startCtrl.text.trim());
    if (t == null) return null;
    return DateTime(_startDate.year, _startDate.month, _startDate.day, t.hour, t.minute);
  }

  DateTime? _endDateTime({required bool allowAutoNextDay}) {
    final t = _parseEndTime(_endCtrl.text.trim());
    if (t == null) return null;

    DateTime end;
    if (t.hour == 24) {
      // 24:00 は翌日 0:00 として扱う（allowAutoNextDay に関係なく確定）
      final nextDay = _endDate.add(const Duration(days: 1));
      end = DateTime(nextDay.year, nextDay.month, nextDay.day, 0, 0);
    } else {
      end = DateTime(_endDate.year, _endDate.month, _endDate.day, t.hour, t.minute);
      final start = _startDateTime();
      if (start == null) return null;

      // 互換: endDate を触っていない（startDate と同一）かつ end < start の場合は翌日扱いにする
      // （24:00 入力時はこのパスを通らないので二重適用の心配なし）
      if (allowAutoNextDay && _isSameDate(_endDate, _startDate) && end.isBefore(start)) {
        end = end.add(const Duration(days: 1));
      }
    }
    return end;
  }

  bool _isSameDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// 終了時刻を「24:00」として表示すべきか判定
  /// - 終了日が開始日の翌日
  /// - 終了時刻が 0:00
  static bool _is24EndTime({
    required DateTime startDate,
    required DateTime endDate,
    required TimeOfDay endTime,
  }) {
    if (endTime.hour != 0 || endTime.minute != 0) return false;
    final nextDay = DateTime(startDate.year, startDate.month, startDate.day)
        .add(const Duration(days: 1));
    return endDate.year == nextDay.year &&
        endDate.month == nextDay.month &&
        endDate.day == nextDay.day;
  }

  int _currentBreakMinutes(int duration) {
    final v = int.tryParse(_breakCtrl.text.trim());
    if (v == null || v < 0) return 0;
    if (v > duration) return duration;
    return v;
  }

  int _currentWorkingMinutesFromCtrl(int duration) {
    final v = int.tryParse(_workingCtrl.text.trim());
    if (v == null || v < 0) return 0;
    if (v > duration) return duration;
    return v;
  }

  int _currentDurationMinutes() {
    final start = _startDateTime();
    final end = _endDateTime(allowAutoNextDay: true);
    if (start == null || end == null) return 0;
    final diff = end.difference(start).inMinutes;
    return diff > 0 ? diff : 0;
  }

  void _updateStickyDurationFromCurrentRange() {
    final start = _startDateTime();
    final end = _endDateTime(allowAutoNextDay: true);
    if (start == null || end == null) return;
    final diff = end.difference(start).inMinutes;
    if (diff <= 0) return;
    _stickyDurationMinutes = diff.clamp(1, maxPlannedTimedMinutes);
  }

  void _syncEndWithStartKeepingDuration({required DateTime newStart}) {
    // 終日/不正入力中は補正しない
    if (_allDay) return;
    final dur = _stickyDurationMinutes.clamp(1, maxPlannedTimedMinutes);
    final newEnd = newStart.add(Duration(minutes: dur));
    final nextEndDate = DateTime(newEnd.year, newEnd.month, newEnd.day);
    final nextEndText = TimelineHelpers.formatTimeForInput(newEnd);

    setState(() {
      _endDate = nextEndDate;
      if (_endCtrl.text != nextEndText) _endCtrl.text = nextEndText;
    });
  }

  void _setCtrlInt(TextEditingController ctrl, int value) {
    final next = value.toString();
    if (ctrl.text == next) return;
    ctrl.text = next;
  }

  void _syncBreakAndWorking({required _WorkBreakLastEdited edited}) {
    if (_updatingWorkBreak) return;
    _updatingWorkBreak = true;
    try {
      final duration = _currentDurationMinutes();
      if (duration <= 0) {
        // 不正な時刻入力中は無理に補正しない
        return;
      }

      if (edited == _WorkBreakLastEdited.breakMinutes) {
        final breakMinutes = _currentBreakMinutes(duration);
        final workingMinutes = (duration - breakMinutes).clamp(0, duration);
        _setCtrlInt(_workingCtrl, workingMinutes);
      } else {
        final workingMinutes = _currentWorkingMinutesFromCtrl(duration);
        final breakMinutes = (duration - workingMinutes).clamp(0, duration);
        _setCtrlInt(_breakCtrl, breakMinutes);
      }
    } finally {
      _updatingWorkBreak = false;
    }
  }

  /// 開始/終了（日時）を変更して「所要時間」が変わったときの補正。
  ///
  /// 仕様:
  /// - 基本的に **休憩(分)** 側で調整する（= 稼働(分)をなるべく維持する）
  /// - 稼働が所要時間を超える場合のみ、稼働をクランプして休憩を 0 に寄せる
  void _syncWorkBreakForRangeChangePreferBreakAdjustment() {
    if (_allDay) return;
    if (_updatingWorkBreak) return;
    _updatingWorkBreak = true;
    try {
      final duration = _currentDurationMinutes();
      if (duration <= 0) {
        // 不正な時刻入力中は無理に補正しない
        return;
      }

      final parsedWorking = int.tryParse(_workingCtrl.text.trim());
      // フォールバック: 稼働が未入力/不正な場合は、休憩を正として稼働を整合化する
      // （「基本的に休憩で調整」だが、稼働が解釈できないと調整元が無いので例外扱い）
      if (parsedWorking == null) {
        _syncBreakAndWorking(edited: _WorkBreakLastEdited.breakMinutes);
        return;
      }

      final rawWorking = parsedWorking;
      final working = rawWorking.clamp(0, duration);
      if (working != rawWorking) {
        _setCtrlInt(_workingCtrl, working);
      }

      final breakMinutes = (duration - working).clamp(0, duration);
      _setCtrlInt(_breakCtrl, breakMinutes);
    } finally {
      _updatingWorkBreak = false;
    }
  }

  void _showSnack(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// 入力を検証し、成功すれば結果を返す。失敗時は SnackBar を出して null を返す。
  BlockEditorResult? buildResultOrShowError(BuildContext context) {
    if (_allDay) {
      final startDate = DateTime(_startDate.year, _startDate.month, _startDate.day);
      final endDate = DateTime(_endDate.year, _endDate.month, _endDate.day);
      if (endDate.isBefore(startDate)) {
        _showSnack(context, '終了日は開始日以降にしてください');
        return null;
      }
      // 安全装置: 終日レンジの上限（2年）
      final endExclusive =
          DateTime(endDate.year, endDate.month, endDate.day).add(const Duration(days: 1));
      if (endExclusive.difference(startDate).inDays > 366 * 2) {
        _showSnack(context, '終日の期間は最大2年までです');
        return null;
      }
      return BlockEditorResult(
        startDate: startDate,
        startTime: const TimeOfDay(hour: 0, minute: 0),
        endDate: endDate, // inclusive
        endTime: const TimeOfDay(hour: 0, minute: 0),
        allDay: true,
        estimatedMinutes: _legacyAllDayEstimatedMinutes,
        breakMinutes: 0,
        workingMinutes: _legacyAllDayEstimatedMinutes,
        title: _titleCtrl.text.trim(),
        blockName: _blockNameCtrl.text.trim().isEmpty ? null : _blockNameCtrl.text.trim(),
        projectId: _selectedProjectId,
        subProjectId: _selectedSubProjectId,
        subProjectName: _selectedSubProjectName,
        modeId: _selectedModeId,
        memo: _memoCtrl.text.trim().isEmpty ? null : _memoCtrl.text.trim(),
        location: _locationCtrl.text.trim().isEmpty ? null : _locationCtrl.text.trim(),
        isEvent: _isEvent,
        excludeFromReport: _excludeFromReport,
      );
    }

    final start = _startDateTime();
    final end = _endDateTime(allowAutoNextDay: true);
    if (start == null || end == null) {
      _showSnack(context, '開始/終了時刻を HH:mm で入力してください');
      return null;
    }
    if (end.isBefore(start) || end.isAtSameMomentAs(start)) {
      _showSnack(context, '終了は開始より後にしてください');
      return null;
    }
    final duration = end.difference(start).inMinutes;
    if (duration <= 0) {
      _showSnack(context, '終了は開始より後にしてください');
      return null;
    }
    if (duration > maxPlannedTimedMinutes) {
      _showSnack(context, '所要時間は最大48時間までです');
      return null;
    }

    // 休憩/稼働は両方入力欄として扱い、最後に触った方を正としてもう片方を逆算する。
    int breakMinutes;
    int workingMinutes;
    if (_lastEdited == _WorkBreakLastEdited.breakMinutes) {
      breakMinutes = _currentBreakMinutes(duration);
      workingMinutes = (duration - breakMinutes).clamp(0, duration);
      // 表示も整合化しておく
      _syncBreakAndWorking(edited: _WorkBreakLastEdited.breakMinutes);
    } else {
      workingMinutes = _currentWorkingMinutesFromCtrl(duration);
      breakMinutes = (duration - workingMinutes).clamp(0, duration);
      _syncBreakAndWorking(edited: _WorkBreakLastEdited.workingMinutes);
    }

    return BlockEditorResult(
      startDate: DateTime(_startDate.year, _startDate.month, _startDate.day),
      startTime: TimeOfDay(hour: start.hour, minute: start.minute),
      endDate: DateTime(end.year, end.month, end.day),
      endTime: TimeOfDay(hour: end.hour, minute: end.minute),
      allDay: false,
      estimatedMinutes: duration,
      breakMinutes: breakMinutes,
      workingMinutes: workingMinutes,
      title: _titleCtrl.text.trim(),
      blockName: _blockNameCtrl.text.trim().isEmpty ? null : _blockNameCtrl.text.trim(),
      projectId: _selectedProjectId,
      subProjectId: _selectedSubProjectId,
      subProjectName: _selectedSubProjectName,
      modeId: _selectedModeId,
      memo: _memoCtrl.text.trim().isEmpty ? null : _memoCtrl.text.trim(),
      location: _locationCtrl.text.trim().isEmpty ? null : _locationCtrl.text.trim(),
      isEvent: _isEvent,
      excludeFromReport: _excludeFromReport,
    );
  }

  String _fmtYmd(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }

  @override
  Widget build(BuildContext context) {
    final bool useTimePicker = MediaQuery.of(context).size.width < 800;
    final double unifiedFontSize =
        Theme.of(context).textTheme.titleMedium?.fontSize ?? 16.0;
    const double _singleLineFieldHeight = 44;

    Widget _topSwitch({
      required String label,
      required bool value,
      required ValueChanged<bool>? onChanged,
    }) {
      // 最上段トグルは「枠線で囲わない」仕様。
      // 他の入力欄と視覚的な高さを揃えるため、最低限の余白だけ持たせる。
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ),
            Switch(value: value, onChanged: onChanged),
          ],
        ),
      );
    }

    InputDecoration _outlinedDecoration({
      required String label,
      String? hintText,
      Widget? suffixIcon,
    }) {
      return InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        floatingLabelBehavior: FloatingLabelBehavior.always,
        hintText: hintText,
        suffixIcon: suffixIcon,
      );
    }

    // InboxTaskEditScreen と同じ「カスタム入力（Project/Mode等）を包む」用の装飾
    InputDecoration _denseDecoratorDecoration({required String label}) {
      return InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        floatingLabelBehavior: FloatingLabelBehavior.always,
        filled: true,
        fillColor: Theme.of(context).inputDecorationTheme.fillColor ??
            Theme.of(context).colorScheme.surfaceContainerHighest,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 最上段: 「終日」「イベント」「集計外」を1行に集約
        Row(
          children: [
            // 追加導線によっては終日を無効化したい（例: タイムライン起点）。
            // その場合もレイアウトを編集画面と揃えるため、UIは表示してdisabledにする。
            Expanded(
              child: Opacity(
                opacity: widget.allowAllDay ? 1.0 : 0.55,
                child: _topSwitch(
                  label: '終日',
                  value: _allDay,
                  onChanged: widget.allowAllDay ? (v) => _setAllDay(v) : null,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _topSwitch(
                label: 'イベント',
                value: _isEvent,
                onChanged: (v) {
                  FocusScope.of(context).unfocus();
                  setIsEvent(v);
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _topSwitch(
                label: '集計外',
                value: _excludeFromReport,
                onChanged: (v) => _setExcludeFromReport(v),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: TextEditingController(text: _fmtYmd(_startDate)),
                readOnly: true,
                style: TextStyle(fontSize: unifiedFontSize),
                decoration: _outlinedDecoration(
                  label: '開始日',
                  suffixIcon: const Icon(Icons.calendar_today),
                ),
                onTap: () async {
                  FocusScope.of(context).unfocus();
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _startDate,
                    firstDate: DateTime(2020),
                    lastDate: DateTime(2100),
                  );
                  if (picked == null) return;
                  setState(() {
                    _startDate = DateTime(picked.year, picked.month, picked.day);
                    // endDate が startDate より前に行かないように追随
                    if (_endDate.isBefore(_startDate)) {
                      _endDate = _startDate;
                    }
                  });
                  _syncWorkBreakForRangeChangePreferBreakAdjustment();
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _allDay
                  ? const SizedBox.shrink()
                  : TextField(
                      controller: _startCtrl,
                      focusNode: _startTimeFocus,
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: unifiedFontSize),
                      readOnly: useTimePicker,
                      keyboardType:
                          useTimePicker ? TextInputType.none : TextInputType.number,
                      decoration: _outlinedDecoration(
                        label: '開始時刻',
                        hintText: 'HH:MM',
                        suffixIcon:
                            useTimePicker ? const Icon(Icons.access_time) : null,
                      ),
                      onTap: useTimePicker ? _pickStartTime : null,
                      onChanged: useTimePicker
                          ? null
                          : (_) {
                        // 開始時刻が有効になったタイミングで、所要時間を維持したまま終了時刻を追随させる。
                        final start = _startDateTime();
                        if (start != null) {
                          _syncEndWithStartKeepingDuration(newStart: start);
                        } else {
                          setState(() {});
                        }
                        _syncWorkBreakForRangeChangePreferBreakAdjustment();
                        },
                    ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: TextEditingController(
                  text: _fmtYmd(
                    _endDateTime(allowAutoNextDay: true) ??
                        DateTime(_endDate.year, _endDate.month, _endDate.day),
                  ),
                ),
                readOnly: true,
                style: TextStyle(fontSize: unifiedFontSize),
                decoration: _outlinedDecoration(
                  label: '終了日',
                  suffixIcon: const Icon(Icons.calendar_today),
                ),
                onTap: () async {
                  FocusScope.of(context).unfocus();
                  final start = _startDateTime();
                  final initial = start ??
                      DateTime(_startDate.year, _startDate.month, _startDate.day);
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _endDate,
                    firstDate: DateTime(2020),
                    lastDate: DateTime(2100),
                  );
                  if (picked == null) return;
                  setState(() {
                    _endDate = DateTime(picked.year, picked.month, picked.day);
                    // 互換: endDate が startDate より前は許容しない
                    if (_endDate.isBefore(
                      DateTime(initial.year, initial.month, initial.day),
                    )) {
                      _endDate = DateTime(initial.year, initial.month, initial.day);
                    }
                  });
                  _syncWorkBreakForRangeChangePreferBreakAdjustment();
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _allDay
                  ? const SizedBox.shrink()
                  : TextField(
                      controller: _endCtrl,
                      focusNode: _endTimeFocus,
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: unifiedFontSize),
                      readOnly: useTimePicker,
                      keyboardType:
                          useTimePicker ? TextInputType.none : TextInputType.number,
                      decoration: _outlinedDecoration(
                        label: '終了時刻',
                        hintText: 'HH:MM',
                        suffixIcon:
                            useTimePicker ? const Icon(Icons.access_time) : null,
                      ),
                      onTap: useTimePicker ? _pickEndTime : null,
                      onChanged: useTimePicker
                          ? null
                          : (_) {
                              setState(() {});
                              // end をユーザーが触ったら、次回 start 変更時にその所要時間を維持できるよう更新する
                              _updateStickyDurationFromCurrentRange();
                              _syncWorkBreakForRangeChangePreferBreakAdjustment();
                            },
                    ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (!_allDay) ...[
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _breakCtrl,
                  focusNode: _breakFocus,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: unifiedFontSize),
                  keyboardType: TextInputType.number,
                  decoration: _outlinedDecoration(label: '休憩(分)'),
                  onChanged: (_) {
                    if (_updatingWorkBreak) return;
                    _lastEdited = _WorkBreakLastEdited.breakMinutes;
                    setState(() {});
                    _syncBreakAndWorking(
                      edited: _WorkBreakLastEdited.breakMinutes,
                    );
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _workingCtrl,
                  focusNode: _workingFocus,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: unifiedFontSize),
                  keyboardType: TextInputType.number,
                  decoration: _outlinedDecoration(label: '稼働(分)'),
                  onChanged: (_) {
                    if (_updatingWorkBreak) return;
                    _lastEdited = _WorkBreakLastEdited.workingMinutes;
                    setState(() {});
                    _syncBreakAndWorking(
                      edited: _WorkBreakLastEdited.workingMinutes,
                    );
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        TextField(
          controller: _blockNameCtrl,
          focusNode: _blockNameFocus,
          style: TextStyle(fontSize: unifiedFontSize),
          decoration: _outlinedDecoration(label: 'ブロック名'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _titleCtrl,
          focusNode: _titleFocus,
          readOnly: !widget.allowEditTitle,
          minLines: 1,
          maxLines: 2,
          textInputAction: TextInputAction.done,
          inputFormatters: [
            // タイトルは改行を許可しない（見た目は折り返しで2行表示）
            FilteringTextInputFormatter.deny(RegExp(r'[\n\r]')),
          ],
          style: TextStyle(fontSize: unifiedFontSize),
          decoration: _outlinedDecoration(label: 'タスク名'),
        ),
        const SizedBox(height: 12),
        InputDecorator(
          decoration: _denseDecoratorDecoration(label: 'プロジェクト'),
          isEmpty: _projectCtrl.text.isEmpty,
          child: ProjectInputField(
            controller: _projectCtrl,
            height: 44,
            fontSize: unifiedFontSize,
            onProjectChanged: (pid) => setState(() {
              _selectedProjectId = pid;
              _selectedSubProjectId = null;
              _selectedSubProjectName = null;
              _subProjectCtrl.text = '';
            }),
            onAutoSave: () {},
            withBackground: false,
            useOutlineBorder: false,
          ),
        ),
        const SizedBox(height: 12),
        InputDecorator(
          decoration: _denseDecoratorDecoration(label: 'サブプロジェクト'),
          isEmpty: _subProjectCtrl.text.isEmpty,
          child: SubProjectInputField(
            controller: _subProjectCtrl,
            projectId: _selectedProjectId,
            height: 44,
            fontSize: unifiedFontSize,
            onSubProjectChanged: (spid, spname) => setState(() {
              _selectedSubProjectId = spid;
              _selectedSubProjectName = spname;
            }),
            onAutoSave: () {},
            withBackground: false,
            useOutlineBorder: false,
          ),
        ),
        const SizedBox(height: 12),
        // 仕様: モードと場所は同じ行に統一する
        Row(
          children: [
            Expanded(
              child: InputDecorator(
                decoration: _denseDecoratorDecoration(label: 'モード'),
                isEmpty: _modeCtrl.text.isEmpty,
                child: ModeInputField(
                  controller: _modeCtrl,
                  height: _singleLineFieldHeight,
                  fontSize: unifiedFontSize,
                  onModeChanged: (modeId) =>
                      setState(() => _selectedModeId = modeId),
                  onAutoSave: () {},
                  useOutlineBorder: false,
                  withBackground: false,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: InputDecorator(
                decoration: _denseDecoratorDecoration(label: '場所'),
                isEmpty: _locationCtrl.text.isEmpty,
                isFocused: _locationFocus.hasFocus,
                child: SizedBox(
                  height: _singleLineFieldHeight,
                  child: TextField(
                    controller: _locationCtrl,
                    focusNode: _locationFocus,
                    style: TextStyle(fontSize: unifiedFontSize),
                    maxLines: 1,
                    textAlignVertical: TextAlignVertical.center,
                    decoration: const InputDecoration.collapsed(hintText: ''),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // メモは一番下に配置
        TextField(
          controller: _memoCtrl,
          focusNode: _memoFocus,
          maxLines: 2,
          style: TextStyle(fontSize: unifiedFontSize),
          decoration: _outlinedDecoration(label: 'メモ'),
        ),
      ],
    );
  }
}

enum _WorkBreakLastEdited { breakMinutes, workingMinutes }

