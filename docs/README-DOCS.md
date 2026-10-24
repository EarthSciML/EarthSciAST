# Documentation Build System

How the EarthSciAST documentation site is generated, built, and deployed.

## Structure

```
docs/
├── README.md              # Orientation for this directory
├── README-DOCS.md         # This file
├── hugo.toml              # Hugo site configuration
├── layouts/               # Hugo templates (api/ and partials/api-tabs.html: the API reference)
├── static/                # Static assets, incl. lib/*.esm standard library
└── content/               # All documentation pages
    ├── _index.md          # Landing page and canonical table of contents
    ├── file-structure/    # The sections of an .esm document, with examples
    ├── operators/         # The expression vocabulary, one page per family
    ├── coupling/          # Composing components
    ├── templates/         # Rewrite rules and discretization
    ├── rfcs/              # Design proposals and the reasoning behind them
    ├── historical/        # Superseded documents, kept for reference
    ├── standard_library.md, units-standard.md
    ├── RELEASE_PIPELINE.md, RELEASE_PROCESS.md
    ├── SCHEMA_CHANGE_PROCEDURE.md, STRUCTURAL_ERROR_TEST_FIXTURES.md
    └── generated/         # Build-time output; not checked in
├── api/                   # API reference inputs: contract, groups.toml, examples, guides
```

## Narrative pages

[`docs/narrative/`](narrative/) holds pages that define an EarthSciAST model in
their own prose. `esm-narrative` assembles the model from the page's directives,
validates it, runs its inline tests, runs its analyses, draws the figures, and
writes the finished page into `content/generated/narrative/` as a page bundle,
`decay/index.md` with `decay.esm` beside it, so the download link is relative
and works under any base URL. Neither output is checked in.

```bash
cargo run --manifest-path pkg/earthsci-narrative/Cargo.toml --bin esm-narrative -- build
cargo run --manifest-path pkg/earthsci-narrative/Cargo.toml --bin esm-narrative -- build --watch
cargo run --manifest-path pkg/earthsci-narrative/Cargo.toml --bin esm-narrative -- build --check
```

The command exits non-zero when a model does not validate or an inline test
fails, which is what stops a bad model reaching the site. The directive syntax
is documented in [`docs/narrative/_index.md`](narrative/_index.md), which is
itself the section's landing page.

## API reference and guides

The API reference under `content/generated/api/` is generated from the five
bindings' own docstrings and from runnable example programs; how is specified
in [`docs/api/README.md`](api/README.md). In short:

```bash
# Per binding (needs that language's toolchain): extract docstrings to
# build/api-docs/<binding>.json and run its examples
scripts/api_docs/python.sh              # likewise julia, typescript, rust, go

# Join them with api-surface.json, docs/api/groups.toml and the guides
python3 scripts/api_docs/render.py      # Python 3.11+
```

`render.py` works with whichever `build/api-docs/*.json` exist; a binding that
was not extracted shows a note in its tabs instead of documentation. Usage
guides live in [`docs/api/guides/`](api/guides/) and pull their code from the
examples with `<!-- example: <region> -->` placeholders.

## Building locally

```bash
hugo server --source docs        # http://localhost:1313
```

Hugo **extended** is required. `pages.yml` pins the version used in CI; match it
if the local build and the deployed site disagree. Run `render.py` first; without
it the site still builds, but the API pages and the links to them are missing.

## CI

| Workflow | Trigger | What it does |
| --- | --- | --- |
| [`docs.yml`](../.github/workflows/docs.yml) | push/PR touching `pkg/**`, `docs/**`, `scripts/api_docs/**` or `api-surface.json` | Runs each binding's `scripts/api_docs/<binding>.sh` in a matrix job (a failing example fails the run), renders the API reference, builds the narrative pages and the site with Hugo, and link-checks it. |
| [`pages.yml`](../.github/workflows/pages.yml) | push to `main` | The same per-binding extraction and render, then builds with Hugo, link-checks the built site with [lychee](https://github.com/lycheeverse/lychee-action), and deploys to GitHub Pages. |

The link check runs against the **built** site and covers internal links only,
so a broken relative link fails the deploy rather than shipping.

## Adding a page

1. Add the Markdown file under the appropriate `content/` subdirectory.
2. Give it Hugo front matter (`title`, `description`) — see any existing page.
3. Link it from `content/_index.md` or the relevant section `_index.md`. Hugo
   resolves links as site URLs (`operators/arrays/`), not file paths.
4. Verify with `hugo server --source docs` before pushing; `pages.yml` will
   reject a broken internal link.

## Conventions

- `content/_index.md` is the single table of contents. Do not duplicate the
  navigation tree elsewhere — a second copy drifts.
- Keep API documentation in the source docstrings and let the API reference
  surface it, rather than restating signatures by hand. Show usage with an
  example region that runs in CI, not with a code block that does not.
- The authoritative format definition is [`esm-spec.md`](../esm-spec.md); pages
  here should link to it rather than paraphrase normative rules.
