import 'package:flutter/material.dart';
import 'package:transport_alarm/locale_registry.dart';

import '../../l10n/app_strings.dart';
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
  /// region that was only turned off keeps its data, and needs nothing.
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
    // A download uses data, so warn first. Going back keeps the user on this
    // screen with their unsaved changes.
    if (toDownload.isNotEmpty) {
      if (!mounted) return;
      if (!await showDataUsageWarning(context)) {
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
    if (toDownload.isNotEmpty) {
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
            onSucceeded: _selectionService.clearPendingLocaleChange,
          ),
        ),
      );
    }
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
