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
    ├── api/               # Hand-maintained API overview per language
    ├── examples/          # Worked examples (some generated from tests)
    ├── getting-started/   # Installation, quick start, per-language guides
    ├── troubleshooting/   # Validation, expression, performance, platform
    ├── rfcs/              # Design proposals and extensions
    ├── historical/        # Superseded documents, kept for reference
    ├── tutorial/          # Placeholder — not yet written
    ├── guides/            # Placeholder — not yet written
    ├── standard_library.md, registered_functions.md, units-standard.md
    └── generated/         # Build-time output; not checked in
```

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
   resolves links as site URLs (`getting-started/installation/`), not file paths.
4. Verify with `hugo server --source docs` before pushing; `pages.yml` will
   reject a broken internal link.

## Conventions

- `content/_index.md` is the single table of contents. Do not duplicate the
  navigation tree elsewhere — a second copy drifts.
- Keep API documentation in the source docstrings and let `generate_docs.py`
  surface it, rather than restating signatures by hand.
- The authoritative format definition is [`esm-spec.md`](../esm-spec.md); pages
  here should link to it rather than paraphrase normative rules.
