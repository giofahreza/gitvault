import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/repositories/sync_engine.dart';

enum RecoveryApprovalPhase {
  checking,
  waiting,
  received,
  completing,
  completed,
  denied,
  expired,
  unavailable,
}

/// Approval UI with injectable operations, independent from vault restoration.
class RecoveryApprovalDialog extends StatefulWidget {
  final String approvalId;
  final Future<DeviceApprovalStatus> Function(String) check;
  final Future<void> Function(String) complete;
  final Future<String> Function() requestAgain;
  final Future<bool> Function(String) recoverWithNewToken;

  const RecoveryApprovalDialog({
    super.key,
    required this.approvalId,
    required this.check,
    required this.complete,
    required this.requestAgain,
    required this.recoverWithNewToken,
  });

  @override
  State<RecoveryApprovalDialog> createState() => _RecoveryApprovalDialogState();
}

class _RecoveryApprovalDialogState extends State<RecoveryApprovalDialog>
    with WidgetsBindingObserver {
  Timer? _timer;
  late String _approvalId;
  RecoveryApprovalPhase _phase = RecoveryApprovalPhase.waiting;
  bool _busy = false;
  int _remainingSeconds = 30;
  String? _error;
  final Stopwatch _elapsed = Stopwatch();
  bool _finalCheckNeeded = false;
  int _remainingAtObservation = 30;

  bool get _terminal =>
      _phase == RecoveryApprovalPhase.denied ||
      _phase == RecoveryApprovalPhase.expired ||
      _phase == RecoveryApprovalPhase.completed;

  @override
  void initState() {
    super.initState();
    _approvalId = widget.approvalId;
    WidgetsBinding.instance.addObserver(this);
    _startTimer();
    unawaited(_check());
  }

  void _startTimer() {
    _timer?.cancel();
    _finalCheckNeeded = false;
    _elapsed
      ..reset()
      ..start();
    _scheduleTimer(30);
  }

  void _scheduleTimer(int seconds) {
    _timer?.cancel();
    _remainingAtObservation = seconds;
    _elapsed
      ..reset()
      ..start();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _terminal) return;
      setState(() => _remainingSeconds = (seconds - timer.tick).clamp(0, 30));
      if (_remainingSeconds == 0) {
        _timer?.cancel();
        // One final remote check: timely approvals remain valid after expiry.
        if (_busy) {
          _finalCheckNeeded = true;
        } else {
          unawaited(_check());
        }
      } else if (_remainingSeconds % 3 == 0) {
        unawaited(_check());
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_terminal) {
      _remainingSeconds =
          (_remainingAtObservation - _elapsed.elapsed.inSeconds).clamp(0, 30);
      if (_remainingSeconds > 0) _scheduleTimer(_remainingSeconds);
      unawaited(_check());
    } else if (state == AppLifecycleState.paused) {
      _timer?.cancel();
    }
  }

  Future<void> _check() async {
    if (_busy || _terminal) return;
    setState(() {
      _busy = true;
      _error = null;
      _phase = RecoveryApprovalPhase.checking;
    });
    try {
      final status = await widget.check(_approvalId);
      if (!mounted) return;
      if (status.isApproved) {
        setState(() => _phase = RecoveryApprovalPhase.received);
        _timer?.cancel();
        setState(() => _phase = RecoveryApprovalPhase.completing);
        await widget.complete(_approvalId);
        if (!mounted) return;
        setState(() => _phase = RecoveryApprovalPhase.completed);
        Navigator.of(context).pop(true);
      } else if (status.isDenied || status.isExpired) {
        _timer?.cancel();
        setState(
          () => _phase = status.isDenied
              ? RecoveryApprovalPhase.denied
              : RecoveryApprovalPhase.expired,
        );
      } else {
        setState(() {
          _phase = RecoveryApprovalPhase.waiting;
          _remainingSeconds = status.remainingSeconds ?? _remainingSeconds;
        });
        if (status.remainingSeconds == 0) {
          _timer?.cancel();
          _timer = Timer(const Duration(seconds: 1), () => unawaited(_check()));
        }
        if (status.remainingSeconds != null && _remainingSeconds > 0) {
          _scheduleTimer(_remainingSeconds);
        }
        if (_remainingSeconds > 0 && !(_timer?.isActive ?? false)) {
          _scheduleTimer(_remainingSeconds);
        }
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _phase = RecoveryApprovalPhase.unavailable;
        _error =
            'Could not confirm approval or complete registration. Check your connection and try Check Approval again.';
      });
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        if (_finalCheckNeeded && !_terminal) {
          _finalCheckNeeded = false;
          unawaited(_check());
        }
      }
    }
  }

  Future<void> _retry() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final id = await widget.requestAgain();
      if (!mounted) return;
      setState(() {
        _approvalId = id;
        _phase = RecoveryApprovalPhase.waiting;
        _remainingSeconds = 30;
      });
      _startTimer();
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not request approval. Please retry.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && !_terminal) await _check();
  }

  Future<void> _newToken() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final completed = await widget.recoverWithNewToken(_approvalId);
      if (mounted && completed) Navigator.of(context).pop(false);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Recovery could not complete. Please retry.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String get _message => switch (_phase) {
        RecoveryApprovalPhase.checking => 'Checking approval...',
        RecoveryApprovalPhase.waiting =>
          'Waiting for approval... $_remainingSeconds seconds left',
        RecoveryApprovalPhase.received => 'Approval received.',
        RecoveryApprovalPhase.completing =>
          'Approval received. Completing registration...',
        RecoveryApprovalPhase.completed => 'Device registered.',
        RecoveryApprovalPhase.denied => 'Recovery request denied.',
        RecoveryApprovalPhase.expired =>
          'Recovery request expired. Request approval again.',
        RecoveryApprovalPhase.unavailable =>
          'Temporarily unable to confirm registration.',
      };

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _elapsed.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !_busy || _phase == RecoveryApprovalPhase.completed,
        child: AlertDialog(
          title: const Text('Approve This Device'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Approve this restore on another trusted device.'),
                const SizedBox(height: 12),
                if (_busy) const LinearProgressIndicator(),
                Text(_message),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!),
                ],
                const SizedBox(height: 12),
                const Text(
                  'If no trusted device is available, use a newly generated GitHub token.',
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: _busy ? null : () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            if (_terminal)
              OutlinedButton(
                onPressed: _busy ? null : _retry,
                child: const Text('Request Approval Again'),
              )
            else
              OutlinedButton(
                onPressed: _busy ? null : _check,
                child: const Text('Check Approval'),
              ),
            FilledButton(
              onPressed: _busy ? null : _newToken,
              child: const Text('Use New Token'),
            ),
          ],
        ),
      );
}
