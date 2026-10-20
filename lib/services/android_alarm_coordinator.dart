import 'dart:convert';
import 'dart:math' show max;
import 'dart:ui' show DartPluginRegistrant;

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:transport_alarm/models/alarm_route_config.dart';
import 'package:transport_alarm/models/transport_alarm.dart';
import 'package:transport_alarm/l10n/app_strings.dart';
import 'package:transport_alarm/services/alarm_storage_service.dart';
import 'package:transport_alarm/services/notification_service.dart';
import 'package:transport_alarm/transit/models/repeat_pattern.dart';
import 'package:transport_alarm/transit/models/route_arrival.dart';
import 'package:transport_alarm/transit/models/threshold_state.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:transport_alarm/transit/services/arrival_resolver.dart';
import 'package:transport_alarm/transit/services/locale_selection_service.dart';
import 'package:transport_alarm/transit/transport_mode.dart';

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
      thresholdStates: _freshThresholds(alarm),
      clearLastEstimatedMinutesUntilThreshold: true,
      clearIgnoreArrivalsBefore: true,
      clearAndroidFallbackArrival: true,
      clearAndroidLiveNotice: true,
      androidOccurrenceStartEpochSeconds: _epochSeconds(occurrence.start),
      androidOccurrenceEndEpochSeconds: _epochSeconds(occurrence.end),
      androidProgressStartEpochSeconds: _epochSeconds(now),
    );
    await _storage.updateAlarm(prepared);
    await _cancelScheduledCallbacks(prepared.id);
    if (activeWindow != null) {
      await _checkAlarm(prepared.id);
    } else {
      await _schedule(prepared, occurrence.start, 'windowStart');
    }
  }

  /// Re-arms every enabled alarm from its saved progress, for when Android has
  /// dropped the app's pending callbacks: after a force stop, an app update,
  /// or a phone maker killing background work. Unlike [startOrSchedule], it
  /// doesn't reset thresholds the user has already acknowledged.
  Future<void> resumeAll() async {
    for (final alarm in await _storage.loadAlarms()) {
      if (!alarm.enabled) continue;
      try {
        await _cancelScheduledCallbacks(alarm.id);
        if (!alarm.spent) {
          await _checkAlarm(alarm.id);
          continue;
        }
        // A repeating alarm between windows is spent until its next start.
        if (alarm.repeat.frequency == RepeatFrequency.none) continue;
        final startsAt = _fromEpochSeconds(alarm.androidOccurrenceStartEpochSeconds);
        if (startsAt != null && startsAt.isAfter(DateTime.now())) {
          await _schedule(alarm, startsAt, 'windowStart');
        } else {
          await handleScheduledCallback(alarmId: alarm.id, event: 'windowStart');
        }
      } catch (e) {
        debugPrint('Could not resume alarm ${alarm.id}: $e');
      }
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
        thresholdStates: startsRepeat ? _freshThresholds(alarm) : null,
        clearLastEstimatedMinutesUntilThreshold: startsRepeat,
        clearIgnoreArrivalsBefore: startsRepeat,
        clearAndroidFallbackArrival: startsRepeat,
        clearAndroidLiveNotice: startsRepeat,
        androidProgressStartEpochSeconds:
            alarm.androidProgressStartEpochSeconds ?? _epochSeconds(DateTime.now()),
      );
      await _storage.updateAlarm(reset);
      if (startsRepeat) {
        await NotificationService.cancel(_statusNotificationId(alarmId));
      }
    }
    await _checkAlarm(alarmId, guaranteedCheck: event == 'liveCheck');
  }

  /// After a check failed partway, schedules another in a minute so the
  /// alarm isn't left without a pending callback. Each check schedules the
  /// next one, so a check that throws first would otherwise end the alarm.
  Future<void> scheduleRecoveryCheck(String alarmId) async {
    final alarm = await _findAlarm(alarmId);
    if (alarm == null || !alarm.enabled || alarm.spent) return;
    await _scheduleNextCheck(alarm);
  }

  /// One arrival check: fetches the next arrival, then rings, arms the
  /// threshold's "fire" callback and countdown, or ends the occurrence, and
  /// always leaves another check pending. [guaranteedCheck] is true for the
  /// guaranteed live check, the only check sure to have network access; see
  /// [_updateLiveNotice].
  Future<void> _checkAlarm(
    String alarmId, {
    bool guaranteedCheck = false,
  }) async {
    var alarm = await _findAlarm(alarmId);
    if (alarm == null || !alarm.enabled || alarm.spent) return;

    final startsAt = _fromEpochSeconds(alarm.androidOccurrenceStartEpochSeconds);
    final endsAt = _windowEnd(alarm);
    if (startsAt == null || endsAt == null) {
      await startOrSchedule(alarm);
      return;
    }
    final now = DateTime.now();
    if (alarm.androidProgressStartEpochSeconds == null) {
      alarm = alarm.copyWith(androidProgressStartEpochSeconds: _epochSeconds(now));
      await _storage.updateAlarm(alarm);
    }
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
      await _scheduleNextCheck(alarm);
      return;
    }

    // The first check skips buses too close to make the first threshold, and
    // the cutoff is kept so later checks don't latch on to them either.
    final ignoreArrivalsBefore = alarm.ignoreArrivalsBeforeEpochSeconds ??
        (_firstThresholdIsStillRequired(alarm)
            ? _epochSeconds(now) +
                alarm.thresholdStates
                        .map((state) => state.minutesBeforeArrival)
                        .reduce((a, b) => a > b ? a : b) *
                    60
            : null);
    final earliestArrival = ignoreArrivalsBefore == null
        ? null
        : max(0, ignoreArrivalsBefore - _epochSeconds(now));
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
    alarm = await _updateLiveNotice(
      alarm,
      lookup,
      canRaise: guaranteedCheck,
    );
    if (!DateTime.now().isBefore(endsAt)) {
      await _finishOccurrence(alarm, dueToWindowEnd: true);
      return;
    }
    await _scheduleLiveCheck(alarm, gotLiveData: lookup.liveFound);

    if (activeThresholdIndex >= 0) {
      final threshold = alarm.thresholdStates[activeThresholdIndex];
      final arrivalAt = lookup.arrivalAt;
      if (arrivalAt == null) {
        await _waitForArrival(alarm);
        return;
      }

      final thresholdAt = arrivalAt.subtract(
        Duration(minutes: threshold.minutesBeforeArrival),
      );
      final remainingSeconds = thresholdAt.difference(now).inSeconds;
      final minutesUntilThreshold = (remainingSeconds / 60).ceil();
      alarm = alarm.copyWith(
        lastEstimatedMinutesUntilThreshold: minutesUntilThreshold,
        ignoreArrivalsBeforeEpochSeconds: ignoreArrivalsBefore,
      );
      await _storage.updateAlarm(alarm);
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
        await _scheduleNextCheck(ringing);
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
      await _scheduleNextCheck(alarm);
      return;
    }

    // Once thresholds are acknowledged, the final transport alert is visible but silent.
    final finalArrivalAt = lookup.arrivalAt;
    if (finalArrivalAt == null) {
      await _waitForArrival(alarm);
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
    await _scheduleNextCheck(alarm);
  }

  /// With no arrival to aim for, drops any armed ring and countdown and
  /// just checks again in a minute.
  Future<void> _waitForArrival(TransportAlarm alarm) async {
    await _cancel(_fireAlarmId(alarm.id));
    await NotificationService.cancel(_countdownNotificationId(alarm.id));
    await _scheduleNextCheck(alarm);
  }

  /// The next arrival for the alarm's routes: live if any bus is tracked,
  /// otherwise from the timetable (unless the alarm is live only). A
  /// timetable arrival stays pinned until a live bus shows up, so the
  /// countdown doesn't jump between scheduled trips.
  Future<ArrivalLookup> _lookupArrival(
    TransportAlarm alarm, {
    int? minimumArrivalSeconds,
  }) async {
    final now = DateTime.now();
    final liveDates = <DateTime>[];
    // Whether a live request itself failed, as opposed to succeeding without
    // a bus on the alarm's routes.
    var liveRequestFailed = false;
    // From resolveArrivals when it was used. Its scheduled arrivals already
    // skip trips a live feed shows as running or gone past the stop.
    List<RouteArrival>? resolved;

    if (_usesOperatorJsonUrls(alarm)) {
      final results = await Future.wait(
        alarm.routeApiConfigs.map(_fetchRouteEta),
      );
      for (final result in results) {
        liveRequestFailed = liveRequestFailed || !result.healthy;
        liveDates.addAll(result.arrivals);
      }
    } else {
      // Other providers' saved URLs (BODS, TfL) aren't this JSON, so their
      // alarms go through the shared resolver like the stop sheet does. So do
      // alarms saved before route-specific API URLs existed.
      try {
        final arrivals = await resolveArrivals(
          gtfsStopId: alarm.gtfsStopId,
          routeNumberFilter: alarm.routeNumbers,
          minimumMinutesFromNow: minimumArrivalSeconds == null
              ? null
              : minimumArrivalSeconds ~/ 60,
          locale: alarm.localeCode,
          onLiveFetchFailed: () => liveRequestFailed = true,
        );
        resolved = arrivals;
        liveDates.addAll(
          arrivals
              .where((arrival) => arrival.isLive)
              .map(
                (arrival) => now.add(Duration(minutes: arrival.minutesFromNow)),
              ),
        );
      } catch (_) {
        liveRequestFailed = true;
      }
    }

    final eligibleLive = liveDates.where((date) {
      return minimumArrivalSeconds == null ||
          date.difference(now).inSeconds >= minimumArrivalSeconds;
    }).toList()..sort();
    if (eligibleLive.isNotEmpty) {
      final saved = await _findAlarm(alarm.id);
      if (saved?.androidFallbackArrivalEpochSeconds != null) {
        await _storage.updateAlarm(
          saved!.copyWith(clearAndroidFallbackArrival: true),
        );
      }
      return ArrivalLookup(
        arrivalAt: eligibleLive.first,
        liveRequestFailed: liveRequestFailed,
        usedSchedule: false,
      );
    }

    if (alarm.liveOnly) {
      return ArrivalLookup(
        arrivalAt: null,
        liveRequestFailed: liveRequestFailed,
        usedSchedule: false,
      );
    }

    final pinnedEpoch = alarm.androidFallbackArrivalEpochSeconds;
    if (pinnedEpoch != null) {
      return ArrivalLookup(
        arrivalAt: _fromEpochSeconds(pinnedEpoch),
        liveRequestFailed: liveRequestFailed,
        usedSchedule: true,
      );
    }

    try {
      final List<int> scheduledMinutes;
      if (resolved != null) {
        scheduledMinutes = resolved
            .where((arrival) => !arrival.isLive)
            .map((arrival) => arrival.minutesFromNow)
            .toList();
      } else {
        // Route-specific live APIs (HK) have no timetable trip IDs to skip
        // live or passed trips with, so read the timetable directly.
        final departures = await GtfsDatabase.forLocale(alarm.localeCode)
            .getUpcomingDepartures(alarm.gtfsStopId, limit: 100);
        scheduledMinutes = departures
            .where((d) => alarm.routeNumbers.keys.contains(d.routeShortName))
            .map((d) => d.minutesFromNow)
            .toList();
      }
      final matching = scheduledMinutes
          .where((minutes) =>
              minimumArrivalSeconds == null ||
              minutes * 60 >= minimumArrivalSeconds)
          .toList()
        ..sort();
      if (matching.isEmpty) {
        return ArrivalLookup(
          arrivalAt: null,
          liveRequestFailed: liveRequestFailed,
          usedSchedule: true,
        );
      }
      final arrivalAt = now.add(Duration(minutes: matching.first));
      final latest = await _findAlarm(alarm.id);
      if (latest != null && latest.androidFallbackArrivalEpochSeconds == null) {
        await _storage.updateAlarm(
          latest.copyWith(
            androidFallbackArrivalEpochSeconds: _epochSeconds(arrivalAt),
          ),
        );
      }
      return ArrivalLookup(
        arrivalAt: arrivalAt,
        liveRequestFailed: liveRequestFailed,
        usedSchedule: true,
      );
    } catch (_) {
      return ArrivalLookup(
        arrivalAt: null,
        liveRequestFailed: liveRequestFailed,
        usedSchedule: false,
      );
    }
  }

  /// Providers whose saved route URLs return the HK operators' ETA JSON,
  /// which [_fetchRouteEta] reads directly.
  static const _operatorJsonProviders = {'kmb', 'ctb'};

  bool _usesOperatorJsonUrls(TransportAlarm alarm) =>
      alarm.routeApiConfigs.isNotEmpty &&
      alarm.routeApiConfigs.every(
        (config) => _operatorJsonProviders.contains(config.providerCode),
      );

  /// Live arrival times from one route's saved operator API URL (the HK
  /// operators' JSON). Unhealthy when the request or its response fails.
  Future<RouteEtaResult> _fetchRouteEta(AlarmRouteConfig config) async {
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

  /// Whether the occurrence hasn't found its bus yet. Until it has, only a
  /// bus at least the largest threshold away counts, so the first ring
  /// isn't for a bus already too close to ring for.
  bool _firstThresholdIsStillRequired(TransportAlarm alarm) {
    return alarm.thresholdStates.isNotEmpty &&
        alarm.thresholdStates.every(
          (state) => state.outcome == ThresholdOutcome.pending,
        ) &&
        alarm.lastEstimatedMinutesUntilThreshold == null &&
        alarm.androidFallbackArrivalEpochSeconds == null;
  }

  /// Shows why there's no live arrival, or clears the notice once there is
  /// one. Notices are only raised or switched when [canRaise]: other checks
  /// may run while Doze has cut off the network, and their failures would
  /// raise false alarms. Any live arrival clears the notice.
  Future<TransportAlarm> _updateLiveNotice(
    TransportAlarm alarm,
    ArrivalLookup lookup, {
    required bool canRaise,
  }) async {
    final notice = lookup.liveFound
        ? null
        : lookup.liveRequestFailed
        ? AndroidLiveNotice.requestFailed
        : lookup.arrivalAt != null
        ? AndroidLiveNotice.usingTimetable
        : AndroidLiveNotice.noBusFound;
    if (notice?.name == alarm.androidLiveNotice) return alarm;
    if (notice == null) {
      final cleared = alarm.copyWith(clearAndroidLiveNotice: true);
      await _storage.updateAlarm(cleared);
      await NotificationService.cancel(_statusNotificationId(alarm.id));
      return cleared;
    }
    if (!canRaise) return alarm;

    final updated = alarm.copyWith(androidLiveNotice: notice.name);
    await _storage.updateAlarm(updated);
    final mode = AppStrings.transportModeValues(alarm.transportMode);
    switch (notice) {
      case AndroidLiveNotice.requestFailed:
        await NotificationService.showAlert(
          notificationId: _statusNotificationId(alarm.id),
          alarmId: alarm.id,
          title: AppStrings.text('notification.live_unavailable'),
          body: alarm.liveOnly
              ? AppStrings.text('notification.live_failed.body')
              : lookup.arrivalAt != null
              ? AppStrings.text('notification.live_failed_schedule.body')
              : AppStrings.text('notification.live_failed_no_bus.body', mode),
        );
      case AndroidLiveNotice.usingTimetable:
        await NotificationService.showSilentStatus(
          notificationId: _statusNotificationId(alarm.id),
          alarmId: alarm.id,
          title: AppStrings.text('notification.using_timetable'),
          body: AppStrings.text('notification.using_timetable.body', mode),
        );
      case AndroidLiveNotice.noBusFound:
        // Sounds like a failed request: with no bus, the alarm can't ring.
        await NotificationService.showAlert(
          notificationId: _statusNotificationId(alarm.id),
          alarmId: alarm.id,
          title: AppStrings.text('notification.no_bus_found', mode),
          body: alarm.liveOnly
              ? AppStrings.text('notification.no_live_bus_found.body', mode)
              : AppStrings.text('notification.no_bus_found.body', mode),
        );
    }
    return updated;
  }

  /// Schedules the next arrival check one minute from now, measured after
  /// the fetch that just finished whether it succeeded or failed, or the
  /// window end if that comes first. The threshold "fire" callback is
  /// separate, so a ring due sooner still happens on time.
  Future<void> _scheduleNextCheck(TransportAlarm alarm) async {
    final now = DateTime.now();
    final retryAt = now.add(const Duration(minutes: 1));
    final end = _windowEnd(alarm) ?? retryAt;
    if (retryAt.isBefore(end)) {
      await _schedule(alarm, retryAt, 'check');
    } else {
      await _schedule(alarm, end, 'windowEnd');
    }
  }

  /// Keeps a guaranteed check pending: 10 minutes out after a check that
  /// got live data, 5 after one that didn't. Each check replaces it, so it
  /// only fires once live data has been missing for that long. It's an
  /// alarm clock alarm, which Doze can't delay and which brings the phone
  /// out of Doze with network access, unlike the one-minute checks.
  Future<void> _scheduleLiveCheck(
    TransportAlarm alarm, {
    required bool gotLiveData,
  }) async {
    final checkAt = DateTime.now().add(
      gotLiveData ? const Duration(minutes: 10) : const Duration(minutes: 5),
    );
    final end = _windowEnd(alarm);
    if (end != null && !checkAt.isBefore(end)) {
      // The window ends first; the regular checks cover the rest.
      await _cancel(_liveCheckAlarmId(alarm.id));
      return;
    }
    await _schedule(alarm, checkAt, 'liveCheck');
  }

  /// Arms the AlarmManager callback for [event]: 'windowStart', 'check',
  /// 'windowEnd', 'fire' (a threshold ring) or 'liveCheck'. An event due at
  /// or after the window end becomes the window end instead.
  Future<void> _schedule(
    TransportAlarm alarm,
    DateTime time,
    String event,
  ) async {
    final now = DateTime.now();
    var scheduledEvent = event;
    var scheduledTime = time;
    final windowEnd = _windowEnd(alarm);
    if (event != 'windowStart' && event != 'windowEnd' && windowEnd != null) {
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
      switch (scheduledEvent) {
        'fire' => _fireAlarmId(alarm.id),
        'liveCheck' => _liveCheckAlarmId(alarm.id),
        _ => _checkAlarmId(alarm.id),
      },
      androidAlarmManagerCallback,
      // Threshold rings and the guaranteed live check use Android's alarm
      // clock scheduling, which Doze can't delay. The minute-by-minute checks
      // stay ordinary exact alarms, which Doze may space out while idle.
      alarmClock: scheduledEvent == 'fire' || scheduledEvent == 'liveCheck',
      exact: true,
      allowWhileIdle: true,
      wakeup: true,
      rescheduleOnReboot: true,
      params: {'alarmId': alarm.id, 'event': scheduledEvent},
    );
    if (!result) {
      throw StateError('Android could not schedule the alarm callback.');
    }
  }

  /// Ends the current occurrence: a one-off alarm turns off, and a repeating
  /// one arms its next window. Shows the arrival notice when the bus came,
  /// or a warning when the window ended without live data.
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
        clearIgnoreArrivalsBefore: true,
        clearAndroidOccurrence: true,
        clearAndroidFallbackArrival: true,
      );
      await _storage.updateAlarm(concluded);
      if (!dueToWindowEnd) {
        await _showFinalArrival(concluded);
      } else if (alarm.androidLiveNotice != null) {
        await _showWindowEndedWarning(alarm, hasNextRepeat: false);
      } else {
        await NotificationService.cancel(_statusNotificationId(alarm.id));
      }
      await NotificationService.cancel(_ringNotificationId(alarm.id));
      return;
    }

    final occurrenceEnd = _windowEnd(alarm) ?? now;
    var nextWindow = _nextOccurrence(alarm, occurrenceEnd);
    if (!nextWindow.end.isAfter(now)) {
      nextWindow = _activeWindow(alarm, now) ?? _nextOccurrence(alarm, now);
    }
    final concluded = alarm.copyWith(
      spent: true,
      clearLastEstimatedMinutesUntilThreshold: true,
      clearIgnoreArrivalsBefore: true,
      clearAndroidFallbackArrival: true,
      clearAndroidProgressStartEpochSeconds: true,
      androidOccurrenceStartEpochSeconds: _epochSeconds(nextWindow.start),
      androidOccurrenceEndEpochSeconds: _epochSeconds(nextWindow.end),
    );
    await _storage.updateAlarm(concluded);
    if (!dueToWindowEnd) {
      await _showFinalArrival(concluded);
    } else if (alarm.androidLiveNotice != null) {
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

  DateTime _androidProgressStartTime(TransportAlarm alarm, DateTime fallback) =>
      _fromEpochSeconds(alarm.androidProgressStartEpochSeconds) ?? fallback;

  DateTime? _windowEnd(TransportAlarm alarm) =>
      _fromEpochSeconds(alarm.androidOccurrenceEndEpochSeconds);

  static int _epochSeconds(DateTime time) => time.millisecondsSinceEpoch ~/ 1000;

  static DateTime? _fromEpochSeconds(int? seconds) =>
      seconds == null ? null : DateTime.fromMillisecondsSinceEpoch(seconds * 1000);

  /// Every threshold back to pending, for a new occurrence.
  static List<ThresholdState> _freshThresholds(TransportAlarm alarm) => alarm.thresholdStates
      .map((state) => ThresholdState(minutesBeforeArrival: state.minutesBeforeArrival))
      .toList();

  Future<void> _cancelScheduledCallbacks(String alarmId) async {
    await _cancel(_checkAlarmId(alarmId));
    await _cancel(_fireAlarmId(alarmId));
    await _cancel(_liveCheckAlarmId(alarmId));
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
    final routes = alarm.routeNumbers.keys.join(', ');
    if (stopName == null) {
      return AppStrings.text('notification.routes_approaching', {'routes': routes});
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

  /// The window that contains [now], if it started on a day the alarm
  /// repeats on. Windows crossing midnight belong to the day they start.
  WindowOccurrence? _activeWindow(TransportAlarm alarm, DateTime now) {
    for (var offset = -1; offset <= 0; offset++) {
      final date = DateTime(now.year, now.month, now.day + offset);
      if (!alarm.repeat.occursOn(date)) continue;
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
      if (alarm.repeat.occursOn(date)) return occurrence;
    }
    throw StateError('Could not find the next repeat window.');
  }

  /// A 30-bit hash of the alarm ID (FNV-1a), stable across launches, for
  /// AlarmManager and notification IDs.
  int _stableId(String alarmId) {
    var hash = 0x811c9dc5;
    for (final unit in alarmId.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0x7fffffff;
    }
    return hash & 0x3fffffff;
  }

  int _checkAlarmId(String alarmId) => _stableId(alarmId) * 2;
  int _fireAlarmId(String alarmId) => _stableId(alarmId) * 2 + 1;
  // Negative, so it can't collide with any alarm's check or fire ID.
  int _liveCheckAlarmId(String alarmId) => -(_stableId(alarmId) * 2) - 1;
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
  final alarmId = params['alarmId'] as String?;
  if (alarmId == null) return;
  final coordinator = AndroidAlarmCoordinator(AlarmStorageService());
  try {
    final languageCode = await LocaleSelectionService().getAppLanguageCode();
    await AppStrings.load(languageCode);
    await NotificationService.initBackground();
    await coordinator.handleScheduledCallback(
      alarmId: alarmId,
      event: params['event'] as String? ?? 'check',
    );
  } catch (error, stackTrace) {
    debugPrint('Android alarm callback failed: $error\n$stackTrace');
    try {
      await coordinator.scheduleRecoveryCheck(alarmId);
    } catch (retryError) {
      debugPrint('Android alarm recovery check failed: $retryError');
    }
  }
}

/// One occurrence of an alarm's window, as real times.
class WindowOccurrence {
  final DateTime start;
  final DateTime end;

  const WindowOccurrence({required this.start, required this.end});
}

/// One route's live arrivals, and whether its request worked.
class RouteEtaResult {
  final bool healthy;
  final List<DateTime> arrivals;

  const RouteEtaResult({this.healthy = false, this.arrivals = const []});
}

/// The arrival a check found, and where it came from.
class ArrivalLookup {
  final DateTime? arrivalAt;
  final bool liveRequestFailed;
  final bool usedSchedule;

  const ArrivalLookup({
    required this.arrivalAt,
    required this.liveRequestFailed,
    required this.usedSchedule,
  });

  bool get liveFound => arrivalAt != null && !usedSchedule;
}

/// Why an alarm has no live arrival, shown as one status notification.
enum AndroidLiveNotice {
  /// A live request failed. Plays a sound.
  requestFailed,

  /// Live data works but tracks no bus yet; the timetable is in use. Silent.
  usingTimetable,

  /// Live data works but there's no live bus, and no timetable bus either
  /// (or the alarm is live only). Plays a sound.
  noBusFound,
}
