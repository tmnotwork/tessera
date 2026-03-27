import 'package:flutter/material.dart';

import '../models/work_type.dart';
import '../models/routine_template_v2.dart';
import '../services/auth_service.dart';
import '../services/device_info_service.dart';
import '../services/routine_lamport_clock_service.dart';
import '../services/routine_template_v2_service.dart';
import '../services/routine_template_v2_sync_service.dart';
import 'shortcut_template_screen.dart';
import '../app/theme/domain_colors.dart';

/// テストメニューでショートカット編集画面を検証するための画面。
///
/// 本画面はテスト用。通常利用では [ShortcutTemplateScreen]（V2）をそのまま表示する。
class ShortcutTestScreen extends StatefulWidget {
  const ShortcutTestScreen({super.key});

  @override
  State<ShortcutTestScreen> createState() => _ShortcutTestScreenState();
}

class _ShortcutTestScreenState extends State<ShortcutTestScreen> {
  bool _isLoading = true;
  RoutineTemplateV2? _template;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    try {
      const templateId = 'shortcut';
      final existing = RoutineTemplateV2Service.getById(templateId);
      if (existing != null) {
        _template = existing;
      } else {
        final deviceId = await DeviceInfoService.getDeviceId();
        final uid = AuthService.getCurrentUserId() ?? '';
        final now = DateTime.now().toUtc();
        final ver = await RoutineLamportClockService.next();
        final tpl = RoutineTemplateV2(
          id: templateId,
          title: '非定型ショートカット',
          memo: '',
          workType: WorkType.free,
          color: DomainColors.defaultHex,
          applyDayType: 'both',
          isActive: true,
          isDeleted: false,
          version: ver,
          deviceId: deviceId,
          userId: uid,
          createdAt: now,
          lastModified: now,
          isShortcut: true,
        )..cloudId = templateId;

        await RoutineTemplateV2Service.add(tpl);
        try {
          await RoutineTemplateV2SyncService().uploadToFirebase(tpl);
          await RoutineTemplateV2Service.update(tpl);
        } catch (_) {}
        _template = tpl;
      }
    } catch (e, st) {
      try {
        // ignore: avoid_print
        print('❌ ShortcutTestScreen load failed: $e');
        // ignore: avoid_print
        print(st);
      } catch (_) {}
      _template = null;
    }

    if (!mounted) return;
    setState(() => _isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (_template == null) {
      return const Scaffold(
        body: Center(child: Text('ショートカットテンプレートが読み込めませんでした。')),
      );
    }

    return ShortcutTemplateScreen(routine: _template!);
  }
}
