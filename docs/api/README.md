# API reference: how it is built

The site's API reference is one page per **canonical operation** in
[`api-surface.json`](../../api-surface.json), with a tab for each binding that
exports it. Each tab shows that binding's spelling, signatures and docstring,
taken from the binding's own documentation tooling, along with any runnable
examples that use the operation. The usage guides are built from the same
examples, and every example runs in CI, so the reference cannot drift from the
code.

```
api-surface.json                       which symbols exist, their canonical names and tiers
scripts/api_docs/<binding>.sh          extract docstrings + run that binding's examples
  -> build/api-docs/<binding>.json     normalized docstrings (gitignored)
docs/api/examples/<binding>/           runnable example programs, with tagged regions
docs/api/examples/fixtures/            the .esm documents every binding's examples share
docs/api/guides/                       usage-guide prose that pulls in example regions
docs/api/groups.toml                   topic grouping of canonical operations
scripts/api_docs/render.py             joins the above -> docs/content/generated/api/
```

## 1. The per-binding entry point

`scripts/api_docs/<binding>.sh`, for `<binding>` in `julia`, `typescript`,
`python`, `rust`, `go`, does two things from the repository root:

1. **Extracts** documentation for every spelling that `api-surface.json` lists
   under that binding, and writes `build/api-docs/<binding>.json` (§2).
2. **Runs** every example program under `docs/api/examples/<binding>/` and exits
   non-zero if any of them fails.

`--extract-only` and `--examples-only` run one half. The script must work in CI
from a clean checkout once the language toolchain is installed, and must work
locally too. Build output goes under `build/` (gitignored), never `/tmp`.

## 2. The normalized docstring file

```json
{
  "binding": "python",
  "package_version": "0.3.1",
  "extractor": "griffe 1.5.1",
  "symbols": [
    {
      "spelling": "load_path",
      "kind": "function",
      "signatures": ["load_path(path: str | os.PathLike) -> EsmFile"],
      "doc": "Read and parse an `.esm` file.\n\n**Parameters**\n\n- `path` — ...",
      "source": { "path": "pkg/earthsci-ast-py/src/earthsci_ast/io.py", "line": 42 },
      "native_url": null
    }
  ]
}
```

- **One entry per spelling** in `api-surface.json` for this binding, including
  both spellings where the manifest lists an alias pair. A spelling the extractor
  cannot find is still listed, with `"doc": null`, `"signatures": []` and
  `"missing": true`. Extra symbols not in the manifest are left out.
- **`kind`** uses the manifest's vocabulary: `function`, `type`, `error`,
  `constant`.
- **`signatures`** are one string per method or overload, in the binding's own
  syntax. Julia lists every method of an exported function, and Go lists a
  type's exported methods under the type's entry (as further signatures, with
  the receiver). The same goes for TypeScript/Python class members that are
  part of the public surface.
- **`doc`** is CommonMark, with the binding's own conventions converted:
  - Section syntax (Google-style `Args:`/`Returns:`, TSDoc `@param`/`@returns`,
    Rust `# Errors`, Julia `# Arguments`) becomes a bold heading followed by a
    bullet list or paragraph.
  - Cross-references (Julia `[`x`](@ref)`, Rust intra-doc ``[`Foo`]``, TSDoc
    `{@link Foo}`, Go `[Foo]`) become `[`Foo`](api:Foo)`, where `Foo` is this
    binding's spelling. The renderer resolves `api:` links to the canonical
    page, or falls back to plain code.
  - Doctest fences (`jldoctest`, Python `>>>` blocks, Rust ```` ```rust,ignore ````)
    become plain fenced code in the binding's language.
  - When a function has several docstrings (Julia methods), they are joined in
    method order, separated by a horizontal rule.
- **`source.path`** is relative to the repository root.
- **`native_url`** is a deep link to the binding's hosted docs where one exists:
  docs.rs for Rust (`https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.load_path.html`),
  pkg.go.dev for Go. Otherwise `null`.

## 3. Example programs

Each binding has a directory `docs/api/examples/<binding>/` of complete,
runnable programs written in that language's normal style, built against the
in-repo package (not a published release). They use the shared documents in
`docs/api/examples/fixtures/` (`decay.esm`, `ozone.esm`, `coupled.esm`,
`invalid.esm`), located relative to the example file rather than the working
directory.

**Examples check their results.** Each step asserts what it just did, using the
language's ordinary means (`@assert`/`@test`, `assert`, `assert!`, Go
`// Output:` or `t.Fatal`, `node:assert`). An example that only runs is not
enough.

### Regions

The renderer pulls code out of the programs by region markers written as line
comments, using the language's own comment token:

```python
# region: load ops=load_path,load_string
doc = earthsci_ast.load_path(FIXTURES / "decay.esm")
assert list(doc.models) == ["Decay"]
# endregion
```

- The region id comes first. `ops=` lists the **canonical** names
  (`api-surface.json` `name`, never the binding spelling) of the operations the
  region demonstrates. The renderer fails on an unknown canonical name.
- Code inside the region is shown dedented. A line ending in a `hide` comment
  (`# hide`, `// hide`) runs but is not shown; use it for setup the reader does
  not need, never to hide the assertion that proves a result.
- Regions may not nest. The same id may not appear twice within one binding.

### The shared scenarios

So that the guides can show one step side by side in every language, each
binding implements these region ids, for every scenario its capability profile
covers (`api-surface.json` `capability_profiles`). A binding without a stable
operation for a step leaves that region out and says why in the report. It does
not fake one.

| Region id | What it shows | Fixture |
|---|---|---|
| `load` | read a document from a path, and from a JSON string | `decay.esm` |
| `validate` | validate a good document; then show how a bad one's errors surface (result object or exception — whichever the binding does) and read the message | `decay.esm`, `invalid.esm` |
| `inspect` | list models and variables; classify them (states, algebraic unknowns, parameters) | `decay.esm` |
| `display` | render an equation or expression for people (Unicode / LaTeX / text) | `decay.esm` |
| `expressions` | build or parse an expression; free variables; substitute | — |
| `edit` | add a variable and an equation, serialize to JSON, write to a file | `decay.esm` |
| `flatten` | flatten a coupled document; list the resulting variables and equations | `coupled.esm` |
| `reactions` | derive the ODEs of a reaction system | `ozone.esm` |
| `simulate` | build a problem and solve it to t = 10 s; assert N(ln 2 / λ) ≈ 50; read the `half_life` observed (simulating bindings only) | `decay.esm` |

A binding may add further regions, named after the operation they demonstrate,
for important stable operations the scenarios do not reach.
