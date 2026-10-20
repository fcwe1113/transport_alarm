import 'package:flutter/material.dart';
import 'package:transport_alarm/transit/models/locale_config.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:transport_alarm/transit/transit_provider.dart';

import '../services/gtfs_sync_service.dart';

/// A region the app has transit data for, such as Hong Kong. Registered in
/// LocaleRegistry; adding a region means implementing this.
abstract class TransitLocale implements Comparable<TransitLocale> {
  LocaleConfig get config;

  /// Where the region's GTFS timetables come from.
  List<GtfsSyncProvider> get gtfsProviders;

  /// The region's operators, for routes, stops and live arrivals.
  List<TransitProvider> get transitProviders;

  /// The region's row in the region pickers, which selects it.
  Widget get menuEntry;

  /// Whether operator stops must be matched to GTFS stops after a refresh,
  /// for regions whose live APIs use their own stop IDs.
  bool get matchingRequired;

  /// Whether the region's live data uses GTFS stop IDs directly, with no
  /// operator stops of its own.
  bool get gtfsOnly;

  late final GtfsDatabase db = GtfsDatabase.forLocale(config.code);

  /// Sorts regions by English name.
  @override
  int compareTo(TransitLocale other) {
    final englishName = config.displayName['en'] ?? config.code;
    final otherEnglishName =
        other.config.displayName['en'] ?? other.config.code;
    return englishName.toLowerCase().compareTo(otherEnglishName.toLowerCase());
  }
}
