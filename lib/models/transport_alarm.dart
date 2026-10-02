import 'package:transport_alarm/transit/models/threshold_state.dart';
import 'package:flutter/material.dart';

import 'alarm_route_config.dart';
import '../transit/transport_mode.dart';
import '../transit/models/repeat_pattern.dart';

/// Transport Alarm object definition
class TransportAlarm {
  final String id; // maybe gen a uuid for it or something, this is local anyways so whatever
  final List<String> routeNumbers; // stores raw route numbers for deduping
  final String gtfsStopId;
  // API URLs are resolved when the alarm is created, so notification
  // processing does not need GTFS to map this stop to an operator stop.
  final List<AlarmRouteConfig> routeApiConfigs;
  // Locale key used for operator API and GTFS arrival lookups.
  final String localeCode;
  final TimeOfDay windowStart;
  final TimeOfDay windowEnd;
  final List<ThresholdState> thresholdStates; // ordered
  final int maxRingsPerThreshold;
  final RepeatPattern repeat;
  final bool liveOnly; // ignore schedule times if true
  // True after this occurrence completes; cleared when its next repeat begins.
  final bool spent;
  final String message;
  final bool enabled; // indicates alarm enabled (similar to ios alarm ui alarm toggle)
  final String? pingId;
  // Cached distance from the active threshold, rather than distance to arrival.
  final int? lastEstimatedMinutesUntilThreshold;
  // Android stores local-device window bounds for the current occurrence.
  final int? androidOccurrenceStartEpochSeconds;
  final int? androidOccurrenceEndEpochSeconds;
  // Start of the visible Android progress timeline for this occurrence.
  final int? androidProgressStartEpochSeconds;
  // Preserve a single GTFS fallback bus while live ETA calls are failing.
  final int? androidFallbackArrivalEpochSeconds;
  final bool androidApiWarningActive;

  /// Mode used for user-facing arrival text, taken from the first selected route.
  String get transportMode =>
      routeApiConfigs.isEmpty ? TransportMode.bus : routeApiConfigs.first.mode;

  const TransportAlarm({ //  constructor
    required this.id,
    required this.gtfsStopId,
    this.routeApiConfigs = const [],
    this.localeCode = 'hk',
    required this.routeNumbers,
    required this.windowStart,
    required this.windowEnd,
    required this.thresholdStates,
    this.maxRingsPerThreshold = 10,
    this.repeat = RepeatPattern.none,
    this.liveOnly = false,
    this.spent = false,
    required this.message,
    this.enabled = true,
    this.pingId,
    this.lastEstimatedMinutesUntilThreshold,
    this.androidOccurrenceStartEpochSeconds,
    this.androidOccurrenceEndEpochSeconds,
    this.androidProgressStartEpochSeconds,
    this.androidFallbackArrivalEpochSeconds,
    this.androidApiWarningActive = false,
  });

  TransportAlarm copyWith({
    String? gtfsStopId,
    List<AlarmRouteConfig>? routeApiConfigs,
    String? localeCode,
    List<String>? routeNumbers,
    TimeOfDay? windowStart,
    TimeOfDay? windowEnd,
    int? maxRingsPerThreshold,
    List<ThresholdState>? thresholdStates,
    RepeatPattern? repeat,
    bool? liveOnly,
    bool? spent,
    String? message,
    bool? enabled,
    String? pingId,
    bool clearPingId = false,
    int? lastEstimatedMinutesUntilThreshold,
    int? androidOccurrenceStartEpochSeconds,
    int? androidOccurrenceEndEpochSeconds,
    int? androidProgressStartEpochSeconds,
    int? androidFallbackArrivalEpochSeconds,
    bool? androidApiWarningActive,
    bool clearLastEstimatedMinutesUntilThreshold = false,
    bool clearAndroidOccurrence = false,
    bool clearAndroidProgressStartEpochSeconds = false,
    bool clearAndroidFallbackArrival = false,
  }) {
    return TransportAlarm(
        id: id,
        gtfsStopId: gtfsStopId ?? this.gtfsStopId,
        routeApiConfigs: routeApiConfigs ?? this.routeApiConfigs,
        localeCode: localeCode ?? this.localeCode,
        routeNumbers: routeNumbers ?? this.routeNumbers,
        windowStart: windowStart ?? this.windowStart,
        windowEnd: windowEnd ?? this.windowEnd,
        thresholdStates: thresholdStates ?? this.thresholdStates,
        repeat: repeat ?? this.repeat,
        liveOnly: liveOnly ?? this.liveOnly,
        spent: spent ?? this.spent,
        message: message ?? this.message,
        enabled: enabled ?? this.enabled,
        pingId: clearPingId ? null : pingId ?? this.pingId,
        lastEstimatedMinutesUntilThreshold: clearLastEstimatedMinutesUntilThreshold
            ? null
            : lastEstimatedMinutesUntilThreshold ?? this.lastEstimatedMinutesUntilThreshold,
        androidOccurrenceStartEpochSeconds: clearAndroidOccurrence
            ? null
            : androidOccurrenceStartEpochSeconds ?? this.androidOccurrenceStartEpochSeconds,
        androidOccurrenceEndEpochSeconds: clearAndroidOccurrence
            ? null
            : androidOccurrenceEndEpochSeconds ?? this.androidOccurrenceEndEpochSeconds,
        androidProgressStartEpochSeconds:
            clearAndroidOccurrence || clearAndroidProgressStartEpochSeconds
                ? null
                : androidProgressStartEpochSeconds ??
                    this.androidProgressStartEpochSeconds,
        androidFallbackArrivalEpochSeconds: clearAndroidFallbackArrival
            ? null
            : androidFallbackArrivalEpochSeconds ?? this.androidFallbackArrivalEpochSeconds,
        androidApiWarningActive: androidApiWarningActive ?? this.androidApiWarningActive,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'gtfsStopId': gtfsStopId,
    'routeApiConfigs': routeApiConfigs.map((route) => route.toJson()).toList(),
    'localeCode': localeCode,
    'routeNumbers': routeNumbers,
    'windowStart': windowStart.hour * 60 + windowStart.minute,
    'windowEnd': windowEnd.hour * 60 + windowEnd.minute,
    'maxRingsPerThreshold': maxRingsPerThreshold,
    'thresholdStates': thresholdStates.map((t) => t.toJson()).toList(),
    'repeat': repeat.toJson(),
    'liveOnly': liveOnly,
    'spent': spent,
    'message': message,
    'enabled': enabled,
    'pingId': pingId,
    'lastEstimatedMinutesUntilThreshold': lastEstimatedMinutesUntilThreshold,
    'androidOccurrenceStartEpochSeconds': androidOccurrenceStartEpochSeconds,
    'androidOccurrenceEndEpochSeconds': androidOccurrenceEndEpochSeconds,
    'androidProgressStartEpochSeconds': androidProgressStartEpochSeconds,
    'androidFallbackArrivalEpochSeconds': androidFallbackArrivalEpochSeconds,
    'androidApiWarningActive': androidApiWarningActive,
  };

  static TransportAlarm fromJson(Map<String, dynamic> json) => TransportAlarm(
    id: json['id'] as String,
    gtfsStopId: json['gtfsStopId'] as String,
    routeApiConfigs: (json['routeApiConfigs'] as List<dynamic>?)
            ?.map((route) => AlarmRouteConfig.fromJson(Map<String, dynamic>.from(route as Map)))
            .toList() ??
        const [],
    localeCode: json['localeCode'] as String? ?? 'hk',
    routeNumbers: List<String>.from(json['routeNumbers']),
    windowStart: _minutesToTimeOfDay(json['windowStart'] as int),
    windowEnd: _minutesToTimeOfDay(json['windowEnd'] as int),
    maxRingsPerThreshold: json['maxRingsPerThreshold'] as int,
    thresholdStates: (json['thresholdStates'] as List).map((t) => ThresholdState.fromJson(t as Map<String, dynamic>)).toList(),
    repeat: RepeatPattern.fromJson(json['repeat'] as Map<String, dynamic>),
    liveOnly: json['liveOnly'] as bool,
    spent: json['spent'] as bool? ?? false,
    message: json['message'] as String,
    enabled: json['enabled'] as bool,
    pingId: json['pingId'] as String?,
    lastEstimatedMinutesUntilThreshold:
        _cachedMinutesUntilThreshold(json),
    androidOccurrenceStartEpochSeconds:
        json['androidOccurrenceStartEpochSeconds'] as int?,
    androidOccurrenceEndEpochSeconds:
        json['androidOccurrenceEndEpochSeconds'] as int?,
    androidProgressStartEpochSeconds:
        json['androidProgressStartEpochSeconds'] as int?,
    androidFallbackArrivalEpochSeconds:
        json['androidFallbackArrivalEpochSeconds'] as int?,
    androidApiWarningActive: json['androidApiWarningActive'] as bool? ?? false,
  );

  static int? _cachedMinutesUntilThreshold(Map<String, dynamic> json) {
    final explicit = json['lastEstimatedMinutesUntilThreshold'] as int?;
    if (explicit != null) return explicit;

    // Convert pre-threshold-cache data once when loading an existing alarm.
    final arrivalEstimate = json['lastEstimatedMinutesUntilArrival'] as int?;
    final states = (json['thresholdStates'] as List?)
        ?.map((state) => Map<String, dynamic>.from(state as Map))
        .toList();
    if (arrivalEstimate == null || states == null) return null;
    final active = states.where((state) {
      final outcome = state['outcome'];
      return outcome == 'pending' || outcome == 'ringing';
    }).firstOrNull;
    final thresholdMinutes = active?['minutesBeforeArrival'] as int?;
    return thresholdMinutes == null ? null : arrivalEstimate - thresholdMinutes;
  }

  static TimeOfDay _minutesToTimeOfDay (int totalMinutes) =>
    TimeOfDay(hour: totalMinutes ~/ 60, minute: totalMinutes % 60);

  int _toMinutes (TimeOfDay t) => t.hour * 60 + t.minute;

  bool isWithinWindow(TimeOfDay t) {
    final start = _toMinutes(windowStart);
    final end = _toMinutes(windowEnd);
    final time = _toMinutes(t);

    if (start <= end) {
      return time >= start && time <= end;
    } else {
      return time >= start || time <= end;
    }
  }
}

// iOS uses the same saved threshold outcomes as Android. The server ping ID is
// kept while a threshold is ringing and is rescheduled every minute until the
// user acknowledges it. Acknowledging advances to the next pending threshold;
// after the final threshold, the ping is stopped or moved to the next repeat.
