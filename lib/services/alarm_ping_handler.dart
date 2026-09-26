import 'package:transport_alarm/models/bus_alarm.dart';
import 'package:transport_alarm/services/alarm_engine.dart';
import 'package:transport_alarm/services/alarm_server_service.dart';
import 'package:transport_alarm/services/alarm_storage_service.dart';
import 'package:transport_alarm/transit/services/arrival_resolver.dart';

class AlarmPingHandler {
  final AlarmStorageService _storage;
  final AlarmServerService _server;

  AlarmPingHandler(this._storage, this._server);

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

  Future<int?> _getMinutesUntilArrival(BusAlarm alarm) async {
    final arrivals = await resolveArrivals(gtfsStopId: alarm.gtfsStopId, routeNumberFilter: alarm.routeNumbers);
    final eligible = alarm.liveOnly ? arrivals.where((a) => a.isLive) : arrivals;
    if (eligible.isEmpty) return null;
    final soonest = eligible.reduce((a, b) => a.minutesFromNow < b.minutesFromNow ? a : b);
    return soonest.minutesFromNow;
  }

  Future<void> _triggerRing(BusAlarm alarm) async {
    // todo
  }
}