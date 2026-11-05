# Veil for agents

Veil is an MCP server. An assistant can read how traffic is routed and change
it through the tools below. This page is the contract they keep; `tools/list`
is the machine-readable half, this is the half that explains what the words
mean.

## Reaching it

Add Veil to any MCP client (Claude, Cursor, …). Settings → Advanced → **Copy
MCP config** gives the snippet with the right path:

```json
{
  "mcpServers": {
    "veil": {
      "command": "/Applications/Veil.app/Contents/MacOS/Veil",
      "args": ["mcp"]
    }
  }
}
```

`Veil mcp` speaks JSON-RPC on stdin/stdout. It is not a second copy of the
app: it forwards each call to the running Veil over a Unix socket at
`~/Library/Application Support/XrayClient/mcp.sock`, and starts Veil in the
background if it is not running. The socket is `0600` inside a `0700`
directory and refuses peers running as another user, so there is no token —
the user account is the boundary.

**No AI** (Settings → Advanced) turns all of this off. Veil removes the socket,
and every tool call answers with an error that says No AI is on.

## What the tools will never tell you

- **Subscription URLs.** The path of one *is* the access token for a provider's
  panel. `list_sources` says that a URL is stored, never what it is.
- **The device identifier.** It is sent to panels as `X-Hwid` and nowhere else.
- **Unredacted logs.** `get_logs` and `get_diagnostics` run everything through
  the same redaction the Export diagnostics button uses.

The tools also cannot add a server or a subscription. Routing is what it is for,
and an interface that cannot read a secret cannot leak one.

## The model

```
sources  →  nodes  →  groups  →  rules  →  the profile a core runs
```

- A **source** is a subscription or the servers added by hand. `list_sources`
  reports how many nodes each produced and what the last fetch had to skip —
  that is the answer to "the provider lists a server I cannot see".
- A **node** is one server. `list_servers` gives its id and the `tag` a rule
  uses to name it. What the *user* attached to it — labels, a pin, a rename, a
  hide — lives separately in `get_node_annotations`, keyed by node id.
- A **group** behaves like one outbound: a selector the user picks from, or a
  urltest that takes the quickest member. A group with a `query` is automatic:
  it states what it wants (source, country, tag, protocol, name fragment) and
  is answered again whenever the list changes, so new nodes join it by
  themselves. `memberIDs` on such a group is the last answer, not an input.
- A **rule** matches traffic and names a target. Rules are ordered and the
  first match wins.
- The **profile** is what a core is actually given. `render_config` renders it
  from the current settings without connecting, which is the cheapest way to
  check an edit.

### Rule targets

| Target | Meaning |
| --- | --- |
| `proxy` | the server that is connected |
| `direct` | out of the tunnel, straight to the network |
| `block` | refused |
| `server:<uuid>` | that specific node |
| `group:<uuid>` | that group's current choice |

`server:` and `group:` need the full profile, which Veil builds in System Proxy
mode and in TUN mode with the native core. In TUN mode with the native inbound
switched off there is one proxy outbound and those targets collapse onto it.
`get_state` reports `nativeCore`; the editor in the app says so too rather
than looking configured.

### Matching an application

`processNames` matches the **executable**, not the name on the icon — Visual
Studio Code is `Electron`. Look it up with `find_apps` with `q: "code"`. Application
rules are enforced only when the core owns the interface: check
`processRoutingAvailable` in `get_state` before writing one.

## Tools

| Tool | What it does | Control endpoint |
| --- | --- | --- |
| `get_state` | connection, mode, counts, what can be enforced | `GET /v1/state` |
| `list_servers` | nodes with the tag a rule names them by | `GET /v1/servers` |
| `list_sources` | where nodes came from, and what a fetch skipped | `GET /v1/sources` |
| `refresh_sources` | re-download every source | `POST /v1/sources/refresh` |
| `get_node_annotations` / `set_node_annotations` | the user's labels, pins, hides and renames | `GET`/`PUT /v1/nodes` |
| `find_apps` (`q`, `limit`) | applications, with executable names | `GET /v1/apps` |
| `get_rules` / `set_rules` (`rules`) | the ordered rules | `GET`/`PUT /v1/rules` |
| `get_groups` / `set_groups` (`groups`) | groups, including automatic ones | `GET`/`PUT /v1/groups` |
| `get_dns` / `set_dns` (`dns`) | resolver settings | `GET`/`PUT /v1/dns` |
| `get_preset` / `set_preset` (`preset`) | the preset, and the ones available | `GET`/`PUT /v1/preset` |
| `render_config` | the profile the current settings would produce | `GET /v1/config` |
| `get_logs` (`limit`, `level`, `q`) | the tail of the core's log, redacted | `GET /v1/logs` |
| `get_diagnostics` | the redacted diagnostics report | `GET /v1/diagnostics` |
| `apply` | push the current settings into a live connection | `POST /v1/apply` |
| `connect` (`serverID`) | connect to a node | `POST /v1/connect` |
| `disconnect` | stop the tunnel | `POST /v1/disconnect` |

Every `set_*` replaces the whole collection. Read, edit the array you were
given, put it back — there is no partial update, and inventing one would race
with the user editing the same list in the window.

## Recipes

**Send one application through a specific node.**

1. `find_apps` with `q: "slack"` → `processName`.
2. `list_servers` → the node's uuid.
3. `get_rules`, append the rule keeping the order, `set_rules` with the array.
4. `apply`, or it waits for the next connect.

A rule looks like this:

```json
{"name": "Work", "target": "server:3B1F…", "processNames": ["Slack"],
 "enabled": true}
```

**Explain a server the user cannot find.** `list_sources`: the `skipped` notes
say what the last fetch dropped and why — an outbound type this build does not
speak, a link scheme it does not parse.

**Say why a domain is still going direct.** `get_rules` (first match wins),
`render_config` (look at `route.rules`, what the core was given), then
`get_logs` with `level: "warning"`.

## Errors

A tool that fails returns `isError: true` with the reason as text: a body that
could not be read, a value that does not exist, no server with that id, a
profile that could not be rendered, No AI switched on, or Veil not running. A
rejected write changes nothing.

## Behaviour to rely on

- Writes are saved immediately and reach a **running** connection only on the
  next connect or on `apply`. `render_config` always reflects the
  settings, connected or not.
- A rule naming a group that currently matches nothing is not an error: the
  profile falls back to the default outbound rather than refusing to start.
- Ordering is meaningful everywhere it exists — rules, and a group's members.
  Preserve it when you write a collection back.
