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
- The **package version** is what these bindings are released as. First release
  was `0.1.1` (`0.1.0` was published to crates.io under the wrong license and
  yanked; a crates.io version can never be reused).

A test in the TypeScript and Python suites used to assert the two were equal.
They were only ever equal by coincidence; the assertion has been removed.

## One-time setup

None of this can be done from CI — it needs a human with registry accounts.

### npm
The `@earthsciml` org must exist and own the scope, and `NPM_TOKEN` must be set
(org-level secret, visible to public repositories). Both are in place.

`package.json` already sets `publishConfig.access = "public"`, which is required
— a scoped package defaults to restricted and the first publish would otherwise
fail.

### PyPI
Configure a **trusted publisher** (no token needed) at
https://pypi.org/manage/account/publishing/:

- PyPI project name: `earthsci-ast`
- Owner: `EarthSciML`
- Repository: `EarthSciAST`
- Workflow: `integrated-release-pipeline.yml`
- Environment: `pypi`

The workflow name is `integrated-release-pipeline.yml` because the PyPI job runs
**directly in that workflow**, not in `release-publish.yml` where the other
registries are handled. That split is deliberate:

> PyPI's trusted publishing does not support reusable workflows.

A `workflow_call` run carries two different claims — `job_workflow_ref` (the
reusable file) and `workflow_ref` (the caller). The OIDC exchange matches the
first, PEP 740 attestations match the second, so **no single publisher
configuration satisfies both**: naming `release-publish.yml` passes the token
exchange and then fails attestation verification, and naming the caller fails the
exchange outright. Publishing from a non-reusable workflow makes the two claims
identical. EarthSciIO avoids the problem by having one workflow overall.

Until this exists, the publish job fails with `invalid-publisher`.

### crates.io
`CARGO_REGISTRY_TOKEN` is set as an org-level secret. Note that a token needs
the **`yank`** scope in addition to publish scopes if you ever have to retract a
version; a publish-only token gets 403 on `cargo yank`. Never commit it —
crates.io publishes are **permanent** (a version can be yanked but never deleted
or reused).

### Julia
Install the [JuliaRegistrator](https://github.com/JuliaRegistries/Registrator)
GitHub App on the repository.

### Go
Nothing. The module proxy serves whatever the tag points at.

## Dependency prerequisites

Both the Rust and Julia bindings depend on **EarthSciIO**:

1. **`earthsciio` → crates.io** — done (0.1.1). The Rust binding declares
   `earthsciio = { path = ..., version = "0.1", optional = true }`; cargo
   resolves the `version` when publishing and rejects a path-only dep.
2. **`EarthSciIO` → General registry** (from `EarthSciIO/julia`) — done.
   `E/EarthSciIO/Package.toml` is in General with `subdir = "julia"` (0.1.1
   merged; 0.1.2 registered 2026-08-24). It is a `[weakdeps]` entry of
   EarthSciAST.jl, and Registrator refuses to register a package whose
   dependencies are not themselves registered, so this was the blocker. It is
   no longer one.

EarthSciAST.jl is still a **new** package to General, so its first registration
sits in a **3-day AutoMerge waiting period**.

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

3. Nothing. Julia registration is automated — `release-publish.yml`'s
   `julia-register` job posts

   ```
   @JuliaRegistrator register subdir=pkg/EarthSciAST.jl
   ```

   on the release commit for you. Registering a subdirectory package does
   require the `subdir=` argument and that argument is only expressible in a
   Registrator comment, but a workflow can post that comment: Registrator
   whitelists `github-actions[bot]` ahead of its collaborator check
   (`Registrator.jl` `src/commentbot/github_utils.jl:36`), and the
   GITHUB_TOKEN recursion rule does not apply because Registrator is a GitHub
   App consuming a webhook, not a workflow run.

   Watch for the registry PR at
   <https://github.com/JuliaRegistries/General/pulls>. If none appears, the
   JuliaRegistrator App has come off the repository — the one prerequisite CI
   cannot satisfy for itself.

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

- **`cargo build --release --all-features` in CI.** `--all-features` enables
  `esio`, whose `earthsciio` dependency is a path into a sibling EarthSciIO
  checkout that no runner has, and `wasm`, which targets another architecture.
  It builds default features now.
- **Release-asset uploads had no tag.** Reached through `workflow_call` from a
  push, `github.ref` is `refs/heads/main`, so the upload action failed with
  "GitHub Releases requires a tag". The tag is now resolved once into
  `RELEASE_TAG` — taking care not to prefix `v` onto a value that already has
  one, which `github.ref_name` and `release.tag_name` both do.
- **Piping git into `head` under `pipefail`.** `head` closing the pipe kills
  `git` with SIGPIPE; with `set -e` that aborted release analysis midway through
  writing a heredoc, leaving an unterminated delimiter. Let git limit itself
  (`git log -n 100`).
