import 'package:transport_alarm/l10n/app_strings.dart';

enum RepeatFrequency { none, daily, weekly, monthly }

/// Which days an alarm's window runs on.
class RepeatPattern {
  final RepeatFrequency frequency;
  /// For weekly repeats: DateTime weekdays, 1 (Monday) to 7 (Sunday).
  final List<int>? weekdays;
  /// For monthly repeats: days of the month, 1 to 31.
  final List<int>? dayOfMonth;

  const RepeatPattern({required this.frequency, this.weekdays, this.dayOfMonth});

  static const none = RepeatPattern(frequency: RepeatFrequency.none);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is RepeatPattern &&
        other.frequency == frequency &&
        _listEquals(other.weekdays, weekdays) &&
        _listEquals(other.dayOfMonth, dayOfMonth);
  }

  @override
  int get hashCode => Object.hash(
    frequency,
    weekdays == null ? null : Object.hashAll(weekdays!),
    dayOfMonth == null ? null : Object.hashAll(dayOfMonth!),
  );

  static bool _listEquals(List<int>? a, List<int>? b) {
    if (a == null) return b == null;
    if (b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Whether a window starting on [day] runs. One-off alarms run on any day.
  bool occursOn(DateTime day) {
    switch (frequency) {
      case RepeatFrequency.none:
      case RepeatFrequency.daily:
        return true;
      case RepeatFrequency.weekly:
        return (weekdays ?? const []).contains(day.weekday);
      case RepeatFrequency.monthly:
        return (dayOfMonth ?? const []).contains(day.day);
    }
  }

  Map<String, dynamic> toJson() => {
    "frequency": frequency.name,
    "weekdays": weekdays,
    "dayOfMonth": dayOfMonth
  };

  static RepeatPattern fromJson(Map<String, dynamic> json) => RepeatPattern(
    frequency: RepeatFrequency.values.byName(json["frequency"] as String),
    weekdays: (json["weekdays"] as List<dynamic>?)?.map((e) => e as int).toList(),
    dayOfMonth: (json["dayOfMonth"] as List<dynamic>?)?.map((e) => e as int).toList(),
  );

  String formatWeekdays(Set<int> days) {
    // Saving turns every day into daily and refuses no days, but older or
    // hand-made data may still have them.
    if (days.isEmpty) return AppStrings.text('repeat.never');
    if (days.length == 7) return AppStrings.text('repeat.everyday');
    if (days.length == 5 && days.containsAll({1, 2, 3, 4, 5})) return AppStrings.text('repeat.weekdays');
    if (days.length == 2 && days.containsAll({6, 7})) return AppStrings.text('repeat.weekends');

    final dayNames = [
      AppStrings.text('repeat.day.mon'),
      AppStrings.text('repeat.day.tue'),
      AppStrings.text('repeat.day.wed'),
      AppStrings.text('repeat.day.thu'),
      AppStrings.text('repeat.day.fri'),
      AppStrings.text('repeat.day.sat'),
      AppStrings.text('repeat.day.sun'),
    ];
    final sortedDays = days.toList()..sort();
    return sortedDays.map((day) => dayNames[day - 1]).join(", ");
  }

  String getOrdinalDay(int day) {
    if (day >= 11 && day <= 13) {
      return AppStrings.text('repeat.ordinal.th', {'day': day});
    }
    switch (day) {
      case 1:
        return AppStrings.text('repeat.ordinal.st', {'day': day});
      case 2:
        return AppStrings.text('repeat.ordinal.nd', {'day': day});
      case 3:
        return AppStrings.text('repeat.ordinal.rd', {'day': day});
      default:
        return AppStrings.text('repeat.ordinal.th', {'day': day});
    }
  }

  String formatMonthlyDays(Set<int> days) {
    if (days.isEmpty) return AppStrings.text('repeat.never');
    final sortedDays = days.toList()..sort();
    final formattedDays = sortedDays.map((d) => getOrdinalDay(d)).join(", ");

    if (sortedDays.length == 1) {
      return AppStrings.text('repeat.monthly_on_day', {'days': formattedDays});
    }
    return AppStrings.text('repeat.monthly_on_days', {'days': formattedDays});
  }

  /// The repeat as shown on the alarm card, or null for a one-off alarm.
  String? toInfoString() {
    switch (frequency) {
      case RepeatFrequency.none:
        return null;
      case RepeatFrequency.daily:
        return AppStrings.text('repeat.daily');
      case RepeatFrequency.weekly:
        return formatWeekdays({...?weekdays});
      case RepeatFrequency.monthly:
        return formatMonthlyDays({...?dayOfMonth});
    }
  }
}
