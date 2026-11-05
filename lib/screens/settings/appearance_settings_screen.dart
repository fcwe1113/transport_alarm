import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';
import '../../settings/appearance_settings.dart';
import '../../widgets/app_shell.dart';

/// Light or dark mode and the theme colour, each applied as soon as it's
/// picked.
class AppearanceSettingsScreen extends StatelessWidget {
  const AppearanceSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return AppShell(
      title: AppStrings.text('settings.appearance'),
      selectedTab: 2,
      body: ValueListenableBuilder<AppearanceSettings>(
        valueListenable: appearanceNotifier,
        builder: (context, appearance, _) => ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            _SectionTitle(AppStrings.text('settings.appearance.theme')),
            RadioGroup<ThemeMode>(
              groupValue: appearance.themeMode,
              onChanged: (mode) {
                if (mode != null) setThemeMode(mode);
              },
              child: Column(
                children: [
                  for (final (mode, key) in const [
                    (ThemeMode.system, 'settings.appearance.theme.system'),
                    (ThemeMode.light, 'settings.appearance.theme.light'),
                    (ThemeMode.dark, 'settings.appearance.theme.dark'),
                  ])
                    RadioListTile<ThemeMode>(value: mode, title: Text(AppStrings.text(key))),
                ],
              ),
            ),
            _SectionTitle(AppStrings.text('settings.appearance.colour')),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Wrap(
                spacing: 16,
                runSpacing: 16,
                children: [
                  for (final seed in themeSeeds)
                    _ColourSwatch(
                      seed: seed,
                      selected: seed.key == appearance.seedKey,
                      onTap: () => setThemeSeed(seed.key),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );
}

/// A tappable circle in the colour the theme would be built from, ticked
/// when it's the current one.
class _ColourSwatch extends StatelessWidget {
  const _ColourSwatch({required this.seed, required this.selected, required this.onTap});

  final ThemeSeed seed;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // The colour the theme actually uses, which can differ from the seed.
    final primary = ColorScheme.fromSeed(seedColor: seed.color, brightness: Theme.of(context).brightness).primary;
    return Semantics(
      button: true,
      selected: selected,
      label: AppStrings.text('settings.appearance.colour.${seed.key}'),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: primary,
            shape: BoxShape.circle,
            border: selected ? Border.all(color: Theme.of(context).colorScheme.onSurface, width: 3) : null,
          ),
          child: selected ? Icon(Icons.check, color: ThemeData.estimateBrightnessForColor(primary) == Brightness.dark ? Colors.white : Colors.black) : null,
        ),
      ),
    );
  }
}
