import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:transport_alarm/models/bus_alarm.dart';
import 'package:transport_alarm/provider_registry.dart';
import 'package:transport_alarm/services/alarm_engine.dart';
import 'package:transport_alarm/services/alarm_lifecycle_service.dart';
import 'package:transport_alarm/services/alarm_server_service.dart';
import 'package:transport_alarm/services/alarm_storage_service.dart';
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
  Future<void> handlePing(String pingId) async {
    final alarms = await _storage.loadAlarms();
    final alarm = alarms.where((a) => a.pingId == pingId).firstOrNull;

    if (alarm == null) { // ping came for a nonexistent/disabled alarm
      await _server.cancelPing(pingId); // tell server to cancel ping
      return;
    }

    final minutesUntilArrival = await _getMinutesUntilArrival(alarm);
    final decision = evaluateAlarm(alarm: alarm, minutesUntilArrival: minutesUntilArrival);
    await _storage.updateAlarm(decision.updatedAlarm);
    if (decision.action == AlarmAction.ring && decision.nextPingTime == null) {
      await _alarmLifecycle.handleOccurenceConcluded(alarm);
    }

    switch (decision.action) {
      case AlarmAction.ring:
        await _triggerRing(decision.updatedAlarm);
        if (decision.nextPingTime != null) {
          await _server.reschedule(pingId: pingId, scheduledTime: decision.nextPingTime!, requireAck: decision.nextPingRequiresAck, expireOn: decision.expireOn);
        }
        break;
      case AlarmAction.scheduleNextPing:
        await _server.reschedule(pingId: pingId, scheduledTime: decision.nextPingTime!, requireAck: decision.nextPingRequiresAck, expireOn: decision.expireOn);
        break;
      case AlarmAction.doNothing:
        await _server.cancelPing(pingId);
        break;
    }
  }

  Future<void> acknowledge(String alarmId) async {
    final alarms = await _storage.loadAlarms();
    final alarm = alarms.where((a) => a.id == alarmId).firstOrNull;
    if (alarm == null) return;

    final activeIndex = alarm.thresholdStates.indexWhere((t) => t.outcome == ThresholdOutcome.ringing);
    if (activeIndex == -1) return;

    final updatedStates = List<ThresholdState>.from(alarm.thresholdStates);
    updatedStates[activeIndex] = updatedStates[activeIndex].copyWith(outcome: ThresholdOutcome.acknowledged);
    final updatedAlarm = alarm.copyWith(thresholdStates: updatedStates);

    await _storage.updateAlarm(updatedAlarm);
    await _alarmLifecycle.handleOccurenceConcluded(updatedAlarm);

    final minutesUntilArrival = await _getMinutesUntilArrival(updatedAlarm);
    if (minutesUntilArrival == null) {
      _server.cancelPing(alarm.pingId!); // todo notify user
      return;
    }

    final arming = armNextThreshold(updatedAlarm, activeIndex, minutesUntilArrival);
    if (arming == null) {
      await _server.cancelPing(alarm.pingId!);
    } else {
      await _server.reschedule(pingId: alarm.pingId!, scheduledTime: arming.nextPingTime, requireAck: arming.requiresAck, expireOn: arming.expireOn);
    }
  }

  Future<int?> _getMinutesUntilArrival(BusAlarm alarm) async {
    final arrivals = await resolveArrivals(gtfsStopId: alarm.gtfsStopId, routeNumberFilter: alarm.routeNumbers);
    final eligible = alarm.liveOnly ? arrivals.where((a) => a.isLive) : arrivals;
    if (eligible.isEmpty) return null;
    return eligible.reduce((a, b) => a.minutesFromNow < b.minutesFromNow ? a : b).minutesFromNow;
  }

  Future<void> _triggerRing(BusAlarm alarm) async {
    const androidDetails = AndroidNotificationDetails(
        "transport_alarm_channel",
        "Transport Alarm",
        importance: Importance.max,
        priority: Priority.high,
        playSound: true,
        fullScreenIntent: true,
        actions: const [AndroidNotificationAction("acknowledge", "I\'m up / Got it")]
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

    final stop = await GtfsDatabase.forLocale("hk").getGtfsStopById(alarm.gtfsStopId); // todo fix locale hardcode
    await NotificationService.plugin.show(
        id: alarm.id.hashCode,
        title: "Bus arriving soon",
        body: stop != null ? "Your bus is approaching ${stop.name}" : "Your bus is arriving",
        notificationDetails: notificationDetails,
        payload: alarm.id
    );
  }
}