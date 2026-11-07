import 'package:flutter_test/flutter_test.dart';
import 'package:transport_alarm/transit/models/repeat_pattern.dart';

void main() {
  final monday = DateTime(2026, 11, 9);
  final saturday = DateTime(2026, 11, 14);

  test('one-off and daily alarms run on any day', () {
    expect(RepeatPattern.none.occursOn(saturday), isTrue);
    expect(const RepeatPattern(frequency: RepeatFrequency.daily).occursOn(saturday), isTrue);
  });

  test('weekly alarms run only on their weekdays', () {
    const weekdays = RepeatPattern(frequency: RepeatFrequency.weekly, weekdays: [1, 2, 3, 4, 5]);
    expect(weekdays.occursOn(monday), isTrue);
    expect(weekdays.occursOn(saturday), isFalse);
  });

  test('monthly alarms run only on their days of the month', () {
    const ninth = RepeatPattern(frequency: RepeatFrequency.monthly, dayOfMonth: [9, 20]);
    expect(ninth.occursOn(monday), isTrue);
    expect(ninth.occursOn(saturday), isFalse);
  });

  test('a weekly alarm with no days never runs', () {
    expect(const RepeatPattern(frequency: RepeatFrequency.weekly, weekdays: []).occursOn(monday), isFalse);
  });

  test('survives a JSON round trip and compares by value', () {
    const pattern = RepeatPattern(frequency: RepeatFrequency.weekly, weekdays: [6, 7]);
    final restored = RepeatPattern.fromJson(pattern.toJson());
    expect(restored, pattern);
    expect(restored.hashCode, pattern.hashCode);
    expect(restored == const RepeatPattern(frequency: RepeatFrequency.weekly, weekdays: [6]), isFalse);
  });
}
