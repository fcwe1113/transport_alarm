import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:transport_alarm/services/app_group_storage.dart';
import 'package:transport_alarm/transit/progress_callback.dart';
import 'package:transport_alarm/transit/services/api_caller.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:transport_alarm/transit/services/gtfs_sync_service.dart';
import 'package:transport_alarm/transit/services/locale_selection_service.dart';
import 'package:transport_alarm/transit/locale/uk/uk_txc_importer.dart';

/// Fetches BODS timetable datasets that serve the selected ATCO areas.
class UkGtfsSyncProvider implements GtfsSyncProvider {
  /// Names the UK locale database this importer updates.
  @override
  final String locale = 'uk';

  /// Names the BODS dataset API used to discover area-filtered timetables.
  @override
  final String feedUrl = 'https://data.bus-data.dft.gov.uk/api/v1/dataset/';

  static const Duration _ttl = Duration(days: 7);
  static const int _areaBatchSize = 40;
  static const int _pageSize = 100;

  /// Loads the BODS API key from the bundled local secrets file.
  Future<String> _apiKey() async {
    final source = await rootBundle.loadString('config/secrets.json');
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
        'config/secrets.json must contain an object.',
      );
    }
    final key = decoded['UK_BODS_KEY'];
    if (key is! String || key.trim().isEmpty) {
      throw StateError('UK_BODS_KEY is missing from config/secrets.json.');
    }
    return key.trim();
  }

  /// Queries BODS for the published timetable datasets relevant to ATCO areas.
  Future<List<BodsTimetableDataset>> _findDatasets(
    Set<String> selectedAreas, {
    required String apiKey,
  }) async {
    final client = http.Client();
    final byId = <String, BodsTimetableDataset>{};
    try {
      final areas = selectedAreas.toList()..sort();
      for (var start = 0; start < areas.length; start += _areaBatchSize) {
        final areaBatch = areas.skip(start).take(_areaBatchSize).toList();
        var offset = 0;
        while (true) {
          final uri = Uri.parse(feedUrl).replace(
            queryParameters: {
              'api_key': apiKey,
              'adminArea': areaBatch.join(','),
              'status': 'published',
              'limit': '$_pageSize',
              'offset': '$offset',
            },
          );
          final response = await client
              .get(uri)
              .timeout(ApiCaller.requestTimeout);
          if (response.statusCode != HttpStatus.ok) {
            throw HttpException(
              'BODS timetable lookup failed: HTTP ${response.statusCode}',
            );
          }
          final decoded = jsonDecode(response.body);
          if (decoded is! Map<String, dynamic>) {
            throw const FormatException(
              'BODS returned an invalid dataset list.',
            );
          }
          final results = decoded['results'];
          if (results is! List) {
            throw const FormatException(
              'BODS dataset response has no results list.',
            );
          }
          for (final item in results) {
            if (item is! Map<String, dynamic>) continue;
            final dataset = BodsTimetableDataset.fromJson(item);
            if (dataset != null) byId[dataset.id] = dataset;
          }
          if (results.length < _pageSize || results.isEmpty) break;
          offset += results.length;
        }
      }
    } finally {
      client.close();
    }
    return byId.values.toList();
  }

  /// Checks local data age and avoids querying BODS more often than needed.
  @override
  Future<bool> checkIsStale() async {
    if (!await GtfsDatabase.forLocale(locale).hasUsableGtfsData()) return true;
    final selectedAreas = (await LocaleSelectionService().getEnabledAtcoCodes())
        .toSet();
    if (selectedAreas.isEmpty) return true;
    final prefs = await SharedPreferences.getInstance();
    final selectionSignature = (selectedAreas.toList()..sort()).join(',');
    if (prefs.getString('gtfs_atco_selection_$locale') != selectionSignature) {
      return true;
    }
    final checkedAt = DateTime.tryParse(
      prefs.getString('gtfs_last_checked_$locale') ?? '',
    );
    if (checkedAt != null) {
      final age = DateTime.now().difference(checkedAt);
      if (!age.isNegative && age < _ttl) return false;
    }
    return true;
  }

  /// Downloads only datasets returned for selected areas and atomically installs them.
  @override
  Future<void> syncFeed({ProgressCallback? onProgress}) async {
    final selectedAreas = (await LocaleSelectionService().getEnabledAtcoCodes())
        .toSet();
    if (selectedAreas.isEmpty) {
      throw StateError(
        'Select at least one UK ATCO area before downloading data.',
      );
    }
    final apiKey = await _apiKey();
    final datasets = await _findDatasets(selectedAreas, apiKey: apiKey);
    if (datasets.isEmpty) {
      throw StateError(
        'BODS returned no published datasets for the selected ATCO areas.',
      );
    }

    final directory = await AppGroupStorage.directory;
    final workDirectory = await Directory(directory.path)
        .createTemp('uk_bods_');
    final db = GtfsDatabase.forLocale(locale);
    try {
      await db.refreshAtomically((stagingDatabase) async {
        final importer = UkTxcImporter(
          database: stagingDatabase,
          selectedAtcoAreas: selectedAreas,
          workDirectory: workDirectory,
          onProgress: onProgress,
        );
        await importer.importDatasets(datasets);
      }, replaceProviderCodes: const {'uk'});
    } finally {
      if (await workDirectory.exists()) {
        await workDirectory.delete(recursive: true);
      }
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'gtfs_last_checked_$locale',
      DateTime.now().toIso8601String(),
    );
    await prefs.setString(
      'gtfs_atco_selection_$locale',
      (selectedAreas.toList()..sort()).join(','),
    );
  }
}
