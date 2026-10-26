#!/bin/sh
# Pure Swift checks; no signing, iPhone, or touch injection required.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ictrl-path-tests.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
swiftc -module-cache-path "$tmp/module-cache" \
    "$root/iCTRLKit/RPCTypes.swift" \
    "$root/iCTRLKit/AuthManager.swift" \
    "$root/iCTRLKit/SecureEnvelope.swift" \
    "$root/iCTRLKit/KeychainStore.swift" \
    "$root/iCTRLKit/TokenFileStore.swift" \
    "$root/iCTRLUITests/ActionCommand.swift" \
    "$root/iCTRLUITests/ContinuousDragPath.swift" \
    "$root/Tests/ContinuousDragPath/main.swift" \
    -o "$tmp/continuous-drag-tests"
"$tmp/continuous-drag-tests"

# The call sites live in XCTest code this script can't compile; a merge that
# drops one still builds, so check they are there.
wired() {
    grep -qF -- "$2" "$root/$1" || { echo "❌ not wired: $1 lacks $2" >&2; exit 1; }
}
wired iCTRLUITests/iCTRLUITests.swift 'if method == "drag" { return ContinuousDragPath.rpcBudget(params'
wired iCTRLUITests/ActionHandler.swift 'ContinuousDragPath.parse(params) { point, index in'
wired iCTRLUITests/ActionHandler.swift 'validateCoordinate(x: Double(point.x), y: Double(point.y), context: "drag point'
wired iCTRLUITests/ActionHandler.swift 'waypoints.contains(where: c.area.contains)'
wired iCTRLUITests/ActionHandler.swift '!ContinuousDragPath.waypoints(cmd.dragPathParams).isEmpty'
wired iCTRLKit/RPCMethod.swift '"drag_path",'
echo "ContinuousDragPath: call sites wired"
