# mk-pnpm-cli: same-version module duplication across install roots

When `mk-pnpm-cli` composes multiple pnpm install roots into a single CLI binary via `bun build --compile`, identity-critical packages like `effect` get physically duplicated in the bundle — even when all roots resolve the same version. This creates incompatible module singletons (duplicate `TagProto`, `GenericTag`, `Context.Tag` prototypes).

## Reproduction

```bash
./repro.sh
```

The script:
1. Creates two independent pnpm install roots (root + external), both with `effect@3.21.0` and `@effect/platform`
2. Creates a library in the external root that reads `HttpClient` from context
3. Creates an app in the root that provides `HttpClient` and calls the library
4. Bundles with `bun build --compile`
5. Checks the bundle for duplicate `TagProto`/`GenericTag` definitions
6. Runs cross-root service resolution tests

## Expected

One copy of `effect` in the bundle. Services registered by one part of the code are findable by another.

## Actual

Two copies of `effect` (`TagProto` + `TagProto2`, two `GenericTag` functions). While basic `Context.Tag` lookups may still work (string-keyed), more complex patterns involving `Layer.provide`, `RpcClient.Protocol`, and `@effect/rpc` serialization break with `Service not found` errors.

In the real scenario (discord-agent CLI), this manifests as:
```
Service not found: @effect/platform/HttpClient
```

## Root cause

`mk-pnpm-cli.nix` runs separate `pnpm install` per install root (by design, for caching). Each produces its own `.pnpm` virtual store. When Bun's bundler resolves imports, it follows filesystem paths — modules from `node_modules/.pnpm/effect@3.21.0/` and `repos/lib-workspace/node_modules/.pnpm/effect@3.21.0/` are treated as distinct modules, producing duplicate singleton registries.

The `identityCriticalPackages` genie validator (#517) catches version divergence but not same-version physical duplication.

## Versions

- effect: 3.21.0
- @effect/platform: 0.96.0
- Bun: 1.3.11
- pnpm: 10.28.1+ / 11.0.0-beta.2
- OS: macOS arm64

## Related Issue

https://github.com/overengineeringstudio/effect-utils/issues/538
