# Releasing EarthSciAST

Five language bindings ship from this repo under one version number:

| Binding | Package | Registry |
| --- | --- | --- |
| Julia | `EarthSciAST` | General registry |
| TypeScript | `@earthsciml/ast` | npm |
| Python | `earthsci-ast` | PyPI |
| Rust | `earthsci-ast` | crates.io |
| Go | `.../pkg/earthsci-ast-go` | Go module proxy |

The editor (`@earthsciml/ast-editor`) is **not** released from this process.

## Package version vs. format version

These are two different numbers and they are *not* kept in lockstep:

- The **esm format version** is `1.0.0`. It appears in every document's `esm`
  field and in the schema `$id`. Changing it is a spec change.
- The **package version** is what these bindings are released as. It starts at
  `0.1.0`.

A test in the TypeScript and Python suites used to assert the two were equal.
They were only ever equal by coincidence; the assertion has been removed.

## One-time setup

None of this can be done from CI — it needs a human with registry accounts.

### npm
The `@earthsciml` scope **does not exist yet**. Create it first, or a scoped
publish cannot succeed:

1. https://www.npmjs.com/org/create → create the `earthsciml` org (free for
   public packages).
2. Create an **automation** access token (Account → Access Tokens).
3. Add it to the repo as the `NPM_TOKEN` secret.

`package.json` already sets `publishConfig.access = "public"`, which is required
— a scoped package defaults to restricted and the first publish would otherwise
fail.

### PyPI
Configure a **trusted publisher** (no token needed) at
https://pypi.org/manage/account/publishing/:

- PyPI project name: `earthsci-ast`
- Owner: `EarthSciML`
- Repository: `EarthSciAST`
- Workflow: `release-publish.yml`
- Environment: `pypi`

Until this exists, the publish job fails with `invalid-publisher`.

### crates.io
Create an API token at https://crates.io/settings/tokens and add it as the
`CARGO_REGISTRY_TOKEN` repo secret. Never commit it — crates.io publishes are
**permanent** (a version can be yanked but never deleted or reused).

### Julia
Install the [JuliaRegistrator](https://github.com/JuliaRegistries/Registrator)
GitHub App on the repository.

### Go
Nothing. The module proxy serves whatever the tag points at.

## Dependency prerequisites

Both the Rust and Julia bindings depend on **EarthSciIO**, which must be
published *before* EarthSciAST can be:

1. **`earthsciio` v0.1.0 → crates.io** (from `EarthSciIO/rust`). The Rust
   binding declares `earthsciio = { path = ..., version = "0.1", optional = true }`;
   cargo resolves the `version` when publishing and rejects a path-only dep.
2. **`EarthSciIO` v0.1.0 → General registry** (from `EarthSciIO/julia`). It is a
   `[weakdeps]` entry of EarthSciAST.jl, and Registrator refuses to register a
   package whose dependencies are not themselves registered.

New packages sit in a **3-day AutoMerge waiting period** in the General
registry, so the Julia binding lands roughly a week after EarthSciIO is
submitted.

## Cutting a release

1. Bump the version in all five manifests **in one reviewed commit**:
   - `pkg/EarthSciAST.jl/Project.toml`
   - `pkg/earthsci-ast-ts/package.json` (and run `npm install --package-lock-only`)
   - `pkg/earthsci-ast-py/pyproject.toml`
   - `pkg/earthsci-ast-rs/Cargo.toml` (and run `cargo generate-lockfile`)
   - Go carries no version in its manifest; it comes from the tag.

   The pipeline reads the version out of the manifests and **fails the run if
   the bindings disagree** — it no longer guesses a version from git tags or
   commit-message keywords.

2. Merge to `main`. `integrated-release-pipeline.yml` then:
   - verifies the five versions agree,
   - skips entirely if tag `v<version>` already exists,
   - runs the security scan (a high/critical finding **blocks** the release),
   - creates the GitHub release and tag,
   - calls `release-publish.yml` to publish to each registry,
   - builds cross-platform binaries and runs conformance.

3. Post the Julia registration comment on the release commit:

   ```
   @JuliaRegistrator register subdir=pkg/EarthSciAST.jl
   ```

   This cannot be automated: registering a package that lives in a
   subdirectory requires the `subdir=` argument, which is only expressible
   through a Registrator comment.

## Things that were broken, and why they are worth not re-breaking

- **`release-publish.yml` was event-driven.** The release is created with
  `GITHUB_TOKEN`, and GitHub does not start workflow runs from
  `GITHUB_TOKEN`-triggered events — so nothing was ever published. It is now
  *called* by the pipeline via `workflow_call`. The `release`/`tag` triggers are
  kept for releases a human creates by hand, which do fire normally.
- **The Go module tag was wrong.** The module path ends in
  `/pkg/earthsci-ast-go`, so Go requires the tag `pkg/earthsci-ast-go/v0.1.0`.
  The old `earthsci-ast-go/v0.1.0` would never resolve via `go get`.
- **The version `sed` was too greedy.** `s/version = "[^"]*"/.../` also matches
  `target-version = "py39"` and `python_version = "3.9"` in `pyproject.toml`,
  silently corrupting the ruff and mypy config.
- **Julia registration never worked.** `julia-actions/RegisterAction` accepts
  only `token` and `registrator`; the `registry:` and `package_dir:` inputs the
  workflow passed were silently ignored.
- **A duplicate beta publish.** `npm-publish-beta` fired on the same `v*` tag as
  the real publish, pushing a throwaway `<version>-beta.<epoch>` alongside every
  release. Removed.
