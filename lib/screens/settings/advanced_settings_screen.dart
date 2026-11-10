import 'dart:io';

import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';
import '../../services/alarm_storage_service.dart';
import '../../services/app_data_export.dart';
import '../../settings/advanced_settings.dart';
import '../../widgets/app_shell.dart';

/// Download tuning and how long data stays fresh. Each setting offers fixed
/// choices, applied as soon as one is picked.
class AdvancedSettingsScreen extends StatefulWidget {
  const AdvancedSettingsScreen({super.key});

  @override
  State<AdvancedSettingsScreen> createState() => _AdvancedSettingsScreenState();
}

class _AdvancedSettingsScreenState extends State<AdvancedSettingsScreen> {
  /// Each setting's title and description keys, and how a value reads.
  static final _rows =
      <
        ({
          AdvancedSetting setting,
          String key,
          String Function(int value) label,
        })
      >[
        (
          setting: AdvancedSettings.parallelRequests,
          key: 'settings.advanced.parallel_requests',
          label: (value) => '$value',
        ),
        (
          setting: AdvancedSettings.timetableRowsPerCommit,
          key: 'settings.advanced.rows_per_commit',
          label: (value) => '$value',
        ),
        (
          setting: AdvancedSettings.refreshIntervalDays,
          key: 'settings.advanced.refresh_interval',
          label: (value) => AppStrings.text(
            value == 1
                ? 'settings.advanced.days.one'
                : 'settings.advanced.days.other',
            {'count': value},
          ),
        ),
        (
          setting: AdvancedSettings.checkLeadMinutes,
          key: 'settings.advanced.check_lead',
          label: (value) => AppStrings.text('alarm.duration', {'minutes': value}),
        ),
      ];

  Future<void> _set(AdvancedSetting setting, int value) async {
    await AdvancedSettings.set(setting, value);
    if (setting == AdvancedSettings.checkLeadMinutes) await _applyCheckLead();
    if (mounted) setState(() {});
  }

  Future<void> _reset() async {
    await AdvancedSettings.resetToDefaults();
    await _applyCheckLead();
    if (mounted) setState(() {});
  }

  /// The alarm checks read the lead time from each alarm, so it's copied on.
  Future<void> _applyCheckLead() => AlarmStorageService()
      .setCheckLeadMinutes(AdvancedSettings.value(AdvancedSettings.checkLeadMinutes));

  bool _exporting = false;

  /// Copies the app's data where the user can reach it; see AppDataExport.
  Future<void> _export() async {
    setState(() => _exporting = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await AppDataExport.export();
      messenger.showSnackBar(
        SnackBar(
          content: Text(AppStrings.text('settings.advanced.export.done')),
        ),
      );
    } catch (e) {
      debugPrint('App data export failed: $e');
      messenger.showSnackBar(
        SnackBar(
          content: Text(AppStrings.text('settings.advanced.export.failed')),
        ),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppShell(
      title: AppStrings.text('settings.advanced'),
      selectedTab: 2,
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          for (final row in _rows)
            ListTile(
              title: Text(AppStrings.text(row.key)),
              subtitle: Text(
                AppStrings.text('${row.key}.description', {
                  'default': row.label(row.setting.defaultValue),
                }),
              ),
              trailing: DropdownButton<int>(
                value: AdvancedSettings.value(row.setting),
                onChanged: (value) {
                  if (value != null) _set(row.setting, value);
                },
                items: [
                  for (final choice in row.setting.choices)
                    DropdownMenuItem(
                      value: choice,
                      child: Text(row.label(choice)),
                    ),
                ],
              ),
            ),
          ListTile(
            title: Text(AppStrings.text('settings.advanced.export')),
            subtitle: Text(
              AppStrings.text(
                Platform.isIOS
                    ? 'settings.advanced.export.description'
                    : 'settings.advanced.export.description.android',
              ),
            ),
            trailing: _exporting
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_alt),
            onTap: _exporting ? null : _export,
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: OutlinedButton(
              onPressed: _reset,
              child: Text(AppStrings.text('settings.advanced.reset')),
            ),
          ),
        ],
      ),
    );
  }
}
