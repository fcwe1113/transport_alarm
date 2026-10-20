import 'package:flutter/material.dart';
import 'package:transport_alarm/l10n/app_strings.dart';
import 'package:transport_alarm/transit/locale/hk/providers/ctb_provider.dart';
import 'package:transport_alarm/transit/locale/hk/providers/kmb_provider.dart';
import 'package:transport_alarm/transit/models/locale_config.dart';
import 'package:transport_alarm/transit/services/api_caller.dart';
import 'package:transport_alarm/transit/services/gtfs_sync_service.dart';
import 'package:transport_alarm/transit/services/locale_selection_service.dart';
import 'package:transport_alarm/transit/transit_provider.dart';

import '../transit_locale.dart';
import 'hk_gtfs_sync_provider.dart';

/// Hong Kong: the Transport Department's GTFS timetable, with KMB and
/// Citybus for routes, stops and live arrivals. Operator stops are matched
/// to GTFS stops after each refresh.
class HkLocale extends TransitLocale {
  final _apiCaller = ApiCaller();

  @override
  final LocaleConfig config = const LocaleConfig(
    code: 'hk',
    displayName: {"en": 'Hong Kong'},
    timeZoneIdentifier: 'Asia/Hong_Kong',
  );

  @override
  final List<GtfsSyncProvider> gtfsProviders = [HkGtfsSyncProvider()];

  @override
  late final Widget menuEntry = _LocaleCheckboxMenuEntry(config: config);

  @override
  late final List<TransitProvider> transitProviders = [KmbProvider(_apiCaller), CtbProvider(_apiCaller)];

  @override
  bool get matchingRequired => true;

  @override
  bool get gtfsOnly => false;
}

/// Hong Kong's entry in the region pickers: one checkbox for the whole
/// region, saved as an empty draft value when ticked.
class _LocaleCheckboxMenuEntry extends StatefulWidget {
  const _LocaleCheckboxMenuEntry({required this.config});

  final LocaleConfig config;

  @override
  State<_LocaleCheckboxMenuEntry> createState() =>
      _LocaleCheckboxMenuEntryState();
}

class _LocaleCheckboxMenuEntryState extends State<_LocaleCheckboxMenuEntry> {
  final _selectionService = LocaleSelectionService();
  bool _selected = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadSelection();
  }

  Future<void> _loadSelection() async {
    final enabledLocales = await _selectionService.getLocaleSelectionDraft();
    if (!mounted) return;
    setState(() {
      _selected = enabledLocales.containsKey(widget.config.code);
      _loaded = true;
    });
  }

  void _setSelected(bool selected) {
    setState(() => _selected = selected);
    _selectionService.updateLocaleSelectionDraftEntry(
      widget.config.code,
      selected ? "" : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    return CheckboxListTile(
      title: Text(AppStrings.text('settings.locale.hong_kong')),
      value: _selected,
      onChanged: _loaded ? (checked) => _setSelected(checked == true) : null,
    );
  }
}
