# CLAUDE.md

Guidance for Claude Code (and other agents) working in this repository.

## What this is

**Veil** — a native macOS VPN client for the Xray-core and sing-box proxy engines, written in
SwiftUI. Swift 6, macOS 14+. The iPhone/iPad app lives in `The-Veil-Foundation/veil-ios` and
compiles `Sources/XrayClient/Models` and `Core` from this repository as a submodule, so keep
those two folders building for iOS (`#if os(macOS)` around anything Mac-only).

This is a **Swift Package Manager executable**, not an Xcode project. There is no `.xcodeproj`
to open for the Mac app.

## Build and run

```bash
Scripts/fetch-xray.sh        # once — the three cores are gitignored SPM resources,
Scripts/fetch-singbox.sh     # so the build fails without them
Scripts/fetch-tun2socks.sh

swift build                  # compile check
swift test                   # tests
Scripts/run-app.sh release   # assemble Veil.app and launch it
```

**`swift run` gives no window.** The SPM product is still named `XrayClient`, but it is
packaged as `Veil.app` (executable renamed to `Veil`, bundle id `dev.local.veil`). Only
`run-app.sh` builds a bundle macOS will show. The app is called **Veil** everywhere
user-facing.

`Scripts/package-app.sh [version] [arch]` is the CI equivalent: no `open`, takes a version
argument and an optional architecture. `x86_64` cross-builds the Intel archive and names it
`dist/Veil-x86_64.app.zip` so it cannot be confused with the Apple Silicon `dist/Veil.app.zip`.

## Architecture

Two cores, launched as subprocesses, chosen per server by `ProxyConfig.engine`:

| Core | Protocols |
| --- | --- |
| Xray-core | VLESS, VMess, Trojan, Shadowsocks — Reality/TLS, `tcp`/`ws`/`grpc`/`http`/`xhttp` |
| sing-box | Hysteria2, TUIC, WireGuard, AnyTLS |

Both expose SOCKS + HTTP inbounds on `127.0.0.1`. Two tunnel modes consume them:

- **System Proxy** — `networksetup` points the active service at those ports. No admin rights.
  Only proxy-aware apps route; Telegram, the terminal and UDP do not.
- **TUN** — `tun2socks` driven by a **root launchd daemon** (`dev.local.veil.helper`).

### Layout

```
Sources/XrayClient/Models/      ProxyConfig, Subscription, AppSettings, Routing
Sources/XrayClient/Core/        parsing, config builders, cores, tunnel, routing, updates
Sources/XrayClient/Views/       ContentView, MenuBarContent, SettingsSheet, RoutingSheet, …
Sources/VeilHelperKit/          XPC protocol + input validation shared with the helper
Sources/VeilHelper/             the privileged launchd daemon
Scripts/                        fetch-*, cores.lock, run-app.sh, *-daemon.sh, set-version.sh
Tests/XrayClientTests/          parsers, link builder, config builders, security, routing
docs/                           website
```

## Rules that are easy to get wrong

### The helper must be reinstalled after every app rebuild

The daemon pins its client by **ad-hoc cdhash** (there is no paid Apple membership), so a new
build is a new hash and the installed helper refuses it — TUN silently will not start. Run
`Scripts/install-daemon.sh` (one `osascript` admin prompt) after rebuilding. A missing
requirement file makes the daemon refuse *all* clients, by design.

Bump `VeilHelperInfo.protocolVersion` whenever helper behaviour changes, so the app rejects an
already-installed older daemon instead of driving it.

Helper logs are root-owned and never reach the app UI:

```bash
sudo tail /Library/Application\ Support/Veil/helper/tun2socks.log
log show --predicate 'subsystem == "dev.local.veil.helper"' --last 10m
```

### The TUN stack must be `gvisor`

sing-box 1.14's default `mixed` stack kills all TCP in TUN mode while every indicator still
says connected. Pin it.

### mux.cool must stay off

It silently kills bridged XHTTP nodes.

### Localization lives in a code table

`Core/LocalizationTable.swift` is a flat array of `(English key, language code, translation)`
tuples. The English string is the key; a missing translation falls back to it. **Keep it an
array of tuples** — it used to be one large dictionary literal, which is pathological for the
Swift optimizer and pushed release builds of the module to ~25 minutes. Every user-facing
string goes through `Loc`.

### Swift 6 concurrency

Subprocess and network callbacks are `@Sendable`. Capture local copies and hop back with
`Task { @MainActor in … }`.

### SwiftUI exclusivity

Deleting from a collection bound to a `ForEach` must pass the id **by value**. Reading a
`$rule` binding inside `removeAll` traps with an exclusivity conflict (SIGABRT) — this was a
real crash in `RoutingSheet`.

### Xray routing

Do not use `geoip:private`; it needs `geoip.dat`. Use explicit private CIDRs.

### `SystemProxy.primaryService`

Must pick the interface holding the default route (`route -n get default`), **not** the first
service in the order — otherwise it configures a serial or USB device.

### Cores are pinned

`Scripts/cores.lock` records version + SHA-256 per architecture. Re-record with
`RECORD_HASHES=1 Scripts/fetch-xray.sh`; the release pipeline cross-builds the Intel zip on an
Apple Silicon runner with `TARGET_ARCH=x86_64 Scripts/fetch-*.sh`, so every core needs both an
`arm64` and an `x86_64` line. After bumping a core, **smoke-test the real
invocation**: tun2socks 2.7 switched to POSIX flags, read `-device` as `-d evice`, and exited
with a usage message — shipping a TUN mode that never came up.

### macOS appearance is decided by the build SDK

The current Tahoe / Liquid Glass look is gated on the SDK the binary links against, not the OS
it runs on. If the app looks dated, check the SDK before touching any view code — CI runs
`macos-26` for exactly this reason.

## Validating generated configs

```bash
Sources/XrayClient/Resources/xray run -test -config <file>
Sources/XrayClient/Resources/sing-box check -c <file>
```

## Secrets

Subscription URLs (the path **is** the access token) and device identifiers live in the
Keychain (`Core/Keychain.swift`, service `com.veil.client`). `store.json` records only that
they exist, as a `0600` file in a `0700` directory (`Core/SecureFile.swift`). The HWID is a
random UUID, sent to panels as `X-Hwid` only — never in a query parameter or the User-Agent.
`Core/Redaction.swift` strips URLs, tokens and IDs from exported diagnostics.

Never print a subscription URL, token or device identifier to the log, a test fixture, or an
issue.

## Conventions

- Commits: one line, imperative, no prefix and no body — describe the behaviour that changed.
- Branches off `main`: `feat/…`, `fix/…`, `docs/…`.
- `CHANGELOG.md` gets an entry under the next version heading.
- Full contributor guide: [CONTRIBUTING.md](CONTRIBUTING.md).

## Releasing

```bash
Scripts/set-version.sh X.Y.Z    # writes VERSION and the project version
# add a ## [X.Y.Z] section to CHANGELOG.md — release.yml FAILS without it
git tag -a vX.Y.Z -m "Release X.Y.Z" && git push origin vX.Y.Z
```

`release.yml` checks the tag against `VERSION`, extracts that CHANGELOG section into the
release body, and attaches `Veil.app.zip`. `ci.yml` runs build + test on every push and PR to
`main`.

## License

AGPLv3. Contributions are licensed under it.
