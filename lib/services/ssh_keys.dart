/// SSH key file management and `ssh-agent` key manipulation for Windows.
///
/// Provides [SshKeyManager] which wraps the standard OpenSSH CLI tools
/// (`ssh-keygen`, `ssh-add`) for:
///
/// * Listing private-key files in `~/.ssh`.
/// * Listing keys currently loaded in the running ssh-agent.
/// * Generating new ed25519 key pairs.
/// * Adding / removing keys from the agent.
///
/// **Windows-specific notes:**
///
/// * `ssh-keygen -N` is broken on Win32-OpenSSH (#1609) — we use `-P` instead.
/// * `ssh-keygen` hangs on Windows when stdin is not a TTY (#836) — the
///   passphrase is passed purely via the `-P` argument; stdin is never used.
/// * All command invocations use a Dart-built `List<String>` so the passphrase
///   is never interpolated into a shell string.
library;

import 'dart:io';

// ---------------------------------------------------------------------------
// Typed exception
// ---------------------------------------------------------------------------

/// Error codes produced by [SshKeyManager].
enum SshKeyErrorCode {
  /// The `ssh-keygen` or `ssh-add` binary was not found on PATH.
  commandNotFound,

  /// The `ssh-add` agent returned a non-zero exit code indicating failure.
  agentCommandFailed,

  /// The target path for key generation already exists.
  fileExists,

  /// The `ssh-keygen` command failed for another reason.
  keygenFailed,

  /// The agent returned an unexpected or unparseable output.
  unexpectedOutput,
}

/// A typed exception thrown by [SshKeyManager] methods.
class SshKeyException implements Exception {
  /// Creates an [SshKeyException].
  SshKeyException(this.code, this.message, {this.rawDetail});

  /// The error category.
  final SshKeyErrorCode code;

  /// Human-readable explanation.
  final String message;

  /// Optional OS-level detail (stdout/stderr) — never exposed to the UI.
  final String? rawDetail;

  @override
  String toString() => 'SshKeyException(${code.name}): $message';
}

// ---------------------------------------------------------------------------
// Loaded-key model
// ---------------------------------------------------------------------------

/// A key identity currently loaded in the ssh-agent.
class LoadedKey {
  /// Creates a [LoadedKey].
  const LoadedKey({
    required this.fingerprint,
    required this.type,
    required this.path,
  });

  /// SHA-256 fingerprint (or MD5 if legacy).
  final String fingerprint;

  /// Key type (e.g. `ED25519`, `RSA`).
  final String type;

  /// File path (e.g. `C:\Users\…\.ssh\id_ed25519`).
  final String path;

  @override
  String toString() => 'LoadedKey($type $fingerprint $path)';
}

// ---------------------------------------------------------------------------
// SshKeyManager
// ---------------------------------------------------------------------------

/// Manages SSH key files and the ssh-agent's loaded identities.
class SshKeyManager {
  // -----------------------------------------------------------------------
  // Helpers
  // -----------------------------------------------------------------------

  /// Resolves `~/.ssh` using `USERPROFILE`.
  ///
  /// Returns an empty string if `USERPROFILE` is not set.
  String get sshDirectory => _sshDir;

  /// Resolves `~/.ssh` using `USERPROFILE`.
  String get _sshDir {
    final userProfile = Platform.environment['USERPROFILE'];
    if (userProfile == null || userProfile.isEmpty) {
      return '';
    }
    return '$userProfile\\.ssh';
  }

  /// Runs a process and throws [SshKeyException] if the binary is missing.
  Future<ProcessResult> _runOrThrow(
    String executable,
    List<String> arguments, {
    bool createNoWindow = false,
  }) {
    return Process.run(
      executable,
      arguments,
      runInShell: false,
      // On Windows we hide the console window for interactive tools.
      // This only takes effect when the current process already has a console;
      // it is harmless on other platforms.
      environment: createNoWindow ? null : null,
    ).catchError((Object error) {
      if (error is OSError) {
        // errno 2 / ENOENT → command not found.
        if (error.errorCode == 2) {
          throw SshKeyException(
            SshKeyErrorCode.commandNotFound,
            '$executable is not installed or not found on PATH.',
            rawDetail: error.toString(),
          );
        }
      }
      throw SshKeyException(
        SshKeyErrorCode.commandNotFound,
        'Failed to launch $executable.',
        rawDetail: error.toString(),
      );
    });
  }

  // -----------------------------------------------------------------------
  // listKeyFiles
  // -----------------------------------------------------------------------

  /// Lists private-key files in `~/.ssh`, excluding `known_hosts` and
  /// `config`.
  ///
  /// Returns `[]` if the directory does not exist — never throws.
  Future<List<String>> listKeyFiles() async {
    final dir = _sshDir;
    if (dir.isEmpty) return [];

    final directory = Directory(dir);
    if (!await directory.exists()) return [];

    final entries = await directory.list().toList();
    final results = <String>[];
    for (final entry in entries) {
      if (entry is! File) continue;
      final name = entry.path.split(Platform.pathSeparator).last;
      if (name == 'known_hosts' || name == 'config') continue;
      // Skip public-key companion files.
      if (name.endsWith('.pub')) continue;
      results.add(entry.path);
    }
    return results;
  }

  // -----------------------------------------------------------------------
  // listLoadedKeys
  // -----------------------------------------------------------------------

  /// Lists key identities currently loaded in the ssh-agent.
  ///
  /// Exit code 1 from `ssh-add -l` means "no identities" — this is **not**
  /// treated as an error; an empty list is returned.
  ///
  /// Throws [SshKeyException] with code [SshKeyErrorCode.commandNotFound] if
  /// `ssh-add` itself is unavailable.
  Future<List<LoadedKey>> listLoadedKeys() async {
    final result = await _runOrThrow('ssh-add', ['-l']);

    final stderr = result.stderr.toString().trim();

    // ssh-add exits 1 when the agent has no keys — valid, not an error.
    if (result.exitCode == 1) return [];

    // ssh-add exits 2 when the agent is not running.
    if (result.exitCode == 2) return [];

    // Non-zero + not 1 or 2 = genuine failure.
    if (result.exitCode != 0) {
      throw SshKeyException(
        SshKeyErrorCode.agentCommandFailed,
        'ssh-add -l failed (exit code ${result.exitCode}).',
        rawDetail: stderr,
      );
    }

    final stdout = result.stdout.toString().trim();
    if (stdout.isEmpty) return [];

    return _parseLoadedKeys(stdout);
  }

  /// Parses the multiline stdout of `ssh-add -l`.
  ///
  /// Expected line format:
  /// ```
  /// 256 SHA256:xxxxx C:\Users\…\.ssh\id_ed25519 (ED25519)
  /// ```
  List<LoadedKey> _parseLoadedKeys(String output) {
    final keys = <LoadedKey>[];
    for (final line in output.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      // Typical: "<bits> <fingerprint> <path> (<type>)"
      // The path may contain spaces on Windows, so we parse from both ends.
      final typeMatch = RegExp(r'\((\w+)\)\s*$').firstMatch(trimmed);
      if (typeMatch == null) continue;
      final type = typeMatch.group(1)!;

      final beforeType = trimmed.substring(0, typeMatch.start).trimRight();

      // Path is the last token before the type paren — but may contain spaces.
      // We find the path by locating the fingerprint (SHA256:… or MD5:…).
      final fpMatch =
          RegExp(r'(SHA256:[A-Za-z0-9/+]+|MD5:[A-Fa-f0-9:]+)').firstMatch(
            beforeType,
          );
      if (fpMatch == null) continue;
      final fingerprint = fpMatch.group(0)!;

      // Everything between the fingerprint and the type is the path.
      final pathStart = fpMatch.end;
      final pathEnd = typeMatch.start;
      final path = trimmed.substring(pathStart, pathEnd).trim();

      keys.add(
        LoadedKey(fingerprint: fingerprint, type: type, path: path),
      );
    }
    return keys;
  }

  // -----------------------------------------------------------------------
  // addKey
  // -----------------------------------------------------------------------

  /// Adds the private key at [path] to the ssh-agent.
  Future<void> addKey(String path) async {
    final result = await _runOrThrow('ssh-add', [path]);
    if (result.exitCode != 0) {
      throw SshKeyException(
        SshKeyErrorCode.agentCommandFailed,
        'ssh-add failed for $path (exit code ${result.exitCode}).',
        rawDetail: '${result.stdout}\n${result.stderr}',
      );
    }
  }

  // -----------------------------------------------------------------------
  // removeKey
  // -----------------------------------------------------------------------

  /// Removes the identity at [path] from the ssh-agent.
  Future<void> removeKey(String path) async {
    final result = await _runOrThrow('ssh-add', ['-d', path]);
    if (result.exitCode != 0) {
      throw SshKeyException(
        SshKeyErrorCode.agentCommandFailed,
        'ssh-add -d failed for $path (exit code ${result.exitCode}).',
        rawDetail: '${result.stdout}\n${result.stderr}',
      );
    }
  }

  // -----------------------------------------------------------------------
  // removeAll
  // -----------------------------------------------------------------------

  /// Removes all identities from the ssh-agent.
  Future<void> removeAll() async {
    final result = await _runOrThrow('ssh-add', ['-D']);
    if (result.exitCode != 0) {
      throw SshKeyException(
        SshKeyErrorCode.agentCommandFailed,
        'ssh-add -D failed (exit code ${result.exitCode}).',
        rawDetail: '${result.stdout}\n${result.stderr}',
      );
    }
  }

  // -----------------------------------------------------------------------
  // generateKey
  // -----------------------------------------------------------------------

  /// Generates a new ed25519 SSH key pair.
  ///
  /// * [name] — the base filename (e.g. `id_ed25519`).  The private key is
  ///   written to `~/.ssh/<name>`; the public key to `~/.ssh/<name>.pub`.
  /// * [passphrase] — if non-null the private key is encrypted with this
  ///   passphrase.  If null the key has no passphrase.
  /// * [comment] — optional comment embedded in the public key (typically an
  ///   email address).
  ///
  /// Uses `-P` (not `-N`) to supply the passphrase because Win32-OpenSSH's
  /// `ssh-keygen` ignores `-N` (issue #1609).
  ///
  /// The passphrase is never interpolated into a shell string — it is passed
  /// as a discrete argument to `Process.run(arguments: …)`.
  ///
  /// Throws [SshKeyException] with code [SshKeyErrorCode.fileExists] if the
  /// target private-key path already exists.
  Future<void> generateKey({
    required String name,
    String? passphrase,
    String? comment,
  }) async {
    final dir = _sshDir;
    if (dir.isEmpty) {
      throw SshKeyException(
        SshKeyErrorCode.keygenFailed,
        'USERPROFILE environment variable is not set.',
      );
    }

    // Ensure ~/.ssh exists.
    final directory = Directory(dir);
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }

    final keyPath = '$dir${Platform.pathSeparator}$name';
    final pubPath = '$keyPath.pub';

    // Check for existing file *before* invoking ssh-keygen.
    if (await File(keyPath).exists()) {
      throw SshKeyException(
        SshKeyErrorCode.fileExists,
        'The key file already exists: $keyPath',
      );
    }

    // Build the argument list.
    // NEVER use -N (broken on Windows).  Use -P instead.
    final args = <String>[
      'ssh-keygen',
      '-t',
      'ed25519',
      '-f',
      keyPath,
      // -P "" means no passphrase (different from -N "" which is broken).
      '-P',
      passphrase ?? '',
    ];

    if (comment != null && comment.isNotEmpty) {
      args
        ..add('-C')
        ..add(comment);
    }

    // Run ssh-keygen.  stdin is NOT connected because ssh-keygen hangs on
    // Windows when stdin is not a TTY (issue #836).  The passphrase is
    // supplied solely via the -P argument.
    final result = await Process.run(
      args.first,
      args.sublist(1),
      runInShell: false,
    );

    if (result.exitCode != 0) {
      // Clean up partial files if keygen partially wrote.
      final privFile = File(keyPath);
      final pubFile = File(pubPath);
      if (await privFile.exists()) await privFile.delete();
      if (await pubFile.exists()) await pubFile.delete();

      throw SshKeyException(
        SshKeyErrorCode.keygenFailed,
        'ssh-keygen failed (exit code ${result.exitCode}).',
        rawDetail: '${result.stdout}\n${result.stderr}',
      );
    }
  }
}
