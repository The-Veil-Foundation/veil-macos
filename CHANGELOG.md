# Changelog

All notable changes to Veil are recorded here. Versions follow
[Semantic Versioning](https://semver.org/).

## [1.12.0] — Unreleased

### Added

- The iOS app catches up with the desktop. The server list now has subscription
  sections with notes, traffic and expiry, grouping, tag and protocol filters,
  sort by ping, pins, custom names and tags, and an arrange mode.
- New Sources tab on iOS. It shows what each subscription returned, what was
  skipped and why, and the groups the panel declared. Every node opens in an
  inspector as Xray JSON or a share link, and manual nodes can be edited there.
- Fastest-node and manual groups on iOS, your own or the panel's. Rules can send
  traffic to a single server or a group, not only to proxy, direct or block.
- Community rule lists, the full DNS editor (servers, detours, fake IP, DNS
  rules) and the geo database screen on iOS.
- iOS shows **Apply now** while connected when routing, DNS or groups changed.
  It reloads the core without dropping the VPN.
- iOS settings gain list options, the subscription User-Agent, device ID
  management and a diagnostics report that is redacted before it is shared.
- iOS long-press menus keep the everyday actions on top. **Advanced** swaps the
  open menu for the rarer ones, with Back to return, and the app behind is
  blurred while a menu is up.
- Grouping, sort by ping and every filter live in one menu in the iOS
  navigation bar.
- The iOS QR code is drawn with rounded dots and the app's mark, opens at once,
  and has proper Copy and Share buttons.

### Changed

- The iOS app moved to its own repository,
  [veil-ios](https://github.com/The-Veil-Foundation/veil-ios), with its history.
  It still builds the shared `Models` and `Core` from here as a submodule.

- iOS still runs only Xray. A fastest-node group runs as an Xray `leastPing`
  balancer, and a manual group routes to its chosen member. Some things Xray
  cannot do are left out of the config instead of failing it: per-app and
  inverted rules, rule sets, and DNS-over-TLS servers.
- iOS traffic counters now include every server in a group, and servers given
  by IP are routed outside the tunnel so their ping is real.
- On iOS, presets that bypass the LAN now keep private networks off the VPN
  entirely, instead of sending them through the tunnel to be routed direct.
  Printers, NAS boxes and the router stay reachable at full speed. Switching
  presets while connected re-applies the routes without dropping the VPN.
- WireGuard servers from Xray JSON subscriptions are imported, and an IPv6
  WireGuard endpoint is written with brackets.

## [1.11.1]

### Fixed

- A routing rule with a port range no longer stops sing-box from starting.
  Ranges such as `1000-2000` were handed to the core as written, and sing-box
  only accepts `1000:2000`; they are now written in that form, and `1000:2000`
  is accepted as input too. Ports outside 1–65535, reversed ranges and entries
  that are not numbers are dropped from the rule instead of reaching the core.

## [1.11.0] — 2026-10-11

### Fixed

- Reopening the window from the menu bar no longer tears down a running TUN
  connection. The start-up work — crash cleanup, auto-connect, login-item
  registration — ran again on every reopen, and the crash cleanup stopped the
  live core while the app went on showing "Connected".
- The window no longer redraws its whole server list once a second while
  connected. The uptime clock is drawn by the system from the connection's
  start time; the app timer that drove it is gone.
- In TUN mode the helper reads only the last 32 KB of the core's log instead of
  the whole file, and the app asks for it only while the log pane is open. The
  log was fetched every two seconds for as long as the tunnel was up, window
  or no window.
- The helper's logs are capped at 4 MB while a tunnel runs, not only when it
  starts.
- Disconnecting, recovering after sleep and re-applying the system proxy no
  longer freeze the window: `networksetup` and the helper's XPC calls run on a
  serial queue off the main thread, in the order they were asked for.
- App Nap no longer throttles Veil and the cores it runs while a connection is
  up and the window is closed to the menu bar.
- Subscriptions, community lists and the update check are refreshed in the
  background while Veil sits in the menu bar, not only at launch.
- The temporary core configuration, which holds the node's credentials, is
  written owner-only and removed when the core stops. Every server switch used
  to leave one behind in the temp folder.
- The log pane is an AppKit text view: new output is appended, a selection
  survives the next line, and it follows the end only when already there.

### Changed

- The Clash-compatible API (port 9090) is off by default. Its secret was random
  per launch and never shown, so nothing outside Veil could use it — it was a
  listening port for nothing. It stays on for anyone whose rules use
  `clash_mode`.
- Xray bridges open a SOCKS port only, not an unused HTTP one beside it.
- The control API binds 127.0.0.1 itself rather than the wildcard address
  restricted to the loopback interface.
- The connection health check runs once a minute instead of every 30 seconds,
  re-checking 10 seconds after a miss, so a dead link is still caught in about
  70 seconds.
- Helper protocol version 7: reinstall the helper after updating.

## [1.10.0] — 2026-09-22

### Added

- A "Hide the Dock icon" setting under Settings › General › Window. Veil then
  runs from the menu bar alone — no Dock tile, no ⌘-Tab entry — and keeps
  running when the window is closed, whatever close-to-tray says, since the
  menu bar item is the only way back to it. The switch takes effect at once,
  without a relaunch.

### Fixed

- Credentials in a share link are percent-decoded once, not twice. A password
  containing `%40` arrived as one containing `@`, and one ending in a bare `%`
  decoded to nothing and was dropped — in both cases the node authenticated as
  somebody else, or not at all. Applies to VLESS, Trojan, Hysteria2, TUIC,
  AnyTLS and WireGuard.
- The builder percent-encodes `:` and `@` inside a credential itself. Leaving
  that to `URLComponents` produced a link that split in a different place on
  macOS 26 than on 15, so an exported password containing either delimiter came
  back truncated.
- A Hysteria2 link that carries its auth string in the query — `auth`,
  `auth_str`, `auth-str` or `password` — is read instead of being treated as a
  node with no password.
- A node with no credential is named as such when it is checked, instead of
  being handed to the core. A Hysteria2 server answers an empty password with
  its masquerade page, which sing-box reports as "authentication failed, status
  code: 404" — a message about the far end for a link that never carried a
  password.

## [1.9.0] — 2026-09-20

### Added

- WireGuard nodes keep their own `AllowedIPs`. The config editor wrote
  `0.0.0.0/0, ::/0` over whatever the peer was handed out with, so a peer that
  only reaches one private network became a full tunnel every time its config
  was opened. The list is parsed from a `wg-quick` paste, a `wireguard://`
  link and an outbound JSON block, shown as it stands, and passed to the core.

### Fixed

- A rule that names its own addresses or domains now outranks the preset's LAN
  bypass. The bypass exists so that a rule about an *application* does not drag
  that application's LAN traffic through the tunnel; it was also outranking
  "send 172.16.4.10 through this peer", which is a sentence about the LAN and
  nothing else, and which therefore did nothing at all.
- The TUN interface no longer routes around a private range a rule claims.
  `route_exclude_address` kept those packets off the tunnel entirely, so the
  core was never asked where they should go. The covering block opens up when a
  rule sends part of it somewhere other than direct; the rest of the block
  still goes straight out.
- A WireGuard endpoint pasted or shown as outbound JSON is read back. The
  1.11+ shape states the remote in its peer rather than at the top level, so
  the editor refused its own output.
- "Changes apply on the next connect or reconnect" is shown only when the
  routing actually differs from what the running core was started with, not
  whenever the panes are opened while connected.

## [1.8.0] — 2026-09-19

### Added

- A Sources page, the second mode of the main window. It lists every source
  behind the server list and, for each one, what the last fetch actually
  returned: the format recognised, how many servers and panel-declared groups
  came out of it, when it ran, and the traffic and expiry the panel reports.
  The subscription URL is never drawn — its path is the access token — so it
  stays in the Keychain, with a "Copy subscription link" command for when it
  is needed.
- Sources now say what they could not use. Entries a body carries that Veil
  cannot connect to — an outbound type it has no support for, a share link
  with an unknown scheme, a Mihomo YAML body — were dropped in silence, which
  is why a WireGuard peer could simply fail to appear. Each one is now counted
  by reason and shown on the Sources page.
- Any server can be read as its own configuration: the `wg-quick` file for a
  WireGuard peer, the outbound JSON its core will run, or the share link. A
  server Veil owns can be edited in that form, and "Check" runs the text past
  the core that will execute it — `sing-box check` or `xray run -test` — so a
  typo is named where it is typed. A subscription's server is read-only, with
  "Duplicate and edit" to take a copy into Manual.
- Tags, renaming, pinning and hiding for individual servers. These are yours,
  kept separately from what the panel sends, and they survive a refresh.
- The list can be grouped by subscription, by tag or by country, or left flat,
  and filtered by tag, by country and by search. Servers can be dragged into
  whatever order suits, with "Reset manual order" to go back.
- Subscriptions can be pinned and reordered, so the list opens on the one in
  use.
- Automatic groups. A group can state what it wants — this source, that
  country, that tag, that protocol, that fragment of a name — instead of
  naming its members, and the answer is worked out again whenever the list
  changes. A group over a subscription of fifty nodes stays right when the
  provider adds the fifty-first; a hand-picked one never did. "Fastest of
  everything" builds the group most people want in one click, and a source's
  own menu offers the same over just that source.
- Your own groups now appear in the server list, at the top, and can be
  connected to like any server. They were configurable but unreachable
  outside the routing rules, and there was nowhere to delete one; a group's
  own row now offers that, and opening the editor from it lands on the groups.
- A preset says what it actually installs: the rules it puts before your own
  and the ones it puts after, each with its target and its matchers.
- Settings are one window with a sidebar. Routing used to be a second window
  of its own, reached by a button inside a settings tab whose only content was
  that button; its five pages are now panes in the same list, each with an
  icon, and the Routing menu command opens them directly.
- Settings that are not self-explanatory carry an "i" beside their name, with
  the explanation a click away instead of a paragraph under every row: what
  each tunnel mode really routes, what the TUN stack setting can break, what
  the ports and the log level are for, what auto-updating sources does, and
  what blocking ads and trackers matches.
- Tags read out of a server's own name — the country, the protocol, a
  provider's own words like Premium or Trial — with a switch in Settings →
  General. Off by default: they are guesses about someone else's naming, and
  the country chips follow the same switch.
- The Sources tab can be hidden once subscriptions are set up.
- The log pane can be dragged to whatever height suits and remembers it, and
  it can be narrowed: a search box, a severity floor that understands both
  cores' spellings, and a count of how much is on screen against how much the
  core wrote. Copy takes what is shown rather than everything.
- The control API reaches the rest of the app. It can now list the sources and
  what each fetch skipped, refresh them, read and write the labels, pins and
  renames on individual nodes, read the redacted log and diagnostics, and push
  an edit into a connection that is already up. Subscription URLs and the
  device identifier remain out of reach by design, and `docs/agents.md` is the
  written contract for whoever is driving it.

### Changed

- A refresh keeps the identity of servers that are still there. Every fetch
  used to mint new ids, which silently broke group membership, routing rules
  naming a server, and the record of which server was last selected. Servers
  are now matched on address, port, protocol and key, falling back to name.

### Fixed

- The control API no longer escapes the slashes in every path it prints, which
  made the schema it hands an assistant read as `GET \/v1\/state`.
- A rule that sends a domain through a particular server or group now works
  in System Proxy mode. Turning the native sing-box inbound off — a TUN
  setting — also dropped that mode onto the single-server path, where there is
  one proxy outbound and every node- and group-specific target silently
  collapses onto it. System Proxy has no tunnel interface to own, so it now
  always builds the full profile. Where the collapse is still real, in TUN
  mode with the native inbound off, the rules editor says so instead of
  looking configured.
- Groups a panel declared can be named by a rule. The target picker only
  offered your own groups, although the profile has always been able to build
  a panel's.
- A routing rule naming a group with no members no longer breaks the profile.
  The group produces no outbound, so the rule named a tag the core had never
  heard of and sing-box refused to start. Such a rule now falls back to the
  default proxy, which is what it asked for.
- The update download now reports how far it has got. The progress bar was
  wired to `URLSession`'s task-specific delegate, which never delivers the
  byte counts for an async download, so it read `Zero KB of 73.7 MB` for the
  whole transfer and then jumped to the end. It now shows bytes, speed and
  time remaining as the file arrives.
- An update that cannot be installed says so instead of quitting. Veil
  replaces the bundle it is running from, and when that bundle is read-only —
  a copy macOS made because it was launched from a quarantined archive, or a
  folder the account cannot write to — the swap was impossible and the app
  simply closed. Both cases are now checked before anything is unpacked, and
  the window explains what to move where.
- An install that fails after Veil has quit is reported on the next launch.
  The swap runs from a detached script, which used to abort silently at the
  first error; it now rolls back to the working version, verifies the version
  it installed, and writes what happened to `~/Library/Logs/Veil/update.log`.

## [1.7.0] — 2026-09-19

### Added

- Balancer groups a panel declares are now used as declared. A subscription
  that answers with a sing-box or Xray config states its grouping outright —
  a `urltest` or `selector` outbound, a `routing.balancers` entry — and Veil
  reads that instead of re-deriving one from the node names. Each group shows
  up in the list as a single entry you can connect to, with its members
  underneath.
- An Intel build, `Veil-x86_64.app.zip`. Releases used to ship only the Apple
  Silicon archive, which Intel Macs refuse to open with "this application is
  not supported on this Mac". The updater now fetches the archive matching the
  Mac it runs on.
- `CONTRIBUTING.md`, a Contributor Covenant `CODE_OF_CONDUCT.md`, and a
  `CLAUDE.md` recording the rules that are easy to get wrong — the helper's
  cdhash pin, the TUN stack, the localization table, the build SDK.

### Changed

- The name heuristic that merges `NL - 1` and `NL - 2` into one balancer now
  runs only for subscriptions that are a list of share links. Those carry no
  grouping at all, so a guess is all there is; a config document does carry
  one, and guessing over it replaced the provider's intent with whatever their
  node names happened to look like.
- Veil is now licensed under the **GNU Affero General Public License v3.0**
  instead of MIT. The bundled cores keep their own licences and nothing in the
  app is paywalled; the change only requires that anyone who distributes a
  modified Veil, or runs one over a network, offers the source for it.
- The README is rewritten around what Veil actually does, with the protocol
  matrix, the two tunnel modes and the security model up front, and a Russian
  translation in `README.ru.md`.

### Removed

- `docs/PLAN.md`. The roadmap had outlived the work it described; the
  CHANGELOG and the issue tracker say what is done and what is next.

## [1.6.3] — 2026-09-19

### Fixed

- The Device ID on screen did not change when it was regenerated. The row read
  the identifier from a static store SwiftUI does not observe, so the new value
  only appeared once something unrelated redrew the row — pressing Copy, for
  instance, which is how it looked like copying was what rotated it.
- Veil no longer goes quiet after it updates itself. The helper pins its client
  by code hash and every build has a different one, so an installed update left
  a helper that refuses the app and a TUN mode that cannot start. The main
  window now says so and offers the reinstall, instead of leaving it to be
  found in Settings.

### Added

- The Device ID can be set by hand, for providers that issue one of their own.
  It is stored exactly as typed rather than folded into Veil's own format.

### Changed

- The subscription check interval is a list of useful intervals — hourly up to
  weekly — rather than a stepper that moved one hour at a time between 1 and
  168. An interval an earlier build stored stays selectable. The row is hidden
  altogether while auto-update is off, since it governs nothing then.

## [1.6.2] — 2026-09-19

### Fixed

- TUN mode carried no TCP traffic at all on a default install. The tunnel's
  network stack was left for the core to choose, and sing-box 1.14 — the
  version pinned in `Scripts/cores.lock` — chooses `mixed`, a gVisor UDP stack
  over a system TCP stack whose macOS half never answers a SYN. Pings were
  replied to, DNS resolved through the tunnel and the core logged nothing, so
  everything read as connected while every connection hung until it timed out.
  The tunnel now asks for `gvisor`, which handles both halves. Picking a stack
  by hand in Settings still overrides it.

## [1.6.1] — 2026-09-19

### Fixed

- Nodes that need the Xray bridge — XHTTP, mKCP, VLESS with post-quantum
  encryption — connected and then carried nothing, in both System Proxy and TUN
  mode. The bridge was built with Xray's `mux.cool` multiplexing switched on,
  which the servers these subscriptions come from do not accept: the handshake
  succeeded, the request went out addressed to `v1.mux.cool`, and every stream
  died with `failed to read metadata`. At the default log level none of that was
  printed, so the tunnel looked healthy while moving zero bytes. No outbound
  enables mux any more, which is also Xray's own default.
- The DNS catch-all can no longer be the bootstrap resolver. That entry is
  pinned to `direct` so a node's hostname can be resolved before the tunnel
  exists; selecting it as "Answer with" sent every lookup out in the clear, to
  the resolver the tunnel was turned on to get away from. It is now left out of
  the picker and corrected on the way to the core.
- TUN mode could report "tunnel up" over a tunnel that was already dead. The
  helper treated the appearance of a `utun` device as success, but sing-box
  creates the interface before it installs the routes that make it useful, so a
  core that failed on `auto_route` was still alive at that instant. The device
  now starts a grace period instead of ending the check.

### Changed

- The routing core's log now reaches the app's log window in TUN mode. It runs
  as root there and writes to a file the app cannot open, so the window used to
  show only the Xray bridge — a core that came up and then misbehaved left no
  trace at all. Terminal colour codes are stripped on the way in, in both modes.

## [1.6.0] — 2026-09-18

### Added

- In-app updates. Veil checks its GitHub releases, shows what changed, downloads
  the new build with a real byte counter and a Cancel button, and swaps the
  bundle on the next launch. A check the user asks for answers with a standard
  system alert when there is nothing to install, with a Version History button
  next to OK.
- An About window with the version, the build and the links people actually
  follow.
- Community rule lists: curated domain and IP lists that can be switched on in
  Routing and pointed at proxy, direct or block. The lists are cached on disk
  and refreshed on demand; only the chosen ids are stored in settings.
- Settings and Routing are windows of their own — ⌘, opens Settings — with the
  section switcher in the title bar instead of a tab strip below it.

### Changed

- The interface was rebuilt on native macOS components throughout: the groups
  editor no longer shows a checklist of every server that exists, the
  application picker has search, scopes and real checkboxes, and the DNS editor
  lays its fields out as labelled rows instead of stretched text fields.
- Release builds are stamped with the SDK they were built against, so the app
  renders in the current macOS style rather than the legacy one.
- All secrets now live in a single keychain item. Veil is signed ad hoc, so its
  code hash changes with every build and macOS asks for authorisation again —
  one item means one dialog instead of one per subscription per launch.
- The device identifier is 16 hexadecimal characters instead of a full UUID.
  Existing installs keep a stable prefix of the identifier they already had.
- The User-Agent carries only the client name and version. The device facts stay
  in the `X-Device-*` headers, which only the panel reads.
- Connecting and switching servers is faster: the SOCKS port is polled every
  25 ms instead of waiting out a fixed delay, the system proxy is configured off
  the main actor, and the primary network service is cached for 15 seconds and
  re-resolved when the network changes.
- Plans with no traffic cap are shown as unlimited instead of "Zero KB".

### Fixed

- The Xray access log no longer goes to standard output. A busy connection could
  produce thousands of lines a second, which flooded the log view and could take
  the app down with it; core output is now buffered and capped as well.
- Stopping a core waits for the process to exit, so the replacement can bind the
  SOCKS port instead of failing and being retried by the watchdog.
- The empty state in Groups is centred in the window.
- `Scripts/run-app.sh` quits the running copy before relaunching, instead of
  activating the old process and appearing to do nothing.

## [1.5.1] — 2026-09-18

### Fixed

- The tunnel no longer fails to start with "detour to an empty direct outbound
  makes no sense" when the DNS bootstrap resolver is set to `direct`. The
  `direct` detour is now omitted, matching sing-box 1.12+ semantics.

## [1.5.0] — 2026-09-18

### Added

- Rules can name a server or a group, not just "the proxy", so two applications
  can leave the machine through two different servers at once.
- Application rules: pick the app from a searchable list of what is installed
  and what is running. The list shows the executable name, which is what the
  core matches and rarely what is on the icon.
- Server groups — manual, or fastest-wins — that a rule can point at.
- A DNS editor: typed resolvers, per-resolver detours, DNS rules and FakeIP.
- A local control API on 127.0.0.1, off by default, for configuring Veil from
  outside it: rules, groups, resolver, preset, connect. Settings hands over a
  briefing to paste into an assistant.
- Settings for the native TUN inbound: strict route and the network stack.

### Changed

- The separate Subscription and Add Link buttons are now one Add button. It
  accepts a subscription URL, share links, a base64 subscription body, a
  wg-quick profile or a QR code, says what it detected while you type, and
  adds or fetches accordingly.
- sing-box owns the TUN interface, which is what makes application matching
  possible. tun2socks remains as a fallback.
- Your own rules now apply under every preset instead of only "Custom". They
  run after the LAN bypass and before the preset's country rules.
- `geosite:` and `geoip:` entries are no longer dropped from sing-box configs;
  they become rule-sets, which is what sing-box has wanted since 1.12.

The helper protocol is version 5, so **the helper has to be reinstalled** —
Settings → TUN Helper → Install. The app refuses to drive the 1.4.x helper
rather than starting a tunnel it knows is broken.

## [1.4.1] — 2026-09-14

### Fixed

- TUN mode failed to start with `utun123 did not come up`. The bundled
  tun2socks 2.7 parses POSIX-style flags, so the helper's `-device` was read as
  the shorthand `-d` with the value `evice`: tun2socks printed its usage and
  exited without ever creating the interface. The long flags now carry two
  dashes, and the argument list moved into `VeilHelperKit` with a test that
  pins the spelling — a flag this binary cannot parse is silent otherwise.
- The helper no longer waits out the full five seconds when tun2socks has
  already exited, and it reports the last line tun2socks logged instead of only
  saying the interface never appeared.

The helper protocol is version 4, so **the helper has to be reinstalled** —
Settings → TUN Helper → Install. The app refuses to talk to the 1.4.0 helper
rather than driving a tunnel it knows is broken.

## [1.4.0] — 2026-09-14

Phase 0 of `docs/PLAN.md`: the security work that had to land before anything
else was worth shipping. **Everyone upgrading from 1.3.x has to reinstall the
TUN helper once** — Settings → TUN Helper → Install. The old install put a
`NOPASSWD` rule in `/etc/sudoers.d`; the new installer removes it.

### Changed — the privileged helper

- TUN mode no longer runs root shell scripts. `install-helper.sh`, `tun-up.sh`,
  `tun-down.sh` and `tun-ping.sh` are gone, and so is the `NOPASSWD` sudoers
  rule they relied on. In their place is a launchd daemon (`Sources/VeilHelper`)
  that speaks a typed XPC protocol: start and stop the tunnel, pin server
  addresses, add and remove probe routes. No argument names a binary, a path or
  a command, and every address and port is validated again on the root side.
- Tunnel state moved out of `/tmp/xrayclient-*`, where any process could read it
  or pre-create it, into a root-owned `0600` file. The daemon replays that file
  on startup, so a crash can no longer leave the machine without a default
  route.
- The daemon accepts connections only from the app binary pinned at install
  time, and refuses every client when the pinned requirement is missing. Veil
  is ad-hoc signed — there is no paid Apple membership behind it — so the pin is
  a `cdhash` and the helper has to be reinstalled after the app is updated.

### Changed — secrets

- Subscription URLs (whose path is the access token) and device identifiers now
  live in the Keychain. `store.json` keeps only a marker, and is written `0600`
  inside a `0700` directory. If the Keychain is unavailable the URL stays in the
  file rather than being lost.
- The subscription fetch no longer logs the URL, the HWID or the token.
- Settings gained an **Export diagnostics** button that redacts credentials
  before it copies, so a report can be pasted into an issue unread.

### Changed — device identifier

- The HWID was the machine's `IOPlatformUUID`: stable across reinstalls and
  identical for every provider. New installs now mint a random identifier, one
  per subscription, rotatable from Settings.
- Installs that already talked to a panel carry their current identifier
  forward. Rotating silently would look like a new device and could trip
  `x-hwid-max-devices-reached` — that is, disconnect someone mid-use.

### Changed — Remnawave

- The whole response-header contract is parsed instead of three headers:
  `x-hwid-active`, `x-hwid-not-supported`, `x-hwid-max-devices-reached`,
  `subscription-userinfo`, `profile-title`, `profile-update-interval`,
  `announce`, `support-url`, `profile-web-page-url` and
  `subscription-refill-date`.
- The HWID goes in `X-Hwid` and nowhere else. It used to travel in two query
  parameters, two headers and the User-Agent — the last of which showed it to
  every proxy on the path. The User-Agent is now overridable per subscription.
- The response body is classified — `XRAY_JSON`, `XRAY_BASE64`, `SINGBOX`,
  Mihomo YAML, plain share links — and kept verbatim instead of being flattened
  into a node list.

### Changed — supply chain

- `Scripts/cores.lock` pins each bundled core's version and SHA-256, and the
  fetch scripts abort on a mismatch: Xray-core 26.3.27, sing-box 1.14.0,
  tun2socks 2.7.0 (arm64).
- Geo databases are staged, checked for size and content, and swapped in as a
  pair, with the previous pair kept for rollback. Routing with one new and one
  old database is worse than not updating at all.

### Fixed

- A fresh install adopted the machine's `IOPlatformUUID` as its HWID, because
  the legacy-identifier reader on macOS always succeeds. It is now consulted
  only when an earlier install actually left a store behind.
- Installing the helper from Settings ran the admin prompt and an XPC round trip
  on the main thread and discarded the error, so a cancelled password prompt
  looked like a button that does nothing. Both run off the main thread now, the
  row shows progress, and failures are shown.

[1.9.0]: https://github.com/faustyu1/veil/releases/tag/v1.9.0
[1.4.1]: https://github.com/faustyu1/veil/releases/tag/v1.4.1
[1.4.0]: https://github.com/faustyu1/veil/releases/tag/v1.4.0
