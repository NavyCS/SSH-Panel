/// SSH Agent Service control module for Windows.
///
/// Wraps the Windows Service Control Manager (SCM) via `package:win32` FFI
/// to manage the OpenSSH `ssh-agent` service. Uses `sc.exe` only for
/// setting the startup type (the single documented exception).
///
/// **FFI lifetime rule:** Every `using((arena) { ... })` block is
/// **synchronous**.  Async work (Process.run, Future.delayed, polling loops)
/// always lives *outside* the `using` block so the arena is never freed
/// while its pointers are still in flight.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'cancellation.dart';
import 'settings_service.dart';

// ---------------------------------------------------------------------------
// Service name constant
// ---------------------------------------------------------------------------

/// The canonical Windows service name for the OpenSSH agent.
const String _kServiceName = 'ssh-agent';

/// `SERVICE_QUERY_CONFIG` access mask.
///
/// Not exported by `package:win32`, so it is declared here with the value
/// documented in the Windows SDK (`winsvc.h`). Reading a service's
/// configuration only, which requires no elevation.
const int _serviceQueryConfig = 0x0001;

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

/// Typed representation of the `dwCurrentState` field from
/// `SERVICE_STATUS_PROCESS`.
enum SshServiceState {
  stopped,
  startPending,
  stopPending,
  running,
  continuePending,
  paused,
  unknown;

  /// Map the raw Win32 constant value to the enum.
  factory SshServiceState.fromWin32(int state) => switch (state) {
        1 => SshServiceState.stopped,
        2 => SshServiceState.startPending,
        3 => SshServiceState.stopPending,
        4 => SshServiceState.running,
        5 => SshServiceState.continuePending,
        7 => SshServiceState.paused,
        _ => SshServiceState.unknown,
      };
}

/// Desired startup type for the ssh-agent service.
enum StartupType {
  /// Start automatically when the system boots.
  automatic,

  /// Start on demand (manually).
  manual,

  /// Disabled — will not start.
  disabled,
}

// ---------------------------------------------------------------------------
// Typed error
// ---------------------------------------------------------------------------

/// Error codes produced by [SshServiceManager].
enum SshServiceErrorCode {
  /// OpenSSH is not installed on this machine.
  opensshNotInstalled,

  /// The `ssh-agent` service does not exist in the SCM.
  serviceNotFound,

  /// The SCM or service handle could not be opened.
  handleOpenFailed,

  /// The SCM refused the operation due to insufficient rights (e.g. the app
  /// is not elevated, or the service is access-protected).
  accessDenied,

  /// A service operation (start / stop / query) failed.
  operationFailed,

  /// The service did not reach the expected state within the timeout.
  timeout,

  /// An `sc.exe` invocation failed.
  scCommandFailed,

  /// The agent pipe was not reachable after the service reported RUNNING.
  agentPipeNotReady,
}

/// A typed exception thrown by [SshServiceManager] methods. The [code]
/// identifies the category; [message] is a human-readable explanation.
/// [rawDetail] may carry an OS-level detail string (never exposed to the
/// end user directly).
class SshServiceException implements Exception {
  SshServiceException(this.code, this.message, {this.rawDetail});

  final SshServiceErrorCode code;
  final String message;
  final String? rawDetail;

  @override
  String toString() =>
      rawDetail == null ? '${code.name}: $message' : '${code.name}: $message ($rawDetail)';
}

// ---------------------------------------------------------------------------
// Synchronous FFI helpers (called inside using() blocks)
// ---------------------------------------------------------------------------

/// Opens the SCM with `SC_MANAGER_CONNECT` (minimal access, no admin needed).
  ///
  /// Returns the SCM handle. Caller must close it.
  ///
  /// Throws a typed [SshServiceException] carrying the Windows error code in
  /// [SshServiceException.rawDetail] (surfaced by [SshServiceException.toString])
  /// so the UI can show *why* the SCM could not be opened instead of a bare
  /// "Failed to open the Service Control Manager." with no clue.
  SC_HANDLE _openScm() {
    // SC_MANAGER_CONNECT = 0x0001 — enough to enumerate/query services
    // without admin rights. Only start/stop/setStartupType need elevation.
    const int scmAccess = 0x0001; // SC_MANAGER_CONNECT
    final result = OpenSCManager(null, null, scmAccess);
  // These two return Win32Result<SC_HANDLE>, so there is no BOOL to check --
  // success is "a non-null handle". Checking result.error.isError instead
  // would consult a GetLastError() that win32 read unconditionally and which
  // can therefore be stale even on success.
  if (result.value == nullptr) {
    final code = result.error.code;
    final hint = _scmFailureHint(code);
    final detail = hint.isEmpty
        ? 'OpenSCManager error $code'
        : 'OpenSCManager error $code -- $hint';
    throw SshServiceException(
      SshServiceErrorCode.handleOpenFailed,
      'Failed to open the Service Control Manager.',
      rawDetail: detail,
    );
  }
  return result.value;
}

/// Translates a raw `OpenSCManager` Windows error code into a short,
/// actionable hint. Returns the empty string for unknown codes.
String _scmFailureHint(int code) => switch (code) {
      5 => 'access denied (the app is not running elevated)',
      1058 => 'the SCM itself is disabled or not running',
      1060 => 'the SCM service is not installed',
      1063 => 'the SCM is not accessible from this session',
      _ => '',
    };

/// Opens a service handle with the requested [access] mask.
///
/// Caller must close the returned handle.
///
/// Throws a typed exception that distinguishes *why* the service could not be
/// opened: [SshServiceErrorCode.accessDenied] when the SCM refused due to
/// insufficient rights (the app is not elevated), and
/// [SshServiceErrorCode.serviceNotFound] when the service simply does not
/// exist. These two cases need different next steps and were previously
/// collapsed into one unhelpful message.
SC_HANDLE _openService(SC_HANDLE scm, int access) {
  return using((arena) {
    final svcName = arena.pcwstr(_kServiceName);
    final result = OpenService(scm, svcName, access);
    if (result.value == nullptr) {
      final code = result.error.code;
      if (code == 5) {
        throw SshServiceException(
          SshServiceErrorCode.accessDenied,
          'Access denied opening the ssh-agent service.',
          rawDetail: 'OpenService error 5 -- the app is not running elevated',
        );
      }
      throw SshServiceException(
        SshServiceErrorCode.serviceNotFound,
        'The ssh-agent service does not exist.',
        rawDetail: 'OpenService error $code',
      );
    }
    return result.value;
  });
}

/// Queries the service status and returns the raw `dwCurrentState`.
SshServiceState _queryServiceState(SC_HANDLE svc) {
  return using((arena) {
    final statusPtr = arena.allocate<SERVICE_STATUS_PROCESS>(
      sizeOf<SERVICE_STATUS_PROCESS>(),
    );
    final bytesNeeded = arena.allocate<Uint32>(sizeOf<Uint32>());

    final result = QueryServiceStatusEx(
      svc,
      SC_STATUS_PROCESS_INFO,
      statusPtr.cast<Uint8>(),
      sizeOf<SERVICE_STATUS_PROCESS>(),
      bytesNeeded,
    );

    // Check the BOOL return value, not result.error.isError: win32 reads
    // GetLastError() unconditionally, so a success can carry a stale code.
    if (!result.value) {
      throw SshServiceException(
        SshServiceErrorCode.operationFailed,
        'QueryServiceStatusEx failed.',
        rawDetail: 'error ${result.error.code}',
      );
    }

    return SshServiceState.fromWin32(statusPtr.ref.dwCurrentState);
  });
}

/// Sends a control code to the service and returns the Win32 error code.
///
/// Returns `0` on success. Returns `1062` (`ERROR_SERVICE_NOT_ACTIVE`) if
/// the service is already stopped (when [controlCode] is
/// `SERVICE_CONTROL_STOP`).
int _controlService(SC_HANDLE svc, int controlCode) {
  return using((arena) {
    final statusPtr = arena.allocate<SERVICE_STATUS>(sizeOf<SERVICE_STATUS>());
    final result = ControlService(svc, controlCode, statusPtr);
    return result.error.code;
  });
}

/// Starts the service. Returns the Win32 error code.
///
/// Returns `0` on success or `1056` (`ERROR_SERVICE_ALREADY_RUNNING`).
int _startServiceRaw(SC_HANDLE svc) {
  final result = StartService(svc, 0, nullptr);
  return result.error.code;
}

/// Queries the configured startup type (`dwStartType`) of the service.
///
/// Uses the two-call `QueryServiceConfig` pattern: the first call passes a null
/// buffer purely to learn how many bytes are needed, the second call fills in a
/// correctly sized buffer.
///
/// Requires only `SERVICE_QUERY_CONFIG`, so no elevation is needed.
StartupType _queryStartupTypeRaw(SC_HANDLE svc) {
  return using((arena) {
    final bytesNeeded = arena.allocate<Uint32>(sizeOf<Uint32>());

    // First call: ask for the required size, ignoring the (expected) failure.
    QueryServiceConfig(svc, null, 0, bytesNeeded);

    final bufferSize = bytesNeeded.value;
    if (bufferSize < sizeOf<Uint32>() * 3) {
      // Too small to even hold the three leading DWORDs -- treat as unknown
      // rather than reading garbage out of the struct.
      throw SshServiceException(
        SshServiceErrorCode.operationFailed,
        'QueryServiceConfig returned an implausible buffer size.',
        rawDetail: 'cbBufSize=$bufferSize',
      );
    }

    final buffer = arena<Uint8>(bufferSize);
    final result = QueryServiceConfig(
      svc,
      buffer.cast<QUERY_SERVICE_CONFIG>(),
      bufferSize,
      bytesNeeded,
    );

    // Trust the BOOL return value, NOT result.error.isError.
    //
    // win32 reads GetLastError() unconditionally after every call, so a
    // *successful* QueryServiceConfig can still carry a stale non-zero code.
    // Verified on this machine: the size-probe call fails with
    // ERROR_INSUFFICIENT_BUFFER (122), and the successful call that follows
    // still reports GetLastError() == 6 (ERROR_INVALID_HANDLE). Checking
    // error.isError here threw a bogus failure for a call that had worked.
    if (!result.value) {
      final code = result.error.code;
      throw SshServiceException(
        code == 5
            ? SshServiceErrorCode.accessDenied
            : SshServiceErrorCode.operationFailed,
        'QueryServiceConfig failed.',
        rawDetail: 'error $code',
      );
    }

    final startType = buffer.cast<QUERY_SERVICE_CONFIG>().ref.dwStartType;

    // SERVICE_BOOT_START / SERVICE_SYSTEM_START are legacy boot-time types. A
    // user-mode OpenSSH agent is never configured with those, but map them to
    // automatic rather than failing, since that is what they effectively mean.
    return switch (startType) {
      SERVICE_AUTO_START || SERVICE_BOOT_START || SERVICE_SYSTEM_START =>
        StartupType.automatic,
      SERVICE_DEMAND_START => StartupType.manual,
      SERVICE_DISABLED => StartupType.disabled,
      _ => throw SshServiceException(
          SshServiceErrorCode.operationFailed,
          'Unrecognised startup type reported by the SCM.',
          rawDetail: 'dwStartType=$startType',
        ),
    };
  });
}


// ---------------------------------------------------------------------------
// SshServiceManager
// ---------------------------------------------------------------------------

/// Controls the Windows `ssh-agent` service via the SCM.
class SshServiceManager {
  // -----------------------------------------------------------------------
  // Presence check
  // -----------------------------------------------------------------------

  /// Asserts that OpenSSH is installed **and** the `ssh-agent` service is
  /// registered in the SCM. Throws [SshServiceException] otherwise.
  Future<void> _assertPresence() async {
    // 1. Check for OpenSSH via Get-Command (fast).
    final sshCheck = await Process.run(
      'powershell.exe',
      [
        '-NoProfile',
        '-Command',
        'Get-Command ssh -ErrorAction SilentlyContinue',
      ],
    );
    if (sshCheck.exitCode != 0) {
      throw SshServiceException(
        SshServiceErrorCode.opensshNotInstalled,
        'OpenSSH is not installed or not found on PATH.',
      );
    }

    // 2. Probe the service handle via the SCM (synchronous FFI).
    final scm = _openScm();
    try {
      final svc = _openService(scm, SERVICE_QUERY_STATUS);
      svc.close();
    } finally {
      scm.close();
    }
  }

  // -----------------------------------------------------------------------
  // queryStartupType
  // -----------------------------------------------------------------------

  /// Reads the startup type the service is *actually* configured with.
  ///
  /// Requires no elevation (`SERVICE_QUERY_CONFIG`), so this is safe to call on
  /// every refresh. Returns `null` when the state cannot be determined -- for
  /// example when OpenSSH is not installed -- so the UI can show "Unknown"
  /// rather than silently displaying a hardcoded value.
  Future<StartupType?> queryStartupType() async {
    if (!await _isPresenceCheckOptional()) return null;

    try {
      final scm = _openScm();
      try {
        final svc = _openService(scm, _serviceQueryConfig);
        try {
          return _queryStartupTypeRaw(svc);
        } finally {
          svc.close();
        }
      } finally {
        scm.close();
      }
    } on SshServiceException {
      // A non-elevated app can normally read this, but if the SCM refuses we
      // report "unknown" instead of failing the whole refresh.
      return null;
    }
  }

  /// Runs the OpenSSH presence check without throwing. Returns false when
  /// OpenSSH is absent, in which case service queries are meaningless.
  Future<bool> _isPresenceCheckOptional() async {
    try {
      await _assertPresence();
      return true;
    } on SshServiceException {
      return false;
    }
  }

  // -----------------------------------------------------------------------
  // checkStatus
  // -----------------------------------------------------------------------

  /// Queries the SCM for the current state of the `ssh-agent` service.
  Future<SshServiceState> checkStatus() async {
    await _assertPresence();

    final scm = _openScm();
    try {
      final svc = _openService(scm, SERVICE_QUERY_STATUS);
      try {
        return _queryServiceState(svc);
      } finally {
        svc.close();
      }
    } finally {
      scm.close();
    }
  }

  // -----------------------------------------------------------------------
  // Elevated execution helper
  // -----------------------------------------------------------------------

  /// Runs an `sc.exe` command with administrator privileges via UAC
  /// for `modePerAction` elevation. Waits for execution to finish.
  ///
  /// [args] is a list rather than a pre-joined string. It used to be
  /// interpolated into a single quoted PowerShell argument
  /// (`-ArgumentList "$scArgs"`), which only stayed safe because every caller
  /// passed a literal from this file. Taking a list makes that structural: each
  /// element is emitted as its own PowerShell single-quoted string, where the
  /// only character needing care is the quote itself. A value containing a
  /// space, a semicolon or a quote therefore stays one argument instead of
  /// becoming extra commands.
  Future<void> _runElevatedSc(List<String> args) async {
    final argList = args
        .map((arg) => "'${arg.replaceAll("'", "''")}'")
        .join(',');
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      'Start-Process sc.exe -ArgumentList @($argList) -Verb RunAs -Wait '
          '-WindowStyle Hidden',
    ]);
    if (result.exitCode != 0) {
      throw SshServiceException(
        SshServiceErrorCode.accessDenied,
        'Administrator permissions were not granted (UAC cancelled or denied).',
        rawDetail: result.stderr.toString(),
      );
    }
  }

  // -----------------------------------------------------------------------
  // start
  // -----------------------------------------------------------------------

  /// Starts the `ssh-agent` service **and** waits for the agent named-pipe
  /// to become reachable (verified via `ssh-add -l`).
  ///
  /// Returns `true` only when the pipe is actually usable.
  ///
  /// Pass a [CancellationToken] to abort the polling phases when the caller is
  /// torn down (tab switch, dispose). The token is only observed between
  /// iterations, so cancellation is not instantaneous.
  Future<bool> start({CancellationToken? cancellationToken}) async {
    await _assertPresence();
    if (cancellationToken?.isCancelled ?? false) {
      throw const CancellationTokenCancelled('Starting the ssh-agent service');
    }

    // On access denied, re-launch elevated and exit immediately.
    try {
      // Phase 1: Issue StartService (synchronous FFI).
      {
        final scm = _openScm();
        try {
          final svc = _openService(scm, SERVICE_START);
          try {
            final err = _startServiceRaw(svc);
            // ERROR_SERVICE_ALREADY_RUNNING (1056) is not fatal.
            if (err != 0 && err != 1056) {
              throw SshServiceException(
                SshServiceErrorCode.operationFailed,
                'StartService failed.',
                rawDetail: 'error $err',
              );
            }
          } finally {
            svc.close();
          }
        } finally {
          scm.close();
        }
      }

    // Phase 2: Poll until SERVICE_RUNNING or timeout (async loop, sync FFI).
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      if (cancellationToken?.isCancelled ?? false) {
        throw const CancellationTokenCancelled('Starting the ssh-agent service');
      }
      final scm = _openScm();
      SshServiceState state;
      try {
        final svc = _openService(scm, SERVICE_QUERY_STATUS);
        try {
          state = _queryServiceState(svc);
        } finally {
          svc.close();
        }
      } finally {
        scm.close();
      }

      if (state == SshServiceState.running) break;
      if (state == SshServiceState.stopped ||
          state == SshServiceState.stopPending) {
        throw SshServiceException(
          SshServiceErrorCode.operationFailed,
          'Service stopped unexpectedly during start.',
          rawDetail: 'state=${state.name}',
        );
      }

      await Future<void>.delayed(const Duration(milliseconds: 300));
    }

    // Timeout guard — verify final state is RUNNING.
    {
      final scm = _openScm();
      SshServiceState finalState;
      try {
        final svc = _openService(scm, SERVICE_QUERY_STATUS);
        try {
          finalState = _queryServiceState(svc);
        } finally {
          svc.close();
        }
      } finally {
        scm.close();
      }

      if (finalState != SshServiceState.running) {
        throw SshServiceException(
          SshServiceErrorCode.timeout,
          'Service did not reach RUNNING within 30 seconds.',
          rawDetail: 'finalState=${finalState.name}',
        );
      }
    }

    // Service reports RUNNING — now verify the named-pipe is reachable.
    return await _waitForAgentPipe(cancellationToken: cancellationToken);
    } on SshServiceException catch (e) {
      if (e.code != SshServiceErrorCode.accessDenied) rethrow;
      final mode = await SettingsService.getElevationMode();
      if (mode == SettingsService.modePerAction) {
        await _runElevatedSc(['start', _kServiceName]);
        return await _waitForAgentPipe(cancellationToken: cancellationToken);
      }
      rethrow;
    }
  }

  /// Polls `ssh-add -l` with exponential back-off until the agent pipe is
  /// reachable or retries are exhausted.
  Future<bool> _waitForAgentPipe({CancellationToken? cancellationToken}) async {
    const maxRetries = 10;
    var delay = Duration(milliseconds: 200);

    for (var attempt = 0; attempt < maxRetries; attempt++) {
      if (cancellationToken?.isCancelled ?? false) {
        throw const CancellationTokenCancelled('Waiting for the agent pipe');
      }
      final result = await Process.run('ssh-add', ['-l']);
      // exit 0 = keys loaded, exit 1 = no keys (but pipe alive),
      // exit 2 = agent not running.
      if (result.exitCode == 0 || result.exitCode == 1) {
        return true;
      }

      await Future<void>.delayed(delay);
      delay *= 2;
      if (delay > const Duration(seconds: 5)) {
        delay = const Duration(seconds: 5);
      }
    }

    throw SshServiceException(
      SshServiceErrorCode.agentPipeNotReady,
      'The ssh-agent pipe was not reachable after start.',
    );
  }

  // -----------------------------------------------------------------------
  // stop
  // -----------------------------------------------------------------------

  /// Stops the `ssh-agent` service and polls until it reports STOPPED.
  ///
  /// See [start] for the meaning of [cancellationToken].
  Future<void> stop({CancellationToken? cancellationToken}) async {
    await _assertPresence();
    if (cancellationToken?.isCancelled ?? false) {
      throw const CancellationTokenCancelled('Stopping the ssh-agent service');
    }

    // On access denied, re-launch elevated and exit immediately.
    try {
      // Phase 1: Issue ControlService(STOP) (synchronous FFI).
      {
        final scm = _openScm();
        try {
          final svc = _openService(scm, SERVICE_STOP | SERVICE_QUERY_STATUS);
          try {
            final err = _controlService(svc, SERVICE_CONTROL_STOP);
            // ERROR_SERVICE_NOT_ACTIVE (1062) = already stopped — not fatal.
            if (err != 0 && err != 1062) {
              throw SshServiceException(
                SshServiceErrorCode.operationFailed,
                'ControlService (STOP) failed.',
                rawDetail: 'error $err',
              );
            }
          } finally {
            svc.close();
          }
        } finally {
          scm.close();
        }
      }

    // Phase 2: Poll until SERVICE_STOPPED or timeout (async loop, sync FFI).
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      if (cancellationToken?.isCancelled ?? false) {
        throw const CancellationTokenCancelled('Stopping the ssh-agent service');
      }
      final scm = _openScm();
      SshServiceState state;
      try {
        final svc = _openService(scm, SERVICE_QUERY_STATUS);
        try {
          state = _queryServiceState(svc);
        } finally {
          svc.close();
        }
      } finally {
        scm.close();
      }

      if (state == SshServiceState.stopped) {
        return;
      }

      await Future<void>.delayed(const Duration(milliseconds: 300));
    }

    throw SshServiceException(
      SshServiceErrorCode.timeout,
      'Service did not reach STOPPED within 30 seconds.',
    );

    } on SshServiceException catch (e) {
      if (e.code != SshServiceErrorCode.accessDenied) rethrow;
      final mode = await SettingsService.getElevationMode();
      if (mode == SettingsService.modePerAction) {
        await _runElevatedSc(['stop', _kServiceName]);
        // Poll until stopped or timeout
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        while (DateTime.now().isBefore(deadline)) {
          final scm = _openScm();
          SshServiceState state;
          try {
            final svc = _openService(scm, SERVICE_QUERY_STATUS);
            try {
              state = _queryServiceState(svc);
            } finally {
              svc.close();
            }
          } finally {
            scm.close();
          }

          if (state == SshServiceState.stopped) {
            return;
          }

          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
        return;
      }
      rethrow;
    }
  }

  // -----------------------------------------------------------------------
  // setStartupType
  // -----------------------------------------------------------------------

  /// Sets the startup type via `sc.exe config ssh-agent start= ...`.
  ///
  /// This intentionally does **not** use `ChangeServiceConfig2` because that
  /// API only toggles the delayed-auto-start flag on a service already set to
  /// AUTO — it cannot set DEMAND or DISABLED.
  Future<void> setStartupType(StartupType type) async {
    await _assertPresence();

    final startArg = switch (type) {
      StartupType.automatic => 'auto',
      StartupType.manual => 'demand',
      StartupType.disabled => 'disabled',
    };

    // On access denied (exit code 5 = ERROR_ACCESS_DENIED),
    // throw accessDenied so the caller can trigger elevation.
    try {
      final result = await Process.run(
        'sc.exe',
        ['config', _kServiceName, 'start=', startArg],
      );

      if (result.exitCode != 0) {
        if (result.exitCode == 5) {
          throw SshServiceException(
            SshServiceErrorCode.accessDenied,
            'sc.exe config failed: access denied (not elevated).',
          );
        }
        throw SshServiceException(
          SshServiceErrorCode.scCommandFailed,
          'sc.exe config failed (exit code ${result.exitCode}).',
          rawDetail: '${result.stdout}\n${result.stderr}',
        );
      }
    } on SshServiceException catch (e) {
      if (e.code != SshServiceErrorCode.accessDenied) rethrow;
      final mode = await SettingsService.getElevationMode();
      if (mode == SettingsService.modePerAction) {
        await _runElevatedSc(['config', _kServiceName, 'start=', startArg]);
        return;
      }
      rethrow;
    }
  }
}
