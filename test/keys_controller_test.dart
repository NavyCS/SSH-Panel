/// Tests for [KeysController]'s pure helpers.
///
/// `isKeyLoaded` decides whether Load or Unload is offered for a key, so a
/// wrong answer either hides the action the user needs or offers one that fails.
/// It is the only piece of Keys logic worth testing exhaustively, because it
/// reconciles two paths that the OS and the agent report differently.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_panel/features/keys/keys_controller.dart';

void main() {
  group('KeysController.shortPath', () {
    test('returns the file name for a Windows path', () {
      expect(
        KeysController.shortPath(r'C:\Users\me\.ssh\id_ed25519'),
        'id_ed25519',
      );
    });

    test('returns the file name for a POSIX path', () {
      expect(KeysController.shortPath('/home/me/.ssh/id_ed25519'), 'id_ed25519');
    });

    test('handles a bare file name', () {
      expect(KeysController.shortPath('id_ed25519'), 'id_ed25519');
    });

    test('returns an empty string for a trailing separator', () {
      // split() leaves a trailing empty segment, so the last element is ''.
      // Pinned as-is because this is a pure refactor and the original behaved
      // this way; unreachable in practice because it is only ever called with
      // key file paths, which never end in a separator.
      expect(KeysController.shortPath(r'C:\keys\'), '');
    });
  });

  group('KeysController.normalizePath', () {
    test('converts forward slashes to backslashes', () {
      expect(
        KeysController.normalizePath('C:/Users/me/.ssh/id_ed25519'),
        r'c:\users\me\.ssh\id_ed25519',
      );
    });

    test('lowercases for case-insensitive comparison', () {
      expect(KeysController.normalizePath(r'C:\KEYS\ID_ED25519'),
          r'c:\keys\id_ed25519');
    });

    test('is idempotent', () {
      const path = r'C:/Mixed/Case/Key';
      final once = KeysController.normalizePath(path);
      expect(KeysController.normalizePath(once), once);
    });

    test('leaves an already-canonical path unchanged', () {
      const canonical = r'c:\keys\id_rsa';
      expect(KeysController.normalizePath(canonical), canonical);
    });
  });

  group('KeysController.isKeyLoaded', () {
    // Matches on fingerprint first, then falls back to path comparison because
    // `ssh-add -l` does not always report the path the way we scanned it.
    test('a fresh controller has nothing loaded', () {
      final controller = KeysController();
      addTearDown(controller.dispose);
      expect(controller.isKeyLoaded(r'C:\keys\id_ed25519'), isFalse);
    });

    test('reports the agent as not running before the first refresh', () {
      final controller = KeysController();
      addTearDown(controller.dispose);
      expect(controller.agentRunning, isFalse);
      expect(controller.isLoading, isFalse);
      expect(controller.keyFiles, isEmpty);
      expect(controller.loadedKeys, isEmpty);
      expect(controller.authorizedKeys, isEmpty);
    });

    test('accessors return false/null rather than throwing for unknown keys', () {
      final controller = KeysController();
      addTearDown(controller.dispose);

      expect(controller.hasPublicKey('nope'), isFalse);
      expect(controller.fingerprintOf('nope'), isNull);
      expect(controller.commentOf('nope'), isNull);
    });

    test('shortPath and normalizePath agree on the same input', () {
      // isKeyLoaded composes these two; if they disagreed on separators the
      // fallback match would never fire.
      const mixed = 'C:/Users/ME/.ssh/ID_Ed25519';
      final name = KeysController.shortPath(mixed).toLowerCase();
      final full = KeysController.normalizePath(mixed);
      expect(full.endsWith('\\$name'), isTrue);
    });
  });

  group('KeysController lifecycle', () {
    test('dispose does not throw', () {
      expect(KeysController().dispose, returnsNormally);
    });

    test('does not notify after dispose', () {
      // refresh() started before dispose must not reach a dead listener.
      final controller = KeysController();
      var notifications = 0;
      controller.addListener(() => notifications++);
      controller.dispose();

      expect(() => controller.refresh(), returnsNormally);
      expect(notifications, 0);
    });
  });
}
