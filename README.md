# Transport Alarm

An app that notifies you about your bus arriving

## Getting Started

This app utilizes the publicly available APIs to tell you exactly when is your ride arriving, it works like an alarm with a time range where the app will try to find your route number and tell you exactly when you should get going in order to catch that bus that you always miss.

- Directly consults the transport API of your locale to fetch the most up to date arrival times
- Builds the transport data on your phone directly to limit server requests to a minimum
- No ads or entry fees
- Open-source, link to the source code below
- Error tolerant, with fallback to scheduled times when live data is unavailable

Due to the nature of the app, a stable internet connection is needed at all times, there are other caveats while using the app as well, please consult https://github.com/fcwe1113/transport_alarm/blob/master/ios/README.md for more details

Currently supported locales:

- Hong Kong (KMB, CTB)
- UK (Busses on Great Britain, with spotty support for Scotland and Wales, Northern Ireland support coming soon)

Currently supported display languages:

- English
- Chinese (Traditional/Simplified)
- Spanish (Partial, credit to my friend Sebastian for translating for free :3)

As this is an early release, expect bugs and errors. I had tried to weed out all potential crashes but if there's any please report them on the repository

## License
This entire project, both client and server side code, is licensed under the GNU Affero General Public License v3.0 — see [LICENSE](LICENSE) for details.