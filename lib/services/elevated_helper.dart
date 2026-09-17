/// Elevated helper process for 'una sola vez' elevation mode.
///
/// When the app runs in [modeOnce] elevation mode, a helper process is
/// launched once with administrator rights via `ShellExecute('runas')`.
/// The helper creates a local TCP server and stays alive, handling all
/// subsequent admin operations without additional UAC prompts.
///
/// The helper is launched with `Platform.resolvedExecutable --elevated-helper`.
/// It listens on a random port, writes the port number via [SettingsService],
/// and processes JSON commands over TCP.
///
/// Commands (JSON sent by the app):
///   `{"cmd": "start"}`           — Start ssh-agent service
///   `{"cmd": "stop"}`            — Stop ssh-agent service
///   `{"cmd": "setStartupType", "type": "automatic"}`
///                                — Set startup type
///
/// Responses (JSON from the helper):
///   `{"success": true, "result": "..."}`
///   `{"success": false, "error": "..."}`

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'settings_service.dart';

/// Default host for the helper TCP server.
const String _helperHost = '127.0.0.1';

/// Maximum time to wait for the helper server to start.
const Duration _serverStartTimeout = const Duration(seconds: 5);

/// The elevated helper server. Creates a TCP socket and processes commands.
class ElevatedHelperServer {
  final ServerSocket _server;

  ElevatedHelperServer(this._server);

  int get port => _server.port;

  /// Start listening for incoming connections indefinitely.
  void serve() {
    _server.listen(_handleConnection);
  }

  Future<void> _handleConnection(Socket socket) async {
    try {
      final buffer = StringBuffer();
      final subscription = socket.listen((data) {
        buffer.write(String.fromCharCodes(data));
      });
      await subscription.asFuture();
      try {
        final response = await _processCommand(buffer.toString());
        socket.write(jsonEncode(response));
      } catch (e) {
        socket.write(jsonEncode({'success': false, 'error': e.toString()}));
      }
      socket.close();
    } catch (_) {
      socket.close();
    }
  }

  Future<Map<String, dynamic>> _processCommand(String raw) async {
    try {
      final cmd = jsonDecode(raw) as Map<String, dynamic>;
      final command = cmd['cmd'] as String;

      switch (command) {
        case 'start':
          await _runSc(['start', 'ssh-agent']);
          return {'success': true, 'result': 'Service started'};
        case 'stop':
          await _runSc(['stop', 'ssh-agent']);
          return {'success': true, 'result': 'Service stopped'};
        case 'setStartupType':
          final type = cmd['type'] as String;
          await _runSc(['config', 'ssh-agent', 'start=', type]);
          return {'success': true, 'result': 'Startup type set to $type'};
        default:
          return {'success': false, 'error': 'Unknown command: $command'};
      }
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  Future<void> _runSc(List<String> args) async {
    final result = await Process.run('sc.exe', args);
    if (result.exitCode != 0) {
      throw Exception(
          'sc.exe exited with code ${result.exitCode}: ${result.stderr}');
    }
  }
}

/// Manages the elevated helper process lifecycle from the main app.
class ElevatedHelperManager {
  static final ElevatedHelperManager _instance = ElevatedHelperManager._();
  factory ElevatedHelperManager() => _instance;
  ElevatedHelperManager._();

  Process? _helperProcess;

  /// Launch the helper process with administrator rights via UAC.
  /// Returns true if the user accepted the UAC prompt.
  Future<bool> launch() async {
    final executable = Platform.resolvedExecutable;
    final args = ['--elevated-helper'];

    final result = _launchElevated(executable, args);
    if (!result) return false;

    // Wait for the helper to write its port.
    final port = await _waitForPort();
    if (port == null) return false;

    return true;
  }

  /// Returns true if the helper is available and we can connect to it.
  Future<bool> ensureRunning() async {
    final portStr = await SettingsService.getHelperPort();
    if (portStr == null) {
      return await launch();
    }

    final port = int.tryParse(portStr);
    if (port == null) return false;

    try {
      final socket = await Socket.connect(_helperHost, port);
      socket.destroy();
      return true;
    } catch (_) {
      return await launch();
    }
  }

  /// Send a command to the elevated helper and return the response.
  Future<Map<String, dynamic>> sendCommand(Map<String, dynamic> command) async {
    final portStr = await SettingsService.getHelperPort();
    if (portStr == null) throw Exception('Helper not running');

    final port = int.tryParse(portStr)!;
    final socket = await Socket.connect(_helperHost, port);

    final completer = Completer<Map<String, dynamic>>();
    final subscription = socket.listen((data) {
      final response = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
      if (!completer.isCompleted) {
        completer.complete(response);
      }
    });
    socket.add(utf8.encode(jsonEncode(command)));
    socket.close();

    final response = await completer.future;
    subscription.cancel();
    return response;
  }

  /// Terminate the helper process and clean up.
  Future<void> stop() async {
    await _helperProcess?.kill();
    _helperProcess = null;
    await SettingsService.clearHelperPort();
  }

  /// Check if the helper is currently running.
  Future<bool> get isRunning async {
    final portStr = await SettingsService.getHelperPort();
    if (portStr == null) return false;
    final port = int.tryParse(portStr);
    if (port == null) return false;

    try {
      final socket = await Socket.connect(_helperHost, port);
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<String?> _waitForPort() async {
    final deadline = DateTime.now().add(_serverStartTimeout);
    while (DateTime.now().isBefore(deadline)) {
      final portStr = await SettingsService.getHelperPort();
      if (portStr != null) return portStr;
      await Future.delayed(const Duration(milliseconds: 200));
    }
    return null;
  }

  bool _launchElevated(String executable, List<String> args) {
    return using((arena) {
      final result = ShellExecute(
        null,
        arena.pcwstr('runas'),
        arena.pcwstr(executable),
        arena.pcwstr(args.join(' ')),
        null,
        SW_HIDE,
      );
      return result.address > 32;
    });
  }
}

/// Entry point for the elevated helper process.
/// Call this when `Platform.executableArguments.contains('--elevated-helper')`.
Future<void> runElevatedHelper() async {
  final server = await ServerSocket.bind(_helperHost, 0);
  await SettingsService.setHelperPort(server.port.toString());

  final helper = ElevatedHelperServer(server);
  helper.serve();
}
