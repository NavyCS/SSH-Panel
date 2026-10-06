import 'dart:io';

import '../services/path_guard.dart';
import '../toast_service.dart';

/// Opens the SSH directory in Windows Explorer after checking it is safe.
///
/// Both the Keys tab and the Domains tab needed this identical guarded
/// Explorer launch, each holding its own controller that exposes
/// `sshDirectory`; the body lived duplicated in two State classes until it
/// was extracted here.
///
/// [PathGuard] is the security boundary: nothing outside `%USERPROFILE%` is
/// ever handed to `explorer`. An empty directory, or one that fails the
/// guard, is ignored (with an error toast for the latter).
void openSshFolder(String dir) {
  if (dir.isEmpty) return;
  if (!PathGuard.isAllowed(dir)) {
    ToastService.instance.showErrorMessage(
      'Refusing to open a folder outside your user profile.',
    );
    return;
  }
  Process.run('explorer', [dir], runInShell: false);
}
