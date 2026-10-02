import 'package:transport_alarm/transit/models/threshold_state.dart';
import 'package:flutter/material.dart';

import '../transit/models/repeat_pattern.dart';

/// Bus Alarm object definition
class BusAlarm {
  final String id; // maybe gen a uuid for it or something, this is local anyways so whatever
  final List<String> routeNumbers; // stores raw route numbers for deduping
  final String gtfsStopId;
  // Locale key used for operator API, timezone, and GTFS arrival lookups.
  final String localeCode;
  final TimeOfDay windowStart;
  final TimeOfDay windowEnd;
  final List<ThresholdState> thresholdStates; // ordered
  final int maxRingsPerThreshold;
  final RepeatPattern repeat;
  final bool liveOnly; // ignore schedule times if true
  final String message;
  final bool enabled; // indicates alarm enabled (similar to ios alarm ui alarm toggle)
  final String? pingId;
  final int? lastEstimatedMinutesUntilArrival;

  const BusAlarm({ //  constructor
    required this.id,
    required this.gtfsStopId,
    this.localeCode = 'hk',
    required this.routeNumbers,
    required this.windowStart,
    required this.windowEnd,
    required this.thresholdStates,
    this.maxRingsPerThreshold = 10,
    this.repeat = RepeatPattern.none,
    this.liveOnly = false,
    required this.message,
    this.enabled = true,
    this.pingId,
    this.lastEstimatedMinutesUntilArrival,
  });

  BusAlarm copyWith({
    String? gtfsStopId,
    String? localeCode,
    List<String>? routeNumbers,
    TimeOfDay? windowStart,
    TimeOfDay? windowEnd,
    int? maxRingsPerThreshold,
    List<ThresholdState>? thresholdStates,
    RepeatPattern? repeat,
    bool? liveOnly,
    String? message,
    bool? enabled,
    String? pingId,
    int? lastEstimatedMinutesUntilArrival,
    bool clearLastEstimatedMinutesUntilArrival = false,
  }) {
    return BusAlarm(
        id: id,
        gtfsStopId: gtfsStopId ?? this.gtfsStopId,
        localeCode: localeCode ?? this.localeCode,
        routeNumbers: routeNumbers ?? this.routeNumbers,
        windowStart: windowStart ?? this.windowStart,
        windowEnd: windowEnd ?? this.windowEnd,
        thresholdStates: thresholdStates ?? this.thresholdStates,
        repeat: repeat ?? this.repeat,
        liveOnly: liveOnly ?? this.liveOnly,
        message: message ?? this.message,
        enabled: enabled ?? this.enabled,
        pingId: pingId ?? this.pingId,
        lastEstimatedMinutesUntilArrival: clearLastEstimatedMinutesUntilArrival
            ? null
            : lastEstimatedMinutesUntilArrival ?? this.lastEstimatedMinutesUntilArrival,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'gtfsStopId': gtfsStopId,
    'localeCode': localeCode,
    'routeNumbers': routeNumbers,
    'windowStart': windowStart.hour * 60 + windowStart.minute,
    'windowEnd': windowEnd.hour * 60 + windowEnd.minute,
    'maxRingsPerThreshold': maxRingsPerThreshold,
    'thresholdStates': thresholdStates.map((t) => t.toJson()).toList(),
    'repeat': repeat.toJson(),
    'liveOnly': liveOnly,
    'message': message,
    'enabled': enabled,
    'pingId': pingId,
    'lastEstimatedMinutesUntilArrival': lastEstimatedMinutesUntilArrival,
  };

  static BusAlarm fromJson(Map<String, dynamic> json) => BusAlarm(
    id: json['id'] as String,
    gtfsStopId: json['gtfsStopId'] as String,
    localeCode: json['localeCode'] as String? ?? 'hk',
    routeNumbers: List<String>.from(json['routeNumbers']),
    windowStart: _minutesToTimeOfDay(json['windowStart'] as int),
    windowEnd: _minutesToTimeOfDay(json['windowEnd'] as int),
    maxRingsPerThreshold: json['maxRingsPerThreshold'] as int,
    thresholdStates: (json['thresholdStates'] as List).map((t) => ThresholdState.fromJson(t as Map<String, dynamic>)).toList(),
    repeat: RepeatPattern.fromJson(json['repeat'] as Map<String, dynamic>),
    liveOnly: json['liveOnly'] as bool,
    message: json['message'] as String,
    enabled: json['enabled'] as bool,
    pingId: json['pingId'] as String?,
    lastEstimatedMinutesUntilArrival:
        json['lastEstimatedMinutesUntilArrival'] as int?,
  );

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
