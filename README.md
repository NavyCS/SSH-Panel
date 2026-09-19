# SSH Panel

Windows desktop application for managing the OpenSSH `ssh-agent` service,
SSH keys, and `~/.ssh/config` / `known_hosts`.

Built with Flutter and the [shadcn/ui](https://pub.dev/packages/shadcn_ui) component
library. Service control goes through the Windows Service Control Manager via
[`package:win32`](https://pub.dev/packages/win32); the agent's _startup type_ is
set with `sc.exe` (a documented gap — `win32` cannot change the start type).
Packaged as an MSIX with the `winapp` CLI.

**On-demand elevation** — `windows/runner/app.manifest` declares
`asInvoker`, and `Package.appxmanifest` declares the `allowElevation`
capability. The app starts without elevation and requests admin via a single
UAC prompt (using `ShellExecute("runas")`) only when you click Start, Stop,
or change the startup type.

## Features

- **Service** — read `ssh-agent` running/stopped state, start, stop, and set the
  startup type (Automatic / Manual / Disabled).
- **Keys** — list files in `~/.ssh`, see which are loaded in the agent, add,
  remove, remove all, and generate a new ed25519 key with or without a
  passphrase.
- **Domains** — read and edit `~/.ssh/config`; list hosts recorded in
  `~/.ssh/known_hosts`.
- Fails gracefully when OpenSSH is not installed.

## Requirements

- Windows 10/11 (x64)
- Flutter (>= 3.41.0 for `shadcn_ui`)
- [Visual Studio Build Tools 2022](https://visualstudio.microsoft.com/downloads/)
  (MSBuild + C++ toolchain + Windows 10 SDK) — `flutter doctor` may report the
  install as "incomplete" even when the build succeeds; that is a false
  positive.
- [`winapp` CLI](https://github.com/microsoft/winappCli): `winget install
Microsoft.winappcli`
- OpenSSH (optional — the app detects its absence and degrades gracefully)

## Project layout

```
SSHPanel/
├── lib/
│   ├── main.dart              # shadcn_ui UI shell (Service / Keys / Domains tabs)
│   └── services/
│       ├── ssh_service.dart   # SshServiceManager — win32 SCM FFI
│       ├── ssh_check.dart     # OpenSSH presence detection
│       ├── ssh_keys.dart      # SshKeyManager — ssh-keygen / ssh-add
│       └── ssh_domains.dart   # SshConfigManager — ~/.ssh/config + known_hosts
├── windows/runner/app.manifest   # asInvoker with on-demand ShellExecute("runas") elevation
├── Package.appxmanifest          # allowElevation + runFullTrust
├── winapp.yaml
├── dist/                         # built MSIX
└── build/windows/x64/runner/Release/
```

## Build & package

```powershell
# 1. Install the winapp CLI (once)
winget install Microsoft.winappcli

# 2. Fetch dependencies
cd SSHPanel
flutter pub get

# 3. Initialise the winapp project (generates Package.appxmanifest + winapp.yaml)
winapp init .

# 4. Add the allowElevation capability to Package.appxmanifest
#    (winapp does not do this automatically)
#    <Capabilities>
#      <rescap:Capability Name="runFullTrust" />
#      <rescap:Capability Name="allowElevation" />
#    </Capabilities>

# 5. Generate a development certificate
winapp cert generate

# 6. Build the Windows release
flutter build windows --release

# 7. Package into an MSIX and sign it
#    NOTE: winapp package takes an INPUT folder, not an output path.
winapp package build/windows/x64/runner/Release `
    --manifest Package.appxmanifest `
    --cert devcert.pfx `
    --output dist/ssh_panel.msix

# 8. Install the certificate in the machine root store (requires elevation)
#    winapp cert install alone fails with access denied.
powershell -Command "Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy Bypass','-File','install-cert.ps1' -Verb RunAs -Wait"
# install-cert.ps1:
#   $pfx="D:\Proyectos\SSHPanel\devcert.pfx"
#   $pwd=ConvertTo-SecureString "password" -AsPlainText -Force
#   $cert=New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($pfx,$pwd)
#   $store=New-Object System.Security.Cryptography.X509Certificates.X509Store(
#       [System.Security.Cryptography.X509Certificates.StoreName]::Root,
#       [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
#   $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
#   $store.Add($cert); $store.Close()

# 9. Install and run the MSIX
Add-AppxPackage -Path dist/ssh_panel.msix
```

## Run (debug)

```powershell
winapp run build/windows/x64/runner/Release
```

> Elevation via loose-layout packages (`winapp run`) is undocumented. The
> proven elevation path is the packed MSIX: build → pack → install, then launch.

## Notes

- `app.manifest` must be created by hand — `flutter create` only writes an
  empty `runner.exe.manifest`, and `winapp` does not generate one.
- `allowElevation` is a **restricted capability** under the `rescap` namespace
  (`.../foundation/windows10/restrictedcapabilities`), _not_ `desktop6`.
- `winapp pack <output>` is invalid — `pack` aliases `package`, which takes an
  **input folder**.
- Key generation uses `ssh-keygen -P` (never `-N`, which errors on Windows) and
  passes the passphrase as a discrete argv argument (stdin hangs on Windows
  without a TTY).
- `flutter doctor` may warn the Visual Studio install is incomplete even though
  MSBuild, `cl.exe`, `link.exe` and the Windows 10 SDK are all present and the
  build succeeds.

## Error handling

All service failures surface as typed exceptions carrying the Windows error code
and a hint:

```
handleOpenFailed: Failed to open the Service Control Manager. (OpenSCManager error 5 -- access denied (the app is not running elevated))
accessDenied: Access denied opening the ssh-agent service. (OpenService error 5 -- the app is not running elevated)
serviceNotFound: The ssh-agent service does not exist. (OpenService error 1060)
```

## Loam

```powershell
dart pub global activate loam
```

```powershell
loam scan --format json > loam-report.json
```
