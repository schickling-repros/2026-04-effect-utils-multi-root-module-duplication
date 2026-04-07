#!/usr/bin/env bash
# Reproduces the multi-install-root module duplication issue.
#
# Simulates the workspace layout that mk-pnpm-cli produces:
#   workspace/
#     node_modules/effect@3.21.0           ← from root install root
#     repos/lib-workspace/
#       node_modules/effect@3.21.0         ← from external install root (DUPLICATE)
#       packages/my-lib/                   ← workspace package using effect
#     app/                                 ← CLI entry point using effect
#
# Then bundles with `bun build --compile` and checks for duplicate singletons.

set -euo pipefail

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
cd "$WORKDIR"

echo "=== Setting up simulated multi-root workspace ==="

# --- Root install root ---
cat > package.json << 'EOF'
{ "name": "root", "private": true, "type": "module", "dependencies": { "effect": "3.21.0" } }
EOF
bun install --frozen-lockfile 2>/dev/null || bun install

# --- External install root (simulates repos/effect-utils) ---
mkdir -p repos/lib-workspace/packages/my-lib/src
pushd repos/lib-workspace > /dev/null
cat > package.json << 'EOF'
{ "name": "lib-workspace", "private": true, "type": "module", "dependencies": { "effect": "3.21.0" } }
EOF
bun install --frozen-lockfile 2>/dev/null || bun install
popd > /dev/null

# Library that creates a singleton using Effect.globalValue (from external root's effect)
cat > repos/lib-workspace/packages/my-lib/package.json << 'EOF'
{ "name": "my-lib", "version": "0.1.0", "type": "module", "exports": { ".": "./src/mod.ts" } }
EOF

cat > repos/lib-workspace/packages/my-lib/src/mod.ts << 'EOF'
import { Context, Effect, Layer } from "effect"

// Create a service tag — this will use the external root's Effect copy
export class MyService extends Context.Tag("repro/MyService")<MyService, { readonly value: number }>() {}

// A layer that provides the service — created using the external root's Effect
export const MyServiceLive = Layer.succeed(MyService, { value: 42 })

// A program that consumes the service — also using the external root's Effect
export const program = Effect.gen(function* () {
  const svc = yield* MyService
  return svc.value
})
EOF

# App entry point — uses the ROOT's effect to run the program
mkdir -p app
cat > app/main.ts << 'EOF'
import { Effect } from "effect"
import { MyServiceLive, program } from "../repos/lib-workspace/packages/my-lib/src/mod.ts"

// The app provides and runs using the root's Effect copy.
// If the two Effect copies have incompatible internals, this may fail.
const main = program.pipe(Effect.provide(MyServiceLive))

Effect.runPromise(main).then(
  (result) => console.log(`SUCCESS: got value ${result}`),
  (e) => {
    const msg = e instanceof Error ? e.message : String(e)
    // Check for the characteristic "Service not found" error
    if (msg.includes("Service not found")) {
      console.error("FAILURE: Service not found — module identity mismatch between Effect copies")
    } else {
      console.error("FAILURE:", msg.slice(0, 200))
    }
    process.exit(1)
  },
)
EOF

echo ""
echo "=== Bundling with bun build --compile ==="
bun build app/main.ts --compile --outfile ./repro-binary 2>&1 | tail -3

echo ""
echo "=== Checking for duplicate Effect singletons in bundle ==="
# TagProto is the prototype used by Context.Tag — multiple copies = multiple tag registries
tagproto_count=$(strings ./repro-binary | grep -c 'var TagProto' || true)
echo "TagProto definitions: $tagproto_count (expected: 1)"
strings ./repro-binary | grep 'var TagProto' | head -5

# Check for duplicate GenericTag functions
generictag_count=$(strings ./repro-binary | grep -c 'var GenericTag' || true)
echo "GenericTag definitions: $generictag_count (expected: 1)"

# Check for duplicate effect/Context module copies
context_copies=$(strings ./repro-binary | grep -c 'effect/Context/Tag' || true)
echo "effect/Context/Tag symbol definitions: $context_copies (expected: 1)"

echo ""
echo "=== Running bundled binary ==="
./repro-binary 2>&1 || true

echo ""
if [ "$tagproto_count" -gt 1 ]; then
  echo "❌ BUG CONFIRMED: Bundle contains $tagproto_count Effect copies"
  echo ""
  echo "Even though this simple test may pass (Context.Tag uses string keys),"
  echo "the duplication breaks more complex patterns like @effect/rpc's Protocol"
  echo "service which relies on module-level singletons for serialization state."
  echo ""
  echo "In the real scenario (discord-agent CLI), this causes:"
  echo "  Service not found: @effect/platform/HttpClient"
  echo "when RPC client code (bundled from root's effect) tries to find HttpClient"
  echo "provided through a layer composed with the external root's effect."
else
  echo "✅ No duplication detected"
fi
