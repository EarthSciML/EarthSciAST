# Release Pipeline

EarthSciAST releases five language bindings and two command-line tools under
one version number. The maintainer checklist, one-time registry setup and
recovery steps are in
[`RELEASING.md`](https://github.com/EarthSciML/EarthSciAST/blob/main/RELEASING.md);
this page describes how the automation fits together.

| Binding or tool | Ships as | Where |
| --- | --- | --- |
| Julia | `EarthSciAST` | General registry |
| TypeScript | `@earthsciml/ast` | npm |
| Python | `earthsci-ast` | PyPI |
| Rust | `earthsci-ast` | crates.io |
| Go | `github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go` | Go module proxy |
| `esm`, `esm-narrative` | per-platform archives | GitHub release |

## Julia first, then everything else

A release runs as three workflows, in order:

1. **Register** (`release-register.yml`). A push to `main` that changes the
   version in `pkg/EarthSciAST.jl/Project.toml` runs the release gates — version
   sync across all nine version sites, a security scan, the conformance suite
   and the MTK compiler-agreement tier — and then asks JuliaRegistrator to
   register that commit, with release notes. Nothing is tagged or published.
2. **Tag** (`TagBot.yml`). When the General registry accepts the
   registration, TagBot tags the registered commit `v<version>` and creates the
   GitHub release from the registration's notes.
3. **Publish** (`release.yml`). The tag push confirms that the tagged commit is
   the one General registered, then publishes to PyPI, crates.io, npm and the
   Go proxy, and attaches `esm` and `esm-narrative` for Linux x64, macOS x64,
   macOS ARM64 and Windows x64 to the release.

The Julia registry goes first because it is the one that can refuse a release
after review, while npm, PyPI and crates.io never let a version number be
reused. If General refuses, the fix is a new commit on `main` and the same
version is registered again from it; no other registry has published anything
yet, so every binding still ships from one commit.

## Version numbers

The package version (currently 0.x) is separate from the esm format version
(`1.0.0`, in every document's `esm` field). Changing the format version is a
spec change; see [`SCHEMA_CHANGE_PROCEDURE.md`](SCHEMA_CHANGE_PROCEDURE.md).
