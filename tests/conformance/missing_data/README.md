# missing_data — a shaped parameter with no data at the front door

CONFORMANCE_SPEC §5.32.6; esm-spec §10.10 ("a parameter with neither a default
nor a supplied value is an error when a problem is built").

Each case in `manifest.json` names a corpus document (mostly outside this
directory) whose shaped parameters have no value in the document itself:

- **Without data**, every binding and every compiler refuses the construction
  with `E_TREEWALK_MISSING_DATA`, and the message names at least one of the
  case's `missing` parameters (by its model-local name or its flattened name).
- **With the case's `const_arrays`** (keyed by flattened name), every compiler
  builds, and where `rhs` is true the right-hand side evaluated at the probe
  state `u[k] = 1 + 0.1*sin(0.37*k)` is bit-for-bit identical between `native`
  and `interpreter` within each binding.

A case whose `missing` is `null` builds without data too; its
`expected_rhs_without_data` / `expected_rhs` pin the exact right-hand side
without and with its arrays (`caller_array_outranks_default`: a caller's array
is the value of a shaped parameter that declares a scalar default).

`loaded_field_default_served`: a data-fed parameter that declares a default,
with no provider and no caller array, takes the default in every binding; no
binding reads the document's own data source unless the caller registers a
provider for it.

The arrays are synthesized: ramps for fields, a wrapped neighbour table for the
stencil documents. They exercise the build and the compiled right-hand side,
not the science.
