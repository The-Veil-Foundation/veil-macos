# Contributing to Veil

## Setup

Requirements: macOS 14.0+, a Swift 6 toolchain (Xcode 16+; CI builds on Xcode 26 for the
macOS 26 SDK). Optional: GitHub CLI (`gh`).

Fork the repo on GitHub, then:

```bash
git clone https://github.com/<your-fork>/veil.git && cd veil
Scripts/fetch-xray.sh
Scripts/fetch-singbox.sh
Scripts/fetch-tun2socks.sh
```

Veil is a **Swift Package Manager executable**, not an Xcode project — there is nothing to
generate and nothing to open. The three core binaries are declared as SPM resources but are
gitignored, so `swift build` fails until you have fetched them. Each fetch script verifies the
download against the version and SHA-256 pinned in `Scripts/cores.lock` and aborts on a
mismatch.

Build and run:

```bash
Scripts/run-app.sh release
```

`run-app.sh` assembles `Veil.app` (Info.plist, icon, ad-hoc codesign) and opens it. **A plain
`swift run` gives you no window** — macOS needs the bundle. `swift build` on its own is fine
for a compile check.

Tests:

```bash
swift test
```

### Bumping a core

Pin the new version in `Scripts/cores.lock`, then record its hashes:

```bash
RECORD_HASHES=1 Scripts/fetch-xray.sh      # and fetch-singbox.sh / fetch-tun2socks.sh
```

Then **smoke-test the actual invocation**, not just the build. A core release can change its
CLI: tun2socks 2.7 moved to POSIX flags, parsed `-device` as `-d evice`, and exited with a
usage message — which shipped as a TUN mode that never came up.

### Working on TUN mode

TUN runs through a root launchd daemon (`Sources/VeilHelper`) that talks to the app over XPC.
The daemon pins its client by ad-hoc code hash, so **it must be reinstalled after every rebuild
of the app** — otherwise it refuses the new binary and TUN will not start. Reinstall from
*Settings → Tunnel*, or:

```bash
Scripts/install-daemon.sh
```

Bump `VeilHelperInfo.protocolVersion` whenever helper behaviour changes, so an app running
against an already-installed older daemon rejects it instead of driving it.

Helper logs are root-owned:

```bash
sudo tail /Library/Application\ Support/Veil/helper/tun2socks.log
log show --predicate 'subsystem == "dev.local.veil.helper"' --last 10m
```

### Validating generated configs

Both config builders emit JSON that the cores themselves can check:

```bash
Sources/XrayClient/Resources/xray run -test -config <file>
Sources/XrayClient/Resources/sing-box check -c <file>
```

## Code Style

There is no linter config; match the surrounding code. The short version:

- 4-space indent, no trailing whitespace
- Explicit access control — `private` unless something outside the file needs it
- No force unwraps (`!`) or force casts (`as!`) outside tests
- Swift 6 strict concurrency: subprocess and network callbacks are `@Sendable`, so capture
  local copies and hop back with `Task { @MainActor in … }`
- User-facing strings go through `Loc` — never a bare literal in a view
- Doc comments (`///`) on types and non-obvious methods; comments explain *why*, not *what*

### Localization

SPM executables cannot easily use `.lproj` bundles, so translations live in a code table:
`Sources/XrayClient/Core/LocalizationTable.swift`, a flat array of
`(English key, language code, translation)` tuples. The English string **is** the key, and a
missing translation falls back to it.

Adding a string means adding one row per language you can cover — an incomplete set is fine,
English will fill the gaps. Keep the table an array of tuples: it used to be one large
dictionary literal, which is pathological for the Swift optimizer and pushed release builds of
the module to ~25 minutes.

`LocalizationTests` checks the table for structural problems. Run `swift test` after editing it.

## Commits

One line, imperative mood, no prefix and no body. Describe the behaviour that changed, not the
code that changed.

```
Start tun2socks with flags it can parse
Fix sing-box startup failure: drop direct DNS detour
Let a rule name the app it is for
```

## Branch Naming

Branch off `main`:

- `feat/singbox-native-routing`
- `fix/settings-and-update-followups`
- `docs/contributing-guide`

## Pull Requests

One logical change per PR. CI (`swift build` + `swift test` on macOS 26) has to be green.

Checklist:

- [ ] Tests added or updated
- [ ] `CHANGELOG.md` updated under the next version heading
- [ ] User-facing strings added to `LocalizationTable.swift`
- [ ] `swift test` passes
- [ ] TUN or helper changes: daemon reinstalled and the tunnel actually brought up once
- [ ] Core or config-builder changes: generated config validated with `xray run -test` /
      `sing-box check`

## Project Layout

```
Package.swift               SPM manifest — three targets, one executable
Sources/XrayClient/
  App.swift                 app entry, menu-bar extra, lifecycle
  Models/                   ProxyConfig, Subscription, AppSettings, Routing
  Core/                     link parsing, config builders, cores, tunnel, routing, updates
  Views/                    ContentView, MenuBarContent, SettingsSheet, RoutingSheet, …
  Resources/                xray, sing-box, tun2socks (fetched, gitignored)
Sources/VeilHelperKit/      XPC protocol + input validation shared with the helper
Sources/VeilHelper/         the privileged launchd daemon (routes, DNS, tun2socks)
Scripts/                    fetch-*, cores.lock, run-app.sh, make-icon.sh, *-daemon.sh
Tests/XrayClientTests/      parsers, link builder, config builders, security, routing
docs/                       website
```

## Adding a Protocol

A protocol touches four places:

1. `Models/ProxyConfig.swift` — a `ProxyProtocol` case, any new fields, and the `engine`
   computed property that decides whether Xray or sing-box handles it.
2. `Core/LinkParser.swift` — parse the `scheme://` share link, and
   `Core/LinkBuilder.swift` — build it back. They must round-trip.
3. `Core/XrayConfigBuilder.swift` or `Core/SingBoxProfileBuilder.swift` — emit the outbound.
4. `Tests/XrayClientTests/ParserTests.swift` — a real-world link, parsed and rebuilt.

Then validate a generated config with the core's own checker.

## Releasing

Maintainers only:

```bash
Scripts/set-version.sh X.Y.Z          # writes VERSION and the project version
# add a ## [X.Y.Z] section to CHANGELOG.md
git commit && git push
git tag -a vX.Y.Z -m "Release X.Y.Z" && git push origin vX.Y.Z
```

`release.yml` checks that the tag matches `VERSION`, extracts that CHANGELOG section into the
release body — **a tag with no section fails the build** — and attaches `Veil.app.zip`.

## Reporting Bugs

Open a [GitHub issue](https://github.com/faustyu1/veil/issues) with:

- macOS version and chip (Apple Silicon / Intel)
- Veil version
- Tunnel mode (Proxy or TUN) and the protocol of the server
- Reproduction steps
- The output of *Settings → Privacy → Export diagnostics* — it has URLs, tokens and device
  identifiers already removed

Never paste a raw subscription URL into an issue. The path is the access token.

## Security

Do not open a public issue for a vulnerability. Report it privately through
[GitHub Security Advisories](https://github.com/faustyu1/veil/security/advisories/new).

## License

Contributions are licensed under [AGPLv3](LICENSE).
