import 'package:flutter/material.dart';
import 'package:transport_alarm/transit/locale/hk/providers/ctb_provider.dart';
import 'package:transport_alarm/transit/locale/hk/providers/kmb_provider.dart';
import 'package:transport_alarm/transit/models/locale_config.dart';
import 'package:transport_alarm/transit/services/api_caller.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:transport_alarm/transit/services/gtfs_sync_service.dart';
import 'package:transport_alarm/transit/services/locale_selection_service.dart';
import 'package:transport_alarm/transit/transit_provider.dart';

import '../transit_locale.dart';
import 'hk_gtfs_sync_provider.dart';

class HkLocale implements TransitLocale {

  final apiCaller = ApiCaller();

  @override
  LocaleConfig config = LocaleConfig(
  code: 'hk',
  displayName: 'Hong Kong',
  timeZoneIdentifier: 'Asia/Hong_Kong',
  );

  @override
  List<GtfsSyncProvider> gtfsProviders = [HkGtfsSyncProvider()];

  @override
  late Widget menuEntry = _LocaleCheckboxMenuEntry(config: config);

  @override
  late List<TransitProvider> transitProviders = [KmbProvider(apiCaller), CtbProvider(apiCaller)];

  @override
  GtfsDatabase db = GtfsDatabase.forLocale("hk");

  @override
  bool matchingRequired = true;
}

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
    final enabledLocales = await _selectionService.getEnabledLocales();
    if (!mounted) return;
    setState(() {
      _selected = enabledLocales.contains(widget.config.code);
      _loaded = true;
    });
  }

  Future<void> _setSelected(bool selected) async {
    setState(() => _selected = selected);
    final enabledLocales = (await _selectionService.getEnabledLocales()).toSet();
    if (selected) {
      enabledLocales.add(widget.config.code);
    } else {
      enabledLocales.remove(widget.config.code);
    }
    await _selectionService.setEnabledLocales(enabledLocales.toList()..sort());
  }

  @override
  Widget build(BuildContext context) {
    return CheckboxListTile(
      title: Text(widget.config.displayName),
      value: _selected,
      onChanged: _loaded ? (checked) => _setSelected(checked == true) : null,
    );
  }
}
