import 'package:flutter_test/flutter_test.dart';
import 'package:transport_alarm/widgets/arrival_progress_bar.dart';

void main() {
  final start = DateTime(2026, 11, 9, 8, 0);
  final arrival = DateTime(2026, 11, 9, 8, 20);
  DateTime at(int minutes) => start.add(Duration(minutes: minutes));

  ArrivalProgress layout({required DateTime now, List<({DateTime time, bool done})> rings = const []}) =>
      ArrivalProgress.compute(start: start, arrival: arrival, now: now, rings: rings);

  test('the vehicle moves with time from start to arrival', () {
    expect(layout(now: at(0)).progress, 0);
    expect(layout(now: at(5)).progress, 0.25);
    expect(layout(now: at(20)).progress, 1);
  });

  test('progress stays on the bar before the start and after the arrival', () {
    expect(layout(now: at(-5)).progress, 0);
    expect(layout(now: at(30)).progress, 1);
  });

  test('ring times sit where they fall, keeping whether they rang', () {
    final result = layout(now: at(0), rings: [(time: at(10), done: true), (time: at(15), done: false)]);
    expect(result.points, const [ProgressPoint(0.5, done: true), ProgressPoint(0.75)]);
  });

  test('ring times on or outside either end are left out', () {
    final result = layout(now: at(0), rings: [
      (time: at(0), done: false),
      (time: at(-3), done: false),
      (time: at(20), done: false),
      (time: at(25), done: false),
    ]);
    expect(result.points, isEmpty);
  });

  test('ring times in the same step show once', () {
    final result = layout(now: at(0), rings: [
      (time: at(10), done: false),
      (time: at(10).add(const Duration(milliseconds: 100)), done: false),
    ]);
    expect(result.points, hasLength(1));
  });

  test('an arrival at or before the start fills the bar instead of dividing by zero', () {
    final result = ArrivalProgress.compute(start: start, arrival: start, now: start, rings: const []);
    expect(result.progress, 0);
    final later = ArrivalProgress.compute(start: start, arrival: start, now: at(1), rings: const []);
    expect(later.progress, 1);
  });
}
