import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:transport_alarm/l10n/app_strings.dart';
import 'package:transport_alarm/l10n/app_language_state.dart';
import 'package:transport_alarm/services/app_group_storage.dart';
import 'package:transport_alarm/screens/loading_screen.dart';
import 'package:transport_alarm/transit/progress_callback.dart';
import 'package:transport_alarm/provider_registry.dart';
import 'package:transport_alarm/transit_bootstrap.dart';
import 'package:transport_alarm/transit/services/locale_selection_service.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:transport_alarm/widgets/app_shell.dart';

/// Settings landing page; language selection is implemented as a child page.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final options = <({IconData icon, String title})>[
      (icon: Icons.language, title: 'settings.app_language'),
      (icon: Icons.public, title: 'settings.enabled_locales'),
      (icon: Icons.public, title: 'settings.transit_locale'),
      (icon: Icons.access_time, title: 'settings.time_zone'),
      (icon: Icons.notifications_outlined, title: 'settings.notifications'),
      (icon: Icons.info_outline, title: 'settings.about'),
      (icon: Icons.download, title: 'drawer.reload_data'),
      (icon: Icons.refresh, title: 'drawer.refresh_data'),
    ];

    return AppShell(
      title: AppStrings.text('settings.title'),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          for (final option in options)
            ListTile(
              leading: Icon(option.icon),
              title: Text(AppStrings.text(option.title)),
              subtitle: option.title == 'settings.app_language'
                  ? Text(AppStrings.text('settings.app_language.subtitle'))
                  : option.title == 'settings.enabled_locales'
                  ? Text(AppStrings.text('settings.enabled_locales.subtitle'))
                  : option.title.startsWith('settings.')
                  ? Text(AppStrings.text('common.coming_soon'))
                  : null,
              onTap: () {
                switch (option.title) {
                  case 'settings.app_language':
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const AppLanguageSettingsScreen(),
                      ),
                    );
                    break;
                  case 'settings.enabled_locales':
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const EnabledLocalesSettingsScreen(),
                      ),
                    );
                    break;
                  case 'drawer.reload_data':
                    _openDataOperation(
                      context,
                      operation: initializeTransitData,
                      forceRefresh: true,
                    );
                    break;
                  case 'drawer.refresh_data':
                    _openDataOperation(
                      context,
                      operation: refreshStaleProviders,
                    );
                    break;
                }
              },
            ),
        ],
      ),
    );
  }
}

/// Lets the user select the app interface language and save it explicitly.
class AppLanguageSettingsScreen extends StatefulWidget {
  const AppLanguageSettingsScreen({super.key});

  @override
  State<AppLanguageSettingsScreen> createState() =>
      _AppLanguageSettingsScreenState();
}

class _AppLanguageSettingsScreenState extends State<AppLanguageSettingsScreen> {
  static const _languages = <({String code, String name})>[
    (code: 'en', name: "English"),
    (code: 'zh-Hant', name: "正體中文"),
    (code: 'zh-Hans', name: "简体中文"),
    (code: 'ja', name: "日本語"),
    (code: 'fr', name: "Français"),
    (code: 'es', name: "Español"),
    (code: 'de', name: "Deutsch"),
    (code: 'nl', name: "Nederlands"),
    (code: 'it', name: "Italiano"),
    (code: 'pl', name: "Polski"),
    (code: 'ko', name: "한국어"),
    (code: 'uk', name: "Українська"),
  ];

  final _selectionService = LocaleSelectionService();
  String? _selectedCode;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadSelection();
  }

  /// Loads saved locale and ATCO selections and groups ATCO areas by region.
  Future<void> _loadSelection() async {
    final code = await _selectionService.getAppLanguageCode();
    if (!mounted) return;
    setState(() => _selectedCode = code);
  }

  Future<void> _confirmSelection() async {
    final code = _selectedCode;
    if (code == null || _saving) return;

    setState(() => _saving = true);
    await _selectionService.setAppLanguageCode(code);
    await AppStrings.load(code);
    await AppGroupStorage.setAppLanguageCode(code);
    appLanguageCodeNotifier.value = code;
    if (mounted) {
      appNavigatorKey.currentState?.pushNamedAndRemoveUntil(
        '/settings',
        (_) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppShell(
      title: AppStrings.text('settings.app_language'),
      selectedTab: 2,
      actions: [
        IconButton(
          tooltip: AppStrings.text('common.done'),
          onPressed: _selectedCode == null || _saving
              ? null
              : _confirmSelection,
          icon: _saving
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.check),
        ),
      ],
      body: RadioGroup<String>(
        groupValue: _selectedCode,
        onChanged: (code) {
          if (_saving) return;
          setState(() => _selectedCode = code);
        },
        child: ListView(
          children: [
            for (final language in _languages)
              RadioListTile<String>(
                value: language.code,
                title: Text(language.name),
              ),
          ],
        ),
      ),
    );
  }
}

Future<void> _openDataOperation(
  BuildContext context, {
  required TransitOperation operation,
  bool forceRefresh = false,
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => LoadingScreen(
        operation: operation,
        forceRefresh: forceRefresh,
        returnToPrevious: true,
        showBottomNavigation: true,
      ),
    ),
  );
}

/// Controls which regional transit databases and providers the app uses.
class EnabledLocalesSettingsScreen extends StatefulWidget {
  const EnabledLocalesSettingsScreen({super.key});

  @override
  State<EnabledLocalesSettingsScreen> createState() =>
      _EnabledLocalesSettingsScreenState();
}

class _EnabledLocalesSettingsScreenState
    extends State<EnabledLocalesSettingsScreen> {
  final _selectionService = LocaleSelectionService();
  Set<String> _selected = {};
  Set<String> _selectedAtcoCodes = {};
  Map<String, List<({String code, String name})>> _atcoByRegion = {};
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadSelection();
  }

  Future<void> _loadSelection() async {
    final enabled = await _selectionService.getEnabledLocales();
    final enabledAtcoCodes = await _selectionService.getEnabledAtcoCodes();
    final atcoJson = await rootBundle.loadString(
      'lib/transit/locale/uk/atco.json',
    );
    final atcoAreas = jsonDecode(atcoJson) as Map<String, dynamic>;
    final byRegion = <String, List<({String code, String name})>>{};
    for (final entry in atcoAreas.entries) {
      final area = Map<String, dynamic>.from(entry.value as Map);
      final region = area['region'] as String;
      byRegion.putIfAbsent(region, () => []).add((
        code: entry.key,
        name: area['name'] as String,
      ));
    }
    for (final areas in byRegion.values) {
      areas.sort((a, b) => a.name.compareTo(b.name));
    }
    if (!mounted) return;
    setState(() {
      _selected = enabled.toSet();
      _selectedAtcoCodes = enabledAtcoCodes.toSet();
      _atcoByRegion = byRegion;
      _loading = false;
    });
  }

  /// Saves the locale selection, refreshes added data, and removes disabled data.
  Future<void> _saveSelection() async {
    if (_saving) return;
    setState(() => _saving = true);
    final previous = (await _selectionService.getEnabledLocales()).toSet();
    final previousAtcoCodes = (await _selectionService.getEnabledAtcoCodes())
        .toSet();
    final nextAtcoCodes = _selectedAtcoCodes.toList()..sort();
    final nextSet = _selected.toSet();
    if (nextAtcoCodes.isNotEmpty) {
      nextSet.add('uk');
    } else {
      nextSet.remove('uk');
    }
    final next = nextSet.toList()..sort();
    final localesToRefresh = nextSet.difference(previous).toSet();
    if (!previousAtcoCodes.containsAll(nextAtcoCodes) ||
        !nextAtcoCodes.toSet().containsAll(previousAtcoCodes)) {
      if (nextSet.contains('uk')) localesToRefresh.add('uk');
    }
    final localesToRemove = previous.difference(nextSet);
    await _selectionService.setEnabledLocales(next);
    await _selectionService.setEnabledAtcoCodes(nextAtcoCodes);
    if (!mounted) return;

    final navigator = Navigator.of(context);
    navigator.pop();
    if (localesToRefresh.isNotEmpty || localesToRemove.isNotEmpty) {
      /// Applies the requested data changes and rolls back selection on failure.
      Future<List<String>> applySelectedData({
        ProgressCallback? onProgress,
        bool forceRefresh = false,
      }) async {
        /// Restores the saved locale and ATCO selections after a failed refresh.
        Future<void> restorePreviousSelection() async {
          await _selectionService.setEnabledLocales(previous.toList()..sort());
          await _selectionService.setEnabledAtcoCodes(
            previousAtcoCodes.toList()..sort(),
          );
        }

        // A retry starts from the requested selection even when the earlier
        // attempt rolled it back after a failed network request.
        await _selectionService.setEnabledLocales(next);
        await _selectionService.setEnabledAtcoCodes(nextAtcoCodes);
        try {
          final failures = localesToRefresh.isEmpty
              ? <String>[]
              : await initializeTransitData(
                  onProgress: onProgress,
                  forceRefresh: forceRefresh,
                  onlyLocales: localesToRefresh.toList(),
                );
          if (failures.isNotEmpty) {
            await restorePreviousSelection();
            return failures;
          }
          for (final locale in localesToRemove) {
            await GtfsDatabase.forLocale(locale).resetDatabase();
          }
          return failures;
        } catch (_) {
          await restorePreviousSelection();
          rethrow;
        }
      }

      await navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => LoadingScreen(
            operation: applySelectedData,
            returnToPrevious: true,
            showBottomNavigation: true,
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final localeCodes =
        providersByLocale.keys.where((code) => code != 'uk').toList()..sort();
    final allAtcoCodes = _atcoByRegion.values
        .expand((areas) => areas.map((area) => area.code))
        .toSet();
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
                  key: const PageStorageKey<String>('enabled-uk-atco-areas'),
                  leading: Checkbox(
                    tristate: true,
                    value: _checkboxState(allAtcoCodes),
                    onChanged: _saving
                        ? null
                        : (_) => _toggleAtcoCodes(allAtcoCodes),
                  ),
                  title: Text(
                    AppStrings.text('settings.locale.united_kingdom'),
                  ),
                  children: [
                    for (final region in _atcoByRegion.keys.toList()..sort())
                      _buildAtcoRegion(region, _atcoByRegion[region]!),
                  ],
                ),
              ],
            ),
    );
  }

  /// Builds a region row whose checkbox controls every ATCO area beneath it.
  Widget _buildAtcoRegion(
    String region,
    List<({String code, String name})> areas,
  ) {
    final codes = areas.map((area) => area.code).toSet();
    return ExpansionTile(
      key: PageStorageKey<String>('enabled-uk-atco-region-$region'),
      leading: Checkbox(
        tristate: true,
        value: _checkboxState(codes),
        onChanged: _saving ? null : (_) => _toggleAtcoCodes(codes),
      ),
      title: Text(region),
      children: [
        for (final area in areas)
          CheckboxListTile(
            value: _selectedAtcoCodes.contains(area.code),
            title: Text(area.name),
            subtitle: Text(area.code),
            onChanged: _saving
                ? null
                : (enabled) => _setAtcoCodes({area.code}, enabled == true),
          ),
      ],
    );
  }

  /// Returns checked, unchecked, or mixed state for a parent checkbox.
  bool? _checkboxState(Set<String> codes) {
    final selectedCount = codes.intersection(_selectedAtcoCodes).length;
    if (selectedCount == 0) return false;
    if (selectedCount == codes.length) return true;
    return null;
  }

  /// Adds or removes the specified ATCO area codes from the pending selection.
  void _setAtcoCodes(Set<String> codes, bool enabled) {
    setState(() {
      if (enabled) {
        _selectedAtcoCodes.addAll(codes);
      } else {
        _selectedAtcoCodes.removeAll(codes);
      }
    });
  }

  /// Toggles a group of ATCO codes as one selection.
  void _toggleAtcoCodes(Set<String> codes) {
    _setAtcoCodes(codes, _checkboxState(codes) != true);
  }
}
