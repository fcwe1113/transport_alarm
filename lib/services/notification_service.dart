import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:live_update_countdown/live_update_countdown.dart';
import 'package:transport_alarm/l10n/app_strings.dart';
import 'package:transport_alarm/services/alarm_storage_service.dart';
import 'package:transport_alarm/services/android_alarm_coordinator.dart';

/// Android's alarm notifications: threshold rings, the live countdown, and
/// status and problem notices, each on its own channel. iOS notices come
/// from the notification service extension instead, so this is only set up
/// on Android.
class NotificationService {
  static final FlutterLocalNotificationsPlugin plugin =
      FlutterLocalNotificationsPlugin();

  static const String ringChannelId = 'transport_alarm_ring_channel';
  static String get ringChannelName => AppStrings.text('notification.channel.rings');
  static const String statusChannelId = 'transport_alarm_status_channel';
  static String get statusChannelName => AppStrings.text('notification.channel.updates');
  // Makes a sound once, for problems the user should know about, such as
  // live arrival times failing to load.
  static const String alertChannelId = 'transport_alarm_alert_channel';
  static String get alertChannelName => AppStrings.text('notification.channel.alerts');

  static const _alarmSound = UriAndroidNotificationSound(
    'content://settings/system/alarm_alert',
  );
  // Android's FLAG_INSISTENT: repeat the sound until the notification is
  // acknowledged or dismissed.
  static final _insistentFlag = Int32List.fromList(<int>[4]);

  /// Sets up notifications in the app, handles an Acknowledge tap that
  /// launched it, and asks for notification permission.
  static Future<void> init() async {
    await plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: _onNotificationResponse,
    );
    await _createAndroidChannels();
    final launchDetails = await plugin.getNotificationAppLaunchDetails();
    final response = launchDetails?.notificationResponse;
    if (launchDetails?.didNotificationLaunchApp == true && response != null) {
      await _handleNotificationResponse(response);
    }
    await _android?.requestNotificationsPermission();
  }

  static AndroidFlutterLocalNotificationsPlugin? get _android =>
      plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  /// Initializes notification support in the AlarmManager background isolate.
  static Future<void> initBackground() async {
    await plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
    await _createAndroidChannels();
  }

  /// Creates or updates the three channels, with names in the app's language.
  static Future<void> _createAndroidChannels() async {
    final android = _android;
    await android?.createNotificationChannel(
      AndroidNotificationChannel(
        ringChannelId,
        ringChannelName,
        description: AppStrings.text('notification.channel.rings.description'),
        importance: Importance.max,
        playSound: true,
        sound: _alarmSound,
        audioAttributesUsage: AudioAttributesUsage.alarm,
        enableVibration: true,
      ),
    );
    await android?.createNotificationChannel(
      AndroidNotificationChannel(
        alertChannelId,
        alertChannelName,
        description: AppStrings.text('notification.channel.alerts.description'),
        importance: Importance.high,
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

  /// A threshold ring: the alarm sound, repeating until acknowledged, over
  /// the lock screen.
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
          sound: _alarmSound,
          audioAttributesUsage: AudioAttributesUsage.alarm,
          additionalFlags: _insistentFlag,
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

  /// Shows a silent live update with a timeline ending at
  /// [estimatedArrivalTime], through the live_update_countdown plugin.
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
    await LiveUpdateCountdown.show(
      id: notificationId,
      title: title,
      body: body,
      progressStartTime: progressStartTime,
      countdownTargetTime: countdownTargetTime,
      estimatedArrivalTime: estimatedArrivalTime,
      thresholdTimes: thresholdTimes,
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

  /// Like [showSilentStatus], but plays the default notification sound once.
  static Future<void> showAlert({
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
          alertChannelId,
          alertChannelName,
          importance: Importance.high,
          priority: Priority.high,
          playSound: true,
          enableVibration: true,
          onlyAlertOnce: true,
          ongoing: false,
          autoCancel: true,
        ),
      ),
      payload: 'status:$alarmId',
    );
  }

  /// Whether AlarmManager can schedule exact alarms. Asked of AlarmManager
  /// itself: on Android 13+ the app holds USE_EXACT_ALARM from install and
  /// doesn't declare SCHEDULE_EXACT_ALARM, which permission_handler wrongly
  /// reports as denied.
  static Future<bool> canScheduleExactAlarms() async =>
      await _android?.canScheduleExactNotifications() ?? true;

  /// Opens Android's "Alarms & reminders" setting if exact alarms aren't
  /// allowed yet, and returns whether they are now. Needs the app on screen.
  static Future<bool> requestExactAlarms() async {
    if (await canScheduleExactAlarms()) return true;
    await _android?.requestExactAlarmsPermission();
    // The result can come back before the setting does, so check again.
    return canScheduleExactAlarms();
  }

  static Future<void> cancel(int notificationId) =>
      plugin.cancel(id: notificationId);

  static void _onNotificationResponse(NotificationResponse response) {
    unawaited(_handleNotificationResponse(response));
  }

  static Future<void> _handleNotificationResponse(
    NotificationResponse response,
  ) async {
    // Payloads are "ring:<alarmId>" or "status:<alarmId>".
    final payload = response.payload;
    if (payload == null || response.actionId != 'acknowledge') return;
    final alarmId = payload.substring(payload.indexOf(':') + 1);
    await AndroidAlarmCoordinator(AlarmStorageService()).acknowledge(alarmId);
  }
}
