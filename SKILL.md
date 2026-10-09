---
name: ictrl-phone-control
description: Control an iPhone over HTTP to automate real apps — tap, type, swipe, read the screen's view tree, launch apps, take screenshots. Use when the user asks to operate a phone, drive an iOS app, automate a mobile task (search a product, check an order, fill a form), or inspect what's on a device's screen. The service is iCTRL, JSON-RPC 2.0 on port 8200; requests are encrypted, so drive it with a client downloaded from the device (a static CLI needing no interpreter, or a Python one) rather than hand-written HTTP.
skill_version: "1.33.0"
---

# iCTRL — control an iPhone over HTTP

iCTRL runs on the iPhone and serves UI automation as **JSON-RPC 2.0 over HTTP, port 8200**, encrypted — use a client downloaded from the device (below). `GET /schema` (no auth) lists every method and parameter.

## Rules — read these first

1. **Open apps by bundle id, never by tapping home-screen icons.** `resolve_app{text:"<name>"}` → `launch_app{bundle_id}`. Icon positions are guesses.
2. **Read before you act.** On any screen you haven't read, call `page_source{visible_only:true, max_children:50}` (~0.4s) to learn which view/tab/date you're really on.
3. **Tap by `ref`.** `find_element{element_id:"<label>"}` → `tap{ref}`. Check `visibility`: `"offscreen"` or a non-empty `alternatives` means you may have a look-alike — use `scroll_to_element` or a more specific label.
4. **Never repeat an action "to be safe."** A success reply means it worked. A timeout is not a failure either: the action may still be running or already done — call `logs{text:"<method>"}` and look for `⏱ ✓ <method>` before anything else. A retried tap fires twice.
5. **Every error from a `ref` action means nothing was tapped.** Re-find and retry is safe.
6. **Screenshot last.** Only when the tree can't answer (images, custom-drawn text, web pages). `screen_text` reads text via OCR without an image round trip.
7. **Stop before paying.** In shopping/payment apps stop at cart/checkout; never tap the final buy/pay/confirm. Never delete the user's own items (cart, notes, messages) without asking.

## Connect

In an on-device sandbox (e.g. Minis) use the static CLI — no Python needed, ~9x faster to start. The device is `127.0.0.1`. **Install it in one place, `~/.ictrl/bin`, and check before downloading** — it is usually already there from an earlier session:
```bash
C=~/.ictrl/bin; [ -f $C/ictrl ] || { mkdir -p $C && wget -qO $C/ictrl http://127.0.0.1:8200/skill/clients/cli && wget -qO $C/ictrl.sh http://127.0.0.1:8200/skill/clients/cli.sh; }
sh $C/ictrl.sh call device_info         # works? you're connected; else: sh $C/ictrl.sh pair
sh $C/ictrl.sh call tap '{"x":100,"y":200}'
sh $C/ictrl.sh shot screen.jpg          # screenshot to a file
```
Run it as `sh …/ictrl.sh`. **Not in `/var/minis/workspace`**: that filesystem ignores the exec bit, so it fails with "Permission denied" whatever you `chmod`.

Anywhere with Python:
```bash
curl -o ictrl_rpc.py http://<host>:8200/skill/clients/python
python3 ictrl_rpc.py --host <host>:8200 pair
python3 ictrl_rpc.py --host <host>:8200 call device_info
```
The CLI defaults to `127.0.0.1:8200`; `--host` or `ICTRL_HOST` targets another device. The Python client needs `pip install cryptography` for LAN pairing (not for `--plain` over localhost/USB via `iproxy 8200 8200`).

Both share `~/.ictrl/token.json`, keyed by `host:port` — **one key per device**, never another device's; several devices can run in parallel. Store `device_name` with each key (hosts move; the name says which phone). Reuse the key: it expires only after 30 days *unused*, whatever its `expires` says. Re-pair only on a real `401`. Pairing blocks until the user taps Allow — ≥60s timeout, no early retry (each pops another prompt).

## Core workflow

```
GET /schema                              every method + params (once)
device_info                              screen size in points, versions, state
resolve_app{text} → launch_app{bundle_id}   then wait 2–3s once (cold render)
page_source{visible_only:true, max_children:50}   where am I?
find_element{element_id} → tap{ref}      act
type{text, submit:true}                  enter text
page{direction:"down"}                   read further
```

| Method | Required | Useful optional |
|---|---|---|
| `find_element` | `element_id` (label or accessibility id) | `element_type`, `match:"contains"`, `bundle_id` |
| `scroll_to_element` | `element_id` | `element_type`, `match`, `direction`, `distance` |
| `tap` / `double_tap` / `long_press` | `ref`, or `x`+`y` | `duration` |
| `type` | `text` | `submit`, `clear` |
| `resolve_app` | `text` | — |
| `launch_app` / `activate_app` / `terminate_app` | `bundle_id` | — |
| `open_url` | `url` | — |
| `page_source` | — | `visible_only`, `max_children`, `filter`, `bundle_id` |
| `page` | — | `direction`, `distance` (screens) |
| `swipe` | — | `direction`, `distance`, `velocity`, `x`, `y` |
| `screenshot` | — | `scale`, `format`, `quality` |

The method is `type`, not `type_text`. `element_type` only filters — `element_id` is always required.

Most responses carry a **`hint`** for that exact result — which limits applied, what to do next. Read it, above all when a result is empty or negative.

## Timing, timeouts and recovery

- Taps and swipes are synthesized and return **without waiting for the UI to settle**. After a tap that changes screens, the next read can catch a half-drawn transition (queries run 5–30x slower and frames are wrong). If a read looks like the old screen or is sparse, wait ~1s and re-read. Don't sleep blindly after every tap.
- Typical: `tap` ~0.3s, `page_source` (visible_only) ~0.4s, `find_element` ~1s, `launch_app` ~0.9s + 2–3s render. Much slower usually means a wrong label or a mid-transition screen.
- The server answers a UI call after **6s** (15s for `page_source`, `tap_element`, `find_and_tap`) even if the work is still running. UI calls run **one at a time**, and a stuck one can't be cancelled. Calls behind it time out too. Their error says *"has NOT run yet: queued behind X"*: they will still run later, so **do not resend them**.
- After two timeouts in a row, UI calls are rejected immediately. The message names the stuck call and how long it has run. Recovery: `reset` (clears refs and the app binding), then **wait** for the stuck call to end (typically 15–45s; watch `logs`), then retry. `reset` can't stop a call already running.
- **Only `logs`, `config` and `reset` answer while the UI queue is stuck.** `device_info` shares the UI queue, so it's no health probe; use `logs`.
- Use a client timeout ≥30s. After restarting your side, reuse the cached key and `bundle_id`s and return via a deep link (`open_url`).

## Finding and tapping

- `find_element` matches exact label → accessibility id → (with `match:"contains"`) substring. **An element in view always beats an off-screen one**: a calendar holds "25" in three months, and you get the visible one. The result has `visibility` (`in_view`/`partial`/`offscreen`), and when several matched, `alternatives[]` + `match_count`.
- A `ref` re-resolves the live element at tap time. If its app has gone to the background (a system sheet, another app), the tap is refused at once: *"belongs to X, which is now in the background"*. Look at the screen before continuing.
- **Off-screen** → `scroll_to_element{element_id}`. If the target is already in the tree, it drags straight to it in one move. Otherwise it searches, and without `direction` it reverses once at an end. **"NOT anywhere in this view" means it isn't on this screen at all** — check page/tab/date, or whether the data exists; don't keep scrolling.
- **Text on screen ≠ accessibility label** (common). Copy the label from `page_source`, or use `match:"contains"`. An accessibility `identifier` shown in `page_source` is the most stable `element_id` of all. Duplicate labels → add `element_type`.
- **Nothing matches but you can see it** → it's a custom control with no label. The failure message lists what *is* on screen. Take its frame from `page_source` and `tap{x,y}`.
- A coordinate `tap` returns `hit` (the element under the point, sampled before tapping) or `hit_warning` (nothing labelled there — you probably hit empty space).
- **Web pages don't appear in the accessibility tree.** In Safari or any in-app web view, `page_source` shows only browser chrome (`foreground_is_browser:true` in `device_info`). Use `screenshot` → locate visually → `tap{x,y}`. Native alerts over a page *are* in the tree.
- A **system alert** covering the app blocks ref/element actions. Read it with `page_source{bundle_id:"com.apple.springboard"}` and tap its button by coordinates.

## Typing and searching

1. The search "bar" on a home screen is often a Button that opens a search page. `find_element` returns `is_text_input`; if false, tap it, then find the real field: `find_element{element_id:"<placeholder>", element_type:"textfield", match:"contains"}` → `tap{ref}` (brings up the keyboard).
2. `type{text, submit:true}`. `submit` presses Return/Search.
3. **Trust success.** If `type` returned no warning, the text went in. Old content in the next read means the page hasn't updated yet — wait ~1s, re-read, don't re-type.
4. **Typing appends.** To replace a field's text use `type{text, clear:true}` or `clear_text` first (select-all + delete). An `append_warning` in the response means you just appended to existing text.
   If `submit` didn't trigger the search, tap the screen's own search/confirm control — don't re-type.
5. `page_source` carries `keyboard` (`visible`, `covers_from_y`). Coordinates read before the keyboard appeared are stale: everything above it has shifted.

## Reading the screen

- **Default: `page_source{visible_only:true, max_children:50}`** — on-screen nodes only, well under 1s even on long feeds. Omit `visible_only` only when you need off-screen structure.
- `filter:{text|label|type:"…"}` returns matching nodes + ancestors — the cheap way to harvest repeated values (prices, titles).
- **Thin tree?** Chat lists and feeds may expose little of what's visible. When `ax_coverage` is low or `sparse_hint`/`viewport_warning` appears, call `screen_text` (OCR; returns text with tappable point coordinates).
- `max_depth` small (3–4) returns structure without labels — layout preview only.
- `max_elements` (default 2000, cap 4000): if the response says `truncated:true`, narrow with `filter`/`visible_only` instead of raising it. An app scrolled for a long time accumulates rows and slows every read; relaunching it clears them.

## Scrolling

- **`page{direction:"down"}`** is how to read long content. Each step moves 75% of the screen (25% overlap) at a speed with no momentum, so nothing falls between reads. Don't use `swipe` for reading — it barely moves; keep it for carousels, partial drags and pull-to-refresh.
- `page`/`swipe`/`scroll` report `moved`. **`moved:false` (`at_end:true`) means stop** — nothing more that way. (A page still loading also looks unmoved; wait ~1s if more is expected.)
- `position` (`percent`, `fraction`, …) says where you are. Trust it only when `confidence` is `estimated` or `exact`. Lists that build rows lazily pin it near 0/100% with few `rows_seen`.

## Apps

- `resolve_app` looks offline first: apps opened on this device before (`source:"opened_here"` — launch directly), then a built-in catalog, then the App Store. Only `opened_here` says anything about *this* device.
- **`launch_app` is the real install test**: success = installed, error = not. Newer iOS refuses `list_apps` enumeration; it then returns only apps opened via iCTRL before (`source:"opened_history"`). Never report "not installed" from a lookup or an empty list — if unsure, check Spotlight (home, swipe down, type the name).
- `open_url{url}` opens any scheme / deep link / universal link. Finish by opening the caller's scheme to hand control back, if you have one.
- After `launch_app`/`activate_app` that app is the **bound target**. Coordinate and `element_id` actions bring it back to the front if it drifted (`app_note` says so). `ref` actions don't — they refuse instead. If the bound app leaves the screen, reads follow whatever is in front. Pass `bundle_id` to read a specific app.

## Coordinates and screenshots

- `tap`/`swipe`/`drag` take **points**. `page_source` frames and OCR boxes are points.
- Screenshots are pixels: `point = pixel / scale`, using the **`scale` from that screenshot response** (default 2), not `device_info.screen_scale` (the panel's 3). Mixing them puts taps ~200pt off.
- Screenshots are JPEG by default; `format:"png"` only when lossless matters.

## Diagnostics

- `device_info.system`: `screen_locked` (black screenshots, taps doing nothing — `unlock` only presses Home; a passcode needs the user), `foreground_app` (what you're really driving), `foreground_is_browser`, thermal/memory/battery. Screen sleep does not stop the runner. For long unattended runs, ask the user to set Auto-Lock to Never.
- `logs{text?, max_elements?}`: recent log lines over the normal channel. `⏱ ✓ <method>` = completed, `⏱ TIMEOUT`, `⛔️`/`✅` channel state. `GET /logs/files` and `GET /logs/history?date=YYYY-MM-DD` keep logs across crashes; byte endpoints (`/logs*`, `/stream`) need a single-use `?ticket=` from the `stream_ticket` RPC.
- `reset`: clears refs and the binding and rebuilds the UI channel state, then `launch_app` the target. `config{stop_server:true}` stops the runner (keys persist); it must be relaunched on the device.
- If `/schema` is unreachable, the runner isn't running. The user must start it on the phone, and the Developer Disk Image must be mounted (it is lost on every reboot).
- On cellular the device isn't reachable from the LAN (on-device clients still work).

## Versions

Compare `device_info.skill_version` with this file's frontmatter. Patch gap: ignore. Minor: refresh if something seems missing. Major, or a different `protocol_version`: refresh `GET /skill` **and** the client together. Device *older* than this file: don't downgrade — use only its `capabilities[]` and tell the user.

## Protocol (only if you can't use a bundled client)

- **Pair**: `POST /pair {"client_name","pub":"<b64 X25519 pubkey>"}`, or `{"client_name","plain":true}` from 127.0.0.1 only. Unwrap: `shared=X25519(c_priv,d_pub)`, `K_wrap=HMAC(shared,"ictrl-pair"‖c_pub‖d_pub)`, `K=token_ct XOR HMAC(K_wrap,"ictrl-wrap")`. Denied → 403.
- **Seal** each `/rpc` call: `tok`=first 4 bytes of SHA256(K) as hex; `nonce`=16 random bytes (never reuse); `ts`=unix seconds (±120s). `K_enc_req=HMAC(K,"ictrl-v1|enc-req"‖nonce)`, `K_enc_resp` likewise with `enc-resp`, `K_mac` with `mac`. Keystream = `HMAC(Kx, nonce‖be32(i))` blocks. `ct = body XOR ks(K_enc_req)`, `tag = HMAC(K_mac,"v1"‖tok‖be64(ts)‖nonce‖ct)`. Send `{"v":1,"tok","ts","nonce":hex,"ct":b64,"tag":hex}`.
- **Open** the reply (same nonce): check `tag == HMAC(K_mac,"resp"‖nonce‖ct)`, decrypt with `K_enc_resp`.
