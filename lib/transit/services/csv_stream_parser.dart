import 'dart:convert';
import 'dart:io';

import 'package:csv/csv.dart';

Future<void> streamParseAndInsert(
  File csvFile,
  Future<void> Function(List<List<dynamic>> batch) insertBatch, {
  required List<String> columns,
  Set<String> optionalColumns = const {},
  bool Function(List<dynamic> row)? includeRow,
  void Function(List<dynamic> row)? onIncludedRow,
  int batchSize = 2000,
}) async {
  final lines = csvFile
      .openRead()
      .transform(utf8.decoder)
      .transform(const LineSplitter());
  const converter = CsvDecoder();

  var batch = <List<dynamic>>[];
  Map<String, int>? columnIndexes;

  await for (final line in lines) {
    if (line.trim().isEmpty) continue;
    final row = converter.convert(line).first;
    if (columnIndexes == null) {
      final header = row.map((value) => value.toString().trim()).toList();
      if (header.isNotEmpty) header[0] = header[0].replaceFirst('\uFEFF', '');
      columnIndexes = {
        for (var index = 0; index < header.length; index++)
          header[index]: index,
      };
      final missing = columns.where(
        (column) =>
            !optionalColumns.contains(column) &&
            !columnIndexes!.containsKey(column),
      );
      if (missing.isNotEmpty) {
        throw FormatException(
          'GTFS CSV ${csvFile.path} is missing columns: ${missing.join(', ')}',
        );
      }
      continue;
    }
    final values = row;
    final normalized = columns.map((column) {
      final index = columnIndexes![column];
      return index == null ? '' : values[index];
    }).toList();
    if (includeRow == null || includeRow(normalized)) {
      onIncludedRow?.call(normalized);
      batch.add(normalized);
    }

    if (batch.length >= batchSize) {
      await insertBatch(batch);
      batch = [];
    }
  }

  if (batch.isNotEmpty) {
    await insertBatch(batch);
  }
  if (columnIndexes == null) {
    throw FormatException('GTFS CSV is empty: ${csvFile.path}');
  }
}
