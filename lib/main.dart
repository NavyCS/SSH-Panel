import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'services/ssh_service.dart';
import 'services/ssh_keys.dart';
import 'services/ssh_domains.dart';

void main() {
  runApp(const SshPanelApp());
}

/// Renders a service error for the UI. [SshServiceException.accessDenied]
/// is the one case where the user can actually *do* something — the app was
/// launched without elevation — so it gets a specific instruction instead of
/// a generic red banner.
String _serviceErrorText(SshServiceException e) {
  if (e.code == SshServiceErrorCode.accessDenied) {
    return 'SSH Panel is not running as administrator, so it cannot control '
        'the ssh-agent service. Reinstall the MSIX and launch the app once — '
        'it will ask for elevation.';
  }
  return e.toString();
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

  @override
  void initState() {
    super.initState();
    _tabsController = ShadTabsController<String>(value: 'service');
  }

  @override
  void dispose() {
    _tabsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

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
              Icon(
                LucideIcons.server,
                size: 20,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 10),
              Text(
                'SSH Panel',
                style: theme.textTheme.h3,
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
  String? _error;
  StartupType _startupType = StartupType.manual;

  @override
  void initState() {
    super.initState();
    _refreshStatus();
  }

  Future<void> _refreshStatus() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final status = await _serviceManager.checkStatus();
      if (!mounted) return;
      setState(() {
        _status = status;
        _loading = false;
      });
    } on SshServiceException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _serviceErrorText(e);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _serviceErrorText(e is SshServiceException
            ? e
            : SshServiceException(SshServiceErrorCode.operationFailed, e.toString()));
        _loading = false;
      });
    }
  }

  Future<void> _startService() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _serviceManager.start();
      if (!mounted) return;
      await _refreshStatus();
    } on SshServiceException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _serviceErrorText(e);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _serviceErrorText(SshServiceException(
            SshServiceErrorCode.operationFailed, e.toString()));
        _loading = false;
      });
    }
  }

  Future<void> _stopService() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _serviceManager.stop();
      if (!mounted) return;
      await _refreshStatus();
    } on SshServiceException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _serviceErrorText(e);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _serviceErrorText(SshServiceException(
            SshServiceErrorCode.operationFailed, e.toString()));
        _loading = false;
      });
    }
  }

  Future<void> _setStartupType(StartupType type) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _serviceManager.setStartupType(type);
      if (!mounted) return;
      setState(() {
        _startupType = type;
        _loading = false;
      });
    } on SshServiceException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _serviceErrorText(e);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _serviceErrorText(SshServiceException(
            SshServiceErrorCode.operationFailed, e.toString()));
        _loading = false;
      });
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
                  if (!_loading && _error == null)
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
                    : _error != null
                        ? ShadAlert.destructive(
                            title: const Text('Error'),
                            description: Text(_error!),
                          )
                        : Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              ShadButton(
                                onPressed: _loading ? null : _startService,
                                child: const Text('Start'),
                              ),
                              ShadButton.destructive(
                                onPressed: _loading ? null : _stopService,
                                child: const Text('Stop'),
                              ),
                              ShadButton.outline(
                                onPressed: _loading ? null : _refreshStatus,
                                child: const Text('Refresh'),
                              ),
                            ],
                          ),
              ),
            ),
          ),

          const SizedBox(height: 16),

          // ---- Startup type card ----
          LayoutBuilder(
            builder: (context, constraints) => ShadCard(
              width: constraints.maxWidth,
              title: const Text('Startup Type'),
              description: const Text(
                'Configure how the ssh-agent service starts with Windows',
              ),
              child: Padding(
                padding: const EdgeInsets.only(top: 12),
                child: ShadSelect<StartupType>(
                  initialValue: _startupType,
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
                ),
              ),
            ),
          ),
        ],
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
  List<String> _keyFiles = [];
  List<LoadedKey> _loadedKeys = [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final keyFiles = await _keyManager.listKeyFiles();
      final loadedKeys = await _keyManager.listLoadedKeys();
      if (!mounted) return;
      setState(() {
        _keyFiles = keyFiles;
        _loadedKeys = loadedKeys;
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
      await _keyManager.addKey(path);
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
    final nameController = TextEditingController(text: 'id_ed25519');
    final commentController = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => ShadDialog(
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
            ShadInput(
              controller: nameController,
              placeholder: const Text('Key name'),
            ),
            const SizedBox(height: 12),
            ShadInput(
              controller: commentController,
              placeholder: const Text('Comment (optional)'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true) return;

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _keyManager.generateKey(
        name: nameController.text,
        comment: commentController.text.isEmpty ? null : commentController.text,
      );
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

  String _shortPath(String path) {
    final parts = path.split(RegExp(r'[/\\]'));
    return parts.isNotEmpty ? parts.last : path;
  }

  void _openSshFolder() {
    final dir = _keyManager.sshDirectory;
    if (dir.isEmpty) return;
    Process.run('explorer', [dir], runInShell: false);
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
              ShadButton.ghost(
                onPressed: _loading ? null : _refresh,
                child: const Icon(LucideIcons.refreshCw, size: 16),
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
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Row(
                                children: [
                                  const Icon(
                                    LucideIcons.keyRound,
                                    size: 14,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      _shortPath(path),
                                      style: theme.textTheme.small,
                                    ),
                                  ),
                                  ShadTooltip(
                                    builder: (context) => Text(path),
                                    child: ShadButton.ghost(
                                      size: ShadButtonSize.sm,
                                      onPressed: _loading
                                          ? null
                                          : () => _addKey(path),
                                      child: const Text('Load'),
                                    ),
                                  ),
                                  ShadTooltip(
                                    builder: (context) => Text(path),
                                    child: ShadButton.ghost(
                                      size: ShadButtonSize.sm,
                                      onPressed: _loading
                                          ? null
                                          : () => _removeKey(path),
                                      child: const Text('Unload'),
                                    ),
                                  ),
                                ],
                              ),
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
                : _loadedKeys.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          'No keys loaded in the agent',
                          style: theme.textTheme.muted,
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

  void _saveConfig() {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _configManager.writeConfig(_configController.text);
      setState(() {
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

void _openSshFolder() {
    final dir = _configManager.sshDirectory;
    if (dir.isEmpty) return;
    Process.run('explorer', [dir], runInShell: false);
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
      _loading = true;
      _error = null;
    });
    try {
      _configManager.removeKnownHost(host, keyType);
      await _refresh();
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
    setState(() {
      _loading = true;
      _error = null;
    });
    List<String> keyLines;
    try {
      keyLines = await _configManager.scanHostKeys(host);
    } on SshConfigException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
      return;
    }
    if (!mounted) return;
    setState(() => _loading = false);

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
      _loading = true;
      _error = null;
    });
    try {
      await _configManager.writeKnownHostKeys(host, chosenLines);
      _hostController.clear();
      await _refresh();
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
              onPressed: _loading || _checkingHosts.contains(host)
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
              onPressed: _loading
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
            footer: Row(
              children: [
                ShadButton.outline(
                  onPressed: _loading ? null : _refresh,
                  child: const Text('Reload'),
                ),
                const SizedBox(width: 8),
                ShadButton(
                  onPressed: _loading ? null : _saveConfig,
                  child: const Text('Save'),
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
                      minHeight: 200,
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
                  onPressed: _loading ? null : _addKnownHost,
                  child: const Icon(LucideIcons.plus, size: 14),
                ),
              ],
            ),
            description: Text('${_knownHosts.length} host(s) in known_hosts'),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 8),
                  child: ShadInput(
                    controller: _hostController,
                    placeholder: const Text('example.com'),
                    onSubmitted: (_) => _addKnownHost(),
                  ),
                ),
                _loading
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