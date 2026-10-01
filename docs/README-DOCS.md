# Documentation Build System

How the EarthSciAST documentation site is generated, built, and deployed.

## Structure

```
docs/
├── README.md              # Orientation for this directory
├── README-DOCS.md         # This file
├── hugo.toml              # Hugo site configuration
├── layouts/               # Hugo templates
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

## Generation

[`scripts/generate_docs.py`](../scripts/generate_docs.py) extracts API
documentation from the language implementations and writes example pages.

```bash
# Write generated pages where Hugo expects them
python3 scripts/generate_docs.py --output docs/content/generated
```

Options: `--project-root` (defaults to the working directory), `--output`
(defaults to `docs/`), and `--setup-infrastructure` to scaffold the automation
files. The site builds without this step; generated pages are simply absent.

## Building locally

```bash
hugo server --source docs        # http://localhost:1313
```

Hugo **extended** is required. `pages.yml` pins the version used in CI; match it
if the local build and the deployed site disagree.

## CI

| Workflow | Trigger | What it does |
| --- | --- | --- |
| [`docs.yml`](../.github/workflows/docs.yml) | push/PR touching `pkg/**`, `docs/**`, or `scripts/generate_docs.py` | Regenerates documentation and checks it is current. |
| [`pages.yml`](../.github/workflows/pages.yml) | push to `main` | Runs `generate_docs.py`, builds with Hugo, link-checks the built site with [lychee](https://github.com/lycheeverse/lychee-action), and deploys to GitHub Pages. |

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
- Keep API documentation in the source docstrings and let `generate_docs.py`
  surface it, rather than restating signatures by hand.
- The authoritative format definition is [`esm-spec.md`](../esm-spec.md); pages
  here should link to it rather than paraphrase normative rules.
