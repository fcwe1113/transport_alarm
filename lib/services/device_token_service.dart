import 'dart:io';
import 'package:transport_alarm/services/apns_token_service.dart';

class DeviceTokenService {
  static Future<String?> getToken() async {
    if (Platform.isIOS) {
      return await ApnsTokenService.instance.getToken();
    }
    return null;
  }
}
