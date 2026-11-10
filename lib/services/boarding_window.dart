import 'package:flutter/material.dart' show TimeOfDay;
import 'package:transport_alarm/transit/models/repeat_pattern.dart';

/// An alarm's window is when the user wants to board ([boardFrom] to
/// [boardUntil]). The alarm becomes active [leadMinutes] before the earliest
/// possible ring, the window start minus the largest threshold, and stays
/// active until [occurrenceGrace] after the window ends, for a delayed bus.
/// Mirrored by the iOS notification extension's AlarmWindow.
class BoardingOccurrence {
  final DateTime boardFrom;
  final DateTime boardUntil;
  final DateTime activeFrom;
  final DateTime activeUntil;

  const BoardingOccurrence({
    required this.boardFrom,
    required this.boardUntil,
    required this.activeFrom,
    required this.activeUntil,
  });
}

/// How long after the window ends a delayed bus is still followed.
const occurrenceGrace = Duration(minutes: 30);

/// The default for the "start checking before the first ring" setting.
const defaultCheckLeadMinutes = 10;

/// The occurrence whose boarding window starts on [day]. A window whose end
/// is earlier than its start ends the next day.
BoardingOccurrence occurrenceOn(
  DateTime day, {
  required TimeOfDay windowStart,
  required TimeOfDay windowEnd,
  required int largestThresholdMinutes,
  required int leadMinutes,
}) {
  final boardFrom = DateTime(day.year, day.month, day.day, windowStart.hour, windowStart.minute);
  final startMinute = windowStart.hour * 60 + windowStart.minute;
  final endMinute = windowEnd.hour * 60 + windowEnd.minute;
  final endDay = startMinute > endMinute ? day.day + 1 : day.day;
  final boardUntil = DateTime(day.year, day.month, endDay, windowEnd.hour, windowEnd.minute);
  return BoardingOccurrence(
    boardFrom: boardFrom,
    boardUntil: boardUntil,
    activeFrom: boardFrom.subtract(Duration(minutes: largestThresholdMinutes + leadMinutes)),
    activeUntil: boardUntil.add(occurrenceGrace),
  );
}

/// The occurrence active at [now], if any. An occurrence belongs to the day
/// its boarding window starts, which must be a repeat day, even when it
/// becomes active the evening before.
BoardingOccurrence? activeOccurrence(
  DateTime now, {
  required TimeOfDay windowStart,
  required TimeOfDay windowEnd,
  required RepeatPattern repeat,
  required int largestThresholdMinutes,
  required int leadMinutes,
}) {
  for (var offset = -1; offset <= 1; offset++) {
    final day = DateTime(now.year, now.month, now.day + offset);
    if (!repeat.occursOn(day)) continue;
    final occurrence = occurrenceOn(
      day,
      windowStart: windowStart,
      windowEnd: windowEnd,
      largestThresholdMinutes: largestThresholdMinutes,
      leadMinutes: leadMinutes,
    );
    if (!now.isBefore(occurrence.activeFrom) && now.isBefore(occurrence.activeUntil)) {
      return occurrence;
    }
  }
  return null;
}

/// The first occurrence that becomes active after [after].
BoardingOccurrence nextOccurrence(
  DateTime after, {
  required TimeOfDay windowStart,
  required TimeOfDay windowEnd,
  required RepeatPattern repeat,
  required int largestThresholdMinutes,
  required int leadMinutes,
}) {
  // From the day before: a window early in the morning can become active
  // the previous evening.
  for (var offset = -1; offset <= 370; offset++) {
    final day = DateTime(after.year, after.month, after.day + offset);
    if (!repeat.occursOn(day)) continue;
    final occurrence = occurrenceOn(
      day,
      windowStart: windowStart,
      windowEnd: windowEnd,
      largestThresholdMinutes: largestThresholdMinutes,
      leadMinutes: leadMinutes,
    );
    if (occurrence.activeFrom.isAfter(after)) return occurrence;
  }
  throw StateError('Could not find the next repeat window.');
}

/// Converts a window saved before it meant boarding times. The old window
/// was when the alarm watched, and it only ever aimed at buses at least the
/// largest threshold away, so the arrivals it could ring for started that
/// much later: the new window starts there and keeps the same end. A window
/// too short for that becomes 30 minutes long. Times are minutes past
/// midnight.
({int start, int end}) migrateWindowMinutes(int start, int end, int largestThresholdMinutes) {
  const day = 24 * 60;
  final length = (end - start) % day;
  final newStart = (start + largestThresholdMinutes) % day;
  if (largestThresholdMinutes >= length) {
    return (start: newStart, end: (newStart + 30) % day);
  }
  return (start: newStart, end: end);
}
