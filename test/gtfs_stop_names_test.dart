import 'package:flutter_test/flutter_test.dart';
import 'package:transport_alarm/transit/models/gtfs_stop.dart';

void main() {
  group('extractNameFragments', () {
    test('splits on |, <BR> and /, dropping [..] tags and repeats', () {
      expect(
        GtfsStop.extractNameFragments('[KMB] Nathan Road | [CTB] Nathan Road<br>Mong Kok/Argyle Street'),
        ['Nathan Road', 'Mong Kok', 'Argyle Street'],
      );
    });

    test('drops empty parts', () {
      expect(GtfsStop.extractNameFragments(' | Central | '), ['Central']);
    });
  });

  group('cleanStopName', () {
    test('keeps the longest fragment', () {
      expect(GtfsStop.cleanStopName('Star Ferry | Star Ferry Pier, Tsim Sha Tsui'), 'Star Ferry Pier, Tsim Sha Tsui');
    });

    test('keeps the raw name when there are no fragments', () {
      expect(GtfsStop.cleanStopName(' | '), ' | ');
    });
  });

  test('normalizeForMatching keeps upper-case letters and digits only', () {
    expect(GtfsStop.normalizeForMatching("St. Mary's Rd (Stop 2)"), 'STMARYSRDSTOP2');
  });

  group('localizedNameFromOperators', () {
    test('uses the longest name in the language', () {
      final name = GtfsStop.localizedNameFromOperators(
        [
          {'en': 'Central', 'zh-Hant': '中環'},
          {'en': 'Central (Exchange Square)', 'zh-Hant': '中環（交易廣場）'},
        ],
        'zh-Hant',
        fallbackName: 'fallback',
      );
      expect(name, '中環（交易廣場）');
    });

    test('falls back to English, then to the fallback name', () {
      expect(
        GtfsStop.localizedNameFromOperators([{'en': 'Admiralty'}], 'ja', fallbackName: 'fallback'),
        'Admiralty',
      );
      expect(
        GtfsStop.localizedNameFromOperators([{'en': '  '}], 'en', fallbackName: 'fallback'),
        'fallback',
      );
    });
  });
}
