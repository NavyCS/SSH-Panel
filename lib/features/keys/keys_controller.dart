import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../services/agent_state.dart';
import '../../services/ssh_keys.dart';
import '../../services/ssh_service.dart';
import '../../toast_service.dart';

/// Owns the state and the I/O of the Keys tab.
///
/// Same split as [DomainsController]: everything here is state plus
/// `SshKeyManager` calls, and nothing needs a `BuildContext`. The tab's
/// `State` keeps only the six dialogs and the `TextEditingController`s they
/// create.
///
/// Two details worth knowing:
///
/// * The generation counter in [refresh] is kept deliberately. It is not a
///   cancellation token -- it answers a different question. A token cancels
///   work in progress cooperatively; the generation answers "is this result
///   still the newest one?", which is what [refresh] needs, since two refreshes
///   both have to finish their reads but only the newer one's result may be
///   published.
///
/// * [isKeyLoaded] reads two collections at once, so it is exposed as a method
///   rather than a cached flag: caching it would mean invalidating the cache on
///   every mutation of either collection.
class KeysController extends ChangeNotifier {
  KeysController({
    SshKeyManager? keyManager,
    SshServiceManager? serviceManager,
  })  : _keyManager = keyManager ??
            SshKeyManager(onWarning: ToastService.instance.showErrorMessage),
        _serviceManager = serviceManager ?? SshServiceManager() {
    // The agent can be started or stopped from the Service tab while this tab
    // is open. Subscribing here keeps Load/Unload enabled state correct without
    // the widget touching the global notifier.
    _agentStateListener = _onAgentStateChanged;
    agentServiceState.addListener(_agentStateListener);
  }

  final SshKeyManager _keyManager;
  final SshServiceManager _serviceManager;

  late final VoidCallback _agentStateListener;

  List<String> _keyFiles = [];
  List<LoadedKey> _loadedKeys = [];
  List<AuthorizedKey> _authorizedKeys = [];
  Map<String, String> _keyFingerprints = {};
  Map<String, bool> _hasPubKey = {};
  Map<String, String> _keyComments = {};
  bool _loading = false;
  bool _agentRunning = false;
  int _refreshGeneration = 0;
  bool _disposed = false;

  /// True once a refresh has completed at least once, whatever the outcome.
  ///
  /// This is what separates "the tab has nothing to show yet" from "an action
  /// is running over data we already have". A single isLoading flag drove both,
  /// so unloading a single key replaced all three cards with a spinner and the
  /// rest of the tab disappeared for the duration.
  bool _hasLoadedOnce = false;

  /// The key file an operation is currently running against, if any.
  ///
  /// Used to show progress on the affected row instead of over the whole tab.
  String? _busyKeyPath;

  /// Paths of the private keys found in `~/.ssh`.
  List<String> get keyFiles => _keyFiles;

  /// Keys currently held by the running agent.
  List<LoadedKey> get loadedKeys => _loadedKeys;

  List<AuthorizedKey> get authorizedKeys => _authorizedKeys;

  /// Whether the agent is running, which gates Load and Unload.
  bool get agentRunning => _agentRunning;

  /// True while any operation is running.
  ///
  /// Use this to disable actions and prevent concurrent mutations of the agent.
  /// Do **not** use it to hide content: see [isInitialLoad].
  bool get isLoading => _loading;

  /// True only while there is nothing to display yet.
  ///
  /// This is the state that justifies replacing the tab's content with a
  /// spinner. Once any data has arrived the cards stay on screen through every
  /// later operation, so a single-key action no longer wipes the view.
  bool get isInitialLoad => _loading && !_hasLoadedOnce;

  /// The key file an operation is running against, for inline row progress.
  bool isBusyWith(String path) => _busyKeyPath == path;

  /// `~/.ssh`, or empty when USERPROFILE is unset.
  String get sshDirectory => _keyManager.sshDirectory;

  /// Fingerprint for the key at [path], or `null` when it could not be read.
  String? fingerprintOf(String path) => _keyFingerprints[path];

  /// Whether a `.pub` file sits next to the private key at [path].
  bool hasPublicKey(String path) => _hasPubKey[path] ?? false;

  /// Comment recorded on the key at [path], if any.
  String? commentOf(String path) => _keyComments[path];

  /// Reloads key files, agent contents, authorized_keys and per-key metadata.
  ///
  /// Safe to call concurrently: each call claims a generation and only the
  /// newest one publishes, so a slow earlier call cannot overwrite fresher
  /// state. This mattered in practice -- two Refresh clicks started two
  /// overlapping six-await runs that raced to assign the same fields.
  Future<void> refresh() async {
    final generation = ++_refreshGeneration;
    _setLoading(true);
    try {
      final keyFiles = await _keyManager.listKeyFiles()
          .timeout(const Duration(seconds: 30));
      final authorizedKeys = await _keyManager.listAuthorizedKeys()
          .timeout(const Duration(seconds: 30));

      // Query the agent first. When it is stopped, `ssh-add -l` would hang
      // trying to reach the named pipe, so skip it entirely.
      SshServiceState agentState;
      try {
        agentState = await _serviceManager.checkStatus();
      } catch (_) {
        agentState = SshServiceState.stopped;
      }
      final agentRunning = agentState == SshServiceState.running;

      final loadedKeys = agentRunning
          ? await _keyManager.listLoadedKeys()
              .timeout(const Duration(seconds: 30))
          : <LoadedKey>[];

      final metadata = await _loadKeyMetadata(keyFiles);

      if (_disposed || generation != _refreshGeneration) return;
      // Reassign rather than mutate: the getters hand these out, and mutating
      // a published collection in place would skip the notification.
      _keyFiles = keyFiles;
      _loadedKeys = loadedKeys;
      _keyFingerprints = metadata.fingerprints;
      _hasPubKey = metadata.hasPub;
      _keyComments = metadata.comments;
      _authorizedKeys = authorizedKeys;
      _agentRunning = agentRunning;
    } on TimeoutException catch (_) {
      if (_disposed || generation != _refreshGeneration) return;
      ToastService.instance.showError(TimeoutException(
          'Refresh timed out — the ssh-agent may be unresponsive.'));
    } on SshKeyException catch (e) {
      if (_disposed || generation != _refreshGeneration) return;
      ToastService.instance.showError(e);
    } catch (e) {
      if (_disposed || generation != _refreshGeneration) return;
      ToastService.instance.showError(
          e is Exception ? e : Exception(e.toString()));
    } finally {
      // Only the newest run may clear the spinner, or a superseded run would
      // leave it off while the newer one is still working.
      if (!_disposed && generation == _refreshGeneration) {
        // Even a failed refresh means we have been asked and have answered, so
        // later refreshes must not blank the tab again.
        _hasLoadedOnce = true;
        _setLoading(false);
      }
    }
  }

  Future<_KeyMetadata> _loadKeyMetadata(List<String> keyFiles) async {
    final fingerprints = <String, String>{};
    final hasPub = <String, bool>{};
    final comments = <String, String>{};
    for (final path in keyFiles) {
      final fp = await _keyManager.getKeyFingerprint(path);
      if (fp != null) {
        fingerprints[path] = fp;
      }
      hasPub[path] = await File('$path.pub').exists();
      final comment = await _keyManager.getKeyComment(path);
      if (comment != null && comment.isNotEmpty) {
        comments[path] = comment;
      }
    }
    return _KeyMetadata(fingerprints, hasPub, comments);
  }

  /// The contents of the `.pub` file that sits next to the key at [path].
  ///
  /// Returns `null` when there is no `.pub` file, which is also when the
  /// "View public key" action should be unavailable.
  Future<String?> readPublicKey(String path) async {
    try {
      return await _keyManager.readPublicKey(path);
    } catch (e) {
      if (_disposed) return null;
      ToastService.instance.showError(
          e is Exception ? e : Exception(e.toString()));
      return null;
    }
  }

  /// Whether the key at [path] is encrypted and therefore needs a passphrase.
  ///
  /// The caller uses this to decide whether to prompt before calling
  /// [loadKey]; reading a passphrase needs a dialog, which a controller has no
  /// way to open.
  Future<bool> hasPassphrase(String path) async {
    try {
      return await _keyManager.hasPassphrase(path);
    } catch (e) {
      if (_disposed) return false;
      ToastService.instance.showError(
          e is Exception ? e : Exception(e.toString()));
      return false;
    }
  }

  /// Loads the key at [path] into the agent.
  ///
  /// [passphrase] must already be collected by the caller: reading it needs a
  /// dialog, and a controller has no BuildContext to open one with.
  Future<void> loadKey(String path, String? passphrase) async {
    _busyKeyPath = path;
    _setLoading(true);
    try {
      await _keyManager.addKey(path, passphrase: passphrase);
      if (_disposed) return;
      ToastService.instance.showSuccess('Key added.');
      await refresh();
    } on SshKeyException catch (e) {
      if (_disposed) return;
      // A wrong passphrase is a recoverable user error with an obvious cause,
      // so it gets plain wording instead of the typed exception text.
      if (e.code == SshKeyErrorCode.wrongPassphrase) {
        ToastService.instance
            .showErrorMessage('The passphrase is incorrect.');
      } else {
        ToastService.instance.showError(e);
      }
    } catch (e) {
      if (_disposed) return;
      ToastService.instance.showError(
          e is Exception ? e : Exception(e.toString()));
    } finally {
      _busyKeyPath = null;
      _setLoading(false);
    }
  }

  /// Unloads the key at [path] from the agent.
  Future<void> unloadKey(String path) async {
    _busyKeyPath = path;
    _setLoading(true);
    try {
      await _keyManager.removeKey(path);
      if (_disposed) return;
      ToastService.instance.showSuccess('Key removed.');
      await refresh();
    } on SshKeyException catch (e) {
      if (_disposed) return;
      ToastService.instance.showError(e);
    } catch (e) {
      if (_disposed) return;
      ToastService.instance.showError(
          e is Exception ? e : Exception(e.toString()));
    } finally {
      _busyKeyPath = null;
      _setLoading(false);
    }
  }

  /// Unloads every key from the agent.
  Future<void> unloadAll() async {
    _setLoading(true);
    try {
      await _keyManager.removeAll();
      if (_disposed) return;
      ToastService.instance.showSuccess('All keys removed.');
      await refresh();
    } on SshKeyException catch (e) {
      if (_disposed) return;
      ToastService.instance.showError(e);
    } catch (e) {
      if (_disposed) return;
      ToastService.instance.showError(
          e is Exception ? e : Exception(e.toString()));
    } finally {
      _setLoading(false);
    }
  }

  /// Generates a new key.
  ///
  /// Throws [SshKeyException] with [SshKeyErrorCode.fileExists] when the name is
  /// already taken, so the caller can offer to replace it. The replacement
  /// itself is [replaceKey], which deletes first.
  Future<void> generateKey({
    required String name,
    required KeyAlgorithm algorithm,
    String? comment,
    String? passphrase,
  }) async {
    _setLoading(true);
    try {
      await _keyManager.generateKey(
        name: name,
        algorithm: algorithm,
        comment: comment,
        passphrase: passphrase,
      );
      if (_disposed) return;
      ToastService.instance.showSuccess('Key generated.');
      await refresh();
    } on SshKeyException catch (e) {
      if (_disposed) return;
      // fileExists is an expected outcome the caller handles with a dialog, so
      // it is rethrown rather than reported here.
      if (e.code != SshKeyErrorCode.fileExists) {
        ToastService.instance.showError(e);
      }
      rethrow;
    } catch (e) {
      if (_disposed) return;
      ToastService.instance.showError(
          e is Exception ? e : Exception(e.toString()));
      rethrow;
    } finally {
      _setLoading(false);
    }
  }

  /// Deletes the key at [path] and its `.pub`, generating over any existing
  /// pair.
  Future<void> replaceKey({
    required String name,
    required KeyAlgorithm algorithm,
    String? comment,
    String? passphrase,
  }) async {
    final dir = _keyManager.sshDirectory;
    final keyPath = '$dir\\$name';
    try {
      for (final path in [keyPath, '$keyPath.pub']) {
        final file = File(path);
        if (await file.exists()) await file.delete();
      }
    } catch (e) {
      if (_disposed) return;
      ToastService.instance.showError(
          e is Exception ? e : Exception(e.toString()));
      return;
    }
    await generateKey(
      name: name,
      algorithm: algorithm,
      comment: comment,
      passphrase: passphrase,
    );
  }

  /// Runs an `authorized_keys` mutation under the shared busy/toast contract.
  ///
  /// Adding and removing are the same sequence -- spin up, mutate, report,
  /// refresh -- so they share one body instead of two copies that would drift
  /// the first time one of them is fixed and the other is not.
  Future<void> _mutateAuthorizedKeys(
    String successMessage,
    Future<void> Function() mutation,
  ) async {
    _setLoading(true);
    try {
      await mutation();
      if (_disposed) return;
      ToastService.instance.showSuccess(successMessage);
      await refresh();
    } on SshKeyException catch (e) {
      if (_disposed) return;
      ToastService.instance.showError(e);
    } catch (e) {
      if (_disposed) return;
      ToastService.instance.showError(
          e is Exception ? e : Exception(e.toString()));
    } finally {
      _setLoading(false);
    }
  }

  /// Appends [line] to `~/.ssh/authorized_keys`.
  Future<void> addAuthorizedKey(String line) => _mutateAuthorizedKeys(
      'Authorized key added.', () => _keyManager.addAuthorizedKey(line));

  /// Removes the entry identified by [rawLine] from `~/.ssh/authorized_keys`.
  ///
  /// Takes the raw line rather than an [AuthorizedKey] because that is what the
  /// manager matches on: the parsed view drops the original spacing and comment,
  /// so it cannot be used to locate the entry again.
  Future<void> removeAuthorizedKey(String rawLine) => _mutateAuthorizedKeys(
      'Authorized key removed.',
      () => _keyManager.removeAuthorizedKey(rawLine));

  /// Deletes the private key at [path] and its `.pub`.
  ///
  /// Unloads it from the agent first when it is loaded, so the agent is never
  /// left holding a key whose file no longer exists. That unload is
  /// best-effort: a failure there is reported but does not stop the delete,
  /// which is what the tab did before -- refusing to delete would leave the
  /// user unable to remove a file the agent had wedged itself on.
  Future<void> deleteKeyFile(String path) async {
    _busyKeyPath = path;
    _setLoading(true);
    try {
      if (isKeyLoaded(path)) {
        try {
          await _keyManager.removeKey(path);
        } on SshKeyException catch (e) {
          if (!_disposed) ToastService.instance.showError(e);
        }
      }
      await _keyManager.deleteKeyFile(path);
      if (_disposed) return;
      ToastService.instance.showSuccess('Key file deleted.');
      await refresh();
    } on SshKeyException catch (e) {
      if (_disposed) return;
      ToastService.instance.showError(e);
    } catch (e) {
      if (_disposed) return;
      ToastService.instance.showError(
          e is Exception ? e : Exception(e.toString()));
    } finally {
      _busyKeyPath = null;
      _setLoading(false);
    }
  }

  // -----------------------------------------------------------------------
  // Pure helpers
  // -----------------------------------------------------------------------

  /// Whether the key at [path] is currently held by the agent.
  ///
  /// Matches on fingerprint first, because that is unambiguous. Falls back to
  /// path comparison because `ssh-add -l` reports the path as the agent sees it,
  /// which is not always byte-identical to the path we scanned: it may use
  /// forward slashes, different casing, or only the file name.
  bool isKeyLoaded(String path) {
    final fp = _keyFingerprints[path];
    if (fp != null && fp.isNotEmpty) {
      if (_loadedKeys.any((k) => k.fingerprint == fp)) return true;
    }
    final normalizedPath = normalizePath(path);
    final fileName = shortPath(path).toLowerCase();
    return _loadedKeys.any((k) {
      final kPath = normalizePath(k.path);
      return kPath == normalizedPath ||
          kPath.endsWith('\\$fileName') ||
          kPath == fileName;
    });
  }

  /// The final path segment of [path], for both Windows and POSIX separators.
  static String shortPath(String path) {
    final parts = path.split(RegExp(r'[/\\]'));
    return parts.isNotEmpty ? parts.last : path;
  }

  /// Canonical form for comparing two paths that may have been written
  /// differently: backslashes, lower case.
  static String normalizePath(String path) =>
      path.replaceAll('/', '\\').toLowerCase();

  // -----------------------------------------------------------------------

  void _onAgentStateChanged() {
    // The agent came up or went down in the other tab; reload so Load/Unload
    // enablement and the Loaded Keys card match reality.
    refresh();
  }

  void _setLoading(bool value) {
    if (_disposed || _loading == value) return;
    _loading = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    agentServiceState.removeListener(_agentStateListener);
    super.dispose();
  }
}

/// Per-key metadata read alongside the file list.
class _KeyMetadata {
  const _KeyMetadata(this.fingerprints, this.hasPub, this.comments);

  final Map<String, String> fingerprints;
  final Map<String, bool> hasPub;
  final Map<String, String> comments;
}
