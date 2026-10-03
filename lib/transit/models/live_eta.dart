class LiveEta {
  final String routeNumber;
  final String bound;
  final DateTime? etaTime; // null if not prediction available
  final String? remark;

  const LiveEta({required this.routeNumber, required this.bound, this.etaTime, this.remark});

  int? get minutesFromNow {
    if (etaTime == null) return null;
    return etaTime!.difference(DateTime.now().toUtc()).inMinutes;
  }
}