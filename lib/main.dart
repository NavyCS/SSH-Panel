import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'features/service/service_controller.dart';
import 'services/agent_state.dart';
import 'services/settings_service.dart';
import 'services/ssh_domains.dart';
import 'services/ssh_keys.dart';
import 'services/ssh_service.dart';
import 'shared/dialogs/passphrase_dialog.dart';
import 'shared/widgets/action_row.dart';
import 'shared/widgets/disabled_action_wrapper.dart';
import 'shared/widgets/host_status_badge.dart';
import 'toast_service.dart';

/// Re-exported so the tabs keep importing it from the entrypoint while the
/// definition lives in a module a controller can also reach.
export 'services/agent_state.dart' show agentServiceState;

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await SettingsService.getElevationMode();

  // Global uncaught-error handler: route every unhandled Flutter/async
  // error to the toaster instead of the red debug screen. Never rethrows -
  // the handler only reports, it does not change control flow.
  FlutterError.onError = (FlutterErrorDetails details) {
    ToastService.instance.handleError(details.exception, details.stack ?? StackTrace.empty);
  };
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    ToastService.instance.handleError(error, stack);
    return true;
  };

  // Normal UI path — run the Flutter app.
  runApp(const SshPanelApp());
}


// ---------------------------------------------------------------------------
// App root
// ---------------------------------------------------------------------------

class SshPanelApp extends StatelessWidget {
  const SshPanelApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ShadApp(
      title: 'SSH Panel',
      home: const SshPanelShell(),
    );
  }
}

// ---------------------------------------------------------------------------
// Shell — title bar + tabs
// ---------------------------------------------------------------------------

class SshPanelShell extends StatefulWidget {
  const SshPanelShell({super.key});

  @override
  State<SshPanelShell> createState() => _SshPanelShellState();
}

class _SshPanelShellState extends State<SshPanelShell> {
  late final ShadTabsController<String> _tabsController;
  String _elevationMode = SettingsService.modePerAction;

  @override
  void initState() {
    super.initState();
    _tabsController = ShadTabsController<String>(value: 'service');
    _elevationMode = SettingsService.elevationModeNotifier.value;
    SettingsService.elevationModeNotifier.addListener(_onElevationModeChanged);
    _loadElevationMode();
    // Capture the ShadToaster state once the first frame is built so any
    // code (including the global uncaught-error handler) can emit toasts.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ToastService.instance.setState(ShadToaster.of(context));
      }
    });
  }

  void _onElevationModeChanged() {
    if (mounted) {
      setState(() {
        _elevationMode = SettingsService.elevationModeNotifier.value;
      });
    }
  }

  Future<void> _loadElevationMode() async {
    final mode = await SettingsService.getElevationMode();
    if (mounted) {
      setState(() => _elevationMode = mode);
    }
  }

  void _showSettingsDialog() {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setStateDialog) => ShadDialog(
          title: const Text('Settings'),
          description: const Text('Choose your elevation mode.'),
          actions: [
            Semantics(
              button: true,
              label: 'Close',
              child: ShadButton.ghost(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Close'),
              ),
            ),
          ],
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ShadSelect<String>(
                initialValue: _elevationMode,
                options: [
                  ShadOption<String>(
                    value: SettingsService.modePerAction,
                    child: const Text('Per action'),
                  ),
                  ShadOption<String>(
                    value: SettingsService.modeOnce,
                    child: const Text('Once'),
                  ),
                ],
                selectedOptionBuilder: (context, value) {
                  return Text(
                    value == SettingsService.modePerAction
                        ? 'Per action'
                        : 'Once',
                  );
                },
                onChanged: (value) async {
                  if (value != null) {
                    await SettingsService.setElevationMode(value);
                    if (mounted) {
                      setState(() => _elevationMode = value);
                    }
                    setStateDialog(() {});
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool get _isElevated => SettingsService.isProcessElevated();

  @override
  void dispose() {
    SettingsService.elevationModeNotifier.removeListener(_onElevationModeChanged);
    _tabsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final isAdminMode = _isElevated;

    return Column(
      children: [
        // ---- Title bar ----
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: theme.colorScheme.card,
            border: Border(
              bottom: BorderSide(color: theme.colorScheme.border),
            ),
          ),
          child: Row(
            children: [
              SvgPicture.asset(
                'assets/logo.svg',
                width: 40,
                height: 40,
              ),
              const SizedBox(width: 10),
              Text(
                'SSH Panel',
                style: theme.textTheme.h3,
              ),
              const Spacer(),
              if (isAdminMode) ...[
                Semantics(
                  button: true,
                  label: 'Admin Mode',
                  child: const ShadButton.outline(
                    size: ShadButtonSize.sm,
                    onPressed: null,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(LucideIcons.shield, size: 13),
                        SizedBox(width: 5),
                        Text('Admin Mode'),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ] else if (_elevationMode == SettingsService.modeOnce) ...[
                ShadTooltip(
                  builder: (context) => const Text('Restart the app with administrator rights'),
                  child: Semantics(
                    button: true,
                    label: 'Restart in Admin Mode',
                    child: ShadButton.outline(
                      size: ShadButtonSize.sm,
                      onPressed: () {
                        SettingsService.restartElevated();
                      },
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(LucideIcons.shield, size: 13),
                          SizedBox(width: 5),
                          Text('Restart in Admin Mode'),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              ShadTooltip(
                builder: (context) => const Text('Settings'),
                child: Semantics(
                  button: true,
                  label: 'Settings',
                  child: ShadIconButton(
                    icon: const Icon(LucideIcons.settings),
                    iconSize: 18,
                    onPressed: _showSettingsDialog,
                  ),
                ),
              ),
            ],
          ),
        ),

        // ---- Tabs ----
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: ShadTabs<String>(
              controller: _tabsController,
              gap: 12,
              tabs: [
                ShadTab(
                  value: 'service',
                  content: const ServiceTab(),
                  expandContent: true,
                  child: const Text('Service'),
                ),
                ShadTab(
                  value: 'keys',
                  content: const KeysTab(),
                  expandContent: true,
                  child: const Text('Keys'),
                ),
                ShadTab(
                  value: 'domains',
                  content: const DomainsTab(),
                  expandContent: true,
                  child: const Text('Domains'),
                ),
              ],
            ),
          ),
        ),
],
);
    }
  }

// Service tab

class ServiceTab extends StatefulWidget {
  const ServiceTab({super.key});

  @override
  State<ServiceTab> createState() => _ServiceTabState();
}

class _ServiceTabState extends State<ServiceTab> {
  /// The tab's state and async logic live in [ServiceController].
  ///
  /// It used to live here, which meant every method carried an
  /// `if (!mounted) return;` after each `await` -- roughly half of this class
  /// was bookkeeping about whether the widget was still alive. The controller
  /// cancels its own polling token in `dispose()`, so nothing has to check.
  final _controller = ServiceController();

  @override
  void initState() {
    super.initState();
    _controller.refresh();
    SettingsService.elevationModeNotifier.addListener(_onModeChanged);
  }

  void _onModeChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    SettingsService.elevationModeNotifier.removeListener(_onModeChanged);
    // Cancels the SCM polling loops and detaches every listener.
    _controller.dispose();
    super.dispose();
  }

  String _statusLabel(SshServiceState state) => ServiceController.statusLabel(state);

  @override
  Widget build(BuildContext context) {
    // Rebuild the tab whenever the controller publishes new state. The
    // controller is a ChangeNotifier, so a plain listenable is enough; the tab
    // no longer needs a setState per state transition.
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) => _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    final theme = ShadTheme.of(context);
    final isElevated = SettingsService.isProcessElevated();
    final isOnceMode = SettingsService.elevationModeNotifier.value == SettingsService.modeOnce;
    final adminEnabled = isElevated || !isOnceMode;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
// ---- Status card ----
          LayoutBuilder(
            builder: (context, constraints) => ShadCard(
              width: constraints.maxWidth,
              title: Row(
                children: [
                  const Text('Agent Status'),
                  const SizedBox(width: 8),
                  if (!_controller.isLoading)
                    ShadBadge(
                      child: Text(
                        _controller.status != null
                            ? _statusLabel(_controller.status!)
                            : 'Unknown',
                      ),
                    ),
                ],
              ),
              description: const Text('Current state of the ssh-agent service'),
              child: Padding(
                padding: const EdgeInsets.only(top: 12),
                child: _controller.isLoading
                    ? Row(
                        children: [
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 10),
                          Text('Loading...', style: theme.textTheme.muted),
                        ],
                      )
                    : Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          Semantics(
                            button: true,
                            label: 'Start Service',
                            child: ShadButton(
                              onPressed: _controller.isLoading ? null : _controller.start,
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(LucideIcons.play, size: 14),
                                  SizedBox(width: 6),
                                  Text('Start'),
                                ],
                              ),
                            ),
                          ),
                          Builder(
                            builder: (context) {
                              Widget stopBtn = Semantics(
                                button: true,
                                label: 'Stop Service',
                                child: ShadButton.destructive(
                                  onPressed: (_controller.isLoading || !adminEnabled) ? null : _controller.stop,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(
                                        LucideIcons.stopCircle,
                                        size: 14,
                                      ),
                                      if (!isElevated && !isOnceMode) ...[
                                        const SizedBox(width: 4),
                                        const Icon(LucideIcons.shield, size: 14),
                                      ],
                                      const SizedBox(width: 6),
                                      const Text('Stop'),
                                    ],
                                  ),
                                ),
                              );

                              if (!adminEnabled) {
                                return DisabledActionWrapper(
                                  enabled: false,
tooltip: 'Requires administrator privileges. Use the "Restart in Admin Mode" button in the top bar.',
                                  child: stopBtn,
                                );
                              }
                              if (!isElevated) {
                                return ShadTooltip(
                                  builder: (context) => const Text('This action will prompt for administrator confirmation (UAC)'),
                                  child: stopBtn,
                                );
                              }
                              return stopBtn;
                            },
                          ),
                          Semantics(
                            button: true,
                            label: 'Refresh Status',
                            child: ShadButton.outline(
                              onPressed: _controller.isLoading ? null : _controller.refresh,
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(LucideIcons.refreshCw, size: 14),
                                  SizedBox(width: 6),
                                  Text('Refresh'),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ),

          const SizedBox(height: 16),

          // ---- Startup type card ----
          LayoutBuilder(
            builder: (context, constraints) {
              // `initialValue` is null when the SCM could not be queried, so the
              // select renders empty instead of asserting a value we did not
              // read. The helper text below explains that state.
              Widget selectWidget = ShadSelect<StartupType>(
                initialValue: _controller.startupType,
                enabled: !_controller.isStartupTypeLoading && adminEnabled,
                options: StartupType.values.map((type) {
                  final label =
                      type.name[0].toUpperCase() + type.name.substring(1);
                  return ShadOption<StartupType>(
                    value: type,
                    child: Text(label),
                  );
                }).toList(),
                selectedOptionBuilder: (context, value) {
                  return Text(
                    value.name[0].toUpperCase() + value.name.substring(1),
                  );
                },
                onChanged: (value) {
                  if (value != null) _controller.setStartupType(value);
                },
              );

              if (!adminEnabled) {
                selectWidget = DisabledActionWrapper(
                  enabled: false,
                  tooltip: 'Requires administrator privileges. Use the "Restart in Admin Mode" button in the top bar.',
                  child: selectWidget,
                );
              }

              return ShadCard(
                width: constraints.maxWidth,
                title: Row(
                  children: [
                    const Text('Startup Type'),
                    const SizedBox(width: 8),
                    if (!isElevated)
                      ShadTooltip(
                        builder: (context) => Text(
                          isOnceMode
                              ? 'Disabled: requires Admin Mode (top bar)'
                              : 'Changing this option will prompt for administrator confirmation (UAC)',
                        ),
                        child: Icon(
                          LucideIcons.shield,
                          size: 14,
                          color: isOnceMode
                              ? theme.colorScheme.mutedForeground
                              : theme.colorScheme.primary,
                        ),
                      ),
                  ],
                ),
                description: Text(
                  !adminEnabled
                      ? 'Configure how the ssh-agent service starts with Windows (Requires Admin Mode)'
                      : 'Configure how the ssh-agent service starts with Windows',
                ),
                child: Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      selectWidget,
                      if (_controller.startupType == null &&
                          !_controller.isStartupTypeLoading)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            'Unknown — the current startup type could not be read from the Service Control Manager.',
                            style: theme.textTheme.small.copyWith(
                              color: theme.colorScheme.mutedForeground,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

// Reusable Action Wrapper for Disabled States
//
// Moved to lib/shared/widgets/disabled_action_wrapper.dart, where it now lives
// alongside ActionRow and the corrected contrast/semantics behaviour.

class _KeyGenerationParams {
  const _KeyGenerationParams({
    required this.effectiveName,
    required this.algorithm,
    required this.comment,
    required this.passphraseProtected,
  });

  final String effectiveName;
  final KeyAlgorithm algorithm;
  final String? comment;
  final bool passphraseProtected;
}

class KeysTab extends StatefulWidget {
  const KeysTab({super.key});

  @override
  State<KeysTab> createState() => _KeysTabState();
}

class _KeysTabState extends State<KeysTab> {
  final _keyManager = SshKeyManager();
  final _serviceManager = SshServiceManager();
  List<String> _keyFiles = [];
  List<LoadedKey> _loadedKeys = [];
  List<AuthorizedKey> _authorizedKeys = [];
  Map<String, String> _keyFingerprints = {};
  Map<String, bool> _hasPubKey = {};
  Map<String, String> _keyComments = {};
  bool _loading = false;
  bool _agentRunning = false;

  /// Incremented by every [_refresh]. Used to discard the results of a
  /// superseded run so a slow earlier call cannot overwrite a newer one.
  int _refreshGeneration = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
    // When the Service tab starts or stops the agent, refresh this tab so
    // Load/Unload buttons and the Loaded Keys card stay in sync.
    agentServiceState.addListener(_onAgentServiceChanged);
  }

  void _onAgentServiceChanged() {
    if (mounted) _refresh();
  }

  @override
  void dispose() {
    agentServiceState.removeListener(_onAgentServiceChanged);
    super.dispose();
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    // Generation guard. _refresh runs six sequential awaits, so two clicks on
    // Refresh (or a click while a previous refresh is still in flight) used to
    // start two overlapping runs that raced to assign _keyFiles/_loadedKeys.
    // Whichever finished last won, which could be the *older* run. Each call
    // now claims a generation; only the newest one may commit.
    final generation = ++_refreshGeneration;
    setState(() {
      _loading = true;
    });
    try {
      final keyFiles = await _keyManager.listKeyFiles()
          .timeout(const Duration(seconds: 30));
      final authorizedKeys = await _keyManager.listAuthorizedKeys()
          .timeout(const Duration(seconds: 30));

      // Query the agent state first. When it is stopped, `ssh-add -l` would
      // hang trying to reach the named pipe, so we skip it entirely.
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

      if (!mounted) return;
      // A newer refresh has started while this one was awaiting; drop these
      // results so they cannot overwrite fresher state.
      if (generation != _refreshGeneration) return;
      setState(() {
        _keyFiles = keyFiles;
        _loadedKeys = loadedKeys;
        _keyFingerprints = fingerprints;
        _hasPubKey = hasPub;
        _keyComments = comments;
        _authorizedKeys = authorizedKeys;
        _agentRunning = agentRunning;
        _loading = false;
      });
    } on TimeoutException catch (_) {
      if (!mounted || generation != _refreshGeneration) return;
      ToastService.instance.showError(
          TimeoutException('Refresh timed out — the ssh-agent may be unresponsive.'));
      setState(() => _loading = false);
    } on SshKeyException catch (e) {
      if (!mounted || generation != _refreshGeneration) return;
      ToastService.instance.showError(e);
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted || generation != _refreshGeneration) return;
      ToastService.instance.showError(e is Exception
          ? e
          : Exception(e.toString()));
      setState(() => _loading = false);
    }
  }

  Future<void> _addKey(String path) async {
    setState(() {
      _loading = true;
    });
    try {
      if (await _keyManager.hasPassphrase(path)) {
        final passphrase = await _promptPassphrase();
        if (passphrase == null) {
          if (!mounted) return;
          setState(() => _loading = false);
          return;
        }
        await _keyManager.addKey(path, passphrase: passphrase);
        if (!mounted) return;
        await _refresh();
        if (mounted) {
          ToastService.instance.showSuccess('Key added.');
        }
      } else {
        await _keyManager.addKey(path);
        if (!mounted) return;
        await _refresh();
        if (mounted) {
          ToastService.instance.showSuccess('Key added.');
        }
      }
    } on SshKeyException catch (e) {
      if (!mounted) return;
      if (e.code == SshKeyErrorCode.wrongPassphrase) {
        ToastService.instance.showErrorMessage('The passphrase is incorrect.');
      } else {
        ToastService.instance.showError(e);
      }
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      ToastService.instance.showError(e is Exception
          ? e
          : Exception(e.toString()));
      setState(() => _loading = false);
    }
  }

  /// Shows a dialog requesting the passphrase for a protected key.
  /// Asks for the passphrase of an *existing* key, in order to load it into the
  /// agent.
  ///
  /// Delegates to [promptPassphrase]. The wording is specific to this case: the
  /// key exists and is already encrypted, so the user is being asked to unlock
  /// something rather than to choose a new secret.
  Future<String?> _promptPassphrase() {
    return promptPassphrase(
      context,
      title: 'Passphrase required',
      description: 'This key is protected by a passphrase.',
      confirmLabel: 'Load',
    );
  }

  Future<void> _removeKey(String path) async {
    setState(() {
      _loading = true;
    });
    try {
      await _keyManager.removeKey(path);
      await _refresh();
      if (mounted) {
        ToastService.instance.showSuccess('Key removed.');
      }
    } on SshKeyException catch (e) {
      if (!mounted) return;
      ToastService.instance.showError(e);
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      ToastService.instance.showError(e is Exception
          ? e
          : Exception(e.toString()));
      setState(() => _loading = false);
    }
  }

  Future<void> _removeAll() async {
    setState(() {
      _loading = true;
    });
    try {
      await _keyManager.removeAll();
      await _refresh();
      if (mounted) {
        ToastService.instance.showSuccess('All keys removed.');
      }
    } on SshKeyException catch (e) {
      if (!mounted) return;
      ToastService.instance.showError(e);
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      ToastService.instance.showError(e is Exception
          ? e
          : Exception(e.toString()));
      setState(() => _loading = false);
    }
  }

  Future<_KeyGenerationParams?> _promptKeyGeneration() async {
    final nameController = TextEditingController();
    final commentController = TextEditingController();
    bool passphraseProtected = false;
    KeyAlgorithm algorithm = KeyAlgorithm.ed25519;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setStateDialog) => ShadDialog(
          title: const Text('Generate Key'),
          actions: [
            Semantics(
              button: true,
              label: 'Cancel key generation',
              child: ShadButton.ghost(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
            ),
            Semantics(
              button: true,
              label: 'Generate key',
              child: ShadButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Generate'),
              ),
            ),
          ],
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: double.infinity,
                child: ShadSelect<KeyAlgorithm>(
                  initialValue: algorithm,
                  options: KeyAlgorithm.values.map((algo) {
                    return ShadOption<KeyAlgorithm>(
                      value: algo,
                      child: Text(algo.label),
                    );
                  }).toList(),
                  selectedOptionBuilder: (context, value) {
                    return Text(value.label);
                  },
                  onChanged: (value) {
                    if (value != null) {
                      setStateDialog(() => algorithm = value);
                    }
                  },
                ),
              ),
              const SizedBox(height: 12),
              ShadInput(
                controller: nameController,
                placeholder: const Text('Key name (optional, ex. id_ed25519)'),
              ),
              const SizedBox(height: 12),
              ShadInput(
                controller: commentController,
                placeholder: const Text('Comment (optional, ex. myname@example.com)'),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  ShadCheckbox(
                    value: passphraseProtected,
                    onChanged: (value) {
                      setStateDialog(() => passphraseProtected = value);
                    },
                    label: const Text('Protect with passphrase'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    if (confirmed != true) return null;
    final name = nameController.text.trim();
    final effectiveName = name.isEmpty ? algorithm.defaultName : name;
    final comment = commentController.text.isEmpty ? null : commentController.text;
    return _KeyGenerationParams(
      effectiveName: effectiveName,
      algorithm: algorithm,
      comment: comment,
      passphraseProtected: passphraseProtected,
    );
  }

  Future<void> _handleExistingKeyConflict(String keyName, KeyAlgorithm algorithm, String? comment, String? passphrase) async {
    final replace = await showDialog<bool>(
      context: context,
      builder: (ctx) => ShadDialog(
        title: const Text('Key already exists'),
        description: const Text(
          'A key with this name already exists. Do you want to replace it?',
        ),
        actions: [
          Semantics(
            button: true,
            label: 'Cancel replace',
            child: ShadButton.ghost(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
          ),
          Semantics(
            button: true,
            label: 'Replace existing key',
            child: ShadButton.destructive(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Replace'),
            ),
          ),
        ],
      ),
    );
    if (replace != true || !mounted) return;

    final dir = _keyManager.sshDirectory;
    final keyPath = '$dir${Platform.pathSeparator}$keyName';
    final pubPath = '$keyPath.pub';
    try {
      final f1 = File(keyPath);
      if (await f1.exists()) await f1.delete();
      final f2 = File(pubPath);
      if (await f2.exists()) await f2.delete();
    } catch (e) {
      ToastService.instance.showError(e is Exception
          ? e
          : Exception(e.toString()));
    }

    try {
      await _keyManager.generateKey(
        name: keyName,
        algorithm: algorithm,
        comment: comment,
        passphrase: passphrase,
      );
      await _refresh();
      if (mounted) {
        ToastService.instance.showSuccess('Key generated.');
      }
    } catch (e) {
      if (!mounted) return;
      ToastService.instance.showError(e is Exception
          ? e
          : Exception(e.toString()));
      setState(() => _loading = false);
    }
  }

  Future<void> _generateKey() async {
    final params = await _promptKeyGeneration();
    if (params == null) return;

    String? passphrase;
    if (params.passphraseProtected) {
      // The dialog above was awaited, so this State may be gone by now; a
      // BuildContext is not valid across an async gap.
      if (!mounted) return;
      // Not _promptPassphrase(): that asks to *unlock* an existing key, and
      // says so. Here the key does not exist yet, so the dialog states what
      // the user is creating and what it will cost them.
      passphrase = await promptPassphrase(
        context,
        title: 'Choose a passphrase',
        description:
            'The new key will be encrypted with this passphrase. Keep it — '
            'there is no way to recover the key without it.',
        confirmLabel: 'Create key',
      );
      if (passphrase == null) return;
    }

    setState(() {
      _loading = true;
    });

    try {
      await _keyManager.generateKey(
        name: params.effectiveName,
        algorithm: params.algorithm,
        comment: params.comment,
        passphrase: passphrase,
      );
      await _refresh();
      if (mounted) {
        ToastService.instance.showSuccess('Key generated.');
      }
    } on SshKeyException catch (e) {
      if (!mounted) return;
      if (e.code == SshKeyErrorCode.fileExists) {
        await _handleExistingKeyConflict(params.effectiveName, params.algorithm, params.comment, passphrase);
      } else {
        ToastService.instance.showError(e);
        setState(() => _loading = false);
      }
    } catch (e) {
      if (!mounted) return;
      ToastService.instance.showError(e is Exception
          ? e
          : Exception(e.toString()));
      setState(() => _loading = false);
    }
  }

  String _shortPath(String path) {
    final parts = path.split(RegExp(r'[/\\]'));
    return parts.isNotEmpty ? parts.last : path;
  }

  void _openSshFolder() {
    final dir = _keyManager.sshDirectory;
    if (dir.isEmpty) return;
    Process.run('explorer', [dir], runInShell: false);
  }

  bool _isKeyLoaded(String path) {
    final fp = _keyFingerprints[path];
    if (fp != null && fp.isNotEmpty) {
      if (_loadedKeys.any((k) => k.fingerprint == fp)) {
        return true;
      }
    }
    final normalizedPath = path.replaceAll('/', '\\').toLowerCase();
    final fileName = _shortPath(path).toLowerCase();
    return _loadedKeys.any((k) {
      final kPath = k.path.replaceAll('/', '\\').toLowerCase();
      return kPath == normalizedPath ||
          kPath.endsWith('\\$fileName') ||
          kPath == fileName;
    });
  }

  Future<void> _addAuthorizedKeyDialog() async {
    final keyController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => ShadDialog(
        title: const Text('Add Authorized Key'),
        description: const Text(
          'Paste a public key line (e.g. ssh-ed25519 AAAAC3... user@host) to authorize incoming SSH connections.',
          style: TextStyle(fontSize: 14),
        ),
        actions: [
          Semantics(
            button: true,
            label: 'Cancel add authorized key',
            child: ShadButton.ghost(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
          ),
          Semantics(
            button: true,
            label: 'Add authorized key',
            child: ShadButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Add'),
            ),
          ),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: ShadInput(
            controller: keyController,
            placeholder: const Text('ssh-ed25519 AAAAC3NzaC1... user@machine'),
            maxLines: 3,
            minLines: 2,
          ),
        ),
      ),
    );

    if (confirmed != true) return;
    final text = keyController.text.trim();
    if (text.isEmpty) return;

    setState(() {
      _loading = true;
    });

    try {
      await _keyManager.addAuthorizedKey(text);
      await _refresh();
      if (mounted) {
        ToastService.instance.showSuccess('Authorized key added.');
      }
    } on SshKeyException catch (e) {
      if (!mounted) return;
      ToastService.instance.showError(e);
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      ToastService.instance.showError(e is Exception
          ? e
          : Exception(e.toString()));
      setState(() => _loading = false);
    }
  }

  Future<void> _removeAuthorizedKey(AuthorizedKey key) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => ShadDialog(
        title: const Text('Remove Authorized Key'),
        description: Text(
          'Are you sure you want to remove this key (${key.comment.isNotEmpty ? key.comment : key.type}) from authorized_keys?',
          style: const TextStyle(fontSize: 14),
        ),
        actions: [
          Semantics(
            button: true,
            label: 'Cancel remove key',
            child: ShadButton.ghost(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
          ),
          Semantics(
            button: true,
            label: 'Remove authorized key',
            child: ShadButton.destructive(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Remove'),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() {
      _loading = true;
    });

    try {
      await _keyManager.removeAuthorizedKey(key.rawLine);
      await _refresh();
      if (mounted) {
        ToastService.instance.showSuccess('Authorized key removed.');
      }
    } on SshKeyException catch (e) {
      if (!mounted) return;
      ToastService.instance.showError(e);
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      ToastService.instance.showError(e is Exception
          ? e
          : Exception(e.toString()));
      setState(() => _loading = false);
    }
  }

Widget _buildKeyFileRow(ShadThemeData theme, String path) {
    final isLoaded = _isKeyLoaded(path);
    final canLoad = !_loading && _agentRunning && !isLoaded;
    final canUnload = !_loading && _agentRunning && isLoaded;
    final hasPub = _hasPubKey[path] ?? false;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          const Icon(
            LucideIcons.keyRound,
            size: 14,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _shortPath(path),
                  style: theme.textTheme.small,
                ),
                if (_keyComments[path] != null && _keyComments[path]!.isNotEmpty)
                  Text(
                    _keyComments[path]!,
                    style: theme.textTheme.muted,
                  ),
              ],
            ),
          ),
          ActionRow(
            // Gaps between View|Load|Unload|Delete were 0 and 4 in the original
            // hand-written tree; a uniform 4 keeps the cluster legible without
            // changing which actions are adjacent.
            actions: [
              RowAction(
                label: 'View',
                onPressed:
                    !_loading && hasPub ? () => _viewPublicKey(path) : null,
                enabledTooltip: 'View public key of ${_shortPath(path)}',
                disabledTooltip: 'No .pub file for ${_shortPath(path)}',
              ),
              RowAction(
                label: 'Load',
                onPressed: canLoad ? () => _addKey(path) : null,
                enabledTooltip: 'Load ${_shortPath(path)} into ssh-agent',
                disabledTooltip: !_agentRunning
                    ? 'Start the ssh-agent service first'
                    : 'Key is already loaded in agent',
              ),
              RowAction(
                label: 'Unload',
                onPressed: canUnload ? () => _removeKey(path) : null,
                enabledTooltip: 'Unload ${_shortPath(path)} from ssh-agent',
                disabledTooltip: !_agentRunning
                    ? 'Start the ssh-agent service first'
                    : 'Key is not loaded in agent',
              ),
              RowAction(
                label: 'Delete',
                onPressed: !_loading ? () => _deleteKeyFile(path) : null,
                enabledTooltip:
                    'Delete ${_shortPath(path)} and its .pub file',
                disabledTooltip: 'Wait for the current operation to finish',
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Shows a dialog with the public key for [path], with Copy and Close actions.
  Future<void> _viewPublicKey(String path) async {
    final pubKey = await _keyManager.readPublicKey(path);
    if (pubKey == null || pubKey.isEmpty) {
      if (!mounted) return;
      ToastService.instance
          .showErrorMessage('Public key not found for ${_shortPath(path)}.');
      return;
    }

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => ShadDialog(
        title: Text('Public Key — ${_shortPath(path)}'),
        description: const Text(
          'The full public key line, ready to be pasted into '
          'authorized_keys on a remote host.',
          style: TextStyle(fontSize: 14),
        ),
        actions: [
          Semantics(
            button: true,
            label: 'Close public key dialog',
            child: ShadButton.ghost(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Close'),
            ),
          ),
          Semantics(
            button: true,
            label: 'Copy public key to clipboard',
            child: ShadButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: pubKey));
                Navigator.of(ctx).pop();
              },
              child: const Text('Copy'),
            ),
          ),
        ],
        child: SelectableText(
          pubKey,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            height: 1.5,
          ),
        ),
      ),
    );
  }

  /// Deletes the key file at [path] from disk, unloading it from the agent
  /// first if it is currently loaded.
  Future<void> _deleteKeyFile(String path) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => ShadDialog(
        title: const Text('Delete Key'),
        description: Text(
          'Are you sure you want to permanently delete '
          '${_shortPath(path)} and its .pub companion file?\n\n'
          'If the key is loaded in ssh-agent, it will be unloaded first.',
          style: const TextStyle(fontSize: 14),
        ),
        actions: [
          Semantics(
            button: true,
            label: 'Cancel delete key',
            child: ShadButton.ghost(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
          ),
          Semantics(
            button: true,
            label: 'Confirm delete key',
            child: ShadButton.destructive(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Delete'),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() {
      _loading = true;
    });

    try {
      // Unload from the agent before deleting the file from disk.
      if (_isKeyLoaded(path)) {
        try {
          await _keyManager.removeKey(path);
        } on SshKeyException catch (e) {
          ToastService.instance.showError(e);
        }
      }

      await _keyManager.deleteKeyFile(path);
      await _refresh();
      if (mounted) {
        ToastService.instance.showSuccess('Key file deleted.');
      }
    } on SshKeyException catch (e) {
      if (!mounted) return;
      ToastService.instance.showError(e);
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      ToastService.instance.showError(e is Exception
          ? e
          : Exception(e.toString()));
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ---- Actions ----
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              Semantics(
                button: true,
                label: 'Generate Key',
                child: ShadButton(
                  onPressed: _loading ? null : _generateKey,
                  child: const Text('Generate'),
                ),
              ),
              Semantics(
                button: true,
                label: 'Unload All Keys',
                child: Builder(
                  builder: (context) {
                    final canUnloadAll = !_loading && _agentRunning;
                    final unloadAllBtn = ShadButton.outline(
                      onPressed: canUnloadAll ? _removeAll : null,
                      child: const Text('Unload All'),
                    );
                    if (!canUnloadAll) {
                      return DisabledActionWrapper(
                        enabled: false,
                        tooltip: _loading
                            ? 'Loading...'
                            : 'The ssh-agent service is not running. Start it on the Service tab first.',
                        child: unloadAllBtn,
                      );
                    }
                    return unloadAllBtn;
                  },
                ),
              ),
              Semantics(
                button: true,
                label: 'Refresh Keys',
                child: ShadButton.ghost(
                  onPressed: _loading ? null : _refresh,
                  child: const Text('Refresh'),
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // ---- Key files card ----
          ShadCard(
            title: Row(
              children: [
                const Text('Key Files'),
                const SizedBox(width: 8),
                Semantics(
                  button: true,
                  label: 'Open SSH Folder',
                  child: ShadButton.ghost(
                    size: ShadButtonSize.sm,
                    onPressed: _openSshFolder,
                    child: const Icon(LucideIcons.folderOpen, size: 14),
                  ),
                ),
              ],
            ),
            description: Text('${_keyFiles.length} file(s) in ~/.ssh'),
            child: _loading
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : _keyFiles.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          'No key files found',
                          style: theme.textTheme.muted,
                        ),
                      )
                    : Column(
                        children: [
                          for (final path in _keyFiles)
                            // KeyedSubtree because _buildKeyFileRow is a
                            // helper method, not a widget, so it cannot take a
                            // key itself. Without a stable identity Flutter
                            // falls back to the list index, so inserting or
                            // removing a key rebuilds every following row and
                            // loses scroll/selection.
                            KeyedSubtree(
                              key: ValueKey(path),
                              child: _buildKeyFileRow(theme, path),
                            ),
                          const SizedBox(height: 12),
                          ShadAlert(
                            icon: const Icon(LucideIcons.info, size: 16),
                            title: const Text('How keys work'),
                            description: const Text(
                              'Load copies the private key into the running '
                              'ssh-agent so it can authenticate without asking '
                              'for the passphrase each time. Unload removes it '
                              'from the agent. Keys are not deleted from disk.',
                            ),
                          ),
                        ],
                      ),
          ),

          const SizedBox(height: 16),

          // ---- Loaded keys card ----
          ShadCard(
            title: const Text('Loaded Keys'),
            description: Text('${_loadedKeys.length} key(s) in agent'),
            child: _loading
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : !_agentRunning
                    ? SizedBox(
                        width: double.infinity,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              const Icon(LucideIcons.powerOff, size: 16),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'The ssh-agent service is stopped. Start it '
                                  'from the Service tab to load or unload keys.',
                                  style: theme.textTheme.muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    : _loadedKeys.isEmpty
                        ? SizedBox(
                            width: double.infinity,
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Text(
                                'No keys loaded in the agent',
                                style: theme.textTheme.muted,
                              ),
                            ),
                          )
                        : Column(
                        children: [
                          for (final key in _loadedKeys)
                            // Keyed by fingerprint: that is the identity the
                            // agent assigns, and it survives a re-sort.
                            KeyedSubtree(
                              key: ValueKey(key.fingerprint),
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 4),
                                child: Row(
                                  children: [
                                    ShadBadge.secondary(
                                      child: Text(key.type),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        key.fingerprint,
                                        style: theme.textTheme.small,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
          ),

          const SizedBox(height: 16),

          // ---- Authorized keys card ----
          ShadCard(
            title: Row(
              children: [
                const Text('Authorized Keys'),
                const Spacer(),
                Semantics(
                  button: true,
                  label: 'Add Key to authorized_keys',
                  child: ShadButton.outline(
                    size: ShadButtonSize.sm,
                    onPressed: _loading ? null : _addAuthorizedKeyDialog,
                    child: const Text('Add Key'),
                  ),
                ),
              ],
            ),
            description: Text(
              '${_authorizedKeys.length} authorized key(s) in ~/.ssh/authorized_keys',
            ),
            child: _loading
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : _authorizedKeys.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          'No authorized keys found',
                          style: theme.textTheme.muted,
                        ),
                      )
                    : Column(
                        children: [
                          for (final key in _authorizedKeys)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Row(
                                children: [
                                  ShadBadge.secondary(
                                    child: Text(key.type),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          key.comment.isNotEmpty
                                              ? key.comment
                                              : (key.key.length > 30
                                                  ? '${key.key.substring(0, 30)}...'
                                                  : key.key),
                                          style: theme.textTheme.small,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        if (key.comment.isNotEmpty)
                                          Text(
                                            key.key.length > 40
                                                ? '${key.key.substring(0, 40)}...'
                                                : key.key,
                                            style: theme.textTheme.muted
                                                .copyWith(fontSize: 11),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                      ],
                                    ),
                                  ),
                                  ShadTooltip(
                                    builder: (context) => const Text(
                                      'Remove from authorized_keys',
                                    ),
                                    child: Semantics(
                                      button: true,
                                      label: 'Remove key from authorized_keys',
                                      child: ShadButton.ghost(
                                        size: ShadButtonSize.sm,
                                        onPressed: _loading
                                            ? null
                                            : () => _removeAuthorizedKey(key),
                                        child: const Icon(
                                          LucideIcons.trash2,
                                          size: 14,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          const SizedBox(height: 12),
                          ShadAlert(
                            icon: const Icon(LucideIcons.info, size: 16),
                            title: const Text('About Authorized Keys'),
                            description: const Text(
                              'Authorized keys define which public keys are permitted to log into this machine via SSH. They are stored in ~/.ssh/authorized_keys.',
                            ),
                          ),
                        ],
                      ),
          ),
        ],
      ),
    );
  }
}

// Domains tab

class DomainsTab extends StatefulWidget {
  const DomainsTab({super.key});

  @override
  State<DomainsTab> createState() => _DomainsTabState();
}

class _DomainsTabState extends State<DomainsTab> {
  final _configManager = SshConfigManager();
  late TextEditingController _configController;
  late final TextEditingController _hostController;
  List<Map<String, String>> _knownHosts = [];
  bool _loading = false;
  bool _editing = false;
  bool _hostsLoading = false;
  final ValueNotifier<bool> _adding = ValueNotifier<bool>(false);
  final Map<String, String?> _hostStatus = {};
  final Set<String> _checkingHosts = {};

  @override
  void initState() {
    super.initState();
    _configController = TextEditingController();
    _hostController = TextEditingController();
    _refresh();
  }

  @override
  void dispose() {
    // _adding was never disposed, so its listeners outlived the State on every
    // tab switch.
    _adding.dispose();
    _configController.dispose();
    _hostController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
    });
    try {
      final config = _configManager.readConfig();
      final hosts = _configManager.getKnownHosts();
      if (!mounted) return;
      setState(() {
        _configController.text = config;
        _knownHosts = hosts;
        _loading = false;
      });
    } on SshConfigException catch (e) {
      if (!mounted) return;
      ToastService.instance.showError(e);
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      ToastService.instance.showError(e is Exception
          ? e
          : Exception(e.toString()));
      setState(() => _loading = false);
    }
  }

  Future<void> _refreshHosts() async {
    setState(() {
      _hostsLoading = true;
    });
    try {
      final hosts = _configManager.getKnownHosts();
      if (!mounted) return;
      final currentHosts = hosts.map((h) => h['host']!).toSet();
      _hostStatus.removeWhere((key, _) => !currentHosts.contains(key));
      setState(() {
        _knownHosts = hosts;
        _hostsLoading = false;
      });
    } on SshConfigException catch (e) {
      if (!mounted) return;
      ToastService.instance.showError(e);
      setState(() => _hostsLoading = false);
    } catch (e) {
      if (!mounted) return;
      ToastService.instance.showError(e is Exception
          ? e
          : Exception(e.toString()));
      setState(() => _hostsLoading = false);
    }
  }

  void _saveConfig() {
    setState(() {
      _loading = true;
    });
    try {
      _configManager.writeConfig(_configController.text);
      setState(() {
        _loading = false;
        _editing = false;
      });
      if (mounted) {
        ToastService.instance.showSuccess('Config saved.');
      }
    } on SshConfigException catch (e) {
      if (!mounted) return;
      ToastService.instance.showError(e);
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      ToastService.instance.showError(e is Exception
          ? e
          : Exception(e.toString()));
      setState(() => _loading = false);
    }
  }

void _openSshFolder() {
    final dir = _configManager.sshDirectory;
    if (dir.isEmpty) return;
    Process.run('explorer', [dir], runInShell: false);
  }

  void _openKnownHostsFile() {
    final path = _configManager.knownHostsPath;
    if (path.isEmpty) return;
    Process.run('explorer', ['/select,', path], runInShell: false);
  }

  String _shortPath(String path) {
    final home = _configManager.sshDirectory;
    if (home.isNotEmpty && path.startsWith(home)) {
      return '~${path.substring(home.length)}';
    }
    return path;
  }

  Future<void> _removeKnownHost(String host, String keyType) async {
    final confirmed = await showShadDialog<bool>(
      context: context,
      builder: (context) => ShadDialog(
        title: const Text('Remove known host'),
        description: Text(
          'Remove the $keyType entry for "$host" from known_hosts?',
        ),
        actions: [
          Semantics(
            button: true,
            label: 'Cancel remove host',
            child: ShadButton.outline(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
          ),
          Semantics(
            button: true,
            label: 'Confirm remove host',
            child: ShadButton.destructive(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Remove'),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() {
      _hostsLoading = true;
    });
    try {
      _configManager.removeKnownHost(host, keyType);
      await _refreshHosts();
      if (mounted) {
        ToastService.instance.showSuccess('Known host entry removed.');
      }
    } on SshConfigException catch (e) {
      if (!mounted) return;
      ToastService.instance.showError(e);
      setState(() => _hostsLoading = false);
    } catch (e) {
      if (!mounted) return;
      ToastService.instance.showError(e is Exception
          ? e
          : Exception(e.toString()));
      setState(() => _hostsLoading = false);
    }
  }

  Future<void> _checkHost(String host) async {
    if (_checkingHosts.contains(host)) return;
    _checkingHosts.add(host);
    setState(() {
      _hostStatus[host] = null;
    });
    try {
      final keys = await _configManager.scanHost(host);
      if (!mounted) return;
      final keyTypes = keys
          .map((line) => line.split(RegExp(r'\s+')).length > 1
              ? line.split(RegExp(r'\s+'))[1]
              : '')
          .where((t) => t.isNotEmpty)
          .toSet()
          .toList();
      setState(() {
        _hostStatus[host] = keys.isEmpty
            ? 'Unreachable'
            : keyTypes.join(', ');
      });
    } on SshConfigException catch (e) {
      if (!mounted) return;
      setState(() {
        _hostStatus[host] = 'Error: ${e.message}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _hostStatus[host] = 'Error';
      });
    } finally {
      _checkingHosts.remove(host);
    }
  }

  Future<List<Map<String, String>>?> _scanAvailableHostKeys(String host) async {
    _adding.value = true;
    if (mounted) setState(() {});

    List<String> keyLines;
    try {
      keyLines = await _configManager.scanHostKeys(host);
    } catch (e) {
      if (!mounted) return null;
      ToastService.instance.showError(e is Exception
          ? e
          : Exception(e.toString()));
      _adding.value = false;
      return null;
    }

    if (!mounted) return null;
    _adding.value = false;

    final entries = <Map<String, String>>[];
    for (final line in keyLines) {
      final tokens = line.split(RegExp(r'\s+'));
      final keyType = tokens.length > 1 ? tokens[1] : '';
      entries.add(<String, String>{'keyType': keyType, 'line': line});
    }

    final existingKeyTypes = _knownHosts
        .where((h) => h['host'] == host)
        .map((h) => h['keyType']!)
        .toSet();

    return entries
        .where((e) => !existingKeyTypes.contains(e['keyType']))
        .toList();
  }

  Future<List<String>?> _selectKeysToAdd(String host, List<Map<String, String>> available) async {
    final selected = List.generate(available.length, (i) => i).toSet();

    final confirmed = await showShadDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setStateDialog) => ShadDialog(
          title: Text('Add $host to known_hosts'),
          description: const Text(
            'Select the key algorithms to add. All are selected by default.',
          ),
          actions: [
            Semantics(
              button: true,
              label: 'Cancel add keys',
              child: ShadButton.outline(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
            ),
            Semantics(
              button: true,
              label: 'Add selected keys',
              child: ShadButton(
                onPressed: selected.isEmpty
                    ? null
                    : () => Navigator.of(context).pop(true),
                child: const Text('Add'),
              ),
            ),
          ],
          child: ListView(
            shrinkWrap: true,
            children: [
              for (var i = 0; i < available.length; i++)
                Row(
                  children: [
                    ShadCheckbox(
                      value: selected.contains(i),
                      onChanged: (value) {
                        setStateDialog(() {
                          if (value) {
                            selected.add(i);
                          } else {
                            selected.remove(i);
                          }
                        });
                      },
                    ),
                    const SizedBox(width: 8),
                    Text(
                      available[i]['keyType']!,
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );

    if (confirmed != true || selected.isEmpty) return null;
    return selected.map((i) => available[i]['line']!).toList();
  }

  Future<void> _addKnownHost() async {
    final host = _hostController.text.trim();
    if (host.isEmpty) return;
    if (!SshConfigManager.isValidHost(host)) {
      if (!mounted) return;
      ToastService.instance
          .showErrorMessage('Invalid host name: "$host".');
      return;
    }

    final available = await _scanAvailableHostKeys(host);
    if (available == null) return;

    if (available.isEmpty) {
      if (!mounted) return;
      ToastService.instance.showErrorMessage(
          'Host "$host" already has all of these key types in known_hosts.');
      return;
    }

    final chosenLines = await _selectKeysToAdd(host, available);
    if (chosenLines == null || chosenLines.isEmpty) return;

    setState(() {
      _hostsLoading = true;
    });
    try {
      await _configManager.writeKnownHostKeys(host, chosenLines);
      _hostController.clear();
      await _refreshHosts();
      if (mounted) {
        ToastService.instance.showSuccess('Known host added.');
      }
    } catch (e) {
      if (!mounted) return;
      ToastService.instance.showError(e is Exception
          ? e
          : Exception(e.toString()));
    }
  }

Widget _buildHostRow(Map<String, String> entry, ShadThemeData theme) {
    final host = entry['host']!;
    final keyType = entry['keyType']!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          const Icon(
            LucideIcons.globe,
            size: 14,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  host,
                  style: theme.textTheme.small,
                  softWrap: true,
                ),
                if (keyType.isNotEmpty)
                  Text(
                    keyType,
                    style: theme.textTheme.muted,
                  ),
              ],
            ),
          ),
          ActionRow(
            actions: [
              RowAction(
                label: 'Check',
                onPressed: _hostsLoading || _checkingHosts.contains(host)
                    ? null
                    : () => _checkHost(host),
                enabledTooltip: 'Scan host keys for $host',
                disabledTooltip: _checkingHosts.contains(host)
                    ? 'Already checking $host'
                    : 'Wait for the current operation to finish',
              ),
              RowAction(
                label: 'Remove',
                onPressed: _hostsLoading
                    ? null
                    : () => _removeKnownHost(host, keyType),
                enabledTooltip: 'Remove $host from known_hosts',
                disabledTooltip: 'Wait for the current operation to finish',
              ),
            ],
          ),
          const SizedBox(width: 6),
          if (_hostStatus[host] != null)
            // Not a button. It used to be wrapped in ShadButton.ghost with an
            // empty onPressed, which put a dead control in the tab order and
            // announced it as a button to screen readers. The status is read
            // only; the tooltip below carries the detail instead.
            ShadTooltip(
              builder: (context) => Text(
                _hostStatus[host] == 'Unreachable'
                    ? 'No response from $host. Check the hostname and that'
                        ' port 22 is reachable, then try again.'
                    : _hostStatus[host]!,
              ),
              child: Semantics(
                label: 'Host status for $host: ${_hostStatus[host]}',
                child: HostStatusBadge(status: _hostStatus[host]!),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

  return ListView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          children: [
          // ---- Config card ----
          ShadCard(
            title: Row(
              children: [
                const Text('SSH Config'),
                const SizedBox(width: 8),
                Semantics(
                  button: true,
                  label: 'Open SSH Folder',
                  child: ShadButton.ghost(
                    size: ShadButtonSize.sm,
                    onPressed: _openSshFolder,
                    child: const Icon(LucideIcons.folderOpen, size: 14),
                  ),
                ),
              ],
            ),
            description: const Text('Contents of ~/.ssh/config'),
            footer: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 12),
                Row(
                  children: [
                    Semantics(
                      button: true,
                      label: 'Reload SSH Config',
                      child: ShadButton.outline(
                        onPressed: _loading ? null : _refresh,
                        child: const Text('Reload'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (!_editing)
                      Semantics(
                        button: true,
                        label: 'Edit SSH Config',
                        child: ShadButton.outline(
                          onPressed: _loading ? null : () => setState(() => _editing = true),
                          child: const Text('Edit'),
                        ),
                      ),
                    if (_editing) ...[
                      Semantics(
                        button: true,
                        label: 'Save SSH Config',
                        child: ShadButton(
                          onPressed: _loading ? null : _saveConfig,
                          child: const Text('Save'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Semantics(
                        button: true,
                        label: 'Cancel SSH Config Edit',
                        child: ShadButton.outline(
                          onPressed: _loading
                              ? null
                              : () {
                                  _configController.text = _configManager.readConfig();
                                  setState(() => _editing = false);
                                },
                          child: const Text('Cancel'),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: _loading
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : ShadTextarea(
                      controller: _configController,
                      placeholder: const Text('No config file found'),
                      minHeight: 120,
                      readOnly: !_editing,
                      resizable: false,
                    ),
            ),
          ),

          const SizedBox(height: 16),

          // ---- Known hosts card ----
          ShadCard(
            title: Row(
              children: [
                const Text('Known Hosts'),
                const SizedBox(width: 8),
                Semantics(
                  button: true,
                  label: 'Open Known Hosts File',
                  child: ShadButton.ghost(
                    size: ShadButtonSize.sm,
                    onPressed: _openKnownHostsFile,
                    child: const Icon(LucideIcons.folderOpen, size: 14),
                  ),
                ),
              ],
            ),
            description: Text(
              '${_knownHosts.length} host(s) in ${_shortPath(_configManager.knownHostsPath)}',
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 8),
                  child: ValueListenableBuilder<bool>(
                    valueListenable: _adding,
                    builder: (context, adding, _) => Row(
                      children: [
                        Expanded(
                          child: ListenableBuilder(
                            listenable: _hostController,
                            builder: (context, _) => ShadInput(
                              controller: _hostController,
                              placeholder: const Text('example.com'),
                              onSubmitted: adding ? null : (_) => _addKnownHost(),
                              enabled: !adding,
                              trailing: _hostController.text.isNotEmpty && !adding
                                  ? Semantics(
                                      button: true,
                                      label: 'Clear host input',
                                      child: ShadButton.ghost(
                                        size: ShadButtonSize.sm,
                                        onPressed: () {
                                          _hostController.clear();
                                        },
                                        child: const Icon(LucideIcons.x, size: 14),
                                      ),
                                    )
                                  : null,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Semantics(
                          button: true,
                          label: 'Add Host to known_hosts',
                          child: ShadButton(
                            onPressed: adding || _hostsLoading ? null : _addKnownHost,
                            leading: adding
                                ? SizedBox.square(
                                    dimension: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: ShadTheme.of(context).colorScheme.primaryForeground,
                                    ),
                                  )
                                : null,
                            child: const Text('Add'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                _hostsLoading
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : _knownHosts.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(
                              'No known hosts found',
                              style: theme.textTheme.muted,
                            ),
                          )
                        : Column(
                            children: [
                              for (final entry in _knownHosts)
                                // Composite key: known_hosts entries are
                                // Map<String, String>, which has no identity
                                // of its own, so host+keyType together stand
                                // in for one.
                                KeyedSubtree(
                                  key: ValueKey(
                                    '${entry['host']}|${entry['keyType']}',
                                  ),
                                  child: _buildHostRow(entry, theme),
                                ),
                            ],
                          ),
          ],
        ),
      ),
    ],
  );
    }
  }
