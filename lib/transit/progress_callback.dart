/// Reports a data operation's step, and its progress from 0 to 1, or null
/// when it can't be measured.
typedef ProgressCallback = void Function(String message, double? progress);
