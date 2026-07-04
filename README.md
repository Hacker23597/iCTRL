# iCTRL

**AI-friendly iOS automation service, built on XCUITest.**

iCTRL turns an iPhone into a controllable automation endpoint. It runs a
long-lived XCUITest runner that exposes a **JSON-RPC 2.0 API over HTTP** (default
port `8200`), so an AI agent — or any HTTP client — can drive the device: tap,
swipe, type, read the UI tree, take screenshots, launch apps, open URLs, and more.

Unlike a raw XCUITest script, iCTRL is designed to be **discovered and driven by a
model**: the server's home page and `config`/schema responses document every
method with progressive disclosure, so an agent can learn the API at runtime and
call it correctly without prior knowledge.

- **Bundle ID:** `com.openminis.ictrl`
- **Transport:** JSON-RPC 2.0 over HTTP, port `8200`
- **Auth:** bearer token, granted on-device via a notification prompt
- **Shipped as two IPAs:** `iCTRL.ipa` (host app) + `iCTRLUITests-Runner.ipa`
  (the automation engine — this is the one that must be running)

## How it works

iCTRL is a UITest target that never stops. On launch it starts an `NWListener`
HTTP server and holds the run loop open (WebDriverAgent-style: block on
`distantFuture`, near-zero idle CPU). Every RPC maps to an XCUITest action
executed against the foreground app or a bound target app.

```
AI agent / curl ──HTTP JSON-RPC──▶ iCTRL runner (XCUITest) ──▶ iOS UI
```

Interactions are synthesized with `XCSynthesizedEventRecord` / `XCPointerEventPath`
(bypasses quiescence waits), with small (±few pt) coordinate jitter within an
element's visible bounds to look less mechanical.

## Quick start

1. Build & install both IPAs (see **Building**), then launch the **runner**.
2. Approve the connection when the on-device notification appears — you get a
   bearer token.
3. Call the API:

```bash
# Discover the API
curl http://<device-ip>:8200/

# Authorize
curl -X POST http://<device-ip>:8200/auth -d '{"client_name":"my-agent"}'

# Act (with the granted token)
curl -X POST http://<device-ip>:8200/rpc \
  -H "Authorization: Bearer <token>" \
  -d '{"jsonrpc":"2.0","method":"screenshot","params":{"scale":1},"id":1}'
```

## API surface

All methods are JSON-RPC 2.0 (`POST /rpc`). Highlights:

| Group | Methods |
|---|---|
| **Touch** | `tap`, `double_tap`, `long_press`, `tap_element`, `swipe`, `scroll`, `scroll_to_element`, `drag`, `page` |
| **Text** | `type` (with `submit` to fire Return) |
| **Read** | `screenshot`, `page_source`, `find_element` |
| **Apps** | `launch_app`, `activate_app`, `terminate_app`, `list_apps`, `resolve_app`, `open_url` |
| **Device** | `device_info`, `home`, `lock`, `unlock`, `is_locked`, `wait` |
| **Server** | `config` (settings, sessions, `stop_server`) |

- **`resolve_app`** — resolve an app name/keyword to a bundle ID via a built-in
  catalog, falling back to the iTunes Search API.
- **App binding** — `launch_app` binds subsequent interactions to that app;
  interaction methods re-foreground the bound app, while read-only methods
  (`screenshot`/`page_source`) act on the current foreground to avoid
  activation-induced stalls.
- **`config { stop_server: true }`** — shut the service down remotely; tokens
  persist so relaunching needs no re-auth.

The endpoints `GET /`, `GET /logs`, `GET /logs/files`, and `GET /logs/history?date=`
expose docs and (redacted) persisted daily logs for diagnostics.

## Auth & sessions

- Tokens are UUIDs granted on-device (notification prompt), stored in a sandbox
  file (`Library/Application Support/iCTRL/`), not the Keychain — so OTA
  re-signing doesn't invalidate them.
- Sessions expire after 30 days of inactivity; the store is capped at 100
  (least-recently-active dropped first).

## Building

Uses `xcodegen` (`project.yml` → `.xcodeproj`) + `xcodebuild build-for-testing`.

```bash
make ipa   # builds iCTRL.ipa and iCTRLUITests-Runner.ipa
```

## Project layout

```
iCTRLApp/        SwiftUI host app (status, sessions, settings)
iCTRLKit/        Shared lib: JSONRPCServer, AuthManager, RPCMethod/registry, token store
iCTRLUITests/    The automation engine: test entry + run loop, ActionHandler,
                 ForegroundApp / LockStateMonitor / EarlyURLHook (private APIs)
project.yml      xcodegen spec
Makefile         build + package
```

## Notes & limitations

- Requires the runner test process to be running; a first-launch-while-locked
  path is handled (setUp does not `activate()` behind the passcode screen, plus
  a bootstrap watchdog re-kicks the test if the passcode prompt interrupted it).
- Uses several private XCTest/`LSApplicationWorkspace` APIs — **not** App Store
  safe; intended for development/automation on your own devices.
- UI reads go through the accessibility tree; synthesized input is
  indistinguishable from real touches, but this offers no guarantee against
  app-side anti-automation heuristics.
