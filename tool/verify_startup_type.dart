// Throwaway runtime check for the new QueryServiceConfig FFI path.
// Run with: dart run tool/verify_startup_type.dart
//
// Exists because a wrong pointer size or struct offset compiles and analyzes
// fine but only fails when it actually talks to the SCM.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

const String serviceName = 'ssh-agent';
const int serviceQueryConfig = 0x0001;

void main() {
  final scmResult = OpenSCManager(null, null, 0x0001);
  if (scmResult.error.isError) {
    stderr.writeln('FAIL: OpenSCManager error ${scmResult.error.code}');
    exit(1);
  }
  final scm = scmResult.value;

  final svcResult = using((arena) {
    final name = arena.pcwstr(serviceName);
    return OpenService(scm, name, serviceQueryConfig);
  });
  if (svcResult.error.isError) {
    stderr.writeln('FAIL: OpenService error ${svcResult.error.code} '
        '(the ssh-agent service is probably not installed on this machine)');
    scm.close();
    exit(1);
  }
  final svc = svcResult.value;

  try {
    final out = using((arena) {
      final bytesNeeded = arena.allocate<Uint32>(sizeOf<Uint32>());
      final probe = QueryServiceConfig(svc, null, 0, bytesNeeded);
      stdout.writeln('probe: value=${probe.value} GetLastError=${probe.error.code} '
          '(this failure is expected and is how we learn the size)');
      final bufferSize = bytesNeeded.value;
      stdout.writeln('cbBufSize reported by SCM: $bufferSize '
          '(struct is ${sizeOf<QUERY_SERVICE_CONFIG>()} bytes)');

      final buffer = arena<Uint8>(bufferSize);
      final result = QueryServiceConfig(
        svc,
        buffer.cast<QUERY_SERVICE_CONFIG>(),
        bufferSize,
        bytesNeeded,
      );
      stdout.writeln('real call: value=${result.value} '
          'GetLastError=${result.error.code}');
      // Trust the BOOL return, NOT GetLastError: win32 reads last-error
      // unconditionally, so a successful call can carry a stale non-zero code.
      if (!result.value) {
        stderr.writeln('FAIL: QueryServiceConfig returned FALSE, '
            'error ${result.error.code}');
        exit(1);
      }
      final cfg = buffer.cast<QUERY_SERVICE_CONFIG>().ref;
      return (
        startType: cfg.dwStartType,
        serviceType: cfg.dwServiceType,
        displayName: cfg.lpDisplayName.toDartString(),
        binaryPath: cfg.lpBinaryPathName.toDartString(),
        startName: cfg.lpServiceStartName.toDartString(),
      );
    });

    stdout.writeln('lpDisplayName     = ${out.displayName}');
    stdout.writeln('lpServiceStartName= ${out.startName}');
    stdout.writeln('lpBinaryPathName  = ${out.binaryPath}');
    stdout.writeln('dwStartType       = ${out.startType}');

    final mapped = switch (out.startType) {
      SERVICE_AUTO_START || SERVICE_BOOT_START || SERVICE_SYSTEM_START =>
        'automatic',
      SERVICE_DEMAND_START => 'manual',
      SERVICE_DISABLED => 'disabled',
      _ => 'UNRECOGNISED',
    };
    stdout.writeln('maps to StartupType.$mapped');
    if (mapped == 'UNRECOGNISED') exit(1);
    stdout.writeln('OK');
  } finally {
    svc.close();
    scm.close();
  }
}
