import 'package:transport_alarm/transit/models/threshold_state.dart';
import 'package:flutter/material.dart';

import 'alarm_route_config.dart';
import '../transit/models/repeat_pattern.dart';

/// Bus Alarm object definition
class BusAlarm {
  final String id; // maybe gen a uuid for it or something, this is local anyways so whatever
  final List<String> routeNumbers; // stores raw route numbers for deduping
  final String gtfsStopId;
  // API URLs are resolved when the alarm is created, so notification
  // processing does not need GTFS to map this stop to an operator stop.
  final List<AlarmRouteConfig> routeApiConfigs;
  // Locale key used for operator API, timezone, and GTFS arrival lookups.
  final String localeCode;
  // IANA timezone used when computing local repeat window start times.
  final String timeZoneIdentifier;
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

  const BusAlarm({ //  constructor
    required this.id,
    required this.gtfsStopId,
    this.routeApiConfigs = const [],
    this.localeCode = 'hk',
    this.timeZoneIdentifier = 'Asia/Hong_Kong',
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
  });

  BusAlarm copyWith({
    String? gtfsStopId,
    List<AlarmRouteConfig>? routeApiConfigs,
    String? localeCode,
    String? timeZoneIdentifier,
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
    int? lastEstimatedMinutesUntilThreshold,
    bool clearLastEstimatedMinutesUntilThreshold = false,
  }) {
    return BusAlarm(
        id: id,
        gtfsStopId: gtfsStopId ?? this.gtfsStopId,
        routeApiConfigs: routeApiConfigs ?? this.routeApiConfigs,
        localeCode: localeCode ?? this.localeCode,
        timeZoneIdentifier: timeZoneIdentifier ?? this.timeZoneIdentifier,
        routeNumbers: routeNumbers ?? this.routeNumbers,
        windowStart: windowStart ?? this.windowStart,
        windowEnd: windowEnd ?? this.windowEnd,
        thresholdStates: thresholdStates ?? this.thresholdStates,
        repeat: repeat ?? this.repeat,
        liveOnly: liveOnly ?? this.liveOnly,
        spent: spent ?? this.spent,
        message: message ?? this.message,
        enabled: enabled ?? this.enabled,
        pingId: pingId ?? this.pingId,
        lastEstimatedMinutesUntilThreshold: clearLastEstimatedMinutesUntilThreshold
            ? null
            : lastEstimatedMinutesUntilThreshold ?? this.lastEstimatedMinutesUntilThreshold,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'gtfsStopId': gtfsStopId,
    'routeApiConfigs': routeApiConfigs.map((route) => route.toJson()).toList(),
    'localeCode': localeCode,
    'timeZoneIdentifier': timeZoneIdentifier,
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
  };

  static BusAlarm fromJson(Map<String, dynamic> json) => BusAlarm(
    id: json['id'] as String,
    gtfsStopId: json['gtfsStopId'] as String,
    routeApiConfigs: (json['routeApiConfigs'] as List<dynamic>?)
            ?.map((route) => AlarmRouteConfig.fromJson(Map<String, dynamic>.from(route as Map)))
            .toList() ??
        const [],
    localeCode: json['localeCode'] as String? ?? 'hk',
    timeZoneIdentifier: json['timeZoneIdentifier'] as String? ?? 'Asia/Hong_Kong',
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
