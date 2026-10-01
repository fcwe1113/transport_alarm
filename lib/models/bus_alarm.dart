import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:transport_alarm/transit/models/threshold_state.dart';
import 'package:flutter/material.dart';

import '../transit/models/repeat_pattern.dart';

/// Bus Alarm object definition
class BusAlarm {
  final String id; // maybe gen a uuid for it or something, this is local anyways so whatever
  final List<String> routeNumbers; // stores raw route numbers for deduping
  final String gtfsStopId;
  // Locale key used by native iOS scheduling and its timezone/GTFS settings.
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
  // Native iOS extension state is kept separate from Android's ThresholdOutcome.
  final List<Map<String, dynamic>> iosThresholdStates;
  final bool iosNextOccurrenceScheduled;
  final String? iosOccurrenceKey;

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
    this.iosThresholdStates = const [],
    this.iosNextOccurrenceScheduled = false,
    this.iosOccurrenceKey,
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
    List<Map<String, dynamic>>? iosThresholdStates,
    bool? iosNextOccurrenceScheduled,
    String? iosOccurrenceKey,
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
        iosThresholdStates: iosThresholdStates ?? this.iosThresholdStates,
        iosNextOccurrenceScheduled:
            iosNextOccurrenceScheduled ?? this.iosNextOccurrenceScheduled,
        iosOccurrenceKey: iosOccurrenceKey ?? this.iosOccurrenceKey,
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
    'iosThresholdStates': iosThresholdStates,
    'iosNextOccurrenceScheduled': iosNextOccurrenceScheduled,
    'iosOccurrenceKey': iosOccurrenceKey,
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
    iosThresholdStates: (json['iosThresholdStates'] as List<dynamic>?)
            ?.map((state) => Map<String, dynamic>.from(state as Map))
            .toList() ??
        const [],
    iosNextOccurrenceScheduled:
        json['iosNextOccurrenceScheduled'] as bool? ?? false,
    iosOccurrenceKey: json['iosOccurrenceKey'] as String?,
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

// IOS alarm workflow
// 0. on alarm register send the next alarm duration start to server
// 1. server pings on alarm duration start
// 2. phone gets updated alarm ring estimate, pings server on next when to ping next, either for estimate update (estimate >5 mins) or actual alarm ring(estimate <5 mins)
// 3. server pings on alarm ring
// 4. phone rings and set server ping in 1 min, if user acknowledge the send delete to remove repeat ring, user can define max run tries (default 10)
// 5. any subsequent alarm rings would be set by phone calculating the next server ping time
// note: if server does not receive an ACK from phone on ping, it will retry in 1 min
// assuming that step 2 runs one estimate update in addition to final check before alarm, user acknowledges alarm on first ring, and all api packets arrive successfully
// each alarm would take 8 server invokations assuming invokations only counts sending/receiving api calls

// assuming each user would make 2 alarms with an average upper invokation count of 10 per alarm
// cloudflare offering 100k invokations per day
// 100000 / 20 (per user) = 5000 ios users per day cap, realistically 3.5k-4k ios users per day

// ping incoming decision flow
// each bus alarm obj save a ping_id that the incoming ping to that alarm will have (garunteed to be unique by server db constraint)
// 1. ping handler will get incoming ping id and point ping toward the correct alarm
// ALARM LAYER
// 2. alarm will see last estimated time away and decide accordingly, if app is open the estimate is updated per min
// 2.1. if over 5 mins api for new estimate, if fail assume last estimate is valid and ask for next ping halfway down
// 2.2. if under 5 mins api for new estimate and ask for an ack ping on alarm trigger time, assume last estimate is correct on api fail
// 3. if on or after alarm time ring the alarm and leave ping_id unchanged, as subsequent ping from no ack will have the same id
// 4. when user acknowledge alarm send ack to server, app also send ack and register next ack ping if next ring threshold is within 1 min

// maybe replace require ack into expire time because cron job runs per minute, is not null means require ack
// server will run clean up per cron trigger for expired pings before batch pinging

// NEW ios alarm workflow
// 0. on alarm register send the next alarm duration start to server
// 1. server pings on alarm duration start
// 2. phone gets updated alarm ring estimate, set alarmkit ring(estimate <5 mins), and pings server for estimate update (estimate >5 mins)
// 3. if alarm is set and next threshold exist then same estimate rules apply but for next threshold, otherwise schedule for next repeat (set alarm status as rang after last alarmkit ring scheduled)

// NEW ping incoming decision flow (also fit in a call when user enables alarm within window?)
// each bus alarm obj save a ping_id that the incoming ping to that alarm will have (garunteed to be unique by server db constraint)
// 1. ping handler will get incoming ping id and point ping toward the correct alarm
// ALARM LAYER
// 2. alarm will see last estimated time away and decide accordingly, if app is open the estimate is updated per min
// 2.1. if over 5 mins api for new estimate, if fail assume last estimate is valid and ask for next ping halfway down
// 2.2. if under 5 mins api for new estimate and set alarmkit alarm, assume last estimate is correct on api fail
// 2.2.1 if next threshold exist then same estimate rules apply but for next threshold, otherwise schedule for next repeat (set alarm status as rang after last alarmkit ring scheduled)
// 2.3 if app open and estimate is at 5 min schedule alarmkit alarm, while app open update newest estimate on alarmcard update, incoming pings will ignore thresholds with an active alarm
