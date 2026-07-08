#!/usr/bin/env python3
"""
iCTRL GUI — a minimal live viewer + input passthrough for the iCTRL phone
automation service.

- Connect to an iCTRL host (host:port). The auth TOKEN is provided by the caller
  (a --token CLI arg or the token field in the UI) — this tool does NOT read the
  token cache file; per the iCTRL SKILL, the token lives at ~/.ictrl/token.json,
  so callers can pass it in, e.g.:
      /usr/bin/python3 tools/ictrl_gui.py --host 10.1.1.43:8200 \\
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
Tkinter's PhotoImage decodes PNG natively (Tk 8.6+), so no Pillow needed.

Run with a Python that has tkinter, e.g. the macOS system Python:
    /usr/bin/python3 tools/ictrl_gui.py --host <host:port> --token <token>
"""

import argparse
import json
import threading
import time
import tkinter as tk
from tkinter import ttk
import urllib.request
import urllib.error

DEFAULT_HOST = "10.1.1.43:8200"


# ─────────────────────────────────────────────────────────────────────────────
# iCTRL HTTP client
# ─────────────────────────────────────────────────────────────────────────────
class ICtrlClient:
    def __init__(self, host, token=None):
        self.base = f"http://{host}"
        self.host = host
        self.token = token  # supplied by the caller (CLI arg / UI field)
        self._id = 0

    # --- low-level HTTP ---
    def _post(self, path, payload, timeout=30, auth=True):
        data = json.dumps(payload).encode("utf-8")
        headers = {"Content-Type": "application/json"}
        if auth and self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        req = urllib.request.Request(self.base + path, data=data, headers=headers, method="POST")
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode("utf-8"))

    def _get(self, path, timeout=10):
        with urllib.request.urlopen(self.base + path, timeout=timeout) as r:
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
        top = ttk.Frame(self.root, padding=6)
        top.pack(fill="x")

        ttk.Label(top, text="Host:").pack(side="left")
        self.host_var = tk.StringVar(value=self.init_host)
        ttk.Entry(top, textvariable=self.host_var, width=18).pack(side="left", padx=(2, 8))

        ttk.Label(top, text="FPS:").pack(side="left")
        self.fps_var = tk.StringVar(value="1")
        ttk.Combobox(top, textvariable=self.fps_var, width=4,
                     values=["0.5", "1", "2", "3", "5"]).pack(side="left", padx=(2, 8))

        ttk.Label(top, text="Quality:").pack(side="left")
        self.scale_var = tk.StringVar(value="1")
        ttk.Combobox(top, textvariable=self.scale_var, width=4,
                     values=["0.5", "1", "2"]).pack(side="left", padx=(2, 8))

        self.connect_btn = ttk.Button(top, text="Connect", command=self.on_connect)
        self.connect_btn.pack(side="left", padx=4)
        self.stop_btn = ttk.Button(top, text="Stop", command=self.stop, state="disabled")
        self.stop_btn.pack(side="left", padx=4)

        self.status = tk.StringVar(value="Idle")
        ttk.Label(top, textvariable=self.status, foreground="#0a7").pack(side="left", padx=10)

        # token row — the caller supplies the token (CLI/UI); we don't read the
        # cache file. Leave blank + press Authorize to grant one on the device.
        row2 = ttk.Frame(self.root, padding=(6, 0, 6, 6))
        row2.pack(fill="x")
        ttk.Label(row2, text="Token:").pack(side="left")
        self.token_var = tk.StringVar(value=self.init_token)
        ttk.Entry(row2, textvariable=self.token_var, width=42, show="•").pack(side="left", padx=(2, 8))
        ttk.Button(row2, text="Authorize", command=self.on_authorize).pack(side="left", padx=4)

        # canvas for the live screen
        self.canvas = tk.Canvas(self.root, bg="#111", width=320, height=640,
                                highlightthickness=0)
        self.canvas.pack(fill="both", expand=True)
        self.canvas.bind("<ButtonPress-1>", self.on_press)
        self.canvas.bind("<B1-Motion>", self.on_motion)
        self.canvas.bind("<ButtonRelease-1>", self.on_release)
        self.canvas.bind("<Double-Button-1>", self.on_double)
        self.canvas.bind("<ButtonPress-3>", self.on_right)  # right = long press

        # keyboard: send typed characters to the device's focused field
        self.root.bind("<Key>", self.on_key)

        # footer hint
        hint = ("Left-click = tap · drag = swipe · double-click = double_tap · "
                "right-click = long_press · type = send to focused field · Enter = submit")
        ttk.Label(self.root, text=hint, padding=4, foreground="#888").pack(fill="x")

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
        # decode on the Tk thread
        self.root.after(0, lambda: self._render(b64))

    def _render(self, b64):
        try:
            img = tk.PhotoImage(data=b64)  # Tk 8.6 decodes base64 PNG directly
        except Exception as e:
            self.set_status(f"decode error: {e}", "#f33")
            return
        cw = self.canvas.winfo_width() or img.width()
        ch = self.canvas.winfo_height() or img.height()
        # fit-to-window by integer subsampling (PhotoImage can't upscale cheaply)
        factor = 1
        while (img.width() // (factor + 1)) >= 1 and (
                img.width() / factor > cw or img.height() / factor > ch):
            factor += 1
        shown = img.subsample(factor) if factor > 1 else img
        self.disp_scale = shown.width() / img.width()  # canvas px per image px
        self._img = shown
        self.img_x0 = max(0, (cw - shown.width()) // 2)
        self.img_y0 = max(0, (ch - shown.height()) // 2)
        self.canvas.delete("all")
        self.canvas.create_image(self.img_x0, self.img_y0, anchor="nw", image=shown)

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
    root.geometry("380x780")
    App(root, host=args.host, token=args.token)
    root.mainloop()


if __name__ == "__main__":
    main()
