# Patches applied to vendored dependencies

These change code inside `Dependencies/`, which is a git submodule — so
`git submodule update` will silently revert them. Each patch here is the
recorded form of a change that is already applied in the working tree, kept so
it can be re-applied and so the reason survives.

Re-apply everything after a submodule update:

```sh
cd Dependencies/AltSign && git apply ../../Patches/altsign-xcode-version.patch
```

## altsign-xcode-version.patch

Upstream AltSign sends `X-Xcode-Version: 11.2 (11B41)` — Xcode 11.2, released
2019 — on every developer-portal request. Apple no longer accepts it. Signing in
fails with:

```
-22411  This action cannot be completed at this time
```

which mentions nothing about a version and reads like an outage or an account
problem, so it is worth knowing this is the cause before debugging anything else.

The patch changes all three sites to `26.0 (26A242)`, the value SideStore
defaults to (`AnisetteConfigManager.resolvedXcodeVersion`). SideStore hit the
same wall and restructured its API to pass the version as a parameter; iCTRL
does not need that flexibility yet, so this is a literal replacement.

**Expect this to expire.** Apple retires these versions periodically, and the
symptom is the same -22411 on a sign-in that used to work. When it happens, bump
the value here to whatever Xcode currently reports — or to whatever SideStore has
moved to, since they track it.
