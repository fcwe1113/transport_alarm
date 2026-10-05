import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';
import '../../provider_registry.dart';
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

class _EnabledLocalesSettingsScreenState
    extends State<EnabledLocalesSettingsScreen> {
  static const _ukRegions = <String>[
    'East Midlands',
    'East Anglia',
    'London',
    'North East',
    'North West',
    'Scotland',
    'South East',
    'South West',
    'Wales',
    'West Midlands',
    'Yorkshire',
  ];

  final _selectionService = LocaleSelectionService();
  Set<String> _selected = {};
  Set<String> _selectedUkRegions = {};
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadSelection();
  }

  Future<void> _loadSelection() async {
    final enabled = await _selectionService.getEnabledLocales();
    final enabledUkRegions = await _selectionService.getEnabledUkRegions();
    if (!mounted) return;
    setState(() {
      _selected = enabled.toSet();
      _selectedUkRegions = enabledUkRegions.toSet();
      _loading = false;
    });
  }

  Future<void> _saveSelection() async {
    if (_saving) return;
    if (_selected.isEmpty && _selectedUkRegions.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppStrings.text('settings.enabled_locales.required')),
        ),
      );
      return;
    }

    setState(() => _saving = true);
    final previous = (await _selectionService.getEnabledLocales()).toSet();
    final previousUkRegions = (await _selectionService.getEnabledUkRegions())
        .toSet();
    final next = _selected.toList()..sort();
    final addedLocales = next.toSet().difference(previous);
    final nextUkRegions = _selectedUkRegions.toList()..sort();
    final ukRegionsChanged = !setEquals(
      previousUkRegions,
      nextUkRegions.toSet(),
    );
    await _selectionService.setEnabledLocales(next);
    await _selectionService.setEnabledUkRegions(nextUkRegions);
    if (!mounted) return;

    final navigator = Navigator.of(context);
    navigator.pop();
    if (addedLocales.isNotEmpty || ukRegionsChanged) {
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
    final localeCodes = providersByLocale.keys.toList()..sort();
    final allUkRegions = _ukRegions.map(_ukRegionKey).toSet();
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
        children: [
          for (final code in localeCodes)
            CheckboxListTile(
              value: _selected.contains(code),
              title: Text(localeConfigs[code]?.displayName ?? code),
              onChanged: _saving
                  ? null
                  : (enabled) => setState(() {
                if (enabled == true) {
                  _selected.add(code);
                } else {
                  _selected.remove(code);
                }
              }),
            ),
          ExpansionTile(
            key: const PageStorageKey<String>('enabled-uk-regions'),
            leading: Checkbox(
              tristate: true,
              value: _checkboxState(allUkRegions),
              onChanged: _saving
                  ? null
                  : (_) => _toggleUkRegions(allUkRegions),
            ),
            title: Text(
              AppStrings.text('settings.locale.united_kingdom'),
            ),
            children: [
              for (final region in _ukRegions)
                CheckboxListTile(
                  value: _selectedUkRegions.contains(
                    _ukRegionKey(region),
                  ),
                  title: Text(region),
                  onChanged: _saving
                      ? null
                      : (enabled) => _setUkRegions({
                    _ukRegionKey(region),
                  }, enabled == true),
                ),
            ],
          ),
        ],
      ),
    );
  }

  String _ukRegionKey(String region) =>
      region.toLowerCase().replaceAll(RegExp(r'\s+'), '_');

  bool? _checkboxState(Set<String> regions) {
    final selectedCount = regions.intersection(_selectedUkRegions).length;
    if (selectedCount == 0) return false;
    if (selectedCount == regions.length) return true;
    return null;
  }

  void _setUkRegions(Set<String> regions, bool enabled) {
    setState(() {
      if (enabled) {
        _selectedUkRegions.addAll(regions);
      } else {
        _selectedUkRegions.removeAll(regions);
      }
    });
  }

  void _toggleUkRegions(Set<String> regions) {
    _setUkRegions(regions, _checkboxState(regions) != true);
  }
}