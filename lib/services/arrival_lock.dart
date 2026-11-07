/// Which bus an alarm aims at during one occurrence, and the rules for
/// keeping or changing it. Pure logic, shared in spirit with the iOS
/// notification extension (NativePingHandler), which follows the same rules.
///
/// The alarm's window is the range of arrivals the user wants to board. The
/// first bus arriving within it is locked, and later checks follow that same
/// bus, identified by its GTFS trip ID or live vehicle ID, unless it leaves
/// the window and another bus is still arriving within it. Providers whose
/// live feed has no stable ID (KMB, CTB) aren't locked: each check aims at
/// the latest bus still arriving within the window.
library;

/// One bus the alarm could aim at.
class ArrivalCandidate {
  final DateTime arrival;
  final bool isLive;
  final String routeNumber;
  /// The GTFS trip it runs, from the timetable or a live feed that matches
  /// vehicles to trips (BODS).
  final String? tripId;
  /// The live feed's vehicle ID, where it has one (TfL).
  final String? vehicleId;

  const ArrivalCandidate({
    required this.arrival,
    required this.isLive,
    required this.routeNumber,
    this.tripId,
    this.vehicleId,
  });

  /// Identifies this bus for skipping: its trip or vehicle, or null without
  /// either.
  String? get identity => tripId != null
      ? 'trip:$tripId'
      : vehicleId != null
      ? 'vehicle:$vehicleId'
      : null;
}

/// The bus an occurrence is aiming at. Saved on the alarm, so field names are
/// shared with Swift.
class LockedArrival {
  /// 'live' or 'timetable'.
  final String source;
  final String routeNumber;
  final String? tripId;
  final String? vehicleId;
  final int arrivalEpochSeconds;
  final int lockedAtEpochSeconds;
  /// When a check last found this bus; earlier than the latest check while
  /// it's missing from the feed.
  final int lastSeenEpochSeconds;

  const LockedArrival({
    required this.source,
    required this.routeNumber,
    this.tripId,
    this.vehicleId,
    required this.arrivalEpochSeconds,
    required this.lockedAtEpochSeconds,
    required this.lastSeenEpochSeconds,
  });

  bool get isLive => source == 'live';
  DateTime get arrival => _fromEpoch(arrivalEpochSeconds);

  String? get identity => tripId != null
      ? 'trip:$tripId'
      : vehicleId != null
      ? 'vehicle:$vehicleId'
      : null;

  factory LockedArrival.fromCandidate(ArrivalCandidate candidate, DateTime now) =>
      LockedArrival(
        source: candidate.isLive ? 'live' : 'timetable',
        routeNumber: candidate.routeNumber,
        tripId: candidate.tripId,
        vehicleId: candidate.vehicleId,
        arrivalEpochSeconds: _epoch(candidate.arrival),
        lockedAtEpochSeconds: _epoch(now),
        lastSeenEpochSeconds: _epoch(now),
      );

  /// This bus seen again as [candidate]: its newest time and source, keeping
  /// whichever IDs are known, and when it was locked.
  LockedArrival seenAs(ArrivalCandidate candidate, DateTime now) => LockedArrival(
    source: candidate.isLive ? 'live' : source,
    routeNumber: routeNumber,
    tripId: tripId ?? candidate.tripId,
    vehicleId: vehicleId ?? candidate.vehicleId,
    arrivalEpochSeconds: _epoch(candidate.arrival),
    lockedAtEpochSeconds: lockedAtEpochSeconds,
    lastSeenEpochSeconds: _epoch(now),
  );

  Map<String, dynamic> toJson() => {
    'source': source,
    'routeNumber': routeNumber,
    'tripId': tripId,
    'vehicleId': vehicleId,
    'arrivalEpochSeconds': arrivalEpochSeconds,
    'lockedAtEpochSeconds': lockedAtEpochSeconds,
    'lastSeenEpochSeconds': lastSeenEpochSeconds,
  };

  static LockedArrival? fromJson(Object? json) {
    if (json is! Map) return null;
    final arrival = (json['arrivalEpochSeconds'] as num?)?.toInt();
    if (arrival == null) return null;
    return LockedArrival(
      source: json['source'] as String? ?? 'timetable',
      routeNumber: json['routeNumber'] as String? ?? '',
      tripId: json['tripId'] as String?,
      vehicleId: json['vehicleId'] as String?,
      arrivalEpochSeconds: arrival,
      lockedAtEpochSeconds: (json['lockedAtEpochSeconds'] as num?)?.toInt() ?? arrival,
      lastSeenEpochSeconds: (json['lastSeenEpochSeconds'] as num?)?.toInt() ?? arrival,
    );
  }
}

/// What a check decided: the bus to aim at, if any.
class LockDecision {
  /// The bus to aim at, or null when no bus is arriving within the window.
  final LockedArrival? locked;
  /// The check didn't find [locked] itself; it's counted down to from its
  /// last known time.
  final bool stale;
  /// A different bus from the one locked before this check.
  final bool changedBus;

  const LockDecision({this.locked, this.stale = false, this.changedBus = false});
}

/// How far a timetabled bus and a live one without a trip ID (TfL) may be
/// apart and still count as the same bus, when switching a timetable lock
/// to live tracking.
const liveMatchTolerance = Duration(minutes: 10);

/// Decides which bus to aim at for one check.
///
/// [candidates] are this check's arrivals on the alarm's routes, live and
/// timetabled (timetabled trips already tracked live left out). Arrivals
/// within [windowStart]–[windowEnd] count; [skipped] identities don't.
/// [stableIds] is false when a route's live feed can't identify buses, which
/// switches to aiming at the latest bus in the window on every check.
/// [onlyAfter] limits the pick to buses arriving after it, for "Next bus".
LockDecision decideLock({
  required List<ArrivalCandidate> candidates,
  required DateTime windowStart,
  required DateTime windowEnd,
  required DateTime now,
  LockedArrival? current,
  Set<String> skipped = const {},
  bool liveOnly = false,
  bool stableIds = true,
  DateTime? onlyAfter,
}) {
  // A bus the user skipped is no longer the one to aim at.
  if (current != null && current.identity != null && skipped.contains(current.identity)) {
    current = null;
  }
  final usable = candidates
      .where((c) => !liveOnly || c.isLive)
      .where((c) => c.identity == null || !skipped.contains(c.identity))
      .where((c) => onlyAfter == null || c.arrival.isAfter(onlyAfter))
      .toList();
  bool inWindow(DateTime arrival) =>
      !arrival.isBefore(windowStart) && !arrival.isAfter(windowEnd);
  final inWindowCandidates = usable.where((c) => inWindow(c.arrival)).toList()
    ..sort((a, b) => a.arrival.compareTo(b.arrival));

  if (!stableIds) {
    // No way to follow one bus: aim at the latest still in the window, live
    // ones first.
    final live = inWindowCandidates.where((c) => c.isLive).toList();
    final pool = live.isNotEmpty ? live : inWindowCandidates;
    if (pool.isEmpty) return const LockDecision();
    final latest = LockedArrival.fromCandidate(pool.last, now);
    return LockDecision(locked: latest, changedBus: current?.arrivalEpochSeconds != latest.arrivalEpochSeconds);
  }

  ArrivalCandidate? earliest() {
    final live = inWindowCandidates.where((c) => c.isLive).toList();
    if (live.isNotEmpty) return live.first;
    return inWindowCandidates.isEmpty ? null : inWindowCandidates.first;
  }

  if (current == null) {
    final pick = earliest();
    return pick == null
        ? const LockDecision()
        : LockDecision(locked: LockedArrival.fromCandidate(pick, now), changedBus: true);
  }

  final match = _findLocked(current, usable);
  final others = inWindowCandidates.where((c) => !identical(c, match)).toList();
  ArrivalCandidate? earliestOther() {
    final live = others.where((c) => c.isLive).toList();
    if (live.isNotEmpty) return live.first;
    return others.isEmpty ? null : others.first;
  }

  if (match != null) {
    if (inWindow(match.arrival)) {
      return LockDecision(locked: current.seenAs(match, now));
    }
    // Now expected outside the window: another bus within it wins.
    final other = earliestOther();
    if (other != null) {
      return LockDecision(locked: LockedArrival.fromCandidate(other, now), changedBus: true);
    }
    return LockDecision(locked: current.seenAs(match, now));
  }

  // Missing from this check's arrivals.
  final other = earliestOther();
  if (other != null) {
    return LockDecision(locked: LockedArrival.fromCandidate(other, now), changedBus: true);
  }
  if (now.isAfter(current.arrival)) {
    // Its time has passed and it never reappeared: it's gone.
    return const LockDecision(changedBus: true);
  }
  return LockDecision(locked: current, stale: true);
}

/// [current] among [candidates]: the same trip or vehicle, or, for a
/// timetabled lock, a live bus on the same route without a trip ID that's
/// within [liveMatchTolerance] of its time (TfL, whose live feed has vehicle
/// IDs but no trips).
ArrivalCandidate? _findLocked(LockedArrival current, List<ArrivalCandidate> candidates) {
  for (final candidate in candidates) {
    if (current.tripId != null && candidate.tripId == current.tripId) return candidate;
    if (current.vehicleId != null && candidate.vehicleId == current.vehicleId) return candidate;
  }
  if (current.isLive || current.vehicleId != null) return null;
  ArrivalCandidate? closest;
  Duration? closestGap;
  for (final candidate in candidates) {
    if (!candidate.isLive || candidate.tripId != null || candidate.routeNumber != current.routeNumber) continue;
    final gap = candidate.arrival.difference(current.arrival).abs();
    if (gap > liveMatchTolerance) continue;
    if (closestGap == null || gap < closestGap) {
      closest = candidate;
      closestGap = gap;
    }
  }
  return closest;
}

/// The thresholds still worth aiming at when a bus is first locked: each
/// whose ring time ([arrival] minus its minutes) is already past is skipped.
/// [minutesBeforeArrival] are the alarm's thresholds; returns the indices
/// still ahead, or an empty list when the bus is too close for every one.
List<int> thresholdsStillAhead(
  List<int> minutesBeforeArrival,
  DateTime arrival,
  DateTime now,
) => [
  for (var i = 0; i < minutesBeforeArrival.length; i++)
    if (arrival.subtract(Duration(minutes: minutesBeforeArrival[i])).isAfter(now)) i,
];

int _epoch(DateTime time) => time.millisecondsSinceEpoch ~/ 1000;
DateTime _fromEpoch(int seconds) => DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
