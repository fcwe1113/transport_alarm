/// Where a threshold is in the current occurrence. Saved by name, and read
/// by the iOS notification extension too.
enum ThresholdOutcome {
  /// Waiting for the bus to be this close.
  pending,
  /// Ringing until acknowledged (or, on iOS, until it has rung enough times).
  ringing,
  acknowledged,
  /// Skipped because the next threshold came due while this one rang.
  superseded,
  /// Stopped after ringing the maximum times without an acknowledgement.
  missed,
}

/// One "ring this many minutes before arrival" setting on an alarm, with
/// its progress in the current occurrence.
class ThresholdState {
  final int minutesBeforeArrival;
  /// Rings so far in this occurrence.
  final int ringCount;
  final ThresholdOutcome outcome;

  const ThresholdState({required this.minutesBeforeArrival, this.ringCount = 0, this.outcome = ThresholdOutcome.pending});

  ThresholdState copyWith({int? ringCount, ThresholdOutcome? outcome}) {
    return ThresholdState(
      minutesBeforeArrival: minutesBeforeArrival,
      ringCount: ringCount ?? this.ringCount,
      outcome: outcome ?? this.outcome,
    );
  }

  Map<String, dynamic> toJson() => {
    "minutesBeforeArrival": minutesBeforeArrival,
    "ringCount": ringCount,
    "outcome": outcome.name,
  };

  static ThresholdState fromJson(Map<String, dynamic> json) => ThresholdState(
    minutesBeforeArrival: json["minutesBeforeArrival"] as int,
    ringCount: json["ringCount"] as int,
    outcome: ThresholdOutcome.values.byName(json["outcome"] as String),
  );
}
