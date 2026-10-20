import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:transport_alarm/services/alarm_storage_service.dart';

class AlarmServerService { // todo handle api errors later
  static const _baseUrl = "https://ios-scheduler.fcwe1113.workers.dev";

  /// Schedules a new ping, returning its ID and the secret that later
  /// reschedule and ack calls must send, or null if the server refused.
  Future<({String id, String secret})?> schedule({required String deviceToken, required DateTime scheduledTime, required bool requireAck}) async {
    final response = await http.post(Uri.parse("${_baseUrl}/schedule"),
      headers: {"content-type": "application/json"},
      body: jsonEncode({"device_token": deviceToken, "delay_seconds": _delaySeconds(scheduledTime), "require_ack": requireAck})
    );
    if (response.statusCode != 200) return null; // todo error handle later
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final id = body["ping_id"]?.toString();
    final secret = body["ping_secret"]?.toString();
    if (id == null || secret == null) return null;
    return (id: id, secret: secret);
  }

  Future<void> reschedule({required String pingId, required DateTime scheduledTime, required bool requireAck, DateTime? expireOn}) async {
    final secret = await _secretFor(pingId);
    if (secret == null) return; // not ours to change; it expires on its own
    await http.post(Uri.parse("${_baseUrl}/reschedule"), headers: {"content-type": "application/json"}, body: jsonEncode({
      "ping_id": pingId,
      "ping_secret": secret,
      "delay_seconds": _delaySeconds(scheduledTime),
      "require_ack": requireAck,
      "expire_on": expireOn == null ? null : expireOn.toUtc().millisecondsSinceEpoch ~/ 1000})
    );
  }

  Future<void> cancelPing(String pingId) async {
    final secret = await _secretFor(pingId);
    if (secret == null) return; // not ours to cancel; it expires on its own
    await http.post(Uri.parse("${_baseUrl}/ack"), headers: {"content-type": "application/json"}, body: jsonEncode({"ping_id": pingId, "ping_secret": secret}));
  }

  /// Seconds from now until [time]. The server adds this to its own clock,
  /// so a wrong phone clock doesn't shift pings.
  static int _delaySeconds(DateTime time) {
    final seconds = (time.difference(DateTime.now()).inMilliseconds / 1000).round();
    return seconds < 0 ? 0 : seconds;
  }

  /// The secret saved with the alarm that owns [pingId], so callers only
  /// need the ID.
  Future<String?> _secretFor(String pingId) async {
    final alarms = await AlarmStorageService().loadAlarms();
    return alarms.where((alarm) => alarm.pingId == pingId).firstOrNull?.pingSecret;
  }
}
