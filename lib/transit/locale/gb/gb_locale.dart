import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:transport_alarm/transit/locale/gb/gb_gtfs_sync_provider.dart';
import 'package:transport_alarm/transit/locale/gb/providers/gb_bods_provider.dart';

import '../../../l10n/app_strings.dart';
import '../../models/locale_config.dart';
import '../../services/gtfs_sync_service.dart';
import '../../services/locale_selection_service.dart';
import '../../transit_provider.dart';
import '../transit_locale.dart';

/// Great Britain: BODS timetables and live bus locations, imported only for
/// the ATCO areas (council areas) picked in its menu entry.
class GbLocale extends TransitLocale {
  @override
  final LocaleConfig config = const LocaleConfig(
    code: 'gb',
    displayName: {"en": 'United Kingdom'},
    timeZoneIdentifier: 'Europe/London',
  );

  @override
  final List<GtfsSyncProvider> gtfsProviders = [GbGtfsSyncProvider()];

  @override
  late final Widget menuEntry = _AtcoListMenuEntry(config: config);

  @override
  late final List<TransitProvider> transitProviders = [GbBodsProvider()];

  @override
  bool get matchingRequired => false;

  @override
  bool get gtfsOnly => true;
}

typedef _AtcoArea = ({String code, String name});

/// The UK entry in the region pickers: a tree of BODS regions and their
/// ATCO areas, each with a checkbox. The picked area codes are saved,
/// comma-separated, as the locale's draft selection; none leaves it off.
class _AtcoListMenuEntry extends StatefulWidget {
  const _AtcoListMenuEntry({required this.config});

  final LocaleConfig config;

  @override
  State<_AtcoListMenuEntry> createState() => _AtcoListMenuEntryState();
}

class _AtcoListMenuEntryState extends State<_AtcoListMenuEntry> {
  final _selectionService = LocaleSelectionService();
  Set<String> _selected = {};
  Map<String, List<_AtcoArea>> _atcoByRegion = {};
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadSelection();
  }

  /// The areas in lib/transit/locale/gb/atco.json, grouped by region and
  /// sorted by name.
  Future<Map<String, List<_AtcoArea>>> _loadAtco() async {
    final atcoAreas = jsonDecode(await rootBundle.loadString("lib/transit/locale/gb/atco.json")) as Map<String, dynamic>;
    final byRegion = <String, List<_AtcoArea>>{};
    for (final entry in atcoAreas.entries) {
      final area = Map<String, dynamic>.from(entry.value as Map);
      byRegion.putIfAbsent(area['region'] as String, () => []).add((
        code: entry.key,
        name: area['name'] as String,
      ));
    }
    for (final areas in byRegion.values) {
      areas.sort((a, b) => a.name.compareTo(b.name));
    }
    return byRegion;
  }

  Future<void> _loadSelection() async {
    final byRegion = await _loadAtco();
    final draft = await _selectionService.getLocaleSelectionDraft();
    if (!mounted) return;
    setState(() {
      _atcoByRegion = byRegion;
      _selected = (draft[widget.config.code] ?? '')
          .split(",")
          .where((code) => code.isNotEmpty)
          .toSet();
      _loaded = true;
    });
  }

  /// Updates the UK locale's draft selection for the confirmation screen.
  void _saveSelected(Set<String> selected) {
    _selectionService.updateLocaleSelectionDraftEntry(
      widget.config.code,
      selected.isNotEmpty ? selected.join(",") : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const Center(child: CircularProgressIndicator(),);
    final allAtcoCodes = _atcoByRegion.values
        .expand((areas) => areas.map((area) => area.code))
        .toSet();
    return ExpansionTile(
      key: const PageStorageKey<String>('enabled-uk-atco-areas'),
      leading: Checkbox(
        tristate: true,
        value: _checkboxState(allAtcoCodes),
        onChanged: (_) => _toggleAtcoCodes(allAtcoCodes),
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

  Widget _buildAtcoRegion(String region, List<_AtcoArea> areas) {
    final codes = areas.map((area) => area.code).toSet();
    return ExpansionTile(
      key: PageStorageKey<String>('enabled-uk-atco-region-$region'),
      leading: Checkbox(
        tristate: true,
        value: _checkboxState(codes),
        onChanged: (_) => _toggleAtcoCodes(codes),
      ),
      title: Text(region),
      children: [
        for (final area in areas)
          CheckboxListTile(
            value: _selected.contains(area.code),
            title: Text(area.name),
            onChanged: (enabled) => _setAtcoCodes({area.code}, enabled == true),
          ),
      ],
    );
  }

  /// Ticked when every one of [codes] is picked, empty when none is, and
  /// dashed (null) in between.
  bool? _checkboxState(Set<String> codes) {
    final selectedCount = codes.intersection(_selected).length;
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

  /// Picks all of [codes], or clears them all if they're already all picked.
  void _toggleAtcoCodes(Set<String> codes) {
    _setAtcoCodes(codes, _checkboxState(codes) != true);
  }
}
