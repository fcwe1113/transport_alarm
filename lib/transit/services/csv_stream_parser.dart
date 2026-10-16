import 'dart:convert';
import 'dart:io';

import 'package:csv/csv.dart';

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
}) => _streamParseAndInsert(
  csvFile,
  (header, batch) => insertBatch(batch),
  batchSize: batchSize,
  filter: filter,
  filterBatch: filterBatch,
  transformRow: transformRow,
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
}) => _streamParseAndInsert(
  csvFile,
  insertBatch,
  batchSize: batchSize,
  filter: filter,
  filterBatch: filterBatch,
  transformRow: transformRow,
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
}) async {
  final lines = csvFile
      .openRead()
      .transform(utf8.decoder)
      .transform(const LineSplitter());
  const converter = CsvDecoder();

  var batch = <List<dynamic>>[];
  List<dynamic>? header;
  var headerRead = false;

  Future<void> flushBatch() async {
    if (batch.isEmpty) return;
    final rows = filterBatch == null
        ? batch
        : await filterBatch(header!, batch);
    if (rows.isNotEmpty) await insertBatch(header!, rows);
    batch = <List<dynamic>>[];
  }

  await for (final line in lines) {
    if (line.trim().isEmpty) continue;
    final row = converter.convert(line).first;
    if (!headerRead) {
      headerRead = true;
      header = row;
      continue;
    }
    if (filter != null && !filter(header!, row)) continue;
    batch.add(transformRow == null ? row : transformRow(header!, row));

    if (batch.length >= batchSize) {
      await flushBatch();
    }
  }

  await flushBatch();
  if (!headerRead) {
    throw FormatException('GTFS CSV is empty: ${csvFile.path}');
  }
}
