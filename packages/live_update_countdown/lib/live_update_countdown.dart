import 'package:flutter/services.dart';

/// A countdown's action button that was tapped: [actionId] and the
/// [argument] it was posted with.
typedef LiveUpdateAction = ({String actionId, String? argument});

/// Posts countdown notifications that request Android Live Update promotion.
/// A countdown can have one action button, which opens the app.
class LiveUpdateCountdown {
  static const MethodChannel _channel =
      MethodChannel('dev.fcwe1113.live_update_countdown');

  /// Handles action taps while the app is running. A tap that launched the
  /// app is read with [takePendingAction] instead.
  static void setActionHandler(void Function(LiveUpdateAction action) handler) {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'onAction') return;
      final action = _parseAction(call.arguments);
      if (action != null) handler(action);
    });
  }

  /// The action whose tap launched the app, once; null otherwise.
  static Future<LiveUpdateAction?> takePendingAction() async =>
      _parseAction(await _channel.invokeMethod<Object?>('takePendingAction'));

  static LiveUpdateAction? _parseAction(Object? arguments) {
    if (arguments is! Map) return null;
    final actionId = arguments['actionId'];
    if (actionId is! String) return null;
    return (actionId: actionId, argument: arguments['argument'] as String?);
  }

  static Future<bool> show({
    required int id,
    required String title,
    required String body,
    required String subText,
    required DateTime progressStartTime,
    required DateTime countdownTargetTime,
    required DateTime estimatedArrivalTime,
    required List<DateTime> thresholdTimes,
    String? actionId,
    String? actionLabel,
    String? actionArgument,
  }) async {
    return await _channel.invokeMethod<bool>('show', {
          'id': id,
          'title': title,
          'body': body,
          'subText': subText,
          'progressStartMillis': progressStartTime.millisecondsSinceEpoch,
          'countdownTargetMillis': countdownTargetTime.millisecondsSinceEpoch,
          'estimatedArrivalMillis':
              estimatedArrivalTime.millisecondsSinceEpoch,
          'thresholdTimesMillis': thresholdTimes
              .map((time) => time.millisecondsSinceEpoch)
              .toList(),
          'actionId': actionId,
          'actionLabel': actionLabel,
          'actionArgument': actionArgument,
        }) ??
        false;
  }
}
