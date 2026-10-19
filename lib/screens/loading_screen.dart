import 'package:transport_alarm/transit/cancellation.dart';
import 'package:transport_alarm/transit/progress_callback.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:transport_alarm/transit/services/locale_selection_service.dart';
import 'package:transport_alarm/transit/services/stale_data_reminder.dart';
import 'package:transport_alarm/transit_bootstrap.dart';
import 'package:transport_alarm/widgets/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:transport_alarm/l10n/app_strings.dart';

class LoadingScreen extends StatefulWidget {
  final bool forceRefresh;
  final TransitOperation operation;
  final bool returnToPrevious;
  final bool showBottomNavigation;
  // Off for first-time setup, which has no data to fall back on.
  final bool cancellable;
  // The first data build: setup only counts as done once it succeeds, and a
  // failure restarts setup.
  final bool firstTimeSetup;
  // Undoes whatever started this operation, such as a locale change, when
  // it's cancelled or fails (it throws, or a locale ends up without data).
  final Future<void> Function()? onAbandon;
  const LoadingScreen({
    super.key,
    this.forceRefresh = false,
    this.operation = initializeTransitData,
    this.returnToPrevious = false,
    this.showBottomNavigation = false,
    this.cancellable = false,
    this.firstTimeSetup = false,
    this.onAbandon,
  });

  @override
  State<LoadingScreen> createState() => _LoadingScreenState();
}

class _LoadingScreenState extends State<LoadingScreen> {
  String _message = AppStrings.text('loading.starting');
  double? _progress;
  String? _error;
  bool _finished = false;
  CancellationToken? _cancelToken;

  @override
  void initState() {
    super.initState();
    _runOperation();
  }

  Future<void> _runOperation() async {
    final cancelToken = CancellationToken();
    setState(() {
      _error = null;
      _finished = false;
      _cancelToken = cancelToken;
    });
    try {
      final failures = await widget.operation(
        forceRefresh: widget.forceRefresh,
        cancelToken: cancelToken,
        onProgress: (message, progress) {
          if (!mounted || cancelToken.isCancelled) return;
          setState(() {
            _message = message;
            _progress = progress;
          });
        },
      );
      
      if (widget.firstTimeSetup && !await _allLocalesHaveData()) {
        await _restartSetup(failures.join(", "));
        return;
      }
      if (widget.onAbandon != null && !await _allLocalesHaveData()) {
        await _abandon(failures.join(", "));
        return;
      }

      if (mounted && failures.isNotEmpty) {
        await showDialog(context: context, builder: (context) => AlertDialog(
          title: Text(AppStrings.text('loading.failures.title')),
          content: Text(AppStrings.text('loading.failures.body', {
            'count': failures.length,
            'failures': failures.join(", "),
          })),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(AppStrings.text('common.ok')))],
        ));
      }
      
      await StaleDataReminder().clearSnooze();
      if (widget.firstTimeSetup) {
        await LocaleSelectionService().setSetupCompleted(true);
      }

      if (mounted) {
        setState(() {
          _message = AppStrings.text('loading.completed');
          _progress = 1.0;
          _finished = true;
        });
      }
    } on OperationCancelledException {
      await widget.onAbandon?.call();
      // The operation has already removed its staging and temp files.
      if (mounted) _onOkPressed();
    } catch (e) {
      if (widget.firstTimeSetup) {
        await _restartSetup('$e');
        return;
      }
      if (widget.onAbandon != null) {
        await _abandon('$e');
        return;
      }
      if (mounted) {
        setState(() {
          _error = AppStrings.text('loading.failed', {'error': e});
        });
      }
    }
  }

  /// Undoes the change that started a failed operation, tells the user, and
  /// leaves the screen.
  Future<void> _abandon(String details) async {
    await widget.onAbandon?.call();
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(AppStrings.text('locale_change.failed.title')),
        content: Text(AppStrings.text('locale_change.failed.body', {'details': details})),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(AppStrings.text('common.ok')))],
      ),
    );
    if (mounted) _onOkPressed();
  }

  /// Whether every enabled locale ended up with a usable timetable.
  Future<bool> _allLocalesHaveData() async {
    final locales = await LocaleSelectionService().getEnabledLocales();
    for (final locale in locales.keys) {
      if (!await GtfsDatabase.forLocale(locale).hasUsableGtfsData()) {
        return false;
      }
    }
    return true;
  }

  /// Explains that the first build failed, then starts setup again from the
  /// language page. The setup flag stays false, so relaunching does too.
  Future<void> _restartSetup(String details) async {
    if (!mounted) return;
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(AppStrings.text('setup.build_failed.title')),
        content: Text(AppStrings.text('setup.build_failed.body', {'details': details})),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(AppStrings.text('common.ok')))],
      ),
    );
    if (!mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/setup-language', (_) => false);
  }

  void _cancel() {
    setState(() {
      _cancelToken?.cancel();
      _message = AppStrings.text('loading.cancelling');
      _progress = null;
    });
  }

  void _onOkPressed() {
    if (widget.returnToPrevious) {
      Navigator.pop(context);
    } else {
      Navigator.pushReplacementNamed(context, "/");
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: _error != null ? [
            const Icon(Icons.error_outline, color: Colors.red, size: 48,),
            const SizedBox(height: 16),
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _runOperation,
              child: Text(AppStrings.text('common.retry'))
            ),
          ] : [
            _progress != null ? LinearProgressIndicator(value: _progress,) : LinearProgressIndicator(),
            const SizedBox(height: 16,),
            Text(_message),
            if (_finished) ...[
              const SizedBox(height: 24,),
              ElevatedButton(onPressed: _onOkPressed, child: Text(AppStrings.text('common.ok')))
            ] else if (widget.cancellable && _cancelToken != null)
              // Hidden while a new snapshot is being swapped in, which has to
              // finish once started.
              ValueListenableBuilder<bool>(
                valueListenable: _cancelToken!.canCancel,
                builder: (context, canCancel, _) => !canCancel
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(top: 24),
                        child: OutlinedButton(
                          // Disabled once pressed, while the operation winds down.
                          onPressed: _cancelToken!.isCancelled ? null : _cancel,
                          child: Text(AppStrings.text('common.cancel')),
                        ),
                      ),
              ),
          ],
        ),
    );
    if (widget.showBottomNavigation) {
      return AppShell(
        title: AppStrings.text('settings.title'),
        selectedTab: 2,
        body: content,
      );
    }
    return Scaffold(body: content);
  }
}
