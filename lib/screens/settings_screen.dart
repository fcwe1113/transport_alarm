import 'dart:io';

import 'package:flutter/material.dart';
import 'package:transport_alarm/l10n/app_strings.dart';
import 'package:transport_alarm/screens/settings/app_language_settings_screen.dart';
import 'package:transport_alarm/screens/settings/enabled_locale_settings_screen.dart';
import 'package:transport_alarm/screens/loading_screen.dart';
import 'package:transport_alarm/transit/progress_callback.dart';
import 'package:transport_alarm/transit_bootstrap.dart';
import 'package:transport_alarm/widgets/app_shell.dart';
import 'package:transport_alarm/widgets/data_usage_warning.dart';
import 'package:url_launcher/url_launcher.dart';

/// Setup and troubleshooting notes for this platform, kept in the repo's
/// ios/ and android/ READMEs.
final _helpUrl = Uri.parse(
  'https://github.com/fcwe1113/transport_alarm/blob/master/${Platform.isIOS ? 'ios' : 'android'}/README.md',
);

/// Settings landing page; language selection is implemented as a child page.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final options = <({IconData icon, String title})>[
      (icon: Icons.language, title: 'settings.app_language'),
      (icon: Icons.public, title: 'settings.enabled_locales'),
      (icon: Icons.notifications_outlined, title: 'settings.alarm_settings'),
      (icon: Icons.help_outline, title: 'settings.help'),
      (icon: Icons.info_outline, title: 'settings.about'),
      (icon: Icons.download, title: 'drawer.reload_data'),
      (icon: Icons.refresh, title: 'drawer.refresh_data'),
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
              subtitle: option.title == 'settings.app_language'
                  ? Text(AppStrings.text('settings.app_language.subtitle'))
                  : option.title == 'settings.enabled_locales'
                  ? Text(AppStrings.text('settings.enabled_locales.subtitle'))
                  : option.title == 'settings.help'
                  ? Text(AppStrings.text('settings.help.subtitle'))
                  : option.title.startsWith('settings.')
                  ? Text(AppStrings.text('common.coming_soon'))
                  : null,
              onTap: () {
                switch (option.title) {
                  case 'settings.app_language':
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const AppLanguageSettingsScreen(),
                      ),
                    );
                    break;
                  case 'settings.enabled_locales':
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const EnabledLocalesSettingsScreen(),
                      ),
                    );
                    break;
                  case 'settings.help':
                    _openHelp(context);
                    break;
                  case 'drawer.reload_data':
                    _openDataOperation(
                      context,
                      operation: initializeTransitData,
                      forceRefresh: true,
                    );
                    break;
                  case 'drawer.refresh_data':
                    _openDataOperation(
                      context,
                      operation: refreshStaleProviders,
                    );
                    break;
                }
              },
            ),
        ],
      ),
    );
  }
}



Future<void> _openHelp(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  final opened = await launchUrl(_helpUrl, mode: LaunchMode.externalApplication)
      .catchError((_) => false);
  if (!opened) {
    messenger.showSnackBar(
      SnackBar(content: Text(AppStrings.text('settings.help.open_failed'))),
    );
  }
}

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


