import 'dart:developer' show log;

import 'package:flutter/foundation.dart';

import '../../services/ssh_domains.dart';
import '../../toast_service.dart';

/// Owns the state and file I/O of the Hosts tab.
///
/// Split deliberately along the line between what needs a `BuildContext` and
/// what does not. The confirmation dialogs stay in the widget — they are UI —
/// while everything here is state plus `SshConfigManager` calls, which makes it
/// reachable from a unit test without mounting the tab or touching the real
/// `~/.ssh`.
///
/// The tab's `ValueNotifier<bool> _adding` is gone: it existed only to poke a
/// `setState` from inside an async gap. Here the same state is a plain bool on
/// a [ChangeNotifier].
class DomainsController extends ChangeNotifier {
  DomainsController({SshConfigManager? configManager})
      : _configManager = configManager ?? SshConfigManager();

  final SshConfigManager _configManager;

  List<Map<String, String>> _knownHosts = [];
  String _configText = '';
  bool _isLoading = false;
  bool _isEditing = false;
  bool _isHostsLoading = false;
  bool _isScanning = false;
  bool _disposed = false;

  /// Per-host check result. A `null` value means "currently checking" — the
  /// entry existing at all is what distinguishes a pending host from one that
  /// was never checked.
  final Map<String, String?> _hostStatus = {};

  /// Hosts with an in-flight scan, used to stop a second scan starting.
  final Set<String> _checkingHosts = {};

  List<Map<String, String>> get knownHosts => _knownHosts;

  /// Current contents of `~/.ssh/config` as last read or written.
  String get configText => _configText;

  bool get isLoading => _isLoading;
  bool get isEditing => _isEditing;
  bool get isHostsLoading => _isHostsLoading;

  /// True while scanning a host for keys that are not yet in known_hosts.
  bool get isScanning => _isScanning;

  /// Result for [host]: `null` when not checked or in flight.
  String? hostStatus(String host) => _hostStatus[host];

  /// Whether [host] has a check in flight.
  bool isChecking(String host) => _checkingHosts.contains(host);

  /// Whether any check is in flight, so a row can show progress.
  bool get hasAnyCheckInFlight => _checkingHosts.isNotEmpty;

  /// `~/.ssh`, or empty when USERPROFILE is unset.
  String get sshDirectory => _configManager.sshDirectory;

  String get knownHostsPath => _configManager.knownHostsPath;

  /// Renders [path] relative to `~/.ssh` as `~/...`.
  String shortPath(String path) {
    final home = _configManager.sshDirectory;
    if (home.isNotEmpty && path.startsWith(home)) {
      return '~${path.substring(home.length)}';
    }
    return path;
  }

  /// Reads the config file and the known-hosts list.
  Future<void> refresh() async {
    _setLoading(true);
    try {
      final config = _configManager.readConfig();
      final hosts = _configManager.getKnownHosts();
      if (_disposed) return;
      _configText = config;
      _knownHosts = hosts;
    } on SshConfigException catch (e) {
      if (_disposed) return;
      ToastService.instance.showError(e);
    } catch (e) {
      if (_disposed) return;
      ToastService.instance.showError(_asException(e));
    } finally {
      _setLoading(false);
    }
  }

  /// Re-reads known_hosts only, dropping status entries for hosts that no
  /// longer exist so a stale badge cannot survive a removal.
  Future<void> refreshHosts() async {
    _isHostsLoading = true;
    _notify();
    try {
      final hosts = _configManager.getKnownHosts();
      if (_disposed) return;
      final currentHosts = hosts.map((h) => h['host']!).toSet();
      _hostStatus.removeWhere((key, _) => !currentHosts.contains(key));
      _knownHosts = hosts;
    } on SshConfigException catch (e) {
      if (_disposed) return;
      ToastService.instance.showError(e);
    } catch (e) {
      if (_disposed) return;
      ToastService.instance.showError(_asException(e));
    } finally {
      _isHostsLoading = false;
      _notify();
    }
  }

  /// Writes [text] to `~/.ssh/config` and leaves edit mode.
  Future<void> saveConfig(String text) async {
    _setLoading(true);
    try {
      _configManager.writeConfig(text);
      if (_disposed) return;
      _configText = text;
      _isEditing = false;
      ToastService.instance.showSuccess('Config saved.');
    } on SshConfigException catch (e) {
      if (_disposed) return;
      ToastService.instance.showError(e);
    } catch (e) {
      if (_disposed) return;
      ToastService.instance.showError(_asException(e));
    } finally {
      _setLoading(false);
    }
  }

  /// Runs `ssh-keyscan` against [host] and records the key types found, or
  /// `Unreachable` when it returns nothing. Reports the result in a toast.
  ///
  /// A second scan of the same host while one is in flight is ignored, so the
  /// row cannot end up with two results racing.
  ///
  /// The toast names every algorithm the host offered, not just how many. The
  /// badge beside the row only has room for a count, and the tooltip that used
  /// to carry the names needed the mouse to be over it -- so the answer to the
  /// question the user actually asked by clicking Check was not on screen
  /// unless they went looking for it.
  Future<void> checkHost(String host) async {
    if (_checkingHosts.contains(host)) return;
    _checkingHosts.add(host);
    _hostStatus[host] = null;
    _notify();
    try {
      final keys = await _configManager.scanHost(host);
      if (_disposed) return;
      final keyTypes = parseKeyTypes(keys);
      if (keyTypes.isEmpty) {
        _hostStatus[host] = 'Unreachable';
        ToastService.instance.showInfo(unreachableMessage, title: host);
      } else {
        _hostStatus[host] = keyTypes.join(', ');
        ToastService.instance.showInfo(checkResultMessage(keyTypes), title: host);
      }
    } on SshConfigException catch (e) {
      if (_disposed) return;
      _hostStatus[host] = 'Error: ${e.message}';
      ToastService.instance.showErrorMessage(e.message);
    } catch (e) {
      if (_disposed) return;
      _hostStatus[host] = 'Error';
      ToastService.instance.showErrorMessage('The scan failed unexpectedly.');
    } finally {
      _checkingHosts.remove(host);
      _notify();
    }
  }

  /// Scans [host] and returns the key types that are not already recorded for
  /// it, as `{'keyType': ..., 'line': ...}` entries.
  ///
  /// Returns `null` on failure. An empty list means the host is reachable and
  /// already has every algorithm known_hosts knows about, which is a different
  /// outcome from a failure.
  Future<List<Map<String, String>>?> scanAvailableHostKeys(String host) async {
    _isScanning = true;
    _notify();
    List<String> keyLines;
    try {
      keyLines = await _configManager.scanHostKeys(host);
    } catch (e) {
      if (!_disposed) ToastService.instance.showError(_asException(e));
      _isScanning = false;
      _notify();
      return null;
    }
    _isScanning = false;
    _notify();
    if (_disposed) return null;

    // Compared through hostKeyOf, not as raw strings. known_hosts does not store
    // what the user typed: `ssh-keyscan ::1` writes `[::1]:22`. A raw comparison
    // silently found no existing entries for an IPv6 literal, so the app offered
    // to re-add keys that were already there.
    final hostKey = SshConfigManager.hostKeyOf(host);
    final existingKeyTypes = _knownHosts
        .where((h) =>
            SshConfigManager.hostKeyOf(h['host'] ?? '') == hostKey)
        .map((h) => h['keyType']!)
        .toSet();

    return keyLines
        .map(parseKeyLine)
        .where((e) => e != null)
        .cast<Map<String, String>>()
        .where((e) => !existingKeyTypes.contains(e['keyType']))
        .toList();
  }

  /// Removes the [keyType] entry for [host] from known_hosts and refreshes.
  Future<void> removeKnownHost(String host, String keyType) async {
    _isHostsLoading = true;
    _notify();
    try {
      _configManager.removeKnownHost(host, keyType);
      if (_disposed) return;
      await refreshHosts();
      if (_disposed) return;
      ToastService.instance.showSuccess('Known host entry removed.');
    } on SshConfigException catch (e) {
      if (_disposed) return;
      ToastService.instance.showError(e);
    } catch (e) {
      if (_disposed) return;
      ToastService.instance.showError(_asException(e));
    } finally {
      _isHostsLoading = false;
      _notify();
    }
  }

  /// Appends [keyLines] to known_hosts for [host] and refreshes.
  ///
  /// Returns whether the keys were written. The caller needs this: a failed
  /// write is reported here as an error toast and then swallowed, so without a
  /// result the caller cannot tell success from failure and would go on to
  /// announce a success that did not happen and clear the user's input.
  Future<bool> addKnownHostKeys(String host, List<String> keyLines) async {
    try {
      await _configManager.writeKnownHostKeys(host, keyLines);
      if (_disposed) return false;
      await refreshHosts();
      return true;
    } on SshConfigException catch (e) {
      if (!_disposed) ToastService.instance.showError(e);
      return false;
    } catch (e) {
      if (!_disposed) ToastService.instance.showError(_asException(e));
      return false;
    }
  }

  /// Enters edit mode for the config file.
  void beginEditing() {
    _isEditing = true;
    _notify();
  }

  /// Leaves edit mode and returns the on-disk contents of the config file.
  ///
  /// Cancel means "discard my edits and go back to what is actually on disk",
  /// so this re-reads the file rather than handing back the cached
  /// [_configText]: the file may have been changed by something else since the
  /// last refresh, and restoring a stale copy would silently discard that.
  ///
  /// Returns the refreshed text. If the read fails the cached value is
  /// returned unchanged, so the editor is never left blank.
  String cancelEditing() {
    _isEditing = false;
    try {
      _configText = _configManager.readConfig();
    } on SshConfigException catch (e, st) {
      // Keep the previous value; surfacing a toast here would double up with
      // whatever the user does next.
      log('Config re-read failed; keeping the cached text for the editor.',
          name: 'ssh_panel', error: e, stackTrace: st);
    }
    _notify();
    return _configText;
  }

  // -----------------------------------------------------------------------
  // Parsing helpers (pure, and therefore directly testable)
  // -----------------------------------------------------------------------

  /// Body of the toast shown after a successful check.
///
/// Every algorithm goes in, one per line. The badge next to the row can only
/// fit a count, and a comma-joined run of names wraps into an unreadable block
/// as soon as a host offers more than three keys -- which is the normal case.
static String checkResultMessage(List<String> keyTypes) =>
    '${keyTypes.length} ${keyTypes.length == 1 ? 'key type' : 'key types'}:\n'
    '${keyTypes.map((type) => '  $type').join('\n')}';

/// Body of the toast shown when a check finds nothing at all.
///
/// Says what did happen rather than only what did not: the scan ran and the
/// host stayed silent, which is a different problem from a scan that failed.
static const String unreachableMessage =
    'No response. Check the hostname and that port 22 is reachable.';

/// Extracts the distinct key algorithms from raw `ssh-keyscan` output.
  ///
  /// Each line is `host keytype base64...`, so the algorithm is field 1.
  static List<String> parseKeyTypes(List<String> keyLines) {
    final seen = <String>{};
    for (final line in keyLines) {
      final entry = parseKeyLine(line);
      final keyType = entry?['keyType'];
      if (keyType != null && keyType.isNotEmpty) seen.add(keyType);
    }
    return seen.toList();
  }

  /// Splits one known_hosts / ssh-keyscan line into key type and full line.
  ///
  /// Returns `null` for anything that is not a key entry: blank lines, comment
  /// lines (known_hosts files legitimately carry `#` comments, and the second
  /// whitespace-separated field of a comment is prose, not an algorithm), and
  /// malformed lines with no second field.
  static Map<String, String>? parseKeyLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.startsWith('#')) return null;
    // known_hosts may mark revoked keys with a leading @cert-authority.
    if (trimmed.startsWith('@')) return null;
    final tokens = trimmed.split(RegExp(r'\s+'));
    if (tokens.length < 2 || tokens[1].isEmpty) return null;
    return <String, String>{'keyType': tokens[1], 'line': trimmed};
  }

  // -----------------------------------------------------------------------

  void _setLoading(bool value) {
    if (_isLoading == value) return;
    _isLoading = value;
    _notify();
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  /// Wraps a non-[Exception] throwable so it can go through the typed toast
  /// mapper instead of leaking its `toString`.
  static Exception _asException(Object e) =>
      e is Exception ? e : Exception(e.toString());

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
