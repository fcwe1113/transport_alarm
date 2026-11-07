import 'package:transport_alarm/transit/models/threshold_state.dart';
import 'package:flutter/material.dart';

import 'alarm_route_config.dart';
import '../services/arrival_lock.dart';
import '../services/boarding_window.dart';
import '../transit/transport_mode.dart';
import '../transit/models/repeat_pattern.dart';

/// A saved alarm: rings a set number of minutes before a bus on the chosen
/// routes reaches a stop, for a bus arriving within a daily window of when
/// the user wants to board (see BoardingOccurrence). Saved as JSON in
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
  /// The earliest arrival the user wants to board.
  final TimeOfDay windowStart;
  /// The latest arrival the user wants to board. May be earlier than
  /// [windowStart], for a window crossing midnight.
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
  /// The bus this occurrence is aiming at (see decideLock).
  final LockedArrival? lockedArrival;
  /// Buses the user skipped with "Next bus" this occurrence, by identity.
  final List<String> skippedArrivals;
  /// After "Next bus", only a bus arriving after this is picked; cleared once
  /// one is.
  final int? nextBusAfterEpochSeconds;
  /// 2 once the window means boarding times; alarms saved before that are
  /// converted when read (see migrateWindowMinutes).
  final int windowVersion;
  /// Minutes before the earliest possible ring that the alarm starts
  /// checking, copied from the Advanced setting.
  final int checkLeadMinutes;
  /// Converted from an older window meaning; shown as needing a check until
  /// the user saves or dismisses it.
  final bool needsReview;
  /// Android: the current occurrence's window, as device-local times.
  final int? androidOccurrenceStartEpochSeconds;
  final int? androidOccurrenceEndEpochSeconds;
  /// Android: start of the countdown's progress timeline for this occurrence.
  final int? androidProgressStartEpochSeconds;
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
    this.lockedArrival,
    this.skippedArrivals = const [],
    this.nextBusAfterEpochSeconds,
    this.windowVersion = 2,
    this.checkLeadMinutes = defaultCheckLeadMinutes,
    this.needsReview = false,
    this.androidOccurrenceStartEpochSeconds,
    this.androidOccurrenceEndEpochSeconds,
    this.androidProgressStartEpochSeconds,
    this.androidLiveNotice,
  });

  /// The largest minutes-before-arrival, which sets how early the alarm
  /// starts checking.
  int get largestThresholdMinutes => thresholdStates.isEmpty
      ? 0
      : thresholdStates.map((state) => state.minutesBeforeArrival).reduce((a, b) => a > b ? a : b);

  /// The occurrence active at [now], if any (see BoardingOccurrence).
  BoardingOccurrence? activeOccurrenceAt(DateTime now) => activeOccurrence(
    now,
    windowStart: windowStart,
    windowEnd: windowEnd,
    repeat: repeat,
    largestThresholdMinutes: largestThresholdMinutes,
    leadMinutes: checkLeadMinutes,
  );

  /// The first occurrence that becomes active after [after].
  BoardingOccurrence nextOccurrenceAfter(DateTime after) => nextOccurrence(
    after,
    windowStart: windowStart,
    windowEnd: windowEnd,
    repeat: repeat,
    largestThresholdMinutes: largestThresholdMinutes,
    leadMinutes: checkLeadMinutes,
  );

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
    LockedArrival? lockedArrival,
    bool clearLockedArrival = false,
    List<String>? skippedArrivals,
    int? nextBusAfterEpochSeconds,
    bool clearNextBusAfter = false,
    int? checkLeadMinutes,
    bool? needsReview,
    int? androidOccurrenceStartEpochSeconds,
    int? androidOccurrenceEndEpochSeconds,
    int? androidProgressStartEpochSeconds,
    String? androidLiveNotice,
    bool clearAndroidLiveNotice = false,
    bool clearLastEstimatedMinutesUntilThreshold = false,
    bool clearAndroidOccurrence = false,
    bool clearAndroidProgressStartEpochSeconds = false,
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
        lockedArrival: clearLockedArrival ? null : lockedArrival ?? this.lockedArrival,
        skippedArrivals: skippedArrivals ?? this.skippedArrivals,
        nextBusAfterEpochSeconds: clearNextBusAfter
            ? null
            : nextBusAfterEpochSeconds ?? this.nextBusAfterEpochSeconds,
        windowVersion: windowVersion,
        checkLeadMinutes: checkLeadMinutes ?? this.checkLeadMinutes,
        needsReview: needsReview ?? this.needsReview,
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
    'lockedArrival': lockedArrival?.toJson(),
    'skippedArrivals': skippedArrivals,
    'nextBusAfterEpochSeconds': nextBusAfterEpochSeconds,
    'windowVersion': windowVersion,
    'checkLeadMinutes': checkLeadMinutes,
    'needsReview': needsReview,
    'androidOccurrenceStartEpochSeconds': androidOccurrenceStartEpochSeconds,
    'androidOccurrenceEndEpochSeconds': androidOccurrenceEndEpochSeconds,
    'androidProgressStartEpochSeconds': androidProgressStartEpochSeconds,
    'androidLiveNotice': androidLiveNotice,
  };

  static TransportAlarm fromJson(Map<String, dynamic> json) {
    final thresholdStates = (json['thresholdStates'] as List).map((t) => ThresholdState.fromJson(t as Map<String, dynamic>)).toList();
    var windowStart = json['windowStart'] as int;
    var windowEnd = json['windowEnd'] as int;
    final windowVersion = (json['windowVersion'] as num?)?.toInt() ?? 1;
    // Saved when the window meant when the alarm watches: convert it to
    // boarding times now, so every reader agrees, and ask the user to check.
    final migrating = windowVersion < 2;
    if (migrating) {
      final largest = thresholdStates.isEmpty
          ? 0
          : thresholdStates.map((state) => state.minutesBeforeArrival).reduce((a, b) => a > b ? a : b);
      final migrated = migrateWindowMinutes(windowStart, windowEnd, largest);
      windowStart = migrated.start;
      windowEnd = migrated.end;
    }
    return TransportAlarm(
      id: json['id'] as String,
      gtfsStopId: json['gtfsStopId'] as String,
      routeApiConfigs: (json['routeApiConfigs'] as List<dynamic>?)
              ?.map((route) => AlarmRouteConfig.fromJson(Map<String, dynamic>.from(route as Map)))
              .toList() ??
          const [],
      localeCode: json['localeCode'] as String? ?? 'hk',
      routeNumbers: (json['routeNumbers'] as Map<String, dynamic>).map((key, value) => MapEntry(key, Map<String, String>.from(value as Map)),),
      windowStart: _minutesToTimeOfDay(windowStart),
      windowEnd: _minutesToTimeOfDay(windowEnd),
      maxRingsPerThreshold: json['maxRingsPerThreshold'] as int,
      thresholdStates: thresholdStates,
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
      // A migrated alarm's progress was planned for the old window.
      lockedArrival: migrating ? null : LockedArrival.fromJson(json['lockedArrival']),
      skippedArrivals: migrating
          ? const []
          : (json['skippedArrivals'] as List<dynamic>?)?.whereType<String>().toList() ?? const [],
      nextBusAfterEpochSeconds:
          migrating ? null : (json['nextBusAfterEpochSeconds'] as num?)?.toInt(),
      windowVersion: 2,
      checkLeadMinutes: (json['checkLeadMinutes'] as num?)?.toInt() ?? defaultCheckLeadMinutes,
      needsReview: migrating || (json['needsReview'] as bool? ?? false),
      androidOccurrenceStartEpochSeconds:
          migrating ? null : json['androidOccurrenceStartEpochSeconds'] as int?,
      androidOccurrenceEndEpochSeconds:
          migrating ? null : json['androidOccurrenceEndEpochSeconds'] as int?,
      androidProgressStartEpochSeconds:
          json['androidProgressStartEpochSeconds'] as int?,
      androidLiveNotice: json['androidLiveNotice'] as String?,
    );
  }

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

