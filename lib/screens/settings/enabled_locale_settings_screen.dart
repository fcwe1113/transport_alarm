import 'package:flutter/material.dart';
import 'package:transport_alarm/locale_registry.dart';

import '../../l10n/app_strings.dart';
import '../../services/region_cleanup_service.dart';
import '../../transit/services/locale_selection_service.dart';
import '../../transit_bootstrap.dart';
import '../../widgets/app_shell.dart';
import '../../widgets/data_usage_warning.dart';
import '../loading_screen.dart';

/// Controls which regional transit databases and providers the app uses.
class EnabledLocalesSettingsScreen extends StatefulWidget {
  const EnabledLocalesSettingsScreen({super.key});

  @override
  State<EnabledLocalesSettingsScreen> createState() =>
      _EnabledLocalesSettingsScreenState();
}

class _EnabledLocalesSettingsScreenState extends State<EnabledLocalesSettingsScreen> {
  final _selectionService = LocaleSelectionService();
  final _locales = LocaleRegistry.getSupportedLocales()..sort();
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadSelection();
  }

  /// Starts a draft from the enabled regions; the menu entries edit it.
  Future<void> _loadSelection() async {
    await _selectionService.beginLocaleSelectionDraft();
    if (!mounted) return;
    setState(() {
      _loading = false;
    });
  }

  /// Saves the draft, leaves this page and downloads data for the regions
  /// that need it: newly enabled ones, and GB when its areas changed. A
  /// region turned off has its alarms and data deleted, once any download
  /// has succeeded, so a failed change leaves everything as it was.
  Future<void> _saveSelection() async {
    if (_saving) return;

    setState(() => _saving = true);
    final previous = await _selectionService.getEnabledLocales();
    final draft = await _selectionService.getLocaleSelectionDraft();
    // The app needs at least one region; the check button is disabled too.
    if (draft.isEmpty) {
      if (mounted) setState(() => _saving = false);
      return;
    }
    final toDownload = {
      for (final entry in draft.entries)
        if (previous[entry.key] != entry.value) entry.key,
    };
    final removed = previous.keys.toSet().difference(draft.keys.toSet());
    final cleanup = RegionCleanupService();

    // Going back from either warning keeps the user on this screen with their
    // unsaved changes.
    final affectedAlarms = await cleanup.alarmsInRegions(removed);
    if (affectedAlarms.isNotEmpty) {
      if (!mounted) return;
      if (!await _confirmAlarmRemoval(affectedAlarms.length)) {
        if (mounted) setState(() => _saving = false);
        return;
      }
    }
    // A download uses data, so warn first.
    if (toDownload.isNotEmpty) {
      if (!mounted) return;
      if (!await showDataUsageWarning(context, selection: {
        for (final code in toDownload) code: draft[code]!,
      })) {
        if (mounted) setState(() => _saving = false);
        return;
      }
      // If the app is killed before the download ends, the next launch goes
      // back to [previous] (see rollBackUnfinishedLocaleChange).
      await _selectionService.markLocaleChangePending(previous);
    }
    await _selectionService.commitLocaleSelectionDraft();
    if (!mounted) return;

    final navigator = Navigator.of(context);
    navigator.pop();
    if (toDownload.isEmpty) {
      await cleanup.removeRegions(removed);
    } else {
      // Regions kept but with changed options (GB's areas), whose alarms may
      // now point at stops or routes the new data doesn't have.
      final changedOptions = toDownload.intersection(previous.keys.toSet());
      var alarmsDeleted = 0;
      var alarmsTrimmed = 0;
      // The app's messenger outlives this screen and the loading screen.
      final messenger = ScaffoldMessenger.maybeOf(navigator.context);
      await navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => LoadingScreen(
            operation: ({onProgress, forceRefresh = false, cancelToken}) => initializeTransitData(
              onProgress: onProgress,
              forceRefresh: forceRefresh,
              cancelToken: cancelToken,
              onlyLocales: toDownload,
            ),
            returnToPrevious: true,
            // No tabs to leave by: the change must finish, fail or be
            // cancelled here, so it can be undone if it doesn't succeed.
            showBottomNavigation: false,
            cancellable: true,
            // A cancelled or failed download leaves the installed data as it
            // was, so restore the selection that matches it.
            onAbandon: () async {
              await _selectionService.setEnabledLocales(previous);
              await _selectionService.clearPendingLocaleChange();
            },
            onSucceeded: () async {
              await _selectionService.clearPendingLocaleChange();
              await cleanup.removeRegions(removed);
              for (final code in changedOptions) {
                final pruned = await cleanup.pruneAlarmsWithMissingRoutes(code);
                alarmsDeleted += pruned.deleted;
                alarmsTrimmed += pruned.trimmed;
              }
            },
          ),
        ),
      );
      final notices = [
        if (alarmsDeleted > 0) AppStrings.text('locale_change.alarms_deleted', {'count': alarmsDeleted}),
        if (alarmsTrimmed > 0) AppStrings.text('locale_change.alarms_trimmed', {'count': alarmsTrimmed}),
      ];
      if (notices.isNotEmpty) {
        messenger?.showSnackBar(SnackBar(content: Text(notices.join("\n"))));
      }
    }
  }

  /// Asks before deleting the [count] alarms in the regions turned off.
  Future<bool> _confirmAlarmRemoval(int count) async {
    final proceed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(AppStrings.text('locale_change.remove_alarms.title')),
        content: Text(AppStrings.text('locale_change.remove_alarms.body', {'count': count})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(AppStrings.text('common.go_back'))),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text(AppStrings.text('common.continue'))),
        ],
      ),
    );
    return proceed == true;
  }

  @override
  Widget build(BuildContext context) {
    return AppShell(
      title: AppStrings.text('settings.enabled_locales'),
      selectedTab: 2,
      actions: [
        // Disabled while no region is picked, as the app needs at least one.
        ValueListenableBuilder<Map<String, String>>(
          valueListenable: LocaleSelectionService.localeSelectionDraftListenable,
          builder: (context, draft, _) => IconButton(
            tooltip: AppStrings.text('common.done'),
            onPressed: _loading || _saving || draft.isEmpty ? null : _saveSelection,
            icon: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check),
          ),
        ),
      ],
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(children: [for (final locale in _locales) locale.menuEntry]),
    );
  }
}
