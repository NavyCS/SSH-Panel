/// SSH config and known_hosts management for Windows.
///
/// Reads and writes the OpenSSH configuration files located at
/// `~/.ssh/config` and `~/.ssh/known_hosts`.  Uses the `USERPROFILE`
/// environment variable to locate the home directory.
///
/// **No SSH connection logic** — this module only manages the text files.
library;

import 'dart:async';
import 'dart:io';

// ---------------------------------------------------------------------------
// Typed error
// ---------------------------------------------------------------------------

/// Error codes produced by [SshConfigManager].
  enum SshConfigErrorCode {
    /// The `USERPROFILE` environment variable is not set.
    userProfileNotSet,

    /// Could not read the file (permission denied, I/O error, etc.).
    readFailed,

    /// Could not write the file (permission denied, I/O error, etc.).
    writeFailed,

    /// `ssh-keyscan` was not found or failed.
    keyscanFailed,

    /// The host name is empty or malformed.
    invalidHost,

    /// The host was not found in known_hosts.
    hostNotFound,
  }

/// A typed exception thrown by [SshConfigManager] methods.  The [code]
/// identifies the category; [message] is a human-readable explanation.
/// [rawDetail] may carry an OS-level detail string (never exposed to the
/// end user directly).
class SshConfigException implements Exception {
  SshConfigException(this.code, this.message, {this.rawDetail});

  final SshConfigErrorCode code;
  final String message;
  final String? rawDetail;

  @override
  String toString() => 'SshConfigException(${code.name}): $message';
}

// ---------------------------------------------------------------------------
// SshConfigManager
// ---------------------------------------------------------------------------

/// Manages the OpenSSH config and known_hosts files on Windows.
///
/// All methods are synchronous — the underlying operations are trivial file
/// reads / writes and do not warrant async overhead.
class SshConfigManager {
  // -----------------------------------------------------------------------
  // Path helpers
  // -----------------------------------------------------------------------

  /// Returns the absolute path to the `~/.ssh` directory.
  ///
  /// Throws [SshConfigException] if `USERPROFILE` is not set.
  String get sshDirectory => _sshDir();

  /// Returns the absolute path to the `~/.ssh` directory.
  ///
  /// Throws [SshConfigException] if `USERPROFILE` is not set.
  String _sshDir() {
    final userProfile = Platform.environment['USERPROFILE'];
    if (userProfile == null || userProfile.isEmpty) {
      throw SshConfigException(
        SshConfigErrorCode.userProfileNotSet,
        'USERPROFILE environment variable is not set.',
      );
    }
    return '$userProfile\\.ssh';
  }

  /// Returns the absolute path to `~/.ssh/config`.
  String get _configPath => '${_sshDir()}\\config';

  /// Returns the absolute path to `~/.ssh/known_hosts`.
  String get knownHostsPath => _knownHostsPath;

  /// Returns the absolute path to `~/.ssh/known_hosts`.
  String get _knownHostsPath => '${_sshDir()}\\known_hosts';

  // -----------------------------------------------------------------------
  // readConfig
  // -----------------------------------------------------------------------

  /// Reads the contents of `~/.ssh/config` as plain text.
  ///
  /// Returns the full file contents as a string.  Returns an empty string
  /// `''` when the file does not exist — **never throws** for a missing
  /// file.
  String readConfig() {
    final file = File(_configPath);
    if (!file.existsSync()) {
      return '';
    }
    try {
      return file.readAsStringSync();
    } on FileSystemException catch (e) {
      throw SshConfigException(
        SshConfigErrorCode.readFailed,
        'Failed to read ~/.ssh/config.',
        rawDetail: e.message,
      );
    }
  }

  // -----------------------------------------------------------------------
  // writeConfig
  // -----------------------------------------------------------------------

  /// Writes [content] to `~/.ssh/config`, replacing the file verbatim.
  ///
  /// This does **not** auto-format or reflow the content — a round-trip
  /// through [readConfig] followed by [writeConfig] preserves bytes.
  ///
  /// Throws [SshConfigException] if the write fails.
  void writeConfig(String content) {
    final file = File(_configPath);
    try {
      // Ensure the ~/.ssh directory exists before writing.
      final dir = file.parent;
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      file.writeAsStringSync(content, mode: FileMode.write);
    } on FileSystemException catch (e) {
      throw SshConfigException(
        SshConfigErrorCode.writeFailed,
        'Failed to write ~/.ssh/config.',
        rawDetail: e.message,
      );
    }
  }

  // -----------------------------------------------------------------------
  // getKnownHosts
  // -----------------------------------------------------------------------

  /// Extracts host entries from `~/.ssh/known_hosts`.
  ///
  /// Each entry in the known_hosts file has the format
  /// `hostname[,hostname2] keytype keydata [comment]`.  This method
  /// returns a list of maps with keys `'host'` and `'keyType'` for
  /// each non-empty line.
  ///
  /// Returns `[]` when the file does not exist or is empty — **never
  /// throws** for a missing or empty file.
  List<Map<String, String>> getKnownHosts() {
    final file = File(_knownHostsPath);
    if (!file.existsSync()) {
      return [];
    }
    try {
      final content = file.readAsStringSync();
      if (content.trim().isEmpty) {
        return [];
      }
      return content
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty && !line.startsWith('#'))
          .map((line) {
            final tokens = line.split(RegExp(r'\s+'));
            final hostField = tokens.isNotEmpty ? tokens[0] : '';
            final host = hostField.split(',').first;
            final keyType = tokens.length > 1 ? tokens[1] : '';
            return <String, String>{'host': host, 'keyType': keyType};
          })
          .toList();
    } on FileSystemException catch (e) {
      throw SshConfigException(
        SshConfigErrorCode.readFailed,
        'Failed to read ~/.ssh/known_hosts.',
        rawDetail: e.message,
      );
    }
  }

  // -----------------------------------------------------------------------
  // addKnownHost
  // -----------------------------------------------------------------------

  /// Validates that [host] is a hostname or IP literal we can hand to
  /// `ssh-keyscan`.
  ///
  /// Accepts three forms:
  ///
  /// * DNS names, including labels with `_`. Underscores are legal in DNS and
  ///   are how SRV and DKIM records are written (`_sip._tcp.example.com`), so
  ///   rejecting them made perfectly scannable hosts impossible to enter.
  /// * IPv4 literals.
  /// * IPv6 literals, bracketed (`[::1]`, the form used in `ssh_config`) or bare
  ///   (`2001:db8::1`).
  ///
  /// A colon outside a valid IPv6 literal is rejected, so `example.com:2222`
  /// does not quietly scan the wrong target.
  ///
  /// This used to reject a list of shell metacharacters outright. That was
  /// defence in depth, and `ssh-keyscan` really is launched with an argument
  /// list and `runInShell: false`, so there is no shell for them to escape
  /// into -- the list only served to reject valid hosts. Characters outside a
  /// hostname are still refused, by the per-label check below.
  ///
  /// This is a cheap client-side guard, not a substitute for reaching the host.
  static bool isValidHost(String host) => isValidHostDetailed(host) == null;

  /// Validates [host], returning `null` when it is acceptable, or a
  /// human-readable reason when it is not.
  ///
  /// The reason is shown to the user, so it names the actual problem rather than
  /// saying "invalid".
  static String? isValidHostDetailed(String host) {
    final reason = _validateHost(host);
    return reason;
  }

  /// Whether a `known_hosts` line should survive a rewrite that is about to
  /// write [keyTypes] for [host].
  ///
  /// A line is dropped only when it is for the same host and for one of the key
  /// types being replaced. Everything else stays: other hosts, other key types
  /// for the same host, and comments.
  ///
  /// Comments and blank lines are returned as `true` by the caller, not here --
  /// this only decides about real entries.
  static bool _keepsLine(String trimmedLine, String hostKey, Set<String> keyTypes) {
    final tokens = trimmedLine.split(RegExp(r'\s+'));
    final lineHost = tokens.first.split(',').first;
    final lineKeyType = tokens.length > 1 ? tokens[1] : '';
    return hostKeyOf(lineHost) != hostKey || !keyTypes.contains(lineKeyType);
  }

  /// Rewrites [contents] with the entries for [host] whose key type is in
  /// [keyTypes] removed.
  ///
  /// Extracted so the matching rule is one implementation used by both the
  /// write and the remove path, and so it can be tested without touching the
  /// user's real `known_hosts`.
  ///
  /// Host comparison goes through [hostKeyOf], which is the point: `ssh-keyscan`
  /// writes `[::1]:22` whatever the user typed, so a raw comparison never
  /// matched and re-adding a key appended a duplicate instead of replacing.
  static String withoutKeysForHost(
    String contents,
    String host,
    Set<String> keyTypes,
  ) {
    final hostKey = hostKeyOf(host);
    final kept = contents
        .split('\n')
        .where((line) {
          final trimmed = line.trim();
          // Preserve comments and blank lines untouched.
          if (trimmed.isEmpty || trimmed.startsWith('#')) return true;
          return _keepsLine(trimmed, hostKey, keyTypes);
        })
        .toList();
    return kept.join('\n');
  }

  /// Reduces a `known_hosts` host field or a user-typed host to a comparable
  /// key, so the two can be matched regardless of formatting.
  ///
  /// `known_hosts` does not store what the user typed. `ssh-keyscan ::1` writes
  /// `[::1]:22`, and a non-default port is written as `host:2222`, so a literal
  /// string comparison against the input silently fails: re-adding a key would
  /// append a duplicate instead of replacing the old line, and removing one
  /// would quietly do nothing. Both call sites use this instead.
  ///
  /// Only the address is kept. The port is dropped, so this matches by host and
  /// key type exactly as the previous code did -- it makes the comparison
  /// forgiving about brackets and port, not about which host is meant.
  static String hostKeyOf(String host) {
    var value = host.trim();
    if (value.startsWith('[')) {
      // Bracketed IPv6: drop the brackets, and the :port if present.
      final close = value.indexOf(']');
      if (close != -1) return value.substring(1, close).toLowerCase();
    }
    // A bare IPv6 literal keeps its colons, so only strip a trailing :port
    // when what precedes it is not itself an address.
    final lastColon = value.lastIndexOf(':');
    if (lastColon > 0) {
      final tail = value.substring(lastColon + 1);
      final isPort = tail.isNotEmpty &&
          int.tryParse(tail) != null &&
          !value.substring(0, lastColon).contains(':');
      if (isPort) value = value.substring(0, lastColon);
    }
    return value.toLowerCase();
  }

  /// Shared validation body. Returns `null` when [host] is acceptable.
  static String? _validateHost(String host) {
    final trimmed = host.trim();
    if (trimmed.isEmpty) return 'The host name is empty.';

    // Whitespace and control characters are never valid.
    if (RegExp(r'[\s\x00-\x1f]').hasMatch(trimmed)) {
      return 'A host name cannot contain spaces or control characters.';
    }

    // Bracketed IPv6 literal, the form ssh_config and ssh-keyscan both accept.
    if (trimmed.startsWith('[')) {
      if (!trimmed.endsWith(']')) {
        return 'An IPv6 literal must close its bracket.';
      }
      if (!_isIpv6Literal(trimmed.substring(1, trimmed.length - 1))) {
        return 'That is not a valid IPv6 address.';
      }
      return null;
    }

    // A colon means it must be an IPv6 literal. `example.com:2222` lands here
    // and fails, which is the intent: ssh-keyscan would otherwise scan
    // something other than what was typed.
    if (trimmed.contains(':')) {
      if (!_isIpv6Literal(trimmed)) {
        return 'Only an IPv6 address may contain a colon; a port is not '
            'accepted here.';
      }
      return null;
    }

    return _isDnsName(trimmed)
        ? null
        : 'Not a valid host name. Use a domain name or an IP address.';
  }

  /// Whether [name] is a dotted hostname whose labels are all valid.
  static bool _isDnsName(String name) {
    if (name.length > 253) return false;
    final labels = name.split('.');
    for (final label in labels) {
      if (label.isEmpty || label.length > 63) return false;
      if (label.startsWith('-') || label.endsWith('-')) return false;
      // Underscore allowed anywhere in a label; it leads SRV/DKIM names.
      if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(label)) return false;
    }
    return true;
  }

  /// Structural check for an IPv6 literal, without an embedded address.
  ///
  /// Not a full RFC 4291 parse: it verifies the shape -- hex groups, colons, at
  /// most one `::` compression, and a bounded group count. That is enough to
  /// separate a real literal from `host:port` or a stray path, which is all this
  /// guard is for.
  static bool _isIpv6Literal(String value) {
    if (value.isEmpty) return false;
    if (!RegExp(r'^[0-9A-Fa-f:.]+$').hasMatch(value)) return false;
    // A colon is mandatory; otherwise this is not an address at all.
    if (!value.contains(':')) return false;
    // `::` compresses zeroes and may appear at most once.
    if ('::'.allMatches(value).length > 1) return false;

    final doubleColon = value.indexOf('::');
    final head = doubleColon == -1 ? value : value.substring(0, doubleColon);
    final tail =
        doubleColon == -1 ? '' : value.substring(doubleColon + 2);

    final headGroups = _ipv6Groups(head);
    final tailGroups = _ipv6Groups(tail);
    if (headGroups == null || tailGroups == null) return false;

    final total = headGroups + tailGroups;
    // Eight groups plus the compressed form; `::` stands for at least one zero.
    return doubleColon == -1 ? total == 8 : total <= 7;
  }

  /// Counts the groups on one side of a `::`, or null when malformed.
  ///
  /// An empty side is legitimate (that is what `::1` and `1::` look like), so
  /// only a stray or repeated separator counts as malformed.
  static int? _ipv6Groups(String side) {
    if (side.isEmpty) return 0;
    if (side.startsWith(':') || side.endsWith(':')) return null;
    final groups = side.split(':');
    for (final group in groups) {
      // An embedded IPv4 tail (`::ffff:192.0.2.1`) counts as two groups.
      if (group.contains('.')) {
        if (!RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(group)) return null;
        continue;
      }
      if (!RegExp(r'^[0-9A-Fa-f]{1,4}$').hasMatch(group)) return null;
    }
    return groups.length;
  }

  /// How long `ssh-keyscan` may run before it is killed.
  ///
  /// `Process.run` has no timeout of its own, so without this a host that
  /// accepts the TCP connection and then goes silent (a tarpit, a firewall
  /// that drops rather than rejects) would keep the isolate awaiting
  /// indefinitely — the tab's "Checking..." state would never resolve.
  static const Duration _keyscanTimeout = Duration(seconds: 15);

  /// Runs `ssh-keyscan` against [host] and returns the raw key lines.
  ///
  /// Returns an empty list if the host is unreachable — **never throws**
  /// for a resolution failure.  Throws [SshConfigException] only if
  /// `ssh-keyscan` itself is missing, or if the scan exceeds
  /// [_keyscanTimeout].
  Future<List<String>> scanHost(String host) async {
    final ProcessResult result;
    try {
      result = await Process.run(
        'ssh-keyscan',
        [host],
        runInShell: false,
      ).timeout(_keyscanTimeout);
    } on TimeoutException {
      // Same user-visible outcome as an unreachable host: no keys were
      // returned. Distinguishable in rawDetail for anyone debugging.
      throw SshConfigException(
        SshConfigErrorCode.keyscanFailed,
        'ssh-keyscan did not respond for $host within '
        '${_keyscanTimeout.inSeconds} seconds.',
        rawDetail: 'ssh-keyscan timed out after ${_keyscanTimeout.inSeconds}s',
      );
    }

    if (result.exitCode != 0) {
      final stderr = result.stderr.toString().trim();
      // ssh-keyscan exits non-zero when the host is unreachable — that is
      // a *result*, not a fatal error.  Only flag it as a failure when
      // there is genuinely no output.
      if (stderr.isEmpty && result.stdout.toString().trim().isEmpty) {
        return [];
      }
      throw SshConfigException(
        SshConfigErrorCode.keyscanFailed,
        'ssh-keyscan failed for $host (exit code ${result.exitCode}).',
        rawDetail: '${result.stdout}\n${result.stderr}',
      );
    }

    final output = result.stdout.toString().trim();
    if (output.isEmpty) return [];
    return output.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  }

  /// Returns the raw key lines from `ssh-keyscan` for [host], or throws.
  ///
  /// Validates the host, runs `ssh-keyscan`, and returns the list of full
  /// key lines (e.g. `github.com ssh-ed25519 AAAAC3…`).  Throws
  /// [SshConfigException] if the host is invalid, unreachable, or
  /// `ssh-keyscan` is missing.
  Future<List<String>> scanHostKeys(String host) async {
    final hostProblem = isValidHostDetailed(host);
    if (hostProblem != null) {
      throw SshConfigException(
        SshConfigErrorCode.invalidHost,
        'Invalid host name: $hostProblem',
        rawDetail: 'Rejected input: "$host"',
      );
    }

    final keys = await scanHost(host);
    if (keys.isEmpty) {
      throw SshConfigException(
        SshConfigErrorCode.keyscanFailed,
        'Host $host is unreachable — no keys found.',
      );
    }
    return keys;
  }

  /// Writes the selected [keyLines] for [host] to `~/.ssh/known_hosts`,
  /// replacing only the entries whose key type matches one of the lines
  /// being written.  Entries for other key types of the same host are
  /// preserved.
  Future<void> writeKnownHostKeys(String host, List<String> keyLines) async {
    // Collect the key types being written so we can remove only those.
    final keyTypesToReplace = <String>{};
    for (final line in keyLines) {
      final tokens = line.split(RegExp(r'\s+'));
      if (tokens.length > 1) keyTypesToReplace.add(tokens[1]);
    }

    final file = File(_knownHostsPath);
    if (file.existsSync()) {
      final updated = withoutKeysForHost(
        file.readAsStringSync(),
        host,
        keyTypesToReplace,
      );
      try {
        file.writeAsStringSync(updated);
      } on FileSystemException catch (e) {
        throw SshConfigException(
          SshConfigErrorCode.writeFailed,
          'Failed to write ~/.ssh/known_hosts.',
          rawDetail: e.message,
        );
      }
    }

    try {
      if (!file.parent.existsSync()) {
        file.parent.createSync(recursive: true);
      }
      file.writeAsStringSync('${keyLines.join('\n')}\n', mode: FileMode.append);
    } on FileSystemException catch (e) {
      throw SshConfigException(
        SshConfigErrorCode.writeFailed,
        'Failed to write ~/.ssh/known_hosts.',
        rawDetail: e.message,
      );
    }
  }

  // -----------------------------------------------------------------------
  /// Removes the specific entry for [host] with [keyType] from
  /// `~/.ssh/known_hosts`.
  ///
  /// Matches lines where the host field (first comma-separated token)
  /// equals [host] **and** the key type (second whitespace token) equals
  /// [keyType].  Host comparison goes through [hostKey], so an IPv6 literal
  /// matches whether it was typed with or without brackets.  Does nothing if no
  /// matching line is found.
  /// Throws [SshConfigException] only on I/O errors.
  void removeKnownHost(String host, String keyType) {
    final file = File(_knownHostsPath);
    if (!file.existsSync()) return;

    final updated =
        withoutKeysForHost(file.readAsStringSync(), host, {keyType});

    try {
      file.writeAsStringSync(updated);
    } on FileSystemException catch (e) {
      throw SshConfigException(
        SshConfigErrorCode.writeFailed,
        'Failed to write ~/.ssh/known_hosts.',
        rawDetail: e.message,
      );
    }
  }
}
