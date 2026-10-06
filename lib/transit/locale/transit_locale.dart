import 'package:flutter/material.dart';
import 'package:transport_alarm/transit/models/locale_config.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:transport_alarm/transit/transit_provider.dart';

import '../services/gtfs_sync_service.dart';

abstract class TransitLocale implements Comparable<TransitLocale> {

  List<GtfsSyncProvider> gtfsProviders = <GtfsSyncProvider>[];
  List<TransitProvider> transitProviders = <TransitProvider>[];
  late LocaleConfig config;
  late Widget menuEntry;
  late GtfsDatabase db = GtfsDatabase.forLocale(config.code);
  late bool matchingRequired;

  @override
  int compareTo(TransitLocale other) {
    final englishName = config.displayName['en'] ?? config.code;
    final otherEnglishName =
        other.config.displayName['en'] ?? other.config.code;
    return englishName.toLowerCase().compareTo(otherEnglishName.toLowerCase());
  }

}
