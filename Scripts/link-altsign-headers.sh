#!/bin/bash
#
# Builds the flat header directory AltSign's own headers expect.
#
# AltSign includes its headers framework-style — `#import <AltSign/ALTSigner.h>`
# — but the files themselves are spread across "Apple API/", "Model/",
# "Signing/", and so on. CocoaPods papers over this by synthesizing a flat
# directory of symlinks; building from source means doing the same thing.
#
# Symlinks rather than copies so the vendored submodule stays the single source
# of truth and nothing here can drift from it.
#
# Safe to re-run: the directory is rebuilt from scratch each time.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/Dependencies/AltSign/AltSign"
OUT="$ROOT/build/altsign-headers/AltSign"

if [ ! -d "$SRC" ]; then
    echo "❌ AltSign sources are missing at $SRC"
    echo "   Run: git submodule update --init --recursive"
    exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"

count=0
while IFS= read -r header; do
    ln -sf "$header" "$OUT/$(basename "$header")"
    count=$((count + 1))
done < <(find "$SRC" -name "*.h")

echo "🔗 Linked $count AltSign headers into ${OUT#"$ROOT"/}"
