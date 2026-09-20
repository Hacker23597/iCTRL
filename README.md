# iCTRL

**AI-friendly iOS automation service, built on XCUITest.**

iCTRL turns an iPhone into a controllable automation endpoint. It runs a
long-lived XCUITest runner that exposes a **JSON-RPC 2.0 API over HTTP** (default
port `8200`), so an AI agent — or any HTTP client — can drive the device: tap,
swipe, type, read the UI tree, take screenshots, launch apps, open URLs, and more.

Unlike a raw XCUITest script, iCTRL is designed to be **discovered and driven by a
model**: `GET /skill` serves a complete operating manual and `GET /schema`
documents every method with its parameters, so an agent can learn the API at
runtime and call it correctly without prior knowledge.

- **Bundle ID:** `com.openminis.ictrl`
- **Transport:** JSON-RPC 2.0 over HTTP, port `8200`
- **Auth:** encrypted envelope (X25519 pairing → HMAC-SHA256 sealed requests)
- **Shipped as two IPAs:** `iCTRL.ipa` (host app) + `iCTRLUITests-Runner.ipa`
  (the automation engine — **this is the one that must be running**)

## How it works

iCTRL is a UITest target that never stops. On launch it starts an `NWListener`
HTTP server and holds the run loop open (WebDriverAgent-style: block on
`distantFuture`, near-zero idle CPU). Every RPC maps to an XCUITest action
executed against the foreground app or a bound target app.

```
AI agent / curl ──HTTP JSON-RPC──▶ iCTRL runner (XCUITest) ──▶ iOS UI
```

Interactions are synthesized with `XCSynthesizedEventRecord` / `XCPointerEventPath`,
which bypasses XCUITest's quiescence waits.

---

# Installation

The runner is an XCUITest bundle, which makes it harder to install than an
ordinary app: the `.xctest` inside it must carry its own valid signature, and
its bundle identifier must match the host runner app. Pick the path that matches
the Apple account you have.

| You have | Use |
|---|---|
| Free Apple ID | [SideStore](#a-free-apple-id--sidestore-via-iloader) (7-day certs, re-sign weekly) |
| Paid Developer account ($99/yr) | [Manual signing](#b-paid-developer-account--sign-the-ipa-yourself) or [Xcode](#c-paid-developer-account--run-straight-from-xcode) |

## A. Free Apple ID — SideStore (via iLoader)

A free account can only issue 7-day certificates, so the app must be re-signed
every week. SideStore automates that; iLoader is the easiest way to get
SideStore itself onto the device.

**1. Install SideStore using iLoader**

Download [iLoader](https://github.com/nab138/iLoader) for your desktop OS, then:

- Connect the iPhone over USB and trust the computer.
- In iLoader, sign in with your Apple ID and install **SideStore**.
- On the device: **Settings → General → VPN & Device Management** → trust your
  developer certificate.

**2. Enable the SideStore pairing file**

SideStore needs a pairing file to refresh certificates without a computer.
Follow SideStore's own setup for this — it is a one-time step.

**3. Install the runner with SideStore**

- Get `iCTRLUITests-Runner.ipa` (from Releases, or build it — see
  [Building](#building)).
- Open SideStore → **+** → choose the IPA → install.
- Optionally install `iCTRL.ipa` the same way for the settings UI.

**4. Launch it**

Tap **iCTRLUITests-Runner** on the Home Screen. It starts the HTTP server and
keeps running in the background.

> **The 7-day limit is real.** Re-open SideStore and refresh before the
> certificate expires, or the runner stops launching. SideStore can refresh in
> the background once its pairing file is configured.

## B. Paid Developer account — sign the IPA yourself

With a paid account you get a 1-year certificate. The signing order matters
more than the tool: **an XCUITest runner has a nested `.xctest` bundle that needs
its own signature**, and many signing tools silently skip it — the app then
installs fine and fails at launch, because `testmanagerd` validates the plugin's
signature separately.

### The structure you are signing

```
iCTRLUITests-Runner.app/
├── iCTRLUITests-Runner          ← host binary
├── Frameworks/
│   └── libXCTCompatShim.dylib   ← must be signed, or dyld rejects it
└── PlugIns/
    └── iCTRLUITests.xctest/     ← sign this FIRST, and separately
        └── iCTRLUITests
```

Two rules that are easy to get wrong:

1. **Inside out.** Sign the dylibs, then the `.xctest`, then the outer `.app`.
   Signing the app first invalidates it as soon as you touch anything inside.
2. **The `.xctest` shares the host's bundle identifier** — it does *not* extend
   it the way a normal app extension does. Signers that assume the extension ID
   must be a strict prefix-extension of the host ID will reject or rewrite it.

`ldid` in particular **will not sign the `.xctest`**: it only recurses into
`.framework` and `.appex`. Use `codesign` (macOS) or
[`apple-codesign`](https://github.com/indygreg/apple-platform-rs) / `zsign`,
which detect bundles by the presence of `Info.plist`.

### Signing with `codesign`

```bash
IDENT="Apple Development: you@example.com (XXXXXXXXXX)"   # security find-identity -v -p codesigning
APP="Payload/iCTRLUITests-Runner.app"

unzip -q iCTRLUITests-Runner.ipa

# 1. Align the .xctest bundle id with the runner (must happen BEFORE signing,
#    so the edited plist is covered by the signature)
RUNNER_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $RUNNER_ID" \
  "$APP/PlugIns/iCTRLUITests.xctest/Info.plist"

# 2. Inside out
for dylib in "$APP/Frameworks/"*.dylib; do
  codesign --force --sign "$IDENT" "$dylib"
done
codesign --force --sign "$IDENT" "$APP/PlugIns/iCTRLUITests.xctest"
codesign --force --sign "$IDENT" --entitlements entitlements.plist "$APP"

# 3. Verify EVERY embedded binary — an unsigned dylib fails at launch with
#    "mapped file has no cdhash", which looks nothing like a signing problem
for f in "$APP/Frameworks/"*.dylib "$APP/PlugIns/iCTRLUITests.xctest" "$APP"; do
  codesign -v "$f" || echo "UNSIGNED: $f"
done

zip -qr iCTRLUITests-Runner-signed.ipa Payload
```

Minimum entitlements — `get-task-allow` is required for a test runner:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>application-identifier</key>
    <string>TEAMID.com.openminis.ictrl.uitests.xctrunner</string>
    <key>com.apple.developer.team-identifier</key>
    <string>TEAMID</string>
    <key>get-task-allow</key>
    <true/>
</dict>
</plist>
```

Then install with any of: Apple Configurator, `ideviceinstaller -i <ipa>`,
Xcode's **Devices and Simulators → Installed Apps → +**, or SideStore.

> `make ipa` already does all of the above using whatever identity Xcode picked
> for the build, so a local build needs no manual signing.

## C. Paid Developer account — run straight from Xcode

The simplest path if you have the source and a Mac.

```bash
brew install xcodegen
make ipa          # or: xcodegen generate && open iCTRL.xcodeproj
```

1. Open `iCTRL.xcodeproj`.
2. Select the **iCTRL** scheme and your device.
3. Set your team under **Signing & Capabilities** for *both* the `iCTRL` and
   `iCTRLUITests` targets.
4. **Product → Test** (⌘U).

Xcode builds, signs, installs and launches the runner. It keeps running after
the test session detaches, so you can quit Xcode and keep using the API.

> First run on a new device: **Settings → General → VPN & Device Management** →
> trust the certificate, and enable **Developer Mode** (iOS 16+) when prompted.

## After installing — verify it works

```bash
curl http://<device-ip>:8200/schema
```

A JSON document means the runner is up. If the connection is refused, the runner
is not running — launch it from the Home Screen.

---

## Quick start

Every `/rpc` body is an **encrypted envelope**; there is no plaintext path. Don't
hand-roll the crypto — download a client from the device itself:

```bash
# Fetch the reference client (unauthenticated)
curl -o ictrl_rpc.py http://<device-ip>:8200/skill/clients/python

# Pair once — tap Allow on the device (blocks up to 60s)
python3 ictrl_rpc.py --host <device-ip>:8200 pair

# Drive it
python3 ictrl_rpc.py --host <device-ip>:8200 call device_info
python3 ictrl_rpc.py --host <device-ip>:8200 call tap '{"x":100,"y":200}'
```

There is also a static aarch64-musl CLI at `/skill/clients/cli` for sandboxes
with no Python.

**`GET /skill`** returns the full operating manual in Markdown — point an agent
at it and it can drive the device without further documentation.

## API surface

All methods are JSON-RPC 2.0 (`POST /rpc`). Highlights:

| Group | Methods |
|---|---|
| **Touch** | `tap`, `double_tap`, `long_press`, `tap_element`, `find_and_tap`, `swipe`, `scroll`, `scroll_to_element`, `drag`, `page` |
| **Text** | `type` (with `submit`/`clear`), `clear_text` |
| **Read** | `screenshot`, `page_source`, `find_element`, `screen_text` (Vision OCR) |
| **Apps** | `launch_app`, `activate_app`, `terminate_app`, `list_apps`, `resolve_app`, `open_url` |
| **Device** | `device_info`, `home`, `lock`, `unlock`, `is_locked`, `wait` |
| **Server** | `config` (settings, sessions, `stop_server`), `reset`, `stream_ticket` |

Notable behaviour:

- **`page_source{visible_only, max_children}`** — on a recycling list (chat
  lists, feeds) the accessibility tree holds far more rows than are on screen.
  `visible_only:true` with `max_children:50` measured p50 416ms across 8 apps and
  returns only what is actually visible.
- **Automatic OCR fallback** — when the tree comes back with nothing on screen,
  the response also carries `ocr_items[]` read from a screenshot, in the same
  shape as `find_element` results.
- **App binding** — `launch_app` binds subsequent interactions to that app;
  read-only methods act on the current foreground to avoid activation stalls.
- **`config{stop_server:true}`** — shut the service down remotely; paired keys
  persist, so relaunching needs no re-pairing.

`GET /`, `GET /remote` (browser control page), `GET /stream` (live H.264),
`GET /logs`, and `GET /logs/history?date=` expose docs, a UI and redacted logs.

## Auth & sessions

`POST /pair` returns a 32-byte key `K` after the device user taps **Allow**:

- **Over USB/localhost** — `{"client_name":"…","plain":true}` returns `K`
  directly (accepted only from `127.0.0.1`).
- **Over the LAN** — send an X25519 public key and unwrap:
  `K = token_ct XOR HMAC(HMAC(X25519(c_priv,d_pub), "ictrl-pair"||c_pub||d_pub), "ictrl-wrap")`

Each request is then sealed with HMAC-SHA256 keys derived from `K` and a fresh
16-byte nonce; replays and clock skew beyond ±120s are rejected.

Keys live in a sandbox file (not the Keychain), so OTA re-signing doesn't
invalidate them. **A key is dropped after 30 days with no successful call** —
every request slides that window forward, so a key in regular use never expires.

### Version negotiation

`device_info` and `/schema` report `server_version` (semver), `protocol_version`
(int), `build` (compile timestamp — the only way to tell two builds apart when
the version wasn't bumped), and a `capabilities` array. Feature-detect against
`capabilities` rather than comparing versions.

## Building

Uses `xcodegen` (`project.yml` → `.xcodeproj`) + `xcodebuild build-for-testing`.

```bash
make ipa   # builds and signs iCTRL.ipa and iCTRLUITests-Runner.ipa
```

`make ipa` strips the XCTest frameworks the runner doesn't need, inserts a
compat shim for older iOS, aligns the `.xctest` bundle id, re-signs inside out,
and verifies every embedded binary is signed before packaging.

## Project layout

```
iCTRLApp/        SwiftUI host app (status, sessions, settings)
iCTRLKit/        Shared lib: JSONRPCServer, AuthManager, SecureEnvelope, RPC registry
iCTRLUITests/    The automation engine: test entry + run loop, ActionHandler,
                 ForegroundApp / LockStateMonitor / EarlyURLHook (private APIs)
iCTRLCompat/     Back-compat shim for older iOS XCTest
SKILL.md         The operating manual served at GET /skill
project.yml      xcodegen spec
Makefile         build + sign + package
```

## Notes & limitations

- The **runner** must be running — the host app alone does nothing.
- Uses several private XCTest / `LSApplicationWorkspace` APIs — **not** App Store
  safe; intended for automation on your own devices.
- `unlock` only wakes the screen. It cannot enter a passcode, and it is not a way
  to keep the screen awake; set Auto-Lock to Never for long unattended runs.
  Note that screen sleep does **not** stop the runner — read-only tasks still
  work with the display off.
- `list_apps` uses a private API that newer iOS versions may refuse, returning an
  empty list on a device full of apps. Use `launch_app` to test for an app.
- Synthesized input is indistinguishable from real touches at the system level,
  but that is no guarantee against app-side anti-automation heuristics — apps
  with bot detection may still challenge you.

## Credits & licensing

iCTRL is licensed under the **GNU Affero General Public License v3** (see
`LICENSE`). Note that §13 covers network use, not just distribution: anyone
interacting with an iCTRL server over a network is entitled to its source.

This project would not exist without the following work.

| Project | Used for | License |
|---|---|---|
| [jkcoxson/idevice](https://github.com/jkcoxson/idevice) | The Rust library doing all the real protocol work behind `iCTRLApp/DDI` — RSD tunnel, lockdownd, AFC, installation_proxy, image mounter. Fetched as an xcframework by `Scripts/fetch-idevice.sh`. | MIT |
| [StikDebug](https://github.com/StikDebug/StikDebug) (formerly StikJIT) | **The approach this project's DDI mounting is ported from.** Mounting the Developer Disk Image from the device itself, with no privileged entitlement, is StikDebug's idea; `DDIMounter.swift` sequences the same calls. | AGPL-3.0 |
| [StosVPN](https://github.com/SideStore/StosVPN) / [LocalDevVPN](https://github.com/jkcoxson/LocalDevVPN) | Provides the local tunnel that makes the device's own `remoted` service routable at `10.7.0.1:49152`, which is what lets an on-device app reach its own lockdownd at all. LocalDevVPN is a maintained fork of StosVPN and is what ships on the App Store. | NOASSERTION — check upstream before reuse |
| [doronz88/DeveloperDiskImage](https://github.com/doronz88/DeveloperDiskImage) | Mirror of the personalized DDI components (`BuildManifest.plist`, `Image.dmg`, `Image.dmg.trustcache`). Apple doesn't publish these for direct download; the same files ship inside Xcode, and you can import your own copy instead. Maintained by the pymobiledevice3 author. | See upstream |
| [WebDriverAgent](https://github.com/appium/WebDriverAgent) | Prior art for the long-lived XCUITest runner: the `distantFuture` run loop, failure-proof test case, and app-activation handling all follow patterns it established. No code is copied. | Apache-2.0 |

### How the pieces fit

On iOS 17.4+ the developer services (MobileImageMounter, `com.apple.dvt.*`,
`testmanagerd`) moved behind **RSD (RemoteServiceDiscovery)** — they are no
longer plain lockdownd ports. Reaching them from the device itself takes four
layers:

```
StosVPN / LocalDevVPN   a route to this device's own lockdownd  (NetworkExtension)
        ↓
lockdownd               CoreDeviceProxy → CDTunnel handshake
        ↓
idevice (Rust, MIT)     RSD over that tunnel, then image_mounter
        ↓
DDIMounter.swift        pairing-file auth → RSD connect → personalized mount
```

The VPN is needed for the *first* step, not for the tunnel: it is not a real VPN
at all but a packet reflector. It assigns the device `10.7.0.0`, routes only
`10.7.0.0/24` (the default route is explicitly excluded, so no real traffic is
captured), and swaps source/destination addresses so that `10.7.0.1` reflects
back to the device. That exists because an app cannot reach its own lockdownd on
`127.0.0.1:62078`; the reflected address makes the connection look ordinary and
inbound. The RSD tunnel itself is implemented in userspace by `idevice` and needs
no interface of its own.

The pairing file authenticates the conversation — the same credential Xcode on a
Mac would use. **It must be in RemotePairing (RP) format**: with an older
lockdown-format file on iOS 17+, service connections die instantly with EPIPE
while UDID lookups still appear to succeed, which is a confusing way to fail.
No privileged entitlement is involved anywhere.
