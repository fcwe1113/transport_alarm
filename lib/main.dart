import 'dart:async';
import 'dart:convert';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:transport_alarm/screens/add_alarm_screen.dart';
import 'package:transport_alarm/screens/alarm_list_screen.dart';
import 'package:transport_alarm/screens/loading_screen.dart';
import 'package:transport_alarm/screens/map_screen.dart';
import 'package:transport_alarm/screens/setup_language_screen.dart';
import 'package:transport_alarm/screens/setup_screen.dart';
import 'package:transport_alarm/screens/settings_screen.dart';
import 'package:transport_alarm/l10n/app_strings.dart';
import 'package:transport_alarm/l10n/app_language_state.dart';
import 'package:transport_alarm/l10n/app_languages.dart';
import 'package:transport_alarm/services/app_group_storage.dart';
import 'package:transport_alarm/services/alarm_lifecycle_service.dart';
import 'package:transport_alarm/services/alarm_storage_service.dart';
import 'package:transport_alarm/services/android_alarm_coordinator.dart';
import 'package:transport_alarm/services/notification_service.dart';
import 'package:transport_alarm/transit/locale/gb/providers/gb_bods_provider.dart';
import 'package:transport_alarm/transit/services/locale_selection_service.dart';
import 'package:transport_alarm/transit/services/temp_file_cleaner.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await GbBodsProvider.loadApiKey();
  // Clear scratch files from a sync that was killed last run. No sync can be
  // running yet, and it isn't awaited so startup isn't held up.
  unawaited(TempFileCleaner.sweep());
  final selectionService = LocaleSelectionService();
  // Before anything reads the enabled regions: a locale change killed
  // partway leaves regions enabled that have no data.
  await selectionService.rollBackUnfinishedLocaleChange();
  final appLanguageCode = await selectionService.getAppLanguageCode();
  await AppStrings.load(appLanguageCode);
  appLanguageCodeNotifier.value = appLanguageCode;
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    await _initIos(appLanguageCode);
  } else if (defaultTargetPlatform == TargetPlatform.android) {
    await _initAndroid();
  }

  final setupDone = await selectionService.hasCompletedSetup();
  runApp(MyApp(initialRoute: setupDone ? "/" : "/setup-language"));
}

/// Shares the app language with the extensions, hands Google Maps its key,
/// and starts keeping server pings on this device's push token. The token
/// may arrive after launch; the resync picks it up when it does.
Future<void> _initIos(String appLanguageCode) async {
  await AppGroupStorage.setAppLanguageCode(appLanguageCode);
  final secrets = jsonDecode(await rootBundle.loadString("config/secrets.json")) as Map<String, dynamic>;
  final apiKey = secrets["MAPS_API_KEY"] as String? ?? "";
  if (apiKey.isNotEmpty) {
    const channel = MethodChannel("com.fcwe1113.transport_alarm/google_maps");
    try {
      await channel.invokeMethod("setApiKey", {"apiKey": apiKey});
    } on PlatformException catch (e) {
      debugPrint("Failed to pass Google Maps API key to iOS: ${e.message}");
    }
  }
  AlarmLifecycleService.startIosPingResync();
}

/// Sets up local alarms and notifications, and re-arms alarms, which
/// Android drops on a force stop or app update.
Future<void> _initAndroid() async {
  await AndroidAlarmManager.initialize();
  await NotificationService.init();
  unawaited(AndroidAlarmCoordinator(AlarmStorageService()).resumeAll());
}

class MyApp extends StatelessWidget {
  final String initialRoute;
  const MyApp({super.key, required this.initialRoute});

  @override
  Widget build(BuildContext context) {
    // Rebuilt with the new locale whenever the app language changes.
    return ValueListenableBuilder<String>(
      valueListenable: appLanguageCodeNotifier,
      builder: (context, languageCode, _) => MaterialApp(
        navigatorKey: appNavigatorKey,
        title: AppStrings.text('app.title'),
        locale: localeForAppLanguage(languageCode),
        supportedLocales: [
          for (final language in appLanguages) localeForAppLanguage(language.code),
        ],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: ThemeData(colorScheme: .fromSeed(seedColor: Colors.deepPurple)),
        initialRoute: initialRoute,
        onGenerateRoute: _generateRoute,
      ),
    );
  }
}

Route<dynamic>? _generateRoute(RouteSettings settings) {
  switch (settings.name) {
    case '/':
      return _tabRoute(settings, const AlarmListScreen());
    case '/map':
      return _tabRoute(settings, const MapScreen());
    case '/settings':
      return _tabRoute(settings, const SettingsScreen());
    case '/setup-language':
      return MaterialPageRoute<void>(
        settings: settings,
        builder: (_) => const SetupLanguageScreen(),
      );
    case '/setup':
      return MaterialPageRoute<void>(
        settings: settings,
        builder: (_) => const SetupScreen(),
      );
    case '/loading':
      return MaterialPageRoute<void>(
        settings: settings,
        builder: (_) => const LoadingScreen(firstTimeSetup: true),
      );
    case '/add-alarm':
      return MaterialPageRoute<void>(
        settings: settings,
        builder: (_) => const AddAlarmScreen(),
      );
    default:
      return null;
  }
}

/// A bottom-tab page, shown without a transition.
PageRoute<void> _tabRoute(RouteSettings settings, Widget page) {
  return PageRouteBuilder<void>(
    settings: settings,
    transitionDuration: Duration.zero,
    reverseTransitionDuration: Duration.zero,
    pageBuilder: (_, _, _) => page,
    transitionsBuilder: (_, _, _, child) => child,
  );
}
