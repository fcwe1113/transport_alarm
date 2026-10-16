import 'package:flutter/material.dart';
import 'package:transport_alarm/l10n/app_strings.dart';
import 'package:transport_alarm/screens/settings/app_language_settings_screen.dart';
import 'package:transport_alarm/screens/settings/enabled_locale_settings_screen.dart';
import 'package:transport_alarm/screens/loading_screen.dart';
import 'package:transport_alarm/transit/progress_callback.dart';
import 'package:transport_alarm/transit_bootstrap.dart';
import 'package:transport_alarm/widgets/app_shell.dart';

/// Settings landing page; language selection is implemented as a child page.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final options = <({IconData icon, String title})>[
      (icon: Icons.language, title: 'settings.app_language'),
      (icon: Icons.public, title: 'settings.enabled_locales'),
      (icon: Icons.public, title: 'settings.transit_locale'),
      (icon: Icons.access_time, title: 'settings.time_zone'),
      (icon: Icons.notifications_outlined, title: 'settings.notifications'),
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



Future<void> _openDataOperation(
  BuildContext context, {
  required TransitOperation operation,
  bool forceRefresh = false,
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => LoadingScreen(
        operation: operation,
        forceRefresh: forceRefresh,
        returnToPrevious: true,
        showBottomNavigation: true,
      ),
    ),
  );
}


