import 'package:flutter/material.dart';
import 'package:transport_alarm/l10n/app_strings.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens [url] in the browser, showing a snackbar if it can't.
Future<void> openExternalLink(BuildContext context, Uri url) async {
  final messenger = ScaffoldMessenger.of(context);
  final opened = await launchUrl(url, mode: LaunchMode.externalApplication)
      .catchError((_) => false);
  if (!opened) {
    messenger.showSnackBar(
      SnackBar(content: Text(AppStrings.text('common.link_open_failed'))),
    );
  }
}
