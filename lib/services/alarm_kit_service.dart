import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// iOS AlarmKit alarms, through AlarmKitBridge in the app. Nothing uses this
/// yet; it's kept for a possible AlarmKit backup to the server pings. Every
/// call returns false if AlarmKit refuses or isn't available.
class AlarmKitService {
  static const _channel = MethodChannel("com.fcwe1113.transport_alarm/alarmkit");

  Future<bool> requestAuthorization() => _invoke("requestAuthorization");

  Future<bool> armAlarm({required String alarmId, required double secondsUntilFire, required String title}) =>
      _invoke("armAlarm", {"alarmId": alarmId, "secondsUntilFire": secondsUntilFire, "title": title});

  Future<bool> cancelAlarm({required String alarmId}) => _invoke("cancelAlarm", {"alarmId": alarmId});

  Future<bool> _invoke(String method, [Map<String, Object>? arguments]) async {
    try {
      return await _channel.invokeMethod<bool>(method, arguments) ?? false;
    } on PlatformException catch (e) {
      debugPrint("AlarmKit $method failed: ${e.message}");
      return false;
    }
  }
}
