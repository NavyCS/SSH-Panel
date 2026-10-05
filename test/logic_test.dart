/// Regression tests for the pieces of logic that had no coverage at all.
///
/// Scope is deliberately limited to pure, deterministic logic that can be
/// exercised without launching processes, touching the real `~/.ssh`
/// directory, or depending on the SCM state of the machine.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_panel/services/cancellation.dart';
import 'package:ssh_panel/services/ssh_domains.dart';
import 'package:ssh_panel/services/ssh_keys.dart';

void main() {
  group('CancellationToken', () {
    test('starts uncancelled', () {
      expect(CancellationToken().isCancelled, isFalse);
    });

    test('cancel() is idempotent', () {
      final token = CancellationToken();
      token
        ..cancel()
        ..cancel();
      expect(token.isCancelled, isTrue);
    });

    test('cancel before the loop starts is observable', () {
      final token = CancellationToken()..cancel();
      expect(token.isCancelled, isTrue);
    });
  });

  group('CancellationTokenCancelled', () {
    test('defaults its description', () {
      expect(const CancellationTokenCancelled().toString(),
          'The operation was cancelled.');
    });

    test('names what was cancelled', () {
      expect(
        const CancellationTokenCancelled('Starting the ssh-agent service')
            .toString(),
        'Starting the ssh-agent service was cancelled.',
      );
    });
  });

  group('SshKeyException', () {
    test('toString includes the code and message', () {
      final e = SshKeyException(
        SshKeyErrorCode.keygenFailed,
        'The key file already exists.',
      );
      expect(e.toString(), contains('keygenFailed'));
      expect(e.toString(), contains('The key file already exists.'));
    });

    test('toString appends rawDetail only when present', () {
      final without = SshKeyException(
        SshKeyErrorCode.keygenFailed,
        'Failed.',
      );
      final with_ = SshKeyException(
        SshKeyErrorCode.keygenFailed,
        'Failed.',
        rawDetail: 'exit code 255',
      );
      expect(without.toString(), isNot(contains('exit code 255')));
      expect(with_.toString(), contains('exit code 255'));
    });

    test('keeps message separate from rawDetail', () {
      // The UI renders `message` only. rawDetail exists for diagnostics and
      // must never be the string shown to the user.
      final e = SshKeyException(
        SshKeyErrorCode.commandNotFound,
        r'ssh-keygen is not installed or not found on PATH.',
        rawDetail: r'OSError: file not found, path C:\Windows\System32\ssh-keygen.exe',
      );
      expect(e.message, contains('not installed'));
      expect(e.message, isNot(contains('System32')));
    });
  });

  group('SshConfigException', () {
    test('toString includes the code and message', () {
      final e = SshConfigException(
        SshConfigErrorCode.readFailed,
        'Could not read the config file.',
      );
      expect(e.toString(), contains('readFailed'));
      expect(e.toString(), contains('Could not read the config file.'));
    });

    test('keeps message separate from rawDetail', () {
      final e = SshConfigException(
        SshConfigErrorCode.writeFailed,
        'Could not write the config file.',
        rawDetail: r'C:\Users\me\.ssh\config',
      );
      expect(e.message, isNot(contains(r'.ssh')));
    });
  });

  group('SshConfigManager.isValidHost', () {
    // Rejects: empty, whitespace, embedded space, user@host, :port, schemes,
    // path separators and command characters. This validation is what keeps
    // arbitrary hostnames from reaching `ssh-keyscan` argv.
    bool valid(String host) => SshConfigManager.isValidHost(host);

    test('accepts plain hostnames', () {
      expect(valid('example.com'), isTrue);
      expect(valid('localhost'), isTrue);
      expect(valid('a'), isTrue);
      expect(valid('my-server'), isTrue);
      expect(valid('host.sub.domain.example.com'), isTrue);
    });

    test('accepts IPv4 addresses', () {
      expect(valid('192.168.1.1'), isTrue);
      expect(valid('8.8.8.8'), isTrue);
    });

    test('rejects empty or whitespace-only input', () {
      expect(valid(''), isFalse);
      expect(valid('   '), isFalse);
    });

    test('rejects the user@host and host:port forms ssh-keyscan rejects', () {
      // `ssh-keyscan user@host` and `host:port` silently scan the wrong thing,
      // so they are rejected up front.
      expect(valid('user@example.com'), isFalse);
      expect(valid('example.com:2222'), isFalse);
    });

    test('rejects path separators', () {
      expect(valid(r'example.com\..\windows'), isFalse);
      expect(valid(r'example.com/../windows'), isFalse);
    });

    test('rejects shell metacharacters', () {
      // Defense in depth: the process is launched without a shell, but a host
      // name containing these should never be accepted.
      expect(valid('example.com;whoami'), isFalse);
      expect(valid(r'example.com&calc'), isFalse);
      expect(valid(r'example.com|calc'), isFalse);
      expect(valid(r'example.com`calc`'), isFalse);
      expect(valid(r'example.com$(whoami)'), isFalse);
    });

    test('rejects a URL scheme', () {
      expect(valid('http://example.com'), isFalse);
      expect(valid('ssh://example.com'), isFalse);
    });
  });
}
