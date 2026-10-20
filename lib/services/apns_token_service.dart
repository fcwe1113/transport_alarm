import 'dart:async';

import 'package:flutter/services.dart';

/// This device's APNs push token, from AppDelegate. iOS can hand out a new
/// token at any launch; [onToken] reports each one so pings can be moved to
/// it.
class ApnsTokenService {
  static const _channel = MethodChannel("com.fcwe1113.transport_alarm/apns_token");
  static final ApnsTokenService instance = ApnsTokenService._();

  String? _token;
  final _controller = StreamController<String>.broadcast();

  ApnsTokenService._() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == "onTokenReceived") {
        final token = call.arguments as String?;
        if (token != null) {
          _token = token;
          _controller.add(token);
        }
      }
    });
  }

  /// Every token iOS issues from now on, including a repeat of the current one.
  Stream<String> get onToken => _controller.stream;

  /// The current token, or null if iOS hasn't issued one yet.
  Future<String?> getToken() async {
    if (_token != null) return _token;
    _token = await _channel.invokeMethod<String?>("getToken");
    return _token;
  }
}
