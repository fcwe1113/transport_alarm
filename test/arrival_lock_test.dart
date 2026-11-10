import 'package:flutter_test/flutter_test.dart';
import 'package:transport_alarm/services/arrival_lock.dart';

void main() {
  final windowStart = DateTime(2026, 11, 9, 8, 0);
  final windowEnd = DateTime(2026, 11, 9, 8, 30);
  final now = DateTime(2026, 11, 9, 7, 35);

  ArrivalCandidate bus(int hour, int minute, {bool live = false, String? trip, String? vehicle, String route = '1'}) =>
      ArrivalCandidate(
        arrival: DateTime(2026, 11, 9, hour, minute),
        isLive: live,
        routeNumber: route,
        tripId: trip,
        vehicleId: vehicle,
      );

  LockDecision decide(List<ArrivalCandidate> candidates, {LockedArrival? current, DateTime? at, Set<String> skipped = const {}, bool stableIds = true, DateTime? onlyAfter, bool liveOnly = false}) =>
      decideLock(
        candidates: candidates,
        windowStart: windowStart,
        windowEnd: windowEnd,
        now: at ?? now,
        current: current,
        skipped: skipped,
        stableIds: stableIds,
        onlyAfter: onlyAfter,
        liveOnly: liveOnly,
      );

  group('picking a bus', () {
    test('locks the earliest bus arriving within the window', () {
      final decision = decide([bus(7, 55, trip: 'a'), bus(8, 10, trip: 'b'), bus(8, 20, trip: 'c')]);
      expect(decision.locked?.tripId, 'b');
      expect(decision.changedBus, isTrue);
    });

    test('prefers a live bus over a timetabled one', () {
      final decision = decide([bus(8, 5, trip: 'a'), bus(8, 12, live: true, vehicle: 'v1')]);
      expect(decision.locked?.vehicleId, 'v1');
      expect(decision.locked?.isLive, isTrue);
    });

    test('ignores timetabled buses for a live-only alarm', () {
      final decision = decide([bus(8, 5, trip: 'a')], liveOnly: true);
      expect(decision.locked, isNull);
    });

    test('finds no bus when nothing arrives within the window', () {
      expect(decide([bus(7, 50, trip: 'a'), bus(8, 40, trip: 'b')]).locked, isNull);
    });

    test('counts buses at the window edges', () {
      expect(decide([bus(8, 0, trip: 'a')]).locked?.tripId, 'a');
      expect(decide([bus(8, 30, trip: 'b')]).locked?.tripId, 'b');
    });
  });

  group('sticking to the locked bus', () {
    final locked = LockedArrival.fromCandidate(bus(8, 15, trip: 'b'), now);

    test('keeps it when an earlier bus appears in the window', () {
      final decision = decide([bus(8, 5, trip: 'a'), bus(8, 16, trip: 'b')], current: locked);
      expect(decision.locked?.tripId, 'b');
      expect(decision.locked?.arrival, DateTime(2026, 11, 9, 8, 16));
      expect(decision.changedBus, isFalse);
    });

    test('switches a timetabled lock to live tracking of the same trip', () {
      final decision = decide([bus(8, 18, live: true, trip: 'b')], current: locked);
      expect(decision.locked?.isLive, isTrue);
      expect(decision.locked?.tripId, 'b');
      expect(decision.changedBus, isFalse);
    });

    test('links a timetabled lock to a live bus without a trip (TfL) by time', () {
      final decision = decide([bus(8, 20, live: true, vehicle: 'v9')], current: locked);
      expect(decision.locked?.vehicleId, 'v9');
      expect(decision.locked?.tripId, 'b');
      expect(decision.changedBus, isFalse);
    });

    test("doesn't link a live bus too far from the timetabled time", () {
      final decision = decide([bus(8, 29, live: true, vehicle: 'v9')], current: locked);
      expect(decision.locked?.vehicleId, 'v9');
      expect(decision.changedBus, isTrue);
    });
  });

  group('when the locked bus leaves the window', () {
    final locked = LockedArrival.fromCandidate(bus(8, 25, trip: 'b'), now);

    test('another bus within the window takes over when it is delayed past the end', () {
      final decision = decide([bus(8, 40, trip: 'b'), bus(8, 28, trip: 'c')], current: locked);
      expect(decision.locked?.tripId, 'c');
      expect(decision.changedBus, isTrue);
    });

    test('keeps the delayed bus when no other bus is within the window', () {
      final decision = decide([bus(8, 40, trip: 'b')], current: locked);
      expect(decision.locked?.tripId, 'b');
      expect(decision.locked?.arrival, DateTime(2026, 11, 9, 8, 40));
    });

    test('another bus takes over when the locked one drops out of the feed', () {
      final decision = decide([bus(8, 28, trip: 'c')], current: locked);
      expect(decision.locked?.tripId, 'c');
    });

    test('counts down to its last time, as stale, when nothing else is in the window', () {
      final decision = decide([], current: locked);
      expect(decision.locked?.tripId, 'b');
      expect(decision.stale, isTrue);
    });

    test("is dropped once its time passes and it hasn't reappeared", () {
      final decision = decide([], current: locked, at: DateTime(2026, 11, 9, 8, 26));
      expect(decision.locked, isNull);
      expect(decision.changedBus, isTrue);
    });
  });

  group('Next bus', () {
    test('skipping locks the next bus after the skipped one', () {
      final locked = LockedArrival.fromCandidate(bus(8, 10, trip: 'b'), now);
      final decision = decide(
        [bus(8, 5, trip: 'a'), bus(8, 10, trip: 'b'), bus(8, 20, trip: 'c')],
        current: locked,
        skipped: {'trip:b'},
        onlyAfter: locked.arrival,
      );
      expect(decision.locked?.tripId, 'c');
    });

    test('skipping with no other bus in the window leaves no bus, not the skipped one', () {
      final locked = LockedArrival.fromCandidate(bus(8, 10, trip: 'b'), now);
      final decision = decide(
        [bus(8, 10, trip: 'b')],
        current: locked,
        skipped: {'trip:b'},
        onlyAfter: locked.arrival,
      );
      expect(decision.locked, isNull);
    });

    test('a skipped bus is never locked again', () {
      final decision = decide([bus(8, 10, trip: 'b'), bus(8, 20, trip: 'c')], skipped: {'trip:b'});
      expect(decision.locked?.tripId, 'c');
    });
  });

  group('providers without stable IDs (KMB, CTB)', () {
    test('aims at the latest bus still arriving within the window', () {
      final decision = decide(
        [bus(8, 5, live: true), bus(8, 25, live: true), bus(8, 40, live: true)],
        stableIds: false,
      );
      expect(decision.locked?.arrival, DateTime(2026, 11, 9, 8, 25));
    });

    test('uses the timetable when no live bus is within the window', () {
      final decision = decide([bus(8, 10, trip: 'a'), bus(8, 22, trip: 'b')], stableIds: false);
      expect(decision.locked?.tripId, 'b');
    });
  });

  group('thresholds still ahead', () {
    final arrival = DateTime(2026, 11, 9, 8, 10);

    test('all ahead when the bus is far enough away', () {
      expect(thresholdsStillAhead([10, 5], arrival, DateTime(2026, 11, 9, 7, 50)), [0, 1]);
    });

    test('skips thresholds already past on a late start', () {
      expect(thresholdsStillAhead([10, 5], arrival, DateTime(2026, 11, 9, 8, 2)), [1]);
    });

    test('none when the bus is too close for every threshold', () {
      expect(thresholdsStillAhead([10, 5], arrival, DateTime(2026, 11, 9, 8, 6)), isEmpty);
    });
  });

  test('a lock survives a JSON round trip', () {
    final locked = LockedArrival.fromCandidate(bus(8, 10, live: true, trip: 't', vehicle: 'v'), now);
    final restored = LockedArrival.fromJson(locked.toJson())!;
    expect(restored.toJson(), locked.toJson());
  });

  group('nextBusAfter', () {
    LockedArrival? next(List<ArrivalCandidate> candidates, LockedArrival current, {Set<String> skipped = const {}}) =>
        nextBusAfter(
          candidates: candidates,
          windowStart: windowStart,
          windowEnd: windowEnd,
          now: now,
          current: current,
          skipped: skipped,
        );

    test('is the earliest other bus arriving after the followed one', () {
      final current = LockedArrival.fromCandidate(bus(8, 5, trip: 'a'), now);
      final found = next([bus(8, 5, trip: 'a'), bus(8, 25, trip: 'c'), bus(8, 15, trip: 'b')], current);
      expect(found?.tripId, 'b');
    });

    test('is none when the followed bus is the last in the window', () {
      final current = LockedArrival.fromCandidate(bus(8, 25, trip: 'c'), now);
      expect(next([bus(8, 5, trip: 'a'), bus(8, 25, trip: 'c'), bus(8, 40, trip: 'd')], current), isNull);
    });

    test('leaves out buses already skipped', () {
      final current = LockedArrival.fromCandidate(bus(8, 5, trip: 'a'), now);
      final found = next([bus(8, 15, trip: 'b'), bus(8, 25, trip: 'c')], current, skipped: {'trip:b'});
      expect(found?.tripId, 'c');
    });

    test('matches the bus a skip then locks', () {
      final current = LockedArrival.fromCandidate(bus(8, 5, trip: 'a'), now);
      final candidates = [bus(8, 5, trip: 'a'), bus(8, 12, live: true, vehicle: 'v'), bus(8, 20, trip: 'c')];
      final afterSkip = decide(candidates, current: current, skipped: {'trip:a'}, onlyAfter: current.arrival);
      expect(next(candidates, current)?.toJson(), afterSkip.locked?.toJson());
    });
  });

  group('previousBusBefore', () {
    LockedArrival? previous(List<ArrivalCandidate> candidates, LockedArrival current, {DateTime? at}) =>
        previousBusBefore(
          candidates: candidates,
          windowStart: windowStart,
          windowEnd: windowEnd,
          now: at ?? now,
          current: current,
        );

    test('is the latest bus in the window arriving before the followed one', () {
      final current = LockedArrival.fromCandidate(bus(8, 25, trip: 'c'), now);
      final found = previous([bus(8, 5, trip: 'a'), bus(8, 15, trip: 'b'), bus(8, 25, trip: 'c')], current);
      expect(found?.tripId, 'b');
    });

    test('is none for the first bus in the window, or one already gone', () {
      final first = LockedArrival.fromCandidate(bus(8, 5, trip: 'a'), now);
      expect(previous([bus(7, 50, trip: 'z'), bus(8, 5, trip: 'a')], first), isNull);
      final current = LockedArrival.fromCandidate(bus(8, 25, trip: 'c'), now);
      expect(previous([bus(8, 10, trip: 'b'), bus(8, 25, trip: 'c')], current, at: DateTime(2026, 11, 9, 8, 12)), isNull);
    });

    test('prefers a live bus, as picking does', () {
      final current = LockedArrival.fromCandidate(bus(8, 25, trip: 'c'), now);
      final found = previous([bus(8, 5, live: true, vehicle: 'v'), bus(8, 15, trip: 'b'), bus(8, 25, trip: 'c')], current);
      expect(found?.vehicleId, 'v');
    });

    test('a bus moved back to is kept by the next check', () {
      final current = LockedArrival.fromCandidate(bus(8, 25, trip: 'c'), now);
      final candidates = [bus(8, 15, trip: 'b'), bus(8, 25, trip: 'c')];
      final back = previous(candidates, current)!;
      expect(decide(candidates, current: back).locked?.tripId, 'b');
    });
  });
}
