#!/usr/bin/env python3
"""iCTRL client — pairing + encrypted-envelope JSON-RPC (protocol v1).

All request-path crypto is HMAC-SHA256 only, so this is portable to any language
with an HMAC primitive. X25519 appears only in LAN pairing (mode A).

Usage:
    ./ictrl_rpc.py --host 10.0.0.5:8200 pair --name my-laptop
    ./ictrl_rpc.py --host 10.0.0.5:8200 call device_info
    ./ictrl_rpc.py --host 10.0.0.5:8200 call tap '{"x":100,"y":200}'
    ./ictrl_rpc.py --host 10.0.0.5:8200 shot out.jpg          # JPEG by default

Nearby (macOS, no shared network needed; the phone has Nearby Discovery on):
    ./ictrl_rpc.py scan                                       # list nearby devices
    ./ictrl_rpc.py --nearby "iPhone 15 (7f3a)" call device_info
    ./ictrl_rpc.py --nearby 7f3a shot out.jpg                 # name or id prefix

The token is cached at ~/.ictrl/token.json keyed by host (or by device id for
nearby devices), so pairing is a one-time step per device. With --nearby it
happens automatically on first use: approve the prompt on the phone once.

Two notes for anything that moves a lot of data (server 1.5.0+):

  screenshot defaults to JPEG. The whole response body is decrypted through the
  envelope keystream, so response size — not device capture time — is what
  dominates a screenshot. A JPEG is several times smaller than the equivalent
  PNG; ask for {"format":"png"} only when you need lossless output.

  If UI calls start timing out and the log shows kAXErrorServerNotFound, the
  accessibility connection has dropped. Call `reset`, then launch_app the target
  app. device_info / logs / config keep working throughout — they run off the UI
  queue — so use them to diagnose while UI methods are blocked.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import http.client
import json
import os
import secrets
import select
import socket
import sys
import time
import urllib.error
import urllib.request

STORE = os.path.expanduser("~/.ictrl/token.json")

LABEL_MAC = b"ictrl-v1|mac"
LABEL_ENC_REQ = b"ictrl-v1|enc-req"
LABEL_ENC_RESP = b"ictrl-v1|enc-resp"
LABEL_PAIR = b"ictrl-pair"
LABEL_WRAP = b"ictrl-wrap"


def _hmac(key: bytes, data: bytes) -> bytes:
    return hmac.new(key, data, hashlib.sha256).digest()


def _keystream_xor(key: bytes, nonce: bytes, data: bytes) -> bytes:
    """PRF-CTR: keystream_i = HMAC(key, nonce || be32(i)).

    Both halves are written for bulk data, because a screenshot response runs
    entirely through here and a naive version dominates its end-to-end time:

    1. The HMAC inner/outer pads depend only on the key, so they're computed once
       and `.copy()`-ed per block. `hmac.new()` in the loop would re-absorb the
       key for every 32-byte block — tens of thousands of times on one image.
    2. The XOR goes through Python's big integers, whose C implementation beats a
       per-byte `zip()` comprehension by an order of magnitude.

    Prefer `format="jpeg"` on screenshot (the default since server 1.5.0): a
    smaller response is the real fix — this loop is merely no longer the
    bottleneck.
    """
    block = key.ljust(64, b"\0") if len(key) <= 64 else hashlib.sha256(key).digest().ljust(64, b"\0")
    inner = hashlib.sha256(bytes(b ^ 0x36 for b in block))
    outer = hashlib.sha256(bytes(b ^ 0x5C for b in block))

    out = bytearray()
    counter = 0
    while len(out) < len(data):
        i = inner.copy()
        i.update(nonce + counter.to_bytes(4, "big"))
        o = outer.copy()
        o.update(i.digest())
        out += o.digest()
        counter += 1

    n = len(data)
    if n == 0:
        return b""
    return (int.from_bytes(data, "big") ^ int.from_bytes(bytes(out[:n]), "big")).to_bytes(n, "big")


class _ZonedHTTPConnection(http.client.HTTPConnection):
    """Dial a zoned link-local IPv6 host ("fe80::1%awdl0") with the socket bound
    to that interface; macOS does not route to a peer-to-peer (AWDL) peer
    otherwise. Every other host connects as usual."""

    def connect(self):
        host = self.host.strip("[]")
        if "%" not in host:
            return super().connect()
        addr, zone = host.split("%", 1)
        index = socket.if_nametoindex(zone)
        sock = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
        sock.setsockopt(socket.IPPROTO_IPV6, _IPV6_BOUND_IF, index)
        sock.settimeout(self.timeout)
        sock.connect((addr, self.port, 0, index))
        self.sock = sock


class _ZonedHandler(urllib.request.HTTPHandler):
    def http_open(self, req):
        return self.do_open(_ZonedHTTPConnection, req)


_IPV6_BOUND_IF = 125            # <netinet6/in6.h>, macOS
_opener = urllib.request.build_opener(_ZonedHandler)


def _post(url: str, obj: dict, timeout: float) -> tuple[int, dict]:
    body = json.dumps(obj).encode()
    req = urllib.request.Request(url, data=body,
                                 headers={"Content-Type": "application/json"})
    try:
        with _opener.open(req, timeout=timeout) as resp:
            return resp.status, json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as e:
        raw = e.read() or b"{}"
        try:
            return e.code, json.loads(raw)
        except json.JSONDecodeError:
            return e.code, {"error": {"message": raw.decode("utf-8", "replace")}}


# ---------------------------------------------------------------- token store
#
# The store is a map of "host:port" -> record, so keys for several devices live
# side by side and can be used concurrently. Stores written by the pre-v1
# plaintext-token client had their single record flattened at the top level
# ("host"/"token"/…); those entries carry no key material and are ignored.


def _is_record(value) -> bool:
    """A usable v1 entry: a dict carrying the 32-byte key and its id."""
    return isinstance(value, dict) and "key" in value and "tok" in value


def load_token(host: str) -> dict | None:
    try:
        with open(STORE) as fh:
            entry = json.load(fh).get(host)
    except (OSError, json.JSONDecodeError, AttributeError):
        return None
    return entry if _is_record(entry) else None


def list_hosts() -> dict:
    """Every device with a usable key, keyed by host:port."""
    try:
        with open(STORE) as fh:
            return {h: r for h, r in json.load(fh).items() if _is_record(r)}
    except (OSError, json.JSONDecodeError, AttributeError):
        return {}


def save_token(host: str, record: dict) -> None:
    os.makedirs(os.path.dirname(STORE), exist_ok=True)
    # Drop legacy/plaintext leftovers rather than carrying them forward, so the
    # file stays a clean host -> record map.
    all_tokens = list_hosts()
    all_tokens[host] = record
    with open(STORE, "w") as fh:
        json.dump(all_tokens, fh, indent=2)
    os.chmod(STORE, 0o600)


# --------------------------------------------------------------------- nearby
#
# Nearby discovery: the phone advertises "_ictrl._tcp" over Apple peer-to-peer
# Wi-Fi (AWDL) only, with TXT "v" (protocol) and "id" (stable device id). macOS
# only, through the system dns_sd API (ctypes, standard library). The address
# is link-local and changes, so devices are keyed by id and re-resolved; a
# short-lived cache spares the lookup on back-to-back calls.

NEARBY_CACHE = os.path.expanduser("~/.ictrl/nearby_cache.json")
NEARBY_CACHE_TTL = 120          # seconds
_DNSSD_FLAGS = 0x100000 | 0x20000   # kDNSServiceFlagsIncludeAWDL | IncludeP2P


def _txt(raw: bytes) -> dict:
    out, i = {}, 0
    while i < len(raw):
        n = raw[i]
        k, _, v = raw[i + 1:i + 1 + n].decode("utf-8", "replace").partition("=")
        out[k] = v
        i += 1 + n
    return out


def nearby_scan(wait: float = 3.0, want=None) -> list[dict]:
    """Browse AWDL for iCTRL devices; each result is {name, id, host}.

    Stops early once `want(device)` is true; otherwise collects for `wait` s.
    """
    if sys.platform != "darwin":
        raise SystemExit("nearby discovery needs macOS (Apple peer-to-peer Wi-Fi)")
    import ctypes
    lib = ctypes.CDLL("/usr/lib/system/libsystem_dnssd.dylib")
    lib.DNSServiceRefSockFD.restype = ctypes.c_int
    awdl = socket.if_nametoindex("awdl0") if hasattr(socket, "if_nametoindex") else 0
    if not awdl:
        raise SystemExit("no awdl0 interface — is Wi-Fi turned on?")
    ref_t = ctypes.c_void_p
    browse_t = ctypes.CFUNCTYPE(None, ref_t, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_int32,
                                ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p)
    resolve_t = ctypes.CFUNCTYPE(None, ref_t, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_int32,
                                 ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint16, ctypes.c_uint16,
                                 ctypes.c_void_p, ctypes.c_void_p)
    addr_t = ctypes.CFUNCTYPE(None, ref_t, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_int32,
                              ctypes.c_char_p, ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p)
    refs, found, devices, keep = [], {}, [], []

    def on_addr(_r, _f, _i, err, _h, sa, _ttl, ctx):
        dev = found.get(ctx)
        if err or not sa or not dev or dev.get("host"):
            return
        raw = ctypes.string_at(sa, 28)                      # sockaddr_in6
        if raw[1] == socket.AF_INET6:
            addr = socket.inet_ntop(socket.AF_INET6, raw[8:24])
            dev["host"] = f"[{addr}%awdl0]:{dev.pop('port')}"
            devices.append(dev)

    def on_resolve(_r, _f, _i, err, _full, target, port, txt_len, txt, ctx):
        dev = found.get(ctx)
        if err or not dev or "port" in dev or dev.get("host"):
            return
        info = _txt(ctypes.string_at(txt, txt_len)) if txt_len else {}
        dev.update(id=info.get("id", ""), v=info.get("v", ""), port=socket.ntohs(port))
        ref = ref_t()
        if lib.DNSServiceGetAddrInfo(ctypes.byref(ref), _DNSSD_FLAGS, awdl, 2, target,
                                     cb_addr, ctypes.c_void_p(ctx)) == 0:
            refs.append(ref)

    def on_browse(_r, flags, ifi, err, name, typ, dom, _ctx):
        if err or not flags & 0x2 or ifi != awdl:          # kDNSServiceFlagsAdd, AWDL only
            return
        ctx = len(found) + 1
        found[ctx] = {"name": name.decode("utf-8", "replace")}
        ref = ref_t()
        if lib.DNSServiceResolve(ctypes.byref(ref), _DNSSD_FLAGS, awdl, name, typ, dom,
                                 cb_resolve, ctypes.c_void_p(ctx)) == 0:
            refs.append(ref)

    cb_browse, cb_resolve, cb_addr = browse_t(on_browse), resolve_t(on_resolve), addr_t(on_addr)
    keep += [cb_browse, cb_resolve, cb_addr]
    browse = ref_t()
    if lib.DNSServiceBrowse(ctypes.byref(browse), _DNSSD_FLAGS, 0, b"_ictrl._tcp", None,
                            cb_browse, None) != 0:
        raise SystemExit("DNSServiceBrowse failed")
    refs.append(browse)
    deadline = time.time() + wait
    try:
        while time.time() < deadline:
            if want and any(want(d) for d in devices):
                break
            fds = {lib.DNSServiceRefSockFD(r): r for r in refs}
            ready, _, _ = select.select(list(fds), [], [], max(0.0, min(0.25, deadline - time.time())))
            for fd in ready:
                lib.DNSServiceProcessResult(fds[fd])
    finally:
        for r in refs:
            lib.DNSServiceRefDeallocate(r)
    return sorted(devices, key=lambda d: d["name"].lower())


def _nearby_cache(update: dict | None = None) -> dict:
    try:
        with open(NEARBY_CACHE) as fh:
            cache = json.load(fh)
    except (OSError, json.JSONDecodeError):
        cache = {}
    if update is not None:
        cache.update(update)
        os.makedirs(os.path.dirname(NEARBY_CACHE), exist_ok=True)
        with open(NEARBY_CACHE, "w") as fh:
            json.dump(cache, fh)
    return cache


def _matches(dev: dict, query: str) -> bool:
    q = query.lower()
    return dev["name"].lower() == q or (len(q) >= 4 and dev.get("id", "").startswith(q))


def nearby_target(query: str, fresh: bool = False) -> tuple[str, str, str]:
    """Resolve a nearby device by name or id prefix -> (store key, host, name)."""
    if not fresh:
        now = time.time()
        for dev_id, ent in _nearby_cache().items():
            if now - ent.get("ts", 0) < NEARBY_CACHE_TTL and _matches({"id": dev_id, **ent}, query):
                return f"nearby:{dev_id}", ent["host"], ent["name"]
    devices = nearby_scan(wait=6.0, want=lambda d: _matches(d, query))
    hits = [d for d in devices if _matches(d, query)]
    if not hits:
        raise SystemExit(f"no nearby device matches {query!r} — run `scan`; "
                         "is Nearby Discovery on (long-press the iCTRL notification)?")
    if len({d["id"] for d in hits}) > 1:
        raise SystemExit(f"{query!r} matches several devices; use the id: "
                         + ", ".join(f"{d['name']} ({d['id'][:8]})" for d in hits))
    dev = hits[0]
    _nearby_cache({dev["id"]: {"name": dev["name"], "host": dev["host"], "ts": time.time()}})
    return f"nearby:{dev['id']}", dev["host"], dev["name"]


def nearby_call(query: str, method: str, params: dict | None, client_name: str) -> dict:
    """Call a nearby device; pairs on first use (the user approves on the phone)
    and re-resolves once if the cached address has gone stale."""
    store, host, name = nearby_target(query)
    if not load_token(store):
        print(f"pairing with {name} — approve the prompt on the phone", file=sys.stderr)
        rec = pair(host, client_name, plain=False, store_key=store)
        rec["device_name"] = name
        save_token(store, rec)
    try:
        return call(host, method, params, store_key=store)
    except OSError:                       # includes URLError / timeouts
        store, host, name = nearby_target(query, fresh=True)
        return call(host, method, params, store_key=store)


# --------------------------------------------------------------------- X25519
#
# RFC 7748 X25519, so pairing needs nothing beyond the standard library. Uses
# `cryptography` when it is installed; otherwise a plain Montgomery ladder. The
# private key is single-use (one per pairing), so the pure-Python fallback's
# lack of constant-time arithmetic exposes nothing reusable.

_X25519_BASE = (9).to_bytes(32, "little")


def _x25519(scalar: bytes, u: bytes) -> bytes:
    try:
        from cryptography.hazmat.primitives.asymmetric.x25519 import (
            X25519PrivateKey, X25519PublicKey)
        from cryptography.hazmat.primitives import serialization
        priv = X25519PrivateKey.from_private_bytes(scalar)
        if u == _X25519_BASE:
            return priv.public_key().public_bytes(
                encoding=serialization.Encoding.Raw, format=serialization.PublicFormat.Raw)
        return priv.exchange(X25519PublicKey.from_public_bytes(u))
    except ImportError:
        pass
    p = 2**255 - 19
    k = bytearray(scalar)
    k[0] &= 248
    k[31] &= 127
    k[31] |= 64
    k = int.from_bytes(k, "little")
    x1 = int.from_bytes(u, "little") & ((1 << 255) - 1)
    x2, z2, x3, z3, swap = 1, 0, x1, 1, 0
    for t in reversed(range(255)):
        bit = (k >> t) & 1
        swap ^= bit
        if swap:
            x2, x3, z2, z3 = x3, x2, z3, z2
        swap = bit
        a, b = (x2 + z2) % p, (x2 - z2) % p
        aa, bb = a * a % p, b * b % p
        e = (aa - bb) % p
        c, d = (x3 + z3) % p, (x3 - z3) % p
        da, cb = d * a % p, c * b % p
        x3 = (da + cb) ** 2 % p
        z3 = x1 * (da - cb) ** 2 % p
        x2 = aa * bb % p
        z2 = e * (aa + 121665 * e) % p
    if swap:
        x2, z2 = x3, z3
    return (x2 * pow(z2, p - 2, p) % p).to_bytes(32, "little")


# -------------------------------------------------------------------- pairing

def pair(host: str, client_name: str, plain: bool, timeout: float = 90.0,
         store_key: str | None = None) -> dict:
    """Pair with the device. BLOCKS until the user taps Allow on-screen."""
    url = f"http://{host}/pair"
    if plain:
        status, resp = _post(url, {"client_name": client_name, "plain": True}, timeout)
        if status != 200:
            raise SystemExit(f"pair failed ({status}): {resp}")
        key = bytes.fromhex(resp["token"])
    else:
        # X25519; the device wraps K against our public key.
        priv = secrets.token_bytes(32)
        pub = _x25519(priv, _X25519_BASE)
        print(f"key fingerprint: {hashlib.sha256(pub).hexdigest()[:8]}  "
              "(verify it matches the on-device prompt)", file=sys.stderr)
        status, resp = _post(url, {
            "client_name": client_name,
            "pub": base64.b64encode(pub).decode(),
        }, timeout)
        if status != 200:
            raise SystemExit(f"pair failed ({status}): {resp}")
        device_pub = base64.b64decode(resp["pub"])
        shared = _x25519(priv, device_pub)
        k_wrap = _hmac(shared, LABEL_PAIR + pub + device_pub)
        pad = _hmac(k_wrap, LABEL_WRAP)
        key = bytes(a ^ b for a, b in zip(bytes.fromhex(resp["token_ct"]), pad))

    record = {
        "tok": hashlib.sha256(key).digest()[:4].hex(),
        "key": key.hex(),
        "client_name": client_name,
        "expires": resp.get("expires"),
    }
    save_token(store_key or host, record)
    return record


# ------------------------------------------------------------------ transport

def call(host: str, method: str, params: dict | None = None,
         timeout: float = 60.0, rpc_id: int = 1, store_key: str | None = None) -> dict:
    """One enveloped JSON-RPC call. Returns the decrypted response object.

    `store_key` names the key record when it differs from `host` (nearby
    devices are keyed by device id; their address changes)."""
    record = load_token(store_key or host)
    if not record:
        raise SystemExit(f"no token for {store_key or host} — run `pair` first")
    key = bytes.fromhex(record["key"])
    tok = record["tok"]

    body = json.dumps({"jsonrpc": "2.0", "method": method,
                       "params": params or {}, "id": rpc_id}).encode()
    nonce = secrets.token_bytes(16)
    ts = int(time.time())

    k_enc = _hmac(key, LABEL_ENC_REQ + nonce)
    k_mac = _hmac(key, LABEL_MAC + nonce)
    ct = _keystream_xor(k_enc, nonce, body)
    signed = b"v1" + bytes.fromhex(tok) + ts.to_bytes(8, "big") + nonce + ct
    tag = _hmac(k_mac, signed)

    status, resp = _post(f"http://{host}/rpc", {
        "v": 1, "tok": tok, "ts": ts, "nonce": nonce.hex(),
        "ct": base64.b64encode(ct).decode(), "tag": tag.hex(),
    }, timeout)

    if status != 200:
        raise SystemExit(f"rpc failed ({status}): {json.dumps(resp)}")

    # Response is sealed under the same nonce with the response-direction key.
    resp_ct = base64.b64decode(resp["ct"])
    expect = _hmac(k_mac, b"resp" + nonce + resp_ct)
    if not hmac.compare_digest(expect, bytes.fromhex(resp["tag"])):
        raise SystemExit("response MAC mismatch — discarding")
    k_enc_resp = _hmac(key, LABEL_ENC_RESP + nonce)
    return json.loads(_keystream_xor(k_enc_resp, nonce, resp_ct))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="127.0.0.1:8200")
    ap.add_argument("--nearby", metavar="NAME_OR_ID",
                    help="reach a nearby device over peer-to-peer Wi-Fi (macOS) instead of --host")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sc = sub.add_parser("scan", help="list nearby devices (macOS)")
    sc.add_argument("--wait", type=float, default=3.0, help="seconds to listen (default 3)")

    p = sub.add_parser("pair", help="pair with the device (blocks on approval)")
    p.add_argument("--name", default=os.uname().nodename)
    p.add_argument("--plain", action="store_true",
                   help="plaintext grant; localhost/USB only")

    c = sub.add_parser("call", help="make an RPC call")
    c.add_argument("method")
    c.add_argument("params", nargs="?", default="{}")

    sub.add_parser("list", help="list paired devices")

    s = sub.add_parser("shot", help="save a screenshot to a file")
    s.add_argument("path", nargs="?", default="screenshot.jpg")
    s.add_argument("--format", default="jpeg", choices=["jpeg", "png"])
    s.add_argument("--quality", type=float, default=0.6,
                   help="JPEG quality 0.1-1.0 (default 0.6); ignored for PNG")
    s.add_argument("--scale", type=float, default=2.0)

    args = ap.parse_args()
    client_name = os.uname().nodename

    def rpc(method: str, params: dict | None = None) -> dict:
        if args.nearby:
            return nearby_call(args.nearby, method, params, client_name)
        return call(args.host, method, params)

    if args.cmd == "scan":
        devices = nearby_scan(wait=args.wait)
        if not devices:
            print("no nearby devices — turn on Nearby Discovery from the iCTRL notification")
        for d in devices:
            paired = "paired" if load_token(f"nearby:{d['id']}") else ""
            print(f"{d['name']:32s} id={d['id'][:8]}  {paired}")
        return 0
    if args.cmd == "list":
        hosts = list_hosts()
        if not hosts:
            print("no paired devices — run `pair` first")
        for h, r in sorted(hosts.items()):
            name = r.get("device_name") or r.get("client_name", "")
            print(f"{h:24s} tok={r['tok']}  {name}")
    elif args.cmd == "pair" and args.nearby:
        store, host, name = nearby_target(args.nearby)
        rec = pair(host, args.name, plain=False, store_key=store)
        rec["device_name"] = name
        save_token(store, rec)
        print(f"paired — tok={rec['tok']} {name} (key cached in {STORE})")
    elif args.cmd == "pair":
        rec = pair(args.host, args.name, args.plain)
        # Stamp the device's own name alongside the key: hosts move with DHCP,
        # so the name is what identifies WHICH phone this key belongs to.
        try:
            info = call(args.host, "device_info").get("result", {})
            if info.get("device_name"):
                rec["device_name"] = info["device_name"]
                save_token(args.host, rec)
        except SystemExit:
            pass   # pairing succeeded; naming is best-effort
        label = rec.get("device_name", "")
        print(f"paired — tok={rec['tok']} {label} (key cached in {STORE})")
    elif args.cmd == "shot":
        params = {"format": args.format, "scale": args.scale}
        if args.format == "jpeg":
            params["quality"] = args.quality
        t0 = time.time()
        result = rpc("screenshot", params).get("result", {})
        if "data" not in result:
            print(f"screenshot failed: {json.dumps(result, ensure_ascii=False)}")
            return 1
        blob = base64.b64decode(result["data"])
        with open(args.path, "wb") as fh:
            fh.write(blob)
        # Print the point-space and scale too, not just the pixel size. A caller
        # looking at the saved image only sees its pixel dimensions, and guessing
        # the divisor from device_scale is wrong whenever the shot was
        # downscaled: a 1206x2622 screen saved at scale 2 is an 804x1748 file, so
        # dividing by 3 puts a tap ~200pt off target.
        px_w = int(result.get("pixel_width", 0))
        px_h = int(result.get("pixel_height", 0))
        pt_w = int(result.get("point_width", 0))
        pt_h = int(result.get("point_height", 0))
        sc = result.get("scale", 0)
        print(f"{args.path}  {len(blob):,} B  {result.get('format')}  "
              f"{px_w}x{px_h}px  ->  {pt_w}x{pt_h}pt  (scale {sc}: tap_x = px/{sc}, tap_y = py/{sc})  "
              f"{(time.time() - t0) * 1000:.0f}ms end-to-end")
    else:
        out = rpc(args.method, json.loads(args.params))
        print(json.dumps(out, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
