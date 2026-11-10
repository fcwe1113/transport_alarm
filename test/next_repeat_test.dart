import 'package:flutter_test/flutter_test.dart';
import 'package:transport_alarm/l10n/app_strings.dart';
import 'package:transport_alarm/widgets/alarm_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => AppStrings.load('en'));

  // A Monday evening, after the day's window.
  final now = DateTime(2026, 11, 9, 18, 0);
  String describe(DateTime next) => describeNextRepeat(next, now, shortDate: (d) => '${d.day}/${d.month}');

  test('later today, for a window that crossed midnight', () {
    expect(describe(DateTime(2026, 11, 9, 23, 30)), 'today 23:30');
  });

  test('tomorrow', () {
    expect(describe(DateTime(2026, 11, 10, 7, 5)), 'tomorrow 07:05');
  });

  test('the weekday within the next week', () {
    expect(describe(DateTime(2026, 11, 11, 7, 30)), 'Wed 07:30');
    expect(describe(DateTime(2026, 11, 15, 7, 30)), 'Sun 07:30');
  });

  test('the date a week or more ahead', () {
    expect(describe(DateTime(2026, 11, 16, 7, 30)), '16/11 07:30');
    expect(describe(DateTime(2026, 12, 9, 7, 30)), '9/12 07:30');
  });

  test('counts calendar days across a clock change', () {
    final beforeChange = DateTime(2026, 3, 28, 18, 0);
    expect(
      describeNextRepeat(DateTime(2026, 3, 29, 7, 30), beforeChange, shortDate: (d) => ''),
      'tomorrow 07:30',
    );
  });
}
