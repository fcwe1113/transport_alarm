import 'package:transport_alarm/transit/cancellation.dart';

/// Reports a data operation's step, and its progress from 0 to 1, or null
/// when it can't be measured.
typedef ProgressCallback = void Function(String message, double? progress);

/// A transit data operation the loading screen runs, such as a first build
/// or a refresh. Resolves to a description of each step that failed, such
/// as "KMB: <error>"; throws [OperationCancelledException] when cancelled.
typedef TransitOperation = Future<List<String>> Function({
  ProgressCallback? onProgress,
  bool forceRefresh,
  CancellationToken? cancelToken,
});
