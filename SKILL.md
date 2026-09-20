---
name: ictrl-phone-control
description: Control an iPhone over HTTP to automate real apps — tap, type, swipe, read the screen's view tree, launch apps, take screenshots. Use when the user asks to operate a phone, drive an iOS app, automate a mobile task (search a product, check an order, fill a form), or inspect what's on a device's screen. The service is iCTRL, JSON-RPC 2.0 on port 8200; requests are encrypted, so drive it with a client downloaded from the device (a static CLI needing no interpreter, or a Python one) rather than hand-written HTTP.
skill_version: "1.21.0"
---

# iCTRL — Control an iPhone over HTTP

iCTRL runs on an iPhone and exposes iOS UI automation as a **JSON-RPC 2.0 API over HTTP (port 8200)**. You drive the phone by POSTing RPC calls: tap, type, swipe, read the accessibility view tree, screenshot, launch apps, and more. This document is the operating manual — read it once and you know how to run the phone the fast way.

Every request is encrypted, so the practical first step is to **download a client from the device** (`/skill/clients/…`) rather than assemble HTTP by hand — there is a static CLI that needs no interpreter and a Python one, both always matching the running build. See *Connect & authorize* below.

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

This document is **skill_version 1.21.0** (see the frontmatter). Every `device_info` response carries the device's own `skill_version` (same value as `server_version`) plus a `skill_update_hint`.

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

## Implementing the protocol yourself

Only read this if you can't use one of the bundled clients. The Python one is stdlib-only (X25519 LAN pairing additionally wants `pip install cryptography`; `--plain` over USB/localhost needs nothing) and lives in the repo at `Scripts/ictrl_rpc.py`; the CLI's C source is under `cli/`.

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
0. GET /schema                     → every method + its parameters (unauthenticated, ~150ms, once)
1. device_info                     → learn point_width/point_height/scale (once)
2. resolve_app{text:"<name>"}      → name → bundle_id (built-in catalog + iTunes fallback)
3. launch_app{bundle_id}           → opens it, binds it as the sticky target; wait 2-3s (cold render)
4. find_element{element_id:"<label>"} → get a ref   (or page_source first to learn labels)
5. tap{ref} / type{text,submit} / page{direction}  → act (no wait; these self-quiesce)
6. page_source{visible_only:true, max_children:50}  → read the result (see "under a second" below)
```

Step 6 defaults matter: plain `page_source` on a chat list or feed can take
seconds and still come back without the rows you can see. `visible_only` +
`max_children:50` measured p50 416ms / p90 593ms across 8 apps and never lost
visible content. If the result looks sparser than the screen, call `screen_text`.

**Step 0 is worth the one round trip.** Parameter names are not uniform across methods —
`find_element` wants `element_id`, `resolve_app` wants `text`, `tap` wants `x`/`y` — and a guessed
name costs a full failed call to discover. `/schema` lists all of them at once and needs no auth.

### Parameter quick reference

The names that are most often guessed wrong. `/schema` remains the authority.

| Method | Required | Useful optional |
|---|---|---|
| `find_element` | `element_id` (label **or** accessibility id) | `element_type`, `match:"contains"`, `bundle_id` |
| `scroll_to_element` | `element_id` | `element_type`, `match`, `direction`, `distance`, `bundle_id` |
| `tap` / `double_tap` / `long_press` | `x`+`y` **or** `ref` | `duration` (long_press) |
| `type` | `text` | `submit`, `clear` |
| `resolve_app` | `text` | — |
| `launch_app` / `activate_app` / `terminate_app` | `bundle_id` | — |
| `open_url` | `url` | — |
| `screenshot` | — | `scale`, `format`, `quality`, `bundle_id` |
| `page_source` | — | `bundle_id`, `max_depth`, `filter` |
| `swipe` | — | `direction`, `distance`, `velocity`, `x`, `y` |
| `page` | — | `direction`, `distance` |

Naming traps: the method is **`type`**, not `type_text`. **`element_type` alone never selects an
element** — it only filters, so `element_id` must accompany it.

## Read the `hint` field

Most responses carry a **`hint`** string. It is written for you at call time and knows things this document cannot: which limits were applied to *that* response, whether a result is trustworthy, and what to do next when it isn't. **Read it and decide whether it applies** — it is advisory, not an order, but ignoring it is how automations reach confident wrong conclusions.

`hint` is the single field for this. (`message` describes what happened; `skill_update_hint` is only about version drift.)

It matters most when a result is **negative or suspiciously empty** — that is exactly when a hint tells you the result may be an API limitation rather than a fact about the device.

## Opening apps & jumping back

- **Open an app**: `resolve_app{text:"<name>"}` → `launch_app{bundle_id}`. `launch_app` opens the app's home; use `open_url` when you know a deep link to a specific screen.
- **Never conclude "the app isn't installed" from a lookup.** `resolve_app` reads a static name→bundle_id catalog and says nothing about *this* device; `list_apps` goes through a private API that newer iOS versions may refuse, returning an **empty list on a phone full of apps**. Both failure modes are silent. To actually decide:
  1. **`launch_app{bundle_id}`** — the real test. Success proves it's installed; an error means genuinely absent.
  2. **Ask iOS** — open the home screen, swipe down from mid-screen for Spotlight, type the app's *name*, read the result. Spotlight indexes every installed app regardless of API restrictions, and it works by name, which is what the user gave you anyway.
  3. Only after one of those should you report the app as missing.
- **`open_url{url:"scheme://…"}`** — iCTRL can open ANY iOS URL scheme / deep link, not just app launches. Use it to jump straight to a feature, open a web/universal link, or trigger another app's action.
- **Return to the calling app when the task is done**: after finishing the automation, you can hand control back by opening the caller's URL scheme, e.g. `open_url{url:"<caller-scheme>://"}`. This brings that app to the foreground — a clean way to "return" once you've read/done what you needed on the target app. (If you were invoked with a specific return/callback scheme, use that.)

## Locating elements — pick by situation

> **Web pages are invisible to the accessibility tree — read this before automating a browser.**
> In Safari (or any browser / in-app web view), `page_source` returns **browser chrome only**: a
> few dozen anonymous `Other` nodes, the status bar, the toolbar. Links, buttons and text *inside
> the page do not appear at all*, so `find_element` can never match them. Concretely: a page with
> five app rows returned 42 nodes, none of them page content, while a native app on the same device
> returned 162 fully-labelled nodes.
> **Do not** reach for `scroll_to_element` or `match:"contains"` — they cannot fix this.
> **Do this instead:** `screenshot` → locate the target visually → convert pixel→point by dividing
> by the `scale` field *from that same screenshot response* → `tap{x,y}`.
> Native alerts (including the system "…想要安装…" install sheet) are a different matter: those ARE
> in the tree, so `find_element` works normally for them even while Safari is in front.

- **Known on-screen label** → `find_element{element_id:"<label>"}` → `tap{ref}`. Fastest. Skip page_source.
- **Off-screen (needs scrolling)** → `scroll_to_element{element_id:"<label>"}` — scrolls and returns the ref in one call. Don't hand-roll swipe loops.
- **App exposes accessibility ids** (`identifier:` in page_source) → use that id as `element_id` — the most stable key.
- **On-screen text ≠ accessibility label** (common) → read the exact label from `page_source`, or use `match:"contains"`.
- **No usable label** (icon / image / webview) → `screenshot`, find it visually, tap by COORDINATE. Screenshots are **JPEG by default** (several times smaller than PNG — and since the whole response is decrypted through the envelope, size is what dominates the round trip). Pass `{"format":"png"}` only for lossless needs; `{"quality":0.4}` shrinks it further.
- **Duplicate labels** → add `element_type` (button/cell/…) to disambiguate.

## Searching & typing (the #1 place automation breaks)

1. `launch_app`, wait 2–3s once (cold render).
2. Find the search ENTRY (by its visible label, whatever the app's language). It is often a **Button/StaticText that opens a separate search page** rather than a real input — check `is_text_input`: false means it's an entry, not the field itself. `find_element{element_id:"<label>"}` → `tap{ref}` — no wait after.
3. Locate the REAL input: `find_element{element_id:"<its placeholder text>", element_type:"textfield", match:"contains"}`, confirm `is_text_input:true`, `tap{ref}` to focus (keyboard comes up with the tap). **`element_id` is always required** — `element_type` only narrows the search, it cannot select an element on its own.
4. `type{text:"…", submit:true}` — `submit` appends Return/Search so the field's action fires.
5. Read results with `page_source` directly.
- **TRUST the result — do NOT re-type the same text.** If `type` returns success (no error/warning), the text WENT IN. Only re-type when `type` itself returns a "no keyboard/focus" **warning**. A common false-failure trap: after `type{submit}` you read `page_source` and see the OLD content (the search page/results haven't updated yet, or you read a stale home-screen search bar) — that is NOT proof the type failed. Wait ~1s and re-read, or check the results, before ever re-typing. Re-typing the same query is almost always wrong and just doubles the work.
- **Searching a second time? Use `type{clear:true, text:"…"}`.** Typing APPENDS — a search box still holding the previous query turns "椰子汁" into "黄桃椰子汁" and searches for that, with nothing in the response to say so unless `append_warning` comes back. `clear_text` works too; tap to focus before either.
- If after `type{submit:true}` the action didn't fire, the field may need its explicit submit/search control tapped instead — `find_element` that control (by its visible label) and `tap{ref}` it, rather than re-typing.

## Reading long content

- **`page{direction:"down", distance:N}`** — precise steps, no momentum. This is how you read a feed/detail page predictably. Each step moves **70% of the screen**, so consecutive reads overlap by ~30% and an item straddling the boundary is fully visible in one of them. Don't raise `distance` to save calls on a feed: at 1.0 the overlap is already only ~30%, and beyond that items fall between reads unnoticed.
- **Do NOT use `swipe` to read feeds** — its default ~100pt travel barely moves the page; you'll under-scroll. Reserve `swipe` for carousels / partial drags / pull-to-refresh.
- **Harvest repeated data cheaply**: when you want many similar values off a page, `page_source{filter:{text:"<substring common to them>"}}` returns only the matching nodes + ancestors — far smaller and easier to parse than the whole tree.

## App binding (sticky target)

After `launch_app`/`activate_app`, that app is the **sticky target**.
- **Interaction** methods (tap, swipe, type, page, …) re-focus the bound app automatically if the foreground drifted (response carries an `app_note`).
- **Read-only** methods (page_source, screenshot, find_element) read the CURRENT foreground and do NOT re-activate — so if the bound app got backgrounded and you want to read IT, run one interaction first, or pass an explicit `bundle_id` to the read call.
- If the bound app **crashed** (state notRunning), interaction methods return a clear error → `launch_app` again.
- A **system alert/permission dialog** covering the app → read it via `page_source{bundle_id:"com.apple.springboard"}` and tap its button first.

## When to screenshot (and when not to)

Screenshots are the easiest tool to over-use: look at the picture, spot the
button, convert pixels to points, tap. Every step there can go wrong silently —
in testing, a tap meant for a search field landed on the nav bar, and a stray tap
while scrolling added a product to a cart. Neither reported an error.

**To act on a control** → `find_element{element_id:"<label>"}` → `tap{ref}`.
A `ref` re-resolves the live element, survives scrolling and animation, and needs
no coordinate maths at all.

**To understand the screen** → `page_source{visible_only:true}`. It returns every
on-screen element with type, label and exact frame, is usually *faster* than a
screenshot (~100ms vs ~150ms) and is far smaller.

**Screenshot when the tree genuinely can't answer you:**

- the target has no label — icon-only buttons, images, custom-drawn controls
- you need a visual judgement (layout, colour, what something looks like)
- confirming an action actually landed
- `page_source` came back sparse — check `ax_coverage`, `sparse_hint`,
  `viewport_warning`. The usual culprit is a **web view**, whose page content
  never enters the accessibility tree at all.

Every screenshot response carries a `prefer_instead` field saying which of these
applies.

## Coordinates

`tap`/`swipe`/`drag`/`type(x,y)` use **POINTS**, not pixels. `page_source` frames are already in points. Screenshots are **pixels** → `point = pixel / scale`.

**Use the `scale` from the screenshot response, NOT the one from `device_info`.** They are different numbers: `device_info.screen_scale` is the panel's native ratio (3 on a recent iPhone), while a screenshot defaults to `scale: 2` and is downscaled to match. On a 1206×2622 device that yields an 804×1748 image — dividing by 3 instead of 2 puts the tap ~200pt off, which is the difference between hitting a button and hitting whatever sits above it. Every screenshot response carries `pixel_width/height`, `point_width/height` and its own `scale`; both bundled clients print all three next to the saved file.

## Timeouts & reliability

- Use generous `/rpc` client timeouts (≥ 30s, ideally 60–120s): `/rpc` drives a real device; a cold launch or heavy page takes seconds. A generous timeout is not a reason to *wait* that long — see the timing table above for what each call normally costs. The server itself gives up on a UI call after 6s and replies (15s for the locate-driven ones: `page_source`, `find_and_tap`, `tap_element`), so a request pending far beyond that is a transport problem, not a slow device.
- **Never locate mid-transition — `wait` 1–2s after ANY navigation** (back, tab switch, opening a page), not just after app launch. While a transition animates, every element query runs 5–30x slower (measured: the same screen answered in 169ms settled vs 6.5s mid-animation) and the tree exposes mid-animation geometry — a skeleton of the page with elements at coordinates they are only passing through, so a match can aim a tap at a spot the control has already left. One `wait` beats a slow, wrong read. Corollary: if a locate that is normally fast suddenly takes seconds, the screen probably wasn't settled — re-read rather than trusting the coordinates.
- **A client timeout ≠ failure.** The device keeps executing. Before retrying, `GET /logs` and look for `⏱ ✓ <method>` — if present, it already succeeded and retrying would DOUBLE the action (e.g. a tap fires twice).
- **Cheap recovery** if the service drops: reuse the cached key (`~/.ictrl/token.json`) and `bundle_id` (don't `resolve_app` again); re-`/pair` only if a call actually returns 401; if you know a deep link back (`open_url`), use it instead of re-navigating from the app's home screen.
- **Cellular vs Wi-Fi.** On Wi-Fi the device's LAN address is remotely reachable. On **cellular/mobile data** the address is a public/CGNAT one that's **reachable on-device only** — the server still runs and localhost/on-device clients work, but a LAN peer can't connect, and that's expected (the server won't self-check or raise a "Local Network" prompt on cellular). If you're driving iCTRL from another host, use Wi-Fi; from on-device (e.g. the same phone) it works on any network.

## Reading the UI (`page_source` params)

- `filter` — return only matching nodes + ancestors: `{label:"<substr>"}`, `{type:"button"}`, or `{text:"<substr>"}`. Also the cheapest way to harvest repeated values (filter by a common substring).
- `max_depth` — cap tree depth. WARNING: labels live near the LEAVES, so a shallow depth (3–4) returns structure with NO useful labels — use it only to preview layout, not to find an element.
- `max_elements` — cap node count (default 2000, hard cap 4000). If hit, the response is `truncated:true` — narrow with `filter` or `visible_only` instead of raising this.
- `visible_only:true` — **return only what is on screen right now**, plus the ancestor path of each visible node. See below; this is the fix for long lists.
- To LOCATE a control, prefer `find_element{element_id:"<label>"}` (add `element_type:"button"/"textfield"/…` to disambiguate) → it returns a stable `ref` you then `tap{ref}`. Off-screen → `scroll_to_element{element_id}` returns the ref after scrolling. A `ref` beats coordinates (survives scroll/animation).

### Reading the visible screen in under a second

Measured across 8 apps (WeChat, X, JD, RED, Settings, Spotify, App Store, GitHub)
at 1–8 pages of scroll:

| Approach | p50 | p90 | ever >1s |
|---|---|---|---|
| `visible_only` | 494ms | 1354ms | yes (X) |
| **`visible_only` + `max_children:50`** | **416ms** | **593ms** | **no** |
| `screen_text` (OCR, fast) | 508ms | 551ms | no |
| `screen_text` (OCR, accurate) | 701ms | 919ms | no |

**Default to `page_source{visible_only:true, max_children:50}`.** It was the
fastest option and never exceeded 1s. Verified it loses nothing: at 6–8 pages deep
in RED/GitHub/JD it returned exactly the same visible labels as the unbounded
read, at half the time — the rows `max_children` drops are offscreen ones
`visible_only` would discard anyway.

**Reach for `screen_text` when the tree comes back thin.** On recycling lists the
accessibility tree can be missing most of what you can see — measured on the same
screens, OCR found ~5x more text than the tree did:

| App | texts via tree | via OCR |
|---|---|---|
| WeChat (6 pages in) | 6 | **35** |
| X (3 pages in) | 8 | **45** |
| RED | 30 | **80** |
| Settings / Spotify / GitHub / JD | 20–69 | similar or fewer |

So: normal apps → the tree is as good or better (and gives you `ref`s). Chat
lists and feeds → the tree may return almost nothing while OCR reads the screen
fine. A `viewport_warning` in the response tells you when you are in that case.

### `visible_only` — reading long / infinitely-scrolling lists

A recycling list (chat list, feed, timeline) keeps far more rows in the
accessibility tree than are on screen. Measured on this device:

| App | Nodes | On screen | Offscreen |
|---|---|---|---|
| WeChat chat list | 1500 (truncated) | 130 | **91%** |
| X timeline | 769 | 104 | **86%** |
| JD home | 744 | 606 | 19% |

Those offscreen rows are real rows with real labels — WeChat's sit anywhere from
y = -9115 to y = +13204 — and they **consume the element budget before the
visible ones are reached**, which is why such a page comes back `truncated:true`
while still missing what you can actually see.

`page_source{visible_only:true}` keeps only nodes intersecting the screen rect
(plus their ancestors, so it is still a tree). On the WeChat list that is
1500 → 130 nodes and 115 KB → 9 KB, and it no longer truncates.

**What it is NOT:** a way to read the whole list. It is a snapshot of the current
viewport. **To see more, scroll and read again** — `page{direction:"down"}` then
`page_source{visible_only:true}`, repeating until you find what you need. To jump
straight to a known item, prefer `scroll_to_element{element_id:"<label>"}`.

**Use the full tree (omit the flag) when** you are looking for something just
offscreen, or reasoning about list length/position — `scroll_to_element` needs
the uncelled tree to know which way to scroll. That is why this is opt-in.

**Performance caveat.** `visible_only` cuts the payload and the element budget,
but **not the traversal**. A container's frame does not bound its children in a
recycling list (measured: 89% of parent/child pairs violate containment — WeChat's
Table reports exactly the screen rect while its cells live thousands of points
away), so every node must still be visited to learn where it is. Expect a large
drop in bytes and a modest one in time. On a very long list the call can still be
slow; combine with `filter` or `max_depth` if it is, and remember an app that has
been scrolled for a long time accumulates rows — relaunching it drops them.

## Safety

When operating real shopping/payment apps, stop at the cart/checkout — do NOT tap the final buy/pay/confirm button. Let the user complete payment themselves.

## Diagnostics

- **Check `device_info.system` first when something looks wrong.** Besides thermal/CPU/memory/disk/battery it reports:
  - `screen_locked` — a locked screen is why a screenshot came back black and taps changed nothing. Try `unlock`, but note it only presses Home: on a passcoded device it wakes the display and then fails (~8s), and the user has to unlock by hand. Planning a long unattended run? Have the user set Auto-Lock to Never rather than trying to keep the screen alive from here — note too that sleep does NOT stop the runner, so a read-only task still works with the screen off.
  - `foreground_app` — which app your actions are actually hitting. A surprising value here explains most "the element isn't there" reports.
  - `foreground_is_browser` — present and true when the foreground app is a browser, i.e. page content will NOT appear in `page_source` (see *Locating elements*).
- `GET /logs` — recent in-memory logs (incl. `⏱ ✓ <method> <ms>` timings).
- `GET /logs/files` — list persisted daily log files (survive crashes/restarts).
- `GET /logs/history?date=YYYY-MM-DD` — read a persisted day's log (recover logs from before a crash).
- `reset` — recover when UI calls start timing out and the log shows `kAXErrorServerNotFound` (the accessibility connection to the app dropped). Clears cached refs + the sticky app binding, then `launch_app` the target app to force a reconnect. Runs off the UI queue, so it answers even while UI methods are blocked.
- `config{stop_server:true}` — stop the service (paired keys persist; relaunch the runner to restart). This is the guaranteed fix if `reset` + `launch_app` doesn't bring UI calls back.
- **`device_info`, `logs` and `config` never block behind UI work** — they run on a separate lane. If they answer but `tap`/`find_element` time out, the UI channel is wedged, not the server. After 2 consecutive UI timeouts the server starts rejecting UI calls immediately (with a recovery hint) rather than queueing them behind a stuck one.
