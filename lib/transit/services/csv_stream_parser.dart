import 'dart:convert';
import 'dart:io';

import 'package:csv/csv.dart';

Future<void> streamParseAndInsert(
  File csvFile,
  Future<void> Function(List<List<dynamic>> batch) insertBatch, {
  int batchSize = 2000,
}) async {
  final lines = csvFile
      .openRead()
      .transform(utf8.decoder)
      .transform(const LineSplitter());
  const converter = CsvDecoder();

  var batch = <List<dynamic>>[];
  var headerRead = false;

  await for (final line in lines) {
    if (line.trim().isEmpty) continue;
    final row = converter.convert(line).first;
    if (!headerRead) {
      headerRead = true;
      continue;
    }
    batch.add(row);

    if (batch.length >= batchSize) {
      await insertBatch(batch);
      batch = [];
    }
  }

  if (batch.isNotEmpty) {
    await insertBatch(batch);
  }
  if (!headerRead) {
    throw FormatException('GTFS CSV is empty: ${csvFile.path}');
  }
}
