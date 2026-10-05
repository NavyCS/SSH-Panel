import 'dart:io';

/// Path guards for handing filesystem paths to external programs.
///
/// The `explorer` calls in this app take their argument from
/// `SshConfigManager.sshDirectory`, which is derived from the `USERPROFILE`
/// environment variable. That is fine under normal operation, but an
/// environment variable is not a trust boundary: a process that can set
/// `USERPROFILE` before launching the app decides which directory the app
/// opens in the file manager. Confining every path to the real user profile
/// makes a manipulated value harmless.
///
/// The check is deliberately narrow rather than clever. `explorer` is launched
/// with `runInShell: false`, so no shell expands these strings and there is no
/// injection to defend against; what matters is only that the path stays where
/// the app intends it to.
class PathGuard {
  PathGuard._();

  /// Whether [path] resolves inside the current user's profile directory.
  ///
  /// Returns false when `USERPROFILE` is unset or when [path] does not start
  /// with it, which is the fail-closed answer: refuse rather than guess.
  ///
  /// Comparison is case-insensitive because Windows paths are, and the prefix
  /// check appends a separator so `C:\Users\navyc-evil` cannot pass by
  /// starting with `C:\Users\navyc`.
  static bool isInsideUserProfile(String path) {
    final profile = Platform.environment['USERPROFILE'];
    if (profile == null || profile.isEmpty) return false;
    if (path.isEmpty) return false;

    final normalisedPath = _normalise(path);
    final normalisedProfile = _normalise(profile);

    if (!normalisedPath.startsWith(normalisedProfile)) return false;

    // The profile itself is inside the profile. Handling this before the
    // separator check matters: with equal lengths there is no next character,
    // so it would otherwise be rejected -- which is how the tests caught it.
    if (normalisedPath.length == normalisedProfile.length) return true;

    // Require a separator so a sibling directory sharing the prefix is
    // rejected: C:\Users\navyc-evil must not pass as C:\Users\navyc.
    final next = normalisedPath[normalisedProfile.length];
    return next == r'\' || next == '/';
  }

  /// Resolves [path] against symlinks where possible, so a link inside the
  /// profile cannot point outside it.
  ///
  /// Falls back to the literal path when the file does not exist yet or the
  /// lookup fails; [isInsideUserProfile] still applies to the result.
  static String resolve(String path) {
    try {
      return File(path).resolveSymbolicLinksSync();
    } catch (_) {
      // Missing path, or a permission problem: use it as given and let the
      // prefix check decide.
      return path;
    }
  }

  /// Whether [path] may be handed to an external program: it must resolve
  /// inside the user profile.
  static bool isAllowed(String path) =>
      path.isNotEmpty && isInsideUserProfile(resolve(path));

  /// Canonical form for comparison: backslashes, no trailing separator, lower
  /// case. [String.trimRight] takes a set of characters, so trailing
  /// separators are stripped with a pattern instead.
  static String _normalise(String value) => value
      .replaceAll('/', r'\')
      .replaceAll(RegExp(r'\\+$'), '')
      .toLowerCase();
}