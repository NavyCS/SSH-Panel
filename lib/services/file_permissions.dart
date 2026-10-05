import 'dart:io';

/// Applies Windows file-system permissions to paths the app creates.
///
/// Deliberately conservative about *when* it runs. OpenSSH expects `~/.ssh` to
/// be private to its owner, but a user who has deliberately widened the
/// permissions on an existing directory should not have that silently undone by
/// opening a panel. So this is only ever called for a directory or file the
/// app just created itself.
class FilePermissions {
  FilePermissions._();

  /// Restricts [directory] to the current user and SYSTEM.
  ///
  /// `/inheritance:r` drops the entries inherited from the profile; the
  /// `(OI)(CI)` flags make the new grants inheritable, so anything created
  /// inside afterwards is covered too. SYSTEM is addressed by SID so the result
  /// does not depend on the Windows UI language.
  ///
  /// Best-effort by design: if `icacls` is missing or fails, the caller has
  /// already created what it needs, and refusing to continue would be a worse
  /// outcome than proceeding without the hardening. The failure is reported on
  /// stderr rather than swallowed, and the return value says whether it applied.
  static Future<bool> restrictToOwner(Directory directory) async {
    final user = Platform.environment['USERNAME'];
    if (user == null || user.isEmpty) return false;
    try {
      final result = await Process.run(
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
      return result.exitCode == 0;
    } catch (e) {
      stderr.writeln('Warning: could not restrict permissions on '
          '${directory.path}: $e');
      return false;
    }
  }

  /// Creates [directory] if missing and, when it had to create it, restricts it
  /// to the owner.
  ///
  /// An existing directory is left exactly as it is. Returns true when the
  /// directory was created by this call.
  static Future<bool> ensurePrivateDirectory(Directory directory) async {
    if (await directory.exists()) return false;
    await directory.create(recursive: true);
    await restrictToOwner(directory);
    return true;
  }
}