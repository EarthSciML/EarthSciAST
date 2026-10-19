# Releasing EarthSciAST

Five language bindings ship from this repo under one version number:

| Binding | Package | Registry |
| --- | --- | --- |
| Julia | `EarthSciAST` | General registry |
| TypeScript | `@earthsciml/ast` | npm |
| Python | `earthsci-ast` | PyPI |
| Rust | `earthsci-ast` | crates.io |
| Go | `.../pkg/earthsci-ast-go` | Go module proxy |

The `esm` and `esm-narrative` command-line tools ship under the same version,
as per-platform archives attached to the GitHub release.

## How a release runs

Three workflows, in order, so that every registry publishes from the one
commit the Julia General registry accepted:

1. **`release-register.yml`** — on a push to `main` that changes the version in
   `pkg/EarthSciAST.jl/Project.toml`: checks the version sites agree, runs the
   security scan, conformance and the MTK compiler-agreement tier, then posts
   `@JuliaRegistrator register subdir=pkg/EarthSciAST.jl` with release notes on
   that commit. Nothing is tagged or published.
2. **`TagBot.yml`** — when General merges the registration, TagBot tags the
   registered commit `v<version>` and creates the GitHub release from the
   registration's notes.
3. **`release.yml`** — the tag push checks that the tag's
   `pkg/EarthSciAST.jl` tree is the one General registered, then publishes to
   PyPI, crates.io, npm and the Go proxy and attaches the binaries.

The order exists because General can refuse a registration, and the other
registries never let a version be reused. v0.3.0 is the case in point: it
reached npm, PyPI, crates.io and Go, while its General PR sat refused by
AutoMerge for want of release notes on a breaking release. Now a refusal costs
nothing: nothing else has shipped yet.


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
- Workflow: `release.yml`
- Environment: `pypi`

The PyPI job must stay in a workflow that is started directly, never one
reached through `workflow_call`:

> PyPI's trusted publishing does not support reusable workflows.

A `workflow_call` run carries two different claims — `job_workflow_ref` (the
reusable file) and `workflow_ref` (the caller). The OIDC exchange matches the
first, PEP 740 attestations match the second, so **no single publisher
configuration satisfies both**. `release.yml` is started by the tag push, so the
two claims are identical.

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

### TagBot
TagBot pushes the release tag with an SSH deploy key, because a tag pushed with
`GITHUB_TOKEN` starts no workflow and `release.yml` would never run.

1. `ssh-keygen -t ed25519 -N "" -C TagBot -f tagbot` (no passphrase).
2. Repository **Settings → Deploy keys → Add deploy key**: paste `tagbot.pub`,
   tick **Allow write access**.
3. Repository **Settings → Secrets and variables → Actions → New repository
   secret**: name `TAGBOT_SSH_KEY`, value the contents of `tagbot` (the private
   key). Then delete both files.
4. **Settings → Actions → General → Workflow permissions** must be **Read and
   write**, which TagBot needs to create the release with `GITHUB_TOKEN`.

TagBot is triggered by the JuliaTagBot account commenting on an issue in this
repository, so issues must stay enabled. It can also be run by hand from the
Actions tab, which tags every registered version that is still untagged.

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

1. Bump the version in all **nine** places **in one reviewed commit**:
   - `pkg/EarthSciAST.jl/Project.toml`
   - `pkg/earthsci-ast-ts/package.json` (and run `npm install --package-lock-only`)
   - `pkg/earthsci-ast-py/pyproject.toml`
   - `pkg/earthsci-ast-rs/Cargo.toml`, and the crate's own entry in
     `pkg/earthsci-ast-rs/Cargo.lock` (run `cargo metadata --format-version 1 >/dev/null`
     in that directory). The lock IS tracked, and the release job's `cargo build`
     rewrites a stale one, after which `cargo publish` refuses the dirty tree.
     That is how v0.3.0 reached every registry except crates.io.
   - `pkg/earthsci-ast-ts/src/version.ts` — `LIBRARY_VERSION`
   - `pkg/earthsci-ast-go/pkg/esm/version.go` — `LibraryVersion`
   - `pkg/earthsci-narrative/Cargo.toml`, and its own entry in
     `pkg/earthsci-narrative/Cargo.lock` (`cargo metadata --format-version 1
     >/dev/null` in that directory). It is not published to crates.io, but the
     `esm-narrative` binary ships on the release. Refreshing that lock also
     updates `pkg/earthsci-typst-plugin/Cargo.lock` if you run it there too.

   The last two are **hand-kept mirrors**, and they are the ones that get
   forgotten. Julia (`pkgversion`), Python (`importlib.metadata`) and Rust
   (`env!("CARGO_PKG_VERSION")`) all derive `LIBRARY_VERSION` from their
   manifest and need nothing. TypeScript cannot import `package.json`
   (tsconfig's `rootDir` is `./src`) and a Go module has no in-tree version
   manifest at all, so both mirror the number by hand.

   `./scripts/check-version-sync.sh` checks all nine and runs in the lint job.
   Go carries no version in its own manifest; the module version comes from
   the tag.

   The pipeline reads the version out of the manifests and **fails the run if
   the bindings disagree** — it no longer guesses a version from git tags or
   commit-message keywords.

   For a breaking release (any 0.x minor bump), also write
   `release-notes/v<version>.md` saying what broke and how to upgrade. It goes
   first in the registration's release notes and from there into the GitHub
   release. Without it the notes are generated from the commit log; they always
   carry "Breaking changes" and "Changelog" headings, which is what General's
   AutoMerge looks for, but they only list breaking commits marked `type!:` or
   `BREAKING CHANGE:`.

2. Merge to `main`. `release-register.yml` runs the gates (about an hour,
   conformance's Julia matrix being the long pole) and posts the registration
   comment. JuliaRegistrator replies on the commit with a link to the PR
   against [General](https://github.com/JuliaRegistries/General/pulls).

3. **If AutoMerge passes**, there is nothing to do. General merges in about 15
   minutes, TagBot tags `v<version>`, and `release.yml` publishes everything
   else from that tag and attaches the binaries.

   **If AutoMerge refuses**, read its comment on the General PR, fix the cause
   on `main` (no version bump: the version is still unpublished everywhere),
   then run **Release 1 - Register Julia** by hand from the Actions tab. It
   registers the same version from the new commit, and Registrator updates the
   open PR in place. A push that leaves the version unchanged never registers by
   itself, so unrelated work merged while a registration is pending does not
   move it.

4. **If `release.yml` fails partway**, it opens an issue. Fix the cause and run
   **Release 3 - Publish** by hand with the tag; every step skips what already
   published.

Registration from a workflow works because Registrator whitelists
`github-actions[bot]` ahead of its collaborator check (`Registrator.jl`
`src/commentbot/github_utils.jl:36`), and the GITHUB_TOKEN recursion rule does
not apply to it: Registrator is a GitHub App consuming a webhook, not a workflow
run. If no reply appears on the commit, the JuliaRegistrator App has come off
the repository.

## Things that were broken, and why they are worth not re-breaking

- **Every registry but General published v0.3.0.** All five bindings were
  released together, the moment the version bump reached `main`; General then
  refused the registration (a breaking release with no release notes), and a
  fix would have had to come from a new commit the other registries could
  never match. Hence the register → TagBot → publish order above.
- **The Linux `esm` only ran on the newest distributions.** It was built
  natively on `ubuntu-latest`, so it required that runner's glibc (2.39) and
  v0.3.0's binary would not start on RHEL 9 (2.34). The Linux builds now link
  against glibc 2.17 with `cargo-zigbuild`, and a step fails the build if
  either binary needs anything newer.
- **Releases were validated after they shipped.** Conformance ran against the
  tag in parallel with the publish jobs. It gates the registration now.
- **Two workflows each created a GitHub release.** `binary-release.yml` made its
  own beside the pipeline's (one of them a stray draft named
  `refs/heads/main`), and two jobs overwrote each other's release notes, one of
  them reading a `release_id` output that was never set. TagBot alone creates
  the release now, and `release.yml` only appends below a marker.

- **Both hand-kept version mirrors shipped stale in v0.2.0.** The four
  manifests were bumped; `LIBRARY_VERSION` in TypeScript and `LibraryVersion`
  in Go were not, so 0.2.0 reports `0.1.1` from both. TypeScript's
  `version.test.ts` caught it — after publishing, because conformance does not
  gate the publish jobs. Go had no guard at all. Hence
  `scripts/check-version-sync.sh` in lint, which runs before any release.
- **`binary-release.yml` resolved its version from `GITHUB_REF`.** Reached
  through `workflow_call`, `github.event_name` is the *caller's* event
  (`push`), so it fell through to `${GITHUB_REF#refs/tags/}` on
  `refs/heads/main` and tried to create a release tagged `refs/heads/main`:
  "branch or tag names starting with 'refs/' are not allowed". It reads
  `inputs.version` first now, and fails loudly rather than passing a `refs/…`
  string to the API. Same class of bug as the release-asset upload below.
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
