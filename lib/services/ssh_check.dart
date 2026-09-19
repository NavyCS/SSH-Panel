/// OpenSSH presence detection for Windows.
///
/// Probes whether OpenSSH (the `ssh` command and related tooling) is installed
/// on this machine using PowerShell. Two strategies are tried in order:
///
/// 1. `Get-WindowsCapability` — queries the Windows optional-feature store
///    for the `OpenSSH.Client` or `OpenSSH.Server` capability.
/// 2. `Get-Command ssh` — fast PATH-based fallback.
///
/// Neither invocation is fatal: if the shell itself cannot be launched, the
/// result is [OpenSshStatus.absent].
library;

import 'dart:io';

// ---------------------------------------------------------------------------
// Result type
// ---------------------------------------------------------------------------

/// Whether OpenSSH appears to be installed.
enum OpenSshStatus {
  /// At least one OpenSSH capability or command was found.
  present,

  /// No OpenSSH artifacts were detected.
  absent,
}

/// The outcome of an OpenSSH presence check.
// loam-ignore: unused-public-exports -- Standalone reusable OpenSSH presence check module
class OpenSshCheckResult {
  /// Creates a check result.
  const OpenSshCheckResult({required this.status, this.detail});

  /// Whether OpenSSH is installed.
  // loam-ignore: unused-public-exports -- Result model field
  final OpenSshStatus status;

  /// Optional human-readable note (e.g. capability name or error summary).
  // loam-ignore: unused-public-exports -- Result model field
  final String? detail;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Detects whether OpenSSH is installed on this Windows machine.
///
/// Returns [OpenSshCheckResult] with status [OpenSshStatus.present] or
/// [OpenSshStatus.absent].  Never throws.
// loam-ignore: unused-public-exports -- Standalone reusable OpenSSH presence check API
Future<OpenSshCheckResult> sshCheck() async {
  // Strategy 1 — Windows capability store (most authoritative).
  try {
    final capResult = await Process.run(
      'powershell.exe',
      [
        '-NoProfile',
        '-Command',
        // Try both Client and Server capabilities; either counts.
        'Get-WindowsCapability -Online '
            '| where Name -like "OpenSSH*" '
            '| Select-Object -ExpandProperty Name',
      ],
    );
    if (capResult.exitCode == 0) {
      final stdout = capResult.stdout.toString().trim();
      if (stdout.isNotEmpty) {
        return OpenSshCheckResult(
          status: OpenSshStatus.present,
          detail: 'capability: $stdout',
        );
      }
    }
  } catch (e) {
    // PowerShell unreachable or command failed; log notice and fall through.
    stderr.writeln('sshCheck strategy 1 notice: $e');
  }

  // Strategy 2 — PATH lookup via Get-Command.
  try {
    final cmdResult = await Process.run(
      'powershell.exe',
      [
        '-NoProfile',
        '-Command',
        'Get-Command ssh -ErrorAction SilentlyContinue '
            '| Select-Object -ExpandProperty Source',
      ],
    );
    if (cmdResult.exitCode == 0) {
      final stdout = cmdResult.stdout.toString().trim();
      if (stdout.isNotEmpty) {
        return OpenSshCheckResult(
          status: OpenSshStatus.present,
          detail: 'path: $stdout',
        );
      }
    }
  } catch (e) {
    // PATH lookup failed; log notice and return absent.
    stderr.writeln('sshCheck strategy 2 notice: $e');
  }

  return const OpenSshCheckResult(status: OpenSshStatus.absent);
}
