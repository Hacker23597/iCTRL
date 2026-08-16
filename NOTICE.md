# Third-party components and licensing

iCTRL as a whole is licensed under the **GNU Affero General Public License,
version 3** (see `LICENSE`).

AGPL was not an arbitrary pick. The code-signing path depends on `ldid`, which
is AGPL-3.0, and linking it makes the combined work AGPL-3.0 as well. iCTRL is
fully open source, so this costs its users nothing — but it is worth stating
plainly, because iCTRL is a network service and AGPL §13 applies to network
use, not only to distribution: anyone who interacts with an iCTRL server over
the network is entitled to its complete source.

## Components

| Component | Upstream | License | Used for |
|---|---|---|---|
| `ldid` | github.com/rileytestut/ldid (fork of saurik/ldid) | **AGPL-3.0** | Writing Mach-O code signatures |
| `AltSign` | github.com/rileytestut/AltSign | **MIT** (declared in `AltSign.podspec`) | Apple ID authentication, developer-portal operations, signing orchestration |
| `OpenSSL` | github.com/krzyzanowskim/OpenSSL | Apache-2.0 | CSR generation, PKCS#12 handling |
| `minizip-ng` | github.com/zlib-ng/minizip-ng | zlib | Reading and writing `.ipa` archives |
| `idevice` | FFI used by `iCTRLApp/DDI` | MIT | RSD tunnel, AFC, installation_proxy, image mounter |

### A note on AltSign's license

Two AltSign repositories exist and they are **not** equally usable:

- **`rileytestut/AltSign`** (upstream) declares `spec.license = "MIT"` in
  `AltSign.podspec`. This is the one iCTRL uses.
- **`SideStore/AltSign`** (fork) ships no `LICENSE`, no `COPYING`, and no
  license declaration of any kind — the podspec that carried it upstream is
  absent. Its sources are marked "All rights reserved". Absent a grant, that
  fork is not licensed for reuse and iCTRL does not take code from it.

Anyone auditing this project should verify the upstream declaration rather than
taking this file's word for it; a podspec field is a weaker signal than a
`LICENSE` file, and upstream may clarify it either way.

## Anisette

Signing in to an Apple ID requires *anisette* — device-fingerprint headers that
Apple's authentication servers demand. iOS cannot produce these locally: it
ships no linkable ADI library, and `AuthKit` only proxies to the entitled Mach
service `com.apple.ak.anisette.xpc` (see `iCTRLApp/DDI/AnisetteProbe.swift`,
which re-checks this at runtime).

Any Apple ID login path therefore depends on an external anisette provider.
That is a genuine third-party trust dependency, not an implementation detail,
and it should be surfaced to users rather than buried.
