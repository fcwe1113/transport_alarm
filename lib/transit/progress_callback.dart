import 'package:transport_alarm/transit/cancellation.dart';

typedef ProgressCallback = void Function(String message, double? progress);
typedef TransitOperation = Future<List<String>> Function({ProgressCallback? onProgress, bool forceRefresh, CancellationToken? cancelToken});