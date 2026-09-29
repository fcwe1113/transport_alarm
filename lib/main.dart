import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:transport_alarm/screens/add_alarm_screen.dart';
import 'package:transport_alarm/screens/alarm_list_screen.dart';
import 'package:transport_alarm/screens/loading_screen.dart';
import 'package:transport_alarm/screens/map_screen.dart';
import 'package:transport_alarm/screens/setup_screen.dart';
import 'package:transport_alarm/services/alarm_lifecycle_service.dart';
import 'package:transport_alarm/services/alarm_ping_handler.dart';
import 'package:transport_alarm/services/alarm_server_service.dart';
import 'package:transport_alarm/services/alarm_storage_service.dart';
import 'package:transport_alarm/services/notification_service.dart';
import 'package:transport_alarm/transit/services/locale_selection_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'firebase_options.dart';

@pragma("vm:entry-point")
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  print("Background message received: ${message.messageId}");
  print("Data: ${message.data}");

  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  final pingId = message.data["ping_id"];
  if (pingId == null) return; // should never happen
  final storage = AlarmStorageService();
  final server = AlarmServerService();
  final handler = AlarmPingHandler(storage, server, AlarmLifecycleService(storage: storage, server: server));
  await handler.handlePing(pingId);
}

Future<void> main() async { // dart entry point

  WidgetsFlutterBinding.ensureInitialized();
  final String jsonString = await rootBundle.loadString("config/secrets.json");
  final Map<String, dynamic> secrets = jsonDecode(jsonString);
  final String apiKey = secrets["MAPS_API_KEY"];

  if (defaultTargetPlatform == TargetPlatform.iOS && apiKey.isNotEmpty) {
    const channel = MethodChannel("com.fcwe1113.transport_alarm/google_maps");
    try {
      await channel.invokeMethod("setApiKey", {"apiKey": apiKey});
    } on PlatformException catch (e) {
      debugPrint("Failed to pass Google Maps API key to iOS: ${e.message}");
    }
  }

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  FirebaseMessaging messaging = FirebaseMessaging.instance;
  NotificationSettings settings = await messaging.requestPermission(alert: true, badge: true, sound: true);

  if(Platform.isIOS) {
    String? apnsToken = await messaging.getAPNSToken();
    var attempts = 0;
    while (apnsToken == null && attempts < 5) {
      await Future.delayed(const Duration(seconds: 1));
      apnsToken = await messaging.getAPNSToken();
      attempts++;
    }
  }

  print("User permission status: ${settings.authorizationStatus}");
  String? token = Platform.isIOS ? await messaging.getAPNSToken() : await messaging.getToken();
  print("FCM DEVICE TOKEN: ${token}");

  FirebaseMessaging.instance.onTokenRefresh.listen((newToken) {
    print("FCM Token Refreshed: ${newToken}"); // todo update token at server
  });

  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

  await NotificationService.init();

  FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
    // print("Foreground message received: ${message.messageId}, data: ${message.data}");
    // const androidDetails = AndroidNotificationDetails("alarm_test_channel", "Alarm Test", importance: Importance.high, priority: Priority.high);
    // const notificationDetails = NotificationDetails(android: androidDetails);
    //
    // await flutterLocalNotificationsPlugin.show(id: message.hashCode, title: message.notification?.title ?? "Ping received", body: message.notification?.body ?? "", notificationDetails: notificationDetails);

    final pingId = message.data["ping_id"];
    if (pingId == null) return; // should never happen
    final storage = AlarmStorageService();
    final server = AlarmServerService();
    final handler = AlarmPingHandler(storage, server, AlarmLifecycleService(storage: storage, server: server));
    await handler.handlePing(pingId);
  });

  final selectionService = LocaleSelectionService();
  final setupDone = await selectionService.hasCompletedSetup(); // check if user did setup before

  runApp(MyApp(initialRoute: setupDone ? "/" : "/setup",)); // app entry point, working with flutter from this point on
}

class MyApp extends StatelessWidget { // statelesswidget only has constant internal data
  final String initialRoute;
  const MyApp({super.key, required this.initialRoute});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        // This is the theme of your application.
        //
        // TRY THIS: Try running your application with "flutter run". You'll see
        // the application has a purple toolbar. Then, without quitting the app,
        // try changing the seedColor in the colorScheme below to Colors.green
        // and then invoke "hot reload" (save your changes or press the "hot
        // reload" button in a Flutter-supported IDE, or press "r" if you used
        // the command line to start the app).
        //
        // Notice that the counter didn't reset back to zero; the application
        // state is not lost during the reload. To reset the state, use hot
        // restart instead.
        //
        // This works for code too, not just values: Most code changes can be
        // tested with just a hot reload.
        colorScheme: .fromSeed(seedColor: Colors.deepPurple),
      ),
      initialRoute: initialRoute, // indicate which route to show on boot
      routes: { // list of screens with the routes linked to it
        "/": (context) => const AlarmListScreen(),
        "/map": (context) => const MapScreen(),
        "/setup": (context) => const SetupScreen(),
        "/loading": (context) => const LoadingScreen(),
        "/add-alarm": (context) => const AddAlarmScreen(),
        // add more routes here as we add more screens
      },
    );
  }
}