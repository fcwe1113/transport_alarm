import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:transport_alarm/l10n/app_strings.dart';
import 'package:transport_alarm/transit/progress_callback.dart';
import 'package:transport_alarm/transit/services/api_caller.dart';

/// Writes [response]'s body to [file], reporting how much of [fileName] has
/// downloaded. The bar fills when the server sends the size; otherwise it
/// stays indeterminate and only the amount so far is shown.
Future<void> downloadToFile(
  http.StreamedResponse response,
  File file, {
  required String fileName,
  ProgressCallback? onProgress,
}) async {
  final total = response.contentLength;
  final sink = file.openWrite();
  var received = 0;
  var lastReported = -1;

  void report() {
    if (total != null && total > 0) {
      onProgress?.call(
        AppStrings.text('transit.downloading', {
          'file': fileName,
          'done': _megabytes(received),
          'total': _megabytes(total),
        }),
        received / total,
      );
    } else {
      onProgress?.call(
        AppStrings.text('transit.downloading_unknown_size', {
          'file': fileName,
          'done': _megabytes(received),
        }),
        null,
      );
    }
  }

  try {
    report();
    await for (final chunk
        in response.stream.timeout(ApiCaller.requestTimeout)) {
      sink.add(chunk);
      received += chunk.length;
      // Report every tenth of a megabyte rather than every chunk.
      final step = received ~/ (100 * 1024);
      if (step != lastReported) {
        lastReported = step;
        report();
      }
    }
    report();
  } finally {
    await sink.close();
  }
}

String _megabytes(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);
