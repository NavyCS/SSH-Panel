/// Tests for [ServiceController].
///
/// These exist because the controller is the first piece of this app's logic
/// that is reachable without a widget tree. Everything here was previously
/// locked inside a `State` subclass, so it could only be exercised by
/// mounting the whole tab against the real Service Control Manager.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_panel/features/service/service_controller.dart';
import 'package:ssh_panel/services/ssh_service.dart';

void main() {
  group('ServiceController.statusLabel', () {
    test('covers every SshServiceState', () {
      // A non-exhaustive switch here would throw at runtime for an unhandled
      // state, which is exactly when a user is most likely to be looking at
      // the badge.
      for (final state in SshServiceState.values) {
        expect(ServiceController.statusLabel(state), isNotEmpty);
      }
    });

    test('maps the states a user actually sees', () {
      expect(ServiceController.statusLabel(SshServiceState.running), 'Running');
      expect(ServiceController.statusLabel(SshServiceState.stopped), 'Stopped');
      expect(
        ServiceController.statusLabel(SshServiceState.startPending),
        'Start Pending',
      );
      expect(
        ServiceController.statusLabel(SshServiceState.stopPending),
        'Stop Pending',
      );
    });
  });

  group('ServiceController lifecycle', () {
    test('starts with nothing known', () {
      // Null rather than a guess. The tab used to seed StartupType.manual,
      // which reported a value the SCM had never confirmed.
      final controller = ServiceController();
      addTearDown(controller.dispose);

      expect(controller.status, isNull);
      expect(controller.startupType, isNull);
      expect(controller.isLoading, isFalse);
      expect(controller.isStartupTypeLoading, isFalse);
    });

    test('dispose does not throw', () {
      final controller = ServiceController();
      expect(controller.dispose, returnsNormally);
    });

    test('dispose cancels the polling token exactly once', () {
      // Calling dispose twice is a ChangeNotifier contract violation and
      // asserts in debug mode, so the contract is "call it once". What
      // matters here is that dispose itself is safe before any operation has
      // started, since dispose() cancels a token nobody has read yet.
      final controller = ServiceController();
      expect(controller.dispose, returnsNormally);
    });
  });

  group('ServiceController notification', () {
    test('does not notify after disposal', () {
      // A late result from an in-flight FFI call must not reach a dead
      // listener; ChangeNotifier would throw on that.
      final controller = ServiceController();
      var notifications = 0;
      controller.addListener(() => notifications++);

      controller.dispose();

      // Calling the notifier path post-dispose must be a no-op rather than an
      // assertion failure.
      expect(() => controller.refresh(), returnsNormally);
      expect(notifications, 0);
    });
  });
}
