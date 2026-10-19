class LiveEta {
  final String routeNumber;
  final String bound;
  final Map<String, String> destination;
  final DateTime? etaTime; // null if not prediction available
  final String? remark;
  final String? tripId; // GTFS trip the vehicle is running, if the provider can tell
  final bool hasPassed; // vehicle on tripId has already passed the stop; etaTime is null

  const LiveEta({required this.routeNumber, required this.bound, required this.destination, this.etaTime, this.remark, this.tripId, this.hasPassed = false});

  int? get minutesFromNow {
    if (etaTime == null) return null;
    return etaTime!.difference(DateTime.now().toUtc()).inMinutes;
  }
}