//! Simulation-output derivation — the Rust mirror of `EarthSciAST.jl`'s
//! `src/data_output.jl` (streaming-output-sinks RFC §7–§9).
//!
//! A solved model hands back a **flat** state vector whose elements are named
//! by the column-major cell-key scheme `name[i,j,…]` (1-based, dim 0 varying
//! fastest — see `simulate_array::compile::build_slot_tables`). A Zarr writer
//! wants the opposite: **dimension-labeled, row-major (C-order) arrays** with
//! CF metadata. This module is the inversion between the two, plus the
//! document-derived metadata that turns positional axes into real `index_sets`
//! names and CF coordinates.
//!
//! It is deliberately I/O-free and writer-agnostic: it produces a *plan*
//! ([`OutputPlan`]), never a store. The plan's field shapes are chosen to drop
//! straight into `earthsciio::format::OutputSchema` / `WriteVar` / `WriteCoord`
//! (see [`OutputPlan`] docs for the exact correspondence), but nothing here
//! links EarthSciIO — the same plan feeds any writer, native or wasm.
//!
//! ## Layers (each independently useful, in dependency order)
//!
//! 1. [`parse_cell_key`] + [`derive_output_gridding`] — the **flat→gridded
//!    inversion** (§7). Language-neutral: the cell-key scheme is identical in
//!    Julia, Python and Rust, so this inversion is specified once and must
//!    agree across all three.
//! 2. [`derive_output_meta`] — the document slice a writer needs: real axis
//!    names (a variable's declared `shape`), per-axis lengths, CF variable
//!    attributes, the additive `coordinates` registry (§8.3), and the time-axis
//!    name.
//! 3. [`plan_dimension_coordinates`] — CF **dimension coordinates** (values +
//!    `standard_name` / `units` / `axis`) resolved from that registry (§8).
//! 4. [`group_gridding_by_grid`] — partition variables into **grids** by their
//!    spatial-dim signature (§9). Grids are emergent, never declared.
//! 5. [`derive_output_plan`] — all of the above, plus the RFC decision-8 rule
//!    that output is the state **plus a caller-named subset** of observed
//!    fields (not every observed by default).
//!
//! ## wasm32
//!
//! This module must compile for `wasm32-unknown-unknown` — the browser runner
//! *is* this crate compiled to wasm. It therefore uses no filesystem, no
//! threads, and **no wall clock**: `std::time::Instant::now()` aborts a wasm32
//! module with a bare `unreachable`, which once killed every spatial run in the
//! browser. There is no timing or instrumentation here, deliberately.
//!
//! ## Cross-language agreement with the Julia reference
//!
//! This module and `EarthSciAST.jl`'s `src/data_output.jl` are the same
//! derivation in two languages, and they are gated as such: the corpus at
//! `tests/conformance/output_derivation/` drives both from one set of `.esm`
//! fixtures + flat slot names and asserts one committed golden per case
//! (`tests/output_derivation_conformance.rs` here, the
//! `output_derivation_conformance_test.jl` twin there). Four behaviours below
//! were divergences the two implementations carried silently until that corpus
//! existed; RFC §16.12 records the reconciliation and the evidence. **All four
//! resolved in this module's favour, and the Julia now matches.**
//!
//! * **Scalars carry no synthetic axis.** `data_output.jl` used to give a
//!   scalar the singleton shape `[1]` with the positional dim name
//!   `"<base>_d0"`, which made every scalar its own single-member grid under
//!   `group_gridding_by_grid`: 66 scalar states meant 66 length-1 dimensions
//!   named after their own variables and 66 separate grids. Here a scalar has
//!   `shape == []` and `dim_names == []`, so it is genuinely
//!   0-spatial-dimensional, every scalar lands in ONE grid, and its on-disk
//!   dims are exactly `[time_dim]` — what CF, Zarr and xarray all expect, and a
//!   rank the store already contains (the `time` coordinate is one). Positional
//!   `"<base>_d0"` naming is retained verbatim for *gridded* variables with no
//!   declared `shape`, where it is load-bearing.
//! * **The record axis leads.** [`VarPlan::dims`] is the record axis followed by
//!   the spatial axes. Julia's `ZarrSink` used to append the record axis last.
//!   Record-first is CF §2.4's T,Z,Y,X recommendation, the order a NetCDF
//!   unlimited dimension requires, the order EarthSciIO's shared
//!   `write_spec.json` already pins for all three writers, and the layout that
//!   keeps one appended record contiguous on disk.
//! * **Density is validated.** The Julia used to derive each axis length as the
//!   max cell index and never check that the cells cover the grid, so a gap left
//!   an uninitialized hole and a repeat silently dropped a slot. An incomplete
//!   or double-covered grid is [`OutputError::SparseGrid`] /
//!   [`OutputError::DuplicateCell`].
//! * **Namespaced lookups.** The Julia used to look a var_map base name up in a
//!   table keyed by *bare* variable name, so a flattened `Model.u` silently fell
//!   back to positional axis names. [`OutputMeta`] registers both the bare and
//!   the `Model.`-qualified key (dropping a bare key that two models would make
//!   ambiguous) and additionally falls back to the last dotted segment.
//!
//! One difference remains, and is not a divergence in behaviour:
//! **`standard_name` is not retained per variable.** `derive_output_meta` in
//! Julia copies `units` / `standard_name` / `description` off the raw variable
//! dict. Neither `ModelVariable` nor `esm-schema.json`'s `ModelVariable` has a
//! `standard_name` property — `additionalProperties` is `false` — so no
//! schema-valid document can carry one and the typed Rust binding models
//! `units` and `description` only.

use std::collections::{BTreeMap, BTreeSet, HashMap};

use serde_json::{Map as JsonMap, Value as JsonValue};

use crate::types::{Coordinate, EsmFile, IndexSet, VariableType};

/// The element type every output array carries. The flat solver state is
/// `f64` throughout, so this is currently a constant rather than a per-variable
/// property; it exists so a writer can name a dtype without hard-coding one.
pub const DTYPE_FLOAT64: &str = "float64";

/// Fallback name for the record axis when the document declares no
/// `domain.independent_variable`.
pub const DEFAULT_TIME_DIM: &str = "time";

// --------------------------------------------------------------------------
// Errors
// --------------------------------------------------------------------------

/// Failure deriving an [`OutputPlan`] — the output-side mirror of the loader
/// seam's errors. Every variant names the offending variable or dimension:
/// a mislabeled axis is silently wrong science, so these fail loudly.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum OutputError {
    /// A scalar (bracket-free) cell key appeared more than once.
    #[error(
        "scalar variable '{base}' maps to {count} flat indices; a scalar cell key must be unique"
    )]
    DuplicateScalar { base: String, count: usize },

    /// Cells of one variable disagreed on how many axes the variable has.
    #[error(
        "variable '{base}' has cells of differing dimensionality ({got} vs {expected}); a gridded variable must be rectangular"
    )]
    RaggedRank {
        base: String,
        got: usize,
        expected: usize,
    },

    /// A cell key carried a 0 (or negative) index; cell keys are 1-based.
    #[error("variable '{base}' has cell index 0 on axis {axis}; cell keys are 1-based")]
    ZeroIndex { base: String, axis: usize },

    /// The variable's cells do not cover its grid.
    #[error(
        "variable '{base}' supplies {got} cell(s) for a {shape:?} grid of {want}; a gridded output variable must be dense"
    )]
    SparseGrid {
        base: String,
        shape: Vec<usize>,
        got: usize,
        want: usize,
    },

    /// Two flat slots claimed the same grid cell.
    #[error("variable '{base}' maps two flat slots to grid cell {cell:?}")]
    DuplicateCell { base: String, cell: Vec<usize> },

    /// The document's declared `shape` has a different rank than the flat state.
    #[error(
        "output metadata for '{base}' declares {declared} dim(s) {dims:?}, but the flat state grids it to {actual} axis/axes {shape:?}"
    )]
    DimCountMismatch {
        base: String,
        dims: Vec<String>,
        declared: usize,
        shape: Vec<usize>,
        actual: usize,
    },

    /// A declared index set's length disagrees with the recovered axis length.
    #[error(
        "output metadata: '{base}' axis {axis} is index set '{dim}' of size {size}, but the flat state grids that axis to length {len}"
    )]
    DimLengthMismatch {
        base: String,
        axis: usize,
        dim: String,
        size: usize,
        len: usize,
    },

    /// Two variables on one grid disagree about a shared dimension's length.
    #[error(
        "dimension '{dim}' has length {a} on variable '{first}' but length {b} on variable '{second}'"
    )]
    DimLengthConflict {
        dim: String,
        first: String,
        a: usize,
        second: String,
        b: usize,
    },

    /// A spatial dimension collides with the record (time) axis name.
    #[error(
        "variable '{base}' has a spatial dimension named '{dim}', which collides with the record axis"
    )]
    TimeDimCollision { base: String, dim: String },

    /// A `coordinates` entry's inline `values` length does not match its axis.
    #[error("coordinate '{name}' supplies {got} value(s) but dimension '{name}' has length {want}")]
    CoordLengthMismatch {
        name: String,
        got: usize,
        want: usize,
    },

    /// The caller asked for an observed field that has no slot in the flat
    /// state. Silently dropping a requested output is worse than refusing.
    #[error(
        "requested observed output '{name}' has no slot in the flat state; the runner must evaluate and append it before the plan is derived"
    )]
    UnknownObserved { name: String },

    /// A scatter/gather call was handed a buffer of the wrong length.
    #[error("variable '{base}': {what} buffer holds {got} element(s), need {want}")]
    BufferLength {
        base: String,
        what: &'static str,
        got: usize,
        want: usize,
    },
}

// --------------------------------------------------------------------------
// §7 — the flat→gridded inversion
// --------------------------------------------------------------------------

/// Split a flat state-element name into `(base, 1-based indices)`, or `None`
/// when it is not a well-formed cell key (no bracket suffix, an empty base
/// name, or a non-integer index). The exact inverse of the `"{name}[{i},{j}]"`
/// formatting in `simulate_array::compile::build_slot_tables`, and the Rust
/// twin of Julia's `_parse_cell_key` / Python's equivalent.
///
/// Matches the Julia regex `^([^\[]+)\[([0-9]+(?:,[0-9]+)*)\]$`: the base name
/// may not itself contain `[`, so the FIRST bracket opens the index list.
///
/// ```
/// use earthsci_ast::data_output::parse_cell_key;
/// assert_eq!(parse_cell_key("u[2,3]"), Some(("u", vec![2, 3])));
/// assert_eq!(parse_cell_key("Model.u[7]"), Some(("Model.u", vec![7])));
/// assert_eq!(parse_cell_key("plain"), None);
/// ```
pub fn parse_cell_key(key: &str) -> Option<(&str, Vec<usize>)> {
    let open = key.find('[')?;
    if open == 0 {
        return None; // empty variable name
    }
    let inner = key.strip_suffix(']')?.get(open + 1..)?;
    if inner.is_empty() {
        return None;
    }
    let mut indices = Vec::new();
    for part in inner.split(',') {
        if part.is_empty() || !part.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        indices.push(part.parse::<usize>().ok()?);
    }
    Some((&key[..open], indices))
}

/// The gridded layout of one output base-variable, derived from the flat
/// state-element names (RFC §7).
///
/// The inversion is baked into [`Self::flat_indices`]: it is indexed by
/// **row-major (C-order) offset** within [`Self::shape`] and holds the
/// *column-major* flat state index that feeds that cell. Scattering is
/// therefore a single linear pass with the transposition already applied —
/// `out[o] = u[flat_indices[o]]` — which is exactly the layout
/// `earthsciio::format::WriteVar::data` requires.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VarGridding {
    /// The variable's base name — the cell key minus its `[…]` suffix, so
    /// possibly namespaced (`"Model.u"`) depending on the build path.
    pub base: String,
    /// The gridded spatial shape, in cell-key axis order. **Empty** for a
    /// scalar variable (see the module-level divergence note).
    pub shape: Vec<usize>,
    /// One name per axis of [`Self::shape`]: the variable's declared
    /// `index_sets` names once [`OutputMeta`] has been applied, otherwise the
    /// positional placeholders `"<base>_d0"`, `"<base>_d1"`, ….
    pub dim_names: Vec<String>,
    /// Flat state index of each grid cell, indexed by row-major offset.
    /// Length is `shape.iter().product()` (1 for a scalar).
    pub flat_indices: Vec<usize>,
}

impl VarGridding {
    /// Number of grid cells (1 for a scalar).
    #[must_use]
    pub fn n_cells(&self) -> usize {
        self.flat_indices.len()
    }

    /// True when the variable has no spatial axes.
    #[must_use]
    pub fn is_scalar(&self) -> bool {
        self.shape.is_empty()
    }

    /// The 0-based grid position of the cell at row-major offset `cell`.
    /// The Rust counterpart of Julia's `VarGridding.cart` entries (which are
    /// 1-based `CartesianIndex`es).
    #[must_use]
    pub fn cart(&self, cell: usize) -> Vec<usize> {
        let mut out = vec![0usize; self.shape.len()];
        let mut rem = cell;
        for d in (0..self.shape.len()).rev() {
            let n = self.shape[d].max(1);
            out[d] = rem % n;
            rem /= n;
        }
        out
    }

    /// Scatter one flat state slab into `out`, a row-major array of
    /// [`Self::shape`]. The Rust twin of Julia's `scatter_grid!`.
    ///
    /// # Errors
    /// [`OutputError::BufferLength`] when `out` is not exactly `n_cells()`
    /// long, or `flat_u` does not reach one of the variable's slots.
    pub fn scatter(&self, flat_u: &[f64], out: &mut [f64]) -> Result<(), OutputError> {
        self.scatter_record(flat_u, out, 0)
    }

    /// Scatter one flat state slab into record `record` of a
    /// `[time, …spatial]` row-major buffer — the whole-trajectory form, where
    /// `out` holds `n_records * n_cells()` values and record `r` occupies
    /// `out[r * n_cells() .. (r + 1) * n_cells()]`.
    ///
    /// # Errors
    /// [`OutputError::BufferLength`] when the record does not fit in `out`, or
    /// `flat_u` does not reach one of the variable's slots.
    pub fn scatter_record(
        &self,
        flat_u: &[f64],
        out: &mut [f64],
        record: usize,
    ) -> Result<(), OutputError> {
        let n = self.n_cells();
        let start = record * n;
        let have = out.len();
        let slot = out
            .get_mut(start..start + n)
            .ok_or_else(|| OutputError::BufferLength {
                base: self.base.clone(),
                what: "gridded output",
                got: have,
                want: start + n,
            })?;
        for (o, &fi) in self.flat_indices.iter().enumerate() {
            slot[o] = *flat_u.get(fi).ok_or_else(|| self.short_state(flat_u, fi))?;
        }
        Ok(())
    }

    /// The inverse of [`Self::scatter`] — read a gridded slab back into the
    /// flat state (the checkpoint-restart direction, RFC §10). The Rust twin of
    /// Julia's `gather_flat!`.
    ///
    /// # Errors
    /// [`OutputError::BufferLength`] when `grid` is not `n_cells()` long or
    /// `flat_u` does not reach one of the variable's slots.
    pub fn gather(&self, grid: &[f64], flat_u: &mut [f64]) -> Result<(), OutputError> {
        if grid.len() != self.n_cells() {
            return Err(OutputError::BufferLength {
                base: self.base.clone(),
                what: "gridded input",
                got: grid.len(),
                want: self.n_cells(),
            });
        }
        for (o, &fi) in self.flat_indices.iter().enumerate() {
            let have = flat_u.len();
            let cell = flat_u.get_mut(fi).ok_or(OutputError::BufferLength {
                base: self.base.clone(),
                what: "flat state",
                got: have,
                want: fi + 1,
            })?;
            *cell = grid[o];
        }
        Ok(())
    }

    fn short_state(&self, flat_u: &[f64], fi: usize) -> OutputError {
        OutputError::BufferLength {
            base: self.base.clone(),
            what: "flat state",
            got: flat_u.len(),
            want: fi + 1,
        }
    }
}

/// Scatter a flat state slab into a row-major gridded buffer. Free-function
/// form of [`VarGridding::scatter`], mirroring Julia's `scatter_grid!`.
///
/// # Errors
/// See [`VarGridding::scatter`].
pub fn scatter(g: &VarGridding, flat_u: &[f64], out: &mut [f64]) -> Result<(), OutputError> {
    g.scatter(flat_u, out)
}

/// Read a row-major gridded buffer back into the flat state. Free-function
/// form of [`VarGridding::gather`], mirroring Julia's `gather_flat!`.
///
/// # Errors
/// See [`VarGridding::gather`].
pub fn gather(g: &VarGridding, grid: &[f64], flat_u: &mut [f64]) -> Result<(), OutputError> {
    g.gather(grid, flat_u)
}

/// Invert the flat state-element names into one [`VarGridding`] per output
/// base-variable (RFC §7), the flat index of a name being its position in
/// `slot_names` — the shape `Solution::state_variable_names` already has.
///
/// Base-variable order is sorted by base name, matching Julia, so a derived
/// plan is reproducible and cross-language comparable.
///
/// # Errors
/// See [`OutputError`]: a ragged rank, a duplicated scalar key, a 0 index, or
/// a grid the cells do not densely cover.
pub fn derive_output_gridding(slot_names: &[String]) -> Result<Vec<VarGridding>, OutputError> {
    derive_output_gridding_from_map(slot_names.iter().enumerate().map(|(i, n)| (n.as_str(), i)))
}

/// [`derive_output_gridding`] over an explicit `(name, flat index)` mapping —
/// the direct analog of Julia's `derive_output_gridding(var_map)`, for callers
/// whose flat index is not the position in a slice.
///
/// # Errors
/// See [`derive_output_gridding`].
pub fn derive_output_gridding_from_map<'a, I>(entries: I) -> Result<Vec<VarGridding>, OutputError>
where
    I: IntoIterator<Item = (&'a str, usize)>,
{
    // base => [(flat index, 1-based cell indices)]
    let mut groups: BTreeMap<String, Vec<(usize, Vec<usize>)>> = BTreeMap::new();
    for (key, idx) in entries {
        let (base, inds) = match parse_cell_key(key) {
            Some((b, i)) => (b.to_string(), i),
            None => (key.to_string(), Vec::new()),
        };
        groups.entry(base).or_default().push((idx, inds));
    }

    // BTreeMap iteration is sorted by base name — Julia's `sort!(collect(keys))`.
    groups
        .into_iter()
        .map(|(base, entries)| grid_one_variable(base, entries))
        .collect()
}

fn grid_one_variable(
    base: String,
    entries: Vec<(usize, Vec<usize>)>,
) -> Result<VarGridding, OutputError> {
    let ndim = entries.iter().map(|(_, i)| i.len()).max().unwrap_or(0);

    if ndim == 0 {
        if entries.len() != 1 {
            return Err(OutputError::DuplicateScalar {
                base,
                count: entries.len(),
            });
        }
        let flat = entries[0].0;
        return Ok(VarGridding {
            base,
            shape: Vec::new(),
            dim_names: Vec::new(),
            flat_indices: vec![flat],
        });
    }

    let mut shape = vec![0usize; ndim];
    for (_, inds) in &entries {
        if inds.len() != ndim {
            return Err(OutputError::RaggedRank {
                base,
                got: inds.len(),
                expected: ndim,
            });
        }
        for (d, &i) in inds.iter().enumerate() {
            if i == 0 {
                return Err(OutputError::ZeroIndex { base, axis: d });
            }
            shape[d] = shape[d].max(i);
        }
    }

    let total: usize = shape.iter().product();
    if entries.len() != total {
        return Err(OutputError::SparseGrid {
            base,
            shape,
            got: entries.len(),
            want: total,
        });
    }

    // The inversion itself: place each flat slot at its ROW-MAJOR offset, so
    // the resulting vector is already in the C order a Zarr writer wants while
    // the flat state it reads from stays column-major.
    let mut flat_indices = vec![usize::MAX; total];
    for (flat, inds) in &entries {
        let mut off = 0usize;
        for (d, &i) in inds.iter().enumerate() {
            off = off * shape[d] + (i - 1);
        }
        if flat_indices[off] != usize::MAX {
            return Err(OutputError::DuplicateCell {
                base,
                cell: inds.clone(),
            });
        }
        flat_indices[off] = *flat;
    }

    let dim_names = (0..ndim).map(|d| format!("{base}_d{d}")).collect();
    Ok(VarGridding {
        base,
        shape,
        dim_names,
        flat_indices,
    })
}

// --------------------------------------------------------------------------
// §7/§8 — document-derived output metadata
// --------------------------------------------------------------------------

/// The document slice a streaming writer needs so it can name axes and emit CF
/// coordinates (RFC §7–§8) without importing the document model. Distilled from
/// an [`EsmFile`] by [`derive_output_meta`]; the Rust mirror of Julia's
/// `OutputMeta`.
///
/// The `var_*` maps are keyed by BOTH the bare variable name and its
/// `Model.`-qualified form, because a flat state's element names are namespaced
/// on the coupled/flattened path and bare on the single-model path. A bare key
/// that two models would make ambiguous is dropped, so an ambiguous lookup
/// falls back to positional axis names rather than guessing.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct OutputMeta {
    /// Model keys present in the document, sorted.
    pub model_names: Vec<String>,
    /// Index-set name → axis length. `0` marks a length only the build knows
    /// (`derived` / `ragged` sets), which callers treat as "unconstrained".
    pub index_sets: BTreeMap<String, usize>,
    /// Variable name → its declared `shape` (ordered index-set names). Absent
    /// for scalars.
    pub var_dims: BTreeMap<String, Vec<String>>,
    /// Variable name → retained CF attributes (`units`, `description`).
    pub var_attrs: BTreeMap<String, JsonMap<String, JsonValue>>,
    /// Variable name → declared kind, so observed fields can be gated on the
    /// caller's request list (RFC decision 8).
    pub var_types: BTreeMap<String, VariableType>,
    /// Keys (bare and qualified) of the variables that are OBSERVED unknowns.
    /// Observedness is derived from the equations (esm-spec §6.3.1), not from
    /// the declared type, so it needs its own set alongside `var_types`.
    pub observed_keys: std::collections::BTreeSet<String>,
    /// The additive document-scoped `coordinates` registry (§8.3), verbatim.
    pub coordinates: BTreeMap<String, Coordinate>,
    /// Record-axis name: `domain.independent_variable`, else `"time"`.
    pub time_dim: String,
}

impl OutputMeta {
    /// Look a flat base name up in one of the `var_*` tables: exact first, then
    /// the last dotted segment (a nested namespace the exact keys do not
    /// cover).
    fn lookup<'m, T>(&self, table: &'m BTreeMap<String, T>, base: &str) -> Option<&'m T> {
        if let Some(v) = table.get(base) {
            return Some(v);
        }
        let bare = base.rsplit('.').next()?;
        if bare == base {
            return None;
        }
        table.get(bare)
    }

    /// The declared dimension names of `base`, if the document has them.
    #[must_use]
    pub fn dims_of(&self, base: &str) -> Option<&Vec<String>> {
        self.lookup(&self.var_dims, base)
    }

    /// The declared kind of `base`, if the document has it.
    #[must_use]
    pub fn type_of(&self, base: &str) -> Option<&VariableType> {
        self.lookup(&self.var_types, base)
    }

    /// Is `base` an OBSERVED unknown (esm-spec §6.3.1)?
    #[must_use]
    pub fn is_observed(&self, base: &str) -> bool {
        self.observed_keys.contains(base)
            || self
                .model_names
                .iter()
                .any(|m| self.observed_keys.contains(&format!("{m}.{base}")))
    }

    /// The retained CF attributes of `base`.
    #[must_use]
    pub fn attrs_of(&self, base: &str) -> Option<&JsonMap<String, JsonValue>> {
        self.lookup(&self.var_attrs, base)
    }
}

/// Static axis length of an index set: `size` for `interval`, member count for
/// `categorical`, and `size` (or 0 = "known only after the build") otherwise.
fn index_set_axis_len(is: &IndexSet) -> usize {
    match is.kind.as_str() {
        "categorical" => is.members.as_ref().map_or(0, Vec::len),
        // `interval` and anything else fall back to a declared `size`.
        _ => usize::try_from(is.size.unwrap_or(0)).unwrap_or(0),
    }
}

/// Distill a run document into [`OutputMeta`] — the Rust mirror of Julia's
/// `derive_output_meta`. Reads only the document (no build artifacts), so it
/// composes with [`derive_output_gridding`].
#[must_use]
pub fn derive_output_meta(doc: &EsmFile) -> OutputMeta {
    let mut meta = OutputMeta {
        time_dim: doc
            .domain
            .as_ref()
            .and_then(|d| d.independent_variable.clone())
            .unwrap_or_else(|| DEFAULT_TIME_DIM.to_string()),
        ..OutputMeta::default()
    };

    if let Some(sets) = &doc.index_sets {
        for (name, is) in sets {
            meta.index_sets.insert(name.clone(), index_set_axis_len(is));
        }
    }

    if let Some(coords) = &doc.coordinates {
        for (name, c) in coords {
            meta.coordinates.insert(name.clone(), c.clone());
        }
    }

    let Some(models) = &doc.models else {
        return meta;
    };
    meta.model_names = models.keys().cloned().collect();
    meta.model_names.sort();

    // Bare names claimed by more than one model are ambiguous; only the
    // qualified key survives for those.
    let mut bare_counts: BTreeMap<&str, usize> = BTreeMap::new();
    for model in models.values() {
        for vn in model.variables.keys() {
            *bare_counts.entry(vn.as_str()).or_insert(0) += 1;
        }
    }

    for mname in &meta.model_names {
        let model = &models[mname];
        let observed: std::collections::HashSet<String> =
            crate::classify::observed_unknowns(model).into_iter().collect();
        let mut vnames: Vec<&String> = model.variables.keys().collect();
        vnames.sort();
        for vn in vnames {
            let v = &model.variables[vn];
            let qualified = format!("{mname}.{vn}");
            let ambiguous = bare_counts.get(vn.as_str()).copied().unwrap_or(0) > 1;

            let mut keys: Vec<String> = vec![qualified];
            if !ambiguous {
                keys.push(vn.clone());
            }

            let mut attrs = JsonMap::new();
            if let Some(u) = &v.units {
                attrs.insert("units".to_string(), JsonValue::from(u.clone()));
            }
            if let Some(d) = &v.description {
                attrs.insert("description".to_string(), JsonValue::from(d.clone()));
            }

            for key in keys {
                if let Some(shape) = &v.shape {
                    meta.var_dims.insert(key.clone(), shape.clone());
                }
                if !attrs.is_empty() {
                    meta.var_attrs.insert(key.clone(), attrs.clone());
                }
                if observed.contains(vn.as_str()) {
                    meta.observed_keys.insert(key.clone());
                }
                meta.var_types.insert(key, v.var_type);
            }
        }
    }

    meta
}

/// Rename one variable's axes from the positional `"<base>_d0"` placeholders to
/// its REAL declared dim names (RFC §7 → §8) — the Rust mirror of Julia's
/// `_name_gridding`. A variable the document does not describe keeps its
/// positional names.
///
/// # Errors
/// [`OutputError::DimCountMismatch`] / [`OutputError::DimLengthMismatch`] when
/// the document and the built state disagree about a variable's shape. A
/// mismatch must fail loudly rather than mislabel an axis.
pub fn apply_output_meta(g: VarGridding, meta: &OutputMeta) -> Result<VarGridding, OutputError> {
    let Some(dims) = meta.dims_of(&g.base) else {
        return Ok(g); // scalar / undeclared → positional
    };
    if dims.len() != g.shape.len() {
        let actual = g.shape.len();
        return Err(OutputError::DimCountMismatch {
            base: g.base,
            dims: dims.clone(),
            declared: dims.len(),
            shape: g.shape,
            actual,
        });
    }
    for (d, dim) in dims.iter().enumerate() {
        if let Some(&size) = meta.index_sets.get(dim)
            && size != 0
            && size != g.shape[d]
        {
            return Err(OutputError::DimLengthMismatch {
                base: g.base,
                axis: d,
                dim: dim.clone(),
                size,
                len: g.shape[d],
            });
        }
    }
    Ok(VarGridding {
        dim_names: dims.clone(),
        ..g
    })
}

/// [`derive_output_gridding`] followed by [`apply_output_meta`] on every
/// variable — the doc-aware form, mirroring Julia's two-argument
/// `derive_output_gridding(var_map, meta)`.
///
/// # Errors
/// See [`derive_output_gridding`] and [`apply_output_meta`].
pub fn derive_output_gridding_with_meta(
    slot_names: &[String],
    meta: &OutputMeta,
) -> Result<Vec<VarGridding>, OutputError> {
    derive_output_gridding(slot_names)?
        .into_iter()
        .map(|g| apply_output_meta(g, meta))
        .collect()
}

// --------------------------------------------------------------------------
// §9 — grids are emergent
// --------------------------------------------------------------------------

/// Partition output variables into GRIDS by their spatial-dim signature
/// (RFC §9): variables over the same set of axes form one grid, so an
/// atmosphere over `[lev, lat, lon]` and an ocean over `[depth, lat, lon]`
/// split by construction. The signature is the SORTED SET of a variable's
/// `dim_names`, so axis order does not fragment a grid, and every scalar
/// (empty signature) lands in one shared 0-D grid. Groups come back in
/// first-seen signature order.
#[must_use]
pub fn group_gridding_by_grid(gridding: Vec<VarGridding>) -> Vec<Vec<VarGridding>> {
    let mut order: Vec<Vec<String>> = Vec::new();
    let mut groups: BTreeMap<Vec<String>, Vec<VarGridding>> = BTreeMap::new();
    for g in gridding {
        let sig: Vec<String> = g
            .dim_names
            .iter()
            .cloned()
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect();
        if !groups.contains_key(&sig) {
            order.push(sig.clone());
        }
        groups.entry(sig).or_default().push(g);
    }
    order
        .into_iter()
        .filter_map(|sig| groups.remove(&sig))
        .collect()
}

// --------------------------------------------------------------------------
// §8 — CF dimension coordinates
// --------------------------------------------------------------------------

/// A CF **dimension coordinate** (§8.3): a 1-D coordinate variable named
/// exactly like its dimension, its values, and its CF attributes. Field-for-
/// field the shape of `earthsciio::format::WriteCoord`.
#[derive(Debug, Clone, PartialEq)]
pub struct CoordPlan {
    /// Coordinate (and dimension) name.
    pub name: String,
    /// The coordinate values, one per grid index along its dimension.
    pub values: Vec<f64>,
    /// CF attributes: `standard_name` / `units` / `axis`, when declared.
    pub attrs: JsonMap<String, JsonValue>,
}

/// Resolve the `coordinates` registry (§8.3) into the CF **dimension
/// coordinates** for a set of [`VarGridding`]s — the Rust mirror of Julia's
/// `plan_dimension_coordinates`.
///
/// For each distinct spatial dim, in first-seen order, a registry entry KEYED
/// BY THAT DIM NAME carrying inline `values` produces a [`CoordPlan`] with the
/// entry's `standard_name` / `units` / `axis`. Entries whose key is not a dim
/// name (CF *auxiliary* coordinates) and `source`-backed entries are skipped:
/// they resolve against build artifacts, not the document, and are the
/// documented next drop-in on the same registry. A dim with no entry emits no
/// coordinate — a bare integer axis.
///
/// # Errors
/// [`OutputError::CoordLengthMismatch`] when an entry's `values` length does
/// not match the axis it names.
pub fn plan_dimension_coordinates(
    gridding: &[VarGridding],
    meta: &OutputMeta,
) -> Result<Vec<CoordPlan>, OutputError> {
    let mut order: Vec<&str> = Vec::new();
    let mut dimlen: BTreeMap<&str, usize> = BTreeMap::new();
    for g in gridding {
        for (d, name) in g.dim_names.iter().enumerate() {
            if !dimlen.contains_key(name.as_str()) {
                order.push(name.as_str());
            }
            dimlen.insert(name.as_str(), g.shape[d]);
        }
    }

    let mut out = Vec::new();
    for name in order {
        let Some(entry) = meta.coordinates.get(name) else {
            continue;
        };
        // v1 handles the inline-`values` dimension-coordinate path only.
        let Some(values) = &entry.values else {
            continue;
        };
        let want = dimlen[name];
        if values.len() != want {
            return Err(OutputError::CoordLengthMismatch {
                name: name.to_string(),
                got: values.len(),
                want,
            });
        }
        let mut attrs = JsonMap::new();
        if let Some(v) = &entry.standard_name {
            attrs.insert("standard_name".to_string(), JsonValue::from(v.clone()));
        }
        if let Some(v) = &entry.units {
            attrs.insert("units".to_string(), JsonValue::from(v.clone()));
        }
        if let Some(v) = &entry.axis {
            attrs.insert("axis".to_string(), JsonValue::from(v.clone()));
        }
        out.push(CoordPlan {
            name: name.to_string(),
            values: values.clone(),
            attrs,
        });
    }
    Ok(out)
}

// --------------------------------------------------------------------------
// The plan
// --------------------------------------------------------------------------

/// One output variable: what a writer declares, plus the inversion that fills
/// it. Field-for-field the shape of `earthsciio::format::WriteVar` once
/// [`Self::gridding`] has scattered the trajectory into `data`.
#[derive(Debug, Clone, PartialEq)]
pub struct VarPlan {
    /// On-disk variable name (the flat base name).
    pub name: String,
    /// Ordered on-disk dimension names: the record axis first, then the
    /// variable's spatial axes. A scalar's dims are exactly `[time_dim]`.
    pub dims: Vec<String>,
    /// CF attributes retained from the document (`units`, `description`).
    pub attrs: JsonMap<String, JsonValue>,
    /// Element type; [`DTYPE_FLOAT64`] throughout (the flat state is `f64`).
    pub dtype: &'static str,
    /// The flat→gridded inversion for this variable.
    pub gridding: VarGridding,
}

impl VarPlan {
    /// Number of values one output record contributes (1 for a scalar).
    #[must_use]
    pub fn values_per_record(&self) -> usize {
        self.gridding.n_cells()
    }
}

/// One grid: a set of variables sharing a spatial-dim signature, with the
/// coordinates and dimension lengths that describe it (RFC §9). The RFC's
/// recommended decomposition is one Sink — one store or group — per grid.
///
/// Converting to `earthsciio::format::OutputSchema` is mechanical:
/// `OutputSchema::dims` is `[(time_dim, n_records)]` followed by
/// [`Self::dims`]; `coords` is [`Self::coords`] plus a `WriteCoord` for the
/// time axis built from the output times; `vars` is one `WriteVar` per
/// [`VarPlan`] whose `data` is [`VarPlan::gridding`] scattered across every
/// record. The record count is deliberately NOT part of the plan: a plan is
/// derived once and stays valid however many records get written.
#[derive(Debug, Clone, PartialEq)]
pub struct GridPlan {
    /// Ordered SPATIAL dims of this grid, `name → length`. Empty for the
    /// scalar grid. The record axis is not included; see [`Self::time_dim`].
    pub dims: Vec<(String, usize)>,
    /// The growable record-axis name (`domain.independent_variable`).
    pub time_dim: String,
    /// CF dimension coordinates for this grid's axes (possibly empty).
    pub coords: Vec<CoordPlan>,
    /// The grid's output variables, ordered by name.
    pub vars: Vec<VarPlan>,
}

impl GridPlan {
    /// Length of `dim` on this grid.
    #[must_use]
    pub fn dim_len(&self, dim: &str) -> Option<usize> {
        self.dims
            .iter()
            .find(|(n, _)| n == dim)
            .map(|&(_, len)| len)
    }
}

/// The full derived output plan: every grid the run produces.
#[derive(Debug, Clone, PartialEq)]
pub struct OutputPlan {
    /// One entry per emergent grid, in first-seen signature order.
    pub grids: Vec<GridPlan>,
}

impl OutputPlan {
    /// Total number of output variables across every grid.
    #[must_use]
    pub fn n_vars(&self) -> usize {
        self.grids.iter().map(|g| g.vars.len()).sum()
    }

    /// Find a variable by name across the grids.
    #[must_use]
    pub fn var(&self, name: &str) -> Option<&VarPlan> {
        self.grids
            .iter()
            .find_map(|g| g.vars.iter().find(|v| v.name == name))
    }
}

/// Derive the whole output plan for a run.
///
/// * `doc` — the (flattened) run document: axis names, axis lengths, CF
///   attributes, and the `coordinates` registry.
/// * `slot_names` — the flat state-element names, index = flat index. This is
///   `Solution::state_variable_names` / `ArrayCompiled::state_variable_names`,
///   including any observed rows the runner appended.
/// * `observed` — the caller-named observed/derived fields to write alongside
///   the state (RFC decision 8). Output is state PLUS these, not every observed
///   field. Names may be bare or `Model.`-qualified.
///
/// # Errors
/// [`OutputError::UnknownObserved`] when a requested observed field has no slot
/// in `slot_names`; otherwise see [`derive_output_gridding`],
/// [`apply_output_meta`] and [`plan_dimension_coordinates`].
pub fn derive_output_plan(
    doc: &EsmFile,
    slot_names: &[String],
    observed: &[String],
) -> Result<OutputPlan, OutputError> {
    let meta = derive_output_meta(doc);
    let gridding = derive_output_gridding_with_meta(slot_names, &meta)?;

    // RFC decision 8: state is always written; an observed field only when the
    // caller named it. A requested name that produced no slots is an error —
    // silently dropping a requested output is the failure mode this refuses.
    let mut wanted: HashMap<&str, bool> = observed.iter().map(|n| (n.as_str(), false)).collect();
    let mut kept: Vec<VarGridding> = Vec::new();
    for g in gridding {
        let requested = match_requested(&mut wanted, &g.base);
        let is_observed = meta.is_observed(&g.base);
        if !is_observed || requested {
            kept.push(g);
        }
    }
    if let Some((name, _)) = wanted.iter().find(|(_, seen)| !**seen) {
        return Err(OutputError::UnknownObserved {
            name: (*name).to_string(),
        });
    }

    let mut grids = Vec::new();
    for group in group_gridding_by_grid(kept) {
        grids.push(build_grid_plan(group, &meta)?);
    }
    Ok(OutputPlan { grids })
}

/// Mark every request key that names `base` (bare or `Model.`-qualified) and
/// report whether any did.
fn match_requested(wanted: &mut HashMap<&str, bool>, base: &str) -> bool {
    let bare = base.rsplit('.').next().unwrap_or(base);
    let mut hit = false;
    for (name, seen) in wanted.iter_mut() {
        let name_bare = name.rsplit('.').next().unwrap_or(name);
        if *name == base || *name == bare || name_bare == base || name_bare == bare {
            *seen = true;
            hit = true;
        }
    }
    hit
}

fn build_grid_plan(group: Vec<VarGridding>, meta: &OutputMeta) -> Result<GridPlan, OutputError> {
    // Dimensions first: a length conflict between two variables on one grid is
    // the more fundamental error, so it must win over a coordinate that merely
    // disagrees with one of the two.
    let mut dims: Vec<(String, usize)> = Vec::new();
    let mut owner: BTreeMap<String, String> = BTreeMap::new();
    for g in &group {
        for (d, name) in g.dim_names.iter().enumerate() {
            if name == &meta.time_dim {
                return Err(OutputError::TimeDimCollision {
                    base: g.base.clone(),
                    dim: name.clone(),
                });
            }
            match dims.iter().find(|(n, _)| n == name) {
                Some(&(_, len)) if len != g.shape[d] => {
                    return Err(OutputError::DimLengthConflict {
                        dim: name.clone(),
                        first: owner[name].clone(),
                        a: len,
                        second: g.base.clone(),
                        b: g.shape[d],
                    });
                }
                Some(_) => {}
                None => {
                    dims.push((name.clone(), g.shape[d]));
                    owner.insert(name.clone(), g.base.clone());
                }
            }
        }
    }

    let coords = plan_dimension_coordinates(&group, meta)?;

    let vars = group
        .into_iter()
        .map(|g| {
            let mut var_dims = Vec::with_capacity(g.dim_names.len() + 1);
            var_dims.push(meta.time_dim.clone());
            var_dims.extend(g.dim_names.iter().cloned());
            VarPlan {
                name: g.base.clone(),
                dims: var_dims,
                attrs: meta.attrs_of(&g.base).cloned().unwrap_or_default(),
                dtype: DTYPE_FLOAT64,
                gridding: g,
            }
        })
        .collect();

    Ok(GridPlan {
        dims,
        time_dim: meta.time_dim.clone(),
        coords,
        vars,
    })
}

// --------------------------------------------------------------------------
// Tests
// --------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn names(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| (*s).to_string()).collect()
    }

    /// Column-major slot names for `shape`, exactly as
    /// `simulate_array::compile::build_slot_tables` emits them (dim 0 fastest).
    fn col_major_slots(base: &str, shape: &[usize]) -> Vec<String> {
        let total: usize = shape.iter().product();
        (0..total)
            .map(|flat| {
                let mut rem = flat;
                let mut idx = Vec::with_capacity(shape.len());
                for &n in shape {
                    idx.push((rem % n) + 1);
                    rem /= n;
                }
                let joined: Vec<String> = idx.iter().map(usize::to_string).collect();
                format!("{base}[{}]", joined.join(","))
            })
            .collect()
    }

    #[test]
    fn parse_cell_key_round_trips_and_rejects() {
        assert_eq!(parse_cell_key("u[3]"), Some(("u", vec![3])));
        assert_eq!(parse_cell_key("u[2,3]"), Some(("u", vec![2, 3])));
        assert_eq!(parse_cell_key("M.u[1,2,3]"), Some(("M.u", vec![1, 2, 3])));
        // Not cell keys.
        assert_eq!(parse_cell_key("u"), None);
        assert_eq!(parse_cell_key("u[]"), None);
        assert_eq!(parse_cell_key("[1]"), None);
        assert_eq!(parse_cell_key("u[a]"), None);
        assert_eq!(parse_cell_key("u[1,]"), None);
        assert_eq!(parse_cell_key("u[1"), None);
        // The Julia regex forbids `[` in the base name, so the FIRST bracket
        // opens the index list and a doubled suffix is not a cell key.
        assert_eq!(parse_cell_key("u[1][2]"), None);
    }

    /// The load-bearing test: a NON-SQUARE 2-D grid, where a row/column-major
    /// mix-up is actually visible (a square grid passes a transposed
    /// implementation). `c` lives on a 3x2 grid; the flat state is column-major
    /// (dim 0 fastest) and the output must be row-major (dim 1 fastest).
    #[test]
    fn inversion_transposes_a_non_square_2d_grid() {
        let slots = col_major_slots("c", &[3, 2]);
        assert_eq!(
            slots,
            names(&["c[1,1]", "c[2,1]", "c[3,1]", "c[1,2]", "c[2,2]", "c[3,2]"])
        );

        let g = &derive_output_gridding(&slots).unwrap()[0];
        assert_eq!(g.shape, vec![3, 2]);
        assert_eq!(g.dim_names, names(&["c_d0", "c_d1"]));
        // Row-major offset o holds the COLUMN-major flat index of that cell.
        // A transposed implementation would produce [0, 1, 2, 3, 4, 5].
        assert_eq!(g.flat_indices, vec![0, 3, 1, 4, 2, 5]);

        // Encode the cell in the value: u at (i, j) = 10 * i + j (1-based).
        let mut u = vec![0.0; 6];
        for (flat, name) in slots.iter().enumerate() {
            let (_, idx) = parse_cell_key(name).unwrap();
            u[flat] = (10 * idx[0] + idx[1]) as f64;
        }
        let mut out = vec![0.0; 6];
        g.scatter(&u, &mut out).unwrap();
        assert_eq!(out, vec![11.0, 12.0, 21.0, 22.0, 31.0, 32.0]);

        // ... and the C-order indexing arithmetic agrees cell by cell.
        for i in 0..3 {
            for j in 0..2 {
                assert_eq!(out[i * 2 + j], (10 * (i + 1) + (j + 1)) as f64);
            }
        }
    }

    /// Rank 3 with three DIFFERENT axis lengths: every axis permutation and
    /// every stride mistake changes the answer.
    #[test]
    fn inversion_handles_a_rank_3_grid_with_distinct_axis_lengths() {
        let shape = [2usize, 3, 4];
        let slots = col_major_slots("f", &shape);
        assert_eq!(slots.len(), 24);
        assert_eq!(slots[0], "f[1,1,1]");
        assert_eq!(slots[1], "f[2,1,1]"); // dim 0 fastest in the flat state
        assert_eq!(slots[2], "f[1,2,1]");
        assert_eq!(slots[23], "f[2,3,4]");

        let g = &derive_output_gridding(&slots).unwrap()[0];
        assert_eq!(g.shape, vec![2, 3, 4]);
        assert_eq!(g.dim_names, names(&["f_d0", "f_d1", "f_d2"]));

        let u: Vec<f64> = (0..24).map(|i| i as f64).collect();
        let mut out = vec![0.0; 24];
        g.scatter(&u, &mut out).unwrap();

        // out is C-order over [2,3,4]; u is column-major over the same shape.
        for i in 0..2 {
            for j in 0..3 {
                for k in 0..4 {
                    let row = (i * 3 + j) * 4 + k;
                    let col = i + 2 * (j + 3 * k);
                    assert_eq!(out[row], col as f64, "cell ({i},{j},{k})");
                    assert_eq!(g.cart(row), vec![i, j, k]);
                }
            }
        }

        // gather is the exact inverse (the restart-read direction).
        let mut back = vec![0.0; 24];
        g.gather(&out, &mut back).unwrap();
        assert_eq!(back, u);
    }

    #[test]
    fn scalars_are_zero_dimensional_and_share_one_grid() {
        let slots = names(&["a", "b"]);
        let gs = derive_output_gridding(&slots).unwrap();
        assert_eq!(gs.len(), 2);
        for g in &gs {
            assert!(g.is_scalar());
            assert!(g.shape.is_empty());
            assert!(g.dim_names.is_empty());
            assert_eq!(g.n_cells(), 1);
        }
        assert_eq!(gs[0].flat_indices, vec![0]);
        assert_eq!(gs[1].flat_indices, vec![1]);

        let groups = group_gridding_by_grid(gs);
        assert_eq!(groups.len(), 1, "every scalar shares the 0-D grid");
        assert_eq!(groups[0].len(), 2);
    }

    #[test]
    fn variables_are_sorted_and_grouped_by_spatial_signature() {
        let mut slots = Vec::new();
        slots.extend(col_major_slots("ocn.t", &[2, 2])); // [ocn.t_d0, ocn.t_d1]
        slots.extend(col_major_slots("atm.q", &[3, 2]));
        slots.push("scalar".to_string());

        let gs = derive_output_gridding(&slots).unwrap();
        let bases: Vec<&str> = gs.iter().map(|g| g.base.as_str()).collect();
        assert_eq!(bases, vec!["atm.q", "ocn.t", "scalar"]); // sorted by base

        // Positional dim names are per-variable, so the two fields are two
        // grids and the scalar is a third.
        let groups = group_gridding_by_grid(gs);
        assert_eq!(groups.len(), 3);
        assert_eq!(groups[0][0].base, "atm.q");
        assert_eq!(groups[1][0].base, "ocn.t");
        assert_eq!(groups[2][0].base, "scalar");
    }

    #[test]
    fn shared_axis_names_collapse_two_variables_into_one_grid() {
        // Same axes, different order: the signature is the sorted SET, so axis
        // order must not fragment the grid (RFC §9).
        let a = VarGridding {
            base: "a".into(),
            shape: vec![2, 3],
            dim_names: names(&["lat", "lon"]),
            flat_indices: (0..6).collect(),
        };
        let b = VarGridding {
            base: "b".into(),
            shape: vec![3, 2],
            dim_names: names(&["lon", "lat"]),
            flat_indices: (6..12).collect(),
        };
        let groups = group_gridding_by_grid(vec![a, b]);
        assert_eq!(groups.len(), 1);
        assert_eq!(groups[0].len(), 2);
    }

    #[test]
    fn malformed_griddings_are_refused() {
        // A scalar key appearing twice.
        let err = derive_output_gridding_from_map([("a", 0usize), ("a", 1usize)]).unwrap_err();
        assert!(matches!(err, OutputError::DuplicateScalar { .. }), "{err}");

        // Cells of differing rank.
        let err = derive_output_gridding(&names(&["u[1]", "u[1,2]"])).unwrap_err();
        assert!(matches!(err, OutputError::RaggedRank { .. }), "{err}");

        // A hole in the grid (5 cells declared over a 3x2 extent).
        let err =
            derive_output_gridding(&names(&["u[1,1]", "u[2,1]", "u[3,1]", "u[1,2]", "u[2,2]"]))
                .unwrap_err();
        assert!(matches!(err, OutputError::SparseGrid { .. }), "{err}");

        // A 0 index (cell keys are 1-based).
        let err = derive_output_gridding(&names(&["u[0]"])).unwrap_err();
        assert!(matches!(err, OutputError::ZeroIndex { .. }), "{err}");
    }

    #[test]
    fn scatter_refuses_a_wrong_sized_buffer() {
        let slots = col_major_slots("c", &[3, 2]);
        let g = &derive_output_gridding(&slots).unwrap()[0];
        let u = vec![1.0; 6];
        let mut too_small = vec![0.0; 5];
        assert!(matches!(
            g.scatter(&u, &mut too_small).unwrap_err(),
            OutputError::BufferLength { .. }
        ));
        let mut trajectory = vec![0.0; 12];
        g.scatter_record(&u, &mut trajectory, 1).unwrap();
        assert!(matches!(
            g.scatter_record(&u, &mut trajectory, 2).unwrap_err(),
            OutputError::BufferLength { .. }
        ));
    }
}
