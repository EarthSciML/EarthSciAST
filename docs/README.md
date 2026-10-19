# EarthSciAST Documentation

This directory is the source of the documentation site, built with
[Hugo](https://gohugo.io/) and deployed to GitHub Pages by
[`.github/workflows/pages.yml`](../.github/workflows/pages.yml).

## Layout

| Path | Contents |
| --- | --- |
| [`content/`](content/) | All documentation pages. [`content/_index.md`](content/_index.md) is the landing page and the canonical table of contents. |
| `content/generated/` | Pages produced at build time: the API reference and guides by [`scripts/api_docs/render.py`](../scripts/api_docs/render.py), the narrative pages by `esm-narrative`. Not checked in. |
| [`api/`](api/) | Inputs to the API reference: the [contract](api/README.md), topic groups, example programs and usage guides. |
| [`hugo.toml`](hugo.toml) | Site configuration. |
| `layouts/`, `static/` | Templates and static assets (including the `lib/` standard-library `.esm` files). |
| [`README-DOCS.md`](README-DOCS.md) | How the build and generation pipeline works. |

Start from [`content/_index.md`](content/_index.md) rather than this file — it is
the index the site actually renders, so it does not drift from what is published.

## Building locally

```bash
# Generate the API reference (optional; the site builds without it). Uses
# whatever build/api-docs/<binding>.json the scripts/api_docs/<binding>.sh
# scripts have produced; see api/README.md.
python3 scripts/api_docs/render.py

# Serve at http://localhost:1313
hugo server --source docs
```

Hugo **extended** is required, matching the version pinned in `pages.yml`.

## Specification

The authoritative format definition lives at the repository root:

- [`esm-spec.md`](../esm-spec.md) — the format specification
- [`esm-libraries-spec.md`](../esm-libraries-spec.md) — implementation requirements
- [`esm-schema.json`](../esm-schema.json) — machine-readable schema

## Contributing

See [CONTRIBUTING.md](../CONTRIBUTING.md). Documentation issues can be filed in the
[GitHub repository](https://github.com/EarthSciML/EarthSciAST).
