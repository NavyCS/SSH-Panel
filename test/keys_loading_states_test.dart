/// Tests for the distinction between an initial load and a later operation.
///
/// The tab used to blank all three of its cards whenever `isLoading` was true,
/// so unloading one key made the whole view disappear and reappear. The fix
/// separates the two states: [KeysController.isInitialLoad] is true only before
/// anything has been read, and is the only state that justifies hiding content.
///
/// These run against the real `~/.ssh` of the machine, which is what the
/// controller reads anyway; no service or agent is involved.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_panel/features/keys/keys_controller.dart';

void main() {
  group('isInitialLoad', () {
    test('is false before any work has been attempted', () {
      // Nothing has been read yet, but nothing is in flight either, so this is
      // not a "loading" state to show a spinner for.
      final controller = KeysController();
      addTearDown(controller.dispose);

      expect(controller.isLoading, isFalse);
      expect(controller.isInitialLoad, isFalse);
    });

    test('is true while the very first read is in flight', () {
      final controller = KeysController();
      addTearDown(controller.dispose);

      // refresh() marks itself loading synchronously before its first await, so
      // the state is observable without awaiting.
      final pending = controller.refresh();

      expect(controller.isLoading, isTrue);
      expect(controller.isInitialLoad, isTrue,
          reason: 'first read: there is genuinely nothing to show yet');

      return pending;
    });

    test('is false once a read has completed, even with no keys', () async {
      final controller = KeysController();
      addTearDown(controller.dispose);

      await controller.refresh();

      // The load finished. Whether ~/.ssh holds keys or not, the tab now knows
      // the answer and must stop treating itself as initial.
      expect(controller.isLoading, isFalse);
      expect(controller.isInitialLoad, isFalse);
      expect(controller.keyFiles, isA<List<String>>());
    });

    test('is false during a later refresh, which is the regression', () async {
      final controller = KeysController();
      addTearDown(controller.dispose);

      await controller.refresh();
      expect(controller.isInitialLoad, isFalse);

      // A second read. isLoading is true, but the tab already has content, so
      // isInitialLoad must stay false -- this is what keeps the cards on screen
      // instead of flashing a spinner over them.
      final second = controller.refresh();

      expect(controller.isLoading, isTrue,
          reason: 'the operation is still running');
      expect(controller.isInitialLoad, isFalse,
          reason: 'but the tab is not in an initial state any more');

      await second;
      expect(controller.isInitialLoad, isFalse);
    });
  });

  group('isBusyWith', () {
    test('is false for any path when no operation is running', () {
      final controller = KeysController();
      addTearDown(controller.dispose);

      expect(controller.isBusyWith(r'C:\keys\id_ed25519'), isFalse);
    });
  });

  group('cleanup', () {
    test('dispose is safe with no work in flight', () {
      expect(KeysController().dispose, returnsNormally);
    });
  });
}