import 'package:flutter/widgets.dart';

/// The app's root navigator, for code outside the widget tree that needs to
/// show a screen or dialog: the ring screen from a notification, the launch
/// prompt for "Alarms & reminders" access, and the language settings, which
/// rebuild the route stack after a language change.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();
