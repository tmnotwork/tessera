import 'package:flutter/material.dart';
import '../widgets/common_layout.dart';
import '../services/app_settings_service.dart';
import '../widgets/calendar_settings.dart';
import 'calendar_screen/helpers.dart' as helpers;

class CalendarSettingsScreen extends StatefulWidget {
	const CalendarSettingsScreen({super.key});

	@override
	State<CalendarSettingsScreen> createState() => _CalendarSettingsScreenState();
}

class _CalendarSettingsScreenState extends State<CalendarSettingsScreen> {
	String _defaultView = 'month';
	int _initialBreakRatio = 100;
	bool _loading = true;

	@override
	void initState() {
		super.initState();
		_load();
	}

	Future<void> _load() async {
		await AppSettingsService.initialize();
		final s = AppSettingsService.getString(AppSettingsService.keyCalendarDefaultViewType) ?? 'month';
		final breakRatio = AppSettingsService.getInt(
			AppSettingsService.keyCalendarInitialBreakRatio,
			defaultValue: 100,
		);
		setState(() {
			_defaultView = (helpers.parseViewType(s) ?? CalendarViewType.month).name;
			_initialBreakRatio = breakRatio;
			_loading = false;
		});
	}

	Future<void> _setDefault(String v) async {
		setState(() => _defaultView = v);
		await AppSettingsService.setString(AppSettingsService.keyCalendarDefaultViewType, v);
		// 任意: lastViewType も同時に更新して初回起動で反映を早める
		await AppSettingsService.setString(AppSettingsService.keyLastViewType, v);
		if (mounted) {
			ScaffoldMessenger.of(context).showSnackBar(
				SnackBar(content: Text('デフォルト表示を ${_labelOf(v)} に設定しました')),
			);
		}
	}

	String _labelOf(String v) {
		switch (v) {
			case 'year':
				return '年表示';
			case 'month':
				return '月表示';
			case 'week':
				return '週表示';
			case 'day':
				return '日表示';
		}
		return v;
	}

	@override
	Widget build(BuildContext context) {
		return CommonLayout(
			title: 'カレンダー設定',
			showDrawer: true,
			suppressBaseActions: true,
			child: Padding(
				padding: const EdgeInsets.all(16.0),
				child: _loading
					? const Center(child: CircularProgressIndicator())
					: Column(
						crossAxisAlignment: CrossAxisAlignment.start,
						children: [
							const Text('デフォルト表示', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
							const SizedBox(height: 8),
							Wrap(
								spacing: 8,
								runSpacing: 8,
								children: [
									ChoiceChip(
										label: const Text('年'),
										selected: _defaultView == 'year',
										onSelected: (_) => _setDefault('year'),
									),
									ChoiceChip(
										label: const Text('月'),
										selected: _defaultView == 'month',
										onSelected: (_) => _setDefault('month'),
									),
									ChoiceChip(
										label: const Text('週'),
										selected: _defaultView == 'week',
										onSelected: (_) => _setDefault('week'),
									),
									ChoiceChip(
										label: const Text('日'),
										selected: _defaultView == 'day',
										onSelected: (_) => _setDefault('day'),
									),
								],
							),
							const SizedBox(height: 24),
							const Divider(),
							const SizedBox(height: 16),
							const Text(
								'初期休憩時間の割合',
								style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
							),
							const SizedBox(height: 8),
							Row(
								children: [
									Expanded(
										child: Slider(
											value: _initialBreakRatio.toDouble(),
											min: 0,
											max: 100,
											divisions: 20,
											label: '$_initialBreakRatio%',
											onChanged: (v) async {
												final newVal = v.round();
												setState(() => _initialBreakRatio = newVal);
												await AppSettingsService.setInt(
													AppSettingsService.keyCalendarInitialBreakRatio,
													newVal,
												);
											},
										),
									),
									SizedBox(
										width: 48,
										child: Text(
											'$_initialBreakRatio%',
											style: const TextStyle(
												fontSize: 14,
												fontWeight: FontWeight.bold,
											),
										),
									),
								],
							),
							Padding(
								padding: const EdgeInsets.only(left: 4),
								child: Text(
									'ブロック追加時のデフォルト休憩率',
									style: TextStyle(
										fontSize: 12,
										color: Theme.of(context).colorScheme.onSurfaceVariant,
									),
								),
							),
						],
					),
			),
		);
	}
}