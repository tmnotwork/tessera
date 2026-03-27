import 'dart:io';
import 'package:flutter/foundation.dart';
import 'dart:async';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:flutter_timezone/flutter_timezone.dart';
import '../models/block.dart' as block;
import '../models/inbox_task.dart' as inbox;
import 'app_settings_service.dart';
import 'log_service.dart';
import 'package:flutter/services.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _fln =
      FlutterLocalNotificationsPlugin();
  static const MethodChannel _permChannel =
      MethodChannel('com.example.task_kant_1/permissions');
  static const String _firstLaunchExactPromptKey =
      'ui.firstLaunchExactPrompted';
  static const String _stableIdMigratedKey = 'notif.stableId.migrated.v1';
  bool _initialized = false;
  // Deduplicate redundant schedules: blockId-derived notification id -> last scheduled trigger (tz)
  final Map<int, DateTime> _lastScheduledTriggers = <int, DateTime>{};
  // Inexact guard timers: while the app is alive, force-show if OS delays too long
  final Map<int, Timer> _inexactGuardTimers = <int, Timer>{};

  Future<void> initialize() async {
    if (_initialized) return;
    if (kIsWeb) {
      _initialized = true;
      try {
        unawaited(AppLogService.appendNotification('INIT: Skipped on Web'));
      } catch (_) {}
      return;
    }
    if (!(Platform.isAndroid || Platform.isIOS)) {
      _initialized = true;
      try {
        unawaited(AppLogService.appendNotification(
            'INIT: Skipped (not Android/iOS)'));
      } catch (_) {}
      return;
    }

    // Timezone setup: ensure tz.local matches device timezone
    tz.initializeTimeZones();
    try {
      final String localTz = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(localTz));
    } catch (_) {
      // Fallback: leave tz.local as default
    }
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true);
    const initSettings =
        InitializationSettings(android: androidInit, iOS: iosInit);
    await _fln.initialize(initSettings);

    if (Platform.isAndroid) {
      const channel = AndroidNotificationChannel(
        'event_reminders_high',
        'Event Reminders (High)',
        description: 'Calendar event reminder notifications',
        importance: Importance.high,
      );
      const criticalChannel = AndroidNotificationChannel(
        'event_reminders_critical',
        'Event Reminders (Critical)',
        description: 'High priority calendar reminders (alarm clock mode)',
        importance: Importance.max,
      );
      final android = _fln.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      // Android 13+ permission request
      try {
        final granted = await android?.requestNotificationsPermission();
        try {
          unawaited(AppLogService.appendNotification(
              'PERM: POST_NOTIFICATIONS granted=$granted'));
        } catch (_) {}
      } catch (e) {
        try {
          unawaited(AppLogService.appendNotification('PERM: request error=$e'));
        } catch (_) {}
      }
      // Probe exact alarm capability and log
      try {
        final bool canExact =
            await _permChannel.invokeMethod('areExactAlarmsAllowed');
        unawaited(AppLogService.appendNotification(
            'PERM: canScheduleExactAlarms=$canExact'));
        // 初回起動時に未許可なら許可画面へ誘導
        try {
          final prompted = AppSettingsService.getBool(
              _firstLaunchExactPromptKey,
              defaultValue: false);
          if (!canExact && !prompted) {
            await _permChannel.invokeMethod('requestExactAlarmPermission');
            await AppSettingsService.setBool(_firstLaunchExactPromptKey, true);
            unawaited(AppLogService.appendNotification(
                'PERM: prompt exact alarm on first launch'));
          }
        } catch (_) {}
      } catch (e) {
        unawaited(AppLogService.appendNotification(
            'PERM: canScheduleExactAlarms error=$e'));
      }
      try {
        await android?.createNotificationChannel(channel);
        try {
          unawaited(AppLogService.appendNotification(
              'CHANNEL: created id=${channel.id} name=${channel.name}'));
        } catch (_) {}
      } catch (e) {
        try {
          unawaited(
              AppLogService.appendNotification('CHANNEL: create error=$e'));
        } catch (_) {}
      }
      try {
        await android?.createNotificationChannel(criticalChannel);
        try {
          unawaited(AppLogService.appendNotification(
              'CHANNEL: created id=${criticalChannel.id} name=${criticalChannel.name}'));
        } catch (_) {}
      } catch (e) {
        try {
          unawaited(
              AppLogService.appendNotification('CHANNEL: create error=$e'));
        } catch (_) {}
      }

      // One-time migration: cancel all existing scheduled notifications to avoid collisions
      // from previously using String.hashCode for IDs (which are unstable across runs).
      try {
        final migrated = AppSettingsService.getBool(_stableIdMigratedKey,
            defaultValue: false);
        if (!migrated) {
          await _fln.cancelAll();
          await AppSettingsService.setBool(_stableIdMigratedKey, true);
          unawaited(AppLogService.appendNotification(
              'MIGRATE: cancelAll scheduled notifications (switch to stable IDs)'));
        }
      } catch (_) {}
    }

    _initialized = true;
    try {
      final platform =
          Platform.isAndroid ? 'Android' : (Platform.isIOS ? 'iOS' : 'Other');
      unawaited(
          AppLogService.appendNotification('INIT: Completed on $platform'));
    } catch (_) {}
  }

  // 即時テスト通知（起動確認用）
  Future<void> showBootTestNotification() async {
    await initialize();
    if (!_initialized) return;
    if (kIsWeb) return;
    if (!(Platform.isAndroid || Platform.isIOS)) return;

    const int id = 999000; // 固定のテストID
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'event_reminders_critical',
        'Event Reminders (Critical)',
        channelDescription:
            'High priority calendar reminders (alarm clock mode)',
        importance: Importance.max,
        priority: Priority.max,
        playSound: true,
        enableVibration: true,
        category: AndroidNotificationCategory.alarm,
        visibility: NotificationVisibility.public,
        fullScreenIntent: true,
        ticker: 'Event reminder',
      ),
      iOS: DarwinNotificationDetails(),
    );
    await _fln.show(id, '通知テスト', 'アプリ起動時テスト通知', details);
  }

  // Schedule reminder for an event block (start - leadMinutes)
  Future<void> scheduleEventReminder(block.Block b) async {
    await initialize();
    if (!_initialized) {
      try {
        unawaited(AppLogService.appendNotification(
            'SKIP: Not initialized for block id=${b.id}'));
      } catch (_) {}
      return;
    }
    if (kIsWeb) {
      try {
        unawaited(AppLogService.appendNotification(
            'SKIP: Web platform for block id=${b.id}'));
      } catch (_) {}
      return;
    }
    if (!(Platform.isAndroid || Platform.isIOS)) {
      try {
        unawaited(AppLogService.appendNotification(
            'SKIP: Unsupported platform for block id=${b.id}'));
      } catch (_) {}
      return;
    }
    if (b.isDeleted || b.isCompleted || b.isPauseDerived) {
      try {
        unawaited(AppLogService.appendNotification(
            'SKIP: Ineligible block (deleted/completed/pauseDerived) id=${b.id}'));
      } catch (_) {}
      return;
    }
    if (b.isEvent != true) {
      try {
        unawaited(AppLogService.appendNotification(
            'SKIP: Not an event block id=${b.id}'));
      } catch (_) {}
      return;
    }
    if (b.allDay == true) {
      // Phase A: 終日イベントは通知対象外（深夜/即時フォールバックの回帰防止）
      try {
        await cancelEventReminder(b);
      } catch (_) {}
      try {
        unawaited(AppLogService.appendNotification(
            'SKIP: allDay event (no reminder) id=${b.id}'));
      } catch (_) {}
      return;
    }

    final leadStr = AppSettingsService.getString(
        AppSettingsService.keyCalendarEventReminderMinutes);
    final lead = int.tryParse(leadStr ?? '') ?? 10;
    if (lead <= 0) {
      await cancelEventReminder(b);
      try {
        unawaited(AppLogService.appendNotification(
            'SKIP: leadMinutes<=0 (notifications disabled) id=${b.id}'));
      } catch (_) {}
      return;
    }

    // Prefer canonical UTC range if present to avoid legacy date drift.
    final start = b.startAt?.toLocal() ??
        DateTime(
          b.executionDate.year,
          b.executionDate.month,
          b.executionDate.day,
          b.startHour,
          b.startMinute,
        );
    final trigger = start.subtract(Duration(minutes: lead));
    final now = DateTime.now();
    try {
      final name = (b.blockName?.isNotEmpty ?? false)
          ? b.blockName!
          : (b.title.isNotEmpty ? b.title : 'イベント');
      unawaited(AppLogService.appendNotification(
          'DECIDE: id=${b.id.substring(b.id.length - 6)} name="$name" start=${start.toIso8601String()} lead=$lead trigger=${trigger.toIso8601String()} now=${now.toIso8601String()}'));
    } catch (_) {}
    if (!trigger.isAfter(now)) {
      // フォールバック: 直近/過去は即時通知
      final title = (b.blockName?.isNotEmpty ?? false)
          ? b.blockName!
          : (b.title.isNotEmpty ? b.title : 'イベント');
      final body =
          '${start.hour.toString().padLeft(2, '0')}:${start.minute.toString().padLeft(2, '0')} 開始 (${lead}分前)';
      final id = _notificationIdFor(b);
      const details = NotificationDetails(
        android: AndroidNotificationDetails(
          'event_reminders_critical',
          'Event Reminders (Critical)',
          channelDescription:
              'High priority calendar reminders (alarm clock mode)',
          importance: Importance.max,
          priority: Priority.max,
          playSound: true,
          enableVibration: true,
          category: AndroidNotificationCategory.alarm,
          visibility: NotificationVisibility.public,
          fullScreenIntent: true,
          ticker: 'Event reminder',
        ),
        iOS: DarwinNotificationDetails(),
      );
      unawaited(AppLogService.appendNotification(
          'SHOW NOW id=$id title="$title" body="$body" (past trigger fallback)'));
      await _fln.show(id, title, body, details);
      try {
        unawaited(AppLogService.appendNotification(
            'SHOW: immediate id=$id reason=past_trigger'));
      } catch (_) {}
      return;
    }

    final id = _notificationIdFor(b);
    final title = (b.blockName?.isNotEmpty ?? false)
        ? b.blockName!
        : (b.title.isNotEmpty ? b.title : 'イベント');
    final body =
        '${start.hour.toString().padLeft(2, '0')}:${start.minute.toString().padLeft(2, '0')} 開始 (${lead}分前)';

    final tzDate = tz.TZDateTime.from(trigger, tz.local);

    // Deduplicate: if same id already scheduled for the same trigger time, skip reschedule and logging
    final last = _lastScheduledTriggers[id];
    if (last != null && last.isAtSameMomentAs(tzDate)) {
      try {
        unawaited(AppLogService.appendNotification(
            'SKIP: duplicate schedule id=$id trigger=${tzDate.toString()}'));
      } catch (_) {}
      return;
    }
    try {
      // デバッグ: スケジュール時刻を出力
      try {
        print('🔔 SCHED: exact at ${tzDate.toString()} id=$id title="$title"');
        unawaited(AppLogService.appendNotification(
            'SCHED exact at=${tzDate.toString()} id=$id title="$title"'));
      } catch (_) {}
      await _fln.zonedSchedule(
        id,
        title,
        body,
        tzDate,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'event_reminders_critical',
            'Event Reminders (Critical)',
            channelDescription:
                'High priority calendar reminders (alarm clock mode)',
            importance: Importance.max,
            priority: Priority.max,
            playSound: true,
            enableVibration: true,
            category: AndroidNotificationCategory.alarm,
            visibility: NotificationVisibility.public,
            fullScreenIntent: true,
            ticker: 'Event reminder',
          ),
          iOS: DarwinNotificationDetails(),
        ),
        androidScheduleMode: AndroidScheduleMode.alarmClock,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
      _lastScheduledTriggers[id] = tzDate;
      try {
        unawaited(AppLogService.appendNotification(
            'SCHED: success mode=exact id=$id'));
      } catch (_) {}
      // Watchdog: 予定時刻の少し後にOS配信有無を確認し、残存していればフォールバック表示
      try {
        _inexactGuardTimers[id]?.cancel();
        final Duration untilTrigger = tzDate.difference(DateTime.now());
        final Duration guardDelay = untilTrigger + const Duration(seconds: 75);
        if (!guardDelay.isNegative) {
          _inexactGuardTimers[id] = Timer(guardDelay, () async {
            try {
              final pending = await _fln.pendingNotificationRequests();
              final stillPending = pending.any((p) => p.id == id);
              if (stillPending) {
                unawaited(AppLogService.appendNotification(
                    'GUARD: pending still exists after trigger -> force show id=$id'));
                const details = NotificationDetails(
                  android: AndroidNotificationDetails(
                    'event_reminders_critical',
                    'Event Reminders (Critical)',
                    channelDescription:
                        'High priority calendar reminders (alarm clock mode)',
                    importance: Importance.max,
                    priority: Priority.max,
                    playSound: true,
                    enableVibration: true,
                    category: AndroidNotificationCategory.alarm,
                    visibility: NotificationVisibility.public,
                    fullScreenIntent: true,
                    ticker: 'Event reminder',
                  ),
                  iOS: DarwinNotificationDetails(),
                );
                await _fln.show(id, title, body, details);
                unawaited(AppLogService.appendNotification(
                    'SHOW: guard_fallback id=$id'));
              } else {
                unawaited(AppLogService.appendNotification(
                    'GUARD: delivered by OS id=$id'));
              }
            } catch (e) {
              unawaited(
                  AppLogService.appendNotification('GUARD: error id=$id e=$e'));
            } finally {
              _inexactGuardTimers.remove(id);
            }
          });
        }
      } catch (_) {}
    } catch (e) {
      // 正確アラーム権限なし・OEM制約等で失敗時は不正確スケジュールにフォールバック
      try {
        print(
            '⚠️ SCHED FALLBACK: exact failed ($e). Using inexactAllowWhileIdle');
        unawaited(AppLogService.appendNotification(
            'FALLBACK inexact (exact failed: $e) id=$id title="$title"'));
      } catch (_) {}
      await _fln.zonedSchedule(
        id,
        title,
        body,
        tzDate,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'event_reminders_critical',
            'Event Reminders (Critical)',
            channelDescription:
                'High priority calendar reminders (alarm clock mode)',
            importance: Importance.max,
            priority: Priority.max,
            playSound: true,
            enableVibration: true,
            category: AndroidNotificationCategory.alarm,
            visibility: NotificationVisibility.public,
            fullScreenIntent: true,
            ticker: 'Event reminder',
          ),
          iOS: DarwinNotificationDetails(),
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
      _lastScheduledTriggers[id] = tzDate;
      try {
        unawaited(AppLogService.appendNotification(
            'SCHED: success mode=inexact id=$id'));
      } catch (_) {}
      // Watchdog for inexact as well（OSがディレイ・抑止する場合の救済）
      try {
        _inexactGuardTimers[id]?.cancel();
        final Duration untilTrigger = tzDate.difference(DateTime.now());
        final Duration guardDelay = untilTrigger + const Duration(seconds: 120);
        if (!guardDelay.isNegative) {
          _inexactGuardTimers[id] = Timer(guardDelay, () async {
            try {
              final pending = await _fln.pendingNotificationRequests();
              final stillPending = pending.any((p) => p.id == id);
              if (stillPending) {
                unawaited(AppLogService.appendNotification(
                    'GUARD: pending still exists after inexact trigger -> force show id=$id'));
                const details = NotificationDetails(
                  android: AndroidNotificationDetails(
                    'event_reminders_critical',
                    'Event Reminders (Critical)',
                    channelDescription:
                        'High priority calendar reminders (alarm clock mode)',
                    importance: Importance.max,
                    priority: Priority.max,
                    playSound: true,
                    enableVibration: true,
                    category: AndroidNotificationCategory.alarm,
                    visibility: NotificationVisibility.public,
                    fullScreenIntent: true,
                    ticker: 'Event reminder',
                  ),
                  iOS: DarwinNotificationDetails(),
                );
                await _fln.show(id, title, body, details);
                unawaited(AppLogService.appendNotification(
                    'SHOW: guard_fallback(inexact) id=$id'));
              } else {
                unawaited(AppLogService.appendNotification(
                    'GUARD: delivered by OS (inexact) id=$id'));
              }
            } catch (e) {
              unawaited(AppLogService.appendNotification(
                  'GUARD: error(inexact) id=$id e=$e'));
            } finally {
              _inexactGuardTimers.remove(id);
            }
          });
        }
      } catch (_) {}
    }
  }

  // Schedule reminder for an important inbox task (start - leadMinutes)
  Future<void> scheduleTaskReminder(inbox.InboxTask t) async {
    await initialize();
    if (!_initialized) {
      try {
        unawaited(AppLogService.appendNotification(
            'SKIP: Not initialized for task id=${t.id}'));
      } catch (_) {}
      return;
    }
    if (kIsWeb) {
      try {
        unawaited(AppLogService.appendNotification(
            'SKIP: Web platform for task id=${t.id}'));
      } catch (_) {}
      return;
    }
    if (!(Platform.isAndroid || Platform.isIOS)) {
      try {
        unawaited(AppLogService.appendNotification(
            'SKIP: Unsupported platform for task id=${t.id}'));
      } catch (_) {}
      return;
    }
    if (t.isDeleted || t.isCompleted) {
      try {
        unawaited(AppLogService.appendNotification(
            'SKIP: Ineligible task (deleted/completed) id=${t.id}'));
      } catch (_) {}
      return;
    }
    if (t.isSomeday == true) {
      try {
        await cancelTaskReminder(t);
      } catch (_) {}
      try {
        unawaited(AppLogService.appendNotification(
            'SKIP: someday task (no reminder) id=${t.id}'));
      } catch (_) {}
      return;
    }
    if (t.isImportant != true) {
      try {
        await cancelTaskReminder(t);
      } catch (_) {}
      try {
        unawaited(AppLogService.appendNotification(
            'SKIP: not important task id=${t.id}'));
      } catch (_) {}
      return;
    }
    final sh = t.startHour;
    final sm = t.startMinute;
    if (sh == null || sm == null) {
      try {
        await cancelTaskReminder(t);
      } catch (_) {}
      try {
        unawaited(AppLogService.appendNotification(
            'SKIP: task has no start time id=${t.id}'));
      } catch (_) {}
      return;
    }

    final leadStr = AppSettingsService.getString(
        AppSettingsService.keyCalendarEventReminderMinutes);
    final lead = int.tryParse(leadStr ?? '') ?? 10;
    if (lead <= 0) {
      await cancelTaskReminder(t);
      try {
        unawaited(AppLogService.appendNotification(
            'SKIP: leadMinutes<=0 (notifications disabled) id=${t.id}'));
      } catch (_) {}
      return;
    }

    final start = DateTime(
      t.executionDate.year,
      t.executionDate.month,
      t.executionDate.day,
      sh,
      sm,
    );
    final trigger = start.subtract(Duration(minutes: lead));
    final now = DateTime.now();
    try {
      final name = t.title.isNotEmpty ? t.title : 'タスク';
      unawaited(AppLogService.appendNotification(
          'DECIDE(TASK): id=${t.id.substring(t.id.length - 6)} name="$name" start=${start.toIso8601String()} lead=$lead trigger=${trigger.toIso8601String()} now=${now.toIso8601String()}'));
    } catch (_) {}
    if (!trigger.isAfter(now)) {
      // フォールバック: 直近/過去は即時通知
      final title = t.title.isNotEmpty ? t.title : 'タスク';
      final body =
          '${start.hour.toString().padLeft(2, '0')}:${start.minute.toString().padLeft(2, '0')} 開始 (${lead}分前)';
      final id = _notificationIdForTask(t);
      const details = NotificationDetails(
        android: AndroidNotificationDetails(
          'event_reminders_critical',
          'Event Reminders (Critical)',
          channelDescription:
              'High priority calendar reminders (alarm clock mode)',
          importance: Importance.max,
          priority: Priority.max,
          playSound: true,
          enableVibration: true,
          category: AndroidNotificationCategory.alarm,
          visibility: NotificationVisibility.public,
          fullScreenIntent: true,
          ticker: 'Event reminder',
        ),
        iOS: DarwinNotificationDetails(),
      );
      unawaited(AppLogService.appendNotification(
          'SHOW NOW(TASK) id=$id title="$title" body="$body" (past trigger fallback)'));
      await _fln.show(id, title, body, details);
      try {
        unawaited(AppLogService.appendNotification(
            'SHOW: immediate(TASK) id=$id reason=past_trigger'));
      } catch (_) {}
      return;
    }

    final id = _notificationIdForTask(t);
    final title = t.title.isNotEmpty ? t.title : 'タスク';
    final body =
        '${start.hour.toString().padLeft(2, '0')}:${start.minute.toString().padLeft(2, '0')} 開始 (${lead}分前)';

    final tzDate = tz.TZDateTime.from(trigger, tz.local);

    // Deduplicate: if same id already scheduled for the same trigger time, skip reschedule and logging
    final last = _lastScheduledTriggers[id];
    if (last != null && last.isAtSameMomentAs(tzDate)) {
      try {
        unawaited(AppLogService.appendNotification(
            'SKIP: duplicate schedule(TASK) id=$id trigger=${tzDate.toString()}'));
      } catch (_) {}
      return;
    }
    try {
      // デバッグ: スケジュール時刻を出力
      try {
        print('🔔 SCHED(TASK): exact at ${tzDate.toString()} id=$id title="$title"');
        unawaited(AppLogService.appendNotification(
            'SCHED(TASK) exact at=${tzDate.toString()} id=$id title="$title"'));
      } catch (_) {}
      await _fln.zonedSchedule(
        id,
        title,
        body,
        tzDate,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'event_reminders_critical',
            'Event Reminders (Critical)',
            channelDescription:
                'High priority calendar reminders (alarm clock mode)',
            importance: Importance.max,
            priority: Priority.max,
            playSound: true,
            enableVibration: true,
            category: AndroidNotificationCategory.alarm,
            visibility: NotificationVisibility.public,
            fullScreenIntent: true,
            ticker: 'Event reminder',
          ),
          iOS: DarwinNotificationDetails(),
        ),
        androidScheduleMode: AndroidScheduleMode.alarmClock,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
      _lastScheduledTriggers[id] = tzDate;
      try {
        unawaited(AppLogService.appendNotification(
            'SCHED: success(TASK) mode=exact id=$id'));
      } catch (_) {}
      // Watchdog: 予定時刻の少し後にOS配信有無を確認し、残存していればフォールバック表示
      try {
        _inexactGuardTimers[id]?.cancel();
        final Duration untilTrigger = tzDate.difference(DateTime.now());
        final Duration guardDelay = untilTrigger + const Duration(seconds: 75);
        if (!guardDelay.isNegative) {
          _inexactGuardTimers[id] = Timer(guardDelay, () async {
            try {
              final pending = await _fln.pendingNotificationRequests();
              final stillPending = pending.any((p) => p.id == id);
              if (stillPending) {
                unawaited(AppLogService.appendNotification(
                    'GUARD: pending still exists after trigger -> force show(TASK) id=$id'));
                const details = NotificationDetails(
                  android: AndroidNotificationDetails(
                    'event_reminders_critical',
                    'Event Reminders (Critical)',
                    channelDescription:
                        'High priority calendar reminders (alarm clock mode)',
                    importance: Importance.max,
                    priority: Priority.max,
                    playSound: true,
                    enableVibration: true,
                    category: AndroidNotificationCategory.alarm,
                    visibility: NotificationVisibility.public,
                    fullScreenIntent: true,
                    ticker: 'Event reminder',
                  ),
                  iOS: DarwinNotificationDetails(),
                );
                await _fln.show(id, title, body, details);
                unawaited(AppLogService.appendNotification(
                    'SHOW: guard_fallback(TASK) id=$id'));
              } else {
                unawaited(AppLogService.appendNotification(
                    'GUARD: delivered by OS(TASK) id=$id'));
              }
            } catch (e) {
              unawaited(AppLogService.appendNotification(
                  'GUARD: error(TASK) id=$id e=$e'));
            } finally {
              _inexactGuardTimers.remove(id);
            }
          });
        }
      } catch (_) {}
    } catch (e) {
      // 正確アラーム権限なし・OEM制約等で失敗時は不正確スケジュールにフォールバック
      try {
        print(
            '⚠️ SCHED FALLBACK(TASK): exact failed ($e). Using inexactAllowWhileIdle');
        unawaited(AppLogService.appendNotification(
            'FALLBACK inexact(TASK) (exact failed: $e) id=$id title="$title"'));
      } catch (_) {}
      await _fln.zonedSchedule(
        id,
        title,
        body,
        tzDate,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'event_reminders_critical',
            'Event Reminders (Critical)',
            channelDescription:
                'High priority calendar reminders (alarm clock mode)',
            importance: Importance.max,
            priority: Priority.max,
            playSound: true,
            enableVibration: true,
            category: AndroidNotificationCategory.alarm,
            visibility: NotificationVisibility.public,
            fullScreenIntent: true,
            ticker: 'Event reminder',
          ),
          iOS: DarwinNotificationDetails(),
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
      _lastScheduledTriggers[id] = tzDate;
      try {
        unawaited(AppLogService.appendNotification(
            'SCHED: success(TASK) mode=inexact id=$id'));
      } catch (_) {}
      // Watchdog for inexact as well（OSがディレイ・抑止する場合の救済）
      try {
        _inexactGuardTimers[id]?.cancel();
        final Duration untilTrigger = tzDate.difference(DateTime.now());
        final Duration guardDelay = untilTrigger + const Duration(seconds: 120);
        if (!guardDelay.isNegative) {
          _inexactGuardTimers[id] = Timer(guardDelay, () async {
            try {
              final pending = await _fln.pendingNotificationRequests();
              final stillPending = pending.any((p) => p.id == id);
              if (stillPending) {
                unawaited(AppLogService.appendNotification(
                    'GUARD: pending still exists after inexact trigger -> force show(TASK) id=$id'));
                const details = NotificationDetails(
                  android: AndroidNotificationDetails(
                    'event_reminders_critical',
                    'Event Reminders (Critical)',
                    channelDescription:
                        'High priority calendar reminders (alarm clock mode)',
                    importance: Importance.max,
                    priority: Priority.max,
                    playSound: true,
                    enableVibration: true,
                    category: AndroidNotificationCategory.alarm,
                    visibility: NotificationVisibility.public,
                    fullScreenIntent: true,
                    ticker: 'Event reminder',
                  ),
                  iOS: DarwinNotificationDetails(),
                );
                await _fln.show(id, title, body, details);
                unawaited(AppLogService.appendNotification(
                    'SHOW: guard_fallback(inexact)(TASK) id=$id'));
              } else {
                unawaited(AppLogService.appendNotification(
                    'GUARD: delivered by OS (inexact)(TASK) id=$id'));
              }
            } catch (e) {
              unawaited(AppLogService.appendNotification(
                  'GUARD: error(inexact)(TASK) id=$id e=$e'));
            } finally {
              _inexactGuardTimers.remove(id);
            }
          });
        }
      } catch (_) {}
    }
  }

  Future<void> cancelEventReminder(block.Block b) async {
    await initialize();
    if (!_initialized) return;
    if (kIsWeb) return;
    final id = _notificationIdFor(b);
    await _fln.cancel(id);
    try {
      unawaited(AppLogService.appendNotification(
          'CANCEL id=$id for blockId=${b.id}'));
    } catch (_) {}
  }

  Future<void> cancelTaskReminder(inbox.InboxTask t) async {
    await initialize();
    if (!_initialized) return;
    if (kIsWeb) return;
    final id = _notificationIdForTask(t);
    await _fln.cancel(id);
    try {
      unawaited(AppLogService.appendNotification(
          'CANCEL id=$id for taskId=${t.id}'));
    } catch (_) {}
  }

  /// 与えられたブロック一覧に対して、イベント通知を一括で再スケジュール
  /// - isEvent=false / 削除済み / 完了済み はキャンセル
  /// - 未来のトリガのみスケジュール
  Future<void> scheduleEventRemindersForBlocks(List<block.Block> blocks) async {
    await initialize();
    if (!_initialized) return;
    if (kIsWeb) return;
    if (!(Platform.isAndroid || Platform.isIOS)) return;

    try {
      final total = blocks.length;
      final eligible = blocks
          .where((b) =>
              !b.isDeleted &&
              !b.isCompleted &&
              !b.isPauseDerived &&
              b.isEvent == true &&
              b.allDay != true)
          .length;
      unawaited(AppLogService.appendNotification(
          'BULK SCHEDULE: total=$total eligible=$eligible'));
    } catch (_) {}

    for (final b in blocks) {
      try {
        if (b.isDeleted ||
            b.isCompleted ||
            b.isPauseDerived ||
            b.isEvent != true ||
            b.allDay == true) {
          await cancelEventReminder(b);
          try {
            unawaited(AppLogService.appendNotification(
                'BULK: cancel id=${b.id.substring(b.id.length - 6)} reason=ineligible(deleted/completed/pauseDerived/isEvent!=true/allDay)'));
          } catch (_) {}
          continue;
        }
        // スケジュール対象: 未来のトリガのみ
        final leadStr = AppSettingsService.getString(
            AppSettingsService.keyCalendarEventReminderMinutes);
        final lead = int.tryParse(leadStr ?? '') ?? 10;
        if (lead <= 0) {
          await cancelEventReminder(b);
          try {
            unawaited(AppLogService.appendNotification(
                'BULK: cancel id=${b.id.substring(b.id.length - 6)} reason=lead<=0'));
          } catch (_) {}
          continue;
        }
        // 未来は通常予約、過去は個別予約に委ねて即時表示（SHOW NOW）させる
        await scheduleEventReminder(b);
      } catch (_) {}
    }
  }

  /// 与えられたタスク一覧に対して、重要タスク通知を一括で再スケジュール
  /// - 重要でない/削除済み/完了済み/いつか/時刻なし はキャンセル
  /// - 未来のトリガのみスケジュール
  Future<void> scheduleTaskRemindersForTasks(List<inbox.InboxTask> tasks) async {
    await initialize();
    if (!_initialized) return;
    if (kIsWeb) return;
    if (!(Platform.isAndroid || Platform.isIOS)) return;

    try {
      final total = tasks.length;
      final eligible = tasks
          .where((t) =>
              !t.isDeleted &&
              !t.isCompleted &&
              t.isSomeday != true &&
              t.isImportant == true &&
              t.startHour != null &&
              t.startMinute != null)
          .length;
      unawaited(AppLogService.appendNotification(
          'BULK SCHEDULE(TASK): total=$total eligible=$eligible'));
    } catch (_) {}

    for (final t in tasks) {
      try {
        final idLabel =
            t.id.length > 6 ? t.id.substring(t.id.length - 6) : t.id;
        if (t.isDeleted ||
            t.isCompleted ||
            t.isSomeday == true ||
            t.isImportant != true ||
            t.startHour == null ||
            t.startMinute == null) {
          await cancelTaskReminder(t);
          try {
            unawaited(AppLogService.appendNotification(
                'BULK: cancel(TASK) id=$idLabel reason=ineligible(deleted/completed/someday/notImportant/noStartTime)'));
          } catch (_) {}
          continue;
        }
        // スケジュール対象: 未来のトリガのみ
        final leadStr = AppSettingsService.getString(
            AppSettingsService.keyCalendarEventReminderMinutes);
        final lead = int.tryParse(leadStr ?? '') ?? 10;
        if (lead <= 0) {
          await cancelTaskReminder(t);
          try {
            unawaited(AppLogService.appendNotification(
                'BULK: cancel(TASK) id=$idLabel reason=lead<=0'));
          } catch (_) {}
          continue;
        }
        // 未来は通常予約、過去は個別予約に委ねて即時表示（SHOW NOW）させる
        await scheduleTaskReminder(t);
      } catch (_) {}
    }
  }

  /// 現在のブロック一覧と照合し、不要な保留中通知をキャンセルする
  Future<void> reconcilePendingWithBlocks(List<block.Block> blocks) async {
    await initialize();
    if (!_initialized) return;
    if (kIsWeb) return;
    try {
      final leadStr = AppSettingsService.getString(
          AppSettingsService.keyCalendarEventReminderMinutes);
      final lead = int.tryParse(leadStr ?? '') ?? 10;
      final Set<int> allowedIds = <int>{};
      final now = DateTime.now();
      for (final b in blocks) {
        if (b.isDeleted ||
            b.isCompleted ||
            b.isPauseDerived ||
            b.isEvent != true ||
            b.allDay == true) {
          continue;
        }
        if (lead <= 0) continue;
        final start = b.startAt?.toLocal() ??
            DateTime(
              b.executionDate.year,
              b.executionDate.month,
              b.executionDate.day,
              b.startHour,
              b.startMinute,
            );
        final trigger = start.subtract(Duration(minutes: lead));
        if (trigger.isAfter(now)) {
          allowedIds.add(_notificationIdFor(b));
        }
      }
      final pending = await _fln.pendingNotificationRequests();
      for (final req in pending) {
        if (!allowedIds.contains(req.id)) {
          await _fln.cancel(req.id);
          try {
            unawaited(AppLogService.appendNotification(
                'RECONCILE: cancel stray pending id=${req.id}'));
          } catch (_) {}
        }
      }
    } catch (e) {
      try {
        unawaited(AppLogService.appendNotification('RECONCILE: error $e'));
      } catch (_) {}
    }
  }

  /// ブロック/タスクをまとめて照合し、不要な保留中通知をキャンセルする
  Future<void> reconcilePendingWithBlocksAndTasks(
    List<block.Block> blocks,
    List<inbox.InboxTask> tasks,
  ) async {
    await initialize();
    if (!_initialized) return;
    if (kIsWeb) return;
    try {
      final leadStr = AppSettingsService.getString(
          AppSettingsService.keyCalendarEventReminderMinutes);
      final lead = int.tryParse(leadStr ?? '') ?? 10;
      final Set<int> allowedIds = <int>{};
      final now = DateTime.now();
      for (final b in blocks) {
        if (b.isDeleted ||
            b.isCompleted ||
            b.isPauseDerived ||
            b.isEvent != true ||
            b.allDay == true) {
          continue;
        }
        if (lead <= 0) continue;
        final start = b.startAt?.toLocal() ??
            DateTime(
              b.executionDate.year,
              b.executionDate.month,
              b.executionDate.day,
              b.startHour,
              b.startMinute,
            );
        final trigger = start.subtract(Duration(minutes: lead));
        if (trigger.isAfter(now)) {
          allowedIds.add(_notificationIdFor(b));
        }
      }
      for (final t in tasks) {
        if (t.isDeleted ||
            t.isCompleted ||
            t.isSomeday == true ||
            t.isImportant != true) {
          continue;
        }
        if (lead <= 0) continue;
        final sh = t.startHour;
        final sm = t.startMinute;
        if (sh == null || sm == null) continue;
        final start = DateTime(
          t.executionDate.year,
          t.executionDate.month,
          t.executionDate.day,
          sh,
          sm,
        );
        final trigger = start.subtract(Duration(minutes: lead));
        if (trigger.isAfter(now)) {
          allowedIds.add(_notificationIdForTask(t));
        }
      }
      final pending = await _fln.pendingNotificationRequests();
      for (final req in pending) {
        if (!allowedIds.contains(req.id)) {
          await _fln.cancel(req.id);
          try {
            unawaited(AppLogService.appendNotification(
                'RECONCILE: cancel stray pending id=${req.id}'));
          } catch (_) {}
        }
      }
    } catch (e) {
      try {
        unawaited(AppLogService.appendNotification('RECONCILE: error $e'));
      } catch (_) {}
    }
  }

  // 診断: 権限・保留中通知の件数などをログに出す
  Future<void> runDiagnostics() async {
    await initialize();
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    try {
      unawaited(AppLogService.appendNotification('DIAG: begin'));
      if (Platform.isAndroid) {
        final android = _fln.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
        try {
          final enabled = await android?.areNotificationsEnabled();
          unawaited(AppLogService.appendNotification(
              'DIAG: areNotificationsEnabled=$enabled'));
        } catch (e) {
          unawaited(AppLogService.appendNotification(
              'DIAG: areNotificationsEnabled error=$e'));
        }
      }
      try {
        final pending = await _fln.pendingNotificationRequests();
        unawaited(AppLogService.appendNotification(
            'DIAG: pendingRequests=${pending.length}'));
      } catch (e) {
        unawaited(
            AppLogService.appendNotification('DIAG: pendingRequests error=$e'));
      }
      unawaited(AppLogService.appendNotification('DIAG: end'));
    } catch (_) {}
  }

  int _notificationIdFor(block.Block b) {
    // Derive a stable 32-bit FNV-1a hash from block id (stable across runs)
    return _stableHash32(b.id);
  }

  int _notificationIdForTask(inbox.InboxTask t) {
    // Prefix to avoid collisions with block ids
    return _stableHash32('task:${t.id}');
  }

  int _stableHash32(String input) {
    const int fnvPrime = 16777619;
    const int offsetBasis = 2166136261;
    int hash = offsetBasis;
    final List<int> units = input.codeUnits;
    for (int i = 0; i < units.length; i++) {
      hash ^= units[i] & 0xFF;
      hash = (hash * fnvPrime) & 0xFFFFFFFF;
    }
    return hash & 0x7FFFFFFF;
  }
}
