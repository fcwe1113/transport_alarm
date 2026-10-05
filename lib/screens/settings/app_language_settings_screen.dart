import 'package:flutter/material.dart';

import '../../l10n/app_language_state.dart';
import '../../l10n/app_strings.dart';
import '../../services/app_group_storage.dart';
import '../../transit/services/locale_selection_service.dart';
import '../../widgets/app_shell.dart';

/// Lets the user select the app interface language and save it explicitly.
class AppLanguageSettingsScreen extends StatefulWidget {
  const AppLanguageSettingsScreen({super.key});

  @override
  State<AppLanguageSettingsScreen> createState() =>
      _AppLanguageSettingsScreenState();
}

class _AppLanguageSettingsScreenState extends State<AppLanguageSettingsScreen> {
  static const _languages = <({String code, String name})>[
    (code: 'en', name: "English"),
    (code: 'zh-Hant', name: "正體中文"),
    (code: 'zh-Hans', name: "简体中文"),
    (code: 'ja', name: "日本語"),
    (code: 'fr', name: "Français"),
    (code: 'es', name: "Español"),
    (code: 'de', name: "Deutsch"),
    (code: 'nl', name: "Nederlands"),
    (code: 'it', name: "Italiano"),
    (code: 'pl', name: "Polski"),
    (code: 'ko', name: "한국어"),
    (code: 'uk', name: "Українська"),
  ];

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

  Future<void> _confirmSelection() async {
    final code = _selectedCode;
    if (code == null || _saving) return;

    setState(() => _saving = true);
    await _selectionService.setAppLanguageCode(code);
    await AppStrings.load(code);
    await AppGroupStorage.setAppLanguageCode(code);
    appLanguageCodeNotifier.value = code;
    if (mounted) {
      appNavigatorKey.currentState?.pushNamedAndRemoveUntil(
        '/settings',
            (_) => false,
      );
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
      body: RadioGroup<String>(
        groupValue: _selectedCode,
        onChanged: (code) {
          if (_saving) return;
          setState(() => _selectedCode = code);
        },
        child: ListView(
          children: [
            for (final language in _languages)
              RadioListTile<String>(
                value: language.code,
                title: Text(language.name),
              ),
          ],
        ),
      ),
    );
  }
}