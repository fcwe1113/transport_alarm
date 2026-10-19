/// Thrown when the user cancels a data reload or refresh.
class OperationCancelledException implements Exception {
  const OperationCancelledException();

  @override
  String toString() => 'Operation cancelled';
}

/// Lets the loading screen ask a running data operation to stop. The
/// operation checks it between steps and stops by throwing
/// [OperationCancelledException], so its cleanup code still runs.
class CancellationToken {
  bool _cancelled = false;
  final _listeners = <void Function()>[];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }

  void throwIfCancelled() {
    if (_cancelled) throw const OperationCancelledException();
  }

  /// Runs [listener] on cancel, e.g. to close an HTTP client so a download
  /// stops straight away. Returns a function that removes it again.
  void Function() onCancel(void Function() listener) {
    if (_cancelled) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }
}
