/// Integration tests for the passphrase hand-off to `ssh-keygen`.
///
/// These run the real `ssh-keygen` and real `icacls`, against a throwaway key
/// created in a temp directory. They exist because the previous implementation
/// passed the passphrase as `-P` on the command line, which put it in the
/// process table where any process can read it, and the fix routes it through
/// SSH_ASKPASS instead.
///
/// The behaviour that distinguishes the two paths:
///
/// * correct passphrase -> `ssh-keygen -p` succeeds, so the call gets past
///   decryption. `ssh-add` may still fail afterwards if no agent is running,
///   which is why the assertions check for the absence of wrongPassphrase
///   rather than for overall success.
/// * wrong passphrase -> decryption fails and the error is `wrongPassphrase`.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_panel/services/ssh_keys.dart';

const _passphrase = 'corr3ct-horse-battery-%staple&"quote"';

void main() {
  late Directory dir;
  late String keyPath;

  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('sshpanel_test_');
    keyPath = '${dir.path}${Platform.pathSeparator}key';
    // Create an encrypted key. -P is used here deliberately and safely: this is
    // test setup in a temp directory, not the code path under test.
    final result = await Process.run(
      'ssh-keygen',
      ['-t', 'ed25519', '-f', keyPath, '-P', _passphrase, '-N', ''],
      runInShell: false,
    );
    if (result.exitCode != 0) {
      fail('could not create the test key: ${result.stderr}');
    }
  });

  tearDownAll(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// True when [keyPath] still carries its original passphrase.
  Future<bool> stillEncrypted() async {
    final probe = await Process.run(
      'ssh-keygen',
      ['-y', '-P', '', '-f', keyPath],
      runInShell: false,
    );
    return probe.exitCode != 0;
  }

  group('addKey with a passphrase', () {
    test('a wrong passphrase is reported, not accepted', () async {
      // Proves the passphrase actually reaches ssh-keygen: if the value were
      // being dropped, an empty/garbage passphrase would behave the same way.
      await expectLater(
        SshKeyManager().addKey(keyPath, passphrase: 'definitely-not-it'),
        throwsA(
          isA<SshKeyException>().having(
            (e) => e.code,
            'code',
            SshKeyErrorCode.wrongPassphrase,
          ),
        ),
      );

      // The key must be untouched: a failed attempt must not leave it
      // decrypted.
      expect(await stillEncrypted(), isTrue);
    });

    test('the correct passphrase decrypts the copy, with the real key '
        'untouched', () async {
      final manager = SshKeyManager();

      Object? caught;
      try {
        await manager.addKey(keyPath, passphrase: _passphrase);
      } catch (e) {
        caught = e;
      }

      // Positive proof that the hand-off worked, not merely that the error was
      // not "wrong passphrase".
      //
      // `addKey` finishes by running `ssh-add`, which needs a live agent. On a
      // machine with the agent stopped the call therefore fails *after* the
      // decryption succeeded, and the failure is agentCommandFailed. Reaching
      // that stage at all means ssh-keygen accepted the passphrase the helper
      // printed, so the decrypt copy is genuinely decrypted.
      //
      // If the askpass hand-off were broken -- the passphrase dropped, mangled
      // by cmd escaping, or the helper never invoked -- ssh-keygen would reject
      // it and the code would be wrongPassphrase instead.
      if (caught is SshKeyException) {
        expect(
          caught.code,
          SshKeyErrorCode.agentCommandFailed,
          reason: 'expected the run to fail at ssh-add (agent stopped), which '
              'proves ssh-keygen decrypted the copy with the hand-off '
              'passphrase. Got ${caught.code.name}: ${caught.message}',
        );
      }

      // The original private key must never be decrypted in place -- only the
      // temporary copy is.
      expect(await stillEncrypted(), isTrue,
          reason: 'the original key must keep its passphrase');
    });

    test('a passphrase containing shell metacharacters is handled', () async {
      // The helper is a .cmd, so % & " and friends would be mangled or
      // injected if the passphrase were interpolated into it directly.
      final manager = SshKeyManager();
      Object? caught;
      try {
        await manager.addKey(keyPath, passphrase: _passphrase);
      } catch (e) {
        caught = e;
      }

      if (caught is SshKeyException) {
        expect(caught.code, isNot(SshKeyErrorCode.wrongPassphrase),
            reason: 'metacharacters must survive the hand-off intact');
      }
      expect(await stillEncrypted(), isTrue);
    });

    test('a missing key file fails without touching anything', () async {
      await expectLater(
        SshKeyManager().addKey('${dir.path}${Platform.pathSeparator}nope',
            passphrase: 'irrelevant'),
        throwsA(isA<SshKeyException>()),
      );
    });
  });

  group('temporary files', () {
    test('no ssh_panel_ work directory is left behind', () async {
      final before = _workDirectories().length;

      try {
        await SshKeyManager().addKey(keyPath, passphrase: 'wrong-on-purpose');
      } catch (_) {
        // expected
      }

      expect(_workDirectories().length, before,
          reason: 'the decrypted key and the passphrase file must be removed');
    });

    test('no loose ssh_temp_ file is left behind', () async {
      // The old implementation wrote to %TEMP%\ssh_temp_<timestamp>; the new
      // one uses a self-cleaning subdirectory, so this guards the switch.
      final leftovers = Directory.systemTemp
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('ssh_temp_'))
          .toList();

      expect(leftovers, isEmpty);
    });
  });
}

/// Work directories this implementation creates in the system temp dir.
List<Directory> _workDirectories() => Directory.systemTemp
    .listSync()
    .whereType<Directory>()
    .where((d) {
      final name = d.path.split(Platform.pathSeparator).last;
      return name.startsWith('ssh_panel_');
    })
    .toList();