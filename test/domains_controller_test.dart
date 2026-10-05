/// Tests for [DomainsController]'s parsing helpers.
///
/// These are the parts that were previously unreachable: the key-type parsing
/// was inlined inside a `State` method that also opened dialogs, so it could
/// only be exercised by driving the whole tab against a real `~/.ssh`.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_panel/features/domains/domains_controller.dart';

void main() {
  group('DomainsController.parseKeyLine', () {
    test('reads the algorithm from a standard known_hosts line', () {
      final entry = DomainsController.parseKeyLine(
        'github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl',
      );
      expect(entry, isNotNull);
      expect(entry!['keyType'], 'ssh-ed25519');
    });

    test('keeps the whole line so it can be written back', () {
      // known_hosts entries are appended verbatim; dropping the trailing
      // comment or reordering fields would corrupt the file.
      const line = 'example.com ssh-rsa AAAAB3NzaC1yc2E comment here';
      final entry = DomainsController.parseKeyLine(line)!;
      expect(entry['line'], line);
      expect(entry['keyType'], 'ssh-rsa');
    });

    test('tolerates extra whitespace between fields', () {
      final entry = DomainsController.parseKeyLine(
        '  example.com   ecdsa-sha2-nistp256   AAAAE2VjZHNh  ',
      )!;
      expect(entry['keyType'], 'ecdsa-sha2-nistp256');
    });

    test('returns null for a line with no second field', () {
      // Comments and blank lines must not become a "key type" of "".
      expect(DomainsController.parseKeyLine('# a comment'), isNull);
      expect(DomainsController.parseKeyLine('   '), isNull);
      expect(DomainsController.parseKeyLine(''), isNull);
      expect(DomainsController.parseKeyLine('onlyhost'), isNull);
    });

    test('returns null for a comment line rather than reading prose as a key type',
        () {
      // known_hosts files carry # comments. The second whitespace-separated
      // field of "# some note" is prose, so parsing it produced a phantom
      // algorithm named after the first word.
      expect(DomainsController.parseKeyLine('# managed by ops'), isNull);
      expect(DomainsController.parseKeyLine('   # indented comment'), isNull);
    });

    test('returns null for @cert-authority marker lines', () {
      // These are valid known_hosts entries whose fields are shifted by the
      // marker, so field 1 is not an algorithm.
      expect(
        DomainsController.parseKeyLine(
          '@cert-authority *.example.com ssh-rsa AAAAB3',
        ),
        isNull,
      );
    });
  });

  group('DomainsController.parseKeyTypes', () {
    test('extracts the distinct algorithms', () {
      final types = DomainsController.parseKeyTypes([
        'example.com ssh-ed25519 AAAAC3',
        'example.com ssh-rsa AAAAB3',
        'example.com ssh-ed25519 AAAAC3',
      ]);
      expect(types.toSet(), {'ssh-ed25519', 'ssh-rsa'});
      expect(types, hasLength(2), reason: 'duplicates must be collapsed');
    });

    test('skips malformed lines without failing the whole scan', () {
      final types = DomainsController.parseKeyTypes([
        'example.com ssh-ed25519 AAAAC3',
        '# comment',
        'garbage',
        'example.com ecdsa-sha2-nistp256 AAAA',
      ]);
      expect(types.toSet(), {'ssh-ed25519', 'ecdsa-sha2-nistp256'});
    });

    test('does not turn comment prose into an algorithm', () {
      final types = DomainsController.parseKeyTypes([
        'example.com ssh-ed25519 AAAAC3',
        '# rotated by ops on tuesday',
      ]);
      expect(types, isNot(contains('rotated')));
      expect(types.toSet(), {'ssh-ed25519'});
    });

    test('returns an empty list for empty input', () {
      // This is the "Unreachable" path: no keys found means the host did not
      // answer, not that the parse failed.
      expect(DomainsController.parseKeyTypes([]), isEmpty);
    });
  });

  group('DomainsController lifecycle', () {
    test('starts empty and undisposed-safe', () {
      final controller = DomainsController();
      addTearDown(controller.dispose);

      expect(controller.knownHosts, isEmpty);
      expect(controller.configText, isEmpty);
      expect(controller.isLoading, isFalse);
      expect(controller.isEditing, isFalse);
      expect(controller.isHostsLoading, isFalse);
      expect(controller.isScanning, isFalse);
      expect(controller.hasAnyCheckInFlight, isFalse);
      expect(controller.hostStatus('nothing'), isNull);
      expect(controller.isChecking('nothing'), isFalse);
    });

    test('editing mode round-trips', () {
      final controller = DomainsController();
      addTearDown(controller.dispose);

      expect(controller.isEditing, isFalse);
      controller.beginEditing();
      expect(controller.isEditing, isTrue);
      controller.cancelEditing();
      expect(controller.isEditing, isFalse);
    });

    test('shortPath leaves paths outside ~/.ssh untouched', () {
      // Only paths under the ssh directory are abbreviated; shortening any
      // other path would misrepresent it.
      final controller = DomainsController();
      addTearDown(controller.dispose);

      expect(controller.shortPath(r'C:\Windows\System32\foo'),
          r'C:\Windows\System32\foo');
    });

    test('dispose does not throw', () {
      expect(DomainsController().dispose, returnsNormally);
    });
  });
}
