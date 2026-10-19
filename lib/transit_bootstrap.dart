import 'package:transport_alarm/l10n/app_strings.dart';
import 'package:transport_alarm/locale_registry.dart';
import 'package:transport_alarm/transit/cancellation.dart';
import 'package:transport_alarm/transit/progress_callback.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:transport_alarm/transit/services/locale_selection_service.dart';
import 'package:transport_alarm/transit/services/temp_file_cleaner.dart';

/// Runs the data refresh routine for a given provider.
Future<List<String>> initializeTransitData({
  ProgressCallback? onProgress,
  bool forceRefresh = false,
  CancellationToken? cancelToken,
}) async {
  final allFailures = <String>[];
  final selectionService = LocaleSelectionService();
  final locales = await selectionService.getEnabledLocales();
  try {
    for (final locale in LocaleRegistry.getLocales(locales.keys.toList())) {
      // todo uk locale did not show up here
      for (final gtfsProvider in locale.gtfsProviders) {
        cancelToken?.throwIfCancelled();
        try {
          await gtfsProvider.syncFeed(
            onProgress: onProgress,
            cancelToken: cancelToken,
          );
        } catch (error) {
          _rethrowIfCancelled(cancelToken);
          allFailures.add('${gtfsProvider.locale} timetable: $error');
        }
      }

      for (final transitProvider in locale.transitProviders) {
        cancelToken?.throwIfCancelled();
        try {
          final result = await transitProvider.refresh(
            forceRefresh: forceRefresh,
            onProgress: onProgress,
          );
          allFailures.addAll(
            result.failedItems.map(
              (item) => '${transitProvider.providerName}: $item',
            ),
          );
        } catch (error) {
          _rethrowIfCancelled(cancelToken);
          allFailures.add('${transitProvider.providerName}: $error');
        }
      }

      if (locale.matchingRequired) {
        cancelToken?.throwIfCancelled();
        try {
          onProgress?.call(
            AppStrings.text('transit.matching_stops', {'locale': locale}),
            null,
          );
          await locale.db.matchOperatorStopsToGtfs();
        } catch (error) {
          _rethrowIfCancelled(cancelToken);
          allFailures.add('$locale stop matching: $error');
        }
      }
    }
  } finally {
    // Runs once every sync has finished or the operation was cancelled.
    await TempFileCleaner.sweep();
  }
  onProgress?.call(AppStrings.text('transit.setup_complete'), 1.0);
  return allFailures;
}

Future<List<String>> refreshStaleProviders({
  ProgressCallback? onProgress,
  bool forceRefresh = false,
  CancellationToken? cancelToken,
}) async {
  final allFailures = <String>[];
  final selectionService = LocaleSelectionService();
  final locales = await selectionService.getEnabledLocales();

  try {
    for (final locale in LocaleRegistry.getLocales(locales.keys.toList())) {
      bool changed = false;
      for (final gtfsProvider in locale.gtfsProviders) {
        cancelToken?.throwIfCancelled();
        try {
          if (forceRefresh || await gtfsProvider.checkIsStale()) {
            await gtfsProvider.syncFeed(
              onProgress: onProgress,
              cancelToken: cancelToken,
            );
            changed = true;
          }
        } catch (error) {
          _rethrowIfCancelled(cancelToken);
          allFailures.add('${gtfsProvider.locale} timetable: $error');
        }
      }

      for (final transitProvider in locale.transitProviders) {
        cancelToken?.throwIfCancelled();
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
            result.failedItems.map(
              (item) => '${transitProvider.providerName}: $item',
            ),
          );
          changed = true;
        } catch (error) {
          _rethrowIfCancelled(cancelToken);
          allFailures.add('${transitProvider.providerName}: $error');
        }
      }

      if (locale.matchingRequired && changed) {
        cancelToken?.throwIfCancelled();
        try {
          onProgress?.call(
            AppStrings.text('transit.matching_stops', {'locale': locale}),
            null,
          );
          await locale.db.matchOperatorStopsToGtfs();
        } catch (error) {
          _rethrowIfCancelled(cancelToken);
          allFailures.add('$locale stop matching: $error');
        }
      }
    }
  } finally {
    await TempFileCleaner.sweep();
  }
  onProgress?.call(AppStrings.text('transit.refresh_complete'), 1.0);
  return allFailures;
}

/// A provider's error after a cancel is the cancel itself (e.g. its download
/// aborted), so stop the whole operation instead of recording a failure.
void _rethrowIfCancelled(CancellationToken? cancelToken) {
  if (cancelToken?.isCancelled ?? false) {
    throw const OperationCancelledException();
  }
}

/// Names of the enabled locales with out-of-date data, for the startup
/// reminder. A provider whose check fails (e.g. offline) counts as fresh, so
/// being offline never triggers the reminder.
Future<List<String>> findStaleLocales() async {
  final staleNames = <String>[];
  final locales = await LocaleSelectionService().getEnabledLocales();
  for (final locale in LocaleRegistry.getLocales(locales.keys.toList())) {
    var stale = false;
    for (final gtfsProvider in locale.gtfsProviders) {
      try {
        stale = stale || await gtfsProvider.checkIsStale();
      } catch (_) {}
    }
    for (final transitProvider in locale.transitProviders) {
      try {
        stale = stale || await transitProvider.isStale();
      } catch (_) {}
    }
    if (stale) {
      final names = locale.config.displayName;
      staleNames.add(
        names[AppStrings.languageCode] ?? names['en'] ?? locale.config.code,
      );
    }
  }
  return staleNames;
}

Future<List<String>> localesForSelection(
  LocaleSelectionService selectionService,
  List<String> enabledLocales,
) async {
  final locales = enabledLocales.toSet();
  return locales.toList();
}
