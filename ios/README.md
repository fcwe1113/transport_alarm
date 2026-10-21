# iOS specific information
This page is dedicated to documenting the various things iOS users should know when using the app, if you need the android version instead click [here](https://github.com/fcwe1113/transport_alarm/blob/master/android/README.md)
## Requirements to ensure the app functions
Due to system differences, iOS has a different set of requirements than Android for the alarm to function, you may also notice the "alarm" you see on iOS is just a slightly more annoying notification, this will be explained in a bit. This list of requirements can be seen below:
- Stable internet connection is needed for the alarm to ring at all, as a remote server is used to poke the phone into doing things in regular intervals
- Permissions to send notifications given by you
- Specific exemptions provided the alarm is supposed to ring while the phone is in a focus mode (e.g. sleep, DND)
- Permission for the app to send time-sensitive notifications, this is what make the notifications "slightly more annoying"
- Your device has to stay on while the alarm is supposed to ring (duh)
## Caveats with app functionality
In addition to the requirements above, there are a few caveats one should know when using the app:
- The app cannot override silent mode, so the sound it normally makes when the alarm rings won't be here if the alarm is ringing when silent mode is turned on, only the vibration and the notification persists
- Sometimes the app will show a notification saying "Alarm checks stopped", please follow the second half of that sentence and open the app, all alarms will stop ringing until you do so
- In iOS the alarm works in coarse minutes, this is due to resctictions from iOS itself and I cannot solve it without setting up an enterprise level dedicated server
## Required settings to ensure app functionality
### General checks
If your app is not functioning for reasons beside bad internet connectivity and caveat number 2 above, check the list of places below before you log a bug report (images accurate per iOS 27.0.1):

![ios guide.png](ios%20guide.png)

Make sure that the toggles circled in orange are all enabled.
### Focus mode settings
Check the settings shown below if your alarm is to ring while a focus mode is on:

![ios focus guide.png](ios%20focus%20guide.png)

Note that you will need to enable the app in each focus mode individually

## FAQ
### Why can't iOS do it like android showing a live progress bar outside the app showing you how far away is the bus/train/tram currently?
While iOS Live Activity can do something similar, due to iOS restrictions triggering the update process has to live off device and triggered by a remote server. With the current model which is less demanding on the server, I will have to start paying my server provider (cloudflare) by the time there are ~2500 iOS users by my current estimates, and I do not plan to charge people for using the app or to show ads. If you want to either keep the app free or me going bankrupt, feel free to donate to me on [kofi](https://ko-fi.com/fcwe1113) :3
### Sometimes my alarm rings some time before or after the threshold its supposed to ring?
Due to iOS restrictions and restrictions from my wallet, the server can only process notifications once per minute, within the app I had made optimizations to hopefully turn the potential delays into potential early triggers (if you are into video game speedrunning: Imagine a bus), however as the app is polling the live arrival APIs in real time when the notification arrives at your phone, sometimes delays happen if the fetch and/or parse process takes too long.
### Why no AlarmKit?
coming soon :)))))))))))))))))))
