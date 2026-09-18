import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'services/settings_service.dart';
import 'services/ssh_service.dart';
import 'services/ssh_keys.dart';
import 'services/ssh_domains.dart';

/// Shared notifier so the Service tab can signal the Keys tab that the
/// ssh-agent state changed (started / stopped). The Keys tab listens to this
/// and refreshes its view so Load/Unload and the Loaded Keys card stay in
/// sync without switching tabs.
final ValueNotifier<SshServiceState?> agentServiceState =
    ValueNotifier<SshServiceState?>(null);

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await SettingsService.getElevationMode();

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
          actions: [
            ShadButton.ghost(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Close'),
            ),
          ],
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
                const ShadButton.outline(
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
                const SizedBox(width: 8),
              ] else if (_elevationMode == SettingsService.modeOnce) ...[
                ShadTooltip(
                  builder: (context) => const Text('Reiniciar la aplicación con permisos de Administrador'),
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
                const SizedBox(width: 8),
              ],
              ShadTooltip(
                builder: (context) => const Text('Settings'),
                child: ShadIconButton(
                  icon: const Icon(LucideIcons.settings),
                  iconSize: 18,
                  onPressed: _showSettingsDialog,
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
                  child: const Text('Service'),
                  content: const ServiceTab(),
                  expandContent: true,
                ),
                ShadTab(
                  value: 'keys',
                  child: const Text('Keys'),
                  content: const KeysTab(),
                  expandContent: true,
                ),
                ShadTab(
                  value: 'domains',
                  child: const Text('Domains'),
                  content: const DomainsTab(),
                  expandContent: true,
                ),
              ],
            ),
          ),
        ),
],
);
    }
  }

// ===========================================================================
// Service tab
// ===========================================================================

class ServiceTab extends StatefulWidget {
  const ServiceTab({super.key});

  @override
  State<ServiceTab> createState() => _ServiceTabState();
}

class _ServiceTabState extends State<ServiceTab> {
  final _serviceManager = SshServiceManager();
  SshServiceState? _status;
  bool _loading = false;
  StartupType _startupType = StartupType.manual;

  @override
  void initState() {
    super.initState();
    _refreshStatus();
    SettingsService.elevationModeNotifier.addListener(_onModeChanged);
  }

  void _onModeChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    SettingsService.elevationModeNotifier.removeListener(_onModeChanged);
    super.dispose();
  }

  /// Shows a non-blocking error toast. Keeps all controls visible.
  void _showToast(SshServiceException e) {
    final contextRef = context;
    // Defer to next frame so ShadToaster is available.
    Future.microtask(() {
      if (!mounted) return;
      ShadToaster.of(contextRef).show(
        ShadToast.destructive(
          title: Text(_toastTitle(e)),
          description: Text(_toastDescription(e)),
          action: ShadButton.destructive(
            child: const Text('Dismiss'),
            onPressed: () => ShadToaster.of(contextRef).hide(),
          ),
        ),
      );
    });
  }

  String _toastTitle(SshServiceException e) {
    return switch (e.code) {
      SshServiceErrorCode.accessDenied => 'Administrator required',
      SshServiceErrorCode.serviceNotFound => 'Service not found',
      SshServiceErrorCode.opensshNotInstalled => 'OpenSSH not installed',
      _ => 'Service error',
    };
  }

  String _toastDescription(SshServiceException e) {
    return switch (e.code) {
      SshServiceErrorCode.accessDenied =>
        'Se requieren permisos de administrador para realizar esta acción. '
        'En modo "Once", puedes usar el botón "Modo Admin" en la barra superior. '
        'En modo "Per action", debes aceptar el diálogo de UAC.',
      SshServiceErrorCode.serviceNotFound => e.message,
      SshServiceErrorCode.opensshNotInstalled => e.message,
      _ => e.toString(),
    };
  }

  Future<void> _refreshStatus() async {
    setState(() {
      _loading = true;
    });
    try {
      final status = await _serviceManager.checkStatus();
      agentServiceState.value = status;
      if (!mounted) return;
      setState(() {
        _status = status;
        _loading = false;
      });
    } on SshServiceException catch (e) {
      if (!mounted) return;
      _showToast(e);
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      _showToast(e is SshServiceException
          ? e
          : SshServiceException(SshServiceErrorCode.operationFailed, e.toString()));
      setState(() => _loading = false);
    }
  }

  Future<void> _startService() async {
    setState(() => _loading = true);
    try {
      await _serviceManager.start();
      if (!mounted) return;
      final status = await _serviceManager.checkStatus();
      agentServiceState.value = status;
      await _refreshStatus();
    } on SshServiceException catch (e) {
      if (!mounted) return;
      _showToast(e);
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      _showToast(SshServiceException(SshServiceErrorCode.operationFailed, e.toString()));
      setState(() => _loading = false);
    }
  }

  Future<void> _stopService() async {
    setState(() => _loading = true);
    try {
      await _serviceManager.stop();
      if (!mounted) return;
      final status = await _serviceManager.checkStatus();
      agentServiceState.value = status;
      await _refreshStatus();
    } on SshServiceException catch (e) {
      if (!mounted) return;
      _showToast(e);
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      _showToast(SshServiceException(SshServiceErrorCode.operationFailed, e.toString()));
      setState(() => _loading = false);
    }
  }

  Future<void> _setStartupType(StartupType type) async {
    final originalType = _startupType;
    setState(() { _startupType = type; _loading = true; });
    try {
      await _serviceManager.setStartupType(type);
      if (!mounted) return;
      setState(() => _loading = false);
    } on SshServiceException catch (e) {
      if (!mounted) return;
      _showToast(e);
      setState(() { _startupType = originalType; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      _showToast(SshServiceException(SshServiceErrorCode.operationFailed, e.toString()));
      setState(() { _startupType = originalType; _loading = false; });
    }
  }

  String _statusLabel(SshServiceState state) => switch (state) {
        SshServiceState.running => 'Running',
        SshServiceState.stopped => 'Stopped',
        SshServiceState.startPending => 'Start Pending',
        SshServiceState.stopPending => 'Stop Pending',
        SshServiceState.continuePending => 'Continue Pending',
        SshServiceState.paused => 'Paused',
        SshServiceState.unknown => 'Unknown',
      };

  @override
  Widget build(BuildContext context) {
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
                  if (!_loading)
                    ShadBadge(
                      child: Text(
                        _status != null
                            ? _statusLabel(_status!)
                            : 'Unknown',
                      ),
                    ),
                ],
              ),
              description: const Text('Current state of the ssh-agent service'),
              child: Padding(
                padding: const EdgeInsets.only(top: 12),
                child: _loading
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
                          ShadButton(
                            onPressed: _loading ? null : _startService,
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(LucideIcons.play, size: 14),
                                SizedBox(width: 6),
                                Text('Start'),
                              ],
                            ),
                          ),
                          Builder(
                            builder: (context) {
                              Widget stopBtn = ShadButton.destructive(
                                onPressed: (_loading || !adminEnabled) ? null : _stopService,
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
                              );

                              if (!adminEnabled) {
                                return DisabledActionWrapper(
                                  enabled: false,
                                  tooltip: 'Requiere permisos de administrador. Usa el botón "Restart in Admin Mode" en la barra superior.',
                                  child: stopBtn,
                                );
                              }
                              if (!isElevated) {
                                return ShadTooltip(
                                  builder: (context) => const Text('Esta acción solicitará confirmación de permisos de administrador (UAC)'),
                                  child: stopBtn,
                                );
                              }
                              return stopBtn;
                            },
                          ),
                          ShadButton.outline(
                            onPressed: _loading ? null : _refreshStatus,
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(LucideIcons.refreshCw, size: 14),
                                SizedBox(width: 6),
                                Text('Refresh'),
                              ],
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
              Widget selectWidget = ShadSelect<StartupType>(
                initialValue: _startupType,
                enabled: !_loading && adminEnabled,
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
                  if (value != null) _setStartupType(value);
                },
              );

              if (!adminEnabled) {
                selectWidget = DisabledActionWrapper(
                  enabled: false,
                  tooltip: 'Requiere permisos de administrador. Usa el botón "Restart in Admin Mode" en la barra superior.',
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
                              ? 'Deshabilitado: requiere Admin Mode (barra superior)'
                              : 'Cambiar esta opción solicitará confirmación de permisos de administrador (UAC)',
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
                  child: selectWidget,
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

// ===========================================================================
// Reusable Action Wrapper for Disabled States
// ===========================================================================

/// A reusable wrapper that ensures disabled buttons properly look and behave
/// as disabled: applies opacity, blocks internal pointer hover effects,
/// and adjusts the mouse cursor, while keeping the tooltip active and informative.
class DisabledActionWrapper extends StatelessWidget {
  const DisabledActionWrapper({
    super.key,
    required this.enabled,
    required this.tooltip,
    required this.child,
    this.disabledOpacity = 0.35,
    this.disabledCursor = SystemMouseCursors.basic,
  });

  final bool enabled;
  final String tooltip;
  final Widget child;
  final double disabledOpacity;
  final MouseCursor disabledCursor;

  @override
  Widget build(BuildContext context) {
    return ShadTooltip(
      builder: (context) => Text(tooltip),
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : disabledCursor,
        child: Opacity(
          opacity: enabled ? 1.0 : disabledOpacity,
          child: IgnorePointer(
            ignoring: !enabled,
            child: child,
          ),
        ),
      ),
    );
  }
}

// ===========================================================================
// Keys tab
// ===========================================================================

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
  String? _error;
  bool _agentRunning = false;

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
    setState(() {
      _loading = true;
      _error = null;
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
      if (!mounted) return;
      setState(() {
        _error =
            'Refresh timed out — the ssh-agent may be unresponsive.';
        _loading = false;
      });
    } on SshKeyException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _addKey(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (await _keyManager.hasPassphrase(path)) {
        final passphrase = await _promptPassphrase();
        if (passphrase == null) {
          if (!mounted) return;
          setState(() {
            _loading = false;
            _error = null;
          });
          return;
        }
        await _keyManager.addKey(path, passphrase: passphrase);
        if (!mounted) return;
        await _refresh();
      } else {
        await _keyManager.addKey(path);
        if (!mounted) return;
        await _refresh();
      }
    } on SshKeyException catch (e) {
      if (!mounted) return;
      setState(() {
        if (e.code == SshKeyErrorCode.wrongPassphrase) {
          _error = 'The passphrase is incorrect.';
        } else {
          _error = e.toString();
        }
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// Shows a dialog requesting the passphrase for a protected key.
  Future<String?> _promptPassphrase() async {
    final controller = TextEditingController();
    bool obscure = true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setStateDialog) => ShadDialog(
          title: const Text('Passphrase required'),
          description: const Text(
            'This key is protected by a passphrase.',
            style: TextStyle(fontSize: 14),
          ),
          child: ShadInput(
            controller: controller,
            obscureText: obscure,
            placeholder: const Text('Enter passphrase'),
            onSubmitted: (_) => Navigator.of(ctx).pop(true),
            trailing: SizedBox.square(
              dimension: 24,
              child: OverflowBox(
                maxWidth: 28,
                maxHeight: 28,
                child: ShadIconButton(
                  iconSize: 20,
                  padding: EdgeInsets.all(2),
                  icon: Icon(obscure ? LucideIcons.eyeOff : LucideIcons.eye),
                  onPressed: () {
                    setStateDialog(() => obscure = !obscure);
                  },
                ),
              ),
            ),
          ),
          actions: [
            ShadButton.ghost(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            ShadButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Load'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return null;
    return controller.text;
  }

  Future<void> _removeKey(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _keyManager.removeKey(path);
      await _refresh();
    } on SshKeyException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _removeAll() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _keyManager.removeAll();
      await _refresh();
    } on SshKeyException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _generateKey() async {
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
            ShadButton.ghost(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            ShadButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Generate'),
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

    if (confirmed != true) return;

    final name = nameController.text.trim();
    // Use algorithm default name if empty.
    final effectiveName = name.isEmpty ? algorithm.defaultName : name;

    String? passphrase;
    if (passphraseProtected) {
      passphrase = await _promptPassphrase();
      if (passphrase == null) return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _keyManager.generateKey(
        name: effectiveName,
        algorithm: algorithm,
        comment: commentController.text.isEmpty ? null : commentController.text,
        passphrase: passphrase,
      );
      await _refresh();
    } on SshKeyException catch (e) {
      if (!mounted) return;
      // If key file already exists, ask if user wants to replace it.
      if (e.code == SshKeyErrorCode.fileExists) {
        final replace = await showDialog<bool>(
          context: context,
          builder: (ctx) => ShadDialog(
            title: const Text('Key already exists'),
            description: const Text(
              'A key with this name already exists. Do you want to '
              'replace it?',
            ),
            actions: [
              ShadButton.ghost(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              ShadButton.destructive(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Replace'),
              ),
            ],
          ),
        );
        if (replace != true || !mounted) return;
        // Remove existing files and try again.
        final dir = _keyManager.sshDirectory;
        final keyPath = '$dir${Platform.pathSeparator}$effectiveName';
        final pubPath = '$keyPath.pub';
        try {
          final f1 = File(keyPath);
          if (await f1.exists()) await f1.delete();
          final f2 = File(pubPath);
          if (await f2.exists()) await f2.delete();
        } catch (_) {}
        try {
          await _keyManager.generateKey(
            name: effectiveName,
            algorithm: algorithm,
            comment: commentController.text.isEmpty
                ? null
                : commentController.text,
            passphrase: passphrase,
          );
          await _refresh();
        } on SshKeyException catch (e2) {
          if (!mounted) return;
          setState(() {
            _error = e2.toString();
            _loading = false;
          });
        } catch (e2) {
          if (!mounted) return;
          setState(() {
            _error = e2.toString();
            _loading = false;
          });
        }
      } else {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
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
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: ShadInput(
            controller: keyController,
            placeholder: const Text('ssh-ed25519 AAAAC3NzaC1... user@machine'),
            maxLines: 3,
            minLines: 2,
          ),
        ),
        actions: [
          ShadButton.ghost(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ShadButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Add'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    final text = keyController.text.trim();
    if (text.isEmpty) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await _keyManager.addAuthorizedKey(text);
      await _refresh();
    } on SshKeyException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
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
          ShadButton.ghost(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ShadButton.destructive(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await _keyManager.removeAuthorizedKey(key.rawLine);
      await _refresh();
    } on SshKeyException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
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
          DisabledActionWrapper(
            enabled: !_loading && hasPub,
            tooltip: hasPub
                ? 'View public key of ${_shortPath(path)}'
                : 'No .pub file for ${_shortPath(path)}',
            child: ShadButton.ghost(
              size: ShadButtonSize.sm,
              onPressed: !_loading && hasPub ? () => _viewPublicKey(path) : null,
              child: const Text('View'),
            ),
          ),
          const SizedBox(width: 4),
          DisabledActionWrapper(
            enabled: canLoad,
            tooltip: !_agentRunning
                ? 'Start the ssh-agent service first'
                : isLoaded
                    ? 'Key is already loaded in agent'
                    : 'Load ${_shortPath(path)} into ssh-agent',
            child: ShadButton.ghost(
              size: ShadButtonSize.sm,
              onPressed: canLoad ? () => _addKey(path) : null,
              child: const Text('Load'),
            ),
          ),
          DisabledActionWrapper(
            enabled: canUnload,
            tooltip: !_agentRunning
                ? 'Start the ssh-agent service first'
                : !isLoaded
                    ? 'Key is not loaded in agent'
                    : 'Unload ${_shortPath(path)} from ssh-agent',
            child: ShadButton.ghost(
              size: ShadButtonSize.sm,
              onPressed: canUnload ? () => _removeKey(path) : null,
              child: const Text('Unload'),
            ),
          ),
          const SizedBox(width: 4),
          DisabledActionWrapper(
            enabled: !_loading,
            tooltip: 'Delete ${_shortPath(path)} and its .pub file',
            child: ShadButton.ghost(
              size: ShadButtonSize.sm,
              onPressed: !_loading ? () => _deleteKeyFile(path) : null,
              child: const Text('Delete'),
            ),
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
      setState(() {
        _error = 'Public key not found for ${_shortPath(path)}.';
      });
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
        child: SelectableText(
          pubKey,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            height: 1.5,
          ),
        ),
        actions: [
          ShadButton.ghost(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
          ShadButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: pubKey));
              Navigator.of(ctx).pop();
            },
            child: const Text('Copy'),
          ),
        ],
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
          ShadButton.ghost(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ShadButton.destructive(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      // Unload from the agent before deleting the file from disk.
      if (_isKeyLoaded(path)) {
        try {
          await _keyManager.removeKey(path);
        } on SshKeyException catch (_) {
          // The agent may reject the unload (e.g. path mismatch); the file
          // deletion below still proceeds so the user is never stuck.
        }
      }

      await _keyManager.deleteKeyFile(path);
      await _refresh();
    } on SshKeyException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ---- Error banner ----
          if (_error != null) ...[
            ShadAlert.destructive(
              title: const Text('Error'),
              description: Text(_error!),
            ),
            const SizedBox(height: 16),
          ],

          // ---- Actions ----
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
               ShadButton(
                 onPressed: _loading ? null : _generateKey,
                 child: const Text('Generate'),
               ),
ShadButton.outline(
                    onPressed: _loading || !_agentRunning ? null : _removeAll,
                   child: const Text('Unload All'),
                 ),
                ShadButton.ghost(
                  onPressed: _loading ? null : _refresh,
                  child: const Text('Refresh'),
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
                ShadButton.ghost(
                  size: ShadButtonSize.sm,
                  onPressed: _openSshFolder,
                  child: const Icon(LucideIcons.folderOpen, size: 14),
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
                            _buildKeyFileRow(theme, path),
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
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
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
                ShadButton.outline(
                  size: ShadButtonSize.sm,
                  onPressed: _loading ? null : _addAuthorizedKeyDialog,
                  child: const Text('Add Key'),
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

// ===========================================================================
// Domains tab
// ===========================================================================

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
    String? _error;
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
    _configController.dispose();
    _hostController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
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
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _refreshHosts() async {
    setState(() {
      _hostsLoading = true;
      _error = null;
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
      setState(() {
        _error = e.toString();
        _hostsLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _hostsLoading = false;
      });
    }
  }

  void _saveConfig() {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _configManager.writeConfig(_configController.text);
      setState(() {
        _loading = false;
        _editing = false;
      });
    } on SshConfigException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
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
          ShadButton.outline(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ShadButton.destructive(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() {
      _hostsLoading = true;
      _error = null;
    });
    try {
      _configManager.removeKnownHost(host, keyType);
      await _refreshHosts();
    } on SshConfigException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _hostsLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _hostsLoading = false;
      });
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

Future<void> _addKnownHost() async {
    final host = _hostController.text.trim();
    if (host.isEmpty) return;
    if (!SshConfigManager.isValidHost(host)) {
      if (!mounted) return;
      setState(() {
        _error = 'Invalid host name: "$host".';
      });
      return;
    }
    _adding.value = true;
    _error = null;
    if (mounted) setState(() {});

    List<String> keyLines;
    try {
      keyLines = await _configManager.scanHostKeys(host);
    } on SshConfigException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _adding.value = false;
      });
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _adding.value = false;
      });
      return;
    }
    if (!mounted) return;
    _adding.value = false;

    // Parse each line into (keyType, fullLine) pairs.
    final entries = <Map<String, String>>[];
    for (final line in keyLines) {
      final tokens = line.split(RegExp(r'\s+'));
      final keyType = tokens.length > 1 ? tokens[1] : '';
      entries.add(<String, String>{'keyType': keyType, 'line': line});
    }

    // Filter out key types that already exist for this host.
    final existingKeyTypes = _knownHosts
        .where((h) => h['host'] == host)
        .map((h) => h['keyType']!)
        .toSet();
    final available = entries
        .where((e) => !existingKeyTypes.contains(e['keyType']))
        .toList();

    if (available.isEmpty) {
      if (!mounted) return;
      setState(() {
        _error = 'Host "$host" already has all of these key types in known_hosts.';
      });
      return;
    }

    // Show a dialog with checkboxes for each key type.
    final selected = <int>{};
    for (var i = 0; i < available.length; i++) {
      selected.add(i);
    }

    final confirmed = await showShadDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setStateDialog) => ShadDialog(
          title: Text('Add $host to known_hosts'),
          description: const Text(
            'Select the key algorithms to add. All are selected by default.',
          ),
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
          actions: [
            ShadButton.outline(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            ShadButton(
              onPressed: selected.isEmpty
                  ? null
                  : () => Navigator.of(context).pop(true),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true || selected.isEmpty) return;

    final chosenLines = selected
        .map((i) => available[i]['line']!)
        .toList();

    setState(() {
      _hostsLoading = true;
      _error = null;
    });
    try {
      await _configManager.writeKnownHostKeys(host, chosenLines);
      _hostController.clear();
      await _refreshHosts();
    } on SshConfigException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
      });
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
          const SizedBox(width: 8),
          ShadTooltip(
            builder: (context) => Text(host),
            child: ShadButton.ghost(
              size: ShadButtonSize.sm,
              onPressed: _hostsLoading || _checkingHosts.contains(host)
                  ? null
                  : () => _checkHost(host),
              child: _checkingHosts.contains(host)
                  ? const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Check'),
            ),
          ),
          const SizedBox(width: 6),
          if (_hostStatus[host] != null)
            ShadTooltip(
              builder: (context) => Text(
                _hostStatus[host] == 'Unreachable'
                    ? 'Did not respond to ssh-keyscan.'
                    : _hostStatus[host]!,
              ),
              child: ShadButton.ghost(
                size: ShadButtonSize.sm,
                onPressed: () {},
                child: ShadBadge(
                  child: Text(
                    _hostStatus[host] == 'Unreachable'
                        ? 'Unreachable'
                        : '${_hostStatus[host]!.split(', ').length} key(s) found',
                    style: const TextStyle(fontSize: 10),
                  ),
                ),
              ),
            ),
          const SizedBox(width: 6),
          ShadTooltip(
            builder: (context) => Text(host),
            child: ShadButton.ghost(
              size: ShadButtonSize.sm,
              onPressed: _hostsLoading
                  ? null
                  : () => _removeKnownHost(host, keyType),
              child: const Text('Remove'),
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
          // ---- Error banner ----
          if (_error != null) ...[
            ShadAlert.destructive(
              title: const Text('Error'),
              description: Text(_error!),
            ),
            const SizedBox(height: 16),
          ],

          // ---- Config card ----
          ShadCard(
            title: Row(
              children: [
                const Text('SSH Config'),
                const SizedBox(width: 8),
                ShadButton.ghost(
                  size: ShadButtonSize.sm,
                  onPressed: _openSshFolder,
                  child: const Icon(LucideIcons.folderOpen, size: 14),
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
                    ShadButton.outline(
                      onPressed: _loading ? null : _refresh,
                      child: const Text('Reload'),
                    ),
                    const SizedBox(width: 8),
                    if (!_editing)
                      ShadButton.outline(
                        onPressed: _loading ? null : () => setState(() => _editing = true),
                        child: const Text('Edit'),
                      ),
                    if (_editing) ...[
                      ShadButton(
                        onPressed: _loading ? null : _saveConfig,
                        child: const Text('Save'),
                      ),
                      const SizedBox(width: 8),
                      ShadButton.outline(
                        onPressed: _loading
                            ? null
                            : () {
                                _configController.text = _configManager.readConfig();
                                setState(() => _editing = false);
                              },
                        child: const Text('Cancel'),
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
                ShadButton.ghost(
                  size: ShadButtonSize.sm,
                  onPressed: _openKnownHostsFile,
                  child: const Icon(LucideIcons.folderOpen, size: 14),
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
                                  ? ShadButton.ghost(
                                      size: ShadButtonSize.sm,
                                      onPressed: () {
                                        _hostController.clear();
                                      },
                                      child: const Icon(LucideIcons.x, size: 14),
                                    )
                                  : null,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ShadButton(
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
                                _buildHostRow(entry, theme),
                            ],
                          ),
          ],
        ),
      ),
    ],
  );
    }
  }