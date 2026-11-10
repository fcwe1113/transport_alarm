import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_test/flutter_test.dart';
import 'package:transport_alarm/models/transport_alarm.dart';
import 'package:transport_alarm/services/boarding_window.dart';
import 'package:transport_alarm/transit/models/repeat_pattern.dart';

void main() {
  group('occurrences', () {
    const start = TimeOfDay(hour: 8, minute: 0);
    const end = TimeOfDay(hour: 8, minute: 30);

    test('become active the lead time before the earliest ring', () {
      final occurrence = occurrenceOn(
        DateTime(2026, 11, 9),
        windowStart: start,
        windowEnd: end,
        largestThresholdMinutes: 10,
        leadMinutes: 10,
      );
      expect(occurrence.activeFrom, DateTime(2026, 11, 9, 7, 40));
      expect(occurrence.boardUntil, DateTime(2026, 11, 9, 8, 30));
      expect(occurrence.activeUntil, DateTime(2026, 11, 9, 9, 0));
    });

    test('a window crossing midnight ends the next day', () {
      final occurrence = occurrenceOn(
        DateTime(2026, 11, 9),
        windowStart: const TimeOfDay(hour: 23, minute: 45),
        windowEnd: const TimeOfDay(hour: 0, minute: 15),
        largestThresholdMinutes: 5,
        leadMinutes: 10,
      );
      expect(occurrence.boardUntil, DateTime(2026, 11, 10, 0, 15));
    });

    test('an early window becomes active the evening before, but belongs to its own day', () {
      // Weekdays only: Monday 00:10 becomes active on Sunday 23:50.
      const weekdays = RepeatPattern(frequency: RepeatFrequency.weekly, weekdays: [1, 2, 3, 4, 5]);
      final active = activeOccurrence(
        DateTime(2026, 11, 8, 23, 55), // a Sunday
        windowStart: const TimeOfDay(hour: 0, minute: 10),
        windowEnd: const TimeOfDay(hour: 0, minute: 40),
        repeat: weekdays,
        largestThresholdMinutes: 10,
        leadMinutes: 10,
      );
      expect(active?.boardFrom, DateTime(2026, 11, 9, 0, 10));
    });

    test("isn't active on a day that doesn't repeat", () {
      const mondays = RepeatPattern(frequency: RepeatFrequency.weekly, weekdays: [1]);
      expect(
        activeOccurrence(
          DateTime(2026, 11, 10, 7, 50), // a Tuesday
          windowStart: start,
          windowEnd: end,
          repeat: mondays,
          largestThresholdMinutes: 10,
          leadMinutes: 10,
        ),
        isNull,
      );
    });

    test('the next occurrence skips to the next repeat day', () {
      const mondays = RepeatPattern(frequency: RepeatFrequency.weekly, weekdays: [1]);
      final next = nextOccurrence(
        DateTime(2026, 11, 10, 12, 0), // a Tuesday
        windowStart: start,
        windowEnd: end,
        repeat: mondays,
        largestThresholdMinutes: 10,
        leadMinutes: 10,
      );
      expect(next.boardFrom, DateTime(2026, 11, 16, 8, 0));
      expect(next.activeFrom, DateTime(2026, 11, 16, 7, 40));
    });
  });

  group('migrating old windows', () {
    test('starts the largest threshold later and keeps the end', () {
      final migrated = migrateWindowMinutes(7 * 60 + 30, 8 * 60 + 30, 10);
      expect(migrated, (start: 7 * 60 + 40, end: 8 * 60 + 30));
    });

    test('a window too short for the threshold becomes 30 minutes long', () {
      final migrated = migrateWindowMinutes(8 * 60, 8 * 60 + 10, 10);
      expect(migrated, (start: 8 * 60 + 10, end: 8 * 60 + 40));
    });

    test('works across midnight', () {
      final migrated = migrateWindowMinutes(23 * 60 + 50, 30, 15);
      expect(migrated, (start: 5, end: 30));
    });

    Map<String, dynamic> savedAlarm({int? windowVersion}) => {
      'id': '1',
      'gtfsStopId': 'stop',
      'localeCode': 'gb',
      'routeNumbers': {'1': {'en': 'Town'}},
      'windowStart': 7 * 60 + 30,
      'windowEnd': 8 * 60 + 30,
      'maxRingsPerThreshold': 10,
      'thresholdStates': [
        {'minutesBeforeArrival': 10, 'ringCount': 0, 'outcome': 'pending'},
        {'minutesBeforeArrival': 5, 'ringCount': 0, 'outcome': 'pending'},
      ],
      'repeat': {'frequency': 'daily'},
      'liveOnly': false,
      'message': '',
      'enabled': true,
      'androidOccurrenceStartEpochSeconds': 123,
      'windowVersion': ?windowVersion,
    };

    test('an alarm saved before boarding windows is converted when read, and marked to check', () {
      final alarm = TransportAlarm.fromJson(savedAlarm());
      expect(alarm.windowStart, const TimeOfDay(hour: 7, minute: 40));
      expect(alarm.windowEnd, const TimeOfDay(hour: 8, minute: 30));
      expect(alarm.windowVersion, 2);
      expect(alarm.needsReview, isTrue);
      // Its progress was planned for the old window, so it's replanned.
      expect(alarm.androidOccurrenceStartEpochSeconds, isNull);
      // Saving it stores the new meaning, so it isn't converted again.
      final reread = TransportAlarm.fromJson(alarm.toJson());
      expect(reread.windowStart, const TimeOfDay(hour: 7, minute: 40));
    });

    test('a current alarm is read unchanged', () {
      final alarm = TransportAlarm.fromJson(savedAlarm(windowVersion: 2));
      expect(alarm.windowStart, const TimeOfDay(hour: 7, minute: 30));
      expect(alarm.needsReview, isFalse);
      expect(alarm.androidOccurrenceStartEpochSeconds, 123);
    });
  });
}
