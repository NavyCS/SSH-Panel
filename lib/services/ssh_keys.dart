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

import 'dart:async';
import 'dart:convert';
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

  /// A command timed out waiting for a response.
  timeout,

  /// The passphrase provided is incorrect for the key.
  wrongPassphrase,
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

  /// Runs a process with a timeout and throws [SshKeyException] if the
  /// binary is missing, the command exceeds [timeout] (default 30 s),
  /// or the process cannot be launched. The process is killed on timeout.
  Future<({int exitCode, List<int> stdout, List<int> stderr})> _runWithTimeout(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    late Process process;
    try {
      process = await Process.start(executable, arguments, runInShell: false);

      final stdoutFuture = process.stdout.expand((x) => x).toList();
      final stderrFuture = process.stderr.expand((x) => x).toList();
      final exitCodeFuture = process.exitCode.timeout(
        timeout,
        onTimeout: () {
          process.kill();
          throw TimeoutException('$executable timed out');
        },
      );

      final results = await Future.wait<dynamic>(
        [stdoutFuture, stderrFuture, exitCodeFuture],
        eagerError: true,
      );

      return (
        exitCode: results[2] as int,
        stdout: results[0] as List<int>,
        stderr: results[1] as List<int>,
      );
    } on TimeoutException catch (_) {
      throw SshKeyException(
        SshKeyErrorCode.timeout,
        '$executable timed out after ${timeout.inSeconds}s.',
      );
    } catch (e) {
      process.kill();
      if (e is SshKeyException) rethrow;
      if (e is OSError) {
        if (e.errorCode == 2) {
          throw SshKeyException(
            SshKeyErrorCode.commandNotFound,
            '$executable is not installed or not found on PATH.',
            rawDetail: e.toString(),
          );
        }
      }
      throw SshKeyException(
        SshKeyErrorCode.commandNotFound,
        'Failed to launch $executable.',
        rawDetail: e.toString(),
      );
    }
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
    final result = await _runWithTimeout('ssh-add', ['-l']);

    final stderr = utf8.decode(result.stderr).trim();

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

    final stdout = utf8.decode(result.stdout).trim();
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

  /// Checks whether the private key at [path] is protected by a passphrase.
  Future<bool> hasPassphrase(String path) async {
    try {
      final result = await _runWithTimeout(
        'ssh-keygen',
        ['-y', '-P', '', '-f', path],
      );
      if (result.exitCode == 0) return false;
      final stderr = utf8.decode(result.stderr);
      return stderr.toLowerCase().contains('passphrase');
    } catch (_) {
      return false;
    }
  }

  /// Adds the private key at [path] to the ssh-agent.
  ///
  /// If [passphrase] is provided it is piped to `ssh-add`'s stdin so
  /// passphrase-protected keys load without hanging for interactive input.
  /// If [passphrase] is null and the key is protected the call will fail
  /// fast (instead of hanging) thanks to the timeout in [_runWithTimeout].
  Future<void> addKey(String path, {String? passphrase}) async {
    if (passphrase != null) {
      await _addKeyWithPassphrase(path, passphrase);
      return;
    }
    final result = await _runWithTimeout('ssh-add', [path]);
    if (result.exitCode != 0) {
      throw SshKeyException(
        SshKeyErrorCode.agentCommandFailed,
        'ssh-add failed for $path (exit code ${result.exitCode}).',
        rawDetail: '${utf8.decode(result.stdout)}\n${utf8.decode(result.stderr)}',
      );
    }
  }

  /// Adds a passphrase-protected key by piping the passphrase to
  /// `ssh-add` via the shell so it never blocks waiting for interactive input.
  /// On Windows, `ssh-add` does not reliably read from stdin when started
  /// via `Process.start`, so we use `cmd /c echo pass | ssh-add path`.
  Future<void> _addKeyWithPassphrase(
    String path,
    String passphrase,
  ) async {
    try {
      // Escape double quotes in the passphrase for cmd.exe.
      final escapedPassphrase = passphrase.replaceAll('"', '""');
      final result = await Process.run(
        'cmd.exe',
        ['/c', 'echo $escapedPassphrase | ssh-add', path],
        runInShell: false,
      ).timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          throw SshKeyException(
            SshKeyErrorCode.wrongPassphrase,
            'The passphrase is incorrect.',
          );
        },
      );

      final stdout = utf8.decode(result.stdout);
      final stderr = utf8.decode(result.stderr);

      if (result.exitCode != 0) {
        // Detect wrong passphrase from ssh-add's stderr output.
        if (stderr.toLowerCase().contains('bad passphrase') ||
            stderr.toLowerCase().contains('incorrect') ||
            stderr.toLowerCase().contains('permission denied') ||
            stderr.toLowerCase().contains('unauthorized')) {
          throw SshKeyException(
            SshKeyErrorCode.wrongPassphrase,
            'The passphrase is incorrect.',
            rawDetail: stderr,
          );
        }
        throw SshKeyException(
          SshKeyErrorCode.agentCommandFailed,
          'ssh-add failed for $path (exit code ${result.exitCode}).',
          rawDetail: '$stdout\n$stderr',
        );
      }
    } on TimeoutException catch (_) {
      throw SshKeyException(
        SshKeyErrorCode.wrongPassphrase,
        'The passphrase is incorrect.',
      );
    } catch (e) {
      if (e is SshKeyException) rethrow;
      throw SshKeyException(
        SshKeyErrorCode.agentCommandFailed,
        'Failed to add key $path.',
        rawDetail: e.toString(),
      );
    }
  }

  // -----------------------------------------------------------------------
  // removeKey
  // -----------------------------------------------------------------------

  /// Removes the identity at [path] from the ssh-agent.
  Future<void> removeKey(String path) async {
    final result = await _runWithTimeout('ssh-add', ['-d', path]);
    if (result.exitCode != 0) {
      throw SshKeyException(
        SshKeyErrorCode.agentCommandFailed,
        'ssh-add -d failed for $path (exit code ${result.exitCode}).',
        rawDetail: '${utf8.decode(result.stdout)}\n${utf8.decode(result.stderr)}',
      );
    }
  }

  // -----------------------------------------------------------------------
  // removeAll
  // -----------------------------------------------------------------------

  /// Removes all identities from the ssh-agent.
  Future<void> removeAll() async {
    final result = await _runWithTimeout('ssh-add', ['-D']);
    if (result.exitCode != 0) {
      throw SshKeyException(
        SshKeyErrorCode.agentCommandFailed,
        'ssh-add -D failed (exit code ${result.exitCode}).',
        rawDetail: '${utf8.decode(result.stdout)}\n${utf8.decode(result.stderr)}',
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
    ).timeout(const Duration(seconds: 30), onTimeout: () {
      throw SshKeyException(
        SshKeyErrorCode.keygenFailed,
        'ssh-keygen timed out after 30s.',
      );
    });

    if (result.exitCode != 0) {
      // Clean up partial files if keygen partially wrote.
      final privFile = File(keyPath);
      final pubFile = File(pubPath);
      if (await privFile.exists()) await privFile.delete();
      if (await pubFile.exists()) await pubFile.delete();

      throw SshKeyException(
        SshKeyErrorCode.keygenFailed,
        'ssh-keygen failed (exit code ${result.exitCode}).',
        rawDetail: '${utf8.decode(result.stdout)}\n${utf8.decode(result.stderr)}',
      );
    }
  }
}
