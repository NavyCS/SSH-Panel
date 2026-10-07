# <img width="25" height="25" alt="icon" src="assets/icon.png" /> SSH Panel

Windows desktop application for managing the OpenSSH `ssh-agent` service,SSH keys, and `~/.ssh/config` / `known_hosts`.

<p align="center">
  <img width="48%" alt="01" src="https://github.com/user-attachments/assets/b41a9bbc-6853-4217-82fc-8e9d80a8338c" />
  <img width="48%" alt="02" src="https://github.com/user-attachments/assets/0a4f960b-8766-423c-a96b-94779ddeda23" />
  <img width="48%" alt="03" src="https://github.com/user-attachments/assets/4efc3408-0d7d-4035-a3c4-32a35fcb9941" />
  <img width="48%" alt="04" src="https://github.com/user-attachments/assets/491a4183-0c7d-402c-a4b9-3cccaefbd039" />
</p>

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
- [Enigma Virtual Box](https://enigmaprotector.com/en/aboutvb.html) (optional — to package it into a portable EXE file)

## Project layout

```
SSHPanel/
├── lib/
│   ├── main.dart                 # shadcn_ui UI shell (~1900 lines): Service / Keys / Domains tabs
│   ├── toast_service.dart        # centralized toasts + global error reporting
│   ├── services/
│   │   ├── ssh_service.dart      # SshServiceManager — win32 SCM FFI
│   │   ├── ssh_keys.dart         # SshKeyManager — ssh-keygen / ssh-add
│   │   ├── ssh_domains.dart      # SshConfigManager — ~/.ssh/config + known_hosts
│   │   ├── ssh_check.dart        # OpenSSH presence detection
│   │   ├── path_guard.dart       # confines paths before handing them to external programs
│   │   ├── file_permissions.dart # ACL hardening for directories the app creates
│   │   ├── agent_state.dart      # shared notifier for the agent service state
│   │   ├── settings_service.dart # settings persistence + process-elevation helpers
│   │   └── cancellation.dart     # cooperative cancellation for polling loops
│   ├── features/
│   │   ├── service/              # service_controller.dart
│   │   ├── keys/                 # keys_controller.dart
│   │   └── domains/              # domains_controller.dart, host_row.dart,
│   │                             # add_host_field.dart, select_keys_dialog.dart
│   └── shared/
│       ├── widgets/              # action_row.dart, disabled_action_wrapper.dart,
│       │                         # app_credit.dart, agent_status_badge.dart,
│       │                         # host_status_badge.dart, title_bar.dart
│       ├── dialogs/
│       │   └── passphrase_dialog.dart
│       ├── plural.dart           # count with a correctly pluralised noun
│       └── open_ssh_folder.dart  # guarded "open ~/.ssh in Explorer"
├── windows/runner/app.manifest   # asInvoker with on-demand ShellExecute("runas") elevation
├── Package.appxmanifest          # allowElevation + runFullTrust
├── winapp.yaml
└── (build output — gitignored, not in the repo)
    ├── dist/                     # built MSIX
    └── build/windows/x64/runner/Release/   # loose-layout flutter build
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

# 6. Generate Icon
dart run flutter_launcher_icons

# 7. Build the Windows release
flutter build windows --release

# 8. Package into an MSIX and sign it
#    NOTE: winapp package takes an INPUT folder, not an output path.
winapp package build/windows/x64/runner/Release `
    --manifest Package.appxmanifest `
    --cert devcert.pfx `
    --output dist/ssh_panel.msix

# 9. Install the certificate in the machine root store (requires elevation)
#    winapp cert install alone fails with access denied.
#    There is no install-cert.ps1 in the repo — save the block below as
#    install-cert.ps1 in the repo root, then run the command below from there.
#    ("password" is the default password `winapp cert generate` writes into
#    devcert.pfx — see `winapp cert generate --help`. If you passed --password,
#    use that same value below.)
# install-cert.ps1:
#   $pfx=Join-Path $PSScriptRoot "devcert.pfx"   # the repo root, wherever you cloned it
#   $pwd=ConvertTo-SecureString "password" -AsPlainText -Force
#   $cert=New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($pfx,$pwd)
#   $store=New-Object System.Security.Cryptography.X509Certificates.X509Store(
#       [System.Security.Cryptography.X509Certificates.StoreName]::Root,
#       [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
#   $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
#   $store.Add($cert); $store.Close()
powershell -Command "Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy Bypass','-File','install-cert.ps1' -Verb RunAs -Wait"

# 10. Install and run the MSIX
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
- Both passphrase paths keep the value off the command line: it reaches
  `ssh-keygen` through an `SSH_ASKPASS` helper (a `.cmd` that prints a sibling
  passphrase file) with `SSH_ASKPASS_REQUIRE=force` and `DISPLAY` set — loading
  a key and generating one alike — so the value never lands in the process
  table, where any process on the machine can read a command-line argument
  (`Get-CimInstance Win32_Process`, the Details tab of Task Manager, EDR
  agents). The only `-P` left is `-P ''` for a key without a passphrase, which
  is not a secret. Stdin is not an alternative either — `ssh-keygen` on Windows
  blocks forever without a TTY.
- Key generation never uses `-N` (Win32-OpenSSH's `ssh-keygen` ignores it).
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

Inline `// loam-ignore:` directives do **not** suppress `slop-empty-catch`
findings in loam 0.1.15: three separate placements were measured against a
positive control in `unused-public-exports`, where the same directive does
suppress correctly. This is a limitation of the tool rather than project
policy — on `slop-empty-catch` the directive currently has no effect, so the
finding will stay in the report until loam fixes it.
