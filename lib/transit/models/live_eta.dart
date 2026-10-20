/// One live arrival prediction from an operator's API.
class LiveEta {
  final String routeNumber;
  /// The operator's direction code, such as KMB's "I" or "O".
  final String bound;
  /// Keyed by language code.
  final Map<String, String> destination;
  /// Null when the operator has no prediction for this vehicle.
  final DateTime? etaTime;
  final String? remark;
  /// The GTFS trip the vehicle is running, if the provider can tell.
  final String? tripId;
  /// The vehicle on [tripId] has already passed the stop; [etaTime] is null.
  final bool hasPassed;

  const LiveEta({
    required this.routeNumber,
    required this.bound,
    required this.destination,
    this.etaTime,
    this.remark,
    this.tripId,
    this.hasPassed = false,
  });

  /// Whole minutes until [etaTime], or null without a prediction.
  int? get minutesFromNow => etaTime?.difference(DateTime.now()).inMinutes;
}
