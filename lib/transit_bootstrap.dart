import 'package:transport_alarm/l10n/app_strings.dart';
import 'package:transport_alarm/locale_registry.dart';
import 'package:transport_alarm/transit/cancellation.dart';
import 'package:transport_alarm/transit/locale/transit_locale.dart';
import 'package:transport_alarm/transit/progress_callback.dart';
import 'package:transport_alarm/transit/services/locale_selection_service.dart';
import 'package:transport_alarm/transit/services/temp_file_cleaner.dart';

/// Downloads every enabled region's timetable and operator data, as on first
/// setup or a full reload, or only the enabled regions in [onlyLocales]. A
/// [TransitOperation].
Future<List<String>> initializeTransitData({
  ProgressCallback? onProgress,
  bool forceRefresh = false,
  CancellationToken? cancelToken,
  Set<String>? onlyLocales,
}) async {
  final failures = await _refreshEnabledLocales(
    onlyStale: false,
    forceRefresh: forceRefresh,
    onProgress: onProgress,
    cancelToken: cancelToken,
    onlyLocales: onlyLocales,
  );
  onProgress?.call(AppStrings.text('transit.setup_complete'), 1.0);
  return failures;
}

/// Refreshes only the enabled regions' data that's out of date (or all of
/// it with [forceRefresh]). A [TransitOperation].
Future<List<String>> refreshStaleProviders({
  ProgressCallback? onProgress,
  bool forceRefresh = false,
  CancellationToken? cancelToken,
}) async {
  final failures = await _refreshEnabledLocales(
    onlyStale: true,
    forceRefresh: forceRefresh,
    onProgress: onProgress,
    cancelToken: cancelToken,
  );
  onProgress?.call(AppStrings.text('transit.refresh_complete'), 1.0);
  return failures;
}

/// For each enabled region: syncs its GTFS timetables, refreshes its
/// operators, then matches operator stops to GTFS stops where the region
/// needs it. With [onlyStale], only out-of-date parts are refreshed, and
/// matching only runs when something changed. [onlyLocales] limits it to
/// those regions. Returns a description of each failed step; a cancel stops
/// everything instead.
Future<List<String>> _refreshEnabledLocales({
  required bool onlyStale,
  required bool forceRefresh,
  ProgressCallback? onProgress,
  CancellationToken? cancelToken,
  Set<String>? onlyLocales,
}) async {
  final failures = <String>[];
  final locales = (await LocaleSelectionService().getEnabledLocales()).keys
      .where((code) => onlyLocales == null || onlyLocales.contains(code))
      .toList();
  try {
    for (final locale in LocaleRegistry.getLocales(locales)) {
      // todo uk locale did not show up here
      var changed = !onlyStale;
      for (final gtfsProvider in locale.gtfsProviders) {
        cancelToken?.throwIfCancelled();
        try {
          if (!onlyStale || forceRefresh || await gtfsProvider.checkIsStale()) {
            await gtfsProvider.syncFeed(
              onProgress: onProgress,
              cancelToken: cancelToken,
            );
            changed = true;
          }
        } catch (error) {
          _rethrowIfCancelled(cancelToken);
          failures.add('${gtfsProvider.locale} timetable: $error');
        }
      }

      for (final transitProvider in locale.transitProviders) {
        cancelToken?.throwIfCancelled();
        try {
          if (onlyStale && !forceRefresh && !await transitProvider.isStale()) {
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
          failures.addAll(
            result.failedItems.map(
              (item) => '${transitProvider.providerName}: $item',
            ),
          );
          changed = true;
        } catch (error) {
          _rethrowIfCancelled(cancelToken);
          failures.add('${transitProvider.providerName}: $error');
        }
      }

      if (locale.matchingRequired && changed) {
        cancelToken?.throwIfCancelled();
        try {
          onProgress?.call(
            AppStrings.text('transit.matching_stops', {'locale': _displayName(locale)}),
            null,
          );
          await locale.db.matchOperatorStopsToGtfs();
        } catch (error) {
          _rethrowIfCancelled(cancelToken);
          failures.add('${_displayName(locale)} stop matching: $error');
        }
      }
    }
  } finally {
    // Runs once every sync has finished or the operation was cancelled.
    await TempFileCleaner.sweep();
  }
  return failures;
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
    if (await _isStale(locale)) staleNames.add(_displayName(locale));
  }
  return staleNames;
}

/// The region's name in the app language, then English, then its code.
String _displayName(TransitLocale locale) {
  final names = locale.config.displayName;
  return names[AppStrings.languageCode] ?? names['en'] ?? locale.config.code;
}

Future<bool> _isStale(TransitLocale locale) async {
  for (final gtfsProvider in locale.gtfsProviders) {
    try {
      if (await gtfsProvider.checkIsStale()) return true;
    } catch (_) {}
  }
  for (final transitProvider in locale.transitProviders) {
    try {
      if (await transitProvider.isStale()) return true;
    } catch (_) {}
  }
  return false;
}
