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
// Key algorithm types
// ---------------------------------------------------------------------------

/// Supported SSH key algorithm types for generation.
enum KeyAlgorithm {
  /// Ed25519 (preferred, introduced in OpenSSH 6.5).
  ed25519('ed25519', 'id_ed25519'),

  /// Ed25519-sk (requires OpenSSH 8.2+, hardware security key).
  ed25519Sk('ed25519-sk', 'id_ed25519_sk'),

  /// ECDSA-sk (requires OpenSSH 8.2+, hardware security key).
  ecdsaSk('ecdsa-sk', 'id_ecdsa_sk'),

  /// RSA with 4096-bit key size (recommended by GitLab).
  rsa('rsa', 'id_rsa'),

  /// ECDSA (NIST P-256 curve).
  ecdsa('ecdsa', 'id_ecdsa'),

  /// DSA (deprecated, not recommended).
  dsa('dsa', 'id_dsa');

  const KeyAlgorithm(this.type, this.defaultName);

  /// The ssh-keygen `-t` argument value.
  final String type;

  /// The default filename (e.g. `id_ed25519`) when no custom name is given.
  final String defaultName;

  /// Human-readable label for the UI.
  String get label => switch (this) {
        ed25519 => 'ED25519 (recommended)',
        ed25519Sk => 'ED25519-SK (hardware key)',
        ecdsaSk => 'ECDSA-SK (hardware key)',
        rsa => 'RSA (4096-bit)',
        ecdsa => 'ECDSA',
        dsa => 'DSA (deprecated)',
      };
}

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

  /// The user profile environment variable is not set.
  userProfileNotSet,

  /// The provided key line or name is invalid.
  invalidKeyName,
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
  String toString() =>
      rawDetail == null ? 'SshKeyException(${code.name}): $message' : 'SshKeyException(${code.name}): $message ($rawDetail)';
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
// Authorized-key model
// ---------------------------------------------------------------------------

/// A public key entry in `~/.ssh/authorized_keys`.
class AuthorizedKey {
  /// Creates an [AuthorizedKey].
  const AuthorizedKey({
    required this.type,
    required this.key,
    required this.comment,
    required this.rawLine,
  });

  /// Key algorithm or format type (e.g. `ssh-ed25519`, `ssh-rsa`).
  final String type;

  /// Base64 encoded public key string.
  final String key;

  /// Optional comment or username/host identifier.
  final String comment;

  /// The original full line from the authorized_keys file.
  final String rawLine;

  @override
  String toString() => 'AuthorizedKey($type $comment)';
}

// ---------------------------------------------------------------------------
// SshKeyManager
// ---------------------------------------------------------------------------

/// Manages SSH key files and the ssh-agent's loaded identities.
class SshKeyManager {
  SshKeyManager({this.onWarning});

  /// Called for failures that are reported but do not fail the operation --
  /// currently only a temporary file that could not be deleted.
  ///
  /// Injected rather than calling `ToastService` directly: that service imports
  /// this file, so a direct call would be a circular import. The keys
  /// controller wires it to the toast.
  final void Function(String message)? onWarning;

  /// Reports a non-fatal problem. Always writes to stderr so it is never
  /// silently lost, and forwards to [onWarning] when one was supplied.
  void _warn(String message) {
    stderr.writeln('Warning: $message');
    onWarning?.call(message);
  }

  // -----------------------------------------------------------------------
  // Helpers
  // -----------------------------------------------------------------------

  /// Restricts [directory] so only the current user and SYSTEM can read it.
  ///
  /// Files created inside afterwards inherit these entries, which is what
  /// protects the decrypted key and the passphrase helper: they no longer pick
  /// up whatever access the user profile happens to grant.
  ///
  /// Best-effort. If `icacls` is unavailable the files are still created and
  /// the operation still works -- the caller only loses the hardening, so
  /// failing loudly here would be worse than proceeding.
  Future<void> _restrictToCurrentUser(Directory directory) async {
    final user = Platform.environment['USERNAME'];
    if (user == null || user.isEmpty) return;
    try {
      // /inheritance:r drops the inherited entries; (OI)(CI) makes the grants
      // inheritable so files created inside are covered too. SYSTEM is
      // referenced by SID so this does not depend on the OS language.
      await Process.run(
        'icacls.exe',
        [
          directory.path,
          '/inheritance:r',
          '/grant:r',
          '$user:(OI)(CI)(F)',
          '/grant:r',
          '*S-1-5-18:(OI)(CI)(F)',
        ],
        runInShell: false,
      );
    } catch (e) {
      stderr.writeln('Warning: could not restrict permissions on the '
          'temporary directory: $e');
    }
  }

  /// Resolves `~/.ssh` using `USERPROFILE`.
  ///
  /// Returns an empty string if `USERPROFILE` is not set.
  String get sshDirectory => _sshDir;

  /// Distinguishes staging files when a key is generated concurrently in two
  /// tabs of this process.
  static int _stagingCounter = 0;

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
  ///
  /// [environment] is merged over the inherited environment. Needed for the
  /// SSH_ASKPASS handshake, which is how a passphrase reaches `ssh-keygen`
  /// without appearing in the process command line.
  Future<({int exitCode, List<int> stdout, List<int> stderr})> _runWithTimeout(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 30),
    Map<String, String>? environment,
  }) async {
    // Nullable on purpose: when [Process.start] itself fails (for example the
    // binary is not on PATH) no Process is ever assigned. Declaring this `late`
    // and then calling kill() in the catch below threw a LateInitializationError
    // that masked the real OSError, making the errorCode == 2 branch below dead
    // code and hiding the "OpenSSH is not installed" message from the user.
    Process? process;
    try {
      process = await Process.start(
        executable,
        arguments,
        runInShell: false,
        environment: environment,
        includeParentEnvironment: true,
      );

      final stdoutFuture = process.stdout.expand((x) => x).toList();
      final stderrFuture = process.stderr.expand((x) => x).toList();
      final exitCodeFuture = process.exitCode.timeout(
        timeout,
        onTimeout: () {
          process?.kill();
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
      // The onTimeout callback above already killed the process. The stdout and
      // stderr subscriptions are abandoned rather than awaited: Future.wait with
      // eagerError completes on the first error, so both futures are left
      // pending here. Their StreamSubscriptions are cancelled when the process
      // handle is closed, which kill() triggers.
      throw SshKeyException(
        SshKeyErrorCode.timeout,
        '$executable timed out after ${timeout.inSeconds}s.',
      );
    } catch (e) {
      // Guard: process is null when Process.start() failed to launch at all.
      process?.kill();
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
      if (name == 'config') continue;
      if (name.startsWith('known_hosts')) continue;
      if (name.startsWith('authorized_keys')) continue;
      // Skip public-key companion files.
      if (name.endsWith('.pub')) continue;
      results.add(entry.path);
    }
    return results;
  }

  /// Obtains the public-key SHA-256 fingerprint for a key file at [path].
  ///
  /// Runs `ssh-keygen -l -f <path>` which works on both unprotected and
  /// passphrase-protected keys without prompting for interactive input.
  /// Returns null if the file cannot be parsed or is not an SSH key.
  Future<String?> getKeyFingerprint(String path) async {
    try {
      final result = await _runWithTimeout(
        'ssh-keygen',
        ['-l', '-f', path],
        timeout: const Duration(seconds: 5),
      );
      if (result.exitCode != 0) return null;
      final stdout = utf8.decode(result.stdout).trim();
      final fpMatch = RegExp(r'(SHA256:[A-Za-z0-9/+]+|MD5:[A-Fa-f0-9:]+)').firstMatch(stdout);
      return fpMatch?.group(0);
    } catch (_) {
      return null;
    }
  }

  /// Obtains the comment embedded in the public key at [path].
  ///
  /// Runs `ssh-keygen -l -f <path>` and extracts the comment field (the text
  /// between the fingerprint and the trailing `(TYPE)` token). Returns an
  /// empty string when the key has no comment, or null when the file cannot
  /// be parsed or is not an SSH key.
  Future<String?> getKeyComment(String path) async {
    try {
      final result = await _runWithTimeout(
        'ssh-keygen',
        ['-l', '-f', path],
        timeout: const Duration(seconds: 5),
      );
      if (result.exitCode != 0) return null;
      final stdout = utf8.decode(result.stdout).trim();
      final typeMatch = RegExp(r'\((\w+)\)\s*$').firstMatch(stdout);
      if (typeMatch == null) return null;
      final beforeType = stdout.substring(0, typeMatch.start).trimRight();
      final fpMatch =
          RegExp(r'(SHA256:[A-Za-z0-9/+]+|MD5:[A-Fa-f0-9:]+)').firstMatch(
        beforeType,
      );
      if (fpMatch == null) return null;
      return beforeType.substring(fpMatch.end).trim();
    } catch (_) {
      return null;
    }
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
  /// If [passphrase] is provided, a temporary copy is decrypted via `ssh-keygen -p`
  /// and added to `ssh-agent`, avoiding Windows OpenSSH stdin/TTY blocking issues.
  /// The temporary file is securely deleted immediately after adding.
  /// If [passphrase] is null and the key is protected, the call will fail
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

  /// Adds a passphrase-protected key by creating a temporary copy, removing its
  /// passphrase using `ssh-keygen -p`, adding the temporary key to `ssh-agent`,
  /// and then securely deleting the temporary file.
  ///
  /// On Windows OpenSSH, `ssh-add` does not read passphrases from stdin when
  /// stdin is not a TTY. This approach bypasses that limitation cleanly and
  /// fails immediately if the passphrase is incorrect.
  Future<void> _addKeyWithPassphrase(
    String path,
    String passphrase,
  ) async {
    final origFile = File(path);
    if (!await origFile.exists()) {
      throw SshKeyException(
        SshKeyErrorCode.agentCommandFailed,
        'Key file not found: $path',
      );
    }

    // A private directory rather than loose files in %TEMP%: everything this
    // method writes -- the decrypted private key, the passphrase, and the
    // helper that hands the passphrase over -- lands inside it, so one ACL
    // change covers all of it.
    Directory? workDir;
    File? tempFile;
    try {
      workDir = Directory.systemTemp.createTempSync('ssh_panel_');
      await _restrictToCurrentUser(workDir);

      final sep = Platform.pathSeparator;
      tempFile = File('${workDir.path}${sep}key');

      await origFile.copy(tempFile.path);

      // The passphrase reaches ssh-keygen through SSH_ASKPASS rather than -P.
      // Passing -P would put it in the process command line, where any process
      // on the machine can read it: `Get-CimInstance Win32_Process`, the
      // Details tab of Task Manager, and most EDR agents all expose it.
      //
      // stdin is not an option: ssh-keygen on Windows blocks forever without a
      // TTY (verified here -- it hung until killed). SSH_ASKPASS with
      // SSH_ASKPASS_REQUIRE=force works without a TTY.
      //
      // The helper is a .cmd that prints a sibling file, so the passphrase
      // needs no cmd escaping -- `%`, `&`, `"` and friends would otherwise be
      // mangled or injected into the command line.
      final passphraseFile = File('${workDir.path}${sep}passphrase.txt');
      final helperFile = File('${workDir.path}${sep}askpass.cmd');
      await passphraseFile.writeAsString(passphrase, flush: true);
      await helperFile.writeAsString(
        '@echo off\r\ntype "%~dp0passphrase.txt"\r\n',
        flush: true,
      );

      final keygenResult = await _runWithTimeout(
        'ssh-keygen',
        ['-p', '-N', '', '-f', tempFile.path],
        timeout: const Duration(seconds: 10),
        environment: {
          'SSH_ASKPASS': helperFile.path,
          // Required on Windows, where ssh would otherwise insist on a TTY.
          'SSH_ASKPASS_REQUIRE': 'force',
          // Some builds only consult SSH_ASKPASS when DISPLAY is set.
          'DISPLAY': 'ssh_panel',
        },
      );

      if (keygenResult.exitCode != 0) {
        final stdout = utf8.decode(keygenResult.stdout);
        final stderr = utf8.decode(keygenResult.stderr);
        final combined = '$stdout\n$stderr'.toLowerCase();
        if (combined.contains('incorrect passphrase') ||
            combined.contains('bad passphrase') ||
            combined.contains('failed to load key') ||
            combined.contains('passphrase') ||
            combined.contains('permission denied')) {
          throw SshKeyException(
            SshKeyErrorCode.wrongPassphrase,
            'The passphrase is incorrect.',
            rawDetail: stderr.isNotEmpty ? stderr : stdout,
          );
        }
        throw SshKeyException(
          SshKeyErrorCode.wrongPassphrase,
          'The passphrase is incorrect or key decryption failed.',
          rawDetail: '$stdout\n$stderr',
        );
      }

      // Add the decrypted temporary key to ssh-agent
      final addResult = await _runWithTimeout('ssh-add', [tempFile.path]);
      if (addResult.exitCode != 0) {
        throw SshKeyException(
          SshKeyErrorCode.agentCommandFailed,
          'ssh-add failed for $path (exit code ${addResult.exitCode}).',
          rawDetail: '${utf8.decode(addResult.stdout)}\n${utf8.decode(addResult.stderr)}',
        );
      }
    } on SshKeyException catch (e) {
      if (e.code == SshKeyErrorCode.timeout) {
        throw SshKeyException(
          SshKeyErrorCode.wrongPassphrase,
          'The passphrase is incorrect or key verification timed out.',
        );
      }
      rethrow;
    } finally {
      // Removing the directory takes the decrypted key, the passphrase file and
      // the helper with it. Previously a failure here left an unencrypted
      // private key in %TEMP% and only wrote to stderr, which is invisible in a
      // release build -- so it now also reaches the user.
      if (workDir != null && await workDir.exists()) {
        try {
          await workDir.delete(recursive: true);
        } catch (e) {
          _warn(
            'A temporary file could not be deleted and may still contain an '
            'unencrypted copy of your key: ${workDir.path} ($e)',
          );
        }
      }
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
  // deleteKeyFile
  // -----------------------------------------------------------------------

  /// Deletes the private key file at [path] and its associated `.pub` companion file from disk.
  Future<void> deleteKeyFile(String path) async {
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
    final pubFile = File('$path.pub');
    if (await pubFile.exists()) {
      await pubFile.delete();
    }
  }

  /// Reads the public key at `$path.pub` and returns its trimmed contents.
  ///
  /// Returns `null` if the companion `.pub` file does not exist or cannot be
  /// read. The returned string is the full public-key line (type, base64,
  /// comment), trimmed of trailing whitespace.
  Future<String?> readPublicKey(String path) async {
    final pubFile = File('$path.pub');
    if (!await pubFile.exists()) return null;
    try {
      final contents = await pubFile.readAsString();
      return contents.trim();
    } catch (_) {
      return null;
    }
  }

  // -----------------------------------------------------------------------
  // generateKey
  // -----------------------------------------------------------------------

  /// Generates a new SSH key pair.
  ///
  /// * [name] — the base filename (e.g. `id_ed25519`).  If empty or null,
  ///   the algorithm's default name is used (e.g. `id_ed25519` for ed25519).
  ///   The private key is written to `~/.ssh/<name>`; the public key to
  ///   `~/.ssh/<name>.pub`.
  /// * [algorithm] — the key type to generate (defaults to [KeyAlgorithm.ed25519]).
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
    KeyAlgorithm algorithm = KeyAlgorithm.ed25519,
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

    // Use algorithm default name if name is empty.
    final effectiveName = name.trim().isEmpty ? algorithm.defaultName : name.trim();

    final keyPath = '$dir${Platform.pathSeparator}$effectiveName';
    final pubPath = '$keyPath.pub';

    // Fail fast when the target already exists, so the common case gives an
    // immediate, specific "file exists" error instead of running ssh-keygen
    // only to have it refuse. This is a convenience check, NOT the safety
    // mechanism: the authoritative guarantee is the atomic rename below.
    if (await File(keyPath).exists()) {
      throw SshKeyException(
        SshKeyErrorCode.fileExists,
        'The key file already exists: $keyPath',
      );
    }

    // Generate into a unique staging name in the same directory, then rename
    // into place. ssh-keygen refuses to overwrite, but a check-then-create
    // sequence leaves a window in which another process could create the target
    // (including as a symlink pointing elsewhere) between the exists() above
    // and ssh-keygen writing to it. Staging in the same directory keeps the
    // rename on the same volume, so it is atomic: either the key appears at
    // the final path or it does not exist at all.
    final stagingStem = '$keyPath.sshpanel-tmp-${_stagingCounter++}';
    final stagingKey = stagingStem;
    final stagingPub = '$stagingStem.pub';

    // Build the argument list.
    // NEVER use -N (broken on Windows).  Use -P instead.
    final args = <String>[
      'ssh-keygen',
      '-t',
      algorithm.type,
      '-f',
      stagingKey,
      // -P "" means no passphrase (different from -N "" which is broken).
      '-P',
      passphrase ?? '',
    ];

    // RSA requires explicit bit size (GitLab recommends 4096).
    if (algorithm == KeyAlgorithm.rsa) {
      args.addAll(['-b', '4096']);
    }

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
      // Clean up the staging files ssh-keygen may have partially written.
      await _deleteIfExists(stagingKey);
      await _deleteIfExists(stagingPub);

      // ssh-keygen can also fail because the *final* path appeared while we
      // were generating. Surface that as the specific "file exists" case
      // rather than a generic generation failure.
      if (await File(keyPath).exists()) {
        throw SshKeyException(
          SshKeyErrorCode.fileExists,
          'The key file already exists: $keyPath',
        );
      }

      throw SshKeyException(
        SshKeyErrorCode.keygenFailed,
        'ssh-keygen failed (exit code ${result.exitCode}).',
        rawDetail: '${utf8.decode(result.stdout)}\n${utf8.decode(result.stderr)}',
      );
    }

    // Publish the staged keys at their final names.
    try {
      await File(stagingKey).rename(keyPath);
      await File(stagingPub).rename(pubPath);
    } catch (e) {
      // Do not leave half-published state behind.
      await _deleteIfExists(stagingKey);
      await _deleteIfExists(stagingPub);
      await _deleteIfExists(keyPath);
      await _deleteIfExists(pubPath);
      throw SshKeyException(
        SshKeyErrorCode.keygenFailed,
        'The key was generated but could not be moved into place.',
        rawDetail: e.toString(),
      );
    }
  }

  /// Deletes [path] if it exists, ignoring the result.
  ///
  /// Best-effort cleanup: a failure here (antivirus holding a handle, a
  /// permission change) must not mask the original error being reported.
  static Future<void> _deleteIfExists(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Intentionally ignored -- see doc comment.
    }
  }

  // -----------------------------------------------------------------------
  // authorized_keys management
  // -----------------------------------------------------------------------

  /// Path to the `authorized_keys` file in `~/.ssh`.
  String get authorizedKeysPath {
    final dir = _sshDir;
    return dir.isEmpty ? '' : '$dir\\authorized_keys';
  }

  /// Lists parsed public key entries from `~/.ssh/authorized_keys`.
  ///
  /// Returns an empty list if the file does not exist or has no valid keys.
  Future<List<AuthorizedKey>> listAuthorizedKeys() async {
    final path = authorizedKeysPath;
    if (path.isEmpty) return [];

    final file = File(path);
    if (!await file.exists()) return [];

    final lines = await file.readAsLines();
    final keys = <AuthorizedKey>[];

    for (final rawLine in lines) {
      final trimmed = rawLine.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;

      final tokens = trimmed.split(RegExp(r'\s+'));
      if (tokens.length < 2) continue;

      int typeIndex = -1;
      for (int i = 0; i < tokens.length; i++) {
        final token = tokens[i].toLowerCase();
        if (token.startsWith('ssh-') ||
            token.startsWith('ecdsa-') ||
            token.startsWith('sk-ssh-') ||
            token.startsWith('sk-ecdsa-')) {
          typeIndex = i;
          break;
        }
      }

      if (typeIndex == -1 || typeIndex + 1 >= tokens.length) {
        final type = tokens[0];
        final key = tokens[1];
        final comment = tokens.length > 2 ? tokens.sublist(2).join(' ') : '';
        keys.add(AuthorizedKey(
          type: type,
          key: key,
          comment: comment,
          rawLine: trimmed,
        ));
      } else {
        final type = tokens[typeIndex];
        final key = tokens[typeIndex + 1];
        final comment = tokens.length > typeIndex + 2
            ? tokens.sublist(typeIndex + 2).join(' ')
            : '';
        keys.add(AuthorizedKey(
          type: type,
          key: key,
          comment: comment,
          rawLine: trimmed,
        ));
      }
    }

    return keys;
  }

  /// Appends a new public key entry to `~/.ssh/authorized_keys`.
  Future<void> addAuthorizedKey(String keyLine) async {
    final trimmed = keyLine.trim();
    if (trimmed.isEmpty) {
      throw SshKeyException(
        SshKeyErrorCode.invalidKeyName,
        'The key line cannot be empty.',
      );
    }

    final path = authorizedKeysPath;
    if (path.isEmpty) {
      throw SshKeyException(
        SshKeyErrorCode.userProfileNotSet,
        'USERPROFILE environment variable is not set.',
      );
    }

    final file = File(path);
    if (!await file.exists()) {
      await file.create(recursive: true);
    }

    final existing = await file.readAsString();
    final needsNewline = existing.isNotEmpty && !existing.endsWith('\n') && !existing.endsWith('\r\n');
    final sink = file.openWrite(mode: FileMode.append);
    if (needsNewline) {
      sink.writeln();
    }
    sink.writeln(trimmed);
    await sink.flush();
    await sink.close();
  }

  /// Removes a key entry from `~/.ssh/authorized_keys` matching [rawLine].
  Future<void> removeAuthorizedKey(String rawLine) async {
    final path = authorizedKeysPath;
    if (path.isEmpty) return;

    final file = File(path);
    if (!await file.exists()) return;

    final lines = await file.readAsLines();
    final filtered = lines.where((line) => line.trim() != rawLine.trim()).toList();

    await file.writeAsString(
      filtered.isEmpty ? '' : '${filtered.join(Platform.lineTerminator)}${Platform.lineTerminator}',
    );
  }
}

