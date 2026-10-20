import 'package:transport_alarm/locale_registry.dart';
import 'package:transport_alarm/l10n/app_strings.dart';
import 'package:transport_alarm/transit/services/locale_selection_service.dart';
import 'package:transport_alarm/widgets/data_usage_warning.dart';
import 'package:flutter/material.dart';

/// Second setup step: pick the regions whose transit data to download, then
/// start the first data build.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _selectionService = LocaleSelectionService();
  // Regions are picked into a draft, which only becomes the enabled
  // selection once confirmed.
  late final Future<Map<String, String>> _draftReady;
  final _locales = LocaleRegistry.getSupportedLocales()..sort();

  @override
  void initState() {
    super.initState();
    _draftReady = _selectionService.beginLocaleSelectionDraft();
  }

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
            child: FutureBuilder<Map<String, String>>(
              future: _draftReady,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Center(child: Text(snapshot.error.toString()));
                }
                return ListView(
                  children: [for (final locale in _locales) locale.menuEntry],
                );
              },
            ),
          ),
        ],
      ),
      // Shown once at least one region is picked.
      floatingActionButton: ValueListenableBuilder<Map<String, String>>(
        valueListenable: LocaleSelectionService.localeSelectionDraftListenable,
        builder: (context, draft, _) => draft.isEmpty
            ? const SizedBox.shrink()
            : FloatingActionButton(
                onPressed: _confirmSelection,
                child: const Icon(Icons.check),
              ),
      ),
    );
  }

  /// Saves the picked regions and starts the first build. Setup stays
  /// incomplete until that build succeeds.
  Future<void> _confirmSelection() async {
    if (!await showDataUsageWarning(context)) return;

    await _selectionService.setSetupCompleted(false);
    await _selectionService.commitLocaleSelectionDraft();
    if (mounted) Navigator.pushReplacementNamed(context, "/loading");
  }
}
