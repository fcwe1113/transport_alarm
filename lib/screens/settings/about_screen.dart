import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';
import '../../widgets/app_shell.dart';
import '../../widgets/external_link.dart';

/// What the app is, where its transit data comes from, and the licences
/// that data and the app's packages are used under.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  /// Each data source's credit, with a link to the terms it's used under.
  static final _sourceCode = Uri.parse('https://github.com/fcwe1113/transport_alarm');

  static final _sources = <({String title, String body, Uri terms})>[
    (
      title: 'about.source.hk.title',
      body: 'about.source.hk.body',
      terms: Uri.parse('https://data.gov.hk/en/terms-and-conditions'),
    ),
    (
      title: 'about.source.bods.title',
      body: 'about.source.bods.body',
      terms: Uri.parse('https://www.nationalarchives.gov.uk/doc/open-government-licence/version/3/'),
    ),
    (
      title: 'about.source.tfl.title',
      body: 'about.source.tfl.body',
      terms: Uri.parse('https://tfl.gov.uk/corporate/terms-and-conditions/transport-data-service'),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppShell(
      title: AppStrings.text('settings.about'),
      selectedTab: 2,
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(AppStrings.text('app.title'), style: theme.textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(AppStrings.text('about.description')),
                const SizedBox(height: 8),
                Text(
                  AppStrings.text('about.disclaimer'),
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              AppStrings.text('about.data_sources'),
              style: theme.textTheme.titleSmall,
            ),
          ),
          for (final source in _sources)
            ListTile(
              title: Text(AppStrings.text(source.title)),
              subtitle: Text(AppStrings.text(source.body)),
              trailing: const Icon(Icons.open_in_new),
              onTap: () => openExternalLink(context, source.terms),
            ),
          const Divider(),
          // AGPL-3.0's notices: copyright, no warranty, the licence, and
          // where the source is.
          ListTile(
            leading: const Icon(Icons.code),
            title: Text(AppStrings.text('about.source_code')),
            subtitle: Text(AppStrings.text('about.app_licence')),
            trailing: const Icon(Icons.open_in_new),
            onTap: () => openExternalLink(context, _sourceCode),
          ),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: Text(AppStrings.text('about.licences')),
            onTap: () => showLicensePage(
              context: context,
              applicationName: AppStrings.text('app.title'),
            ),
          ),
        ],
      ),
    );
  }
}
