import 'package:flutter/material.dart';

import '../../l10n/app_language_state.dart';
import '../../l10n/app_strings.dart';
import '../../l10n/app_languages.dart';
import '../../transit/services/locale_selection_service.dart';
import '../../widgets/app_language_list.dart';
import '../../widgets/app_shell.dart';

/// Lets the user select the app interface language and save it explicitly.
class AppLanguageSettingsScreen extends StatefulWidget {
  const AppLanguageSettingsScreen({super.key});

  @override
  State<AppLanguageSettingsScreen> createState() =>
      _AppLanguageSettingsScreenState();
}

class _AppLanguageSettingsScreenState extends State<AppLanguageSettingsScreen> {
  final _selectionService = LocaleSelectionService();
  String? _selectedCode;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadSelection();
  }

  Future<void> _loadSelection() async {
    final code = await _selectionService.getAppLanguageCode();
    if (!mounted) return;
    setState(() => _selectedCode = code);
  }

  /// Applies the picked language, then rebuilds the app from the settings
  /// page so every screen shows it.
  Future<void> _confirmSelection() async {
    final code = _selectedCode;
    if (code == null || _saving) return;

    setState(() => _saving = true);
    try {
      await applyAppLanguage(code);
    } catch (e) {
      debugPrint("Could not apply app language $code: $e");
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.text('settings.app_language.failed'))),
      );
      return;
    }
    if (mounted) {
      appNavigatorKey.currentState?.pushNamedAndRemoveUntil('/settings', (_) => false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppShell(
      title: AppStrings.text('settings.app_language'),
      selectedTab: 2,
      actions: [
        IconButton(
          tooltip: AppStrings.text('common.done'),
          onPressed: _selectedCode == null || _saving
              ? null
              : _confirmSelection,
          icon: _saving
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.check),
        ),
      ],
      // Picking only marks the language; the check button applies it.
      body: AppLanguageList(
        selectedCode: _selectedCode,
        onChanged: (code) {
          if (_saving) return;
          setState(() => _selectedCode = code);
        },
      ),
    );
  }
}