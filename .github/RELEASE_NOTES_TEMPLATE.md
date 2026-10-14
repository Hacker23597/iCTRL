<!--
Standard part of every GitHub release description. Copy the block below into
the release notes, then add the changes for that version above it.
-->

### Which IPA do I need?

| File | Needed? | What it is |
|---|---|---|
| `iCTRLUITests-Runner.ipa` | **Required** | The automation engine. It serves the JSON-RPC API that agents and clients call, and must be running. |
| `iCTRL.ipa` | Optional | Companion app for the phone itself: mount the Developer Disk Image without a Mac (and re-mount after a reboot), start and stop the runner, switch who can reach it (this device only / LAN / LAN + nearby), see and revoke authorized clients, and read the runner's log live. |

Skip `iCTRL.ipa` if you mount the Developer Disk Image with Xcode or StikDebug
and manage the runner from its notification or a computer. With a free Apple
ID (three sideloaded apps, SideStore included), install StikDebug *or* the
iCTRL app alongside the runner, not both.
