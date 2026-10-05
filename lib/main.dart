import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'features/domains/domains_controller.dart';
import 'features/keys/keys_controller.dart';
import 'features/service/service_controller.dart';
import 'services/settings_service.dart';
import 'services/ssh_domains.dart';
import 'services/ssh_keys.dart';
import 'services/ssh_service.dart';
import 'shared/dialogs/passphrase_dialog.dart';
import 'shared/plural.dart';
import 'shared/widgets/agent_status_badge.dart';
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
  // Load the theme before the first frame. Reading it later in the app's
  // initState would build once with ThemeMode.system and then repaint, which
  // is a visible flash when the stored preference is light or dark.
  await SettingsService.getThemeMode();

  // Global uncaught-error handler: route every unhandled Flutter/async
  // error to the toaster instead of the red debug screen. Never rethrows -
  // the handler only reports, it does not change control flow.
  //
  // The stack is also written to stderr. Without it the only trace of a
  // startup failure is the toast, which carries the exception message and
  // nothing about where it came from. stderr is invisible in a normal launch.
  FlutterError.onError = (FlutterErrorDetails details) {
    stderr.writeln('FlutterError: ${details.exception}\n${details.stack ?? StackTrace.empty}');
    ToastService.instance.handleError(details.exception, details.stack ?? StackTrace.empty);
  };
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    stderr.writeln('PlatformError: $error\n$stack');
    ToastService.instance.handleError(error, stack);
    return true;
  };

  // Normal UI path — run the Flutter app.
  runApp(const SshPanelApp());
}


// ---------------------------------------------------------------------------
// App root
// ---------------------------------------------------------------------------

/// Builds the shadcn theme for a given brightness.
///
/// shadcn exposes exactly one colour scheme per brightness -- slate -- so both
/// branches only need to set [ShadThemeData.brightness]; the package then picks
/// `ShadSlateColorScheme.light()` or `.dark()` on its own.
ShadThemeData _themeFor(Brightness brightness) =>
    ShadThemeData(brightness: brightness);

/// Maps a stored preference to the matching [ThemeMode].
///
/// [SettingsService.themeModeOptions] holds exactly the `ThemeMode` names, so
/// the lookup cannot drift out of sync with the enum.
ThemeMode _themeModeFor(String preference) =>
    ThemeMode.values.firstWhere(
      (mode) => mode.name == preference,
      // Unreachable for values that came through setThemeMode, which rejects
      // unknown input; the fallback keeps a hand-edited preferences file from
      // throwing during startup.
      orElse: () => ThemeMode.system,
    );

/// Stateful only so it can rebuild when the theme preference changes.
class SshPanelApp extends StatefulWidget {
  const SshPanelApp({super.key});

  @override
  State<SshPanelApp> createState() => _SshPanelAppState();
}

class _SshPanelAppState extends State<SshPanelApp> {
  ThemeMode _themeMode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    SettingsService.themeModeNotifier.addListener(_onThemeModeChanged);
    _loadThemeMode();
  }

  @override
  void dispose() {
    SettingsService.themeModeNotifier.removeListener(_onThemeModeChanged);
    super.dispose();
  }

  void _onThemeModeChanged() {
    if (!mounted) return;
    setState(() {
      _themeMode = _themeModeFor(SettingsService.themeModeNotifier.value);
    });
  }

  Future<void> _loadThemeMode() async {
    final stored = await SettingsService.getThemeMode();
    if (!mounted) return;
    setState(() => _themeMode = _themeModeFor(stored));
  }

  @override
  Widget build(BuildContext context) {
    return ShadApp(
      title: 'SSH Panel',
      // Without an explicit dark theme, ShadApp falls back to
      // ShadThemeData(brightness: Brightness.light) for every platform
      // brightness, so the app ignored the Windows setting entirely and was
      // always light.
      theme: _themeFor(Brightness.light),
      darkTheme: _themeFor(Brightness.dark),
      themeMode: _themeMode,
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

  /// Mirrors [SettingsService.themeModeNotifier] so the settings dialog shows
  /// the current value. Held here only for display: the theme itself is applied
  /// by `SshPanelApp`, which owns the `ShadApp`.
  String _themeModeName = SettingsService.themeSystem;

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
    SettingsService.themeModeNotifier.addListener(_onThemeModeChanged);
  }

  void _onThemeModeChanged() {
    if (!mounted) return;
    setState(() {
      _themeModeName = SettingsService.themeModeNotifier.value;
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
          description: const Text(
            'Administrator prompts and appearance.',
          ),
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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Administrator prompts',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              const Text(
                'Controls when Windows asks for administrator permission.',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 8),
              ShadSelect<String>(
                initialValue: _elevationMode,
                options: [
                  ShadOption<String>(
                    value: SettingsService.modePerAction,
                    child: const Text('Ask every time'),
                  ),
                  ShadOption<String>(
                    value: SettingsService.modeOnce,
                    child: const Text('Ask once per session'),
                  ),
                ],
                selectedOptionBuilder: (context, value) => Text(
                  value == SettingsService.modePerAction
                      ? 'Ask every time'
                      : 'Ask once per session',
                ),
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
              const SizedBox(height: 20),
              const Text(
                'Theme',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              const Text(
                'Automatic follows the light or dark setting in Windows.',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 8),
              ShadSelect<String>(
                initialValue: _themeModeName,
                options: const [
                  ShadOption<String>(
                    value: SettingsService.themeSystem,
                    child: Text('Automatic'),
                  ),
                  ShadOption<String>(
                    value: SettingsService.themeLight,
                    child: Text('Light'),
                  ),
                  ShadOption<String>(
                    value: SettingsService.themeDark,
                    child: Text('Dark'),
                  ),
                ],
                selectedOptionBuilder: (context, value) => Text(
                  switch (value) {
                    SettingsService.themeLight => 'Light',
                    SettingsService.themeDark => 'Dark',
                    _ => 'Automatic',
                  },
                ),
                onChanged: (value) async {
                  if (value == null) return;
                  await SettingsService.setThemeMode(value);
                  // No local setState: SshPanelApp listens to
                  // themeModeNotifier and rebuilds itself, which also swaps the
                  // theme this dialog is rendered in.
                  setStateDialog(() {});
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
    SettingsService.themeModeNotifier.removeListener(_onThemeModeChanged);
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
                    AgentStatusBadge(state: _controller.status),
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
                // startupType is null when the SCM could not be queried --
                // OpenSSH absent, or the SCM refused. ShadSelect dereferences
                // its placeholder unconditionally when the value is null
                // (select.dart: `result = widget.placeholder!`), so the
                // placeholder is required here, not decorative: without it the
                // release build throws "Null check operator used on a null
                // value" instead of showing the unknown state.
                placeholder: Text(
                  'Unknown',
                  style: theme.textTheme.muted,
                ),
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
  /// State and I/O live in [KeysController]. Only the dialogs stay here,
  /// because they need a [BuildContext].
  final _controller = KeysController();

  @override
  void initState() {
    super.initState();
    // The controller subscribes to agentServiceState itself, so a start or stop
    // on the Service tab reloads the Load/Unload state and the Loaded Keys card
    // without this widget knowing about it.
    _controller.refresh();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    await _controller.refresh();
  }

  Future<void> _addKey(String path) async {
    // The passphrase dialog lives here because it needs a BuildContext;
    // everything after it is the controller's job.
    String? passphrase;
    if (await _controller.hasPassphrase(path)) {
      passphrase = await _promptPassphrase();
      if (passphrase == null) return;
    }
    if (!mounted) return;
    await _controller.loadKey(path, passphrase);
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
    await _controller.unloadKey(path);
  }

  Future<void> _removeAll() async {
    await _controller.unloadAll();
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

    final dir = _controller.sshDirectory;
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
      await _controller.generateKey(
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


    try {
      await _controller.generateKey(
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
      }
    } catch (e) {
      if (!mounted) return;
      ToastService.instance.showError(e is Exception
          ? e
          : Exception(e.toString()));
    }
  }

  String _shortPath(String path) => KeysController.shortPath(path);

  void _openSshFolder() {
    final dir = _controller.sshDirectory;
    if (dir.isEmpty) return;
    Process.run('explorer', [dir], runInShell: false);
  }

  bool _isKeyLoaded(String path) => _controller.isKeyLoaded(path);

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


    try {
      await _controller.addAuthorizedKey(text);
      await _refresh();
      if (mounted) {
        ToastService.instance.showSuccess('Authorized key added.');
      }
    } on SshKeyException catch (e) {
      if (!mounted) return;
      ToastService.instance.showError(e);
    } catch (e) {
      if (!mounted) return;
      ToastService.instance.showError(e is Exception
          ? e
          : Exception(e.toString()));
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

    // The controller refreshes internally, so the extra _refresh() here was a
    // second full reload of keys, agent state and authorized_keys.
    await _controller.removeAuthorizedKey(key.rawLine);
  }

Widget _buildKeyFileRow(ShadThemeData theme, String path) {
    final isLoaded = _isKeyLoaded(path);
    final canLoad = !_controller.isLoading && _controller.agentRunning && !isLoaded;
    final canUnload = !_controller.isLoading && _controller.agentRunning && isLoaded;
    final hasPub = _controller.hasPublicKey(path);

    // Progress belongs on the row being acted on. The tab no longer blanks
    // itself for a single-key action, so the row has to say so itself -- and
    // the other rows stay readable and still show their state.
    final isBusy = _controller.isBusyWith(path);

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
                if (_controller.commentOf(path) != null && _controller.commentOf(path)!.isNotEmpty)
                  Text(
                    _controller.commentOf(path)!,
                    style: theme.textTheme.muted,
                  ),
              ],
            ),
          ),
          if (isBusy)
            const Padding(
              padding: EdgeInsets.only(left: 8),
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
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
                    !_controller.isLoading && hasPub ? () => _viewPublicKey(path) : null,
                enabledTooltip: 'View public key of ${_shortPath(path)}',
                disabledTooltip: 'No .pub file for ${_shortPath(path)}',
              ),
              RowAction(
                label: 'Load',
                onPressed: canLoad ? () => _addKey(path) : null,
                enabledTooltip: 'Load ${_shortPath(path)} into ssh-agent',
                disabledTooltip: !_controller.agentRunning
                    ? 'Start the ssh-agent service first'
                    : 'Key is already loaded in agent',
              ),
              RowAction(
                label: 'Unload',
                onPressed: canUnload ? () => _removeKey(path) : null,
                enabledTooltip: 'Unload ${_shortPath(path)} from ssh-agent',
                disabledTooltip: !_controller.agentRunning
                    ? 'Start the ssh-agent service first'
                    : 'Key is not loaded in agent',
              ),
              RowAction(
                label: 'Delete',
                onPressed: !_controller.isLoading ? () => _deleteKeyFile(path) : null,
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
    final pubKey = await _controller.readPublicKey(path);
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

    // Unload-then-delete and the refresh both live in the controller, so this
    // used to call removeKey and then deleteKeyFile, which unloaded twice.
    await _controller.deleteKeyFile(path);
  }

  @override
  Widget build(BuildContext context) {
    // Without this the tab renders once and then never updates: every field it
    // reads now lives on the controller, which notifies instead of calling
    // setState.
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) => _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
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
                  onPressed: _controller.isLoading ? null : _generateKey,
                  child: const Text('Generate'),
                ),
              ),
              Semantics(
                button: true,
                label: 'Unload All Keys',
                child: Builder(
                  builder: (context) {
                    final canUnloadAll = !_controller.isLoading && _controller.agentRunning;
                    final unloadAllBtn = ShadButton.outline(
                      onPressed: canUnloadAll ? _removeAll : null,
                      child: const Text('Unload All'),
                    );
                    if (!canUnloadAll) {
                      return DisabledActionWrapper(
                        enabled: false,
                        tooltip: _controller.isLoading
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
                  onPressed: _controller.isLoading ? null : _refresh,
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
            description: Text('${plural(_controller.keyFiles.length, 'file')} in ~/.ssh'),
            child: _controller.isInitialLoad
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : _controller.keyFiles.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          'No key files found',
                          style: theme.textTheme.muted,
                        ),
                      )
                    : Column(
                        children: [
                          for (final path in _controller.keyFiles)
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
            description: Text('${plural(_controller.loadedKeys.length, 'key')} in agent'),
            child: _controller.isInitialLoad
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : !_controller.agentRunning
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
                    : _controller.loadedKeys.isEmpty
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
                          for (final key in _controller.loadedKeys)
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
                    onPressed: _controller.isLoading ? null : _addAuthorizedKeyDialog,
                    child: const Text('Add Key'),
                  ),
                ),
              ],
            ),
            description: Text(
              '${plural(_controller.authorizedKeys.length, 'authorized key')} in '
                  '~/.ssh/authorized_keys',
            ),
            child: _controller.isInitialLoad
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : _controller.authorizedKeys.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          'No authorized keys found',
                          style: theme.textTheme.muted,
                        ),
                      )
                    : Column(
                        children: [
                          for (final key in _controller.authorizedKeys)
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
                                        onPressed: _controller.isLoading
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
/// State and file I/O live in [DomainsController]. Only the dialogs stay
  /// here, because they need a [BuildContext].
  final _controller = DomainsController();

  late TextEditingController _configController;
  late final TextEditingController _hostController;

  @override
  void initState() {
    super.initState();
    _configController = TextEditingController();
    _hostController = TextEditingController();
    _refresh();
  }

  @override
  void dispose() {
    _controller.dispose();
    _configController.dispose();
    _hostController.dispose();
    super.dispose();
  }

  /// Reads config + known_hosts, then mirrors the config text into the field.
  ///
  /// The controller holds the text as the source of truth; the
  /// TextEditingController is only its view, so it has to be re-synced.
  Future<void> _refresh() async {
    await _controller.refresh();
    if (!mounted) return;
    if (_configController.text != _controller.configText) {
      _configController.text = _controller.configText;
    }
  }

  Future<void> _saveConfig() => _controller.saveConfig(_configController.text);

  void _openSshFolder() {
    final dir = _controller.sshDirectory;
    if (dir.isEmpty) return;
    Process.run('explorer', [dir], runInShell: false);
  }

  void _openKnownHostsFile() {
    final path = _controller.knownHostsPath;
    if (path.isEmpty) return;
    Process.run('explorer', ['/select,', path], runInShell: false);
  }

  String _shortPath(String path) => _controller.shortPath(path);

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
    await _controller.removeKnownHost(host, keyType);
  }

  Future<void> _checkHost(String host) => _controller.checkHost(host);

  Future<List<Map<String, String>>?> _scanAvailableHostKeys(String host) =>
      _controller.scanAvailableHostKeys(host);

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

    await _controller.addKnownHostKeys(host, chosenLines);
    if (mounted) {
      _hostController.clear();
      ToastService.instance.showSuccess('Known host added.');
    }
  }

Widget _buildHostRow(Map<String, String> entry, ShadThemeData theme) {
    final host = entry['host']!;
    final keyType = entry['keyType']!;
    // Read the controller once per row instead of once per reference.
    final status = _controller.hostStatus(host);
    final isChecking = _controller.isChecking(host);
    final isHostsLoading = _controller.isHostsLoading;
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
                onPressed: isHostsLoading || isChecking
                    ? null
                    : () => _checkHost(host),
                enabledTooltip: 'Scan host keys for $host',
                disabledTooltip: isChecking
                    ? 'Already checking $host'
                    : 'Wait for the current operation to finish',
              ),
              RowAction(
                label: 'Remove',
                onPressed: isHostsLoading
                    ? null
                    : () => _removeKnownHost(host, keyType),
                enabledTooltip: 'Remove $host from known_hosts',
                disabledTooltip: 'Wait for the current operation to finish',
              ),
            ],
          ),
          const SizedBox(width: 6),
          if (status != null)
            // Not a button. It used to be wrapped in ShadButton.ghost with an
            // empty onPressed, which put a dead control in the tab order and
            // announced it as a button to screen readers. The status is read
            // only; the tooltip below carries the detail instead.
            ShadTooltip(
              builder: (context) => Text(
                status == 'Unreachable'
                    ? 'No response from $host. Check the hostname and that'
                        ' port 22 is reachable, then try again.'
                    : status,
              ),
              child: Semantics(
                label: 'Host status for $host: $status',
                child: HostStatusBadge(status: status),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild on every controller notification. The config field is a
    // TextEditingController, so its own edits do not rebuild the tab, which is
    // what keeps typing in the textarea smooth.
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) => _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
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
                        onPressed: _controller.isLoading ? null : _refresh,
                        child: const Text('Reload'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (!_controller.isEditing)
                      Semantics(
                        button: true,
                        label: 'Edit SSH Config',
                        child: ShadButton.outline(
                          onPressed: _controller.isLoading
                              ? null
                              : _controller.beginEditing,
                          child: const Text('Edit'),
                        ),
                      ),
                    if (_controller.isEditing) ...[
                      Semantics(
                        button: true,
                        label: 'Save SSH Config',
                        child: ShadButton(
                          onPressed:
                              _controller.isLoading ? null : _saveConfig,
                          child: const Text('Save'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Semantics(
                        button: true,
                        label: 'Cancel SSH Config Edit',
                        child: ShadButton.outline(
                          onPressed: _controller.isLoading
                              ? null
                              : () {
                                  // Discard edits by restoring what is actually
                                  // on disk right now, not a cached copy.
                                  _configController.text =
                                      _controller.cancelEditing();
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
              child: _controller.isLoading
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
                      readOnly: !_controller.isEditing,
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
              '${plural(_controller.knownHosts.length, 'host')} in '
              '${_shortPath(_controller.knownHostsPath)}',
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 8),
                  child: Builder(
                    builder: (context) {
                      // Was a ValueListenableBuilder over a ValueNotifier that
                      // existed only to trigger a setState from an async gap.
                      // The controller already rebuilds this whole subtree, so
                      // reading the flag is enough.
                      final adding = _controller.isScanning;
                      return Row(
                      children: [
                        Expanded(
                          child: ListenableBuilder(
                            listenable: _hostController,
                            builder: (context, _) => ShadInput(
                              controller: _hostController,
                              placeholder: const Text('example.com'),
                              onSubmitted:
                                  adding ? null : (_) => _addKnownHost(),
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
                            onPressed: adding || _controller.isHostsLoading
                                ? null
                                : _addKnownHost,
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
                    );
                  },
                ),
              ),
              _controller.isHostsLoading
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : _controller.knownHosts.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(
                              'No known hosts found',
                              style: theme.textTheme.muted,
                            ),
                          )
                        : Column(
                            children: [
                              for (final entry in _controller.knownHosts)
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
