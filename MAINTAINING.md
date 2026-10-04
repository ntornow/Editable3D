# Maintaining Editable3D

## Layout and reuse

`src/init.luau` exposes public namespaces; internal modules live beside them so a single ModuleScript tree remains portable. `Util`, `AttributeCore`, `Connectivity` and the interval/exact arithmetic modules provide shared numerical and topology infrastructure. Operator modules should call those helpers instead of duplicating tolerance, attribute-transfer or connectivity logic. The root import has no scene mutation or network effects.

New production infrastructure follows the same separation:

- `OperationBudget`: reusable cooperative counters, limits and callbacks.
- `PublishRetry`: bounded retries for idempotent operations.
- `PublishTransaction`: prepare/validate/commit, reverse rollback and cleanup.
- `PublishPipeline`: service-independent asset lifecycle and resume ledger.
- `NativeContent`: canonical native content verification.
- `RobloxPublish`: the small engine adapter used by `Roblox.publish`.
- `Types`: public boundary contracts.

`tests` contains deterministic numerical fixtures, fault-injection tests and engine integration tests. `examples` contains callable authoring workflows. `tools` contains package construction, validation, release staging and optional fixture generators. Production operations do not depend on Python, an HTTP server, test fixtures or example scripts. The flat source tree avoids breaking existing Instance require paths; namespace and dependency boundaries carry the architecture.

## Local and CI validation

From this directory:

```sh
python3 tools/validate.py --bootstrap
```

Bootstrap downloads **tools only**, from official release URLs in `toolchain.lock.json`, and checks every archive's SHA-256. Luau 0.713, Lune 0.10.5, Rojo 7.7.0 and StyLua 2.5.2 are pinned for Linux x86_64 and macOS arm64/x86_64. Binary receipts allow verified cached reuse. Python 3.10+ standard library is sufficient for release validation; optional symbolic fixture-generation scripts may need their separately documented dependencies. `rokit.toml` provides matching versions for an existing Rokit development setup; the checksum lock is authoritative for CI.

`.github/workflows/editable3d.yml` runs this same command on every push and pull request, with read-only repository permissions and SHA-pinned actions. Reports and both package profiles are uploaded even if a later gate fails. Hosted CI only runs after the commit reaches GitHub; passing locally does not imply a hosted run has occurred.

The gate runs:

1. Stable formatting for the changed production boundaries and their tests. Existing unrelated formatting is not rewritten.
2. Strict core and positive/negative public contract checks. A disposable mirror changes only Roblox require paths, which standalone Luau cannot resolve.
3. Static analysis of all legacy source, tests and examples; root exported contracts are checked in the mirror.
4. Headless texture, budget, failure-recovery and content-verification regressions using Lune's Roblox value types.
5. Actual Luau VM line coverage for four service-independent strict modules, requiring at least 90% in each. This is **subset line coverage**, not whole-library coverage or branch coverage.
6. Texture noise, blur and AO benchmarks with deterministic work/allocation ceilings and a generous 15-second per-case timing gate. These report accounted bytes, not peak process memory.
7. XML and Rojo binary builds for both profiles, followed by exact ModuleScript source parity checks.

Reports are under `.validation/`. Generated artifacts, installed tools and temporary reports are ignored by Git. Source, tests, docs, fixtures, lockfiles and build/CI definitions belong in version control. Do not commit credentials, live place files or generated archives.

## Release procedure

1. Change `Version` and the header in `src/init.luau`; update README, changelog and relevant contracts. Add tests for changed behavior and failure modes. Format with the pinned StyLua using `--verify`, then `--check` until stable.
2. Run the complete local validation command. It regenerates `API.md`, source manifests and both portable profiles. Review the generated API changes.
3. Serve `dist/` locally and explicitly run `tools/studio_verify.luau` in Studio's Edit context. It creates a fresh verification tree to avoid stale require caches, runs **all** suites and examples, then verifies source parity. It restores HttpService.HttpEnabled after transfer. Native tests use in-memory content and never upload assets.
4. Read the chunked report with `tools/studio_read_report.luau`. Require zero failed tests/examples and exact source parity. Preserve the report alongside the artifact manifest. Do not install a running or failed candidate.
5. Create `dist/docs.json` as a name-to-content dictionary of root guides (excluding CHANGELOG), set the three version/candidate placeholders in `tools/studio_install.luau`, and invoke it. Installation uses the verified runtime subset, preserves a local verification report, and retains the two newest prior library archives. Existing scripts holding the old module table must reacquire the new root explicitly.
6. Save the place and verify the save. Remove only the temporary verification tree after successful installation; retained version archives follow the two-version policy. Preserve portable development artifacts outside the place for future tests.
7. Commit only this package and its CI changes. Publish/push through the repository's normal authorized workflow. A GitHub run and any real remote asset smoke test are separate evidence from local validation.

`dist/Editable3D.rbxmx` and `dist/Editable3D-rojo.rbxm` contain runtime, tests, fixtures and examples. `dist/production/` contains runtime modules only (the XML also includes README). Both expose the same public API. `production.project.json` is the equivalent minimal Rojo project.

## Remaining boundaries

This release does not migrate all numerical modules to strict typing, establish whole-library coverage, provide hard memory/preemption guarantees, prove every graph-isomorphism case in native verification, or complete Blender feature parity. Large numerical operators retain their documented algorithmic bounds. Promote additional modules incrementally with contract tests and independently justified numerical fixtures, instead of using passing line coverage as a proof of correctness.
