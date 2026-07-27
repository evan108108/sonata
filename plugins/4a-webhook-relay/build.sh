#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# Refresh inlined copies from the 4A gateway repo if it's reachable — same
# pattern as sonata-studio/build.sh. The plugin ships as a single binary, so
# the NIP-44 / NIP-17 primitives are inlined at build time rather than
# imported across repos; they MUST round-trip with the gateway's
# implementations or hook decryption silently breaks. The hook-specific
# unwrap branch lives in src/crypto/unwrap-hook.ts (plugin-authored, NOT
# auto-generated) so these copies stay pristine.

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

copy_from_gateway /Users/evan/projects/4a/gateway/src/lib/nip44.ts \
                  src/crypto/nip44.ts
copy_from_gateway /Users/evan/projects/4a/gateway/src/lib/nip17.ts \
                  src/crypto/nip17.ts

mkdir -p bin
bun build src/index.ts \
  --compile \
  --target=bun-darwin-arm64 \
  --outfile bin/4a-webhook-relay

# Sign for macOS Gatekeeper (matches prstar's pattern).
codesign -s - bin/4a-webhook-relay || true

echo "built bin/4a-webhook-relay"
