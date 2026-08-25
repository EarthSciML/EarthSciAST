# EarthSciAST Documentation

This directory is the source of the documentation site, built with
[Hugo](https://gohugo.io/) and deployed to GitHub Pages by
[`.github/workflows/pages.yml`](../.github/workflows/pages.yml).

## Layout

| Path | Contents |
| --- | --- |
| [`content/`](content/) | All documentation pages. [`content/_index.md`](content/_index.md) is the landing page and the canonical table of contents. |
| `content/generated/` | API and example pages produced at build time by [`scripts/generate_docs.py`](../scripts/generate_docs.py). Not checked in. |
| [`hugo.toml`](hugo.toml) | Site configuration. |
| `layouts/`, `static/` | Templates and static assets (including the `lib/` standard-library `.esm` files). |
| [`README-DOCS.md`](README-DOCS.md) | How the build and generation pipeline works. |

Start from [`content/_index.md`](content/_index.md) rather than this file — it is
the index the site actually renders, so it does not drift from what is published.

## Building locally

```bash
# Generate the API + example pages (optional; the site builds without them)
python3 scripts/generate_docs.py --output docs/content/generated

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
