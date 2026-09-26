enum ThresholdOutcome { pending, ringing, acknowledged, superseded, missed }

class ThresholdState {
  final int minutesBeforeArrival;
  final int ringCount;
  final ThresholdOutcome outcome;

  const ThresholdState({required this.minutesBeforeArrival, this.ringCount = 0, this.outcome = ThresholdOutcome.pending});

  ThresholdState copyWith({int? ringCount, ThresholdOutcome? outcome}){
    return ThresholdState(
        minutesBeforeArrival: minutesBeforeArrival,
        ringCount: ringCount ?? this.ringCount,
        outcome: outcome ?? this.outcome
    );
  }

  Map<String, dynamic> toJson() => {
    "minutesBeforeArrival": minutesBeforeArrival,
    "ringCount": ringCount,
    "outcome": outcome.name
  };

  static ThresholdState fromJson(Map<String, dynamic> json) => ThresholdState(
    minutesBeforeArrival: json["minutesBeforeArrival"] as int,
    ringCount: json["ringCount"] as int,
    outcome: ThresholdOutcome.values.byName(json["outcome"] as String)
  );
}