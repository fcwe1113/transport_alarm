import 'package:flutter/material.dart';
import 'package:transport_alarm/l10n/app_strings.dart';

/// Warns that downloading transit data can take a while and use a lot of
/// data. Resolves to true only when the user chooses to continue.
Future<bool> showDataUsageWarning(BuildContext context) async {
  final proceed = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: Text(AppStrings.text('setup.heads_up')),
      content: Text(AppStrings.text('setup.download_warning')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(AppStrings.text('common.go_back'))),
        TextButton(onPressed: () => Navigator.pop(context, true), child: Text(AppStrings.text('common.continue'))),
      ],
    ),
  );
  return proceed == true;
}
