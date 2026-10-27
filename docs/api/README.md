# API reference inputs

The tooling that builds the API reference moved to
[EarthSciML/earthsci.dev](https://github.com/EarthSciML/earthsci.dev) and is
shared by every EarthSci project. Its README, `tools/api_docs/README.md`, is the
contract: the normalized docstring format, example programs and `region:`
markers, the shared scenarios, usage guides and rendering.

What this repo keeps here:

```
config.toml     per-binding package paths and names (read by the tooling)
groups.toml     topic grouping of the canonical stable operations
examples/       runnable example programs per binding, plus shared fixtures/
guides/         usage-guide prose that pulls in example regions
../../api-surface.json   the canonical-operation manifest
```

Run locally with a checkout of earthsci.dev beside this repo:

```bash
../earthsci.dev/tools/api_docs/python.sh --repo-root .   # likewise julia, typescript, rust, go
python3 ../earthsci.dev/tools/api_docs/render.py --repo-root .
```
