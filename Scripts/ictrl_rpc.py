#!/usr/bin/env python3
"""iCTRL client — pairing + encrypted-envelope JSON-RPC (protocol v1).

All request-path crypto is HMAC-SHA256 only, so this is portable to any language
with an HMAC primitive. X25519 appears only in LAN pairing (mode A).

Usage:
    ./ictrl_rpc.py --host 10.0.0.5:8200 pair --name my-laptop
    ./ictrl_rpc.py --host 10.0.0.5:8200 call device_info
    ./ictrl_rpc.py --host 10.0.0.5:8200 call tap '{"x":100,"y":200}'

The token is cached at ~/.ictrl/token.json keyed by host, so `pair` is a
one-time step per device.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import os
import secrets
import sys
import time
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
    """PRF-CTR: keystream_i = HMAC(key, nonce || be32(i))."""
    out = bytearray()
    counter = 0
    while len(out) < len(data):
        out += _hmac(key, nonce + counter.to_bytes(4, "big"))
        counter += 1
    return bytes(a ^ b for a, b in zip(data, out))


def _post(url: str, obj: dict, timeout: float) -> tuple[int, dict]:
    body = json.dumps(obj).encode()
    req = urllib.request.Request(url, data=body,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
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


# -------------------------------------------------------------------- pairing

def pair(host: str, client_name: str, plain: bool, timeout: float = 90.0) -> dict:
    """Pair with the device. BLOCKS until the user taps Allow on-screen."""
    url = f"http://{host}/pair"
    if plain:
        status, resp = _post(url, {"client_name": client_name, "plain": True}, timeout)
        if status != 200:
            raise SystemExit(f"pair failed ({status}): {resp}")
        key = bytes.fromhex(resp["token"])
    else:
        # X25519 via cryptography if available; the device wraps K against it.
        try:
            from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
            from cryptography.hazmat.primitives import serialization
        except ImportError:
            raise SystemExit(
                "LAN pairing needs `pip install cryptography`, or use --plain over "
                "USB/localhost (iproxy 8200 8200).")
        priv = X25519PrivateKey.generate()
        pub = priv.public_key().public_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PublicFormat.Raw)
        print(f"key fingerprint: {hashlib.sha256(pub).hexdigest()[:8]}  "
              "(verify it matches the on-device prompt)", file=sys.stderr)
        status, resp = _post(url, {
            "client_name": client_name,
            "pub": base64.b64encode(pub).decode(),
        }, timeout)
        if status != 200:
            raise SystemExit(f"pair failed ({status}): {resp}")
        from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PublicKey
        device_pub = base64.b64decode(resp["pub"])
        shared = priv.exchange(X25519PublicKey.from_public_bytes(device_pub))
        k_wrap = _hmac(shared, LABEL_PAIR + pub + device_pub)
        pad = _hmac(k_wrap, LABEL_WRAP)
        key = bytes(a ^ b for a, b in zip(bytes.fromhex(resp["token_ct"]), pad))

    record = {
        "tok": hashlib.sha256(key).digest()[:4].hex(),
        "key": key.hex(),
        "client_name": client_name,
        "expires": resp.get("expires"),
    }
    save_token(host, record)
    return record


# ------------------------------------------------------------------ transport

def call(host: str, method: str, params: dict | None = None,
         timeout: float = 60.0, rpc_id: int = 1) -> dict:
    """One enveloped JSON-RPC call. Returns the decrypted response object."""
    record = load_token(host)
    if not record:
        raise SystemExit(f"no token for {host} — run `pair` first")
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
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("pair", help="pair with the device (blocks on approval)")
    p.add_argument("--name", default=os.uname().nodename)
    p.add_argument("--plain", action="store_true",
                   help="plaintext grant; localhost/USB only")

    c = sub.add_parser("call", help="make an RPC call")
    c.add_argument("method")
    c.add_argument("params", nargs="?", default="{}")

    sub.add_parser("list", help="list paired devices")

    args = ap.parse_args()
    if args.cmd == "list":
        hosts = list_hosts()
        if not hosts:
            print("no paired devices — run `pair` first")
        for h, r in sorted(hosts.items()):
            name = r.get("device_name") or r.get("client_name", "")
            print(f"{h:24s} tok={r['tok']}  {name}")
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
    else:
        out = call(args.host, args.method, json.loads(args.params))
        print(json.dumps(out, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
