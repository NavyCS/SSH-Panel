/// SSH config and known_hosts management for Windows.
///
/// Reads and writes the OpenSSH configuration files located at
/// `~/.ssh/config` and `~/.ssh/known_hosts`.  Uses the `USERPROFILE`
/// environment variable to locate the home directory.
///
/// **No SSH connection logic** — this module only manages the text files.
library;

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

  /// Validates that [host] looks like a plausible hostname or IP.
  ///
  /// Rejects empty strings, whitespace, and anything containing characters
  /// that cannot appear in a hostname (spaces, control chars, shell
  /// metacharacters, etc.).  This is a cheap client-side guard, not a
  /// substitute for actually reaching the host.
  static bool isValidHost(String host) {
    if (host.isEmpty) return false;
    final trimmed = host.trim();
    if (trimmed.isEmpty) return false;
    // Reject whitespace and control characters.
    if (RegExp(r'[\s\x00-\x1f]').hasMatch(trimmed)) return false;
    // Reject shell metacharacters that could break out of ssh-keyscan.
    const forbidden = <String>{
      '<', '>', '&', '|', ';', '"', "'", '\\', '\$', '`',
      '!', '#', '?', '*', '~', '[', ']', '{', '}', '(', ')',
    };
    if (trimmed.split('').any((c) => forbidden.contains(c))) return false;
    // Each label must be 1-63 chars, total ≤ 253, no leading/trailing dot/dash.
    if (trimmed.length > 253) return false;
    final labels = trimmed.split('.');
    for (final label in labels) {
      if (label.isEmpty || label.length > 63) return false;
      if (label.startsWith('-') || label.endsWith('-')) return false;
      if (!RegExp(r'^[a-zA-Z0-9-]+$').hasMatch(label)) return false;
    }
    return true;
  }

  /// Runs `ssh-keyscan` against [host] and returns the raw key lines.
  ///
  /// Returns an empty list if the host is unreachable — **never throws**
  /// for a resolution failure.  Throws [SshConfigException] only if
  /// `ssh-keyscan` itself is missing.
  Future<List<String>> scanHost(String host) async {
    final result = await Process.run(
      'ssh-keyscan',
      [host],
      runInShell: false,
    );

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
    if (!isValidHost(host)) {
      throw SshConfigException(
        SshConfigErrorCode.invalidHost,
        'Invalid host name: "$host".',
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
      final lines = file.readAsLinesSync();
      final filtered = lines
          .where((line) {
            final trimmed = line.trim();
            if (trimmed.isEmpty || trimmed.startsWith('#')) return true;
            final tokens = trimmed.split(RegExp(r'\s+'));
            final lineHost = tokens.isNotEmpty ? tokens[0].split(',').first : '';
            final lineKeyType = tokens.length > 1 ? tokens[1] : '';
            // Keep the line if it's for a different host, or for the same
            // host but a key type we are NOT replacing.
            return lineHost != host || !keyTypesToReplace.contains(lineKeyType);
          })
          .toList();
      try {
        file.writeAsStringSync(filtered.join('\n'));
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

  /// Internal helper: removes **all** entries whose host field matches
  /// [host], regardless of key type.  Used by [addKnownHost] to replace
  /// the full set of keys for a host.
  void _removeAllHostEntries(String host) {
    final file = File(_knownHostsPath);
    if (!file.existsSync()) return;

    final lines = file.readAsLinesSync();
    final filtered = lines
        .where((line) {
          final trimmed = line.trim();
          if (trimmed.isEmpty || trimmed.startsWith('#')) return true;
          final tokens = trimmed.split(RegExp(r'\s+'));
          final lineHost = tokens.isNotEmpty ? tokens[0].split(',').first : '';
          return lineHost != host;
        })
        .toList();

    try {
      file.writeAsStringSync(filtered.join('\n'));
    } on FileSystemException catch (e) {
      throw SshConfigException(
        SshConfigErrorCode.writeFailed,
        'Failed to write ~/.ssh/known_hosts.',
        rawDetail: e.message,
      );
    }
  }

  // -----------------------------------------------------------------------
  // removeKnownHost
  // -----------------------------------------------------------------------

  /// Removes the specific entry for [host] with [keyType] from
  /// `~/.ssh/known_hosts`.
  ///
  /// Matches lines where the host field (first comma-separated token)
  /// equals [host] **and** the key type (second whitespace token) equals
  /// [keyType].  Does nothing if no matching line is found.
  /// Throws [SshConfigException] only on I/O errors.
  void removeKnownHost(String host, String keyType) {
    final file = File(_knownHostsPath);
    if (!file.existsSync()) return;

    final lines = file.readAsLinesSync();
    final filtered = lines
        .where((line) {
          final trimmed = line.trim();
          if (trimmed.isEmpty || trimmed.startsWith('#')) return true;
          final tokens = trimmed.split(RegExp(r'\s+'));
          final lineHost = tokens.isNotEmpty ? tokens[0].split(',').first : '';
          final lineKeyType = tokens.length > 1 ? tokens[1] : '';
          return lineHost != host || lineKeyType != keyType;
        })
        .toList();

    try {
      file.writeAsStringSync(filtered.join('\n'));
    } on FileSystemException catch (e) {
      throw SshConfigException(
        SshConfigErrorCode.writeFailed,
        'Failed to write ~/.ssh/known_hosts.',
        rawDetail: e.message,
      );
    }
  }
}
