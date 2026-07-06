---
name: ictrl-phone-control
description: Control an iPhone over HTTP to automate real apps — tap, type, swipe, read the screen's view tree, launch apps, take screenshots. Use when the user asks to operate a phone, drive an iOS app, automate a mobile task (search a product, check an order, fill a form), or inspect what's on a device's screen. The service is iCTRL, JSON-RPC 2.0 on port 8200.
---

# iCTRL — Control an iPhone over HTTP

iCTRL runs on an iPhone and exposes iOS UI automation as a **JSON-RPC 2.0 API over HTTP (port 8200)**. You drive the phone by POSTing RPC calls: tap, type, swipe, read the accessibility view tree, screenshot, launch apps, and more. This document is the operating manual — read it once and you know how to run the phone the fast way.

## Connect & authorize

1. **Probe readiness** (short timeout): `GET http://<host>:8200/schema` → HTTP 200 means the service is up. If it's not reachable, the runner isn't running — it must be launched on the device (tapping the iCTRL app, or an `ictrl://` URL scheme if you have one).
2. **Get a token**: `POST /auth` with `{"client_name":"<you>"}`. **This BLOCKS until the device user taps Allow on-screen** — use a client timeout ≥ 60s and do NOT retry early (each retry pops another prompt). On approval you get a token (valid 30 days, survives restarts); denial returns HTTP 403.
3. **Call methods**: `POST /rpc` with `{"jsonrpc":"2.0","method":"…","params":{…},"id":1}` and header `Authorization: Bearer <token>`.

**Cache the token so you don't re-prompt the user every run.** On first successful `/auth`, persist it to **`~/.ictrl/token.json`** as:
```json
{"host": "<host>:8200", "token": "<token>", "granted_at": "<ISO8601>", "client_name": "<you>"}
```
On subsequent runs, **before calling `/auth`**: read `~/.ictrl/token.json`, and if it exists for this host, try it directly (any authenticated call, e.g. `device_info`). Only fall back to `/auth` if that call returns **401** (token expired/revoked) — tokens last 30 days and survive app restarts, so re-auth is rarely needed. This avoids the on-screen Allow prompt on every run. If you cache the resolved `bundle_id`s too (e.g. `~/.ictrl/apps.json`), you can also skip `resolve_app` on repeat tasks.

Full machine-readable method list + parameters + guidance: **`GET /schema`** (JSON). This SKILL is the how; `/schema` is the exact what (method names, params, return shapes). Method set can change — trust `/schema` for the current list.

## The golden rules (this is where speed comes from)

Most automation is slow because of two anti-patterns. Avoid them:

### 1. Don't blind-wait
`tap`, `type`, `swipe`, `page`, `scroll` **already block on UI quiescence before they return**. After an interaction you can read/act **immediately** — no `wait` call. `page_source` reads whatever is currently settled.
- The **only** routine wait is **2–3s once after a cold `launch_app`** (the app is still rendering).
- If a `page_source` comes back mid-transition (splash / placeholder / empty), **then** wait ~1s and re-read — reactively, not by default.
- Blind 2–3s sleeps after every tap are pure wasted latency.

### 2. Act by `ref`, not by coordinates
Don't read `page_source`, find an element's frame, and tap its center. Instead:
- `find_element{element_id:"<label>"}` → returns a stable **`ref`** → `tap{ref}`.
- A `ref` re-resolves the live element: it survives scroll/animation, needs no coordinate math, and no re-read to re-derive coordinates.
- Reserve raw coordinate taps for elements with **no usable label** (icons, canvas, games).
- `page_source` is for **understanding layout**, not for your locate-and-tap loop.

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
- **No usable label** (icon / image / webview) → `screenshot`, find it visually, tap by COORDINATE.
- **Duplicate labels** → add `element_type` (button/cell/…) to disambiguate.

## Searching & typing (the #1 place automation breaks)

1. `launch_app`, wait 2–3s once (cold render).
2. Find the search ENTRY. On most home screens the "search bar" is a **Button/StaticText that opens a search page**, not the input itself (`is_text_input:false`). `find_element{element_id:"搜索"}` → `tap{ref}` — no wait after.
3. Locate the REAL input: `find_element{element_type:"textfield"}`, confirm `is_text_input:true`, `tap{ref}` to focus (keyboard comes up with the tap).
4. `type{text:"…", submit:true}` — `submit` appends Return/Search so the field's action fires. If `type` returns a "no keyboard/focus" **warning**, re-focus the field and retry — don't assume it landed.
5. Read results with `page_source` directly.
- Replace existing text: `type{clear:true, text:"…"}` (empties first) or `clear_text`; tap to focus before clearing.

## Reading long content

- **`page{direction:"down", pages:N}`** — precise one-screen steps, no momentum. This is how you read a feed/detail page predictably.
- **Do NOT use `swipe` to read feeds** — its default ~100pt travel barely moves the page; you'll under-scroll. Reserve `swipe` for carousels / partial drags / pull-to-refresh.
- **Harvest repeated data cheaply**: `page_source{filter:{text:"¥"}}` returns only the price-bearing nodes + ancestors — far easier than parsing the whole tree.

## App binding (sticky target)

After `launch_app`/`activate_app`, that app is the **sticky target**.
- **Interaction** methods (tap, swipe, type, page, …) re-focus the bound app automatically if the foreground drifted (response carries an `app_note`).
- **Read-only** methods (page_source, screenshot, find_element) read the CURRENT foreground and do NOT re-activate — so if the bound app got backgrounded and you want to read IT, run one interaction first, or pass an explicit `bundle_id` to the read call.
- If the bound app **crashed** (state notRunning), interaction methods return a clear error → `launch_app` again.
- A **system alert/permission dialog** covering the app → read it via `page_source{bundle_id:"com.apple.springboard"}` and tap its button first.

## Coordinates

`tap`/`swipe`/`drag`/`type(x,y)` use **POINTS**, not pixels. `page_source` frames are already in points. Screenshots are **pixels** → `point = pixel / scale`. Get `scale` and the valid range from `device_info`.

## Timeouts & reliability

- Use generous `/rpc` client timeouts (≥ 30s, ideally 60–120s): `/rpc` drives a real device; a cold launch or heavy page takes seconds.
- **A client timeout ≠ failure.** The device keeps executing. Before retrying, `GET /logs` and look for `⏱ ✓ <method>` — if present, it already succeeded and retrying would DOUBLE the action (e.g. a tap fires twice).
- **Cheap recovery** if the service drops: reuse the cached token (`~/.ictrl/token.json`) and `bundle_id` (don't `resolve_app` again); re-`/auth` only if a call actually returns 401; if you know a deep link back (`open_url`), use it instead of re-navigating from the app's home screen.

## Safety

When operating real shopping/payment apps, stop at the cart/checkout — do NOT tap the final buy/pay/confirm button. Let the user complete payment themselves.

## Diagnostics

- `GET /logs` — recent in-memory logs (incl. `⏱ ✓ <method> <ms>` timings).
- `GET /logs/files` — list persisted daily log files (survive crashes/restarts).
- `GET /logs/history?date=YYYY-MM-DD` — read a persisted day's log (recover logs from before a crash).
- `config{stop_server:true}` — stop the service (tokens persist; relaunch the runner to restart).
