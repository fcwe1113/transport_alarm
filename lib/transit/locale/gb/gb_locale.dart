import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:transport_alarm/transit/locale/gb/gb_gtfs_sync_provider.dart';

import '../../../l10n/app_strings.dart';
import '../../models/locale_config.dart';
import '../../services/api_caller.dart';
import '../../services/gtfs_sync_service.dart';
import '../../services/locale_selection_service.dart';
import '../../transit_provider.dart';
import '../transit_locale.dart';

class GbLocale extends TransitLocale {
  final apiCaller = ApiCaller();

  @override
  LocaleConfig config = LocaleConfig(
    code: 'gb',
    displayName: {"en": 'United Kingdom'},
    timeZoneIdentifier: 'Europe/London',
  );

  @override
  List<GtfsSyncProvider> gtfsProviders = [GbGtfsSyncProvider()];

  @override
  late Widget menuEntry = _AtcoListMenuEntry(config: config);

  @override
  late List<TransitProvider> transitProviders = []; // todo fill

  @override
  bool matchingRequired = false;
}

class _AtcoListMenuEntry extends StatefulWidget {
  const _AtcoListMenuEntry({required this.config});

  final LocaleConfig config;

  @override
  State<_AtcoListMenuEntry> createState() => _AtcoListMenuEntryState();
}

class _AtcoListMenuEntryState extends State<_AtcoListMenuEntry> {
  final _selectionService = LocaleSelectionService();
  late Set<String> _selected; // if list empty treat as locale unselected
  late Map<String, List<({String code, String name})>> _atcoByRegion;
  bool _loaded = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadSelection();
  }

  Future<void> _loadAtco() async {
    final atcoAreas = jsonDecode(await rootBundle.loadString("lib/transit/locale/gb/atco.json")) as Map<String, dynamic>;
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
    if(!mounted) return;
    setState(() {
      _atcoByRegion = byRegion;
    });
  }

  Future<void> _loadSelection() async {
    await _loadAtco();
    final enabledLocales = await _selectionService.getLocaleSelectionDraft();
    if (!mounted) return;
    if (enabledLocales.containsKey(widget.config.code)) {
      _selected = enabledLocales[widget.config.code]!.split(",").toSet();
    } else {
      _selected = <String>{};
    }
    setState(() {
      _loaded = true;
    });
  }

  /// Updates the UK locale's temporary selection for the confirmation screen.
  void _saveSelected(Set<String> selected) {
    _selectionService.updateLocaleSelectionDraftEntry(
      widget.config.code,
      selected.isNotEmpty ? selected.join(",") : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const Center(child: CircularProgressIndicator(),);
    final List<String> allAtcoCodes = _atcoByRegion.values
        .expand((areas) => areas.map((area) => area.code))
        .toList();
    return ExpansionTile(
          key: const PageStorageKey<String>('enabled-uk-atco-areas'),
          leading: Checkbox(
            tristate: true,
            value: _checkboxState(allAtcoCodes.toSet()),
            onChanged: _saving
                ? null
                : (_) => _toggleAtcoCodes(allAtcoCodes.toSet()),
          ),
          title: Text(
            AppStrings.text('settings.locale.united_kingdom'),
          ),
          children: [
            for (final region in _atcoByRegion.keys.toList()..sort())
              _buildAtcoRegion(region, _atcoByRegion[region]!),
          ],
    );
  }

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
            value: _selected.contains(area.code),
            title: Text(area.name),
            // subtitle: Text(area.code),
            onChanged: _saving
                ? null
                : (enabled) => _setAtcoCodes({area.code}, enabled == true),
          ),
      ],
    );
  }

  bool? _checkboxState(Set<String> codes) {
    final selectedCount = codes.intersection(_selected.toSet()).length;
    if (selectedCount == 0) return false;
    if (selectedCount == codes.length) return true;
    return null;
  }

  void _setAtcoCodes(Set<String> codes, bool enabled) {
    setState(() {
      if (enabled) {
        _selected.addAll(codes);
      } else {
        _selected.removeAll(codes);
      }
      _saveSelected(Set<String>.from(_selected));
    });
  }

  void _toggleAtcoCodes(Set<String> codes) {
    _setAtcoCodes(codes, _checkboxState(codes) != true);
  }

}
