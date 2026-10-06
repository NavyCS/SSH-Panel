import 'dart:developer' show log;

import 'package:flutter/foundation.dart';

import '../../services/agent_state.dart';
import '../../services/cancellation.dart';
import '../../services/ssh_service.dart';
import '../../toast_service.dart';

/// Owns the state and the async logic of the Service tab.
///
/// This logic used to live in a `State` subclass, which forced two things on
/// every method: an `if (!mounted) return;` after each `await`, because a
/// widget can be torn down while an FFI call is in flight; and `setState` calls
/// interleaved with the awaits. Roughly half of `_ServiceTabState` was
/// bookkeeping about *whether it was still alive*.
///
/// Holding the same state in a [ChangeNotifier] removes all of it:
///
/// * `dispose()` cancels the polling token, so there is nothing to guard
///   against — the token is the shutdown signal.
/// * `notifyListeners()` is a no-op after disposal, so a late result cannot
///   reach a dead widget.
///
/// [status] is also mirrored into the app-wide `agentServiceState` notifier
/// that the Keys tab reads, which is how one tab learns the agent came up
/// without the two tabs knowing about each other.
class ServiceController extends ChangeNotifier {
  ServiceController({SshServiceManager? serviceManager})
      : _serviceManager = serviceManager ?? SshServiceManager();

  final SshServiceManager _serviceManager;

  /// Aborts the SCM polling loops in start/stop when this controller is
  /// disposed. Without it, switching tabs leaves a loop waking the isolate
  /// every 300 ms for up to 30 s for a result nobody is waiting for.
  final CancellationToken _cancellation = CancellationToken();

  SshServiceState? _status;

  /// The startup type as reported by the SCM. `null` means it could not be
  /// determined — OpenSSH is absent, or the SCM refused the query.
  ///
  /// This used to be initialised to `StartupType.manual`, so the dropdown
  /// asserted "Manual" even when the service was set to Automatic.
  StartupType? _startupType;

  bool _loading = false;
  bool _startupLoading = false;
  bool _disposed = false;

  /// Current service state, or `null` before the first successful read.
  SshServiceState? get status => _status;

  StartupType? get startupType => _startupType;

  /// True while a status read or a start/stop is in flight.
  bool get isLoading => _loading;

  /// True while a startup-type change is being written.
  bool get isStartupTypeLoading => _startupLoading;

  /// Human-readable label for [state], for the status badge.
  static String statusLabel(SshServiceState state) => switch (state) {
        SshServiceState.running => 'Running',
        SshServiceState.stopped => 'Stopped',
        SshServiceState.startPending => 'Start Pending',
        SshServiceState.stopPending => 'Stop Pending',
        SshServiceState.continuePending => 'Continue Pending',
        SshServiceState.paused => 'Paused',
        SshServiceState.unknown => 'Unknown',
      };

  /// Reads the service state and the startup type from the SCM.
  Future<void> refresh() async {
    _setLoading(true);
    try {
      final status = await _serviceManager.checkStatus();
      final startupType = await _serviceManager.queryStartupType();
      if (_disposed) return;
      // Publish before the local field so the Keys tab never sees a newer
      // local value than the notifier it listens to.
      agentServiceState.value = status;
      _status = status;
      _startupType = startupType;
    } on SshServiceException catch (e) {
      if (_disposed) return;
      ToastService.instance.showError(e);
    } catch (e) {
      if (_disposed) return;
      ToastService.instance.showError(SshServiceException(
        SshServiceErrorCode.operationFailed,
        e.toString(),
      ));
    } finally {
      _setLoading(false);
    }
  }

  /// Starts the agent, waits for the named pipe, then refreshes.
  Future<void> start() =>
      _perform(() => _serviceManager.start(cancellationToken: _cancellation));

  /// Stops the agent, then refreshes.
  Future<void> stop() =>
      _perform(() => _serviceManager.stop(cancellationToken: _cancellation));

  /// Writes [type] to the service configuration, restoring the previous value
  /// if the write fails.
  ///
  /// This is the one action that does not re-read afterwards: `setStartupType`
  /// either succeeds, or the SCM never moved and the optimistic value has to
  /// be rolled back.
  Future<void> setStartupType(StartupType type) async {
    final original = _startupType;
    _startupType = type;
    _startupLoading = true;
    _notify();
    try {
      await _serviceManager.setStartupType(type);
      if (_disposed) return;
      ToastService.instance.showSuccess('Startup type set.');
    } on SshServiceException catch (e) {
      if (_disposed) return;
      _startupType = original;
      ToastService.instance.showError(e);
    } catch (e) {
      if (_disposed) return;
      _startupType = original;
      ToastService.instance.showError(SshServiceException(
        SshServiceErrorCode.operationFailed,
        e.toString(),
      ));
    } finally {
      _startupLoading = false;
      _notify();
    }
  }

  /// Runs [action], then refreshes and reports success.
  Future<void> _perform(Future<void> Function() action) async {
    _setLoading(true);
    try {
      await action();
      if (_disposed) return;
      await refresh();
      if (_disposed) return;
      ToastService.instance.showSuccess('Service action completed.');
    } on CancellationTokenCancelled catch (e, st) {
      // The tab went away mid-poll. Not something the user caused or needs to
      // be told about, so it is logged rather than surfaced as a toast.
      log('Action abandoned: the tab went away mid-poll.',
          name: 'ssh_panel', error: e, stackTrace: st);
    } on SshServiceException catch (e) {
      if (_disposed) return;
      ToastService.instance.showError(e);
    } catch (e) {
      if (_disposed) return;
      ToastService.instance.showError(SshServiceException(
        SshServiceErrorCode.operationFailed,
        e.toString(),
      ));
    }
  }

  void _setLoading(bool value) {
    if (_loading == value) return;
    _loading = value;
    _notify();
  }

  /// Notifies only while alive, so a late result cannot reach a disposed
  /// listener.
  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancellation.cancel();
    super.dispose();
  }
}
