import 'dart:convert';

import 'package:http/http.dart' as http;

class AlarmServerService { // todo handle api errors later
  static const _baseUrl = "https://ios-scheduler.fcwe1113.workers.dev";

  Future<String?> schedule({required String deviceToken, required DateTime scheduledTime, required bool requireAck}) async {
    final response = await http.post(Uri.parse("${_baseUrl}/schedule"),
      // headers: {"content-type": "application/json"},
      body: jsonEncode({"device_token": deviceToken, "scheduled_time": scheduledTime.toUtc().millisecondsSinceEpoch ~/ 1000, "require_ack": requireAck})
    );
    if (response.statusCode != 200) return null; // todo error handle later
    return jsonDecode(response.body)["ping_id"]?.toString();
  }

  Future<void> reschedule({required String pingId, required DateTime scheduledTime, required bool requireAck, DateTime? expireOn}) async {
    await http.post(Uri.parse("${_baseUrl}/reschedule"), headers: {"content-type": "application/json"}, body: jsonEncode({
      "ping_id": int.tryParse(pingId), // todo check functionality
      "scheduled_time": scheduledTime.toUtc().millisecondsSinceEpoch ~/ 1000,
      "require_ack": requireAck,
      "expire_on": expireOn == null ? null : expireOn.toUtc().millisecondsSinceEpoch ~/ 1000})
    );
  }

  Future<void> cancelPing(String pingId) async {
    await http.post(Uri.parse("${_baseUrl}/ack"), headers: {"content-type": "application/json"}, body: jsonEncode({"ping_id": pingId}));
  }
}