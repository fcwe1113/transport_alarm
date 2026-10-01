import 'package:flutter/services.dart';

class AlarmKitService {
  static const _channel = MethodChannel("com.fcwe1113.transport_alarm/alarmkit");

  Future<bool> requestAuthorization() async {
    try {
      return await _channel.invokeMethod<bool>("requestAuthorization") ?? false;
    } on PlatformException catch (e) {
      print("AlarmKit authorization failed: ${e.message}");
      return false;
    }
  }

  Future<bool> armAlarm({required String alarmId, required double secondsUntilFire, required String title}) async {
    try {
      final result = await _channel.invokeMethod<bool>("armAlarm", {"alarmId": alarmId, "secondsUntilFire": secondsUntilFire, "title": title});
      return result ?? false;
    } on PlatformException catch (e) {
      print("AlarmKit arm failed: ${e.message}");
      return false;
    }
  }

  Future<bool> cancelAlarm({required String alarmId, required double secondsUntilFire, required String title}) async {
    try {
      final result = await _channel.invokeMethod<bool>("cancelAlarm", {"alarmId": alarmId});
      return result ?? false;
    } on PlatformException catch (e) {
      print("AlarmKit cancel failed: ${e.message}");
      return false;
    }
  }
}
