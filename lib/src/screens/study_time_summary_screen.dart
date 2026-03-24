import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../database/local_database.dart';
import '../sync/ensure_synced_for_local_read.dart';

/// ローカルに蓄積した勉強時間のざっくり集計（直近7日・種別内訳・最近のセッション）
class StudyTimeSummaryScreen extends StatefulWidget {
  const StudyTimeSummaryScreen({super.key, this.localDatabase});

  final LocalDatabase? localDatabase;

  @override
  State<StudyTimeSummaryScreen> createState() => _StudyTimeSummaryScreenState();
}

class _StudyTimeSummaryScreenState extends State<StudyTimeSummaryScreen> {
  bool _loading = true;
  String? _error;
  int _weekTotalSec = 0;
  Map<String, int> _byTypeSec = {};
  List<Map<String, dynamic>> _recent = [];

  static String _labelForType(String? t) {
    switch (t) {
      case 'question':
        return '四択・テキスト問題';
      case 'knowledge':
        return '知識カード';
      case 'english_example':
        return '例文読み上げ';
      case 'english_example_composition':
        return '英作文（例文）';
      case 'memorization':
        return '暗記カード';
      default:
        return t ?? 'その他';
    }
  }

  static String _formatDuration(int sec) {
    if (sec <= 0) return '0分';
    final m = sec ~/ 60;
    final s = sec % 60;
    if (m >= 60) {
      final h = m ~/ 60;
      final rm = m % 60;
      return '$h時間$rm分';
    }
    if (m == 0) return '${s}秒';
    if (s == 0) return '$m分';
    return '$m分$s秒';
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = widget.localDatabase?.db;
    if (db == null) {
      setState(() {
        _loading = false;
        _error = null;
        _weekTotalSec = 0;
        _byTypeSec = {};
        _recent = [];
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      if (!kIsWeb) {
        await triggerBackgroundSyncWithThrottle();
      }

      final now = DateTime.now();
      final weekStart = now.subtract(const Duration(days: 7));

      final rows = await db.query(
        LocalTable.studySessions,
        columns: [
          'session_type',
          'duration_sec',
          'ended_at',
          'content_title',
          'subject_name',
          'tts_sec',
        ],
        where: 'ended_at IS NOT NULL AND TRIM(COALESCE(ended_at, \'\')) != \'\'',
        orderBy: 'ended_at DESC',
      );

      var weekTotal = 0;
      final byType = <String, int>{};
      for (final r in rows) {
        final endedRaw = r['ended_at']?.toString();
        if (endedRaw == null || endedRaw.isEmpty) continue;
        final ended = DateTime.tryParse(endedRaw);
        if (ended == null) continue;
        if (ended.isBefore(weekStart)) continue;
        final ds = r['duration_sec'];
        final sec = ds is int ? ds : int.tryParse(ds?.toString() ?? '') ?? 0;
        if (sec <= 0) continue;
        weekTotal += sec;
        final st = r['session_type']?.toString() ?? 'other';
        byType[st] = (byType[st] ?? 0) + sec;
      }

      final recent = rows.take(25).toList();

      if (mounted) {
        setState(() {
          _weekTotalSec = weekTotal;
          _byTypeSec = byType;
          _recent = recent;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (widget.localDatabase == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('勉強時間')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'この機能はアプリ版（ローカルDBあり）で利用できます。Web版では記録されません。',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('勉強時間'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
            tooltip: '再読み込み',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        FilledButton(onPressed: _load, child: const Text('再試行')),
                      ],
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                    children: [
                      Text(
                        '直近7日間',
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Card(
                        margin: EdgeInsets.zero,
                        child: ListTile(
                          title: const Text('合計'),
                          trailing: Text(
                            _formatDuration(_weekTotalSec),
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      if (_byTypeSec.isNotEmpty) ...[
                        const SizedBox(height: 24),
                        Text(
                          '活動の内訳（7日）',
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Card(
                          margin: EdgeInsets.zero,
                          child: Column(
                            children: [
                              for (final e in _byTypeSec.entries)
                                ListTile(
                                  title: Text(_labelForType(e.key)),
                                  trailing: Text(_formatDuration(e.value)),
                                ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      Text(
                        '最近のセッション',
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (_recent.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(16),
                          child: Text('まだ記録がありません。学習画面を開くと自動で記録されます。'),
                        )
                      else
                        Card(
                          margin: EdgeInsets.zero,
                          child: Column(
                            children: [
                              for (final r in _recent)
                                ListTile(
                                  title: Text(
                                    r['content_title']?.toString().isNotEmpty == true
                                        ? r['content_title'].toString()
                                        : '（無題）',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(
                                    [
                                      _labelForType(r['session_type']?.toString()),
                                      if (r['subject_name'] != null &&
                                          r['subject_name'].toString().isNotEmpty)
                                        r['subject_name'].toString(),
                                      _formatDuration(
                                        r['duration_sec'] is int
                                            ? r['duration_sec'] as int
                                            : int.tryParse(
                                                    r['duration_sec']?.toString() ?? '',
                                                  ) ??
                                                0,
                                      ),
                                      if ((r['tts_sec'] is int
                                              ? r['tts_sec'] as int
                                              : int.tryParse(
                                                      r['tts_sec']?.toString() ?? '',
                                                    ) ??
                                                  0) >
                                          0)
                                        'TTS ${_formatDuration(r['tts_sec'] is int ? r['tts_sec'] as int : int.tryParse(r['tts_sec']?.toString() ?? '') ?? 0)}',
                                    ].join(' · '),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 24),
                      Text(
                        'データは端末内に保存され、同期実行時に Supabase へ送信されます（ログイン時）。',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
    );
  }
}
