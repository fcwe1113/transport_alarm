import 'package:flutter/material.dart';
import 'package:transport_alarm/l10n/app_languages.dart';

/// A radio button for each interface language, as used in setup and in
/// settings.
class AppLanguageList extends StatelessWidget {
  final String? selectedCode;
  final ValueChanged<String?> onChanged;

  const AppLanguageList({super.key, required this.selectedCode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return RadioGroup<String>(
      groupValue: selectedCode,
      onChanged: onChanged,
      child: ListView(
        children: [
          for (final language in appLanguages)
            RadioListTile<String>(
              value: language.code,
              title: Text(language.name),
            ),
        ],
      ),
    );
  }
}
