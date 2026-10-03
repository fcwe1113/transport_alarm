import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:transport_alarm/l10n/app_strings.dart';
import 'package:transport_alarm/l10n/app_language_state.dart';
import 'package:transport_alarm/services/app_group_storage.dart';
import 'package:transport_alarm/screens/loading_screen.dart';
import 'package:transport_alarm/transit/progress_callback.dart';
import 'package:transport_alarm/provider_registry.dart';
import 'package:transport_alarm/transit_bootstrap.dart';
import 'package:transport_alarm/transit/services/locale_selection_service.dart';
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
