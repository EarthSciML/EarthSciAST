# EarthSciAST Documentation

This directory holds the **content** of EarthSciAST's documentation. The site
itself (Hugo config, layouts, theme, API-doc tooling) lives in [EarthSciML/earthsci.dev](https://github.com/EarthSciML/earthsci.dev), which
publishes it at <https://earthsci.dev/ast/>. On every push to `main`,
[`.github/workflows/docs.yml`](../.github/workflows/docs.yml) builds a docs
bundle and notifies earthsci.dev, which rebuilds the whole site.

## Layout

| Path | Contents |
| --- | --- |
| [`site.toml`](site.toml) | Project metadata and nav for earthsci.dev. |
| [`content/`](content/) | All documentation pages. [`content/_index.md`](content/_index.md) is the landing page and the canonical table of contents. |
| `content/generated/` | Pages produced at build time: the API reference and guides by earthsci.dev's `tools/api_docs/render.py`, the narrative pages by `esm-narrative`. Not checked in. |
| [`api/`](api/) | Inputs to the API reference: [`config.toml`](api/config.toml), topic groups, example programs and usage guides. |
| [`narrative/`](narrative/) | Narrative page sources. |
| `static/` | Static assets (including the `lib/` standard-library `.esm` files), published under `/ast/`. |
| [`README-DOCS.md`](README-DOCS.md) | How the build and generation pipeline works. |

Start from [`content/_index.md`](content/_index.md) rather than this file.
Write root-relative links as if this project were the site root
(`/generated/api/ref/load_path`); the site build prefixes `/ast`.

## Building locally

Check out [EarthSciML/earthsci.dev](https://github.com/EarthSciML/earthsci.dev) next to this repo.

```bash
# API reference (optional): extract with ../earthsci.dev/tools/api_docs/<binding>.sh --repo-root .
python3 ../earthsci.dev/tools/api_docs/render.py --repo-root .
cargo run --manifest-path pkg/earthsci-narrative/Cargo.toml --bin esm-narrative -- build
```

Then follow earthsci.dev's `tools/api_docs/README.md` ("Local preview") to
assemble and serve the full site.

## Specification

The authoritative format definition lives at the repository root:

- [`esm-spec.md`](../esm-spec.md) — the format specification
- [`esm-libraries-spec.md`](../esm-libraries-spec.md) — implementation requirements
- [`esm-schema.json`](../esm-schema.json) — machine-readable schema

## Contributing

See [CONTRIBUTING.md](../CONTRIBUTING.md). Documentation issues can be filed in the
[GitHub repository](https://github.com/EarthSciML/EarthSciAST).
