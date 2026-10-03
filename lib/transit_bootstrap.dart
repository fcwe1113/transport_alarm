import 'package:transport_alarm/provider_registry.dart';
import 'package:transport_alarm/l10n/app_strings.dart';
import 'package:transport_alarm/locale_gtfs_registry.dart';
import 'package:transport_alarm/transit/progress_callback.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:transport_alarm/transit/services/locale_selection_service.dart';

/// Runs the data refresh routine for a given provider.
Future<List<String>> initializeTransitData({
  ProgressCallback? onProgress,
  bool forceRefresh = false,
}) async {
  final allFailures = <String>[];
  final selectionService = LocaleSelectionService();
  final enabledLocales = await selectionService.getEnabledLocales();
  final enabledProviders = providersForLocales(enabledLocales);
  final gtfsProviders = LocaleGtfsRegistry.getProvidersForLocale(
    enabledLocales,
  );

  for (final provider in gtfsProviders) {
    try {
      await provider.syncFeed(onProgress: onProgress);
    } catch (error) {
      allFailures.add('${provider.locale} timetable: $error');
    }
  }

  for (final provider in enabledProviders) {
    try {
      final result = await provider.refresh(
        forceRefresh: forceRefresh,
        onProgress: onProgress,
      );
      allFailures.addAll(
        result.failedItems.map((item) => '${provider.providerName}: $item'),
      );
    } catch (error) {
      allFailures.add('${provider.providerName}: $error');
    }
  }

  for (final locale in enabledLocales) {
    try {
      onProgress?.call(
        AppStrings.text('transit.matching_stops', {'locale': locale}),
        null,
      );
      await GtfsDatabase.forLocale(locale).matchOperatorStopsToGtfs();
    } catch (error) {
      allFailures.add('$locale stop matching: $error');
    }
  }

  onProgress?.call(AppStrings.text('transit.setup_complete'), 1.0);
  return allFailures;
}

Future<List<String>> refreshStaleProviders({
  ProgressCallback? onProgress,
  bool forceRefresh = false,
}) async {
  final selectionService = LocaleSelectionService();
  final enabledLocales = await selectionService.getEnabledLocales();
  final gtfsProviders = LocaleGtfsRegistry.getProvidersForLocale(
    enabledLocales,
  );
  final enabledProviders = providersForLocales(enabledLocales);
  final allFailures = <String>[];

  for (final provider in gtfsProviders) {
    try {
      if (forceRefresh || await provider.checkIsStale()) {
        await provider.syncFeed(onProgress: onProgress);
      }
    } catch (error) {
      allFailures.add('${provider.locale} timetable: $error');
    }
  }

  for (final provider in enabledProviders) {
    try {
      final stale = forceRefresh || await provider.isStale();
      if (!stale) {
        onProgress?.call(
          AppStrings.text('transit.provider_up_to_date', {
            'providerName': provider.providerName,
          }),
          null,
        );
        continue;
      }

      final result = await provider.refresh(
        forceRefresh: forceRefresh,
        onProgress: onProgress,
      );
      allFailures.addAll(
        result.failedItems.map((item) => '${provider.providerName}: $item'),
      );
    } catch (error) {
      allFailures.add('${provider.providerName}: $error');
    }
  }

  for (final locale in enabledLocales) {
    try {
      onProgress?.call(
        AppStrings.text('transit.matching_stops', {'locale': locale}),
        null,
      );
      await GtfsDatabase.forLocale(locale).matchOperatorStopsToGtfs();
    } catch (error) {
      allFailures.add('$locale stop matching: $error');
    }
  }

  onProgress?.call(AppStrings.text('transit.refresh_complete'), 1.0);
  return allFailures;
}
