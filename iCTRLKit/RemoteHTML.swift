import Foundation

/// Static HTML for GET /remote — a browser control page: plays the live MPEG-TS
/// stream in <video> (via mpegts.js) and drives the device with the same JSON-RPC
/// as the desktop GUI (tap/swipe/scroll/keyboard + a side panel of buttons).
/// The visual style is a light-touch shadcn/ui port — Tailwind-flavor tokens,
/// Radix-ish surfaces (zinc, subtle border, rounded, focus rings) — hand-written
/// in CSS so the page stays a single self-contained file.
///
/// The page has NO external network dependency: CSS is inline, mpegts.js is
/// vendored into MpegtsJS.swift and inlined at build time. Works fully offline.
///
/// The page uses the SAME token as /rpc (it's the query token passed by the
/// user when they open /remote?token=…) and re-uses it on every RPC call.
enum RemoteHTML {
    /// Full HTML for GET /remote, with mpegts.js inlined so the page has no
    /// external network dependency (fully self-contained: CSS, JS, decoder).
    static var page: String { pageHead + MpegtsJS.source + pageBody }

    private static let pageHead: String = #"""
<!doctype html>
<html lang="en" class="dark">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>iCTRL Remote</title>
<script>
"""#

    private static let pageBody: String = #"""
</script>
<style>
  /* ── shadcn-inspired tokens (dark) ── */
  :root {
    --bg: #09090b;          /* zinc-950 */
    --card: #18181b;        /* zinc-900 */
    --card-hi: #27272a;     /* zinc-800 */
    --border: #27272a;
    --border-hi: #3f3f46;   /* zinc-700 */
    --fg: #fafafa;          /* zinc-50 */
    --muted: #a1a1aa;       /* zinc-400 */
    --muted-2: #71717a;     /* zinc-500 */
    --primary: #fafafa;
    --primary-fg: #18181b;
    --accent: #22c55e;      /* green-500 */
    --danger: #ef4444;      /* red-500 */
    --warn: #f59e0b;        /* amber-500 */
    --ring: rgba(250,250,250,.35);
    --radius: 10px;
  }
  * { box-sizing: border-box; }
  html, body { height: 100%; overscroll-behavior: none; }
  body {
    margin: 0;
    font: 14px/1.4 -apple-system, BlinkMacSystemFont, "SF Pro Text", ui-sans-serif, system-ui, "Segoe UI", Roboto, sans-serif;
    color: var(--fg); background: var(--bg);
    -webkit-font-smoothing: antialiased;
  }
  .app {
    display: grid;
    grid-template-columns: minmax(0, 1fr) clamp(280px, 26vw, 340px);
    gap: 12px;
    padding: 12px;
    padding-bottom: 44px;   /* leave room for the fixed #status bar */
    height: 100vh;
    height: 100dvh;         /* mobile: exclude URL bar */
  }
  /* ── panels ── */
  .panel {
    background: var(--card);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    overflow: hidden;
  }
  .stage {
    position: relative; display: flex; align-items: center; justify-content: center;
    background: #000; user-select: none;
    min-height: 0; min-width: 0;
  }
  #video {
    width: 100%; height: 100%; display: block; background: #000;
    object-fit: contain;
    outline: none;
  }
  .stage .overlay {
    position: absolute; inset: 0;
    /* invisible input catcher — sits above <video>, receives clicks/keys */
    cursor: crosshair;
  }
  .stage .hud {
    position: absolute; top: 10px; left: 12px; right: 12px;
    display: flex; justify-content: space-between; align-items: center;
    color: var(--muted); font-size: 12px; pointer-events: none;
  }
  .badge {
    background: rgba(0,0,0,.5); border: 1px solid var(--border);
    padding: 2px 8px; border-radius: 999px;
  }
  .dot { display:inline-block; width:6px; height:6px; border-radius: 999px; margin-right:6px; vertical-align: middle; }
  .dot.on { background: var(--accent); }
  .dot.off { background: var(--muted-2); }
  .dot.err { background: var(--danger); }

  /* ── sidebar ── */
  aside {
    display: flex; flex-direction: column; gap: 12px;
    overflow-y: auto; overflow-x: hidden;
    /* Bound the sidebar to the grid row so overflow triggers the scrollbar
       instead of the whole page scrolling. */
    min-height: 0; max-height: 100%;
    /* subtle scrollbar */
    scrollbar-width: thin;
    scrollbar-color: var(--border-hi) transparent;
  }
  aside::-webkit-scrollbar { width: 8px; }
  aside::-webkit-scrollbar-track { background: transparent; }
  aside::-webkit-scrollbar-thumb {
    background: var(--border-hi); border-radius: 999px; border: 2px solid var(--card);
  }
  aside::-webkit-scrollbar-thumb:hover { background: #52525b; }
  .section { padding: 12px; }
  .section h3 {
    margin: 0 0 10px; font-size: 12px; font-weight: 600;
    color: var(--muted); text-transform: uppercase; letter-spacing: .06em;
  }
  .row { display: flex; gap: 8px; }
  .row + .row { margin-top: 8px; }
  .col { display: flex; flex-direction: column; gap: 8px; }
  .grid-2 { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; }
  .grid-3 { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 8px; }

  /* ── buttons (shadcn variants) ── */
  .btn {
    appearance: none; border: 1px solid var(--border-hi);
    background: var(--card-hi); color: var(--fg);
    padding: 8px 12px; border-radius: 8px;
    font-size: 13px; font-weight: 500;
    display: inline-flex; align-items: center; justify-content: center; gap: 6px;
    cursor: pointer; transition: background .12s, border-color .12s, transform .06s;
    min-height: 34px;
  }
  .btn:hover { background: #2d2d31; border-color: #52525b; }
  .btn:active { transform: translateY(1px); }
  .btn:focus-visible { outline: 2px solid var(--ring); outline-offset: 1px; }
  .btn.primary { background: var(--fg); color: var(--primary-fg); border-color: var(--fg); }
  .btn.primary:hover { background: #e4e4e7; }
  .btn.ghost { background: transparent; border-color: var(--border); }
  .btn.ghost:hover { background: var(--card-hi); }
  .btn.danger { color: #fca5a5; border-color: #7f1d1d; background: transparent; }
  .btn.danger:hover { background: #7f1d1d33; }
  .btn.icon { padding: 8px; min-width: 34px; }
  .btn:disabled { opacity: .5; cursor: not-allowed; }
  .btn.full { width: 100%; }

  /* ── inputs ── */
  .input {
    background: var(--bg); color: var(--fg); border: 1px solid var(--border-hi);
    padding: 8px 10px; border-radius: 8px; font-size: 13px; width: 100%;
  }
  .input:focus { outline: 2px solid var(--ring); outline-offset: 0; border-color: var(--border-hi); }
  .label { font-size: 12px; color: var(--muted); margin-bottom: 4px; display: block; }

  /* ── status bar (fixed bottom, always visible) ── */
  #status {
    position: fixed; left: 0; right: 0; bottom: 0; z-index: 40;
    padding: 8px 12px;
    border-top: 1px solid var(--border);
    font-size: 12px; color: var(--muted);
    background: rgba(24,24,27,.92);
    backdrop-filter: blur(6px);
    display: flex; align-items: center; gap: 8px;
    min-height: 30px;
  }
  #status .sep { color: var(--border-hi); }
  #status .toast {
    padding: 1px 8px; border-radius: 999px;
    border: 1px solid var(--border);
    background: var(--card-hi);
    color: var(--fg);
    animation: toastIn .18s ease;
  }
  #status .toast.ok    { color: #86efac; border-color: #14532d; background: #052e16; }
  #status .toast.err   { color: #fca5a5; border-color: #7f1d1d; background: #450a0a; }
  #status .toast.warn  { color: #fcd34d; border-color: #78350f; background: #451a03; }
  @keyframes toastIn { from { opacity: 0; transform: translateY(4px); } to { opacity: 1; transform: none; } }
  .kbd {
    background: var(--card-hi); border: 1px solid var(--border-hi);
    padding: 1px 6px; border-radius: 4px; font-size: 11px; color: var(--muted);
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  }
  .hint { color: var(--muted-2); font-size: 11px; margin-top: 6px; }

  /* ── mobile: sidebar collapses into a FAB + bottom-sheet drawer ── */
  #fab {
    display: none;
    position: fixed; right: 16px; bottom: 56px; z-index: 30;
    width: 56px; height: 56px; border-radius: 999px;
    background: var(--fg); color: var(--primary-fg);
    border: none; box-shadow: 0 6px 20px rgba(0,0,0,.5);
    font-size: 22px; cursor: pointer;
    align-items: center; justify-content: center;
  }
  #fab:active { transform: translateY(1px); }
  #scrim {
    display: none;
    position: fixed; inset: 0; background: rgba(0,0,0,.55); z-index: 20;
    backdrop-filter: blur(2px);
  }

  /* Drawer styling only kicks in on narrow viewports — on desktop the sidebar
     is a normal grid column. */
  @media (max-width: 720px) {
    .app { grid-template-columns: minmax(0, 1fr); padding: 8px; padding-bottom: 40px; }
    .app > aside {
      position: fixed; left: 0; right: 0; bottom: 0; z-index: 25;
      max-height: 78dvh; overflow-y: auto;
      background: var(--card);
      border-top: 1px solid var(--border);
      border-top-left-radius: 16px; border-top-right-radius: 16px;
      padding: 8px 12px 24px;
      transform: translateY(100%);
      transition: transform .22s ease;
    }
    .app > aside::before {
      content: ''; display: block; width: 44px; height: 4px; margin: 6px auto 10px;
      background: var(--border-hi); border-radius: 999px;
    }
    .app.open > aside { transform: translateY(0); }
    .app.open #scrim { display: block; }
    #fab { display: inline-flex; }
    .stage { border-radius: 12px; }
    .section { padding: 10px; }
    .grid-3 { max-width: 240px; }
  }
  /* landscape phones: keep video full width, drawer larger */
  @media (max-width: 720px) and (orientation: landscape) {
    #fab { bottom: 12px; right: 12px; width: 48px; height: 48px; font-size: 20px; }
    .app > aside { max-height: 92dvh; }
  }
</style>
</head>
<body>
<div class="app" id="app">
  <!-- ── LEFT: video stage ── -->
  <section class="panel stage" id="stage">
    <video id="video" autoplay muted playsinline></video>
    <div class="hud">
      <span class="badge" id="hudDevice">—</span>
      <span class="badge"><span id="statusDot" class="dot off"></span><span id="hudState">Disconnected</span></span>
    </div>
    <!-- overlay catches pointer + keyboard events -->
    <div class="overlay" id="overlay" tabindex="0"></div>
  </section>

  <!-- ── RIGHT: control panel ── -->
  <aside>
    <div class="panel section">
      <h3>Connection</h3>
      <label class="label">Token</label>
      <input class="input" id="tokenInput" type="password" placeholder="Bearer token" autocomplete="off">
      <div class="row" style="margin-top: 8px">
        <button class="btn primary" id="connectBtn">Connect</button>
        <button class="btn ghost" id="stopBtn" disabled>Stop</button>
      </div>
      <div class="hint">Also opens with <span class="kbd">/remote?token=…</span></div>
    </div>

    <div class="panel section">
      <h3>Stream</h3>
      <div class="grid-2">
        <div>
          <label class="label">FPS</label>
          <select class="input" id="fpsSel">
            <option value="1">1</option>
            <option value="2" selected>2</option>
            <option value="3">3</option>
            <option value="5">5</option>
          </select>
        </div>
        <div>
          <label class="label">Quality</label>
          <select class="input" id="qSel" disabled title="Encoded server-side">
            <option>auto</option>
          </select>
        </div>
      </div>
    </div>

    <div class="panel section">
      <h3>Device</h3>
      <div class="grid-2">
        <button class="btn" data-act="home">🏠 Home</button>
        <button class="btn" data-act="lock-confirm">🔒 Lock</button>
        <button class="btn" data-act="unlock">🔓 Unlock</button>
        <button class="btn" data-act="screenshot">📷 Shot</button>
      </div>
      <button class="btn full" style="margin-top:8px" data-act="open-app">📱 Open App…</button>
    </div>

    <div class="panel section">
      <h3>Navigate</h3>
      <div class="grid-3" style="max-width: 200px; margin: 0 auto">
        <div></div>
        <button class="btn icon" data-nav="up">↑</button>
        <div></div>
        <button class="btn icon" data-nav="left">←</button>
        <button class="btn icon" data-nav="center">•</button>
        <button class="btn icon" data-nav="right">→</button>
        <div></div>
        <button class="btn icon" data-nav="down">↓</button>
        <div></div>
      </div>
      <div class="row" style="margin-top:8px">
        <button class="btn full" data-page="up">⇞ PgUp</button>
        <button class="btn full" data-page="down">⇟ PgDn</button>
      </div>
    </div>

    <div class="panel section">
      <h3>Text</h3>
      <button class="btn full" data-act="type-text">⌨️ Type text…</button>
      <div class="row" style="margin-top:8px">
        <button class="btn full" data-act="clear-text">⌫ Clear field</button>
        <button class="btn full" data-act="submit">⏎ Submit</button>
      </div>
      <div class="hint">Click the video, then type — keys go to the focused field on the device. Enter = submit.</div>
    </div>
  </aside>
</div>

<div id="scrim"></div>
<button id="fab" aria-label="Open controls" title="Controls">⚙︎</button>

<div id="status">
  <span class="dot off" id="statusDotBar"></span>
  <span id="statusText">Idle</span>
  <span class="sep">•</span>
  <span id="lastAction" class="toast" style="display:none"></span>
</div>

<script>
(() => {
  // ── DOM ──
  const $ = s => document.querySelector(s);
  const video = $('#video'), stage = $('#stage'), overlay = $('#overlay');
  const tokenInput = $('#tokenInput'), fpsSel = $('#fpsSel');
  const connectBtn = $('#connectBtn'), stopBtn = $('#stopBtn');
  const statusText = $('#statusText'), statusDot = $('#statusDotBar');
  const lastAction = $('#lastAction');
  const hudState = $('#hudState'), hudDevice = $('#hudDevice'), hudDot = $('#statusDot');
  let toastTimer = null;

  // ── state ──
  let player = null;
  // Token precedence: ?token= query wins (explicit) > localStorage (last used).
  // localStorage is scoped per (host, port) — safe for switching between
  // multiple iCTRL devices — and we only persist on a successful connect.
  const STORE_KEY = 'ictrl.token';
  const qToken = new URLSearchParams(location.search).get('token') || '';
  let token = qToken || localStorage.getItem(STORE_KEY) || '';
  if (token) tokenInput.value = token;
  let deviceInfo = null;   // {point_width, point_height}
  let dragStart = null;

  // ── status ──
  // Two channels:
  //   setConn(msg, kind)  → the LEFT half of the status bar + video HUD,
  //                         a sticky connection state ("connected", "streaming …").
  //   setToast(msg, kind) → a transient badge on the RIGHT of the status bar,
  //                         auto-clears after ~2.4s. Used for per-action feedback
  //                         (tap ok, swipe ok, rpc failed, …).
  function setConn(msg, kind = 'idle') {
    statusText.textContent = msg;
    hudState.textContent = msg;
    const cls = 'dot ' + (kind === 'ok' ? 'on' : kind === 'err' ? 'err' : 'off');
    statusDot.className = cls; hudDot.className = cls;
  }
  function setToast(msg, kind = 'ok', ttl = 2400) {
    lastAction.textContent = msg;
    lastAction.className = 'toast ' + (kind || '');
    lastAction.style.display = '';
    if (toastTimer) clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { lastAction.style.display = 'none'; }, ttl);
  }
  // Legacy shim: existing call sites use setStatus(msg, kind). Route lifecycle
  // words to the sticky connection line, everything else to the toast.
  const CONN_WORDS = ['idle','connecting','stopped','connected','streaming','switching','waiting'];
  function setStatus(msg, kind = 'idle') {
    const isConn = CONN_WORDS.some(w => msg.toLowerCase().startsWith(w));
    if (isConn) setConn(msg, kind);
    else setToast(msg, kind === 'err' ? 'err' : kind === 'ok' ? 'ok' : 'warn');
  }

  // ── RPC ──
  async function rpc(method, params = {}) {
    if (!token) throw new Error('no token');
    const r = await fetch('/rpc', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + token },
      body: JSON.stringify({ jsonrpc: '2.0', method, params, id: Date.now() }),
    });
    if (r.status === 401 || r.status === 403) {
      // Server rejected the token — forget it so the next visit doesn't loop.
      try { localStorage.removeItem(STORE_KEY); } catch (_) {}
      throw new Error('token rejected (' + r.status + ')');
    }
    const j = await r.json();
    if (j.error) throw new Error(j.error.message || 'rpc failed');
    return j.result || {};
  }

  // ── HUD device badge (short label + full details on hover) ──
  function updateHudDevice(info) {
    if (!info) { hudDevice.textContent = '—'; hudDevice.title = ''; return; }
    const name = info.device_name || info.model || 'iPhone';
    const os = info.system_version ? ` · iOS ${info.system_version}` : '';
    hudDevice.textContent = name + os;
    const lines = [
      `Name:    ${info.device_name || '—'}`,
      `Model:   ${info.model || '—'}`,
      `iOS:     ${info.system_version || '—'}`,
      `Screen:  ${info.point_width}×${info.point_height} pt (${info.pixel_width}×${info.pixel_height} px, ${info.scale}x)`,
      `Server:  ${info.server_version || '—'}${info.protocol_version != null ? ' (proto ' + info.protocol_version + ')' : ''}`,
    ];
    hudDevice.title = lines.join('\n');
  }

  // ── coordinate conversion ──
  // The video element shows the encoded frame; we map a click on it to device
  // POINTS via device_info's point_width/point_height. video.videoWidth/Height
  // is the encoded pixel size; the letterboxed layout inside the element uses
  // getBoundingClientRect for the visible box.
  function videoBox() {
    const rect = video.getBoundingClientRect();
    const vw = video.videoWidth || rect.width;
    const vh = video.videoHeight || rect.height;
    if (!vw || !vh) return null;
    // fit-to-contain: compute the shown image rect inside the element
    const scale = Math.min(rect.width / vw, rect.height / vh);
    const w = vw * scale, h = vh * scale;
    const x0 = rect.left + (rect.width - w) / 2;
    const y0 = rect.top + (rect.height - h) / 2;
    return { x0, y0, w, h, vw, vh };
  }
  function clientToPoint(cx, cy) {
    if (!deviceInfo) return null;
    const b = videoBox(); if (!b) return null;
    if (cx < b.x0 || cx > b.x0 + b.w || cy < b.y0 || cy > b.y0 + b.h) return null;
    // fraction inside the image → device points
    const fx = (cx - b.x0) / b.w, fy = (cy - b.y0) / b.h;
    return { x: fx * deviceInfo.point_width, y: fy * deviceInfo.point_height };
  }

  // ── input handling on the video ──
  overlay.addEventListener('pointerdown', e => {
    overlay.setPointerCapture(e.pointerId);
    dragStart = { x: e.clientX, y: e.clientY, t: Date.now() };
    overlay.focus();
  });
  overlay.addEventListener('pointerup', async e => {
    if (!dragStart) return;
    const s = dragStart; dragStart = null;
    const dx = e.clientX - s.x, dy = e.clientY - s.y;
    const dist = Math.hypot(dx, dy);
    try {
      if (dist < 6) {
        const p = clientToPoint(e.clientX, e.clientY); if (!p) return;
        await rpc('tap', { x: Math.round(p.x), y: Math.round(p.y) });
        setStatus(`tap (${Math.round(p.x)},${Math.round(p.y)})`, 'ok');
      } else {
        const p1 = clientToPoint(s.x, s.y), p2 = clientToPoint(e.clientX, e.clientY);
        if (!p1 || !p2) return;
        await rpc('swipe', {
          from_x: Math.round(p1.x), from_y: Math.round(p1.y),
          to_x:   Math.round(p2.x), to_y:   Math.round(p2.y),
          velocity: 'normal',
        });
        setStatus(`swipe → (${Math.round(p2.x)},${Math.round(p2.y)})`, 'ok');
      }
    } catch (err) { setStatus(err.message, 'err'); }
  });
  // Double-click → double_tap
  overlay.addEventListener('dblclick', async e => {
    const p = clientToPoint(e.clientX, e.clientY); if (!p) return;
    try { await rpc('double_tap', { x: Math.round(p.x), y: Math.round(p.y) }); setStatus(`double_tap`, 'ok'); }
    catch (err) { setStatus(err.message, 'err'); }
  });
  // Right-click → long_press
  overlay.addEventListener('contextmenu', async e => {
    e.preventDefault();
    const p = clientToPoint(e.clientX, e.clientY); if (!p) return;
    try { await rpc('long_press', { x: Math.round(p.x), y: Math.round(p.y) }); setStatus(`long_press`, 'ok'); }
    catch (err) { setStatus(err.message, 'err'); }
  });
  // Wheel → page or swipe. Trackpad up = feed moves down = swipe up gesture.
  let wheelAcc = 0, wheelTimer = null;
  overlay.addEventListener('wheel', e => {
    e.preventDefault();
    wheelAcc += e.deltaY;
    if (wheelTimer) clearTimeout(wheelTimer);
    wheelTimer = setTimeout(async () => {
      const acc = wheelAcc; wheelAcc = 0;
      if (Math.abs(acc) < 40) return;
      try {
        const dir = acc > 0 ? 'down' : 'up';
        await rpc('page', { direction: dir });
        setStatus(`page ${dir}`, 'ok');
      } catch (err) { setStatus(err.message, 'err'); }
    }, 100);
  }, { passive: false });
  // Keyboard → type. Enter → submit; printable char → type; Backspace → clear one char via clear_text is heavy — send a delete via type of \b? iCTRL clear_text empties the whole field; skip that on Backspace and let user use the Clear button.
  overlay.addEventListener('keydown', async e => {
    if (e.key === 'Enter') {
      e.preventDefault();
      try { await rpc('type', { text: '', submit: true }); setStatus('submit', 'ok'); } catch (err) { setStatus(err.message, 'err'); }
      return;
    }
    if (e.key.length === 1 && !e.metaKey && !e.ctrlKey && !e.altKey) {
      e.preventDefault();
      try { await rpc('type', { text: e.key }); setStatus(`type '${e.key}'`, 'ok'); } catch (err) { setStatus(err.message, 'err'); }
    }
  });

  // ── side-panel buttons ──
  document.querySelectorAll('[data-act]').forEach(btn => {
    btn.addEventListener('click', async () => {
      const act = btn.dataset.act;
      try {
        if (act === 'home') { await rpc('home'); setStatus('home', 'ok'); }
        else if (act === 'unlock') { await rpc('unlock'); setStatus('unlock', 'ok'); }
        else if (act === 'lock-confirm') {
          if (!confirm('Lock the phone?\nUnlocking may need the passcode entered on the device.')) return;
          await rpc('lock'); setStatus('lock', 'ok');
        }
        else if (act === 'screenshot') {
          const s = await rpc('screenshot', { scale: 1 });
          const a = document.createElement('a');
          a.href = 'data:image/png;base64,' + s.data;
          a.download = `ictrl-shot-${Date.now()}.png`;
          a.click();
          setStatus('screenshot saved', 'ok');
        }
        else if (act === 'open-app') {
          const name = prompt('App name to open:'); if (!name) return;
          setStatus(`resolving "${name}"…`);
          const r = await rpc('resolve_app', { text: name });
          const app = (r.apps || [])[0];
          if (!app) { setStatus(`no app "${name}"`, 'err'); return; }
          await rpc('launch_app', { bundle_id: app.bundle_id });
          setStatus(`opened ${app.name}`, 'ok');
        }
        else if (act === 'type-text') {
          const text = prompt('Text to type into the focused field:'); if (!text) return;
          const submit = confirm('Submit (press Return) after typing?');
          await rpc('type', { text, submit });
          setStatus(`type "${text}"` + (submit ? ' + submit' : ''), 'ok');
        }
        else if (act === 'clear-text') { await rpc('clear_text'); setStatus('clear_text', 'ok'); }
        else if (act === 'submit') { await rpc('type', { text: '', submit: true }); setStatus('submit', 'ok'); }
      } catch (err) { setStatus(err.message, 'err'); }
    });
  });
  // Direction pad: swipe from center of the video image.
  document.querySelectorAll('[data-nav]').forEach(btn => {
    btn.addEventListener('click', async () => {
      const dir = btn.dataset.nav;
      if (!deviceInfo) return setStatus('not connected', 'err');
      const w = deviceInfo.point_width, h = deviceInfo.point_height;
      const cx = w/2, cy = h/2, d = Math.min(w, h) * 0.35;
      const vec = { up: [0,-d], down: [0,d], left: [-d,0], right: [d,0], center: [0,0] }[dir];
      try {
        if (dir === 'center') {
          await rpc('tap', { x: Math.round(cx), y: Math.round(cy) });
          setStatus('tap center', 'ok');
        } else {
          await rpc('swipe', {
            from_x: Math.round(cx), from_y: Math.round(cy),
            to_x:   Math.round(cx + vec[0]), to_y: Math.round(cy + vec[1]),
            velocity: 'normal',
          });
          setStatus(`swipe ${dir}`, 'ok');
        }
      } catch (err) { setStatus(err.message, 'err'); }
    });
  });
  document.querySelectorAll('[data-page]').forEach(btn => {
    btn.addEventListener('click', async () => {
      try { await rpc('page', { direction: btn.dataset.page }); setStatus(`page ${btn.dataset.page}`, 'ok'); }
      catch (err) { setStatus(err.message, 'err'); }
    });
  });

  // ── connection lifecycle ──
  async function connect() {
    token = tokenInput.value.trim();
    if (!token) { setStatus('token required', 'err'); return; }
    setStatus('connecting…');
    // Prime device_info for coord conversion + title.
    try {
      deviceInfo = await rpc('device_info');
      updateHudDevice(deviceInfo);
      // Auth confirmed by a successful RPC — remember the token for next visit.
      try { localStorage.setItem(STORE_KEY, token); } catch (_) {}
    } catch (err) { setStatus('rpc: ' + err.message, 'err'); return; }

    // mpegts.js is bundled inline; this guards against an accidental strip.
    if (!window.mpegts) {
      setStatus('mpegts.js not available (bundle stripped?)', 'err');
      return;
    }
    if (!mpegts.isSupported()) {
      setStatus('mpegts.js not supported in this browser (needs MSE)', 'err');
      return;
    }

    const fps = fpsSel.value;
    const src = `/stream?token=${encodeURIComponent(token)}&fps=${fps}`;

    // NOTE: no preflight fetch — the /stream endpoint is a single-client-
    // per-connection push, so opening a second GET (even briefly) would
    // spin the encoder up/down and confuse the real player. Trust the
    // player's own error events instead.

    if (player) { try { player.destroy(); } catch(_){} player = null; }
    player = mpegts.createPlayer({ type: 'mpegts', isLive: true, url: src }, {
      // 2 fps is a very sparse stream — stashing helps mpegts.js batch
      // demux work; latency-chasing would fight it. Live-sync disabled
      // for the same reason (would seek past every idle gap).
      enableStashBuffer: true,
      stashInitialSize: 128,
      lazyLoad: false,
      liveBufferLatencyChasing: false,
      autoCleanupSourceBuffer: true,
    });
    // Surface mpegts / MSE errors so the user isn't stuck on a black screen.
    player.on(mpegts.Events.ERROR, (type, detail, info) => {
      console.error('mpegts error', type, detail, info);
      setStatus(`stream: ${type} ${detail||''}`, 'err');
    });
    player.on(mpegts.Events.MEDIA_INFO, (info) => {
      console.log('media info', info);
      setStatus(`streaming ${info.width||'?'}×${info.height||'?'}`, 'ok');
    });
    player.on(mpegts.Events.STATISTICS_INFO, (s) => {
      // First few chunks are useful to confirm data actually flows.
      if (s.decodedFrames < 3) console.log('mpegts stats', s);
    });
    video.addEventListener('error', () => {
      const e = video.error;
      if (e) setStatus(`video: ${e.code} ${e.message||''}`, 'err');
    }, { once: false });

    player.attachMediaElement(video);
    player.load();
    try { await video.play(); } catch (err) {
      setStatus('autoplay blocked — click the video', 'err');
    }
    connectBtn.disabled = true; stopBtn.disabled = false;
    setStatus('connected — waiting for first frame…', 'ok');
    overlay.focus();
  }
  function stop() {
    if (player) { try { player.destroy(); } catch(_){} player = null; }
    connectBtn.disabled = false; stopBtn.disabled = true;
    setStatus('stopped');
    hudDot.className = 'dot off';
  }
  connectBtn.addEventListener('click', connect);
  stopBtn.addEventListener('click', stop);
  // Changing FPS mid-stream: reconnect so the server sees the new ?fps=…
  // (broadcaster restarts the encoder at the new rate).
  fpsSel.addEventListener('change', () => {
    if (player) { setStatus(`switching to ${fpsSel.value} fps…`); connect(); }
  });

  // ── mobile drawer (FAB opens/closes the sidebar as a bottom sheet) ──
  const app = document.getElementById('app');
  const fab = document.getElementById('fab');
  const scrim = document.getElementById('scrim');
  const isMobile = () => window.matchMedia('(max-width: 720px)').matches;
  function openDrawer() { app.classList.add('open'); }
  function closeDrawer() { app.classList.remove('open'); }
  fab.addEventListener('click', () => app.classList.contains('open') ? closeDrawer() : openDrawer());
  scrim.addEventListener('click', closeDrawer);
  // Auto-close after tapping a control on mobile — keeps the video visible.
  document.querySelectorAll('aside [data-act], aside [data-nav], aside [data-page]').forEach(el => {
    el.addEventListener('click', () => { if (isMobile()) setTimeout(closeDrawer, 120); });
  });
  // Prevent the video overlay from stealing swipes over the drawer.
  document.addEventListener('keydown', e => { if (e.key === 'Escape') closeDrawer(); });

  // Auto-connect if a token was passed via ?token=
  if (token) queueMicrotask(connect);
})();
</script>
</body>
</html>
"""#
}
