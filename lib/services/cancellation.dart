/// Cooperative cancellation for long-running polling loops.
///
/// The service manager polls the SCM for up to 30 seconds while waiting for
/// `ssh-agent` to start or stop. Without a token, switching tabs or closing
/// the app leaves those loops running: they keep waking the isolate every
/// 300 ms and keep issuing FFI calls against a window the user no longer cares
/// about.
///
/// Callers pass a token in and cancel it from `dispose()`. Loops check
/// [isCancelled] at the top of every iteration and bail out with
/// [CancellationTokenCancelled].
class CancellationToken {
  bool _cancelled = false;

  /// Whether [cancel] has been called.
  bool get isCancelled => _cancelled;

  /// Requests that any loop holding this token stop at its next checkpoint.
  ///
  /// Safe to call more than once, and safe to call before the loop starts.
  void cancel() => _cancelled = true;
}

/// Thrown by a polling loop that was aborted because its token was cancelled.
///
/// This is deliberately a distinct type from the service's own timeout so that
/// callers can tell "the user navigated away" apart from "the operation really
/// did fail", and stay silent in the first case.
class CancellationTokenCancelled implements Exception {
  const CancellationTokenCancelled([this.what = 'The operation']);

  /// What was being cancelled, e.g. 'Starting the ssh-agent service'.
  final String what;

  @override
  String toString() => '$what was cancelled.';
}
