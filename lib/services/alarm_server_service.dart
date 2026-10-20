import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:transport_alarm/services/alarm_storage_service.dart';

/// The app's calls to the Cloudflare Worker that sends iOS alarm pings. The
/// notification extension and AppDelegate reschedule and acknowledge pings
/// natively; the app only creates them, moves them to a new push token, and
/// cancels them.
class AlarmServerService {
  static const _baseUrl = "https://ios-scheduler.fcwe1113.workers.dev";
  // Without one, a request on a dead connection can hang for minutes.
  static const _timeout = Duration(seconds: 10);

  /// Schedules a new ping, returning its ID and the secret that later
  /// reschedule and ack calls must send, or null if the server refused.
  Future<({String id, String secret})?> schedule({required String deviceToken, required DateTime scheduledTime, required bool requireAck}) async {
    final response = await _post("schedule", {
      "device_token": deviceToken,
      "delay_seconds": _delaySeconds(scheduledTime),
      "require_ack": requireAck,
    });
    if (response.statusCode != 200) return null;
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final id = body["ping_id"]?.toString();
    final secret = body["ping_secret"]?.toString();
    if (id == null || secret == null) return null;
    return (id: id, secret: secret);
  }

  /// Moves a ping to the device's current push token. Returns false when
  /// the server no longer has the ping, so the caller can schedule a new one;
  /// throws on other failures.
  Future<bool> updateToken({required String pingId, required String secret, required String deviceToken}) async {
    final response = await _post("update_token", {
      "ping_id": pingId,
      "ping_secret": secret,
      "device_token": deviceToken,
    });
    if (response.statusCode == 404) return false;
    if (response.statusCode != 200) throw Exception("update_token failed with HTTP ${response.statusCode}");
    return true;
  }

  Future<void> cancelPing(String pingId) async {
    final secret = await _secretFor(pingId);
    if (secret == null) return; // not ours to cancel; it expires on its own
    await _post("ack", {"ping_id": pingId, "ping_secret": secret});
  }

  /// Throws a TimeoutException after [_timeout].
  Future<http.Response> _post(String path, Map<String, Object?> body) => http.post(
    Uri.parse("$_baseUrl/$path"),
    headers: {"content-type": "application/json"},
    body: jsonEncode(body),
  ).timeout(_timeout);

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
