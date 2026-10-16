import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:transport_alarm/locale_registry.dart';

import '../../l10n/app_strings.dart';
import '../../transit/services/locale_selection_service.dart';
import '../../transit_bootstrap.dart';
import '../../widgets/app_shell.dart';
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
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadSelection();
  }

  Future<void> _loadSelection() async {
    await _selectionService.beginLocaleSelectionDraft();
    if (!mounted) return;
    setState(() {
      _loading = false;
    });
  }

  Future<void> _saveSelection() async {
    if (_saving) return;

    setState(() => _saving = true);
    final previous = await _selectionService.getEnabledLocales();
    final draft = await _selectionService.getLocaleSelectionDraft();
    final selectionChanged = !mapEquals(previous, draft);
    await _selectionService.commitLocaleSelectionDraft();
    if (!mounted) return;

    final navigator = Navigator.of(context);
    navigator.pop();
    if (selectionChanged) {
      await navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const LoadingScreen(
            operation: initializeTransitData,
            returnToPrevious: true,
            showBottomNavigation: true,
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final locales = LocaleRegistry.getSupportedLocales()..sort();
    return AppShell(
      title: AppStrings.text('settings.enabled_locales'),
      selectedTab: 2,
      actions: [
        IconButton(
          tooltip: AppStrings.text('common.done'),
          onPressed: _loading || _saving ? null : _saveSelection,
          icon: _saving
              ? const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
              : const Icon(Icons.check),
        ),
      ],
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
        children: locales.map((l) => l.menuEntry).toList()
      ),
    );
  }
}
