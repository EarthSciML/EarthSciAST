# Documentation Build System

How EarthSciAST's documentation is generated and published. The Hugo site, theme
and API-doc tooling live in [EarthSciML/earthsci.dev](https://github.com/EarthSciML/earthsci.dev)
(see its `DESIGN.md`); this repo supplies content, `docs/site.toml` and
`docs/api/config.toml`.

## Structure

```
docs/
├── README.md              # Orientation for this directory
├── README-DOCS.md         # This file
├── site.toml              # Project metadata and nav for earthsci.dev
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
├── api/                   # API reference inputs: config.toml, groups.toml, examples, guides
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

The reference under `content/generated/api/` is generated from the five
bindings' own docstrings and from runnable example programs by the tooling in
earthsci.dev (`tools/api_docs/`, documented in its README). Inputs kept here:
`docs/api/config.toml`, `api-surface.json`, `docs/api/groups.toml`,
`docs/api/examples/` and `docs/api/guides/`.

```bash
# With ../earthsci.dev checked out
../earthsci.dev/tools/api_docs/python.sh --repo-root .   # likewise julia, typescript, rust, go
python3 ../earthsci.dev/tools/api_docs/render.py --repo-root .
```

`render.py` works with whichever `build/api-docs/*.json` exist; a binding that
was not extracted shows a note in its tabs.

## CI and publishing

[`.github/workflows/docs.yml`](../.github/workflows/docs.yml) runs on pushes to
`main`, pull requests and manual dispatch:

1. `extract`: one job per binding (actions from earthsci.dev) extracts
   docstrings and runs the examples. A failing example fails pull requests; on
   `main` the binding renders as "not extracted".
2. `bundle`: builds the narrative pages (a model that fails validation or an
   inline test stops the run), renders the reference, and assembles the
   bundle. On `main` it force-pushes the bundle to this repo's `docs-bundle`
   branch and dispatches `docs-updated` to earthsci.dev, which refetches every
   project's bundle, builds the site, link-checks it and deploys it. Needs the
   `SITE_DISPATCH_TOKEN` secret.

Pull requests build the bundle but neither publish nor dispatch.

## Adding a page

1. Add the Markdown file under the appropriate `content/` subdirectory.
2. Give it Hugo front matter (`title`, `description`).
3. Link it from `content/_index.md` or the relevant section `_index.md`.
4. Root-relative links are written as if the project were the site root.

## Conventions

- `content/_index.md` is the single table of contents. Do not duplicate the
  navigation tree elsewhere.
- Keep API documentation in the source docstrings; show usage with an example
  region that runs in CI.
- The authoritative format definition is [`esm-spec.md`](../esm-spec.md); pages
  here link to it rather than paraphrase normative rules.
