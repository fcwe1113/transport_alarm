import 'package:flutter/material.dart';
import 'package:transport_alarm/l10n/app_strings.dart';

/// Shared app layout with persistent navigation for the three main sections.
class AppShell extends StatelessWidget {
  final String title;
  final Widget body;
  final List<Widget>? actions;
  final int? selectedTab;
  final bool showBottomNavigation;

  const AppShell({
    super.key,
    required this.title,
    required this.body,
    this.actions,
    this.selectedTab,
    this.showBottomNavigation = true,
  });

  @override
  Widget build(BuildContext context) {
    final currentRoute = ModalRoute.of(context)?.settings.name;
    final currentTab = selectedTab ?? switch (currentRoute) {
      '/map' => 1,
      '/settings' => 2,
      _ => 0,
    };
    const destinations = ['/', '/map', '/settings'];

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: actions,
      ),
      body: body,
      bottomNavigationBar: showBottomNavigation
          ? BottomNavigationBar(
              type: BottomNavigationBarType.fixed,
              currentIndex: currentTab,
              onTap: (index) {
                final destination = destinations[index];
                if (currentRoute == destination) return;
                Navigator.of(context).pushNamedAndRemoveUntil(
                  destination,
                  (_) => false,
                );
              },
              items: [
                BottomNavigationBarItem(
                  icon: const Icon(Icons.alarm),
                  label: AppStrings.text('drawer.alarms'),
                ),
                BottomNavigationBarItem(
                  icon: const Icon(Icons.map),
                  label: AppStrings.text('drawer.map'),
                ),
                BottomNavigationBarItem(
                  icon: const Icon(Icons.settings),
                  label: AppStrings.text('drawer.settings'),
                ),
              ],
            )
          : null,
    );
  }
}
