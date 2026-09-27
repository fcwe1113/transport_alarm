import 'package:firebase_messaging/firebase_messaging.dart';

class DeviceTokenService {
  Future<String?> getToken() {
    return FirebaseMessaging.instance.getToken();
  }
}