import 'dart:convert';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:transport_alarm/screens/add_alarm_screen.dart';
import 'package:transport_alarm/screens/alarm_list_screen.dart';
import 'package:transport_alarm/screens/loading_screen.dart';
import 'package:transport_alarm/screens/map_screen.dart';
import 'package:transport_alarm/screens/setup_screen.dart';
import 'package:transport_alarm/screens/settings_screen.dart';
import 'package:transport_alarm/l10n/app_strings.dart';
import 'package:transport_alarm/l10n/app_language_state.dart';
import 'package:transport_alarm/services/app_group_storage.dart';
import 'package:transport_alarm/services/apns_token_service.dart';
import 'package:transport_alarm/services/notification_service.dart';
import 'package:transport_alarm/transit/services/locale_selection_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

Future<void> main() async { // dart entry point

  WidgetsFlutterBinding.ensureInitialized();
  await AppGroupStorage.migrateLegacyDocuments();
  final selectionService = LocaleSelectionService();
  final appLanguageCode = await selectionService.getAppLanguageCode();
  await AppStrings.load(appLanguageCode);
  appLanguageCodeNotifier.value = appLanguageCode;
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    await AppGroupStorage.setAppLanguageCode(appLanguageCode);
  }
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    final String jsonString = await rootBundle.loadString("config/secrets.json");
    final Map<String, dynamic> secrets = jsonDecode(jsonString);
    final String apiKey = secrets["MAPS_API_KEY"];
    if (apiKey.isNotEmpty) {
      const channel = MethodChannel("com.fcwe1113.transport_alarm/google_maps");
      try {
        await channel.invokeMethod("setApiKey", {"apiKey": apiKey});
      } on PlatformException catch (e) {
        debugPrint("Failed to pass Google Maps API key to iOS: ${e.message}");
      }
    }

    String? apnsToken = await ApnsTokenService.instance.getToken();
    var attempts = 0;
    while (apnsToken == null && attempts < 5) {
      await Future.delayed(const Duration(seconds: 1));
      apnsToken = await ApnsTokenService.instance.getToken();
      attempts++;
    }
    print("APNS DEVICE TOKEN: ${apnsToken}");
  } else if (defaultTargetPlatform == TargetPlatform.android) {
    await AndroidAlarmManager.initialize();
    await NotificationService.init();
  }

  final setupDone = await selectionService.hasCompletedSetup(); // check if user did setup before

  runApp(MyApp(
    initialRoute: setupDone ? "/" : "/setup",
  )); // app entry point, working with flutter from this point on
}

class MyApp extends StatelessWidget { // statelesswidget only has constant internal data
  final String initialRoute;
  final String? appLanguageCode;
  const MyApp({super.key, required this.initialRoute, this.appLanguageCode});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: appLanguageCodeNotifier,
      builder: (context, languageCode, _) => MaterialApp(
      title: AppStrings.text('app.title'),
      locale: localeForAppLanguage(languageCode),
      supportedLocales: const [
        Locale('en'),
        Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
        Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
        Locale('ja'),
        Locale('fr'),
        Locale('es'),
        Locale('de'),
        Locale('nl'),
        Locale('it'),
        Locale('pl'),
        Locale('ko'),
        Locale('uk'),
      ],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
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
        "/settings": (context) => const SettingsScreen(),
        // add more routes here as we add more screens
      },
      ),
    );
  }
}
