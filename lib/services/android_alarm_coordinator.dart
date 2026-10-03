import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show DartPluginRegistrant;

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:transport_alarm/models/alarm_route_config.dart';
import 'package:transport_alarm/models/transport_alarm.dart';
import 'package:transport_alarm/l10n/app_strings.dart';
import 'package:transport_alarm/services/alarm_storage_service.dart';
import 'package:transport_alarm/services/notification_service.dart';
import 'package:transport_alarm/transit/models/repeat_pattern.dart';
import 'package:transport_alarm/transit/models/threshold_state.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:transport_alarm/transit/services/arrival_resolver.dart';
import 'package:transport_alarm/transit/services/locale_selection_service.dart';
import 'package:transport_alarm/transit/transport_mode.dart';
import 'package:transport_alarm/transit/locale/uk/uk_time.dart';

/// Coordinates Android's local wall-clock alarms and the Dart decision flow.
class AndroidAlarmCoordinator {
  final AlarmStorageService _storage;

  const AndroidAlarmCoordinator(this._storage);

  /// Starts the current window immediately, or arms its next eligible start.
  Future<void> startOrSchedule(TransportAlarm alarm) async {
    await _requireExactAlarmPermission();
    final now = DateTime.now();
    final activeWindow = _activeWindow(alarm, now);
    final occurrence = activeWindow ?? _nextOccurrence(alarm, now);
    final prepared = alarm.copyWith(
      enabled: true,
      spent: false,
      thresholdStates: alarm.thresholdStates
          .map(
            (state) => ThresholdState(
              minutesBeforeArrival: state.minutesBeforeArrival,
            ),
          )
          .toList(),
      clearLastEstimatedMinutesUntilThreshold: true,
      clearAndroidFallbackArrival: true,
      androidApiWarningActive: false,
      androidOccurrenceStartEpochSeconds:
          occurrence.start.millisecondsSinceEpoch ~/ 1000,
      androidOccurrenceEndEpochSeconds:
          occurrence.end.millisecondsSinceEpoch ~/ 1000,
      androidProgressStartEpochSeconds: now.millisecondsSinceEpoch ~/ 1000,
    );
    await _storage.updateAlarm(prepared);
    await _cancelScheduledCallbacks(prepared.id);
    if (activeWindow != null) {
      await _checkAlarm(prepared.id);
    } else {
      await _schedule(prepared, occurrence.start, 'windowStart');
    }
  }

  /// Stops pending callbacks and removes this alarm's local notifications.
  Future<void> disable(String alarmId) async {
    await _cancelScheduledCallbacks(alarmId);
    await NotificationService.cancel(_ringNotificationId(alarmId));
    await NotificationService.cancel(_statusNotificationId(alarmId));
    await NotificationService.cancel(_countdownNotificationId(alarmId));
  }

  /// Acknowledges a ringing threshold and immediately evaluates the next stage.
  Future<void> acknowledge(String alarmId) async {
    final alarm = await _findAlarm(alarmId);
    if (alarm == null || !alarm.enabled || alarm.spent) return;
    final index = alarm.thresholdStates.indexWhere(
      (state) => state.outcome == ThresholdOutcome.ringing,
    );
    if (index < 0) return;

    final states = List<ThresholdState>.of(alarm.thresholdStates);
    states[index] = states[index].copyWith(
      outcome: ThresholdOutcome.acknowledged,
    );
    await _storage.updateAlarm(alarm.copyWith(thresholdStates: states));
    await NotificationService.cancel(_ringNotificationId(alarmId));
    await _checkAlarm(alarmId);
  }

  /// Handles one AlarmManager callback in its background Dart isolate.
  Future<void> handleScheduledCallback({
    required String alarmId,
    required String event,
  }) async {
    if (event == 'windowStart') {
      final alarm = await _findAlarm(alarmId);
      if (alarm == null || !alarm.enabled) return;
      final startsRepeat =
          alarm.spent && alarm.repeat.frequency != RepeatFrequency.none;
      final reset = alarm.copyWith(
        spent: startsRepeat ? false : alarm.spent,
        thresholdStates: startsRepeat
            ? alarm.thresholdStates
                  .map(
                    (state) => ThresholdState(
                      minutesBeforeArrival: state.minutesBeforeArrival,
                    ),
                  )
                  .toList()
            : null,
        clearLastEstimatedMinutesUntilThreshold: startsRepeat,
        clearAndroidFallbackArrival: startsRepeat,
        androidApiWarningActive: startsRepeat ? false : null,
        androidProgressStartEpochSeconds:
            alarm.androidProgressStartEpochSeconds ??
            DateTime.now().millisecondsSinceEpoch ~/ 1000,
      );
      await _storage.updateAlarm(reset);
      if (startsRepeat) {
        await NotificationService.cancel(_statusNotificationId(alarmId));
      }
    }
    await _checkAlarm(alarmId);
  }

  Future<void> _checkAlarm(String alarmId) async {
    var alarm = await _findAlarm(alarmId);
    if (alarm == null || !alarm.enabled || alarm.spent) return;

    final startSeconds = alarm.androidOccurrenceStartEpochSeconds;
    final endSeconds = alarm.androidOccurrenceEndEpochSeconds;
    if (startSeconds == null || endSeconds == null) {
      await startOrSchedule(alarm);
      return;
    }
    final now = DateTime.now();
    if (alarm.androidProgressStartEpochSeconds == null) {
      alarm = alarm.copyWith(
        androidProgressStartEpochSeconds: now.millisecondsSinceEpoch ~/ 1000,
      );
      await _storage.updateAlarm(alarm);
    }
    final startsAt = DateTime.fromMillisecondsSinceEpoch(startSeconds * 1000);
    final endsAt = DateTime.fromMillisecondsSinceEpoch(endSeconds * 1000);
    if (now.isBefore(startsAt)) {
      await _schedule(alarm, startsAt, 'windowStart');
      return;
    }
    if (!now.isBefore(endsAt)) {
      await _finishOccurrence(alarm, dueToWindowEnd: true);
      return;
    }

    final activeThresholdIndex = alarm.thresholdStates.indexWhere(
      (state) =>
          state.outcome == ThresholdOutcome.pending ||
          state.outcome == ThresholdOutcome.ringing,
    );

    // A threshold stays visibly ringing until the user acknowledges it.
    if (activeThresholdIndex >= 0 &&
        alarm.thresholdStates[activeThresholdIndex].outcome ==
            ThresholdOutcome.ringing) {
      await _scheduleRetry(alarm, now);
      return;
    }

    final earliestArrival = _firstThresholdIsStillRequired(alarm)
        ? alarm.thresholdStates
                  .map((state) => state.minutesBeforeArrival)
                  .reduce((a, b) => a > b ? a : b) *
              60
        : null;
    debugPrint(
      '[AndroidAlarmCoordinator] Refreshing ETA for alarm ${alarm.id} '
      'at ${now.toIso8601String()}',
    );
    final lookup = await _lookupArrival(
      alarm,
      minimumArrivalSeconds: earliestArrival,
    );
    debugPrint(
      '[AndroidAlarmCoordinator] ETA refresh for alarm ${alarm.id}: '
      '${lookup.arrivalAt?.toIso8601String() ?? 'no arrival found'}',
    );
    alarm = await _findAlarm(alarm.id) ?? alarm;
    alarm = await _updateApiWarning(alarm, lookup.apiFailed);
    if (!DateTime.now().isBefore(endsAt)) {
      await _finishOccurrence(alarm, dueToWindowEnd: true);
      return;
    }

    if (activeThresholdIndex >= 0) {
      final threshold = alarm.thresholdStates[activeThresholdIndex];
      final arrivalAt = lookup.arrivalAt;
      if (arrivalAt == null) {
        await _cancel(_fireAlarmId(alarm.id));
        await NotificationService.cancel(_countdownNotificationId(alarm.id));
        await _scheduleRetry(alarm, now);
        return;
      }

      final thresholdAt = arrivalAt.subtract(
        Duration(minutes: threshold.minutesBeforeArrival),
      );
      final remainingSeconds = thresholdAt.difference(now).inSeconds;
      final minutesUntilThreshold = (remainingSeconds / 60).ceil();
      await _storage.updateAlarm(
        alarm.copyWith(
          lastEstimatedMinutesUntilThreshold: minutesUntilThreshold,
        ),
      );
      if (!now.isBefore(thresholdAt)) {
        final states = List<ThresholdState>.of(alarm.thresholdStates);
        states[activeThresholdIndex] = threshold.copyWith(
          outcome: ThresholdOutcome.ringing,
          ringCount: threshold.ringCount + 1,
        );
        final ringing = alarm.copyWith(
          thresholdStates: states,
          lastEstimatedMinutesUntilThreshold: 0,
        );
        await _storage.updateAlarm(ringing);
        await _cancel(_fireAlarmId(alarm.id));
        final stopName = await _stopName(ringing);
        await NotificationService.showThresholdRing(
          notificationId: _ringNotificationId(ringing.id),
          alarmId: ringing.id,
          title: AppStrings.text(
            'notification.transport_arriving_soon',
            AppStrings.transportModeValues(alarm.transportMode),
          ),
          body: _ringBody(ringing, stopName),
        );
        await _scheduleRetry(ringing, now);
        return;
      }

      await _schedule(alarm, thresholdAt, 'fire');
      if (thresholdAt.isBefore(endsAt)) {
        await NotificationService.showCountdown(
          notificationId: _countdownNotificationId(alarm.id),
          alarmId: alarm.id,
          title: AppStrings.text('notification.next_transport_alarm', {
            ...AppStrings.transportModeValues(alarm.transportMode),
          }),
          body: _ringBody(alarm, await _stopName(alarm)),
          progressStartTime: _androidProgressStartTime(alarm, now),
          countdownTargetTime: thresholdAt,
          estimatedArrivalTime: arrivalAt,
          thresholdTimes: alarm.thresholdStates
              .map(
                (state) => arrivalAt.subtract(
                  Duration(minutes: state.minutesBeforeArrival),
                ),
              )
              .toList(),
        );
      } else {
        await NotificationService.cancel(_countdownNotificationId(alarm.id));
      }
      await _scheduleHalfwayCheck(alarm, now, thresholdAt);
      return;
    }

    // Once thresholds are acknowledged, the final transport alert is visible but silent.
    final finalArrivalAt = lookup.arrivalAt;
    if (finalArrivalAt == null) {
      await _cancel(_fireAlarmId(alarm.id));
      await NotificationService.cancel(_countdownNotificationId(alarm.id));
      await _scheduleRetry(alarm, now);
      return;
    }
    final arrivalAlertAt = finalArrivalAt.subtract(const Duration(seconds: 20));
    if (!now.isBefore(arrivalAlertAt)) {
      await _finishOccurrence(alarm, dueToWindowEnd: false);
      return;
    }

    await _schedule(alarm, arrivalAlertAt, 'fire');
    if (arrivalAlertAt.isBefore(endsAt)) {
      await NotificationService.showCountdown(
        notificationId: _countdownNotificationId(alarm.id),
        alarmId: alarm.id,
        title: AppStrings.text(
          'notification.transport_arriving_soon',
          AppStrings.transportModeValues(alarm.transportMode),
        ),
        body: alarm.message.isNotEmpty
            ? alarm.message
            : AppStrings.text(
                'notification.default_transport_body',
                AppStrings.transportModeValues(alarm.transportMode),
              ),
        progressStartTime: _androidProgressStartTime(alarm, now),
        countdownTargetTime: finalArrivalAt,
        estimatedArrivalTime: finalArrivalAt,
        thresholdTimes: alarm.thresholdStates
            .map(
              (state) => finalArrivalAt.subtract(
                Duration(minutes: state.minutesBeforeArrival),
              ),
            )
            .toList(),
      );
    } else {
      await NotificationService.cancel(_countdownNotificationId(alarm.id));
    }
    await _scheduleHalfwayCheck(alarm, now, arrivalAlertAt);
  }

  /// Finds the next arrival and records whether it came from live data or schedule.
  Future<ArrivalLookup> _lookupArrival(
    TransportAlarm alarm, {
    int? minimumArrivalSeconds,
  }) async {
    final now = DateTime.now();
    final liveDates = <DateTime>[];
    final scheduledDates = <DateTime>{};
    var hasHealthyApi = false;
    var hasFailedApi = false;

    if (alarm.routeApiConfigs.isNotEmpty) {
      final results = await Future.wait(
        alarm.routeApiConfigs.map(_fetchRouteEta),
      );
      for (final result in results) {
        final scheduleAllowed = !alarm.liveOnly || !result.usedSchedule;
        hasHealthyApi = hasHealthyApi || (result.healthy && scheduleAllowed);
        hasFailedApi = hasFailedApi || (!result.healthy && scheduleAllowed);
        if (scheduleAllowed) {
          liveDates.addAll(result.arrivals);
          if (result.usedSchedule) scheduledDates.addAll(result.arrivals);
        }
      }
    } else {
      // Compatibility for alarms saved before route-specific API URLs existed.
      try {
        final arrivals = await resolveArrivals(
          gtfsStopId: alarm.gtfsStopId,
          localeCode: alarm.localeCode,
          routeNumberFilter: alarm.routeNumbers,
          routeProviderCodeFilter: alarm.routeApiConfigs
              .map((route) => route.providerCode)
              .toList(),
          minimumMinutesFromNow: minimumArrivalSeconds == null
              ? null
              : minimumArrivalSeconds ~/ 60,
        );
        liveDates.addAll(
          arrivals
              .where((arrival) => arrival.isLive)
              .map(
                (arrival) => now.add(Duration(minutes: arrival.minutesFromNow)),
              ),
        );
        hasHealthyApi = arrivals.any((arrival) => arrival.isLive);
        hasFailedApi = !hasHealthyApi;
      } catch (_) {
        hasHealthyApi = false;
        hasFailedApi = true;
      }
    }

    final eligibleLive = liveDates.where((date) {
      return minimumArrivalSeconds == null ||
          date.difference(now).inSeconds >= minimumArrivalSeconds;
    }).toList()..sort();
    if (eligibleLive.isNotEmpty) {
      final usedSchedule = scheduledDates.contains(eligibleLive.first);
      final saved = await _findAlarm(alarm.id);
      if (usedSchedule && saved != null) {
        await _storage.updateAlarm(
          saved.copyWith(
            androidFallbackArrivalEpochSeconds:
                eligibleLive.first.millisecondsSinceEpoch ~/ 1000,
          ),
        );
      } else if (!usedSchedule &&
          saved?.androidFallbackArrivalEpochSeconds != null) {
        await _storage.updateAlarm(
          saved!.copyWith(clearAndroidFallbackArrival: true),
        );
      }
      return ArrivalLookup(
        arrivalAt: eligibleLive.first,
        apiFailed: hasFailedApi,
        usedSchedule: usedSchedule,
      );
    }

    if (alarm.liveOnly) {
      return ArrivalLookup(
        arrivalAt: null,
        apiFailed: hasFailedApi || !hasHealthyApi,
        usedSchedule: false,
      );
    }

    final pinnedEpoch = alarm.androidFallbackArrivalEpochSeconds;
    if (pinnedEpoch != null) {
      return ArrivalLookup(
        arrivalAt: DateTime.fromMillisecondsSinceEpoch(pinnedEpoch * 1000),
        apiFailed: hasFailedApi || !hasHealthyApi,
        usedSchedule: true,
      );
    }

    try {
      final ukRouteIds = alarm.localeCode == 'uk'
          ? alarm.routeApiConfigs
                .map((config) => Uri.tryParse(config.apiUrl))
                .where((uri) => uri?.scheme == 'gtfs')
                .map((uri) => uri?.queryParameters['route_id'])
                .whereType<String>()
                .toSet()
                .toList()
          : null;
      final departures = await GtfsDatabase.forLocale(alarm.localeCode)
          .getUpcomingDepartures(
            alarm.gtfsStopId,
            limit: 100,
            routeIds: ukRouteIds,
          );
      final matching = departures.where((departure) {
        return alarm.routeNumbers.contains(departure.routeShortName) &&
            (minimumArrivalSeconds == null ||
                departure.minutesFromNow * 60 >= minimumArrivalSeconds);
      }).toList()..sort((a, b) => a.minutesFromNow.compareTo(b.minutesFromNow));
      if (matching.isEmpty) {
        return ArrivalLookup(
          arrivalAt: null,
          apiFailed: hasFailedApi || !hasHealthyApi,
          usedSchedule: true,
        );
      }
      final arrivalAt = now.add(
        Duration(minutes: matching.first.minutesFromNow),
      );
      final latest = await _findAlarm(alarm.id);
      if (latest != null && latest.androidFallbackArrivalEpochSeconds == null) {
        await _storage.updateAlarm(
          latest.copyWith(
            androidFallbackArrivalEpochSeconds:
                arrivalAt.millisecondsSinceEpoch ~/ 1000,
          ),
        );
      }
      return ArrivalLookup(
        arrivalAt: arrivalAt,
        apiFailed: hasFailedApi || !hasHealthyApi,
        usedSchedule: true,
      );
    } catch (_) {
      return ArrivalLookup(
        arrivalAt: null,
        apiFailed: hasFailedApi || !hasHealthyApi,
        usedSchedule: false,
      );
    }
  }

  /// Resolves one route URL into live ETAs or its local UK timetable departures.
  Future<RouteEtaResult> _fetchRouteEta(AlarmRouteConfig config) async {
    final uri = Uri.tryParse(config.apiUrl);
    if (uri?.scheme == 'gtfs' && uri?.host == 'uk') {
      final segments = uri!.pathSegments;
      final routeId = uri.queryParameters['route_id'];
      if (segments.isEmpty || routeId == null || routeId.isEmpty) {
        return const RouteEtaResult(healthy: false);
      }
      final encodedStopId = segments[0];
      final operatorStopId = encodedStopId.startsWith('uk:')
          ? encodedStopId
          : 'uk:$encodedStopId';
      final routes = await GtfsDatabase.forLocale('uk')
          .getRoutesForOperatorStop(operatorStopId);
      if (!routes.any((route) => route.routeNumber == config.routeNumber)) {
        return const RouteEtaResult(healthy: false);
      }
      final stopMapping = await GtfsDatabase.forLocale('uk')
          .getGtfsStopIdForOperatorStop(operatorStopId);
      if (stopMapping == null) return const RouteEtaResult(healthy: false);
      final directionId = int.tryParse(
        uri.queryParameters['direction_id'] ?? '',
      );
      final departures = await GtfsDatabase.forLocale('uk')
          .getUpcomingDepartures(
            stopMapping,
            limit: 200,
            routeIds: [routeId],
            directionId: directionId,
          );
      final matching = departures
          .map(
            (departure) => UkTime.departureToDeviceLocal(departure.arrivalTime),
          )
          .toList();
      return RouteEtaResult(arrivals: matching, usedSchedule: true);
    }
    if (config.mode != TransportMode.bus) {
      return const RouteEtaResult(healthy: false);
    }
    try {
      final response = await http
          .get(Uri.parse(config.apiUrl))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) {
        return const RouteEtaResult(healthy: false);
      }
      final payload = jsonDecode(response.body);
      if (payload is! Map<String, dynamic> || payload['data'] is! List) {
        return const RouteEtaResult(healthy: false);
      }
      final dates = (payload['data'] as List)
          .whereType<Map<String, dynamic>>()
          .where(
            (entry) =>
                entry['route'] == config.routeNumber && entry['eta'] is String,
          )
          .map((entry) => DateTime.tryParse(entry['eta'] as String)?.toLocal())
          .whereType<DateTime>()
          .toList();
      return RouteEtaResult(healthy: true, arrivals: dates);
    } catch (_) {
      return const RouteEtaResult(healthy: false);
    }
  }

  bool _firstThresholdIsStillRequired(TransportAlarm alarm) {
    return alarm.thresholdStates.isNotEmpty &&
        alarm.thresholdStates.every(
          (state) => state.outcome == ThresholdOutcome.pending,
        ) &&
        alarm.lastEstimatedMinutesUntilThreshold == null &&
        alarm.androidFallbackArrivalEpochSeconds == null;
  }

  Future<TransportAlarm> _updateApiWarning(
    TransportAlarm alarm,
    bool apiFailed,
  ) async {
    if (apiFailed == alarm.androidApiWarningActive) return alarm;
    final updated = alarm.copyWith(androidApiWarningActive: apiFailed);
    await _storage.updateAlarm(updated);
    if (apiFailed) {
      await NotificationService.showSilentStatus(
        notificationId: _statusNotificationId(alarm.id),
        alarmId: alarm.id,
        title: AppStrings.text('notification.live_unavailable'),
        body: alarm.liveOnly
            ? AppStrings.text('notification.live_failed.body')
            : AppStrings.text('notification.live_failed_schedule.body'),
      );
    } else {
      await NotificationService.cancel(_statusNotificationId(alarm.id));
    }
    return updated;
  }

  Future<void> _scheduleHalfwayCheck(
    TransportAlarm alarm,
    DateTime now,
    DateTime target,
  ) async {
    final endSeconds = alarm.androidOccurrenceEndEpochSeconds;
    final windowEnd = endSeconds == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(endSeconds * 1000);
    if (windowEnd != null && !target.isBefore(windowEnd)) {
      await _schedule(alarm, windowEnd, 'windowEnd');
      return;
    }
    final remainingSeconds = target.difference(now).inSeconds;
    if (remainingSeconds <= 60) return;
    final waitSeconds = math.max(60, remainingSeconds ~/ 2).toInt();
    final checkAt = now.add(Duration(seconds: waitSeconds));
    if (checkAt.isBefore(target)) {
      await _schedule(alarm, checkAt, 'check');
    }
  }

  Future<void> _scheduleRetry(TransportAlarm alarm, DateTime now) async {
    final endSeconds = alarm.androidOccurrenceEndEpochSeconds;
    final end = endSeconds == null
        ? now.add(const Duration(minutes: 1))
        : DateTime.fromMillisecondsSinceEpoch(endSeconds * 1000);
    final retryAt = now.add(const Duration(minutes: 1));
    if (retryAt.isBefore(end)) {
      await _schedule(alarm, retryAt, 'check');
    } else {
      await _schedule(alarm, end, 'windowEnd');
    }
  }

  Future<void> _schedule(
    TransportAlarm alarm,
    DateTime time,
    String event,
  ) async {
    final now = DateTime.now();
    var scheduledEvent = event;
    var scheduledTime = time;
    final endSeconds = alarm.androidOccurrenceEndEpochSeconds;
    if (event != 'windowStart' && event != 'windowEnd' && endSeconds != null) {
      final windowEnd = DateTime.fromMillisecondsSinceEpoch(endSeconds * 1000);
      if (!scheduledTime.isBefore(windowEnd)) {
        scheduledTime = windowEnd;
        scheduledEvent = 'windowEnd';
      }
    }
    final safeTime = scheduledTime.isAfter(now)
        ? scheduledTime
        : now.add(const Duration(seconds: 1));
    final result = await AndroidAlarmManager.oneShotAt(
      safeTime,
      scheduledEvent == 'fire'
          ? _fireAlarmId(alarm.id)
          : _checkAlarmId(alarm.id),
      androidAlarmManagerCallback,
      exact: true,
      allowWhileIdle: true,
      wakeup: true,
      params: {'alarmId': alarm.id, 'event': scheduledEvent},
    );
    if (!result) {
      throw StateError('Android could not schedule the alarm callback.');
    }
  }

  Future<void> _finishOccurrence(
    TransportAlarm alarm, {
    required bool dueToWindowEnd,
  }) async {
    await _cancelScheduledCallbacks(alarm.id);
    await NotificationService.cancel(_countdownNotificationId(alarm.id));
    final now = DateTime.now();
    if (alarm.repeat.frequency == RepeatFrequency.none) {
      final concluded = alarm.copyWith(
        enabled: false,
        spent: true,
        clearLastEstimatedMinutesUntilThreshold: true,
        clearAndroidOccurrence: true,
        clearAndroidFallbackArrival: true,
      );
      await _storage.updateAlarm(concluded);
      if (!dueToWindowEnd) {
        await _showFinalArrival(concluded);
      } else if (alarm.androidApiWarningActive) {
        await _showWindowEndedWarning(alarm, hasNextRepeat: false);
      } else {
        await NotificationService.cancel(_statusNotificationId(alarm.id));
      }
      await NotificationService.cancel(_ringNotificationId(alarm.id));
      return;
    }

    final occurrenceEnd = alarm.androidOccurrenceEndEpochSeconds == null
        ? now
        : DateTime.fromMillisecondsSinceEpoch(
            alarm.androidOccurrenceEndEpochSeconds! * 1000,
          );
    var nextWindow = _nextOccurrence(alarm, occurrenceEnd);
    if (!nextWindow.end.isAfter(now)) {
      final activeWindow = _activeWindow(alarm, now);
      final activeStartDate = activeWindow == null
          ? null
          : DateTime(
              activeWindow.start.year,
              activeWindow.start.month,
              activeWindow.start.day,
            );
      nextWindow =
          activeWindow != null && _repeatMatches(alarm.repeat, activeStartDate!)
          ? activeWindow
          : _nextOccurrence(alarm, now);
    }
    final concluded = alarm.copyWith(
      spent: true,
      clearLastEstimatedMinutesUntilThreshold: true,
      clearAndroidFallbackArrival: true,
      clearAndroidProgressStartEpochSeconds: true,
      androidOccurrenceStartEpochSeconds:
          nextWindow.start.millisecondsSinceEpoch ~/ 1000,
      androidOccurrenceEndEpochSeconds:
          nextWindow.end.millisecondsSinceEpoch ~/ 1000,
    );
    await _storage.updateAlarm(concluded);
    if (!dueToWindowEnd) {
      await _showFinalArrival(concluded);
    } else if (alarm.androidApiWarningActive) {
      await _showWindowEndedWarning(alarm, hasNextRepeat: true);
    } else {
      await NotificationService.cancel(_statusNotificationId(alarm.id));
    }
    await NotificationService.cancel(_ringNotificationId(alarm.id));
    await _schedule(concluded, nextWindow.start, 'windowStart');
  }

  Future<void> _showFinalArrival(TransportAlarm alarm) async {
    final stopName = await _stopName(alarm);
    await NotificationService.showSilentStatus(
      notificationId: _statusNotificationId(alarm.id),
      alarmId: alarm.id,
      title: AppStrings.text(
        'notification.transport_arriving_now',
        AppStrings.transportModeValues(alarm.transportMode),
      ),
      body: alarm.message.isNotEmpty
          ? alarm.message
          : stopName == null
          ? AppStrings.text(
              'notification.default_transport_body',
              AppStrings.transportModeValues(alarm.transportMode),
            )
          : AppStrings.text('notification.transport_expected_at', {
              ...AppStrings.transportModeValues(alarm.transportMode),
              'stop': stopName,
            }),
    );
  }

  Future<void> _showWindowEndedWarning(
    TransportAlarm alarm, {
    required bool hasNextRepeat,
  }) async {
    await NotificationService.showSilentStatus(
      notificationId: _statusNotificationId(alarm.id),
      alarmId: alarm.id,
      title: AppStrings.text('notification.window_ended'),
      body: hasNextRepeat
          ? AppStrings.text('notification.window_ended.next_repeat')
          : AppStrings.text('notification.window_ended.no_repeat'),
    );
  }

  DateTime _androidProgressStartTime(TransportAlarm alarm, DateTime fallback) {
    final startSeconds = alarm.androidProgressStartEpochSeconds;
    if (startSeconds == null) return fallback;
    return DateTime.fromMillisecondsSinceEpoch(startSeconds * 1000);
  }

  Future<void> _cancelScheduledCallbacks(String alarmId) async {
    await _cancel(_checkAlarmId(alarmId));
    await _cancel(_fireAlarmId(alarmId));
  }

  Future<void> _cancel(int id) async {
    await AndroidAlarmManager.cancel(id);
  }

  Future<TransportAlarm?> _findAlarm(String alarmId) async {
    return (await _storage.loadAlarms())
        .where((alarm) => alarm.id == alarmId)
        .firstOrNull;
  }

  Future<String?> _stopName(TransportAlarm alarm) async {
    try {
      return (await GtfsDatabase.forLocale(alarm.localeCode)
              .getGtfsStopById(alarm.gtfsStopId))
          ?.name;
    } catch (_) {
      return null;
    }
  }

  String _ringBody(TransportAlarm alarm, String? stopName) {
    if (alarm.message.isNotEmpty) return alarm.message;
    final routes = alarm.routeNumbers.join(', ');
    if (stopName == null) {
      return AppStrings.text('notification.routes_approaching', {
        'routes': routes,
      });
    }
    return AppStrings.text('notification.routes_stop_approaching', {
      'routes': routes,
      'stop': stopName,
    });
  }

  Future<void> _requireExactAlarmPermission() async {
    if (!(await Permission.notification.status).isGranted) {
      throw StateError(
        'Allow notifications for Transport Alarm so threshold and arrival alerts can appear.',
      );
    }
    final status = await Permission.scheduleExactAlarm.status;
    if (status.isGranted) return;
    final requested = await Permission.scheduleExactAlarm.request();
    if (!requested.isGranted) {
      throw StateError(
        'Allow Transport Alarm under Android “Alarms & reminders” to schedule alarms.',
      );
    }
  }

  WindowOccurrence? _activeWindow(TransportAlarm alarm, DateTime now) {
    for (var offset = -1; offset <= 0; offset++) {
      final date = DateTime(now.year, now.month, now.day + offset);
      final occurrence = _windowForStart(alarm, date);
      if (!now.isBefore(occurrence.start) && now.isBefore(occurrence.end)) {
        return occurrence;
      }
    }
    return null;
  }

  WindowOccurrence _windowForStart(TransportAlarm alarm, DateTime date) {
    final start = DateTime(
      date.year,
      date.month,
      date.day,
      alarm.windowStart.hour,
      alarm.windowStart.minute,
    );
    final startMinute = alarm.windowStart.hour * 60 + alarm.windowStart.minute;
    final endMinute = alarm.windowEnd.hour * 60 + alarm.windowEnd.minute;
    final endDate = startMinute > endMinute
        ? DateTime(date.year, date.month, date.day + 1)
        : date;
    final end = DateTime(
      endDate.year,
      endDate.month,
      endDate.day,
      alarm.windowEnd.hour,
      alarm.windowEnd.minute,
    );
    return WindowOccurrence(start: start, end: end);
  }

  WindowOccurrence _nextOccurrence(TransportAlarm alarm, DateTime after) {
    for (var offset = 0; offset <= 370; offset++) {
      final date = DateTime(after.year, after.month, after.day + offset);
      final occurrence = _windowForStart(alarm, date);
      if (!occurrence.start.isAfter(after)) continue;
      if (_repeatMatches(alarm.repeat, date)) return occurrence;
    }
    throw StateError('Could not find the next repeat window.');
  }

  bool _repeatMatches(RepeatPattern repeat, DateTime date) {
    switch (repeat.frequency) {
      case RepeatFrequency.none:
      case RepeatFrequency.daily:
        return true;
      case RepeatFrequency.weekly:
        return (repeat.weekdays ?? const []).contains(date.weekday);
      case RepeatFrequency.monthly:
        return (repeat.dayOfMonth ?? const []).contains(date.day);
    }
  }

  int _stableId(String alarmId) {
    var hash = 0x811c9dc5;
    for (final unit in alarmId.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0x7fffffff;
    }
    return hash & 0x3fffffff;
  }

  int _checkAlarmId(String alarmId) => _stableId(alarmId) * 2;
  int _fireAlarmId(String alarmId) => _stableId(alarmId) * 2 + 1;
  int _ringNotificationId(String alarmId) => _stableId(alarmId);
  int _statusNotificationId(String alarmId) => _stableId(alarmId) + 0x40000000;
  int _countdownNotificationId(String alarmId) =>
      -0x40000000 + _stableId(alarmId);
}

/// Top-level entrypoint invoked by AlarmManager in its background Dart isolate.
@pragma('vm:entry-point')
Future<void> androidAlarmManagerCallback(
  int id,
  Map<String, dynamic> params,
) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  final languageCode = await LocaleSelectionService().getAppLanguageCode();
  await AppStrings.load(languageCode);
  await NotificationService.initBackground();
  try {
    final alarmId = params['alarmId'] as String?;
    if (alarmId == null) return;
    await AndroidAlarmCoordinator(AlarmStorageService())
        .handleScheduledCallback(
          alarmId: alarmId,
          event: params['event'] as String? ?? 'check',
        );
  } catch (error, stackTrace) {
    debugPrint('Android alarm callback failed: $error\n$stackTrace');
  }
}

class WindowOccurrence {
  final DateTime start;
  final DateTime end;

  const WindowOccurrence({required this.start, required this.end});
}

class RouteEtaResult {
  final bool healthy;
  final List<DateTime> arrivals;
  final bool usedSchedule;

  const RouteEtaResult({
    this.healthy = false,
    this.arrivals = const [],
    this.usedSchedule = false,
  });
}

class ArrivalLookup {
  final DateTime? arrivalAt;
  final bool apiFailed;
  final bool usedSchedule;

  const ArrivalLookup({
    required this.arrivalAt,
    required this.apiFailed,
    required this.usedSchedule,
  });
}
