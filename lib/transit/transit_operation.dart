import 'package:transport_alarm/transit/cancellation.dart';
import 'package:transport_alarm/transit/progress_callback.dart';

/// A transit data operation the loading screen runs, such as a first build
/// or a refresh. Resolves to a description of each step that failed, such
/// as "KMB: (error)"; throws [OperationCancelledException] when cancelled.
typedef TransitOperation = Future<List<String>> Function({
  ProgressCallback? onProgress,
  bool forceRefresh,
  CancellationToken? cancelToken,
});
