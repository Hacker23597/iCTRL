---
name: ictrl-phone-control
description: Control an iPhone over HTTP to automate real apps — tap, type, swipe, read the screen's view tree, launch apps, take screenshots. Use when the user asks to operate a phone, drive an iOS app, automate a mobile task (search a product, check an order, fill a form), or inspect what's on a device's screen. The service is iCTRL, JSON-RPC 2.0 on port 8200.
skill_version: "1.6.2"
---

# iCTRL — Control an iPhone over HTTP

iCTRL runs on an iPhone and exposes iOS UI automation as a **JSON-RPC 2.0 API over HTTP (port 8200)**. You drive the phone by POSTing RPC calls: tap, type, swipe, read the accessibility view tree, screenshot, launch apps, and more. This document is the operating manual — read it once and you know how to run the phone the fast way.

## Connect & authorize

Every `/rpc` body is an **encrypted envelope (protocol v1)**. There is no plaintext or Bearer path — an unsealed POST gets `401 auth_required`. All request-path crypto is HMAC-SHA256 only, so this is a few lines in any language.

**Don't hand-write the crypto — download a working client from the device itself.**

**Running inside Minis (or any Alpine/musl sandbox)? Use the compiled CLI.** That rootfs has no `python3`, so the Python client costs an `apk add` (network round-trip, ~50MB) before the first call, then pays interpreter startup on every invocation through an emulated syscall layer. The CLI is a single static aarch64-musl binary with no runtime dependencies — measured ~9x faster per invocation (5.4ms vs 47ms just to start).

```bash
# From inside Minis, the device is simply localhost — the guest shares the
# phone's network stack, so no forwarding or host address is needed.
wget -qO ictrl     http://127.0.0.1:8200/skill/clients/cli
wget -qO ictrl.sh  http://127.0.0.1:8200/skill/clients/cli.sh
sh ictrl.sh pair                          # tap Allow on the device
sh ictrl.sh call device_info
sh ictrl.sh call tap '{"x":100,"y":200}'
sh ictrl.sh shot screen.jpg               # screenshot straight to a file
```

Invoke it through `sh ictrl.sh`, not `./ictrl`. Skill files are installed **without the exec bit** (the importer writes 0644 and never chmods), so calling the binary directly fails with `EACCES` on a fresh install. The wrapper runs via `sh` — which needs no exec bit — and fixes the mode on first use. After that `./ictrl` works too.

The key is cached in `~/.ictrl/token.json`, the same file and format the Python client uses, so the two are interchangeable.

**Everywhere else (a Mac, a Linux host with Python):**
```bash
curl -o ictrl_rpc.py http://<host>:8200/skill/clients/python   # unauthenticated
python3 ictrl_rpc.py --host <host>:8200 pair                    # tap Allow on the device
python3 ictrl_rpc.py --host <host>:8200 call device_info
python3 ictrl_rpc.py --host <host>:8200 call tap '{"x":100,"y":200}'
```

Both speak the identical protocol against the same token store — pick by what the environment already has, not by preference. The CLI defaults to `127.0.0.1:8200`; pass `--host` or set `ICTRL_HOST` to target another device.

## Version check — glance at this on your first `device_info`

This document is **skill_version 1.6.2** (see the frontmatter). Every `device_info` response carries the device's own `skill_version` (same value as `server_version`) plus a `skill_update_hint`.

**This is advisory — a version gap is not an error, and most gaps need no action.** Your installed copy is a snapshot from whenever it was fetched; the device's copy always matches the running build. Use semver to decide whether the difference could actually affect you:

| Gap | What it means | Do |
|---|---|---|
| Equal, or **patch** (`1.6.1` → `1.6.2`) | Bug fixes. No method, parameter or return shape changed. | Nothing — carry on. |
| **Minor** (`1.5.x` → `1.6.x`) | New methods/fields added; existing ones still work. | Refresh only if something you need seems missing, or you want the new features. |
| **Major** (`1.x` → `2.x`) | Breaking changes are possible. | Refresh before relying on the details below. |
| `protocol_version` differs from your client's | The envelope format itself moved. | Refresh — nothing will authenticate otherwise. |

To refresh (both endpoints are unauthenticated — no pairing needed):

```bash
curl -o SKILL.md      http://<host>:8200/skill
curl -o ictrl_rpc.py  http://<host>:8200/skill/clients/python
# …or, in Minis / an Alpine sandbox, the compiled client instead of the Python one:
wget -qO ictrl        http://127.0.0.1:8200/skill/clients/cli
```

Then re-read SKILL.md. Refresh **both** together — a stale client is the more dangerous half, since it hand-rolls the envelope crypto and mis-decrypts silently if the protocol moved.

If the device's version is *older* than this file, the device is behind. Don't downgrade this skill; stick to what its `capabilities` array advertises and mention the old build to the user.

For individual features, prefer feature-detecting against `capabilities` over comparing versions — versions tell you *whether refreshing is worth it*, capabilities tell you *what you can call right now*.
It is **Python stdlib only** (X25519 LAN pairing additionally wants `pip install cryptography`; `--plain` over USB/localhost needs nothing), caches keys per device, and is served straight off the runner so it always matches the running build. The same file is in the repo at `Scripts/ictrl_rpc.py`.

Read the rest of this section only if you're implementing the protocol yourself.

1. **Probe readiness** (short timeout): `GET http://<host>:8200/schema` → HTTP 200 means the service is up. If it's not reachable, the runner isn't running — it must be launched on the device (tapping the iCTRL app, or an `ictrl://` URL scheme if you have one). Unauthenticated routes are only `/schema`, `/skill`, `/skill/clients/python` and `/skill/clients/cli[.sh]` (capability discovery, this manual, and the two client implementations — never session data).
2. **Pair once** to get the 32-byte key `K`: `POST /pair` with `{"client_name":"<you>","plain":true}` (accepted **only from 127.0.0.1** — USB via `iproxy 8200 8200`), or over the LAN `{"client_name":"<you>","pub":"<base64 raw 32B X25519 pubkey>"}` and unwrap:
   ```
   shared  = X25519(client_priv, device_pub)
   K_wrap  = HMAC-SHA256(shared, "ictrl-pair" || c_pub || d_pub)
   K       = token_ct XOR HMAC-SHA256(K_wrap, "ictrl-wrap")
   ```
   **This BLOCKS until the device user taps Allow on-screen** — use a client timeout ≥ 60s and do NOT retry early (each retry pops another prompt). Denial returns HTTP 403.
3. **Seal every call**. `POST /rpc` with the envelope below (no auth headers at all):
   ```
   tok   = first 4 bytes of SHA256(K), 8 hex chars   (a lookup id, NOT a secret)
   nonce = 16 fresh random bytes per request          (never reuse — replays are rejected)
   ts    = unix seconds                               (server allows ±120s)

   K_enc_req  = HMAC(K, "ictrl-v1|enc-req"  || nonce)
   K_enc_resp = HMAC(K, "ictrl-v1|enc-resp" || nonce)
   K_mac      = HMAC(K, "ictrl-v1|mac"      || nonce)

   keystream(Kx) = HMAC(Kx, nonce||be32(0)) || HMAC(Kx, nonce||be32(1)) || …   (truncate)
   ct  = <json-rpc body> XOR keystream(K_enc_req)
   tag = HMAC(K_mac, "v1" || tok_4B || be64(ts) || nonce || ct)
   ```
   Body: `{"v":1,"tok":"…","ts":…,"nonce":"<32 hex>","ct":"<base64>","tag":"<64 hex>"}`
4. **Open the reply** — sealed under the **same nonce**: verify `tag == HMAC(K_mac, "resp" || nonce || ct)`, then decrypt with `K_enc_resp`. The plaintext is the normal JSON-RPC response.

**Detect capabilities from `device_info`.** The first `device_info` call returns `server_version` (semver), `protocol_version` (int), and a `capabilities` array (`envelope_v1`, `stream_ticket`, `page_source_filter`, `max_depth`, `find_element_ref`, `scroll_to_element`, `clear_text`, `open_url`, `resolve_app`, `page`, `stop_server`, `logs_history`, `screenshot_jpeg`, `reset`, `nonui_lane`). Feature-detect against these — no separate `/schema` fetch — and don't assume a method exists on an older `server_version`.

### Key cache — one key PER DEVICE

**Each device has its own key.** A key is minted by, and only valid on, the device that issued it — there is no shared secret. So the cache is **keyed by `host:port`**, and you can hold keys for many devices at once and drive them **concurrently**.

Persist to **`~/.ictrl/token.json`** as a map, never a bare object:
```json
{
  "10.1.10.3:8200": {"tok": "a1b2c3d4", "key": "<64 hex K>", "client_name": "<you>",
                     "device_name": "Colour's iPhone", "expires": 1755820800},
  "10.1.1.253:8200": {"tok": "9f8e7d6c", "key": "<64 hex K>", "client_name": "<you>",
                      "device_name": "Ethan's iPhone", "expires": 1755906300}
}
```

Rules that matter when more than one device is in play:
- **Look up by the exact `host:port` you are calling.** Never reuse another device's key — it authenticates as an unknown `tok` and fails `401 auth_failed`.
- **Pair per device**, once each. Pairing device B does not affect device A's key.
- **Keep each device's `nonce` stream separate** — nonces are random per request anyway, so just never reuse an envelope across devices.
- Record `device_name` (from `device_info`) alongside the key. Hosts move (DHCP); the name is what lets you tell the user *which phone* you're driving, and lets you notice a host now answers as a different device.
- Driving several devices at once is fine and fully parallel — separate keys, separate sessions, no shared state on either side.
- `Scripts/ictrl_rpc.py` already does all of this: `--host` selects the device and the store is a host-keyed map.

On later runs, **use the cached key directly** — don't call `/pair`. Expiry is **idle-based**: a key dies only after 30 days of *no use*, and every call slides that window forward, so a key in regular use never expires and survives app restarts. The `expires` returned at pair time is merely "expiry if never used" — do **not** discard a cached key because that timestamp passed. Re-pair only when a call actually returns **401**. If you cache resolved `bundle_id`s too (e.g. `~/.ictrl/apps.json`, also keyed per host), you can skip `resolve_app` on repeat tasks.

**Dev shortcut:** if the runner was launched from Xcode with `ICTRL_ALLOW_AUTH_ONCE=1` in the scheme's environment, the **first** pairing after that cold start is auto-approved (no on-device tap). It is consumed by that one pairing and never rearms.

**Byte streams use a ticket, not an envelope.** `GET /stream` and `GET /logs*` return raw bytes a browser/player fetches directly, so they can't carry an envelope. Call the `stream_ticket` RPC (over the encrypted channel) to mint a **single-use, ~60s** ticket, then append `?ticket=<t>` to the URL. Mint a fresh one per fetch.

Full machine-readable method list + parameters + guidance: **`GET /schema`** (JSON). This SKILL is the how; `/schema` is the exact what (method names, params, return shapes). Method set can change — trust `/schema` for the current list.

**Capability negotiation.** `/schema` and `device_info` include `protocol_version` and a `capabilities` list. Read them and don't assume a method exists on an older `server_version`; older servers without these fields → treat conservatively.

## The golden rules (this is where speed comes from)

Most automation is slow because of three anti-patterns. Avoid them:

### 1. Don't blind-wait
`tap`, `type`, `swipe`, `page`, `scroll` **already block on UI quiescence before they return**. After an interaction you can read/act **immediately** — no `wait` call. `page_source` reads whatever is currently settled.
- The **only** routine wait is **2–3s once after a cold `launch_app`** (the app is still rendering).
- If a `page_source` comes back mid-transition (splash / placeholder / empty), **then** wait ~1s and re-read — reactively, not by default.
- Blind 2–3s sleeps after every tap are pure wasted latency.

**How long calls actually take.** Measured on a real device (iPhone 17 Pro, iOS 26), median and p90 in ms:

| Call | median | p90 | Notes |
|---|---|---|---|
| `device_info` | 20 | 130 | Cheap — safe to poll |
| `screenshot` | 155 | 215 | JPEG default; PNG is several times slower to transfer |
| `tap` | 280 | 650 | Includes the UI settling |
| `swipe` | 420 | 540 | |
| `home` | 550 | 600 | |
| `type` | 640 | 670 | Per call, not per character |
| `page_source` | 460 | 1250 | Grows with page size — use `filter` |
| `launch_app` | 860 | 930 | Plus 2–3s of rendering before the UI is readable |
| `find_element` | 950 | 2200 | A **miss** costs the most — see below |

Use these as your expectation, not as timeouts: keep the client timeout generous (30s+), but if you find yourself *sleeping* longer than the numbers above, you are waiting for nothing. A tap that returns in 280ms has already settled — the next call can go out immediately.

**When something takes much longer than this, it is a signal, not a reason to wait harder:**
- `find_element` running seconds long usually means the label is **wrong**, not that the element is slow to appear. A miss walks the whole tree before giving up. Confirm the exact text with `page_source{filter:{text:"…"}}` instead of retrying variations.
- Any UI call exceeding ~6s gets a timeout reply while still running on the device. **Don't blindly retry** — check `GET /logs` for `⏱ ✓ <method>` first; a retried tap fires twice.
- Repeated timeouts mean the UI channel is wedged (see Diagnostics): `device_info` still answering while `tap` times out confirms it. Call `reset`, don't wait it out.

### 2. Act by `ref`, not by coordinates
Don't read `page_source`, find an element's frame, and tap its center. Instead:
- `find_element{element_id:"<label>"}` → returns a stable **`ref`** → `tap{ref}`.
- A `ref` re-resolves the live element: it survives scroll/animation, needs no coordinate math, and no re-read to re-derive coordinates.
- Reserve raw coordinate taps for elements with **no usable label** (icons, canvas, games).
- `page_source` is for **understanding layout**, not for your locate-and-tap loop.

### 3. Trust the result — don't re-do an action that already succeeded
When a call returns success, it worked. Don't repeat it "to be safe."
- After `type{submit}`, if it returned no error/warning, the text is in — do NOT re-type the same query. Reading `page_source` and seeing OLD content usually means the page hasn't updated yet (wait ~1s, re-read), NOT that the action failed.
- Before retrying anything after a client timeout, check `/logs` for `⏱ ✓ <method>` — if it's there, it already ran; retrying doubles it (a tap fires twice, a query searches twice).
- The cost of a needless retry is high: a wasted type (~2s) plus the taps and reads around it.

## Core workflow

```
1. device_info                     → learn point_width/point_height/scale (once)
2. resolve_app{text:"<name>"}      → name → bundle_id (built-in catalog + iTunes fallback)
3. launch_app{bundle_id}           → opens it, binds it as the sticky target; wait 2-3s (cold render)
4. find_element{element_id:"<label>"} → get a ref   (or page_source first to learn labels)
5. tap{ref} / type{text,submit} / page{direction}  → act (no wait; these self-quiesce)
6. page_source                     → read the result directly (wait ~1s + re-read ONLY if still loading)
```

## Opening apps & jumping back

- **Open an app**: `resolve_app{text:"<name>"}` → `launch_app{bundle_id}`. `launch_app` opens the app's home; use `open_url` when you know a deep link to a specific screen.
- **`open_url{url:"scheme://…"}`** — iCTRL can open ANY iOS URL scheme / deep link, not just app launches. Use it to jump straight to a feature, open a web/universal link, or trigger another app's action.
- **Return to the calling app when the task is done**: after finishing the automation, you can hand control back by opening the caller's URL scheme, e.g. `open_url{url:"<caller-scheme>://"}`. This brings that app to the foreground — a clean way to "return" once you've read/done what you needed on the target app. (If you were invoked with a specific return/callback scheme, use that.)

## Locating elements — pick by situation

- **Known on-screen label** → `find_element{element_id:"<label>"}` → `tap{ref}`. Fastest. Skip page_source.
- **Off-screen (needs scrolling)** → `scroll_to_element{element_id:"<label>"}` — scrolls and returns the ref in one call. Don't hand-roll swipe loops.
- **App exposes accessibility ids** (`identifier:` in page_source) → use that id as `element_id` — the most stable key.
- **On-screen text ≠ accessibility label** (common) → read the exact label from `page_source`, or use `match:"contains"`.
- **No usable label** (icon / image / webview) → `screenshot`, find it visually, tap by COORDINATE. Screenshots are **JPEG by default** (several times smaller than PNG — and since the whole response is decrypted through the envelope, size is what dominates the round trip). Pass `{"format":"png"}` only for lossless needs; `{"quality":0.4}` shrinks it further.
- **Duplicate labels** → add `element_type` (button/cell/…) to disambiguate.

## Searching & typing (the #1 place automation breaks)

1. `launch_app`, wait 2–3s once (cold render).
2. Find the search ENTRY (by its visible label, whatever the app's language). It is often a **Button/StaticText that opens a separate search page** rather than a real input — check `is_text_input`: false means it's an entry, not the field itself. `find_element{element_id:"<label>"}` → `tap{ref}` — no wait after.
3. Locate the REAL input: `find_element{element_type:"textfield"}`, confirm `is_text_input:true`, `tap{ref}` to focus (keyboard comes up with the tap).
4. `type{text:"…", submit:true}` — `submit` appends Return/Search so the field's action fires.
5. Read results with `page_source` directly.
- **TRUST the result — do NOT re-type the same text.** If `type` returns success (no error/warning), the text WENT IN. Only re-type when `type` itself returns a "no keyboard/focus" **warning**. A common false-failure trap: after `type{submit}` you read `page_source` and see the OLD content (the search page/results haven't updated yet, or you read a stale home-screen search bar) — that is NOT proof the type failed. Wait ~1s and re-read, or check the results, before ever re-typing. Re-typing the same query is almost always wrong and just doubles the work.
- Replace existing text: `type{clear:true, text:"…"}` (empties first) or `clear_text`; tap to focus before clearing.
- If after `type{submit:true}` the action didn't fire, the field may need its explicit submit/search control tapped instead — `find_element` that control (by its visible label) and `tap{ref}` it, rather than re-typing.

## Reading long content

- **`page{direction:"down", pages:N}`** — precise one-screen steps, no momentum. This is how you read a feed/detail page predictably.
- **Do NOT use `swipe` to read feeds** — its default ~100pt travel barely moves the page; you'll under-scroll. Reserve `swipe` for carousels / partial drags / pull-to-refresh.
- **Harvest repeated data cheaply**: when you want many similar values off a page, `page_source{filter:{text:"<substring common to them>"}}` returns only the matching nodes + ancestors — far smaller and easier to parse than the whole tree.

## App binding (sticky target)

After `launch_app`/`activate_app`, that app is the **sticky target**.
- **Interaction** methods (tap, swipe, type, page, …) re-focus the bound app automatically if the foreground drifted (response carries an `app_note`).
- **Read-only** methods (page_source, screenshot, find_element) read the CURRENT foreground and do NOT re-activate — so if the bound app got backgrounded and you want to read IT, run one interaction first, or pass an explicit `bundle_id` to the read call.
- If the bound app **crashed** (state notRunning), interaction methods return a clear error → `launch_app` again.
- A **system alert/permission dialog** covering the app → read it via `page_source{bundle_id:"com.apple.springboard"}` and tap its button first.

## Coordinates

`tap`/`swipe`/`drag`/`type(x,y)` use **POINTS**, not pixels. `page_source` frames are already in points. Screenshots are **pixels** → `point = pixel / scale`. Get `scale` and the valid range from `device_info`.

## Timeouts & reliability

- Use generous `/rpc` client timeouts (≥ 30s, ideally 60–120s): `/rpc` drives a real device; a cold launch or heavy page takes seconds. A generous timeout is not a reason to *wait* that long — see the timing table above for what each call normally costs. The server itself gives up on a UI call after 6s and replies, so a request pending far beyond that is a transport problem, not a slow device.
- **A client timeout ≠ failure.** The device keeps executing. Before retrying, `GET /logs` and look for `⏱ ✓ <method>` — if present, it already succeeded and retrying would DOUBLE the action (e.g. a tap fires twice).
- **Cheap recovery** if the service drops: reuse the cached key (`~/.ictrl/token.json`) and `bundle_id` (don't `resolve_app` again); re-`/pair` only if a call actually returns 401; if you know a deep link back (`open_url`), use it instead of re-navigating from the app's home screen.
- **Cellular vs Wi-Fi.** On Wi-Fi the device's LAN address is remotely reachable. On **cellular/mobile data** the address is a public/CGNAT one that's **reachable on-device only** — the server still runs and localhost/on-device clients work, but a LAN peer can't connect, and that's expected (the server won't self-check or raise a "Local Network" prompt on cellular). If you're driving iCTRL from another host, use Wi-Fi; from on-device (e.g. the same phone) it works on any network.

## Reading the UI (`page_source` params)

- `filter` — return only matching nodes + ancestors: `{label:"<substr>"}`, `{type:"button"}`, or `{text:"<substr>"}`. Also the cheapest way to harvest repeated values (filter by a common substring).
- `max_depth` — cap tree depth. WARNING: labels live near the LEAVES, so a shallow depth (3–4) returns structure with NO useful labels — use it only to preview layout, not to find an element.
- `max_elements` — cap node count (default 500, hard cap 2000). If hit, the response is `truncated:true` — narrow with `filter` instead of raising this.
- To LOCATE a control, prefer `find_element{element_id:"<label>"}` (add `element_type:"button"/"textfield"/…` to disambiguate) → it returns a stable `ref` you then `tap{ref}`. Off-screen → `scroll_to_element{element_id}` returns the ref after scrolling. A `ref` beats coordinates (survives scroll/animation).

## Safety

When operating real shopping/payment apps, stop at the cart/checkout — do NOT tap the final buy/pay/confirm button. Let the user complete payment themselves.

## Diagnostics

- `GET /logs` — recent in-memory logs (incl. `⏱ ✓ <method> <ms>` timings).
- `GET /logs/files` — list persisted daily log files (survive crashes/restarts).
- `GET /logs/history?date=YYYY-MM-DD` — read a persisted day's log (recover logs from before a crash).
- `reset` — recover when UI calls start timing out and the log shows `kAXErrorServerNotFound` (the accessibility connection to the app dropped). Clears cached refs + the sticky app binding, then `launch_app` the target app to force a reconnect. Runs off the UI queue, so it answers even while UI methods are blocked.
- `config{stop_server:true}` — stop the service (paired keys persist; relaunch the runner to restart). This is the guaranteed fix if `reset` + `launch_app` doesn't bring UI calls back.
- **`device_info`, `logs` and `config` never block behind UI work** — they run on a separate lane. If they answer but `tap`/`find_element` time out, the UI channel is wedged, not the server. After 2 consecutive UI timeouts the server starts rejecting UI calls immediately (with a recovery hint) rather than queueing them behind a stuck one.
