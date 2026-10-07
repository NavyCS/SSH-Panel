# TODO

Open items, with enough context that the next person does not have to
rediscover them. Remove each one as it is done.

## 1. Re-sign the MSIX after the Publisher change — BLOCKING

`Package.appxmanifest` now declares `CN=DuArc` as its `Publisher`, so any MSIX
built before that change is signed by a certificate whose subject no longer
matches the manifest. `Add-AppxPackage` fails on an identity mismatch, so the
package currently on disk is not installable.

Regenerate the certificate and repackage:

```powershell
winapp cert generate --if-exists Overwrite
flutter build windows --release
winapp package build/windows/x64/runner/Release `
    --manifest Package.appxmanifest `
    --cert devcert.pfx `
    --output dist/ssh_panel.msix
```

Notes that matter:

- **`winapp cert generate` reads the publisher from the manifest.** Its help
  says the publisher is "auto-inferred if `--manifest` is provided or
  `Package.appxmanifest` is in working directory", so running it from the repo
  root produces a certificate with `CN=DuArc` and the manifest already matches.
  There is no publisher field in `winapp.yaml`, and none is needed. If it is
  ever run from elsewhere, pass `--manifest Package.appxmanifest` explicitly.
- **`--if-exists Overwrite` is required if `devcert.pfx` is still on disk.**
  The default is `Error`, so the command fails on an existing file. Deleting the
  old `.pfx` first has the same effect.
- **The password defaults to the publicly known string `password`.** The help
  text is explicit that this makes the certificate development-only, because
  anyone who obtains the `.pfx` can sign as you. Fine for local testing, which
  is what this certificate is for; do not reuse it to sign anything you ship.
  `--password` overrides it.
- Signing and packaging need no elevation.

Installing the certificate into the machine root store is the only part that
needs elevation, and it is not needed to build or sign. Either re-run the
generate with `--install` from an elevated shell, or add it by hand:

```powershell
# from an elevated shell
$store = New-Object System.Security.Cryptography.X509Certificates.X509Store(
    'Root', 'LocalMachine')
$store.Open('ReadWrite')
$store.Add(New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
    'devcert.pfx', 'password'))
$store.Close()
```

`devcert.pfx` is gitignored, so regenerating it changes nothing in the repo.

## 2. Decide whether CI should produce the MSIX

The release workflow (`.github/workflows/release.yaml`) publishes two things: a
ZIP of the loose build, and a single-file portable EXE via Enigma Virtual Box.
Neither is the MSIX, yet the README documents the MSIX as the distribution path.
That matters because `allowElevation` is a capability declared in
`Package.appxmanifest`, so it only exists in a packed MSIX. The README itself
says elevation via a loose layout is undocumented and that the proven path is
"build, pack, install, then launch" -- so shipping the ZIP or the portable EXE
means shipping a build whose elevation feature is at best unproven. Worth
deciding deliberately rather than by omission.

Three options, none obviously right:

- Build and sign the MSIX in CI. This needs the certificate in the runner,
  which means a secret, which means deciding how to store it.
- Drop the MSIX claim from the README and document the ZIP as the distribution.
- Keep building MSIX by hand and attach it to the release manually.

## 3. Pin the third-party GitHub Actions to commit SHAs

The workflow references `actions/checkout@v4`, `subosito/flutter-action@v2` and
`ncipollo/release-action@v1` by tag. Tags are mutable, so whoever controls the
upstream repo can repoint them at new code that runs with this repository's
credentials. Pinning to the full commit SHA, with the tag in a trailing comment
for readability, is the usual mitigation:

```yaml
uses: actions/checkout@<40-char-sha> # v4
```

Worth doing before the repository is widely forked.

## 4. Report the `loam` suppression bug upstream

`// loam-ignore: <ruleId> -- <reason>` directives have **no effect on
`slop-empty-catch`** findings in loam 0.1.15.

Measured, not assumed: three placements of the directive (trailing on the catch
line, on its own line above the catch, and on the closing brace so the finding
lands at `line + 1`) were all still reported, while two control cases using
`unused-public-exports` *were* suppressed — the `suppressed` counter went 3 → 5,
so the mechanism itself works. Reading the tool's source rules out a local
mistake: `suppression_engine.dart` matches on `(filePath, line, ruleId)`,
`inline_suppression_scanner.dart` records the directive on the line of the
comment, `analysis_runner.dart` passes the directive set to every rule, and
`slop_empty_catch_rule.dart` builds `filePath` from the same `relativePath` the
directive uses. There is no exemption and no bypass.

Consequences for this repository:

- The four directives in `lib/services/ssh_check.dart` (lines 30, 36, 40, 52)
  **are inert**. They look like they are protecting something and they are not.
  They do not need removing, because the findings they target happen not to
  fire today, but they must not be trusted as a mechanism.
- The empty-`catch` findings in `domains_controller.dart`,
  `service_controller.dart`, `ssh_keys.dart` and `app_credit.dart` had to be
  fixed for real, with `log()` from `dart:developer` carrying `error` and
  `stackTrace`, rather than suppressed.

Report it at <https://github.com/silvio-l/loam>. The one-line repro is the
control comparison above.