import 'dart:convert';
import 'dart:io';

import 'package:csv/csv.dart';
import 'package:transport_alarm/transit/cancellation.dart';

const _linesPerReport = 10000;

/// Counts the data rows in [csvFile] (every line after the header) by
/// scanning for line breaks, without decoding the file.
Future<int> countCsvDataLines(
  File csvFile, {
  CancellationToken? cancelToken,
}) async {
  var lineBreaks = 0;
  var endsWithLineBreak = true;
  await for (final chunk in csvFile.openRead()) {
    cancelToken?.throwIfCancelled();
    for (final byte in chunk) {
      if (byte == 0x0A) lineBreaks++;
    }
    if (chunk.isNotEmpty) endsWithLineBreak = chunk.last == 0x0A;
  }
  final lines = endsWithLineBreak ? lineBreaks : lineBreaks + 1;
  return lines > 0 ? lines - 1 : 0;
}

Future<void> streamParseAndInsert(
  File csvFile,
  Future<void> Function(List<List<dynamic>> batch) insertBatch, {
  int batchSize = 2000,
  bool Function(List<dynamic> header, List<dynamic> row)? filter,
  Future<List<List<dynamic>>> Function(
    List<dynamic> header,
    List<List<dynamic>> batch,
  )?
  filterBatch,
  List<dynamic> Function(List<dynamic> header, List<dynamic> row)? transformRow,
  CancellationToken? cancelToken,
  void Function(int linesRead)? onLinesRead,
}) => _streamParseAndInsert(
  csvFile,
  (header, batch) => insertBatch(batch),
  batchSize: batchSize,
  filter: filter,
  filterBatch: filterBatch,
  transformRow: transformRow,
  cancelToken: cancelToken,
  onLinesRead: onLinesRead,
);

Future<void> streamParseAndInsertWithHeader(
  File csvFile,
  Future<void> Function(List<dynamic> header, List<List<dynamic>> batch)
  insertBatch, {
  int batchSize = 2000,
  bool Function(List<dynamic> header, List<dynamic> row)? filter,
  Future<List<List<dynamic>>> Function(
    List<dynamic> header,
    List<List<dynamic>> batch,
  )?
  filterBatch,
  List<dynamic> Function(List<dynamic> header, List<dynamic> row)? transformRow,
  CancellationToken? cancelToken,
  void Function(int linesRead)? onLinesRead,
}) => _streamParseAndInsert(
  csvFile,
  insertBatch,
  batchSize: batchSize,
  filter: filter,
  filterBatch: filterBatch,
  transformRow: transformRow,
  cancelToken: cancelToken,
  onLinesRead: onLinesRead,
);

Future<void> _streamParseAndInsert(
  File csvFile,
  Future<void> Function(List<dynamic> header, List<List<dynamic>> batch)
  insertBatch, {
  required int batchSize,
  required bool Function(List<dynamic> header, List<dynamic> row)? filter,
  required Future<List<List<dynamic>>> Function(
    List<dynamic> header,
    List<List<dynamic>> batch,
  )?
  filterBatch,
  required List<dynamic> Function(List<dynamic> header, List<dynamic> row)?
  transformRow,
  CancellationToken? cancelToken,
  void Function(int linesRead)? onLinesRead,
}) async {
  final lines = csvFile
      .openRead()
      .transform(utf8.decoder)
      .transform(const LineSplitter());
  const converter = CsvDecoder();

  var batch = <List<dynamic>>[];
  List<dynamic>? header;
  var headerRead = false;
  var linesRead = 0;

  Future<void> flushBatch() async {
    cancelToken?.throwIfCancelled();
    if (batch.isEmpty) return;
    final rows = filterBatch == null
        ? batch
        : await filterBatch(header!, batch);
    if (rows.isNotEmpty) await insertBatch(header!, rows);
    batch = <List<dynamic>>[];
  }

  await for (final line in lines) {
    if (line.trim().isEmpty) continue;
    // GTFS rows rarely contain quotes; split those directly, which gives the
    // same fields as the CSV decoder (it returns strings) at a fraction of
    // the cost, and only decode quoted lines.
    final row = line.contains('"') ? converter.convert(line).first : line.split(',');
    if (!headerRead) {
      headerRead = true;
      header = row;
      continue;
    }
    // Counts every data row read, including ones the filter drops.
    linesRead++;
    if (onLinesRead != null && linesRead % _linesPerReport == 0) {
      onLinesRead(linesRead);
    }
    if (filter != null && !filter(header!, row)) continue;
    batch.add(transformRow == null ? row : transformRow(header!, row));

    if (batch.length >= batchSize) {
      await flushBatch();
    }
  }

  await flushBatch();
  onLinesRead?.call(linesRead);
  if (!headerRead) {
    throw FormatException('GTFS CSV is empty: ${csvFile.path}');
  }
}
