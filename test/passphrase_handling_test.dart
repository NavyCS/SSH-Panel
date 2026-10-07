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
///
/// And the generation path, which has the same hand-off but a nastier failure
/// mode: a broken hand-off is silent — ssh-keygen either exits 0 and writes an
/// *unencrypted* key, or blocks on stdin until the timeout — so the assertions
/// there check the produced key itself, plus the argv (the passphrase must not
/// be in it) and the absence of helper leftovers.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_panel/services/ssh_keys.dart';

const _passphrase = 'corr3ct-horse-battery-%staple&"quote"';

void main() {
  late Directory dir;
  late String keyPath;
  late String sshDir;

  /// Keys created in the real `~/.ssh` by the generation tests, removed again
  /// after every test. `USERPROFILE` cannot be redirected from inside the test
  /// process, so `generateKey` writes where it always writes.
  final generatedKeys = <String>[];

  setUpAll(() async {
    final userProfile = Platform.environment['USERPROFILE'];
    if (userProfile == null || userProfile.isEmpty) {
      fail('USERPROFILE is not set; generateKey has no directory to write to');
    }
    sshDir = '$userProfile${Platform.pathSeparator}.ssh';

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

  tearDown(() async {
    for (final path in generatedKeys) {
      for (final candidate in [path, '$path.pub']) {
        final file = File(candidate);
        if (await file.exists()) {
          await file.delete();
        }
      }
    }
    generatedKeys.clear();
  });

  /// A key name that cannot collide with a real key of the user.
  String uniqueName() =>
      'sshpanel_test_${pid}_${DateTime.now().microsecondsSinceEpoch}';

  /// The full path [name] has inside the real `~/.ssh`.
  String pathFor(String name) => '$sshDir${Platform.pathSeparator}$name';

  /// Exit code of `ssh-keygen -y -P <passphrase>` on the key at [path];
  /// 0 means the passphrase opened it.
  Future<int> probe(String path, String passphrase) async {
    final result = await Process.run(
      'ssh-keygen',
      ['-y', '-P', passphrase, '-f', path],
      runInShell: false,
    );
    return result.exitCode;
  }

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

  group('generateKey with a passphrase', () {
    test('the generated key really is encrypted by the new path', () async {
      final name = uniqueName();
      final path = pathFor(name);
      generatedKeys.add(path);

      await SshKeyManager().generateKey(
        name: name,
        passphrase: _passphrase,
        comment: 'sshpanel generation test',
      );

      // A broken hand-off is silent: ssh-keygen either exits 0 and writes an
      // *unencrypted* key, or blocks on stdin until the timeout. So the only
      // real evidence that the helper supplied the passphrase is the produced
      // key itself.
      expect(await probe(path, ''), isNot(0),
          reason: 'ssh-keygen -y -P "" must be rejected: the key has to be '
              'encrypted, which only happens if the helper really supplied '
              'the passphrase during generation');

      expect(await probe(path, _passphrase), 0,
          reason: 'the passphrase -- % & " included -- must open the key, so '
              'it reached ssh-keygen intact');
    });

    test('the passphrase never reaches the argument vector', () {
      final args = SshKeyManager().buildGenerateKeyArgs(
        stagingKey: 'C:\\Users\\x\\.ssh\\id_ed25519.sshpanel-tmp-0',
        algorithm: KeyAlgorithm.ed25519,
        passphrase: _passphrase,
        comment: 'someone@example.com',
      );

      expect(args, isNotEmpty);
      for (final arg in args) {
        expect(arg, isNot(equals(_passphrase)),
            reason: 'no argv element may be the passphrase: $args');
        expect(arg.contains(_passphrase), isFalse,
            reason: 'no argv element may contain the passphrase: $args');
      }
      expect(args, isNot(contains('-P')),
          reason: 'with a passphrase present, -P must be gone from the argv, '
              'because it would carry the secret into the process table: '
              '$args');

      // Without a passphrase the empty form survives: an empty argument is
      // not a secret, and it is what tells ssh-keygen not to prompt.
      final withoutPassphrase = SshKeyManager().buildGenerateKeyArgs(
        stagingKey: 'C:\\Users\\x\\.ssh\\id_ed25519.sshpanel-tmp-1',
        algorithm: KeyAlgorithm.rsa,
        passphrase: null,
      );
      final pIndex = withoutPassphrase.indexOf('-P');
      expect(pIndex, greaterThanOrEqualTo(0),
          reason: 'the empty-passphrase branch still uses -P: '
              '$withoutPassphrase');
      expect(withoutPassphrase[pIndex + 1], '',
          reason: 'and it passes the empty string, not a value');
    });

    test('the askpass helper only prints a sibling passphrase file', () {
      // Pinned byte-for-byte: the helper must stay a `type` of the sibling
      // file, so the passphrase can never be interpolated into it -- %, & and
      // " would otherwise be mangled or injected by cmd.
      expect(SshKeyManager.askpassHelperScript,
          '@echo off\r\ntype "%~dp0passphrase.txt"\r\n');
      expect(SshKeyManager.askpassHelperScript.contains(_passphrase), isFalse,
          reason: 'the passphrase must never be written into the helper');
    });

    test('no passphrase: unencrypted key and no helper file', () async {
      final dirsBefore = _workDirectories().length;
      final name = uniqueName();
      final path = pathFor(name);
      generatedKeys.add(path);

      await SshKeyManager().generateKey(name: name);

      expect(await probe(path, ''), 0,
          reason: 'a key generated without a passphrase must be openable '
              'with an empty one');
      expect(_workDirectories().length, dirsBefore,
          reason: 'the empty-passphrase branch must not create a temporary '
              'helper directory at all');
      expect(_passphraseArtifacts(), isEmpty,
          reason: 'no passphrase.txt / askpass.cmd may be created when there '
              'is no passphrase');
    });
  });

  group('temporary files', () {
    test('no ssh_panel_ work directory is left behind', () async {
      final before = _workDirectories().length;

      await expectLater(
        SshKeyManager().addKey(keyPath, passphrase: 'wrong-on-purpose'),
        throwsA(isA<SshKeyException>()),
        reason: 'this test only means anything if the call actually fails: '
            'the leftover-file assertion below is about cleanup after a '
            'failure, and a silent catch would let it pass vacuously',
      );

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

    test('a generation leaves no passphrase file or staged key behind',
        () async {
      final dirsBefore = _workDirectories().length;
      final name = uniqueName();
      final path = pathFor(name);
      generatedKeys.add(path);

      await SshKeyManager().generateKey(
        name: name,
        passphrase: _passphrase,
      );

      expect(_workDirectories().length, dirsBefore,
          reason: 'the askpass directory holding passphrase.txt and '
              'askpass.cmd must be deleted on the success path');
      expect(_passphraseArtifacts(), isEmpty,
          reason: 'neither the passphrase file nor the helper may survive');
      expect(_stagingLeftovers(sshDir), isEmpty,
          reason: 'the staged key must have been renamed, not left in '
              '~/.ssh');
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

/// The `passphrase.txt` / `askpass.cmd` files that still exist — loose in the
/// system temp dir or inside a surviving `ssh_panel_` work directory.
List<File> _passphraseArtifacts() {
  final found = <File>[];
  for (final entry in Directory.systemTemp.listSync()) {
    if (entry is! File) continue;
    final name = entry.path.split(Platform.pathSeparator).last;
    if (name == 'passphrase.txt' || name == 'askpass.cmd') found.add(entry);
  }
  for (final workDir in _workDirectories()) {
    for (final entry in workDir.listSync()) {
      if (entry is! File) continue;
      final name = entry.path.split(Platform.pathSeparator).last;
      if (name == 'passphrase.txt' || name == 'askpass.cmd') found.add(entry);
    }
  }
  return found;
}

/// Staged key files a generation left behind in [sshDir].
List<File> _stagingLeftovers(String sshDir) {
  final directory = Directory(sshDir);
  if (!directory.existsSync()) return [];
  return directory
      .listSync()
      .whereType<File>()
      .where((f) => f.path.contains('.sshpanel-tmp-'))
      .toList();
}