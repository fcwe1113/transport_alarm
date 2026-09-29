import 'dart:io';
import 'package:firebase_messaging/firebase_messaging.dart';

class DeviceTokenService {
  static Future<String?> getToken() async {
    if (Platform.isIOS) {
      return await FirebaseMessaging.instance.getAPNSToken();
    }
    return await FirebaseMessaging.instance.getToken();
  }
}