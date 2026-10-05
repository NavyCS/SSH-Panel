import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'services/ssh_service.dart';
import 'services/ssh_keys.dart';
import 'services/ssh_domains.dart';

/// Centralized toast service.
///
/// Holds a reference to the app's [ShadToasterState], captured once at shell
/// startup via [setState]. Any code - including Flutter's global uncaught
/// error handler, which runs outside any widget - can call [showError],
/// [showErrorMessage], [showSuccess], or [showInfo] without needing a
/// [BuildContext].
///
/// All public methods are safe to call before [setState] has been invoked:
/// they silently no-op when the toaster state is null.
class ToastService {
  ToastService._();

  static final ToastService instance = ToastService._();

  ShadToasterState? _state;

  /// Called by the shell after the first frame to publish the toaster state.
  ///
  /// Safe to call multiple times; only the latest value is used.
  void setState(ShadToasterState state) {
    _state = state;
  }

  // -- Error ---------------------------------------------------------------

  /// How long an error toast stays on screen.
  ///
  /// The shadcn default is around 5 s, which is fine for "Config saved." but
  /// far too short for a three-line error explanation: the message finishes
  /// scrolling as the user starts to read it, and by the time they look for the
  /// Copy button it is gone. Errors are the one case where being unreadable
  /// costs the user real information, so they get a longer life.
  static const Duration _errorToastDuration = Duration(seconds: 15);

  /// Shows a destructive toast for any thrown [error].
  ///
  /// Typed exceptions ([SshServiceException], [SshKeyException],
  /// [SshConfigException]) and [TimeoutException] are mapped to a title and
  /// description; unknown exceptions fall back to their [Object.toString].
  ///
  /// The action button copies the description to the clipboard. It deliberately
  /// does not replace the toast with a confirmation: doing so destroyed the
  /// error message at the exact moment the user asked to keep it.
  void showError(Exception error) {
    final (title, description) = _mapError(error);
    _show(
      ShadToast.destructive(
        title: Text(title),
        description: Text(description),
        duration: _errorToastDuration,
        action: Semantics(
          button: true,
          label: 'Copy error to clipboard',
          child: ShadButton.destructive(
            child: const Text('Copy'),
            onPressed: () => _copyToClipboard(description, showConfirmation: false),
          ),
        ),
      ),
    );
  }

  /// Shows a destructive toast for a manual error [message].
  ///
  /// Used for error strings that are not caught exceptions (e.g. a
  /// "public key not found" message produced by a guard clause).
  ///
  /// The action button copies the message to the clipboard.
  void showErrorMessage(String message) {
    _show(
      ShadToast.destructive(
        title: const Text('Error'),
        description: Text(message),
        duration: _errorToastDuration,
        action: Semantics(
          button: true,
          label: 'Copy error to clipboard',
          child: ShadButton.destructive(
            child: const Text('Copy'),
            onPressed: () => _copyToClipboard(message, showConfirmation: false),
          ),
        ),
      ),
    );
  }

  /// Global error-handler entry point.
  ///
  /// [FlutterError.onError] and [PlatformDispatcher.instance.onError] pass
  /// an [Object] and [StackTrace], not an [Exception]. This method delegates
  /// to [showError] after a best-effort cast, and never rethrows.
  void handleError(Object error, StackTrace stack) {
    if (error is Exception) {
      showError(error);
    } else {
      showErrorMessage(error.toString());
    }
  }

  // -- Success / info ------------------------------------------------------

  /// Shows a primary (non-destructive) toast for a successful action.
  void showSuccess(String message) {
    _show(
      ShadToast(
        title: const Text('Done'),
        description: Text(message),
      ),
    );
  }

  /// Shows a primary toast for an informational message.
  void showInfo(String message) {
    _show(
      ShadToast(
        title: const Text('Info'),
        description: Text(message),
      ),
    );
  }

  // -- Internal ------------------------------------------------------------

  void _show(ShadToast toast) {
    final state = _state;
    if (state == null) return;
    // Defer to the next frame so the toaster is fully built.
    Future.microtask(() {
      state.show(toast);
    });
  }

  /// Copies [text] to the system clipboard.
  ///
  /// [showConfirmation] controls whether a "Copied to clipboard" toast is
  /// raised. Callers copying from an error toast pass `false`, because
  /// `ShadToasterState.show` replaces the visible toast: the confirmation would
  /// displace the very error the user asked to preserve.
  void _copyToClipboard(String text, {bool showConfirmation = true}) {
    Clipboard.setData(ClipboardData(text: text));
    if (showConfirmation) {
      showInfo('Copied to clipboard');
    }
  }

  (String title, String description) _mapError(Exception error) {
    if (error is SshServiceException) {
      return (_serviceTitle(error), _serviceDescription(error));
    }
    if (error is SshKeyException) {
      return (_keyTitle(error), error.message);
    }
    if (error is SshConfigException) {
      return (_configTitle(error), error.message);
    }
    if (error is TimeoutException) {
      return ('Timed out', error.message ?? 'The operation timed out.');
    }
    return ('Error', error.toString());
  }

  String _serviceTitle(SshServiceException e) => switch (e.code) {
    SshServiceErrorCode.accessDenied => 'Administrator required',
    SshServiceErrorCode.serviceNotFound => 'Service not found',
    SshServiceErrorCode.opensshNotInstalled => 'OpenSSH not installed',
    _ => 'Service error',
  };

  // Every branch returns e.message, never e.toString(): toString() embeds
  // rawDetail, which carries raw Win32 error codes, stderr and absolute paths.
  // That string used to be rendered in the toast and pushed to the clipboard by
  // the "Copy" action, leaking internals and file paths to the UI.
  String _serviceDescription(SshServiceException e) => switch (e.code) {
    SshServiceErrorCode.accessDenied =>
      'Administrator privileges are required for this action. '
      'In "Once" mode, use the "Admin Mode" button in the top bar. '
      'In "Per action" mode, accept the UAC prompt.',
    _ => e.message,
  };

  String _keyTitle(SshKeyException e) => switch (e.code) {
    SshKeyErrorCode.commandNotFound => 'SSH tools not found',
    SshKeyErrorCode.agentCommandFailed => 'Agent command failed',
    SshKeyErrorCode.fileExists => 'Key file already exists',
    SshKeyErrorCode.keygenFailed => 'Key generation failed',
    SshKeyErrorCode.unexpectedOutput => 'Unexpected response',
    SshKeyErrorCode.timeout => 'Timed out',
    SshKeyErrorCode.wrongPassphrase => 'Wrong passphrase',
    SshKeyErrorCode.userProfileNotSet => 'User profile not set',
    SshKeyErrorCode.invalidKeyName => 'Invalid key name',
  };

  String _configTitle(SshConfigException e) => switch (e.code) {
    SshConfigErrorCode.userProfileNotSet => 'User profile not set',
    SshConfigErrorCode.readFailed => 'Could not read config',
    SshConfigErrorCode.writeFailed => 'Could not write config',
    SshConfigErrorCode.keyscanFailed => 'Host scan failed',
    SshConfigErrorCode.invalidHost => 'Invalid host',
    SshConfigErrorCode.hostNotFound => 'Host not found',
  };
}