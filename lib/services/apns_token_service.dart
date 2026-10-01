import 'dart:async';

import 'package:flutter/services.dart';

class ApnsTokenService {
  static const _channel = MethodChannel("com.fcwe1113.transport_alarm/apns_token");

  String? _token;
  final _controller = StreamController<String>.broadcast();

  ApnsTokenService() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == "onTokenReceived") {
        _token = call.arguments as String;
        _controller.add(_token!);
      }
    });
  }

  String? get currentToken => _token;
  Stream<String> get onToken => _controller.stream;
}