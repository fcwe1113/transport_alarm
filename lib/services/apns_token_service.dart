import 'dart:async';

import 'package:flutter/services.dart';

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

  String? get currentToken => _token;
  Stream<String> get onToken => _controller.stream;

  Future<String?> getToken() async {
    if (_token != null) return _token;
    _token = await _channel.invokeMethod<String?>("getToken");
    return _token;
  }
}
