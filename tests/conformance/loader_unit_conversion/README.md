# Loader `unit_conversion` conformance (`tests/conformance/loader_unit_conversion/`)

Cross-binding conformance for **esm-spec §8.5**:

> `unit_conversion` is either a plain multiplicative factor or a full
> `Expression` AST (§4); the runtime applies it **when producing values in the
> declared `units`**.

## Why this set exists

`unit_conversion` was applied on one path in one binding
(`earthsci_ast.data_loaders.variables.apply_unit_conversion`, reached by the
typed variable-mapping helper) and on **no** path in the other two. The ESIO
provider route — `providers_from_document` plus the per-variable provider each
binding hands to `prepare`, i.e. the route a loader-fed model actually gets its
numbers through — did not apply it at all, in any binding. A document could
declare feet→metres and °F→K and be handed feet and Fahrenheit, with no error:
the wrong answer rather than a failure.

That is invisible while the affected columns go unused, which is exactly why it
needs a fixture rather than a review.

## The four cases

One FF10 point loader over the committed four-record
`fixtures/stacks_ff10_point.csv`, whose variables cover every case the runtime
must distinguish:

| Variable | On disk | Declared | `unit_conversion` | Case |
|---|---|---|---|---|
| `annual` | `ANN_VALUE` | `ton/yr` | *(none)* | **the control** — must deliver the raw column, bit for bit |
| `stkhgt` | `STKHGT` (ft) | `m` | `0.3048` | numeric factor |
| `stkdiam` | `STKDIAM` (ft) | `m` | `{"op":"*","args":[0.3048,1.0]}` | **closed** Expression → folds to a factor |
| `stktemp` | `STKTEMP` (°F) | `K` | `(stktemp + 459.67) * 5/9` | **open** Expression, evaluated per element |

The °F→K case is not decoration. §4.8.1 keeps affine offsets OUT of the
dimensional metadata on purpose — `degF` carries the Kelvin dimension and the
scale 5/9, and *"a unit conversion that needs the offset is a `unit_conversion`
expression, not a dimensional judgement"*. A runtime that honours only the
factor spelling silently delivers Fahrenheit.

## The contract

For each fixture, a binding's adapter:

1. Loads `document`, builds providers with `providers_from_document`, passing
   `url_overrides` — each entry's value is a path relative to `tests/`, which
   the adapter turns into an absolute `file://` URL. No network.
2. Samples every key in the golden's `delivered` map and compares to the golden
   **by f64 bits** (the golden's decimals are shortest round-trip, so every
   binding parses the same bits). Not a tolerance: see the manifest.
3. Asserts the **no-op property** — every key in `no_conversion_declared`
   delivers the golden's `raw_columns` entry bit for bit.
4. Asserts the fixture is **load-bearing** — every key NOT in
   `no_conversion_declared` differs from its `raw_columns` entry, so an
   implementation that applies nothing cannot pass.

The golden is analytic: it is plain f64 arithmetic on the raw columns, written
out independently of any binding.

## Adding a fixture

Add the document, its data file, and a golden of the same shape, then add an
entry to `manifest.json`. **No adapter changes** — the adapters iterate the
manifest and are driven entirely by the golden's key sets.
