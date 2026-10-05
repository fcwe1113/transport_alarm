import 'package:transport_alarm/provider_registry.dart';
import 'package:transport_alarm/l10n/app_strings.dart';
import 'package:transport_alarm/locale_registry.dart';
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
  final locales = await selectionService.getEnabledLocales();
  for (final locale in LocaleRegistry.getLocales(locales)) {
    for (final gtfsProvider in locale.gtfsProviders) {
      try {
        await gtfsProvider.syncFeed(onProgress: onProgress);
      } catch (error) {
        allFailures.add('${gtfsProvider.locale} timetable: $error');
      }
    }

    for (final transitProvider in locale.transitProviders) {
      try {
        final result = await transitProvider.refresh(
          forceRefresh: forceRefresh,
          onProgress: onProgress,
        );
        allFailures.addAll(
          result.failedItems.map((item) => '${transitProvider.providerName}: $item'),
        );
      } catch (error) {
        allFailures.add('${transitProvider.providerName}: $error');
      }
    }

    if (locale.matchingRequired) {
      try {
        onProgress?.call(
          AppStrings.text('transit.matching_stops', {'locale': locale}),
          null,
        );
        await locale.db.matchOperatorStopsToGtfs();
      } catch (error) {
        allFailures.add('$locale stop matching: $error');
      }
    }
  }

  onProgress?.call(AppStrings.text('transit.setup_complete'), 1.0);
  return allFailures;
}

Future<List<String>> refreshStaleProviders({
  ProgressCallback? onProgress,
  bool forceRefresh = false,
}) async {
  final allFailures = <String>[];
  final selectionService = LocaleSelectionService();
  final locales = await selectionService.getEnabledLocales();

  for (final locale in LocaleRegistry.getLocales(locales)) {
    bool changed = false;
    for (final gtfsProvider in locale.gtfsProviders) {
      try {
        if (forceRefresh || await gtfsProvider.checkIsStale()) {
          await gtfsProvider.syncFeed(onProgress: onProgress);
          changed = true;
        }
      } catch (error) {
        allFailures.add('${gtfsProvider.locale} timetable: $error');
      }
    }

    for (final transitProvider in locale.transitProviders) {
      try {
        final stale = forceRefresh || await transitProvider.isStale();
        if (!stale) {
          onProgress?.call(
            AppStrings.text('transit.provider_up_to_date', {
              'providerName': transitProvider.providerName,
            }),
            null,
          );
          continue;
        }

        final result = await transitProvider.refresh(
          forceRefresh: forceRefresh,
          onProgress: onProgress,
        );
        allFailures.addAll(
          result.failedItems.map((item) => '${transitProvider.providerName}: $item'),
        );
        changed = true;
      } catch (error) {
        allFailures.add('${transitProvider.providerName}: $error');
      }
    }

    if (locale.matchingRequired && changed) {
      try {
        onProgress?.call(
          AppStrings.text('transit.matching_stops', {'locale': locale}),
          null,
        );
        await locale.db.matchOperatorStopsToGtfs();
      } catch (error) {
        allFailures.add('$locale stop matching: $error');
      }
    }
  }

  onProgress?.call(AppStrings.text('transit.refresh_complete'), 1.0);
  return allFailures;
}

Future<List<String>> localesForSelection(
  LocaleSelectionService selectionService,
  List<String> enabledLocales,
) async {
  final locales = enabledLocales.toSet();
  return locales.toList();
}
