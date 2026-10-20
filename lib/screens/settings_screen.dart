import 'dart:io';

import 'package:flutter/material.dart';
import 'package:transport_alarm/l10n/app_strings.dart';
import 'package:transport_alarm/screens/settings/about_screen.dart';
import 'package:transport_alarm/screens/settings/app_language_settings_screen.dart';
import 'package:transport_alarm/screens/settings/enabled_locale_settings_screen.dart';
import 'package:transport_alarm/screens/loading_screen.dart';
import 'package:transport_alarm/transit/progress_callback.dart';
import 'package:transport_alarm/transit_bootstrap.dart';
import 'package:transport_alarm/widgets/app_shell.dart';
import 'package:transport_alarm/widgets/data_usage_warning.dart';
import 'package:transport_alarm/widgets/external_link.dart';

/// Setup and troubleshooting notes for this platform, kept in the repo's
/// ios/ and android/ READMEs.
final _helpUrl = Uri.parse(
  'https://github.com/fcwe1113/transport_alarm/blob/master/${Platform.isIOS ? 'ios' : 'android'}/README.md',
);

/// The settings landing page. Each entry opens its own page, a link or a
/// data operation.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    void push(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

    // An entry with no onTap isn't built yet.
    final options = <({IconData icon, String title, String? subtitle, VoidCallback? onTap})>[
      (icon: Icons.language, title: 'settings.app_language', subtitle: 'settings.app_language.subtitle',
        onTap: () => push(const AppLanguageSettingsScreen())),
      (icon: Icons.public, title: 'settings.enabled_locales', subtitle: 'settings.enabled_locales.subtitle',
        onTap: () => push(const EnabledLocalesSettingsScreen())),
      (icon: Icons.notifications_outlined, title: 'settings.alarm_settings', subtitle: 'common.coming_soon', onTap: null),
      (icon: Icons.help_outline, title: 'settings.help', subtitle: 'settings.help.subtitle',
        onTap: () => openExternalLink(context, _helpUrl)),
      (icon: Icons.info_outline, title: 'settings.about', subtitle: null, onTap: () => push(const AboutScreen())),
      (icon: Icons.download, title: 'drawer.reload_data', subtitle: null,
        onTap: () => _openDataOperation(context, operation: initializeTransitData, forceRefresh: true)),
      (icon: Icons.refresh, title: 'drawer.refresh_data', subtitle: null,
        onTap: () => _openDataOperation(context, operation: refreshStaleProviders)),
    ];

    return AppShell(
      title: AppStrings.text('settings.title'),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          for (final option in options)
            ListTile(
              leading: Icon(option.icon),
              title: Text(AppStrings.text(option.title)),
              subtitle: option.subtitle == null ? null : Text(AppStrings.text(option.subtitle!)),
              // Kept tappable so unbuilt entries look the same as before.
              onTap: option.onTap ?? () {},
            ),
        ],
      ),
    );
  }
}

/// Warns about data usage, then runs [operation] on the loading screen.
Future<void> _openDataOperation(
  BuildContext context, {
  required TransitOperation operation,
  bool forceRefresh = false,
}) async {
  if (!await showDataUsageWarning(context)) return;
  if (!context.mounted) return;
  await Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => LoadingScreen(
        operation: operation,
        forceRefresh: forceRefresh,
        returnToPrevious: true,
        showBottomNavigation: true,
        cancellable: true,
      ),
    ),
  );
}
