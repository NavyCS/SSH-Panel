/// Tests for [DomainsController]'s parsing helpers.
///
/// These are the parts that were previously unreachable: the key-type parsing
/// was inlined inside a `State` method that also opened dialogs, so it could
/// only be exercised by driving the whole tab against a real `~/.ssh`.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_panel/features/domains/domains_controller.dart';
import 'package:ssh_panel/services/ssh_domains.dart';

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

  group('DomainsController.addKnownHostKeys reports whether it worked', () {
    // The controller swallows a failed write after showing an error toast, so
    // the caller cannot tell success from failure unless it is told. It used to
    // return nothing, and the caller announced success unconditionally: the
    // user was told their keys were stored when they were not, and the host
    // they had typed was cleared so they had to scan again.
    late DomainsController controller;

    setUp(() {
      controller = DomainsController(
        configManager: _FakeConfigManager(shouldFail: true),
      );
    });

    tearDown(() => controller.dispose());

    test('returns false when the write throws', () async {
      final written = await controller.addKnownHostKeys('example.com', [
        'example.com ssh-ed25519 AAAAC3',
      ]);
      expect(written, isFalse);
    });

    test('returns false for a non-SshConfigException too', () async {
      // The generic catch, not just the expected one: a bad surprise must not
      // read as success either.
      controller = DomainsController(
        configManager: _FakeConfigManager(throwGeneric: true),
      );
      final written = await controller.addKnownHostKeys('example.com', [
        'example.com ssh-ed25519 AAAAC3',
      ]);
      expect(written, isFalse);
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

    test('cancelEditing leaves edit mode and reports the on-disk text', () {
      // Cancel must restore what is on disk, not a cached copy: something
      // else may have rewritten the file since the last refresh.
      final controller = DomainsController();
      addTearDown(controller.dispose);

      controller.beginEditing();
      final restored = controller.cancelEditing();

      expect(controller.isEditing, isFalse);
      expect(restored, isA<String>());
      expect(restored, controller.configText);
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

/// Stands in for [SshConfigManager] with a write that fails.
///
/// Only the one method the controller calls on this path is overridden. The
/// controller takes its manager by constructor argument precisely so this can
/// be tested, and overriding beats redirecting `USERPROFILE` at the real
/// `~/.ssh/known_hosts`.
class _FakeConfigManager implements SshConfigManager {
  _FakeConfigManager({this.shouldFail = false, this.throwGeneric = false});

  /// Throw the expected [SshConfigException].
  final bool shouldFail;

  /// Throw something the controller does not specifically expect.
  final bool throwGeneric;

  @override
  Future<void> writeKnownHostKeys(String host, List<String> keyLines) async {
    if (throwGeneric) throw const FormatException('unexpected');
    if (shouldFail) {
      throw SshConfigException(
        SshConfigErrorCode.writeFailed,
        'Failed to write ~/.ssh/known_hosts.',
      );
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not used here');
}
