#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# Refresh inlined copies from the 4A gateway repo if it's reachable. The
# plugin ships as a single binary, so these utilities are inlined at build
# time rather than imported across repos. See plan §§3.4, 3.5, 4.3 — kept
# in lockstep with the gateway because the encrypted-variant validator,
# NIP-44 v2, and NIP-17 wrap/unwrap MUST round-trip with the gateway's
# implementations or audiences silently break.

copy_from_gateway() {
  local src="$1" dst="$2"
  if [ -f "$src" ]; then
    {
      echo "// AUTO-GENERATED — copied at build time from:"
      echo "//   $src"
      echo "// Edits will be overwritten by build.sh on the next compile."
      echo ""
      cat "$src"
    } > "$dst"
  fi
}

copy_from_gateway /Users/evan/projects/4a/gateway/src/lib/blake3-tag.ts \
                  src/crypto/blake3-tag.ts
copy_from_gateway /Users/evan/projects/4a/gateway/src/lib/nip44.ts \
                  src/crypto/nip44.ts
copy_from_gateway /Users/evan/projects/4a/gateway/src/lib/nip17.ts \
                  src/crypto/nip17.ts

# validators.ts: copy + rewrite imports to point at plugin-local equivalents.
# The gateway version refers to ../audience-validator, ../lib/blake3-tag,
# ../lib/nip44, ../relay-pool — none of which exist in the plugin tree. The
# plugin re-states the relevant types in src/audience-types.ts and ships
# blake3-tag/nip44 in src/crypto/.
validators_src=/Users/evan/projects/4a/gateway/src/studio-v0/validators.ts
if [ -f "$validators_src" ]; then
  {
    echo "// AUTO-GENERATED — copied at build time from:"
    echo "//   $validators_src"
    echo "// Edits will be overwritten by build.sh on the next compile."
    echo "// Imports are rewritten from gateway-relative to plugin-relative."
    echo ""
    sed \
      -e 's|from "../audience-validator"|from "./audience-types"|g' \
      -e 's|from "../lib/blake3-tag"|from "./crypto/blake3-tag"|g' \
      -e 's|from "../lib/nip44"|from "./crypto/nip44"|g' \
      -e 's|from "../relay-pool"|from "./audience-types"|g' \
      "$validators_src"
  } > src/validators.ts
fi

mkdir -p bin
bun build src/index.ts \
  --compile \
  --target=bun-darwin-arm64 \
  --outfile bin/sonata-studio

# Sign for macOS Gatekeeper (matches prstar's pattern).
codesign -s - bin/sonata-studio || true

echo "built bin/sonata-studio"
