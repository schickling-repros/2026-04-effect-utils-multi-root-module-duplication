#!/usr/bin/env bash
# Reproduces the multi-install-root module duplication issue.
#
# Simulates the workspace layout that mk-pnpm-cli produces after restoring
# two independent pnpm install roots. Uses pnpm (not bun install) to match
# the real .pnpm virtual store layout.
#
#   workspace/
#     node_modules/.pnpm/effect@3.21.0/...           ← root install root
#     repos/lib-workspace/
#       node_modules/.pnpm/effect@3.21.0/...         ← external install root
#       packages/my-lib/                              ← lib using @effect/platform
#     app/                                            ← CLI entry point

set -euo pipefail

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
cd "$WORKDIR"

echo "=== Setting up simulated multi-root workspace (pnpm) ==="

EFFECT_VERSION="3.21.0"
PLATFORM_VERSION="0.96.0"
PLATFORM_NODE_VERSION="0.106.0"

# --- Root install root ---
cat > package.json << EOF
{
  "name": "root-workspace",
  "private": true,
  "type": "module",
  "dependencies": {
    "effect": "$EFFECT_VERSION",
    "@effect/platform": "$PLATFORM_VERSION",
    "@effect/platform-node": "$PLATFORM_NODE_VERSION"
  }
}
EOF
cat > pnpm-workspace.yaml << 'EOF'
packages:
  - app
EOF
pnpm install 2>&1 | tail -3

# --- External install root (simulates repos/effect-utils after separate pnpm install) ---
mkdir -p repos/lib-workspace/packages/my-lib/src
pushd repos/lib-workspace > /dev/null
cat > package.json << EOF
{
  "name": "lib-workspace-root",
  "private": true,
  "type": "module",
  "dependencies": {
    "effect": "$EFFECT_VERSION",
    "@effect/platform": "$PLATFORM_VERSION",
    "@effect/platform-node": "$PLATFORM_NODE_VERSION"
  }
}
EOF
cat > pnpm-workspace.yaml << 'EOF'
packages:
  - packages/my-lib
EOF
# my-lib declares effect + @effect/platform as workspace deps
cat > packages/my-lib/package.json << EOF
{
  "name": "my-lib",
  "version": "0.1.0",
  "type": "module",
  "exports": { ".": "./src/mod.ts" },
  "dependencies": {
    "effect": "$EFFECT_VERSION",
    "@effect/platform": "$PLATFORM_VERSION",
    "@effect/platform-node": "$PLATFORM_NODE_VERSION"
  }
}
EOF
pnpm install 2>&1 | tail -3
popd > /dev/null

# --- Library source (resolves from external root's node_modules) ---
cat > repos/lib-workspace/packages/my-lib/src/mod.ts << 'EOF'
import { HttpClient, HttpClientRequest } from "@effect/platform"
import { NodeHttpClient } from "@effect/platform-node"
import { Effect, Layer } from "effect"

/**
 * Simulates the RPC client layer from discord-agent.
 * Creates a layer that:
 * 1. Reads HttpClient from the fiber context (tag from external root's @effect/platform)
 * 2. Makes an HTTP request using that client
 */
export const makeHttpCall = Effect.gen(function* () {
  const client = yield* HttpClient.HttpClient
  return `got HttpClient: ${typeof client}`
})

/** Layer that provides HttpClient via NodeHttpClient (from external root) */
export const httpLayer = NodeHttpClient.layer
EOF

# --- App entry point (resolves from root's node_modules) ---
mkdir -p app
cat > app/package.json << EOF
{
  "name": "app",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "dependencies": {
    "effect": "$EFFECT_VERSION",
    "@effect/platform": "$PLATFORM_VERSION",
    "@effect/platform-node": "$PLATFORM_NODE_VERSION",
    "my-lib": "link:../repos/lib-workspace/packages/my-lib"
  }
}
EOF

cat > app/main.ts << 'EOF'
import { FetchHttpClient, HttpClient } from "@effect/platform"
import { NodeHttpClient } from "@effect/platform-node"
import { Effect } from "effect"
import { httpLayer, makeHttpCall } from "../repos/lib-workspace/packages/my-lib/src/mod.ts"

// Test 1: App provides its own HttpClient, lib's code consumes it.
// If the two effect copies have incompatible HttpClient tags, this fails.
console.log("Test 1: Root provides FetchHttpClient → lib reads HttpClient...")
await Effect.runPromise(
  makeHttpCall.pipe(Effect.provide(FetchHttpClient.layer), Effect.scoped),
).then(
  (msg) => console.log(`  ✅ PASS: ${msg}`),
  (e) => {
    const msg = e instanceof Error ? e.message : String(e)
    if (msg.includes("Service not found")) {
      console.log(`  ❌ FAIL: ${msg.split("\n")[0]}`)
    } else {
      console.log(`  ❌ FAIL: ${msg.slice(0, 200)}`)
    }
  },
)

// Test 2: Lib provides its own HttpClient layer, app just runs the effect.
// Both sides from the same (external) copy — should work regardless.
console.log("Test 2: Lib provides its own NodeHttpClient layer...")
await Effect.runPromise(
  makeHttpCall.pipe(Effect.provide(httpLayer), Effect.scoped),
).then(
  (msg) => console.log(`  ✅ PASS: ${msg}`),
  (e) => {
    const msg = e instanceof Error ? e.message : String(e)
    if (msg.includes("Service not found")) {
      console.log(`  ❌ FAIL: ${msg.split("\n")[0]}`)
    } else {
      console.log(`  ❌ FAIL: ${msg.slice(0, 200)}`)
    }
  },
)

// Test 3: Same-copy baseline — app provides and consumes its own HttpClient.
console.log("Test 3: Root provides and consumes its own HttpClient (baseline)...")
await Effect.runPromise(
  Effect.gen(function* () {
    const client = yield* HttpClient.HttpClient
    return `got HttpClient: ${typeof client}`
  }).pipe(Effect.provide(FetchHttpClient.layer), Effect.scoped),
).then(
  (msg) => console.log(`  ✅ PASS: ${msg}`),
  (e) => console.log(`  ❌ FAIL: ${String(e).slice(0, 200)}`),
)
EOF

# Reinstall root workspace (picks up the app package)
pnpm install 2>&1 | tail -3

echo ""
echo "=== Bundling with bun build --compile ==="
bun build app/main.ts --compile --outfile ./repro-binary 2>&1 | tail -3

echo ""
echo "=== Checking for duplicate Effect modules in bundle ==="
tagproto_count=$(strings ./repro-binary | grep -c 'var TagProto' || true)
generictag_count=$(strings ./repro-binary | grep -c 'var GenericTag' || true)
httpclient_tag_count=$(strings ./repro-binary | grep -c 'GenericTag("@effect/platform/HttpClient")' || true)
echo "TagProto definitions:       $tagproto_count (expected: 1)"
echo "GenericTag functions:       $generictag_count (expected: 1)"
echo "HttpClient tag definitions: $httpclient_tag_count (expected: 1)"

echo ""
echo "=== Source paths in bundle (showing duplication origin) ==="
strings ./repro-binary | grep "node_modules.*effect/dist" | sort -u | head -6

echo ""
echo "=== Running bundled binary ==="
./repro-binary 2>&1 || true

echo ""
if [ "$tagproto_count" -gt 1 ]; then
  echo "❌ DUPLICATION CONFIRMED: $tagproto_count Effect copies in bundle"
else
  echo "✅ No duplication detected"
fi
