import 'package:flutter/material.dart';
import 'package:transport_alarm/l10n/app_strings.dart';
import 'package:transport_alarm/l10n/app_language_state.dart';
import 'package:transport_alarm/services/app_group_storage.dart';
import 'package:transport_alarm/transit/services/locale_selection_service.dart';
import 'package:transport_alarm/widgets/app_shell.dart';

/// Settings landing page; language selection is implemented as a child page.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final options = <({IconData icon, String title})>[
      (
        icon: Icons.language,
        title: 'settings.app_language',
      ),
      (
        icon: Icons.public,
        title: 'settings.transit_locale',
      ),
      (
        icon: Icons.access_time,
        title: 'settings.time_zone',
      ),
      (
        icon: Icons.notifications_outlined,
        title: 'settings.notifications',
      ),
      (
        icon: Icons.info_outline,
        title: 'settings.about',
      ),
    ];

    return AppShell(
      title: AppStrings.text('settings.title'),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          for (final option in options)
            ListTile(
              leading: Icon(option.icon),
              title: Text(AppStrings.text(option.title)),
              subtitle: Text(AppStrings.text(
                option.title == 'settings.app_language'
                    ? 'settings.app_language.subtitle'
                    : 'common.coming_soon',
              )),
              onTap: option.title == 'settings.app_language'
                  ? () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const AppLanguageSettingsScreen(),
                        ),
                      )
                  : null,
            ),
        ],
      ),
    );
  }
}

/// Lets the user select the app interface language and save it explicitly.
class AppLanguageSettingsScreen extends StatefulWidget {
  const AppLanguageSettingsScreen({super.key});

  @override
  State<AppLanguageSettingsScreen> createState() =>
      _AppLanguageSettingsScreenState();
}

class _AppLanguageSettingsScreenState extends State<AppLanguageSettingsScreen> {
  static const _languages = <({String code, String labelKey})>[
    (code: 'en', labelKey: 'settings.language.en'),
    (code: 'zh-Hant', labelKey: 'settings.language.zh_hant'),
    (code: 'zh-Hans', labelKey: 'settings.language.zh_hans'),
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
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AppShell(
      title: AppStrings.text('settings.app_language'),
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
      body: ListView(
        children: [
          for (final language in _languages)
            RadioListTile<String>(
              value: language.code,
              groupValue: _selectedCode,
              title: Text(AppStrings.text(language.labelKey)),
              onChanged: _saving
                  ? null
                  : (code) => setState(() => _selectedCode = code),
            ),
        ],
      ),
    );
  }
}
