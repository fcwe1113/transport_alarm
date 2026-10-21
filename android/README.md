# Android specific information
This page is dedicated to documenting the various things Android users should know when using the app, if you need the iOS version instead click [here](https://github.com/fcwe1113/transport_alarm/blob/master/ios/README.md)
## Requirements to ensure the app functions
Due to system differences, Android has a different set of requirements than iOS for the alarm to function, list of requirements can be seen below:
- Stable internet connection is required for grabbing live arrivals, if it isn't available then scheduled times will be used instead if there is one saved in the database
- Permissions to send notifications and to set alarms given by you
- Your device has to stay on while the alarm is supposed to ring (duh)
## Caveats with app functionality
In addition to the requirements above, there are a few caveats one should know when using the app:
- App behaves differently when ran on an Android version below 16, consult the table below for details
- Depending on your phone's manufacturer, extra steps may be needed on the user to ensure the app wasn't killed by the phone's battery optimization settings, see [dontkillmyapp.com](dontkillmyapp.com) for specific settings for your particular phone
- Force Stop (that is sliding the app up in the multitasker to kill it) cancels all pending alarms until you open the app again
- Alarms will not ring if you restart the phone until you unlock it for the first time post restart
- While the app schedules "mandatory" arrival updates when the alarm has less than 5 minutes till ring, all arrival updates before then can be delayed when Doze is enabled
- The full screen alarm popup only shows when locked or if the phone's screen is off, otherwise only a normal notification will show
- Turning off "Alarms & Reminders" would immediately disable all pending alarms, users would be asked again for permission when opening the app again
- If user restricts background data for the app, alarms would defer back to locally available schedules as live APIs would not be reachable, and live only alarms would fail
- Alarms would stop ringing when the alarm's active window ends
## Functionality differences over different Android versions
There are other minor behavioral differences but the main ones are listed below:

| Feature                        | Version | On older versions                                                                        |
|--------------------------------|---------|------------------------------------------------------------------------------------------|
| Notification permission prompt | 13      | Permission granted automatically                                                         |
| “Alarms & reminders” access    | 12      | Permission granted automatically                                                         |
| Full-screen alert permission   | 14      | Permission granted automatically                                                         |
| Live Update progress bar       | 16      | The rest of the notification, including the countdown will show without the progress bar |

Additionally, on Android 17 users can disable the app's access local network devices, it is safe to do so as the app does not call any local network devices. 
## Required settings to ensure app functionality
Please consult [dontkillmyapp.com](dontkillmyapp.com) for any manufacturer specific settings, below will show any android wide settings to ensure app functionality (taken on an emulated Pixel 9 running Android 17):
### Required settings
Notification permissions:

![android notifs guide.png](android%20notifs%20guide.png)

Note that Alarm Problems/Updates can be disabled without impacting alarm functionality, but may make troubleshooting harder

Mobile data/Battery Optimizations:

![android data_battery guide.png](android%20data_battery%20guide.png)

Full screen alert permissions:

![android full_screen guide.png](android%20full_screen%20guide.png)

Live updates can also be disabled if you want to disable the progress bar tracker
## FAQ
WIP