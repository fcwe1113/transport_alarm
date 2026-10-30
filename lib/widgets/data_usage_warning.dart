import 'package:flutter/material.dart';
import 'package:transport_alarm/l10n/app_strings.dart';
import 'package:transport_alarm/locale_registry.dart';

/// Warns that downloading transit data can take a while and use a lot of
/// data, adding each region's note when its value in [selection] makes for a
/// large download. Resolves to true only when the user chooses to continue.
Future<bool> showDataUsageWarning(
  BuildContext context, {
  Map<String, String> selection = const {},
}) async {
  final notes = [
    for (final entry in selection.entries)
      ?LocaleRegistry.getLocale(entry.key).largeDownloadWarning(entry.value),
  ];
  final proceed = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: Text(AppStrings.text('setup.heads_up')),
      content: Text([AppStrings.text('setup.download_warning'), ...notes].join('\n\n')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(AppStrings.text('common.go_back'))),
        TextButton(onPressed: () => Navigator.pop(context, true), child: Text(AppStrings.text('common.continue'))),
      ],
    ),
  );
  return proceed == true;
}
