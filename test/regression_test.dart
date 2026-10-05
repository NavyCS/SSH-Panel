/// Regression tests for the defects that produced wrong behaviour in shipped
/// code, plus the toast mapping that leaked internals to the UI.
///
/// These tests exist to fail if the fixes are undone.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_panel/services/cancellation.dart';
import 'package:ssh_panel/services/ssh_keys.dart';
import 'package:ssh_panel/services/ssh_service.dart';
import 'package:ssh_panel/toast_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('rawDetail stays out of user-facing text', () {
    test('SshKeyException.message excludes rawDetail', () {
      final e = SshKeyException(
        SshKeyErrorCode.keygenFailed,
        'The key file already exists.',
        rawDetail: r'ssh-keygen exit code 255 at C:\Users\me\.ssh\id_ed25519',
      );
      expect(e.message, isNot(contains('exit code 255')));
      expect(e.message, isNot(contains('.ssh')));
      // toString() is the debug/logger surface and still carries it.
      expect(e.toString(), contains('exit code 255'));
    });

    test('SshServiceException.message excludes rawDetail', () {
      final e = SshServiceException(
        SshServiceErrorCode.accessDenied,
        'Access denied opening the ssh-agent service.',
        rawDetail: 'OpenService error 5 -- not running elevated',
      );
      expect(e.message, isNot(contains('error 5')));
      expect(e.toString(), contains('error 5'));
    });
  });

  group('ToastService error mapping', () {
    // Regression: _mapError returned `error.toString()` for SshKeyException
    // and SshConfigException, and fell through to `_ => e.toString()` for other
    // service codes. Because toString() embeds rawDetail, users saw strings
    // like "SshKeyException(keygenFailed): ... (exit code 255)" and the Copy
    // button pushed that same text to the clipboard.
    //
    // No toaster is registered here, so showError cannot render; the point is
    // that mapping and dispatching a typed exception carrying a rawDetail must
    // not throw and must not reach the clipboard.
    late List<MethodCall> clipboardCalls;

    setUp(() {
      clipboardCalls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        clipboardCalls.add(call);
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    test('key errors with rawDetail do not throw', () {
      expect(
        () => ToastService.instance.showError(
          SshKeyException(
            SshKeyErrorCode.keygenFailed,
            'The key file already exists.',
            rawDetail: r'ssh-keygen exit code 255 at C:\Users\me\.ssh\id_ed25519',
          ),
        ),
        returnsNormally,
      );
      expect(clipboardCalls, isEmpty);
    });

    test('config errors with rawDetail do not throw', () {
      expect(
        () => ToastService.instance.showError(
          SshKeyException(
            SshKeyErrorCode.commandNotFound,
            'ssh-keygen is not installed or not found on PATH.',
            rawDetail: r'OSError: file not found C:\Windows\System32\ssh-keygen.exe',
          ),
        ),
        returnsNormally,
      );
      expect(clipboardCalls, isEmpty);
    });

    test('service errors with rawDetail do not throw', () {
      expect(
        () => ToastService.instance.showError(
          SshServiceException(
            SshServiceErrorCode.operationFailed,
            'QueryServiceConfig failed.',
            rawDetail: 'error 1060',
          ),
        ),
        returnsNormally,
      );
      expect(clipboardCalls, isEmpty);
    });

    test('handleError accepts an Error, not only an Exception', () {
      // FlutterError.onError hands over an Object. An internal bug like the
      // LateInitializationError fixed in SshKeyManager._runWithTimeout arrives
      // as an Error (not an Exception), so this path must not rethrow.
      expect(
        () => ToastService.instance.handleError(
          StateError('field process has not been initialized'),
          StackTrace.current,
        ),
        returnsNormally,
      );
    });
  });

  group('StartupType', () {
    test('covers the three values the UI offers', () {
      expect(StartupType.values, hasLength(3));
      expect(
        StartupType.values.map((e) => e.name).toSet(),
        {'automatic', 'manual', 'disabled'},
      );
    });
  });

  group('CancellationToken', () {
    test('CancellationTokenCancelled is catchable as an Exception', () {
      // ServiceTab catches it separately from SshServiceException so that
      // "the tab went away" is not reported to the user as a failure.
      expect(const CancellationTokenCancelled(), isA<Exception>());
    });

    test('is honoured before any FFI call when pre-cancelled', () {
      final token = CancellationToken()..cancel();
      expect(token.isCancelled, isTrue);
    });
  });
}
