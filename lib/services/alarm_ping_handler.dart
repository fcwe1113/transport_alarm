import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:transport_alarm/models/alarm_route_config.dart';
import 'package:transport_alarm/models/bus_alarm.dart';
import 'package:transport_alarm/provider_registry.dart';
import 'package:transport_alarm/services/alarm_engine.dart';
import 'package:transport_alarm/services/alarm_lifecycle_service.dart';
import 'package:transport_alarm/services/alarm_server_service.dart';
import 'package:transport_alarm/services/alarm_storage_service.dart';
import 'package:transport_alarm/transit/models/repeat_pattern.dart';
import 'package:transport_alarm/transit/models/threshold_state.dart';
import 'package:transport_alarm/transit/services/arrival_resolver.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:transport_alarm/services/notification_service.dart';

class AlarmPingHandler {
  final AlarmStorageService _storage;
  final AlarmServerService _server;
  final AlarmLifecycleService _alarmLifecycle;

  AlarmPingHandler(this._storage, this._server, this._alarmLifecycle);

  // call this on receiving ping
  Future<AlarmPingPresentation> handlePing(
    String pingId, {
    bool showLocalNotification = true,
  }) async {
    final alarms = await _storage.loadAlarms();
    var alarm = alarms.where((a) => a.pingId == pingId).firstOrNull;
    print("handler received ping id: ${pingId}");

    if (alarm == null) {
      // ping came for a nonexistent/disabled alarm
      await _server.cancelPing(pingId); // tell server to cancel ping
      return const AlarmPingPresentation(
        action: 'noMatchingAlarm',
        title: 'Alarm not active',
        body: 'No active alarm matches this notification.',
      );
    }

    // The next scheduled repeat starts a fresh occurrence and may ring again.
    if (alarm.spent && alarm.repeat.frequency != RepeatFrequency.none) {
      alarm = alarm.copyWith(
        spent: false,
        thresholdStates: alarm.thresholdStates
            .map(
              (state) => ThresholdState(
                minutesBeforeArrival: state.minutesBeforeArrival,
              ),
            )
            .toList(),
        clearLastEstimatedMinutesUntilThreshold: true,
      );
      await _storage.updateAlarm(alarm);
    }

    final activeThreshold = alarm.thresholdStates
        .where(
          (state) =>
              state.outcome == ThresholdOutcome.pending ||
              state.outcome == ThresholdOutcome.ringing,
        )
        .firstOrNull;
    final fetchedArrivalEstimate = await _getMinutesUntilArrival(alarm);
    final fetchedEstimateUntilThreshold =
        fetchedArrivalEstimate == null || activeThreshold == null
        ? null
        : fetchedArrivalEstimate - activeThreshold.minutesBeforeArrival;
    final alarmWithLatestEstimate = fetchedEstimateUntilThreshold == null
        ? alarm
        : alarm.copyWith(
            lastEstimatedMinutesUntilThreshold: fetchedEstimateUntilThreshold,
          );
    // Keep using the last successful estimate when a live lookup fails.
    final minutesUntilThreshold =
        fetchedEstimateUntilThreshold ??
        alarm.lastEstimatedMinutesUntilThreshold;
    final decision = evaluateAlarm(
      alarm: alarmWithLatestEstimate,
      minutesUntilThreshold: minutesUntilThreshold,
    );
    await _storage.updateAlarm(decision.updatedAlarm);
    if (decision.action == AlarmAction.ring && decision.nextPingTime == null) {
      await _alarmLifecycle.handleOccurenceConcluded(alarm);
    }

    switch (decision.action) {
      case AlarmAction.ring:
        if (showLocalNotification) {
          await _triggerRing(decision.updatedAlarm);
        }
        if (decision.nextPingTime != null) {
          await _server.reschedule(
            pingId: pingId,
            scheduledTime: decision.nextPingTime!,
            requireAck: decision.nextPingRequiresAck,
            expireOn: decision.expireOn,
          );
        }
        return const AlarmPingPresentation(
          action: 'ring',
          title: 'Alarm decision: ring',
          body: 'The alarm reached its ring condition.',
        );
      case AlarmAction.scheduleNextPing:
        await _server.reschedule(
          pingId: pingId,
          scheduledTime: decision.nextPingTime!,
          requireAck: decision.nextPingRequiresAck,
          expireOn: decision.expireOn,
        );
        return const AlarmPingPresentation(
          action: 'scheduleNextPing',
          title: 'Alarm decision: rescheduled',
          body: 'The alarm remains active and another ping was scheduled.',
        );
      case AlarmAction.doNothing:
        await _server.cancelPing(pingId);
        return const AlarmPingPresentation(
          action: 'doNothing',
          title: 'Alarm decision: no action',
          body: 'No further alarm action is needed.',
        );
    }
  }

  Future<void> acknowledge(String alarmId) async {
    final alarms = await _storage.loadAlarms();
    final alarm = alarms.where((a) => a.id == alarmId).firstOrNull;
    if (alarm == null) return;

    final activeIndex = alarm.thresholdStates.indexWhere(
      (t) => t.outcome == ThresholdOutcome.ringing,
    );
    if (activeIndex == -1) return;

    final updatedStates = List<ThresholdState>.from(alarm.thresholdStates);
    updatedStates[activeIndex] = updatedStates[activeIndex].copyWith(
      outcome: ThresholdOutcome.acknowledged,
    );
    final updatedAlarm = alarm.copyWith(thresholdStates: updatedStates);

    await _storage.updateAlarm(updatedAlarm);

    final nextPendingIndex = updatedStates.indexWhere(
      (state) => state.outcome == ThresholdOutcome.pending,
    );
    if (nextPendingIndex == -1) {
      if (updatedAlarm.repeat.frequency != RepeatFrequency.none &&
          updatedAlarm.pingId != null) {
        await _server.cancelPing(updatedAlarm.pingId!);
      }
      await _alarmLifecycle.handleOccurenceConcluded(updatedAlarm);
      return;
    }

    final nextThreshold = updatedStates[nextPendingIndex];
    final currentThreshold = alarm.thresholdStates[activeIndex];
    final fetchedArrivalEstimate = await _getMinutesUntilArrival(updatedAlarm);
    final minutesUntilNextThreshold = fetchedArrivalEstimate != null
        ? fetchedArrivalEstimate - nextThreshold.minutesBeforeArrival
        : updatedAlarm.lastEstimatedMinutesUntilThreshold == null
        ? null
        : updatedAlarm.lastEstimatedMinutesUntilThreshold! +
              currentThreshold.minutesBeforeArrival -
              nextThreshold.minutesBeforeArrival;
    final alarmWithLatestEstimate = minutesUntilNextThreshold == null
        ? updatedAlarm
        : updatedAlarm.copyWith(
            lastEstimatedMinutesUntilThreshold: minutesUntilNextThreshold,
          );
    if (minutesUntilNextThreshold != null) {
      await _storage.updateAlarm(alarmWithLatestEstimate);
    }

    if (minutesUntilNextThreshold == null) {
      if (alarm.pingId != null) {
        await _server.reschedule(
          pingId: alarm.pingId!,
          scheduledTime: DateTime.now().add(const Duration(minutes: 1)),
          requireAck: false,
        );
      }
      return;
    }
    final DateTime nextPingTime;
    final bool requireAck;
    if (minutesUntilNextThreshold > 5) {
      final estimateHalf = (minutesUntilNextThreshold / 2).round();
      nextPingTime = DateTime.now().add(
        Duration(minutes: estimateHalf < 1 ? 1 : estimateHalf),
      );
      requireAck = false;
    } else if (minutesUntilNextThreshold > 0) {
      nextPingTime = DateTime.now().add(
        Duration(minutes: minutesUntilNextThreshold),
      );
      requireAck = true;
    } else {
      // The next threshold is already due or less than a minute away; check it
      // on the next server ping and keep the same alarm ping ID.
      nextPingTime = DateTime.now().add(const Duration(minutes: 1));
      requireAck = true;
    }
    if (alarm.pingId != null) {
      await _server.reschedule(
        pingId: alarm.pingId!,
        scheduledTime: nextPingTime,
        requireAck: requireAck,
      );
    }
  }

  Future<int?> _getMinutesUntilArrival(BusAlarm alarm) async {
    final isFreshOccurrence =
        alarm.lastEstimatedMinutesUntilThreshold == null &&
        alarm.thresholdStates.isNotEmpty &&
        alarm.thresholdStates.every(
          (state) => state.outcome == ThresholdOutcome.pending,
        );
    final minimumArrivalMinutes = isFreshOccurrence
        ? alarm.thresholdStates
              .map((state) => state.minutesBeforeArrival)
              .reduce((a, b) => a > b ? a : b)
        : null;

    if (alarm.routeApiConfigs.isNotEmpty) {
      final liveDates = await Future.wait(
        alarm.routeApiConfigs.map(_fetchArrivalFromRouteConfig),
      );
      final arrivals =
          liveDates
              .expand((dates) => dates)
              .where(
                (date) =>
                    minimumArrivalMinutes == null ||
                    date.difference(DateTime.now().toUtc()).inMinutes >=
                        minimumArrivalMinutes,
              )
              .toList()
            ..sort();
      if (arrivals.isNotEmpty) {
        return arrivals.first.difference(DateTime.now().toUtc()).inMinutes;
      }
      if (alarm.liveOnly) return null;

      // Keep the existing scheduled timetable fallback when live APIs have no ETA.
      final scheduled = await GtfsDatabase.forLocale(alarm.localeCode)
          .getUpcomingDepartures(alarm.gtfsStopId, limit: 50);
      final matching =
          scheduled
              .where(
                (departure) =>
                    alarm.routeNumbers.contains(departure.routeShortName) &&
                    (minimumArrivalMinutes == null ||
                        departure.minutesFromNow >= minimumArrivalMinutes),
              )
              .toList()
            ..sort((a, b) => a.minutesFromNow.compareTo(b.minutesFromNow));
      return matching.isEmpty ? null : matching.first.minutesFromNow;
    }

    // Older saved alarms do not yet have route-specific API URLs.
    final arrivals = await resolveArrivals(
      gtfsStopId: alarm.gtfsStopId,
      routeNumberFilter: alarm.routeNumbers,
      minimumMinutesFromNow: minimumArrivalMinutes,
    );
    final eligible = alarm.liveOnly
        ? arrivals.where((a) => a.isLive)
        : arrivals;
    if (eligible.isEmpty) return null;
    return eligible
        .reduce((a, b) => a.minutesFromNow < b.minutesFromNow ? a : b)
        .minutesFromNow;
  }

  Future<List<DateTime>> _fetchArrivalFromRouteConfig(
    AlarmRouteConfig config,
  ) async {
    if (config.mode != 'bus') return const [];
    try {
      final response = await http
          .get(Uri.parse(config.apiUrl))
          .timeout(const Duration(seconds: 3));
      if (response.statusCode != 200) return const [];
      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final data = payload['data'] as List<dynamic>? ?? const [];
      final dates =
          data
              .whereType<Map<String, dynamic>>()
              .where((entry) {
                return entry['route'] == config.routeNumber &&
                    entry['eta'] is String;
              })
              .map(
                (entry) => DateTime.tryParse(entry['eta'] as String)?.toUtc(),
              )
              .whereType<DateTime>()
              .toList()
            ..sort();
      return dates;
    } catch (_) {
      return const [];
    }
  }

  Future<void> _triggerRing(BusAlarm alarm) async {
    const androidDetails = AndroidNotificationDetails(
      "transport_alarm_channel",
      "Transport Alarm",
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
      fullScreenIntent: true,
      actions: const [
        AndroidNotificationAction("acknowledge", "I\'m up / Got it"),
      ],
    );
    const darwinDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    const notificationDetails = NotificationDetails(
      android: androidDetails,
      iOS: darwinDetails,
    );

    final stop = await GtfsDatabase.forLocale("hk")
        .getGtfsStopById(alarm.gtfsStopId); // todo fix locale hardcode
    await NotificationService.plugin.show(
      id: alarm.id.hashCode,
      title: "Bus arriving soon",
      body: stop != null
          ? "Your bus is approaching ${stop.name}"
          : "Your bus is arriving",
      notificationDetails: notificationDetails,
      payload: alarm.id,
    );
  }
}

class AlarmPingPresentation {
  final String action;
  final String title;
  final String body;

  const AlarmPingPresentation({
    required this.action,
    required this.title,
    required this.body,
  });

  Map<String, String> toMap() => {
    'action': action,
    'title': title,
    'body': body,
  };
}
