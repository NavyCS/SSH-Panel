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

  /// Extracts hostnames from `~/.ssh/known_hosts`.
  ///
  /// Each entry in the known_hosts file has the format
  /// `hostname,key-type,key [comment]`.  This method returns the first
  /// token (hostname) of each non-empty line, trimmed of whitespace.
  ///
  /// Returns `[]` when the file does not exist or is empty — **never
  /// throws** for a missing or empty file.
  List<String> getKnownHosts() {
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
          .map((line) => line.split(RegExp(r'\s+')).first)
          .toList();
    } on FileSystemException catch (e) {
      throw SshConfigException(
        SshConfigErrorCode.readFailed,
        'Failed to read ~/.ssh/known_hosts.',
        rawDetail: e.message,
      );
    }
  }
}
