import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:transport_alarm/transit/cancellation.dart';
import 'package:transport_alarm/transit/services/csv_stream_parser.dart';

void main() {
  late Directory directory;

  setUp(() async => directory = await Directory.systemTemp.createTemp('csv_test_'));
  tearDown(() async => directory.delete(recursive: true));

  Future<File> csv(String contents) async {
    final file = File('${directory.path}/data.txt');
    await file.writeAsString(contents);
    return file;
  }

  Future<({List<dynamic>? header, List<List<dynamic>> batches})> parse(
    File file, {
    int batchSize = 2000,
    CsvRowFilter? filter,
    CsvRowTransform? transformRow,
    CsvBatchFilter? filterBatch,
  }) async {
    List<dynamic>? header;
    final batches = <List<dynamic>>[];
    await streamParseAndInsertWithHeader(
      file,
      (h, batch) async {
        header = h;
        batches.add(batch);
      },
      batchSize: batchSize,
      filter: filter,
      transformRow: transformRow,
      filterBatch: filterBatch,
    );
    return (header: header, batches: batches.cast<List<dynamic>>());
  }

  test('passes rows in batches, with the header', () async {
    final file = await csv('stop_id,stop_name\n1,A\n2,B\n3,C\n');
    final result = await parse(file, batchSize: 2);
    expect(result.header, ['stop_id', 'stop_name']);
    expect(result.batches, [
      [['1', 'A'], ['2', 'B']],
      [['3', 'C']],
    ]);
  });

  test('drops a byte-order mark, so the first column keeps its name', () async {
    final file = await csv('﻿stop_id,stop_name\n1,A\n');
    expect((await parse(file)).header, ['stop_id', 'stop_name']);
  });

  test('decodes quoted fields with commas', () async {
    final file = await csv('stop_id,stop_name\n1,"Market St, Stand B"\n');
    expect((await parse(file)).batches.single.single, ['1', 'Market St, Stand B']);
  });

  test('skips blank lines', () async {
    final file = await csv('stop_id\n1\n\n2\n');
    expect((await parse(file)).batches.single, [['1'], ['2']]);
  });

  test('applies the row filter, the transform and the batch filter in turn', () async {
    final file = await csv('id\n1\n2\n3\n4\n');
    final result = await parse(
      file,
      filter: (header, row) => row.first != '2',
      transformRow: (header, row) => ['x${row.first}'],
      filterBatch: (header, batch) async => batch.where((row) => row.first != 'x4').toList(),
    );
    expect(result.batches.single, [['x1'], ['x3']]);
  });

  test('throws for an empty file', () async {
    final file = await csv('');
    expect(() => parse(file), throwsA(isA<FormatException>()));
  });

  test('stops when cancelled', () async {
    final file = await csv('id\n1\n2\n');
    final token = CancellationToken()..cancel();
    expect(
      () => streamParseAndInsertWithHeader(file, (_, _) async {}, cancelToken: token),
      throwsA(isA<OperationCancelledException>()),
    );
  });

  group('countCsvDataLines', () {
    test('counts the rows after the header', () async {
      expect(await countCsvDataLines(await csv('id\n1\n2\n3\n')), 3);
    });

    test('counts a last row without a line break', () async {
      expect(await countCsvDataLines(await csv('id\n1\n2')), 2);
    });

    test('is zero for a header alone or an empty file', () async {
      expect(await countCsvDataLines(await csv('id\n')), 0);
      expect(await countCsvDataLines(await csv('')), 0);
    });
  });
}
