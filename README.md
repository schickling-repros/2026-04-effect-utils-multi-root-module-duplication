# mk-pnpm-cli: same-version module duplication across install roots

When `mk-pnpm-cli` composes multiple install roots (e.g., a root workspace + `repos/effect-utils`), each root runs its own `pnpm install` and gets its own `node_modules/.pnpm/` store. Even when both roots resolve an identity-critical package (like `effect`) to the **same version**, `bun build --compile` bundles two physical copies — creating incompatible module singletons.

This breaks any pattern relying on module identity: Effect's `Context.Tag`, `instanceof` checks, `Symbol.for`-based registries, etc.

## Reproduction

This repro simulates the multi-install-root layout that `mk-pnpm-cli` produces after restoring prepared dependencies, then bundles with Bun to demonstrate the duplication.

```bash
./repro.sh
```

## Expected

The bundled binary should contain exactly **one** copy of `effect`'s `Context.Tag` prototype (`TagProto`). Services registered by one part of the code should be findable by another.

## Actual

The bundle contains **two** `TagProto` definitions (`TagProto` and `TagProto2`). `Context.Tag` instances created from one copy are invisible to code using the other, causing `Service not found` errors at runtime.

```
TagProto count in bundle: 2
var TagProto = {
var TagProto2 = {
---
Runtime test: Service not found: MyService
```

## Root cause

`mk-pnpm-cli.nix` creates separate `pnpm install` runs per install root (by design, for caching). Each produces its own `.pnpm` store with its own copy of `effect`. The `identityCriticalPackages` genie validator (#517) catches **version divergence** but not **same-version physical duplication**.

The bundler treats each physical copy as a distinct module, creating duplicate singleton registries.

## Versions

- effect: 3.21.0
- Bun: 1.3.11
- OS: macOS arm64

## Related Issue

https://github.com/overengineeringstudio/effect-utils/issues/538
