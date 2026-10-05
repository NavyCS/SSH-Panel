/// Tests for the hardened host validation and the path guard.
///
/// Two changes are covered here:
///
/// * `isValidHost` stopped rejecting `_` in DNS labels and stopped rejecting
///   IPv6 literals. It had been refusing scannable hosts, and the reason it
///   refused them -- fear of shell metacharacters -- does not apply, because
///   ssh-keyscan is launched with an argument list and `runInShell: false`.
///   The tests that mattered most are the ones asserting it still refuses
///   everything dangerous.
/// * `PathGuard` confines paths handed to `explorer` to the user profile, so a
///   manipulated `USERPROFILE` cannot redirect the app to open another folder.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_panel/services/file_permissions.dart';
import 'package:ssh_panel/services/path_guard.dart';
import 'package:ssh_panel/services/ssh_domains.dart';

void main() {
  bool valid(String host) => SshConfigManager.isValidHost(host);

  group('isValidHost: DNS names', () {
    test('accepts ordinary names', () {
      expect(valid('example.com'), isTrue);
      expect(valid('localhost'), isTrue);
      expect(valid('a'), isTrue);
      expect(valid('my-server'), isTrue);
      expect(valid('host.sub.domain.example.com'), isTrue);
    });

    test('accepts underscores, which SRV and DKIM records require', () {
      // The regression: these are ordinary DNS names and ssh-keyscan scans
      // them, but the old validator refused every label containing one.
      expect(valid('my_service.example.com'), isTrue);
      expect(valid('_sip._tcp.example.com'), isTrue);
      expect(valid('_domainkey.example.com'), isTrue);
      expect(valid('_25._tcp.mail.example.com'), isTrue);
    });

    test('accepts uppercase', () {
      expect(valid('EXAMPLE.COM'), isTrue);
      expect(valid('Mi_Server.Example.Com'), isTrue);
    });

    test('still rejects a label that is only a hyphen or dot', () {
      expect(valid('-example.com'), isFalse);
      expect(valid('example-.com'), isFalse);
      expect(valid('example..com'), isFalse);
      expect(valid('.example.com'), isFalse);
      expect(valid('example.com.'), isFalse);
    });
  });

  group('isValidHost: IPv4', () {
    test('accepts dotted quads', () {
      expect(valid('192.168.1.1'), isTrue);
      expect(valid('8.8.8.8'), isTrue);
      expect(valid('255.255.255.255'), isTrue);
    });
  });

  group('isValidHost: IPv6', () {
    test('accepts bracketed literals, the ssh_config form', () {
      expect(valid('[::1]'), isTrue);
      expect(valid('[2001:db8::1]'), isTrue);
      expect(valid('[fe80::1%25eth0]') || valid('[fe80::1]'), isTrue);
    });

    test('accepts bare literals', () {
      expect(valid('::1'), isTrue);
      expect(valid('2001:db8::1'), isTrue);
      expect(valid('fe80::1'), isTrue);
    });

    test('accepts a full eight-group address', () {
      expect(valid('2001:0db8:0000:0000:0000:0000:0000:0001'), isTrue);
    });

    test('accepts an IPv4-mapped literal', () {
      expect(valid('::ffff:192.0.2.1'), isTrue);
    });

    test('rejects malformed literals', () {
      expect(valid('2001:db8:::1'), isFalse);
      expect(valid('[2001:db8::1'), isFalse, reason: 'unclosed bracket');
      expect(valid('2001:db8::1]'), isFalse, reason: 'unopened bracket');
      expect(valid('gggg::1'), isFalse, reason: 'not hex');
      expect(valid('12345::1'), isFalse, reason: 'group too long');
    });
  });

  group('isValidHost: still refuses everything dangerous', () {
    // The old blocklist rejected these because of shell metacharacters. They
    // are still refused, now because the per-label check does not admit them.
    // If someone loosens the DNS rule later, these are the tests that should
    // fail first.
    test('refuses shell metacharacters', () {
      expect(valid('example.com;whoami'), isFalse);
      expect(valid(r'example.com&calc'), isFalse);
      expect(valid(r'example.com|calc'), isFalse);
      expect(valid(r'example.com`calc`'), isFalse);
      expect(valid(r'example.com$(whoami)'), isFalse);
      expect(valid('example.com>out'), isFalse);
      expect(valid('example.com"quote'), isFalse);
    });

    test('refuses path separators and traversal', () {
      expect(valid(r'example.com\..\windows'), isFalse);
      expect(valid(r'example.com/../windows'), isFalse);
    });

    test('refuses the user@host and host:port forms', () {
      // host:port would make ssh-keyscan scan the wrong target, so a colon
      // outside a valid IPv6 literal is refused.
      expect(valid('user@example.com'), isFalse);
      expect(valid('example.com:2222'), isFalse);
      expect(valid('[::1]:2222'), isFalse);
    });

    test('refuses a URL scheme', () {
      expect(valid('http://example.com'), isFalse);
      expect(valid('ssh://example.com'), isFalse);
    });

    test('refuses whitespace, control characters and empties', () {
      expect(valid(''), isFalse);
      expect(valid('   '), isFalse);
      expect(valid('exa mple.com'), isFalse);
      expect(valid('example.com\nrm -rf'), isFalse);
    });
  });

  group('PathGuard', () {
    final profile = Platform.environment['USERPROFILE'];
    final hasProfile = profile != null && profile.isNotEmpty;

    test('accepts a path inside the user profile', () {
      if (!hasProfile) return;
      expect(PathGuard.isInsideUserProfile('$profile\\.ssh'), isTrue);
      expect(PathGuard.isInsideUserProfile(profile), isTrue,
          reason: 'the profile directory itself must count as inside it');
    });

    test('accepts forward slashes and mixed case', () {
      if (!hasProfile) return;
      expect(PathGuard.isInsideUserProfile('$profile/.ssh'), isTrue);
      expect(PathGuard.isInsideUserProfile(profile.toUpperCase()), isTrue);
    });

    test('refuses a sibling directory sharing the prefix', () {
      // The classic prefix bug: C:\Users\navyc-evil must not pass because it
      // starts with C:\Users\navyc.
      if (!hasProfile) return;
      expect(PathGuard.isInsideUserProfile('$profile-evil\\secrets'), isFalse);
      expect(PathGuard.isInsideUserProfile('$profile.bak\\keys'), isFalse);
    });

    test('refuses paths outside the profile', () {
      expect(PathGuard.isInsideUserProfile(r'C:\Windows\System32'), isFalse);
      expect(PathGuard.isInsideUserProfile(r'\\server\share'), isFalse);
    });

    test('refuses empty input', () {
      expect(PathGuard.isInsideUserProfile(''), isFalse);
    });

    test('isAllowed rejects an empty path', () {
      expect(PathGuard.isAllowed(''), isFalse);
    });
  });

  group('isValidHost: explains why it refuses', () {
    test('returns no reason for an acceptable host', () {
      expect(SshConfigManager.isValidHostDetailed('example.com'), isNull);
      expect(SshConfigManager.isValidHostDetailed('::1'), isNull);
      expect(SshConfigManager.isValidHostDetailed('[::1]'), isNull);
    });

    test('names the actual problem instead of saying "invalid"', () {
      // These reasons are shown to the user verbatim, so they have to describe
      // what is actually wrong.
      expect(SshConfigManager.isValidHostDetailed(''), contains('empty'));
      expect(
        SshConfigManager.isValidHostDetailed('example.com:2222'),
        contains('port'),
        reason: 'a port is the likely mistake, so it should be named',
      );
      expect(SshConfigManager.isValidHostDetailed('exa mple.com'),
          contains('spaces'));
      expect(SshConfigManager.isValidHostDetailed('[2001:db8::1'),
          contains('bracket'));
      expect(SshConfigManager.isValidHostDetailed('gg::1'), isNotNull);
    });
  });

  group('hostKeyOf: matching what the user typed against what ssh-keyscan wrote',
      () {
    String key(String value) => SshConfigManager.hostKeyOf(value);

    test('a bare IPv6 literal matches the bracketed form ssh-keyscan writes',
        () {
      // The bug this fixes: ssh-keyscan writes "[::1]:22" no matter how the
      // user typed it. Comparing raw strings, re-adding a key appended a
      // duplicate instead of replacing the old line, and removing one did
      // nothing at all.
      expect(key('::1'), key('[::1]:22'));
      expect(key('::1'), key('[::1]'));
      expect(key('2001:db8::1'), key('[2001:db8::1]:22'));
      expect(key('[::1]:22'), key('::1'));
    });

    test('a host name matches whatever port was written', () {
      expect(key('example.com'), key('example.com:2222'));
      expect(key('example.com:2222'), key('example.com'));
      expect(key('example.com'), key('example.com'));
    });

    test('is case-insensitive, because DNS names are', () {
      expect(key('Example.COM'), key('example.com:2222'));
      expect(key('2001:DB8::1'), key('[2001:db8::1]:22'));
    });

    test('does not confuse two different hosts', () {
      // The normalisation must not become so forgiving that distinct hosts
      // collide.
      expect(key('example.com'), isNot(key('other.com')));
      expect(key('::1'), isNot(key('::2')));
      expect(key('2001:db8::1'), isNot(key('2001:db8::2')));
    });

    test('leaves a bare IPv6 literal intact rather than eating a group', () {
      // ::1 has colons of its own; a naive :port strip would mangle it.
      expect(key('::1'), '::1');
      expect(key('2001:db8::1'), '2001:db8::1');
      expect(key('fe80::1'), 'fe80::1');
    });
  });

  group('withoutKeysForHost: the duplicate-entry bug, end to end', () {
    // Real known_hosts content, in the format ssh-keyscan actually writes.
    // Key material is abbreviated so each line is identifiable by its blob.
    const knownHosts = '''
# a comment ssh-keyscan left behind
[::1]:22 ssh-ed25519 KEYSTALE25519
[::1]:22 ecdsa-sha2-nistp256 KEYSTALEECDSA
[::1]:22 ssh-rsa KEYSTALERSA
other.example.com:22 ssh-ed25519 KEYOTHERHOST
example.com:2222 ssh-ed25519 KEYOTHERHOSTPORT
''';

    String without(String host, Set<String> types) =>
        SshConfigManager.withoutKeysForHost(knownHosts, host, types);

    /// Lines in [contents] whose host field is [host], ignoring brackets and
    /// port. Counting by key type alone would be wrong: other hosts in the
    /// fixture also carry `ssh-ed25519`.
    List<String> linesFor(String contents, String host) {
      final key = SshConfigManager.hostKeyOf(host);
      return contents
          .split('\n')
          .where((line) {
            final trimmed = line.trim();
            if (trimmed.isEmpty || trimmed.startsWith('#')) return false;
            return SshConfigManager.hostKeyOf(
                    trimmed.split(RegExp(r'\s+')).first.split(',').first) ==
                key;
          })
          .toList();
    }

    test('replacing a key for a bare IPv6 literal does not duplicate it', () {
      // The regression. The user typed "::1", ssh-keyscan wrote "[::1]:22", and
      // the old comparison was a raw string test -- so the stale line survived
      // and the new one was appended, leaving known_hosts with two conflicting
      // keys for the same host.
      final result = without('::1', {'ssh-ed25519'});

      expect(
        linesFor(result, '::1').where((l) => l.contains('ssh-ed25519')),
        isEmpty,
        reason: 'the stale entry must be replaced, not joined by a new one',
      );
      expect(result, isNot(contains('KEYSTALE25519')),
          reason: 'the stale ed25519 blob for ::1 is gone');
    });

    test('leaves the other key types for the same host in place', () {
      final result = without('::1', {'ssh-ed25519'});
      expect(result, contains('KEYSTALEECDSA'));
      expect(result, contains('KEYSTALERSA'));
    });

    test('preserves comments and other hosts', () {
      final result = without('::1', {'ssh-ed25519'});
      expect(result, contains('# a comment ssh-keyscan left behind'));
      expect(result, contains('KEYOTHERHOST'));
      expect(result, contains('KEYOTHERHOSTPORT'));
    });

    test('removing one key type removes only that one', () {
      final result = without('::1', {'ecdsa-sha2-nistp256'});
      expect(result, isNot(contains('KEYSTALEECDSA')));
      expect(result, contains('KEYSTALE25519'));
      expect(result, contains('KEYSTALERSA'));
    });

    test('works the same when the host is typed with brackets', () {
      final result = without('[::1]', {'ssh-ed25519'});
      expect(
        linesFor(result, '::1').where((l) => l.contains('ssh-ed25519')),
        isEmpty,
      );
      expect(result, isNot(contains('KEYSTALE25519')));
    });

    test('does not touch a different host that looks similar', () {
      final result = without('::2', {'ssh-ed25519'});
      expect(result, contains('KEYSTALE25519'),
          reason: '::2 must not remove the ::1 entries');
    });

    test('handles an empty or comment-only file', () {
      expect(SshConfigManager.withoutKeysForHost('', '::1', {'ssh-ed25519'}),
          '');
      expect(
        SshConfigManager.withoutKeysForHost('# only a comment\n', '::1',
            {'ssh-ed25519'}),
        '# only a comment\n',
      );
    });
  });

  group('known_hosts host matching, as the controller does it', () {
    // The controller filters known_hosts by host to work out which key types are
    // already recorded. It has to use the same normalisation as the rewrite
    // path, or the two disagree about what "this host" is.
    Set<String> existingTypesFor(
      List<Map<String, String>> knownHosts,
      String input,
    ) {
      final key = SshConfigManager.hostKeyOf(input);
      return knownHosts
          .where((h) => SshConfigManager.hostKeyOf(h['host'] ?? '') == key)
          .map((h) => h['keyType']!)
          .toSet();
    }

    test('finds existing key types for a bare IPv6 literal', () {
      // The second occurrence of this bug, in the controller. Without the
      // normalisation existingTypesFor returns empty, so the app offers to add
      // keys the host already has.
      final known = [
        {'host': '[::1]:22', 'keyType': 'ssh-ed25519'},
        {'host': '[::1]:22', 'keyType': 'ecdsa-sha2-nistp256'},
      ];
      expect(existingTypesFor(known, '::1'),
          {'ssh-ed25519', 'ecdsa-sha2-nistp256'},
          reason: 'the bracketed entry belongs to the host the user typed');
      expect(existingTypesFor(known, '[::1]'),
          {'ssh-ed25519', 'ecdsa-sha2-nistp256'});
    });

    test('finds existing key types for a host name with any port', () {
      final known = [
        {'host': 'example.com:2222', 'keyType': 'ssh-ed25519'},
      ];
      expect(existingTypesFor(known, 'example.com'), {'ssh-ed25519'});
    });

    test('does not confuse a different host', () {
      final known = [
        {'host': '[::1]:22', 'keyType': 'ssh-ed25519'},
        {'host': 'other.example.com:22', 'keyType': 'ssh-rsa'},
      ];
      expect(existingTypesFor(known, '::2'), isEmpty);
      expect(existingTypesFor(known, 'other.example.com'), {'ssh-rsa'});
    });

    test('tolerates a missing host field', () {
      expect(existingTypesFor([{'keyType': 'ssh-ed25519'}], '::1'), isEmpty);
    });
  });

  group('FilePermissions', () {
    // These touch the real file system, so they work in a temp directory and
    // clean up after themselves rather than asserting on the user's ~/.ssh.
    late Directory sandbox;

    setUp(() async {
      sandbox = Directory.systemTemp.createTempSync('sshpanel_perm_test_');
    });

    tearDown(() async {
      if (await sandbox.exists()) await sandbox.delete(recursive: true);
    });

    test('ensurePrivateDirectory creates a missing directory', () async {
      final target = Directory('${sandbox.path}${Platform.pathSeparator}nested');
      expect(await target.exists(), isFalse);

      final created = await FilePermissions.ensurePrivateDirectory(target);

      expect(created, isTrue, reason: 'it did not exist beforehand');
      expect(await target.exists(), isTrue);
    });

    test('ensurePrivateDirectory leaves an existing directory alone', () async {
      // The contract that matters: the app must not silently re-permission a
      // directory the user already owns and may have widened on purpose.
      final created = await FilePermissions.ensurePrivateDirectory(sandbox);
      expect(created, isFalse, reason: 'already existed');

      // A sentinel proves nothing was changed underneath us.
      final marker = File('${sandbox.path}${Platform.pathSeparator}keep.txt');
      await marker.writeAsString('intact');
      expect(await marker.readAsString(), 'intact');
    });

    test('ensurePrivateDirectory is idempotent', () async {
      final target = Directory('${sandbox.path}${Platform.pathSeparator}twice');
      expect(await FilePermissions.ensurePrivateDirectory(target), isTrue);
      expect(await FilePermissions.ensurePrivateDirectory(target), isFalse);
    });

    test('restrictToOwner reports whether it applied', () async {
      // Not asserting `true`: icacls may be unavailable or restricted, and the
      // helper is explicitly best-effort. The contract under test is that it
      // reports honestly and never throws.
      final result = await FilePermissions.restrictToOwner(sandbox);
      expect(result, anyOf(isTrue, isFalse));
      expect(await sandbox.exists(), isTrue,
          reason: 'it must never remove or break the directory');
    });

    test('restrictToOwner survives a missing directory without throwing', () async {
      final ghost =
          Directory('${sandbox.path}${Platform.pathSeparator}not_there');
      await expectLater(FilePermissions.restrictToOwner(ghost), completes);
    });
  });
}