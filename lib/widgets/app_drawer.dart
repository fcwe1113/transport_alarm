import 'package:transport_alarm/screens/loading_screen.dart';
import 'package:transport_alarm/transit_bootstrap.dart';
import 'package:flutter/material.dart';
import 'package:transport_alarm/l10n/app_strings.dart';

/// this is the actual menu object, with each menu entry
class AppDrawer extends StatelessWidget { // stateless bc the menu entrys are set
  const AppDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    return Drawer( // the built in side bar menu thing
        child: ListView( // make the menu scrollabel if needed
          padding: EdgeInsets.zero,
          children: [
            DrawerHeader(
                padding: EdgeInsets.all(30),
                decoration: BoxDecoration(color: Colors.blue),
                child: Text(AppStrings.text('drawer.title'), style: TextStyle(color: Colors.white, fontSize: 24),)),
            ListTile(leading: const Icon(Icons.alarm), title: Text(AppStrings.text('drawer.alarms')), onTap: () { // List stile describes the actual buttons on the menu
              Navigator.pop(context); // dismiss the drawer (sidebar)
              Navigator.pushReplacementNamed(context, "/"); // jump to the screen linked to the path, pushNamed() would allow flutter to stack screen on top of each other which is wasteful
            },),
            ListTile(leading: const Icon(Icons.map), title: Text(AppStrings.text('drawer.map')), onTap: () {
              Navigator.pop(context);
              Navigator.pushReplacementNamed(context, "/map");
            },),
            ListTile(leading: const Icon(Icons.download), title: Text(AppStrings.text('drawer.reload_data')), onTap: () {
              Navigator.pop(context);
              Navigator.push(context, MaterialPageRoute(builder: (context) => const LoadingScreen(operation: initializeTransitData,forceRefresh: true)));
            },),
            ListTile(leading: const Icon(Icons.refresh), title: Text(AppStrings.text('drawer.refresh_data')), onTap: () {
              Navigator.pop(context);
              Navigator.push(context, MaterialPageRoute(builder: (context) => const LoadingScreen(operation: refreshStaleProviders,)));
            },),
            ListTile(leading: const Icon(Icons.settings), title: Text(AppStrings.text('drawer.settings')), onTap: () {
              Navigator.pop(context);
              Navigator.pushReplacementNamed(context, "/settings");
            },),
          ],
        )
    );
  }
}
