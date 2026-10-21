import 'package:transport_alarm/transit/models/threshold_state.dart';
import 'package:flutter/material.dart';

import 'alarm_route_config.dart';
import '../transit/transport_mode.dart';
import '../transit/models/repeat_pattern.dart';

/// A saved alarm: rings a set number of minutes before a bus on the chosen
/// routes reaches a stop, within a daily time window. Saved as JSON in
/// alarms.json, which the iOS notification extension also reads and writes,
/// so field names are shared with Swift.
class TransportAlarm {
  /// Creation time in milliseconds, as a string; local to this device.
  final String id;
  /// Route number to its destination names by language code, so a route
  /// with several destinations matches the one picked.
  final Map<String, Map<String, String>> routeNumbers;
  final String gtfsStopId;
  /// API URLs resolved when the alarm is created, so alarm checks don't
  /// need GTFS to map this stop to an operator stop.
  final List<AlarmRouteConfig> routeApiConfigs;
  /// Locale key used for operator API and GTFS arrival lookups.
  final String localeCode;
  final TimeOfDay windowStart;
  /// May be earlier than [windowStart], for a window crossing midnight.
  final TimeOfDay windowEnd;
  /// Ordered from the largest minutes-before-arrival down, the order they ring in.
  final List<ThresholdState> thresholdStates;
  /// How many times a threshold rings before it's marked missed (iOS; Android
  /// rings until acknowledged).
  final int maxRingsPerThreshold;
  final RepeatPattern repeat;
  /// Ignores timetable arrivals and waits for a live bus.
  final bool liveOnly;
  /// True after this occurrence completes; cleared when its next repeat begins.
  final bool spent;
  /// Shown on the ring notification.
  final String message;
  final bool enabled;
  /// The iOS server ping that drives this alarm.
  final String? pingId;
  /// Proves to the scheduling server that this device owns [pingId]; sent
  /// with every reschedule and ack.
  final String? pingSecret;
  /// The phone that scheduled [pingId] (AppGroupStorage.deviceId), so a phone
  /// restored from this one's backup doesn't take over its pings. Null for
  /// pings scheduled before this was recorded.
  final String? pingDeviceId;
  /// Minutes until the active threshold at the last estimate, for when a
  /// later fetch fails.
  final int? lastEstimatedMinutesUntilThreshold;
  /// Arrivals before this time are ignored for the rest of the occurrence:
  /// buses already too close to make the first threshold when it started.
  final int? ignoreArrivalsBeforeEpochSeconds;
  /// Android: the current occurrence's window, as device-local times.
  final int? androidOccurrenceStartEpochSeconds;
  final int? androidOccurrenceEndEpochSeconds;
  /// Android: start of the countdown's progress timeline for this occurrence.
  final int? androidProgressStartEpochSeconds;
  /// Android: the timetable bus being counted down to while there's no live one.
  final int? androidFallbackArrivalEpochSeconds;
  /// Android: which live-data notice is showing (an AndroidLiveNotice name), or null.
  final String? androidLiveNotice;

  /// Mode used for user-facing arrival text, taken from the first selected route.
  String get transportMode =>
      routeApiConfigs.isEmpty ? TransportMode.bus : routeApiConfigs.first.mode;

  const TransportAlarm({
    required this.id,
    required this.gtfsStopId,
    this.routeApiConfigs = const [],
    required this.localeCode,
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
    this.pingSecret,
    this.pingDeviceId,
    this.lastEstimatedMinutesUntilThreshold,
    this.ignoreArrivalsBeforeEpochSeconds,
    this.androidOccurrenceStartEpochSeconds,
    this.androidOccurrenceEndEpochSeconds,
    this.androidProgressStartEpochSeconds,
    this.androidFallbackArrivalEpochSeconds,
    this.androidLiveNotice,
  });

  TransportAlarm copyWith({
    String? gtfsStopId,
    List<AlarmRouteConfig>? routeApiConfigs,
    String? localeCode,
    Map<String, Map<String, String>>? routeNumbers,
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
    String? pingSecret,
    String? pingDeviceId,
    bool clearPingId = false,
    int? lastEstimatedMinutesUntilThreshold,
    int? ignoreArrivalsBeforeEpochSeconds,
    int? androidOccurrenceStartEpochSeconds,
    int? androidOccurrenceEndEpochSeconds,
    int? androidProgressStartEpochSeconds,
    int? androidFallbackArrivalEpochSeconds,
    String? androidLiveNotice,
    bool clearAndroidLiveNotice = false,
    bool clearLastEstimatedMinutesUntilThreshold = false,
    bool clearIgnoreArrivalsBefore = false,
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
        maxRingsPerThreshold: maxRingsPerThreshold ?? this.maxRingsPerThreshold,
        repeat: repeat ?? this.repeat,
        liveOnly: liveOnly ?? this.liveOnly,
        spent: spent ?? this.spent,
        message: message ?? this.message,
        enabled: enabled ?? this.enabled,
        pingId: clearPingId ? null : pingId ?? this.pingId,
        pingSecret: clearPingId ? null : pingSecret ?? this.pingSecret,
        pingDeviceId: clearPingId ? null : pingDeviceId ?? this.pingDeviceId,
        lastEstimatedMinutesUntilThreshold: clearLastEstimatedMinutesUntilThreshold
            ? null
            : lastEstimatedMinutesUntilThreshold ?? this.lastEstimatedMinutesUntilThreshold,
        ignoreArrivalsBeforeEpochSeconds: clearIgnoreArrivalsBefore
            ? null
            : ignoreArrivalsBeforeEpochSeconds ?? this.ignoreArrivalsBeforeEpochSeconds,
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
        androidLiveNotice: clearAndroidLiveNotice
            ? null
            : androidLiveNotice ?? this.androidLiveNotice,
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
    'pingSecret': pingSecret,
    'pingDeviceId': pingDeviceId,
    'lastEstimatedMinutesUntilThreshold': lastEstimatedMinutesUntilThreshold,
    'ignoreArrivalsBeforeEpochSeconds': ignoreArrivalsBeforeEpochSeconds,
    'androidOccurrenceStartEpochSeconds': androidOccurrenceStartEpochSeconds,
    'androidOccurrenceEndEpochSeconds': androidOccurrenceEndEpochSeconds,
    'androidProgressStartEpochSeconds': androidProgressStartEpochSeconds,
    'androidFallbackArrivalEpochSeconds': androidFallbackArrivalEpochSeconds,
    'androidLiveNotice': androidLiveNotice,
  };

  static TransportAlarm fromJson(Map<String, dynamic> json) => TransportAlarm(
    id: json['id'] as String,
    gtfsStopId: json['gtfsStopId'] as String,
    routeApiConfigs: (json['routeApiConfigs'] as List<dynamic>?)
            ?.map((route) => AlarmRouteConfig.fromJson(Map<String, dynamic>.from(route as Map)))
            .toList() ??
        const [],
    localeCode: json['localeCode'] as String? ?? 'hk',
    routeNumbers: (json['routeNumbers'] as Map<String, dynamic>).map((key, value) => MapEntry(key, Map<String, String>.from(value as Map)),),
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
    pingSecret: json['pingSecret'] as String?,
    pingDeviceId: json['pingDeviceId'] as String?,
    lastEstimatedMinutesUntilThreshold:
        json['lastEstimatedMinutesUntilThreshold'] as int?,
    ignoreArrivalsBeforeEpochSeconds:
        (json['ignoreArrivalsBeforeEpochSeconds'] as num?)?.toInt(),
    androidOccurrenceStartEpochSeconds:
        json['androidOccurrenceStartEpochSeconds'] as int?,
    androidOccurrenceEndEpochSeconds:
        json['androidOccurrenceEndEpochSeconds'] as int?,
    androidProgressStartEpochSeconds:
        json['androidProgressStartEpochSeconds'] as int?,
    androidFallbackArrivalEpochSeconds:
        json['androidFallbackArrivalEpochSeconds'] as int?,
    androidLiveNotice: json['androidLiveNotice'] as String?,
  );

  static TimeOfDay _minutesToTimeOfDay(int totalMinutes) =>
    TimeOfDay(hour: totalMinutes ~/ 60, minute: totalMinutes % 60);

  int _toMinutes(TimeOfDay t) => t.hour * 60 + t.minute;

  /// Whether [t] falls in the window, end minute included. Repeat days
  /// aren't checked.
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

