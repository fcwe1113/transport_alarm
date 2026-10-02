import 'dart:async';
import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:live_update_countdown/live_update_countdown.dart';
import 'package:transport_alarm/l10n/app_strings.dart';
import 'package:transport_alarm/services/alarm_lifecycle_service.dart';
import 'package:transport_alarm/services/alarm_ping_handler.dart';
import 'package:transport_alarm/services/alarm_server_service.dart';
import 'package:transport_alarm/services/alarm_storage_service.dart';
import 'package:transport_alarm/services/android_alarm_coordinator.dart';

class NotificationService {
  static final FlutterLocalNotificationsPlugin plugin =
      FlutterLocalNotificationsPlugin();

  static const String ringChannelId = 'transport_alarm_ring_channel';
  static String get ringChannelName => AppStrings.text('notification.channel.rings');
  static const String statusChannelId = 'transport_alarm_status_channel';
  static String get statusChannelName => AppStrings.text('notification.channel.updates');

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
              AppStrings.text('native.acknowledge'),
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
        AndroidNotificationChannel(
          ringChannelId,
          ringChannelName,
          description: AppStrings.text('notification.channel.rings.description'),
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
      ),
    );
    await android?.createNotificationChannel(
        AndroidNotificationChannel(
          statusChannelId,
          statusChannelName,
          description: AppStrings.text('notification.channel.updates.description'),
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
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          ringChannelId,
          ringChannelName,
          importance: Importance.max,
          priority: Priority.max,
          playSound: true,
          enableVibration: true,
          ongoing: true,
          autoCancel: false,
          category: AndroidNotificationCategory.alarm,
          fullScreenIntent: true,
          visibility: NotificationVisibility.public,
          actions: [
            AndroidNotificationAction(
              'acknowledge',
              AppStrings.text('notification.acknowledge_action'),
              showsUserInterface: true,
            ),
          ],
        ),
      ),
      payload: 'ring:$alarmId',
    );
  }

  /// Shows a silent notification with a timeline ending at [estimatedArrivalTime].
  static Future<void> showCountdown({
    required int notificationId,
    required String alarmId,
    required String title,
    required String body,
    required DateTime progressStartTime,
    required DateTime countdownTargetTime,
    required DateTime estimatedArrivalTime,
    required List<DateTime> thresholdTimes,
  }) async {
    if (Platform.isAndroid) {
      await LiveUpdateCountdown.show(
        id: notificationId,
        title: title,
        body: body,
        progressStartTime: progressStartTime,
        countdownTargetTime: countdownTargetTime,
        estimatedArrivalTime: estimatedArrivalTime,
        thresholdTimes: thresholdTimes,
      );
      return;
    }

    await plugin.show(
      id: notificationId,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          statusChannelId,
          statusChannelName,
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          playSound: false,
          enableVibration: false,
          ongoing: true,
          autoCancel: false,
          progress: _progressValue(
            progressStartTime,
            estimatedArrivalTime,
          ),
          maxProgress: 1000,
          showProgress: true,
          showWhen: true,
          when: countdownTargetTime.millisecondsSinceEpoch,
          usesChronometer: true,
          chronometerCountDown: true,
        ),
      ),
      payload: 'status:$alarmId',
    );
  }

  static int _progressValue(DateTime start, DateTime arrival) {
    final totalMillis = arrival.difference(start).inMilliseconds;
    if (totalMillis <= 0) return 1000;
    final elapsedMillis = DateTime.now().difference(start).inMilliseconds;
    return (elapsedMillis * 1000 / totalMillis)
        .round()
        .clamp(0, 1000)
        .toInt();
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
      notificationDetails: NotificationDetails(
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
      if (response.actionId == 'acknowledge') {
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
