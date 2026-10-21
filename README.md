# Transport Alarm

An app that notifies you about your mode of transport arriving

## Introduction

This app utilizes the publicly available APIs to tell you exactly when is your ride arriving, it works like an alarm with a time range where the app will try to find your route number and tell you exactly when you should get going in order to catch that bus that you always miss.

- Directly consults the transport API of your locale to fetch the most up to date arrival times
- Builds the transport data on your phone directly to limit server requests to a minimum
- No ads or entry fees
- Open-source, link to the source code below
- Error tolerant, with fallback to scheduled times when live data is unavailable

This app is available on both iOS and Android (pending store review), consult the version specific READMEs for more information([iOS](https://github.com/fcwe1113/transport_alarm/blob/master/ios/README.md), [Android](https://github.com/fcwe1113/transport_alarm/blob/master/android/README.md))

## Obvious question: Whats this app different from Citymapper/Google Maps(or the transit app of your choice)

This app does not help you find the best way to get from A to B, what it however does is to remind you when is your ride coming, which none of the current transit apps does.
### What this app is:
- A reminder app for you to not miss your ride
- A centralized way to see estimated arrival times of public transport
### What this app isn't:
- A pathfinder
- A place to see real time disruption information, consult other apps or your transport department in this case

## Supported locales

- Hong Kong (KMB, CTB)
- UK (Busses on Great Britain, with spotty support for Scotland and Wales, Northern Ireland support coming soon)

## Currently supported display languages

- English
- Chinese (Traditional/Simplified)
- Spanish (Partial, credit to my friend [Sebastian](https://github.com/Pomalec) for translating for free :3)

Feel free to provide translations if you know how to by providing a translated copy of the [english localization strings list](https://github.com/fcwe1113/transport_alarm/blob/master/assets/localization/strings_en.json)

## Current roadmap

- Publish the app onto App store and Play store
- fill in locale support holes for currently supported regions (hk: new lantau bus, minibuses, uk: better Scotland and Wales support)
- add support for trains and trams (hk: MTR, gb: national rail, sheffield/manchester/birmingham/london trams and Glasgow/Newcastle/London underground)
- add northern ireland support for uk
- add new locale support (Taiwan, Germany, Netherlands, Japan, Singapore, France, Spain, etc)

As this is an early release, expect bugs and errors. I had tried to weed out all potential crashes but if there's any please report them on the repository

## Donations

This app does have running costs, if you liked the app, please buy me a cup of tea on [kofi](https://ko-fi.com/fcwe1113)

## License
This entire project, both client and server side code, is licensed under the GNU Affero General Public License v3.0 — see [LICENSE](LICENSE) for details.
