import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:transport_alarm/services/alarm_lifecycle_service.dart';
import 'package:transport_alarm/services/alarm_ping_handler.dart';
import 'package:transport_alarm/services/alarm_server_service.dart';
import 'package:transport_alarm/services/alarm_storage_service.dart';

class NotificationService {
  static final FlutterLocalNotificationsPlugin plugin = FlutterLocalNotificationsPlugin();

  static Future<void> init() async {
    const androidSettings = AndroidInitializationSettings("@mipmap/ic_launcher");
    final darwinSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
      defaultPresentAlert: true,
      defaultPresentBadge: true,
      defaultPresentBanner: true,
      notificationCategories: [DarwinNotificationCategory("ping", actions: [DarwinNotificationAction.plain("acknowledge", "Acknowledge", options: {DarwinNotificationActionOption.foreground})])]
    );
    final initSettings = InitializationSettings(
      android: androidSettings,
      iOS: darwinSettings,
    );
    await plugin.initialize(settings: initSettings, onDidReceiveNotificationResponse: _onNotificationResponse);
  }

  static void _onNotificationResponse(NotificationResponse response) { // todo check if ackking alarm has upcoming threshold, if so schedule that instead of ack
    if (response.actionId == "acknowledge" && response.payload != null) {
      final storage = AlarmStorageService();
      final server = AlarmServerService();
      AlarmPingHandler(storage, server, AlarmLifecycleService(storage: storage, server: server)).acknowledge(response.payload!);
    }
  }
}