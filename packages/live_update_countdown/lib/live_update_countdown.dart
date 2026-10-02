import 'package:flutter/services.dart';

/// Posts countdown notifications that request Android Live Update promotion.
class LiveUpdateCountdown {
  static const MethodChannel _channel =
      MethodChannel('dev.fcwe1113.live_update_countdown');

  static Future<bool> show({
    required int id,
    required String title,
    required String body,
    required DateTime progressStartTime,
    required DateTime countdownTargetTime,
    required DateTime estimatedArrivalTime,
    required List<DateTime> thresholdTimes,
  }) async {
    return await _channel.invokeMethod<bool>('show', {
          'id': id,
          'title': title,
          'body': body,
          'progressStartMillis': progressStartTime.millisecondsSinceEpoch,
          'countdownTargetMillis': countdownTargetTime.millisecondsSinceEpoch,
          'estimatedArrivalMillis':
              estimatedArrivalTime.millisecondsSinceEpoch,
          'thresholdTimesMillis': thresholdTimes
              .map((time) => time.millisecondsSinceEpoch)
              .toList(),
        }) ??
        false;
  }
}
