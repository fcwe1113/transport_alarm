import 'package:flutter/material.dart';
import 'package:transport_alarm/l10n/app_languages.dart';
import 'package:transport_alarm/l10n/app_strings.dart';
import 'package:transport_alarm/transit/services/locale_selection_service.dart';
import 'package:transport_alarm/widgets/app_language_list.dart';

/// First setup step: pick the interface language before the region, so the
/// rest of setup is shown in that language.
class SetupLanguageScreen extends StatefulWidget {
  const SetupLanguageScreen({super.key});

  @override
  State<SetupLanguageScreen> createState() => _SetupLanguageScreenState();
}

class _SetupLanguageScreenState extends State<SetupLanguageScreen> {
  String? _selectedCode;
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    _loadSelection();
  }

  Future<void> _loadSelection() async {
    final code = await LocaleSelectionService().getAppLanguageCode();
    if (!mounted) return;
    setState(() => _selectedCode = code);
  }

  /// Applies [code] straight away, so this page switches language as the
  /// user picks.
  Future<void> _select(String? code) async {
    if (code == null || _applying || code == _selectedCode) return;
    setState(() {
      _selectedCode = code;
      _applying = true;
    });
    try {
      await applyAppLanguage(code);
    } catch (e) {
      // The previous language stays; the check button comes back either way.
      debugPrint("Could not apply app language $code: $e");
    } finally {
      if (mounted) setState(() => _applying = false);
    }
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
            child: Text(AppStrings.text('setup.choose_language'),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: AppLanguageList(selectedCode: _selectedCode, onChanged: _select),
          ),
        ],
      ),
      floatingActionButton: _selectedCode == null || _applying
          ? null
          : FloatingActionButton(
              onPressed: () => Navigator.pushReplacementNamed(context, "/setup"),
              child: const Icon(Icons.check),
            ),
    );
  }
}
