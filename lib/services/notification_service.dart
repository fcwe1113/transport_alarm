import 'dart:async';
import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:transport_alarm/services/alarm_lifecycle_service.dart';
import 'package:transport_alarm/services/alarm_ping_handler.dart';
import 'package:transport_alarm/services/alarm_server_service.dart';
import 'package:transport_alarm/services/alarm_storage_service.dart';
import 'package:transport_alarm/services/android_alarm_coordinator.dart';

class NotificationService {
  static final FlutterLocalNotificationsPlugin plugin =
      FlutterLocalNotificationsPlugin();

  static const String ringChannelId = 'transport_alarm_ring_channel';
  static const String ringChannelName = 'Alarm rings';
  static const String statusChannelId = 'transport_alarm_status_channel';
  static const String statusChannelName = 'Alarm updates';

  static Future<void> init() async {
    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    final darwinSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
      defaultPresentAlert: true,
      defaultPresentBadge: true,
      defaultPresentBanner: true,
      notificationCategories: [
        DarwinNotificationCategory(
          'ping',
          actions: [
            DarwinNotificationAction.plain(
              'acknowledge',
              'Acknowledge',
              options: {DarwinNotificationActionOption.foreground},
            ),
          ],
        ),
      ],
    );
    await plugin.initialize(
      settings: InitializationSettings(
        android: androidSettings,
        iOS: darwinSettings,
      ),
      onDidReceiveNotificationResponse: _onNotificationResponse,
    );
    if (Platform.isAndroid) {
      await _createAndroidChannels();
      final launchDetails = await plugin.getNotificationAppLaunchDetails();
      final response = launchDetails?.notificationResponse;
      if (launchDetails?.didNotificationLaunchApp == true && response != null) {
        await _handleNotificationResponse(response);
      }
      await plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
    }
  }

  /// Initializes notification support in the AlarmManager background isolate.
  static Future<void> initBackground() async {
    await plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
    await _createAndroidChannels();
  }

  static Future<void> _createAndroidChannels() async {
    final android = plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        ringChannelId,
        ringChannelName,
        description: 'Audible notifications for acknowledged alarm thresholds.',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
      ),
    );
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        statusChannelId,
        statusChannelName,
        description: 'Silent arrival tracking and service status updates.',
        importance: Importance.defaultImportance,
        playSound: false,
        enableVibration: false,
      ),
    );
  }

  static Future<void> showThresholdRing({
    required int notificationId,
    required String alarmId,
    required String title,
    required String body,
  }) async {
    await plugin.show(
      id: notificationId,
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          ringChannelId,
          ringChannelName,
          importance: Importance.max,
          priority: Priority.max,
          playSound: true,
          enableVibration: true,
          ongoing: true,
          autoCancel: false,
          actions: [
            AndroidNotificationAction(
              'acknowledge',
              "I'm up / Got it",
              showsUserInterface: true,
            ),
          ],
        ),
      ),
      payload: 'ring:$alarmId',
    );
  }

  static Future<void> showSilentStatus({
    required int notificationId,
    required String alarmId,
    required String title,
    required String body,
  }) async {
    await plugin.show(
      id: notificationId,
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          statusChannelId,
          statusChannelName,
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          playSound: false,
          enableVibration: false,
          ongoing: false,
          autoCancel: true,
        ),
      ),
      payload: 'status:$alarmId',
    );
  }

  static Future<void> cancel(int notificationId) =>
      plugin.cancel(id: notificationId);

  static void _onNotificationResponse(NotificationResponse response) {
    unawaited(_handleNotificationResponse(response));
  }

  static Future<void> _handleNotificationResponse(
    NotificationResponse response,
  ) async {
    final payload = response.payload;
    if (Platform.isAndroid && payload != null) {
      final isRingNotification = payload.startsWith('ring:');
      if (response.actionId == 'acknowledge' ||
          (response.actionId == null && isRingNotification)) {
        final alarmId = payload.substring(payload.indexOf(':') + 1);
        await AndroidAlarmCoordinator(
          AlarmStorageService(),
        ).acknowledge(alarmId);
      }
      return;
    }

    if (response.actionId == 'acknowledge' && payload != null) {
      final storage = AlarmStorageService();
      final server = AlarmServerService();
      await AlarmPingHandler(
        storage,
        server,
        AlarmLifecycleService(storage: storage, server: server),
      ).acknowledge(payload);
    }
  }
}
