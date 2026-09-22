---
title: "Narrative models"
description: "Pages that define a model in their own prose, then validate, test and plot it as they are built."
---

A narrative page is ordinary Markdown with directives in it. `esm-narrative`
reads the directives, assembles them into an `.esm` document, validates it, runs
its inline tests, runs its analyses and draws its figures — then writes the page
you are reading, with the mathematics, results and figures filled in. A model
that does not validate, or a test that fails, stops the build.

Source pages live in `docs/narrative/`; the built pages land in
`docs/content/generated/narrative/` and are not checked in.

## The directives

| Written | Means |
| --- | --- |
| `:var[N]{default=100 units="mol"}` | a state variable, shown as \(N\) |
| `:param[lambda]{default=0.1 units="1/s"}` | a parameter, shown as \(\lambda\) |
| `::model[Decay]{description="…"}` | starts a model; what follows belongs to it |
| `::eq[D(N, t) = -lambda*N]{#eq-decay}` | a display equation, with an anchor |
| `:::esm-test{#id span="0..10"}` … `:::` | an esm-spec §6.6 inline test |
| `:::esm-plot{#id span="0..50" y=N}` … `:::` | one figure, with its own run |
| `:::esm-analysis{#id span="0..100"}` … `:::` | an esm-spec §6.7 analysis and its plots |
| `::esm-example[a + b*c]` | one expression as text, mathematics and JSON |
| `::esm-variables{}` | a table of what the current model declares |
| `::esm-download{}` | a link to the page's `.esm` file |

One colon is inline, two own a line, and three open a block that a line of
`:::` closes. A directive inside a code span or a fenced code block is left
alone, which is how this table shows them. A directive whose name is neither
one of the four model words nor in the `esm-` namespace is passed through
untouched, so a page may use another tool's directives alongside these.

## Attributes and bodies

Attributes go in braces: `{#id key=value key="value with spaces" flag}`. A value
that reads as JSON keeps its type, so `default=100` is a number and
`y=["A","B"]` is a list. `#id` sets whichever field identifies the element — an
equation's `label`, a test's or a plot's `id`.

A block directive's body is YAML in the esm-spec shapes, so anything the format
allows can be written even though the attributes cover only the common fields:

````text
:::esm-plot{#rates span="0..50" y=N}
description: Faster decay constants empty the sample sooner.
parameter_sweep:
  type: cartesian
  dimensions:
    - parameter: lambda
      values: [0.05, 0.1, 0.2]
:::
````

Two attributes are shorthand for longer fields: `span="0..50"` is
`time_span: {start: 0, end: 50}`, and `sliders="lambda=0.01..1 log"` is the
`interactive` list that an interactive figure will read.

## Building

```bash
cargo run --manifest-path pkg/earthsci-narrative/Cargo.toml --bin esm-narrative -- build
cargo run --manifest-path pkg/earthsci-narrative/Cargo.toml --bin esm-narrative -- build --watch
cargo run --manifest-path pkg/earthsci-narrative/Cargo.toml --bin esm-narrative -- build --check   # CI
```

`--check` writes nothing and fails if the generated output is out of date.
Diagnostics are printed as `file:line: error[code]: message`, and every one
also appears on the page, next to the directive that caused it.
