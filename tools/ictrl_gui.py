#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""
iCTRL GUI — a minimal live viewer + input passthrough for the iCTRL phone
automation service.

Run with uv (gives a modern Python with Tk 8.6 — needed for base64-PNG decode):
    uv run tools/ictrl_gui.py --host <host:port> --token <token>
(uv reads the inline PEP 723 header above; no venv/deps setup needed.)

- Connect to an iCTRL host (host:port). The auth TOKEN is provided by the caller
  (a --token CLI arg or the token field in the UI) — this tool does NOT read the
  token cache file; per the iCTRL SKILL, the token lives at ~/.ictrl/token.json,
  so callers can pass it in, e.g.:
      /usr/bin/python3 tools/ictrl_gui.py --host <host:port> \\
          --token "$(python3 -c 'import json;print(json.load(open(__import__("os").path.expanduser("~/.ictrl/token.json")))["token"])')"
  If no token is given, use the "Authorize" button to grant one on the device.
- Poll the device screen at a fixed frame rate (default 1 Hz) and show it.
- Passthrough input:
    * left click            → tap        (pixel→point converted from screenshot)
    * left drag (press→move→release) → swipe
    * double click          → double_tap
    * right click           → long_press
    * keyboard typing        → type (into the currently-focused field on device)
    * Enter                  → submit
- Coordinate conversion is driven by the screenshot response, which reports the
  image's pixel size and the point-space to tap in (x = px / scale).

Zero third-party deps: uses only the Python standard library (tkinter + urllib).
Tkinter's PhotoImage decodes PNG natively on Tk 8.6+, so no Pillow is needed —
uv gives a Tk 8.6 Python; the macOS system Python
is Tk 8.5 and can't decode a base64 PNG.
"""

import argparse
import json
import os
import sys
import threading
import time

# uv's standalone Python ships Tcl/Tk under sys.base_prefix/lib but doesn't set
# TCL_LIBRARY/TK_LIBRARY in `uv run script` mode, so `import tkinter` fails with
# "Can't find a usable init.tcl". Point them at the bundled libs before import.
def _fix_tcl_tk_paths():
    lib = os.path.join(sys.base_prefix, "lib")
    for var, sub in (("TCL_LIBRARY", "tcl8.6"), ("TK_LIBRARY", "tk8.6")):
        if not os.environ.get(var):
            cand = os.path.join(lib, sub)
            if os.path.isdir(cand):
                os.environ[var] = cand
_fix_tcl_tk_paths()

import tkinter as tk
from tkinter import ttk, messagebox, simpledialog
import urllib.request
import urllib.error

# Generic default — not a specific device. Override with --host or the UI field.
DEFAULT_HOST = "127.0.0.1:8200"


# ─────────────────────────────────────────────────────────────────────────────
# iCTRL HTTP client
# ─────────────────────────────────────────────────────────────────────────────
class ICtrlClient:
    def __init__(self, host, token=None):
        self.base = f"http://{host}"
        self.host = host
        self.token = token  # supplied by the caller (CLI arg / UI field)
        self._id = 0
        # The frame loop (screenshot) and input handlers call this client from
        # different threads. The server processes one connection at a time, so
        # overlapping requests can interfere; serialize all HTTP on one lock.
        self._http_lock = threading.Lock()

    # --- low-level HTTP ---
    def _post(self, path, payload, timeout=30, auth=True):
        # allow_nan=False: never emit NaN/Infinity (invalid JSON) — a bad coordinate
        # would otherwise reach the server as `{"x": NaN}` and fail as a parse error.
        data = json.dumps(payload, allow_nan=False).encode("utf-8")
        headers = {"Content-Type": "application/json"}
        if auth and self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        req = urllib.request.Request(self.base + path, data=data, headers=headers, method="POST")
        try:
            with self._http_lock, urllib.request.urlopen(req, timeout=timeout) as r:
                return json.loads(r.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            # Non-2xx (e.g. 401) still carries a JSON-RPC error body — read it so
            # the real message ("Unauthorized", a timeout, …) surfaces instead of
            # a misleading generic/parse error.
            try:
                return json.loads(e.read().decode("utf-8"))
            except Exception:
                raise RuntimeError(f"HTTP {e.code} {e.reason}")

    def _get(self, path, timeout=10):
        with self._http_lock, urllib.request.urlopen(self.base + path, timeout=timeout) as r:
            return r.read()

    # --- lifecycle ---
    def probe(self, timeout=3):
        """Return True if the service answers on /schema."""
        try:
            self._get("/schema", timeout=timeout)
            return True
        except Exception:
            return False

    def authorize(self, client_name="iCTRL GUI", timeout=90):
        """Blocks until the user taps Allow on the device (up to `timeout`).
        Returns the granted token (caller decides whether to persist it)."""
        res = self._post("/auth", {"client_name": client_name}, timeout=timeout, auth=False)
        tok = res.get("token") or res.get("result", {}).get("token")
        if tok:
            self.token = tok
            return True
        return False

    def rpc(self, method, params=None, timeout=30):
        self._id += 1
        res = self._post("/rpc", {"jsonrpc": "2.0", "method": method,
                                  "params": params or {}, "id": self._id}, timeout=timeout)
        if "error" in res:
            raise RuntimeError(res["error"].get("message", str(res["error"])))
        return res.get("result", {})

    # --- convenience ---
    def token_valid(self):
        try:
            self.rpc("device_info", timeout=8)
            return True
        except Exception:
            return False

    def screenshot(self, scale=1):
        return self.rpc("screenshot", {"scale": scale}, timeout=20)

    def tap(self, x, y):
        return self.rpc("tap", {"x": round(x, 1), "y": round(y, 1)}, timeout=15)

    def double_tap(self, x, y):
        return self.rpc("double_tap", {"x": round(x, 1), "y": round(y, 1)}, timeout=15)

    def long_press(self, x, y, duration=0.8):
        return self.rpc("long_press", {"x": round(x, 1), "y": round(y, 1), "duration": duration}, timeout=15)

    def swipe(self, x1, y1, x2, y2):
        return self.rpc("swipe", {"from_x": round(x1, 1), "from_y": round(y1, 1),
                                  "to_x": round(x2, 1), "to_y": round(y2, 1),
                                  "velocity": "normal"}, timeout=15)

    def type_text(self, text, submit=False):
        return self.rpc("type", {"text": text, "submit": submit}, timeout=15)


# ─────────────────────────────────────────────────────────────────────────────
# GUI
# ─────────────────────────────────────────────────────────────────────────────
class App:
    def __init__(self, root, host=DEFAULT_HOST, token=""):
        self.root = root
        self.root.title("iCTRL GUI")
        self.init_host = host
        self.init_token = token or ""
        self.client = None
        self.running = False            # frame loop active
        self.poll_thread = None
        self._img = None                # keep a ref so Tk doesn't GC it

        # screenshot geometry (updated every frame)
        self.pix_w = self.pix_h = 0     # image pixels
        self.pt_w = self.pt_h = 0       # device points
        self.scale = 1.0                # image pixel / point
        self.disp_scale = 1.0           # canvas pixel / image pixel (fit-to-window)
        self.img_x0 = self.img_y0 = 0   # image offset within canvas

        self._drag_start = None         # (canvas_x, canvas_y) on press
        self._press_time = 0

        self._build_ui()

    # ---- UI construction ----
    def _build_ui(self):
        # Two-column layout: left = live screen, right = control panel.
        outer = ttk.Frame(self.root)
        outer.pack(fill="both", expand=True)

        left = ttk.Frame(outer)
        left.pack(side="left", fill="both", expand=True)
        right = ttk.Frame(outer, padding=8, width=220)
        right.pack(side="right", fill="y")
        right.pack_propagate(False)

        # ── LEFT: live screen ──
        self.canvas = tk.Canvas(left, bg="#111", width=320, height=640, highlightthickness=0)
        self.canvas.pack(fill="both", expand=True)
        self.canvas.bind("<ButtonPress-1>", self.on_press)
        self.canvas.bind("<B1-Motion>", self.on_motion)
        self.canvas.bind("<ButtonRelease-1>", self.on_release)
        self.canvas.bind("<Double-Button-1>", self.on_double)
        self.canvas.bind("<ButtonPress-3>", self.on_right)  # right = long press
        self.root.bind("<Key>", self.on_key)  # typing → device focused field

        # ── RIGHT: control panel ──
        # Connection
        conn = ttk.LabelFrame(right, text="Connection", padding=6)
        conn.pack(fill="x")
        ttk.Label(conn, text="Host").grid(row=0, column=0, sticky="w")
        self.host_var = tk.StringVar(value=self.init_host)
        ttk.Entry(conn, textvariable=self.host_var, width=18).grid(row=0, column=1, columnspan=2, sticky="we", pady=2)
        ttk.Label(conn, text="Token").grid(row=1, column=0, sticky="w")
        self.token_var = tk.StringVar(value=self.init_token)
        ttk.Entry(conn, textvariable=self.token_var, width=18, show="•").grid(row=1, column=1, columnspan=2, sticky="we", pady=2)
        self.connect_btn = ttk.Button(conn, text="Connect", command=self.on_connect)
        self.connect_btn.grid(row=2, column=0, columnspan=2, sticky="we", pady=(4, 0))
        self.stop_btn = ttk.Button(conn, text="Stop", command=self.stop, state="disabled")
        self.stop_btn.grid(row=2, column=2, sticky="we", pady=(4, 0))
        ttk.Button(conn, text="Authorize on device", command=self.on_authorize).grid(
            row=3, column=0, columnspan=3, sticky="we", pady=(2, 0))
        conn.columnconfigure(1, weight=1)

        # Stream settings
        strm = ttk.LabelFrame(right, text="Stream", padding=6)
        strm.pack(fill="x", pady=(8, 0))
        # Vertical layout so neither field gets clipped in the narrow panel.
        ttk.Label(strm, text="FPS").grid(row=0, column=0, sticky="w", pady=2)
        self.fps_var = tk.StringVar(value="1")
        ttk.Combobox(strm, textvariable=self.fps_var, width=6,
                     values=["0.5", "1", "2", "3", "5"]).grid(row=0, column=1, sticky="we", padx=4, pady=2)
        ttk.Label(strm, text="Quality").grid(row=1, column=0, sticky="w", pady=2)
        self.scale_var = tk.StringVar(value="2")  # full device resolution by default
        ttk.Combobox(strm, textvariable=self.scale_var, width=6,
                     values=["0.5", "1", "2", "3"]).grid(row=1, column=1, sticky="we", padx=4, pady=2)
        strm.columnconfigure(1, weight=1)

        # Device buttons
        dev = ttk.LabelFrame(right, text="Device", padding=6)
        dev.pack(fill="x", pady=(8, 0))
        buttons = [
            ("🏠 Home", lambda: self._send(lambda: self.client.rpc("home"), "home")),
            ("🔒 Lock", self._lock_confirm),  # needs confirmation
            ("🔓 Unlock", lambda: self._send(lambda: self.client.rpc("unlock"), "unlock")),
            ("📷 Shot", lambda: self._send(self._save_shot, "screenshot saved")),
        ]
        for i, (label, cmd) in enumerate(buttons):
            ttk.Button(dev, text=label, width=9, command=cmd).grid(
                row=i // 2, column=i % 2, sticky="we", padx=2, pady=2)
        ttk.Button(dev, text="📱 Open App…", command=self.on_open_app).grid(
            row=2, column=0, columnspan=2, sticky="we", padx=2, pady=2)
        dev.columnconfigure(0, weight=1); dev.columnconfigure(1, weight=1)

        # Direction pad (swipe-based) + paging
        nav = ttk.LabelFrame(right, text="Navigate (swipe)", padding=6)
        nav.pack(fill="x", pady=(8, 0))
        ttk.Button(nav, text="↑", width=4, command=lambda: self._swipe_dir("up")).grid(row=0, column=1, pady=1)
        ttk.Button(nav, text="←", width=4, command=lambda: self._swipe_dir("left")).grid(row=1, column=0, padx=1)
        ttk.Button(nav, text="•", width=4, command=self._center_tap).grid(row=1, column=1)
        ttk.Button(nav, text="→", width=4, command=lambda: self._swipe_dir("right")).grid(row=1, column=2, padx=1)
        ttk.Button(nav, text="↓", width=4, command=lambda: self._swipe_dir("down")).grid(row=2, column=1, pady=1)
        for c in range(3):
            nav.columnconfigure(c, weight=1)
        pg = ttk.Frame(nav)
        pg.grid(row=3, column=0, columnspan=3, sticky="we", pady=(4, 0))
        ttk.Button(pg, text="⇞ PgUp", command=lambda: self._page("up")).pack(side="left", expand=True, fill="x", padx=1)
        ttk.Button(pg, text="⇟ PgDn", command=lambda: self._page("down")).pack(side="left", expand=True, fill="x", padx=1)

        # Text actions
        txt = ttk.LabelFrame(right, text="Text", padding=6)
        txt.pack(fill="x", pady=(8, 0))
        ttk.Button(txt, text="⌨️ Type text…", command=self.on_type_text).pack(fill="x", pady=1)
        self.submit_after_var = tk.BooleanVar(value=True)
        ttk.Checkbutton(txt, text="Submit after typing", variable=self.submit_after_var).pack(anchor="w", pady=1)
        ttk.Button(txt, text="⌫ Clear field", command=lambda: self._send(
            lambda: self.client.rpc("clear_text"), "clear_text")).pack(fill="x", pady=1)
        ttk.Button(txt, text="⏎ Submit", command=lambda: self._send(
            lambda: self.client.type_text("", submit=True), "submit")).pack(fill="x", pady=1)

        # Status (bottom of panel)
        self.status = tk.StringVar(value="Idle")
        ttk.Label(right, textvariable=self.status, foreground="#0a7", wraplength=200).pack(
            side="bottom", fill="x", pady=(8, 0))
        ttk.Label(right, text="click=tap · drag=swipe · dbl=double · right=long-press",
                  foreground="#888", wraplength=200).pack(side="bottom", fill="x")

    # ---- connection ----
    def on_connect(self):
        host = self.host_var.get().strip()
        if not host:
            return
        token = self.token_var.get().strip()
        self.client = ICtrlClient(host, token=token or None)
        self.set_status("Connecting…", "#fa0")
        threading.Thread(target=self._connect_worker, daemon=True).start()

    def _connect_worker(self):
        c = self.client
        if not c.probe():
            self.set_status("Not reachable (is the runner up?)", "#f33")
            return
        # Use the caller-supplied token. If it's missing or rejected, tell the
        # user to Authorize — we never read the token cache file ourselves.
        if not c.token:
            self.set_status("No token — press Authorize (or pass --token)", "#fa0")
            return
        if not c.token_valid():
            self.set_status("Token invalid/expired — press Authorize", "#f33")
            return
        self.set_status("Connected", "#0a7")
        # Show the device name in the window title.
        try:
            info = c.rpc("device_info", timeout=8)
            name = info.get("device_name") or info.get("name")
            if name:
                self.root.after(0, lambda: self.root.title(f"iCTRL GUI — {name}"))
        except Exception:
            pass
        self.running = True
        self.root.after(0, lambda: self.stop_btn.config(state="normal"))
        self.root.after(0, lambda: self.connect_btn.config(state="disabled"))
        self.poll_thread = threading.Thread(target=self._frame_loop, daemon=True)
        self.poll_thread.start()

    def on_authorize(self):
        """Grant a fresh token on the device (blocks until the user taps Allow).
        The token is put into the field; the caller can copy/persist it."""
        host = self.host_var.get().strip()
        if not host:
            return
        client = ICtrlClient(host)
        self.set_status("Authorize on device (tap Allow)…", "#fa0")

        def worker():
            try:
                if client.authorize():
                    self.root.after(0, lambda: self.token_var.set(client.token))
                    self.set_status("Authorized — token filled in, press Connect", "#0a7")
                else:
                    self.set_status("Authorization denied", "#f33")
            except Exception as e:
                self.set_status(f"Auth failed: {e}", "#f33")

        threading.Thread(target=worker, daemon=True).start()

    def stop(self):
        self.running = False
        self.stop_btn.config(state="disabled")
        self.connect_btn.config(state="normal")
        self.set_status("Stopped", "#888")
        self.root.title("iCTRL GUI")

    # ---- frame loop (fixed rate) ----
    def _frame_loop(self):
        while self.running:
            t0 = time.time()
            try:
                fps = float(self.fps_var.get() or "1")
            except ValueError:
                fps = 1.0
            period = 1.0 / max(0.1, fps)
            try:
                sc = float(self.scale_var.get() or "1")
                shot = self.client.screenshot(scale=sc)
                self._on_frame(shot)
            except Exception as e:
                self.set_status(f"frame error: {e}", "#f33")
            # sleep to hold the target rate
            dt = time.time() - t0
            time.sleep(max(0.0, period - dt))

    def _on_frame(self, shot):
        # update geometry from the response (authoritative conversion info)
        self.pix_w = float(shot.get("pixel_width", shot.get("width", 0)))
        self.pix_h = float(shot.get("pixel_height", shot.get("height", 0)))
        self.pt_w = float(shot.get("point_width", shot.get("width", 0)))
        self.pt_h = float(shot.get("point_height", shot.get("height", 0)))
        self.scale = float(shot.get("scale", 1.0)) or 1.0
        b64 = shot.get("data", "")
        if not b64:
            return
        # Render with tkinter's native PhotoImage (Tk 8.6 decodes base64 PNG). We
        # deliberately DON'T use Pillow's ImageTk here: under uv's standalone
        # Python its _imagingtk C extension isn't registered with our Tk
        # ("invalid command name PyImagingPhoto"), so ImageTk.PhotoImage fails.
        self.root.after(0, lambda: self._render(b64))

    def _render(self, b64):
        try:
            img = tk.PhotoImage(data=b64)
        except Exception as e:
            self.set_status(f"decode error: {e}", "#f33")
            return
        # winfo_width() is 1 (not 0) before the canvas is laid out — guard with a
        # threshold, else scaling collapses and the image renders ~invisible.
        cw = self.canvas.winfo_width()
        ch = self.canvas.winfo_height()
        if cw <= 1: cw = img.width()
        if ch <= 1: ch = img.height()
        # Fit-to-window with integer subsampling (PhotoImage only scales by whole
        # factors). Quality=2 gives a full-res source so the down-scaled result is
        # still crisp.
        factor = 1
        while (img.width() // (factor + 1)) >= 1 and (
                img.width() / factor > cw or img.height() / factor > ch):
            factor += 1
        img = img.subsample(factor) if factor > 1 else img
        dw, dh = img.width(), img.height()
        self._img = img
        # canvas px per IMAGE pixel = 1/factor (subsample shrinks by whole factors)
        self.disp_scale = 1.0 / factor
        self.img_x0 = max(0, (cw - dw) // 2)
        self.img_y0 = max(0, (ch - dh) // 2)
        self.canvas.delete("all")
        self.canvas.create_image(self.img_x0, self.img_y0, anchor="nw", image=self._img)

    # ---- coordinate conversion: canvas → device points ----
    def canvas_to_point(self, cx, cy):
        """Map a canvas pixel to a device TAP POINT.
        canvas px → image px (÷disp_scale) → device point (÷scale)."""
        if self.disp_scale <= 0 or self.scale <= 0:
            return None
        img_px = (cx - self.img_x0) / self.disp_scale
        img_py = (cy - self.img_y0) / self.disp_scale
        # clamp to image bounds
        if not (0 <= img_px <= self.pix_w and 0 <= img_py <= self.pix_h):
            return None
        x_pt = img_px / self.scale
        y_pt = img_py / self.scale
        return (x_pt, y_pt)

    # ---- mouse handlers ----
    def on_press(self, e):
        self._drag_start = (e.x, e.y)
        self._press_time = time.time()

    def on_motion(self, e):
        pass  # drag tracked on release

    def on_release(self, e):
        if not self._drag_start or not self.client:
            return
        sx, sy = self._drag_start
        self._drag_start = None
        dist = ((e.x - sx) ** 2 + (e.y - sy) ** 2) ** 0.5
        p1 = self.canvas_to_point(sx, sy)
        p2 = self.canvas_to_point(e.x, e.y)
        if p1 is None:
            return
        if dist < 8:  # treat as a tap
            self._send(lambda: self.client.tap(*p1), f"tap ({p1[0]:.0f},{p1[1]:.0f})")
        elif p2 is not None:  # swipe
            self._send(lambda: self.client.swipe(p1[0], p1[1], p2[0], p2[1]),
                       f"swipe →({p2[0]:.0f},{p2[1]:.0f})")

    def on_double(self, e):
        p = self.canvas_to_point(e.x, e.y)
        if p and self.client:
            self._send(lambda: self.client.double_tap(*p), f"double_tap ({p[0]:.0f},{p[1]:.0f})")

    def on_right(self, e):
        p = self.canvas_to_point(e.x, e.y)
        if p and self.client:
            self._send(lambda: self.client.long_press(*p), f"long_press ({p[0]:.0f},{p[1]:.0f})")

    # ---- keyboard handler ----
    def on_key(self, e):
        if not self.client or not self.running:
            return
        # Enter → submit; printable chars → type; ignore modifiers/navigation.
        if e.keysym in ("Return", "KP_Enter"):
            self._send(lambda: self.client.type_text("", submit=True), "submit")
        elif e.char and e.char.isprintable() and len(e.char) == 1:
            ch = e.char
            self._send(lambda: self.client.type_text(ch), f"type '{ch}'")

    # ---- right-panel actions ----
    def _guard(self):
        """Return True if connected; else set a status hint."""
        if not self.client or not self.running:
            self.set_status("Connect first", "#fa0")
            return False
        return True

    def _swipe_dir(self, direction):
        """Direction pad: swipe across the middle of the screen. On a phone this
        is the natural 'arrow key' — a directional scroll/navigation gesture."""
        if not self._guard():
            return
        w, h = self.pt_w or 390, self.pt_h or 844
        cx, cy = w / 2, h / 2
        d = min(w, h) * 0.35  # travel distance in points
        vec = {"up": (0, -d), "down": (0, d), "left": (-d, 0), "right": (d, 0)}[direction]
        # Swiping content up means dragging the finger downward, etc. We map the
        # arrow to the finger travel direction directly (arrow ↑ = swipe upward).
        x2, y2 = cx + vec[0], cy + vec[1]
        self._send(lambda: self.client.swipe(cx, cy, x2, y2), f"swipe {direction}")

    def _lock_confirm(self):
        """Lock the device — requires an explicit confirmation, since locking
        interrupts the session (and can require a passcode to get back in)."""
        if not self._guard():
            return
        if messagebox.askyesno("Lock device?",
                               "Lock the phone now?\n\nThis ends the current view; "
                               "unlocking again may need the passcode entered on the device."):
            self._send(lambda: self.client.rpc("lock"), "lock")

    def on_open_app(self):
        """Prompt for an app name, resolve it to a bundle_id (resolve_app), then
        launch it (launch_app)."""
        if not self._guard():
            return
        name = simpledialog.askstring("Open App", "App name to open:", parent=self.root)
        if not name:
            return

        def worker():
            try:
                self.set_status(f"resolving “{name}”…", "#fa0")
                res = self.client.rpc("resolve_app", {"text": name}, timeout=20)
                apps = res.get("apps") or []
                if not apps:
                    self.set_status(f"no app found for “{name}”", "#f33")
                    return
                bid = apps[0].get("bundle_id")
                disp = apps[0].get("name", name)
                if not bid:
                    self.set_status(f"no bundle_id for “{name}”", "#f33")
                    return
                self.set_status(f"launching {disp} ({bid})…", "#fa0")
                self.client.rpc("launch_app", {"bundle_id": bid}, timeout=20)
                self.set_status(f"opened {disp}", "#0a7")
            except Exception as e:
                self.set_status(f"open app failed: {e}", "#f33")

        threading.Thread(target=worker, daemon=True).start()

    def on_type_text(self):
        """Prompt for a string and type it into the device's focused field.
        Tap a text field on the screen first so it has keyboard focus."""
        if not self._guard():
            return
        text = simpledialog.askstring("Type text", "Text to type into the focused field:",
                                      parent=self.root)
        if not text:  # cancelled or empty
            return
        submit = self.submit_after_var.get()
        self._send(lambda: self.client.type_text(text, submit=submit),
                   f"type {text!r}" + (" + submit" if submit else ""))

    def _page(self, direction):
        if not self._guard():
            return
        self._send(lambda: self.client.rpc("page", {"direction": direction}), f"page {direction}")

    def _center_tap(self):
        if not self._guard():
            return
        w, h = self.pt_w or 390, self.pt_h or 844
        self._send(lambda: self.client.tap(w / 2, h / 2), "tap center")

    def _save_shot(self):
        """Fetch one screenshot and write it to a PNG next to the tool."""
        import base64
        shot = self.client.screenshot(scale=1)
        data = base64.b64decode(shot["data"])
        path = os.path.join(os.getcwd(), f"ictrl-shot-{int(time.time())}.png")
        with open(path, "wb") as f:
            f.write(data)
        return path  # shown in status by _send wrapper

    # ---- async send with status ----
    def _send(self, fn, label):
        def worker():
            try:
                fn()
                self.set_status(label, "#0a7")
            except Exception as ex:
                self.set_status(f"{label} failed: {ex}", "#f33")
        threading.Thread(target=worker, daemon=True).start()

    def set_status(self, text, color="#0a7"):
        self.root.after(0, lambda: (self.status.set(text),
                                    self.root.nametowidget(".").update_idletasks()))
        try:
            self.root.after(0, lambda: self.status.set(text))
        except Exception:
            pass


def main():
    ap = argparse.ArgumentParser(description="iCTRL live viewer + input passthrough")
    ap.add_argument("--host", default=DEFAULT_HOST, help="iCTRL host:port (default %(default)s)")
    ap.add_argument("--token", default="", help="auth token (from ~/.ictrl/token.json per the SKILL)")
    args = ap.parse_args()

    root = tk.Tk()
    if root.tk.call("info", "patchlevel").split(".")[:2] < ["8", "6"]:
        # Tk 8.5 can't decode base64 PNG and renders ttk poorly. uv gives 8.6.
        import sys
        print("iCTRL GUI needs Tk >= 8.6 — run it with uv:  uv run tools/ictrl_gui.py",
              file=sys.stderr)
    # Size for both columns up front: a portrait phone canvas (~360) + the
    # 240-wide control panel, so it's usable without dragging. Enforce a minimum.
    root.geometry("620x820")
    root.minsize(520, 640)
    App(root, host=args.host, token=args.token)
    root.mainloop()


if __name__ == "__main__":
    main()
