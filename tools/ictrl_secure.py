#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.9"
# dependencies = ["cryptography"]
# ///
"""
iCTRL secure client — end-to-end encrypted JSON-RPC over the plain HTTP port,
matching the server's Curve25519 ECDH + HKDF-SHA256 + AES-GCM scheme.

Flow (mirrors the Swift SecureChannel):
  1. pair(): generate a Curve25519 key pair (persisted at ~/.ictrl/keypair.json),
     POST /pair {client_name, client_pubkey}. The DEVICE shows a confirm
     notification with the key fingerprint (like ADB "Allow USB debugging").
     On approval you get {server_pubkey, pairing_id}; both are cached.
  2. secure_rpc(): derive the session key via ECDH(own priv, server pub) → HKDF,
     then send each request AES-GCM-encrypted in an envelope carrying a fresh
     nonce + millisecond timestamp (anti-replay); decrypt the response the same way.

Usage:
    from ictrl_secure import SecureClient
    c = SecureClient("10.1.1.43:8200")
    c.pair("my-agent")                 # one-time; confirm on the device
    print(c.secure_rpc("device_info"))

CLI:
    uv run tools/ictrl_secure.py <host:port> pair  <client_name>
    uv run tools/ictrl_secure.py <host:port> rpc   <method> ['<json params>']
"""

import base64
import json
import os
import sys
import time
import urllib.request

from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

STORE = os.path.expanduser("~/.ictrl/keypair.json")
b64e = lambda b: base64.b64encode(b).decode()
b64d = lambda s: base64.b64decode(s)


class SecureClient:
    def __init__(self, host):
        self.host = host
        self.base = f"http://{host}"
        self._id = 0
        self._priv = None          # X25519PrivateKey
        self._pub_raw = None       # 32 bytes
        self.pairing_id = None
        self.server_pub_raw = None
        self._session_key = None
        self._load()

    # ---- key + pairing persistence ----
    def _load(self):
        try:
            with open(STORE) as f:
                d = json.load(f)
            self._priv = X25519PrivateKey.from_private_bytes(b64d(d["priv"]))
            self._pub_raw = self._priv.public_key().public_bytes(
                serialization.Encoding.Raw, serialization.PublicFormat.Raw)
            p = d.get("pairings", {}).get(self.host)
            if p:
                self.pairing_id = p["pairing_id"]
                self.server_pub_raw = b64d(p["server_pubkey"])
        except Exception:
            self._new_keypair()

    def _new_keypair(self):
        self._priv = X25519PrivateKey.generate()
        self._pub_raw = self._priv.public_key().public_bytes(
            serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        self._save()

    def _save(self):
        os.makedirs(os.path.dirname(STORE), exist_ok=True)
        d = {"priv": b64e(self._priv.private_bytes(
                serialization.Encoding.Raw, serialization.PrivateFormat.Raw,
                serialization.NoEncryption())),
             "pairings": {}}
        # merge existing pairings
        try:
            with open(STORE) as f:
                d["pairings"] = json.load(f).get("pairings", {})
        except Exception:
            pass
        if self.pairing_id and self.server_pub_raw:
            d["pairings"][self.host] = {"pairing_id": self.pairing_id,
                                        "server_pubkey": b64e(self.server_pub_raw)}
        with open(STORE, "w") as f:
            json.dump(d, f)

    # ---- crypto ----
    def _derive_key(self):
        if self._session_key:
            return self._session_key
        peer = X25519PublicKey.from_public_bytes(self.server_pub_raw)
        shared = self._priv.exchange(peer)
        self._session_key = HKDF(
            algorithm=hashes.SHA256(), length=32,
            salt=b"iCTRL-x25519", info=b"ictrl.secure.v1").derive(shared)
        return self._session_key

    @staticmethod
    def fingerprint(pub_raw):
        h = hashes.Hash(hashes.SHA256()); h.update(pub_raw)
        return ":".join(f"{b:02X}" for b in h.finalize()[:8])

    # ---- HTTP ----
    def _post(self, path, obj, headers=None):
        data = json.dumps(obj).encode()
        req = urllib.request.Request(self.base + path, data=data, method="POST",
                                     headers={"Content-Type": "application/json", **(headers or {})})
        try:
            with urllib.request.urlopen(req, timeout=90) as r:
                return json.loads(r.read().decode())
        except urllib.error.HTTPError as e:
            return json.loads(e.read().decode())

    # ---- pairing ----
    def pair(self, client_name="ictrl secure client"):
        """One-time pairing. BLOCKS until the user confirms on the device."""
        print(f"Pairing… confirm on the device. Your key fingerprint: {self.fingerprint(self._pub_raw)}",
              file=sys.stderr)
        res = self._post("/pair", {"client_name": client_name,
                                   "client_pubkey": b64e(self._pub_raw)})
        if "error" in res:
            raise RuntimeError(f"pair failed: {res['error']}")
        self.pairing_id = res["pairing_id"]
        self.server_pub_raw = b64d(res["server_pubkey"])
        self._session_key = None
        self._save()
        return res

    # ---- secure rpc ----
    def secure_rpc(self, method, params=None):
        if not self.pairing_id:
            raise RuntimeError("not paired — call pair() first")
        self._id += 1
        plaintext = json.dumps({"jsonrpc": "2.0", "method": method,
                                "params": params or {}, "id": self._id}).encode()
        key = self._derive_key()
        nonce = os.urandom(12)
        ct = AESGCM(key).encrypt(nonce, plaintext, None)   # ct||tag
        env = {"nonce": b64e(nonce),
               "ts": int(time.time() * 1000),
               "ciphertext": b64e(ct)}
        res = self._post("/rpc/secure", env, headers={"X-ICTRL-Pairing": self.pairing_id})
        if "error" in res and "nonce" not in res:          # plaintext error (not an envelope)
            raise RuntimeError(res["error"])
        # decrypt response envelope
        dnonce = b64d(res["nonce"]); dct = b64d(res["ciphertext"])
        out = AESGCM(key).decrypt(dnonce, dct, None)
        resp = json.loads(out.decode())
        if "error" in resp and resp["error"]:
            raise RuntimeError(resp["error"].get("message", str(resp["error"])))
        return resp.get("result", {})


def _main():
    if len(sys.argv) < 3:
        print(__doc__); sys.exit(1)
    host, action = sys.argv[1], sys.argv[2]
    c = SecureClient(host)
    if action == "pair":
        print(json.dumps(c.pair(sys.argv[3] if len(sys.argv) > 3 else "ictrl secure client"), indent=2))
    elif action == "rpc":
        method = sys.argv[3]
        params = json.loads(sys.argv[4]) if len(sys.argv) > 4 else {}
        print(json.dumps(c.secure_rpc(method, params), ensure_ascii=False, indent=2))
    else:
        print("actions: pair | rpc"); sys.exit(1)


if __name__ == "__main__":
    _main()
