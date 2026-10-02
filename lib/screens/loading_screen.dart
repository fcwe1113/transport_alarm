import 'package:transport_alarm/transit/progress_callback.dart';
import 'package:transport_alarm/transit_bootstrap.dart';
import 'package:transport_alarm/widgets/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:transport_alarm/l10n/app_strings.dart';

class LoadingScreen extends StatefulWidget {
  final bool forceRefresh;
  final TransitOperation operation;
  final bool returnToPrevious;
  final bool showBottomNavigation;
  const LoadingScreen({
    super.key,
    this.forceRefresh = false,
    this.operation = initializeTransitData,
    this.returnToPrevious = false,
    this.showBottomNavigation = false,
  });

  @override
  State<LoadingScreen> createState() => _LoadingScreenState();
}

class _LoadingScreenState extends State<LoadingScreen> {
  String _message = AppStrings.text('loading.starting');
  double? _progress;
  String? _error;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _runOperation();
  }

  Future<void> _runOperation() async {
    setState(() {
      _error = null;
      _finished = false;
    });
    try {
      final failures = await widget.operation(
        forceRefresh: widget.forceRefresh,
        onProgress: (message, progress) {
          if (!mounted) return;
          setState(() {
            _message = message;
            _progress = progress;
          });
        },
      );
      
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
      
      if (mounted) {
        setState(() {
          _message = AppStrings.text('loading.completed');
          _progress = 1.0;
          _finished = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = AppStrings.text('loading.failed', {'error': e});
        });
      }
    }
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
            ]
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
