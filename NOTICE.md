# Third-party components and licensing

iCTRL as a whole is licensed under the **GNU Affero General Public License,
version 3** (see `LICENSE`).

That choice originally followed from vendoring `ldid` (AGPL-3.0) for on-device
code signing. That code has since been removed, so nothing currently forces
AGPL — but the licence stays: versions carrying it have already been
distributed, and relicensing would not un-publish them. It costs this project
nothing, since iCTRL is fully open source. It is worth knowing that §13 applies
to network use, not only distribution: anyone who interacts with an iCTRL server
over the network is entitled to its complete source.

## Components

| Component | Upstream | License | Used for |
|---|---|---|---|
| `idevice` | FFI used by `iCTRLApp/DDI` | MIT | RSD tunnel, AFC, installation_proxy, image mounter |

## On-device signing

iCTRL does not sign apps. It installs packages that are already signed for the
device, over the same RSD tunnel it uses to mount the developer disk image.

An in-app signer was built and removed. What it ran into is worth recording,
because none of it is apparent up front:

- **Apple ID login needs anisette**, and iOS cannot produce it. There is no
  linkable ADI library on the system, and `AuthKit` only proxies to an
  entitlement-gated XPC service (`iCTRLApp/DDI/AnisetteProbe.swift` still checks
  this at runtime). Every route to a certificate therefore depends on a
  third-party anisette server seeing the fingerprint the account logs in under.
- **The runner is not an ordinary app.** Its `.xctest` shares the host's bundle
  identifier instead of extending it, and generic signers reject or mishandle
  that. `ldid` skips `.xctest` entirely — it recurses only into `.framework` and
  `.appex` — so the bundle installs and then fails to launch, because
  testmanagerd validates the plugin's own signature.

Signing the runner with a desktop tool and installing the result here works, and
is the supported path.
