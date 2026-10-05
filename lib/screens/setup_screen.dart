import 'package:timezone/timezone.dart';
import 'package:transport_alarm/locale_registry.dart';
import 'package:transport_alarm/provider_registry.dart';
import 'package:transport_alarm/l10n/app_strings.dart';
import 'package:transport_alarm/transit/locale/transit_locale.dart';
import 'package:transport_alarm/transit/services/locale_selection_service.dart';
import 'package:flutter/material.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final Set<TransitLocale> _selected = {};

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(AppStrings.text('setup.title')),
        automaticallyImplyLeading: false,
      ),
      body: Column(
        children: [
          Padding(padding: const EdgeInsets.all(16),
            child: Text(AppStrings.text('setup.choose_region'),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
              child: ListView(
                children: LocaleRegistry.getSupportedLocales().map((locale) {
                  return CheckboxListTile(
                      title: Text(locale.config.displayName),
                      value: _selected.contains(locale),
                      onChanged: (checked) {
                        setState(() {
                          checked == true ? _selected.add(locale) : _selected.remove(locale);
                        });
                      });
                }).toList(),
              ),)
        ],),
        floatingActionButton: _selected.isEmpty ? null : FloatingActionButton(onPressed: _confirmSelection, child: const Icon(Icons.check),),
    );
  }

  Future<void> _confirmSelection() async {
    final shouldProceed = await _showWifiReminder();
    if (shouldProceed != true) return; // user clicked no on the popup

    await LocaleSelectionService().setEnabledLocales(_selected.map((l) => l.config.displayName).toList());
    if (mounted) Navigator.pushReplacementNamed(context, "/loading");
  }

  Future<bool?> _showWifiReminder() {
    return showDialog(context: context, barrierDismissible: false, builder: (context) => AlertDialog(
      title: Text(AppStrings.text('setup.heads_up')),
      content: Text(AppStrings.text('setup.download_warning')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(AppStrings.text('common.go_back'))),
        TextButton(onPressed: () => Navigator.pop(context, true), child: Text(AppStrings.text('common.continue'))),
      ],
    ));
  }
}
