# Native model shapes (`native_model_shapes`)

The document shapes the downstream models need and the native compilers
refused or mis-evaluated when every downstream document (EqWeFiC, eqice,
moves.esm, isrm.esm) was run through them on 2026-10-15. Each fixture is a
small document built from the minimal reproduction of one gap, with every value
computed by hand in its own `tests` block. The interpreter is the oracle; the
goldens are the Julia interpreter's actuals (CONFORMANCE_SPEC §5.45). `native`
is required for every fixture in Julia and Rust, as everywhere.

## The shapes

| Fixture | Shape | Where it comes from |
|---|---|---|
| `computed_scalar_index_*` | a scalar `index` whose subscript is computed: from a parameter (`x[floor(kp) - 1]`), from a per-column count (`x[kpbl - 1]`), into an inline `const`; dynamic: from a state | YSU `brdn1 = Ri1[kpbl1 - 1]`, wrf_wesely, gwdo (26 EqWeFiC documents) |
| `const_subscript_maps_*` | reversed (`c[6 - i]`), parameter-offset (`p[o + i]`) and min/max-clamped subscripts into an inline `const`, a named `const` observed and a parameter with inline data | madronich `zd`, cloud_grid `idt_above`, rrtm `fp`/`ft` |
| `data_dependent_gather_*` | `c[j[i]]` into an inline `const`; `b[ix[k]]` through an index array; `fld[layer[r]*4 + c]`; an inline `const` selector `const([1,0])[d]` | rrtm_setcoef `jt`; isrm member-index and per-record layer gathers, ring vertex selectors |
| `mod_floor_unflatten_*` | `X[1 + mod(i-1, 2), 1 + floor((i-1)/2)]`, written with `floor`, on an observed, a parameter and an inline `const` | rrtm `pfrac_bNN_flat` (14 documents, incl. eqweather_scm) |
| `nested_scalar_reduction_*` | a rank-0 `faq` inside an array `faq` body: a whole-array sum, a column sum reading the outer index, a filtered prefix sum; dynamic: a column sum of the state | rrtm `o3_clim[L]`, `semis_g`; moves age_distribution |
| `makearray_nested_reduction_*` | a `makearray` whose region value is an array `faq` with a rank-0 `faq` sum nested in its body: one region, `[0, nested]` over the same box, overlapping regions (last wins) with an inner window and a rank-0 total, a gap at the 0 default, an all-`-0.0` fold, a rank-1 face value beside a rank-2 one; dynamic: two states whose right-hand sides are such makearrays, one summing a state; data alternating 1e16 magnitudes so any other fold order shows | EarthSciASTDiff's derived evaluation model, every contracted-index band (issue #547) |
| `ifelse_mixed_boxes_*` | `ifelse` with a runtime scalar condition and branches of different shapes (scalar vs array element) | eqice `strain_term`, `hadv_term`, `w_eff` |
| `guarded_out_of_range_*` | a const subscript that would be out of range, in an `ifelse` branch no cell takes, and one a `faq` filter excludes: nothing may fault | chem_vertical_mixing `rho_w` |
| `ic_const_gather` | `ic(u)` defined by a `faq` gather of an inline `const` (plain, reversed, through a `const` index array) | level_set_tendency_wrffire `ic(psi)` |
| `join_on_computed_key_*` | a value-equality `join` keyed on a const-cadence computed observed (CONFORMANCE_SPEC §5.5.8) | moves F57/F58 controls, seven moves components, gates/equijoin_driven |
| `join_on_parameter_key_*` | a value-equality `join` whose key column is computed from a scalar parameter, which the build bakes (CONFORMANCE_SPEC §5.5.8): the default and a test's `parameter_overrides` both decide the match set | moves fuel_properties, geographic_allocation, liquid_leaking_emissions (`runYearID`, `runCountyID`) |
| `overlap_join_binning_*` | a containment-binning `faq` with an `overlap` gate, beside the same body ungated | every isrm `E_*` rule |
| `polygon_area_in_faq_*` | `polygon_intersection_area` as a `faq` body over partial-rank ring slices, gated and ungated | isrm polygon `E_*` rules |
| `makearray_prefix_scan_*` | a two-region `makearray` whose first region is a prefix-scan `faq` (`filter j < k`, and a `j >= k` suffix variant) and whose second is the rank-0 column total (or 0), on a non-uniform column (#533) | EarthSciDiscretizations column_nonuniform_1d `integral_lev_nodes_cumulative_from_bottom` / `_to_top` (`integral_column_*`) |
| `ragged_contraction_*` | a contraction over a ragged range bounded through an `offsets` factor (`k from edges_of_cell of [i]`), rows of 3, 2, 4 and 1 edges with out-of-range padding; dynamic: inline under a negation, the lowered `u_t = -div(F)` (#534) | EarthSciDiscretizations MPAS `fv_divergence_cell`, `fv_laplacian_cell` (`divergence_mpas`, `laplacian_mpas`) |

Every shape but `ic_const_gather` has two documents. The **static** one has no
state, so every rule is a build-time observed; the **dynamic** one adds a state
whose right-hand side reads the same rules, so they are also lowered on the
run-time path.

The cases where a guarded subscript IS taken, which must fail with
`E_TREEWALK_CONSTARRAY_OOB`, are in `../const_array_gather_bounds/` (the
`guarded_*` fixtures), because a fault is not an inline-test value.

## The build-time path: `ingest/`

A document that ingests data has its rules evaluated by the build pipeline, a
route of its own in Rust. `ingest/` holds the four shapes that only show up
there, each reading a committed parquet table through its own `data_sources`:
a join of an ingested column against a computed key (every moves fixture), a
recurrence in an ingesting document (moves F24b), a gather through an ingested
index column, and an overlap-gated binning over ingested cell envelopes (isrm).
`ingest/manifest.json` lists them. The Rust test
`pkg/earthsci-ast-rs/tests/native_model_shapes_conformance.rs` runs them under
both compilers, and also runs every fixture of this tier with the build pipeline
switched on; both must pass every assertion and native must equal the
interpreter bit for bit. Julia is not gated on `ingest/`: reading parquet needs
Parquet2, which is not in EarthSciAST.jl's test target, and Julia evaluates
these shapes through the same evaluator as the fixtures above.

## Python

Python is out of the native-models round's scope and is `scope_excluded` from
this tier until it is brought in. What it answered on 2026-10-15: every dynamic
document passes under its interpreter except `guarded_out_of_range_dynamic`
(the untaken branch faults, `E_TREEWALK_CONSTARRAY_OOB`); its native also
refuses `nested_scalar_reduction_*`, `overlap_join_binning_*` and
`polygon_area_in_faq_*`; and every static document whose rules read a shaped
parameter fails under both compilers with "Unresolved symbol".

The #535 shape (a construction-time observed carrying an `overlap` join, which
only Python's native refused) is not here, because this tier does not run
Python: it is `overlap_gated_regrid_ode` in `../value_invention_geometry/`,
which requires Python native.

## Named exclusions

None.
