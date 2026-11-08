import 'package:transport_alarm/models/transport_alarm.dart';
import 'package:transport_alarm/services/arrival_lock.dart';
import 'package:transport_alarm/services/bus_following.dart';
import 'package:transport_alarm/transit/services/arrival_resolver.dart';

/// The buses "Previous bus" and "Next bus" would move [alarm] to, looked up
/// now, so the buttons can show their times, or stay off when there's none.
/// Both null when the alarm isn't following a bus or can't follow one.
///
/// Only alarms that can follow one bus (BODS, TfL) get these buttons, and
/// those look their arrivals up through the shared resolver, as the checks do.
Future<({LockedArrival? previous, LockedArrival? next})> findNeighbourBuses(TransportAlarm alarm) async {
  const none = (previous: null, next: null);
  final current = alarm.lockedArrival;
  if (current == null || !canFollowOneBus(alarm)) return none;
  final now = DateTime.now();
  final occurrence = alarm.activeOccurrenceAt(now);
  if (occurrence == null) return none;
  final candidates = await resolveArrivalCandidates(
    gtfsStopId: alarm.gtfsStopId,
    routeNumberFilter: alarm.routeNumbers,
    locale: alarm.localeCode,
  );
  return (
    previous: previousBusBefore(
      candidates: candidates,
      windowStart: occurrence.boardFrom,
      windowEnd: occurrence.boardUntil,
      now: now,
      current: current,
      liveOnly: alarm.liveOnly,
    ),
    next: nextBusAfter(
      candidates: candidates,
      windowStart: occurrence.boardFrom,
      windowEnd: occurrence.boardUntil,
      now: now,
      current: current,
      skipped: alarm.skippedArrivals.toSet(),
      liveOnly: alarm.liveOnly,
    ),
  );
}

/// [alarm] aiming at [bus] instead, as "Previous bus" does: [bus] is no
/// longer counted as skipped, and the "Next bus" restriction is lifted, so
/// the next check keeps following it.
TransportAlarm followingBus(TransportAlarm alarm, LockedArrival bus) => alarm.copyWith(
  lockedArrival: bus,
  skippedArrivals: alarm.skippedArrivals.where((identity) => identity != bus.identity).toList(),
  clearNextBusAfter: true,
);
