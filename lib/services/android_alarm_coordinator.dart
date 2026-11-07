import 'dart:convert';
import 'dart:ui' show DartPluginRegistrant;

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:transport_alarm/models/alarm_route_config.dart';
import 'package:transport_alarm/models/transport_alarm.dart';
import 'package:transport_alarm/services/arrival_lock.dart';
import 'package:transport_alarm/services/boarding_window.dart';
import 'package:transport_alarm/services/bus_following.dart';
import 'package:transport_alarm/l10n/app_strings.dart';
import 'package:transport_alarm/services/alarm_storage_service.dart';
import 'package:transport_alarm/services/notification_service.dart';
import 'package:transport_alarm/transit/models/repeat_pattern.dart';
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
    final activeWindow = alarm.activeOccurrenceAt(now);
    final occurrence = activeWindow ?? alarm.nextOccurrenceAfter(now);
    final prepared = alarm.copyWith(
      enabled: true,
      spent: false,
      thresholdStates: _freshThresholds(alarm),
      clearLastEstimatedMinutesUntilThreshold: true,
      clearLockedArrival: true,
      skippedArrivals: const [],
      clearNextBusAfter: true,
      clearAndroidLiveNotice: true,
      androidOccurrenceStartEpochSeconds: _epochSeconds(occurrence.activeFrom),
      androidOccurrenceEndEpochSeconds: _epochSeconds(occurrence.activeUntil),
      androidProgressStartEpochSeconds: _epochSeconds(now),
    );
    await _storage.updateAlarm(prepared);
    await _cancelScheduledCallbacks(prepared.id);
    if (activeWindow != null) {
      await _checkAlarm(prepared.id);
    } else {
      await _schedule(prepared, occurrence.activeFrom, 'windowStart');
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
        clearLockedArrival: startsRepeat,
        skippedArrivals: startsRepeat ? const [] : null,
        clearNextBusAfter: startsRepeat,
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

  /// One arrival check: finds the bus to aim at within the boarding window
  /// (see decideLock), then rings, arms the threshold's "fire" callback and
  /// countdown, or ends the occurrence, and always leaves another check
  /// pending. [guaranteedCheck] is true for the guaranteed live check, the
  /// only check sure to have network access; see [_updateLiveNotice].
  Future<void> _checkAlarm(
    String alarmId, {
    bool guaranteedCheck = false,
  }) async {
    var alarm = await _findAlarm(alarmId);
    if (alarm == null) {
      // Deleted, perhaps while a check of it was running: clear anything
      // that check left behind.
      await disable(alarmId);
      return;
    }
    if (!alarm.enabled || alarm.spent) return;

    // Its region's data is gone: the region was turned off, which deletes
    // its alarms too. Stop here, clearing anything this alarm left behind.
    try {
      await GtfsDatabase.forLocale(alarm.localeCode).database;
    } on LocaleDataMissingException {
      await disable(alarmId);
      return;
    }

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

    // The boarding window this occurrence is for, worked back from when it
    // became active and when it ends.
    final boarding = _boardingWindow(alarm, startsAt, endsAt);

    var activeThresholdIndex = alarm.thresholdStates.indexWhere(
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

    debugPrint(
      '[AndroidAlarmCoordinator] Refreshing ETA for alarm ${alarm.id} '
      'at ${now.toIso8601String()}',
    );
    final lookup = await _lookupCandidates(alarm);
    alarm = await _findAlarm(alarm.id) ?? alarm;
    final freshOccurrence = alarm.lockedArrival == null &&
        alarm.thresholdStates.every((state) => state.outcome == ThresholdOutcome.pending);
    final decision = decideLock(
      candidates: lookup.candidates,
      windowStart: boarding.from,
      windowEnd: boarding.until,
      now: now,
      current: alarm.lockedArrival,
      skipped: alarm.skippedArrivals.toSet(),
      liveOnly: alarm.liveOnly,
      stableIds: canFollowOneBus(alarm),
      onlyAfter: _fromEpochSeconds(alarm.nextBusAfterEpochSeconds),
    );
    final locked = decision.locked;
    debugPrint(
      '[AndroidAlarmCoordinator] ETA refresh for alarm ${alarm.id}: '
      '${locked?.arrival.toIso8601String() ?? 'no bus in the window'}',
    );
    alarm = locked == null
        ? alarm.copyWith(clearLockedArrival: true)
        // Once "Next bus" has found its bus, later picks are unrestricted.
        : alarm.copyWith(lockedArrival: locked, clearNextBusAfter: decision.changedBus);
    await _storage.updateAlarm(alarm);
    alarm = await _updateLiveNotice(
      alarm,
      ArrivalLookup(
        arrivalAt: locked?.arrival,
        liveRequestFailed: lookup.liveRequestFailed,
        usedSchedule: locked != null && (!locked.isLive || decision.stale),
      ),
      canRaise: guaranteedCheck,
    );
    if (!DateTime.now().isBefore(endsAt)) {
      await _finishOccurrence(alarm, dueToWindowEnd: true);
      return;
    }
    if (locked == null) {
      // No bus within the window: once the window has passed there won't
      // be one, so end; until then keep looking.
      if (!now.isBefore(boarding.until)) {
        await _finishOccurrence(alarm, dueToWindowEnd: true);
      } else {
        await _waitForArrival(alarm);
      }
      return;
    }
    await _scheduleLiveCheck(alarm, gotLiveData: locked.isLive && !decision.stale);

    // When the bus is first picked, thresholds whose ring time has already
    // passed (a late start) are skipped. A bus too close for every one rings
    // nothing, and the occurrence ends.
    if (freshOccurrence) {
      final ahead = thresholdsStillAhead(
        alarm.thresholdStates.map((state) => state.minutesBeforeArrival).toList(),
        locked.arrival,
        now,
      );
      if (ahead.isEmpty) {
        await _finishOccurrence(alarm, dueToWindowEnd: true);
        return;
      }
      if (ahead.first > 0) {
        alarm = alarm.copyWith(thresholdStates: [
          for (var i = 0; i < alarm.thresholdStates.length; i++)
            i < ahead.first
                ? alarm.thresholdStates[i].copyWith(outcome: ThresholdOutcome.missed)
                : alarm.thresholdStates[i],
        ]);
        await _storage.updateAlarm(alarm);
        activeThresholdIndex = ahead.first;
      }
    }

    // While the locked bus is missing from the feed, the countdown aims at
    // its last known time; [staleSince] says when that was, for display.
    final arrivalAt = locked.arrival;
    final staleSince = decision.stale
        ? _fromEpochSeconds(locked.lastSeenEpochSeconds)
        : null;

    if (activeThresholdIndex >= 0) {
      final threshold = alarm.thresholdStates[activeThresholdIndex];
      final thresholdAt = arrivalAt.subtract(
        Duration(minutes: threshold.minutesBeforeArrival),
      );
      final remainingSeconds = thresholdAt.difference(now).inSeconds;
      final minutesUntilThreshold = (remainingSeconds / 60).ceil();
      alarm = alarm.copyWith(
        lastEstimatedMinutesUntilThreshold: minutesUntilThreshold,
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
          transportMode: alarm.transportMode,
          title: AppStrings.text('notification.next_transport_alarm', {
            ...AppStrings.transportModeValues(alarm.transportMode),
          }),
          body: _ringBody(alarm, await _stopName(alarm)),
          progressStartTime: _androidProgressStartTime(alarm, now),
          countdownTargetTime: thresholdAt,
          staleSince: staleSince,
          estimatedArrivalTime: arrivalAt,
          thresholdTimes: alarm.thresholdStates
              .map(
                (state) => arrivalAt.subtract(
                  Duration(minutes: state.minutesBeforeArrival),
                ),
              )
              .toList(),
          canSkipBus: _canSkipBus(alarm),
        );
      } else {
        await NotificationService.cancel(_countdownNotificationId(alarm.id));
      }
      await _scheduleNextCheck(alarm, firesAt: thresholdAt);
      return;
    }

    // Once thresholds are acknowledged, the final transport alert is visible but silent.
    final arrivalAlertAt = arrivalAt.subtract(const Duration(seconds: 20));
    if (!now.isBefore(arrivalAlertAt)) {
      await _finishOccurrence(alarm, dueToWindowEnd: false);
      return;
    }

    await _schedule(alarm, arrivalAlertAt, 'fire');
    if (arrivalAlertAt.isBefore(endsAt)) {
      await NotificationService.showCountdown(
        notificationId: _countdownNotificationId(alarm.id),
        alarmId: alarm.id,
        transportMode: alarm.transportMode,
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
        countdownTargetTime: arrivalAt,
        staleSince: staleSince,
        estimatedArrivalTime: arrivalAt,
        thresholdTimes: alarm.thresholdStates
            .map(
              (state) => arrivalAt.subtract(
                Duration(minutes: state.minutesBeforeArrival),
              ),
            )
            .toList(),
        canSkipBus: _canSkipBus(alarm),
      );
    } else {
      await NotificationService.cancel(_countdownNotificationId(alarm.id));
    }
    await _scheduleNextCheck(alarm, firesAt: arrivalAlertAt);
  }

  /// With no arrival to aim for, drops any armed ring and countdown and
  /// just checks again in a minute.
  Future<void> _waitForArrival(TransportAlarm alarm) async {
    await _cancel(_fireAlarmId(alarm.id));
    await NotificationService.cancel(_countdownNotificationId(alarm.id));
    await _scheduleNextCheck(alarm);
  }

  /// "Next bus": stops aiming at the locked bus, which isn't picked again
  /// this occurrence, and checks straight away for the next one arriving
  /// within the window.
  Future<void> skipToNextBus(String alarmId) async {
    final alarm = await _findAlarm(alarmId);
    final locked = alarm?.lockedArrival;
    if (alarm == null || locked == null || !_canSkipBus(alarm)) return;
    final identity = locked.identity;
    await _storage.updateAlarm(alarm.copyWith(
      skippedArrivals: [...alarm.skippedArrivals, ?identity],
      nextBusAfterEpochSeconds: locked.arrivalEpochSeconds,
    ));
    await _cancel(_fireAlarmId(alarmId));
    await _checkAlarm(alarmId);
  }

  bool _canSkipBus(TransportAlarm alarm) => canFollowOneBus(alarm);

  /// The boarding window of the occurrence active from [activeFrom] to
  /// [activeUntil] (see BoardingOccurrence).
  ({DateTime from, DateTime until}) _boardingWindow(
    TransportAlarm alarm,
    DateTime activeFrom,
    DateTime activeUntil,
  ) => (
    from: activeFrom.add(
      Duration(minutes: alarm.largestThresholdMinutes + alarm.checkLeadMinutes),
    ),
    until: activeUntil.subtract(occurrenceGrace),
  );

  /// Every bus on the alarm's routes this check could aim at: live ones,
  /// then timetabled ones not already tracked live (unless live only), and
  /// whether a live request failed, as opposed to finding no bus.
  Future<({List<ArrivalCandidate> candidates, bool liveRequestFailed})>
  _lookupCandidates(TransportAlarm alarm) async {
    var liveRequestFailed = false;
    final candidates = <ArrivalCandidate>[];

    if (_usesOperatorJsonUrls(alarm)) {
      final results = await Future.wait(
        alarm.routeApiConfigs.map(_fetchRouteEta),
      );
      for (final (index, result) in results.indexed) {
        liveRequestFailed = liveRequestFailed || !result.healthy;
        candidates.addAll(result.arrivals.map((arrival) => ArrivalCandidate(
          arrival: arrival,
          isLive: true,
          routeNumber: alarm.routeApiConfigs[index].routeNumber,
        )));
      }
      if (!alarm.liveOnly) {
        // Route-specific live APIs (HK) have no timetable trip IDs to skip
        // live trips with, so the timetable is read directly.
        try {
          final departures = await GtfsDatabase.forLocale(alarm.localeCode)
              .getUpcomingDepartures(alarm.gtfsStopId, limit: 100);
          final now = DateTime.now();
          candidates.addAll(departures
              .where((d) => alarm.routeNumbers.containsKey(d.routeShortName))
              .map((d) => ArrivalCandidate(
                    arrival: now.add(Duration(minutes: d.minutesFromNow)),
                    isLive: false,
                    routeNumber: d.routeShortName,
                    tripId: d.tripId,
                  )));
        } on LocaleDataMissingException {
          rethrow;
        } catch (_) {
          // The timetable can't be read; live arrivals may still do.
        }
      }
    } else {
      // Other providers' saved URLs (BODS, TfL) aren't this JSON, so their
      // alarms go through the shared resolver like the stop sheet does. So do
      // alarms saved before route-specific API URLs existed.
      try {
        candidates.addAll(await resolveArrivalCandidates(
          gtfsStopId: alarm.gtfsStopId,
          routeNumberFilter: alarm.routeNumbers,
          locale: alarm.localeCode,
          onLiveFetchFailed: () => liveRequestFailed = true,
        ));
      } on LocaleDataMissingException {
        rethrow;
      } catch (_) {
        liveRequestFailed = true;
      }
    }
    return (candidates: candidates, liveRequestFailed: liveRequestFailed);
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
  ///
  /// Within [_mandatoryChecksBefore] of [firesAt], the next ring or arrival
  /// alert, the check is the guaranteed live check instead, which Doze can't
  /// delay or cut off from the network, so the last estimates before it
  /// fires are fresh.
  Future<void> _scheduleNextCheck(TransportAlarm alarm, {DateTime? firesAt}) async {
    final now = DateTime.now();
    final retryAt = now.add(const Duration(minutes: 1));
    final end = _windowEnd(alarm) ?? retryAt;
    final firesSoon = firesAt != null && firesAt.difference(now) <= _mandatoryChecksBefore;
    if (retryAt.isBefore(end) && firesSoon) {
      await _cancel(_checkAlarmId(alarm.id));
      await _schedule(alarm, retryAt, 'liveCheck');
    } else if (retryAt.isBefore(end)) {
      await _schedule(alarm, retryAt, 'check');
    } else {
      await _schedule(alarm, end, 'windowEnd');
    }
  }

  static const _mandatoryChecksBefore = Duration(minutes: 5);

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
        clearAndroidOccurrence: true,
        clearLockedArrival: true,
        skippedArrivals: const [],
        clearNextBusAfter: true,
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

    // The next occurrence that becomes active after this one: occurrences
    // can overlap when the window is long, and one that started while this
    // one ran is skipped rather than started late.
    final nextWindow = alarm.nextOccurrenceAfter(now);
    final concluded = alarm.copyWith(
      spent: true,
      clearLastEstimatedMinutesUntilThreshold: true,
      clearLockedArrival: true,
      skippedArrivals: const [],
      clearNextBusAfter: true,
      clearAndroidProgressStartEpochSeconds: true,
      androidOccurrenceStartEpochSeconds: _epochSeconds(nextWindow.activeFrom),
      androidOccurrenceEndEpochSeconds: _epochSeconds(nextWindow.activeUntil),
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
    await _schedule(concluded, nextWindow.activeFrom, 'windowStart');
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
    } on LocaleDataMissingException {
      rethrow;
    } catch (_) {
      return null;
    }
  }

  /// The ring notification's text for [alarm], for the ring screen.
  Future<String> ringBody(TransportAlarm alarm) async =>
      _ringBody(alarm, await _stopName(alarm));

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
    // Only checked: this also runs in the background, where nothing can be
    // asked. The app asks before saving or turning on an alarm.
    if (!await NotificationService.canScheduleExactAlarms()) {
      throw StateError(
        'Allow Transport Alarm under Android “Alarms & reminders” to schedule alarms.',
      );
    }
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
  } on LocaleDataMissingException {
    // The region's data was deleted partway through the check, as the
    // region was turned off: stop rather than schedule a recovery check.
    try {
      await coordinator.disable(alarmId);
    } catch (error) {
      debugPrint('Android alarm cleanup failed: $error');
    }
  } catch (error, stackTrace) {
    debugPrint('Android alarm callback failed: $error\n$stackTrace');
    try {
      await coordinator.scheduleRecoveryCheck(alarmId);
    } catch (retryError) {
      debugPrint('Android alarm recovery check failed: $retryError');
    }
  }
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
