//! Adapter: serve an ESS data loader through a real EarthSciIO [`Provider`].
//!
//! [`CadenceProvider`]'s own documentation specifies this seam — *"ESS does not
//! link the EarthSciIO crate; a thin adapter at the integration boundary
//! implements this trait by delegating to the real `Provider` (and converting an
//! f64 anchor to the [`OffsetDateTime`] the upstream `refresh` wants)"*. This
//! module is that adapter, behind the optional `esio` feature so the default
//! build still does not link EarthSciIO.
//!
//! It mirrors the Python binding's `earthsci_ast.data_sources.esio_provider`:
//! opt-in, caller-selected, never the default. Wiring it unconditionally would
//! couple ESS to EarthSciIO and to whichever formats that crate happens to
//! register.
//!
//! ```ignore
//! # use earthsci_ast::esio_provider::EsioProvider;
//! let provider = EsioProvider::builder(loader, cache)
//!     .var("SOA", "SR_SOA")                       // on-disk name -> model variable
//!     .select(Selection::Orthogonal(vec![
//!         AxisSelect::Indices(vec![0]),           // emisLayer 0
//!         AxisSelect::Indices(ppl_0based),        // the invented support set
//!         AxisSelect::All,                        // every receptor
//!     ]))
//!     .build()?;
//! ```
//!
//! ## Projection pushdown
//!
//! The optional [`select`](EsioProviderBuilder::select) is what makes a gated
//! const loader tractable: the ISRM SR matrix is 52,411 x 52,411 per pathway, and
//! only the 1,520 emission-bearing rows are ever read. The selection is handed to
//! the store-backed reader, so only the intersecting chunks are fetched — it is
//! not a post-hoc slice of a whole-array read. [`supports_selection`] reports
//! whether the bound reader can honour one.
//!
//! [`Provider`]: earthsciio::Provider
//! [`supports_selection`]: EsioProvider::supports_selection

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use earthsciio::format::{ArrayData, AxisSelect, NativeField as EsioField, Selection};
use earthsciio::{Cache, DataSource, Provider, Window};
use indexmap::IndexMap;
use ndarray::{ArrayD, Axis, IxDyn};
use time::OffsetDateTime;

use crate::provider::{CadenceProvider, NativeField, ProviderError};
use crate::pushdown_rewrite::GateAxis;
use crate::types::UnitConversion;
use crate::unit_conversion::{apply_unit_conversion, parse_unit_conversion};

fn err(msg: impl Into<String>) -> ProviderError {
    crate::error::MessageError(msg.into())
}

// --------------------------------------------------------------------------- //
// The DECLARED loader semantics (esm-spec §8.9) this adapter honours: a
// per-axis `select`, a string→code map on a variable, a record filter, and the
// loader's own extent. Everything here is read off the document — none of it
// is a caller-side transform any more.
// --------------------------------------------------------------------------- //

/// What a `codes` map does with a value it does not contain.
#[derive(Debug, Clone, PartialEq)]
enum Unmapped {
    /// Drop the whole RECORD (every variable of the loader loses that row).
    Drop,
    /// Fail the load, naming the offending value.
    Error,
    /// Substitute this number.
    Value(f64),
}

/// A loader variable's declared string→number code map (`codes`).
#[derive(Debug, Clone)]
struct CodeMap {
    map: HashMap<String, f64>,
    case_insensitive: bool,
    unmapped: Unmapped,
}

impl CodeMap {
    /// The code for one raw cell, or `None` when it is unmapped and the policy
    /// is to drop the record.
    fn lookup(&self, raw: &str, var: &str) -> Result<Option<f64>, ProviderError> {
        let key = raw.trim();
        let key = if self.case_insensitive {
            key.to_uppercase()
        } else {
            key.to_string()
        };
        if let Some(v) = self.map.get(&key) {
            return Ok(Some(*v));
        }
        match &self.unmapped {
            Unmapped::Drop => Ok(None),
            Unmapped::Value(v) => Ok(Some(*v)),
            Unmapped::Error => Err(err(format!(
                "loader variable '{var}': value {raw:?} is not in its declared `codes` map \
                 (set codes.unmapped to \"drop\" or a number to accept it)"
            ))),
        }
    }
}

/// One column of a record-table loader: where it comes from and how its cells
/// become numbers.
#[derive(Debug, Clone)]
struct ColumnSpec {
    /// The CONSUMING PARAMETER's flattened name (`"Ingest.lon"`) — its identity
    /// from 1.0.0, since two parameters may read one `file_variable` with
    /// different units and must not collide in the decoded table.
    name: String,
    /// The on-disk column.
    file_variable: String,
    codes: Option<CodeMap>,
    /// The declared `unit_conversion` (esm-spec §8.5), parsed; `None` when the
    /// variable declares none.
    unit_conversion: Option<UnitConversion>,
}

/// Convert one EarthSciIO native field to the ESS-side [`NativeField`].
///
/// Numeric dtypes widen to `f64` (the only element type the RHS evaluates);
/// a string field is a hard error rather than a silent drop, because a loader
/// wired to feed a model variable from a text column is a modelling mistake that
/// should surface at the boundary, not as an absent forcing later.
///
/// `record_dim` is the time dimension of a two-record (`records_per_sample: 2`)
/// sample: esm-spec §8.5.1 stacks the two records along the parameter's FIRST
/// dimension, while the reader keeps the time dimension where the file has
/// it, so it is moved to axis 0 here, before any declared select or gathered
/// selection addresses the axes.
fn to_ess_field(
    name: &str,
    f: EsioField,
    coords: &HashMap<String, earthsciio::format::Coord>,
    record_dim: Option<&str>,
) -> Result<NativeField, ProviderError> {
    let record_pos = match record_dim {
        None => None,
        Some(td) => {
            let pos = f.dims.iter().position(|d| d == td).ok_or_else(|| {
                err(format!(
                    "loader variable '{name}': two records per sample are taken along its \
                     time dimension '{td}', but the delivered field has dims {:?}",
                    f.dims
                ))
            })?;
            if f.shape.get(pos) != Some(&2) {
                return Err(err(format!(
                    "loader variable '{name}': two records per sample should give length 2 \
                     along '{td}', but the delivered field has shape {:?} over dims {:?}",
                    f.shape, f.dims
                )));
            }
            Some(pos)
        }
    };
    // Takes the field by value so an already-f64 slab MOVES into the model
    // array — a gated SR slab is ~0.6 GB, and a clone here doubles the
    // transient footprint of every fetch.
    let n_values = f.data.len();
    let values: Vec<f64> = match f.data {
        ArrayData::F64(v) => v,
        ArrayData::I64(v) => v.iter().map(|&x| x as f64).collect(),
        ArrayData::I32(v) => v.iter().map(|&x| x as f64).collect(),
        ArrayData::Bool(v) => v.iter().map(|&x| if x { 1.0 } else { 0.0 }).collect(),
        ArrayData::Str(_) => {
            return Err(err(format!(
                "loader variable '{name}' decoded as strings; a model forcing must be \
                 numeric (widen or map it in the reader, not here)"
            )));
        }
    };
    let array = ArrayD::from_shape_vec(IxDyn(&f.shape), values).map_err(|e| {
        err(format!(
            "loader variable '{name}': shape {:?} does not match {n_values} values ({e})",
            f.shape,
        ))
    })?;
    let (array, dims) = match record_pos {
        Some(pos) if pos > 0 => {
            let mut order: Vec<usize> = (0..array.ndim()).collect();
            order.remove(pos);
            order.insert(0, pos);
            let dims: Vec<String> = order.iter().map(|&i| f.dims[i].clone()).collect();
            let moved = array.permuted_axes(IxDyn(&order));
            (moved.as_standard_layout().into_owned(), dims)
        }
        _ => (array, f.dims),
    };

    // Carry only the coordinate axes this field actually spans, in dims order, so
    // an in-model regrid coupling sees the axes it indexes and nothing else.
    let mut out_coords: IndexMap<String, Vec<f64>> = IndexMap::new();
    for dim in &dims {
        let Some(coord) = coords.get(dim) else {
            continue;
        };
        let vals: Vec<f64> = match &coord.field.data {
            ArrayData::F64(v) => v.clone(),
            ArrayData::I64(v) => v.iter().map(|&x| x as f64).collect(),
            ArrayData::I32(v) => v.iter().map(|&x| x as f64).collect(),
            _ => continue, // a non-numeric axis carries no usable coordinate
        };
        out_coords.insert(dim.clone(), vals);
    }
    Ok(NativeField {
        array,
        coords: out_coords,
    })
}

/// A record-table loader's decode, SHARED by its per-variable providers.
///
/// A `points` loader that declares a `record_filter` or a `codes` map is a
/// TABLE, not a bag of independent arrays: which rows survive is a property of
/// the whole record, so every column must be filtered by the same mask or the
/// columns silently misalign. That forces one decode — this type — rather than
/// one decode per variable, which also means the 69 MB FF10 zip is unzipped and
/// parsed once for all eight of its variables instead of eight times.
///
/// The decode is keyed by the source's RECORD ANCHOR: the cadence anchor at or
/// before the requested instant for a time-varying source, and one key for a
/// const source. Only the most recent decode is held, so memory stays bounded
/// by one record however long the run; the providers are sampled one after
/// another at the same instant, and the second one must not re-read. Every
/// column served for an instant comes from that instant's decode, so the
/// columns stay aligned across a refresh too.
struct RecordTable {
    loader_name: String,
    /// The table source's own provider, sampled statelessly
    /// ([`Provider::sample_at`]) at each new anchor.
    provider: Provider,
    /// The source's cadence, `None` for a const source.
    temporal: Option<earthsciio::SourceTemporal>,
    columns: Vec<ColumnSpec>,
    /// Loader variables whose non-finite cells drop the record.
    require_finite: Vec<String>,
    /// The most recent decode: its record anchor (`None` for a const source)
    /// and its name → filtered column map.
    state: Mutex<Option<(Option<OffsetDateTime>, RecordColumns)>>,
}

impl RecordTable {
    /// The record anchor an instant reads: the cadence anchor at or before it,
    /// or `None` for a const source (one record for the whole run).
    fn anchor(&self, at: OffsetDateTime) -> Option<OffsetDateTime> {
        self.temporal.as_ref().map(|t| t.record_anchor(at))
    }

    /// The filtered column for loader variable `name` at instant `at`, and the
    /// record anchor it was decoded at.
    fn column_at(
        &self,
        name: &str,
        at: OffsetDateTime,
    ) -> Result<(Option<OffsetDateTime>, ArrayD<f64>), ProviderError> {
        let anchor = self.anchor(at);
        let cols = self.materialize(anchor, at)?;
        let v = cols.get(name).ok_or_else(|| {
            err(format!(
                "loader '{}' has no column '{name}' (declared: {:?})",
                self.loader_name,
                cols.keys().collect::<Vec<_>>()
            ))
        })?;
        let arr = ArrayD::from_shape_vec(IxDyn(&[v.len()]), v.clone())
            .expect("a 1-D shape always matches its own length");
        Ok((anchor, arr))
    }

    /// Decode + filter once per anchor; later calls at the same anchor reuse
    /// the columns, and a new anchor replaces them.
    fn materialize(
        &self,
        anchor: Option<OffsetDateTime>,
        at: OffsetDateTime,
    ) -> Result<RecordColumns, ProviderError> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| err("record table lock poisoned by an earlier decode failure"))?;
        if let Some((held, cols)) = state.as_ref()
            && *held == anchor
        {
            return Ok(cols.clone());
        }
        // Drop the old decode BEFORE the new one, so two records are never
        // held at once.
        *state = None;
        let cols = Arc::new(self.decode(at)?);
        *state = Some((anchor, cols.clone()));
        Ok(cols)
    }

    fn decode(&self, at: OffsetDateTime) -> Result<HashMap<String, Vec<f64>>, ProviderError> {
        // The stateless sampler: the record in effect at `at` for a
        // time-varying source (its time axis dropped), the whole file for a
        // const one.
        let fields = self
            .provider
            .sample_at(at)
            .map_err(|e| err(format!("loader '{}' decode failed: {e}", self.loader_name)))?
            .variables;

        // Raw columns (unfiltered), plus the per-record keep mask the `codes`
        // drops and the finite requirement build up.
        let mut raw: HashMap<String, Vec<f64>> = HashMap::with_capacity(self.columns.len());
        let mut keep: Option<Vec<bool>> = None;
        let mut nrec: Option<usize> = None;
        for spec in &self.columns {
            let f = fields.get(&spec.file_variable).ok_or_else(|| {
                err(format!(
                    "loader '{}': the reader returned no column '{}' for variable '{}'",
                    self.loader_name, spec.file_variable, spec.name
                ))
            })?;
            if f.shape.len() != 1 {
                return Err(err(format!(
                    "loader '{}' declares a record filter, but variable '{}' is rank {} \
                     ({:?}); a record filter needs a single record axis",
                    self.loader_name,
                    spec.name,
                    f.shape.len(),
                    f.shape
                )));
            }
            let n = f.shape[0];
            match nrec {
                None => {
                    nrec = Some(n);
                    keep = Some(vec![true; n]);
                }
                Some(m) if m != n => {
                    return Err(err(format!(
                        "loader '{}': column '{}' has {n} records but an earlier column has \
                         {m}; the reader did not return one aligned table",
                        self.loader_name, spec.name
                    )));
                }
                _ => {}
            }
            let mask = keep.as_mut().expect("mask sized with the first column");
            let values = match (&spec.codes, &f.data) {
                (Some(cm), ArrayData::Str(cells)) => {
                    let mut out = Vec::with_capacity(cells.len());
                    for (i, cell) in cells.iter().enumerate() {
                        match cm.lookup(cell, &spec.name)? {
                            Some(v) => out.push(v),
                            None => {
                                mask[i] = false;
                                out.push(f64::NAN);
                            }
                        }
                    }
                    out
                }
                (Some(_), other) => {
                    return Err(err(format!(
                        "loader '{}' variable '{}' declares `codes`, but the column decoded \
                         as {:?}; a code map maps a TEXT column to numbers",
                        self.loader_name,
                        spec.name,
                        other.dtype()
                    )));
                }
                (None, data) => widen(&spec.name, data)?,
            };
            raw.insert(spec.name.clone(), values);
        }

        let n = nrec.unwrap_or(0);
        let mut mask = keep.unwrap_or_default();
        // `require_finite` names FILE variables (esm-spec §8.9): from 1.0.0 a
        // source declares no variables of its own, so the filter is stated in
        // the reader's vocabulary. Resolve it there — through a bound
        // parameter's already-decoded column when one reads it, and straight
        // from the reader otherwise, since a source may filter on a column no
        // parameter reads.
        let mut by_file: HashMap<&str, &Vec<f64>> = HashMap::new();
        for spec in &self.columns {
            by_file
                .entry(spec.file_variable.as_str())
                .or_insert_with(|| &raw[&spec.name]);
        }
        for name in &self.require_finite {
            let widened;
            let col: &[f64] = match by_file.get(name.as_str()) {
                Some(c) => c.as_slice(),
                None => {
                    let f = fields.get(name).ok_or_else(|| {
                        err(format!(
                            "loader '{}': record_filter.require_finite names file variable \
                             '{name}', which the source does not deliver",
                            self.loader_name
                        ))
                    })?;
                    widened = widen(name, &f.data)?;
                    widened.as_slice()
                }
            };
            if col.len() != n {
                return Err(err(format!(
                    "loader '{}': record_filter.require_finite column '{name}' has {} records \
                     but the table has {n}",
                    self.loader_name,
                    col.len()
                )));
            }
            for i in 0..n {
                if !col[i].is_finite() {
                    mask[i] = false;
                }
            }
        }
        drop(by_file);

        let kept = mask.iter().filter(|k| **k).count();
        let out = raw
            .into_iter()
            .map(|(name, col)| {
                let filtered: Vec<f64> = col
                    .into_iter()
                    .zip(mask.iter())
                    .filter_map(|(v, k)| k.then_some(v))
                    .collect();
                (name, filtered)
            })
            .collect();
        if kept != n {
            // The record count IS the loader's extent, so say what was dropped.
            eprintln!(
                "  [esio] loader '{}': {n} records read, {kept} kept by its declared \
                 record filter",
                self.loader_name
            );
        }
        Ok(out)
    }
}

/// A record table's decoded columns, keyed by loader-variable name. Shared
/// (and refcounted) so every column read after the first is free.
type RecordColumns = Arc<HashMap<String, Vec<f64>>>;

/// Widen one numeric EarthSciIO column to `f64` (a text column with no `codes`
/// map is a modelling mistake, not a silent drop — same rule as
/// [`to_ess_field`]).
fn widen(name: &str, data: &ArrayData) -> Result<Vec<f64>, ProviderError> {
    Ok(match data {
        ArrayData::F64(v) => v.clone(),
        ArrayData::I64(v) => v.iter().map(|&x| x as f64).collect(),
        ArrayData::I32(v) => v.iter().map(|&x| x as f64).collect(),
        ArrayData::Bool(v) => v.iter().map(|&x| if x { 1.0 } else { 0.0 }).collect(),
        ArrayData::Str(_) => {
            return Err(err(format!(
                "loader variable '{name}' decoded as strings; a model forcing must be \
                 numeric (declare a `codes` map for it)"
            )));
        }
    })
}

/// Apply a declared `select` to an already-materialized array: take each axis's
/// indices, then DROP the `fixed` axes (which come back length 1).
fn apply_axes(
    key: &str,
    arr: ArrayD<f64>,
    axes: &[GateAxis],
) -> Result<ArrayD<f64>, ProviderError> {
    if axes.len() != arr.ndim() {
        return Err(err(format!(
            "provider '{key}': the declared select has {} axes but the array is rank {} \
             ({:?})",
            axes.len(),
            arr.ndim(),
            arr.shape()
        )));
    }
    let mut out = arr;
    for (i, ax) in axes.iter().enumerate() {
        let dim = out.shape()[i];
        let idx: Vec<usize> = match ax {
            GateAxis::All => continue,
            GateAxis::Fixed(f) => vec![*f],
            GateAxis::Range { start, stop, step } => (*start..*stop).step_by(*step).collect(),
            GateAxis::GatedBy(set) => {
                return Err(err(format!(
                    "provider '{key}': axis {i} gates on '{set}', which is resolved by \
                     value-invention inside prepare, not by an eager sample"
                )));
            }
        };
        if let Some(&bad) = idx.iter().find(|&&g| g >= dim) {
            return Err(err(format!(
                "provider '{key}': the declared select reaches index {bad} on axis {i}, \
                 whose native length is {dim}"
            )));
        }
        out = out.select(Axis(i), &idx);
    }
    // Fixed axes are length-1 by construction now; drop them.
    let drop: Vec<usize> = axes
        .iter()
        .enumerate()
        .filter_map(|(i, ax)| matches!(ax, GateAxis::Fixed(_)).then_some(i))
        .collect();
    if drop.is_empty() {
        return Ok(out);
    }
    let shape: Vec<usize> = out
        .shape()
        .iter()
        .enumerate()
        .filter(|(i, _)| !drop.contains(i))
        .map(|(_, &s)| s)
        .collect();
    out.into_shape_with_order(IxDyn(&shape)).map_err(|e| {
        err(format!(
            "provider '{key}': reshape after fixed-axis drop: {e}"
        ))
    })
}

/// One axis of a declared `select` that a reader can resolve on its own.
///
/// The [`GateAxis`] vocabulary minus `gated_by` — deliberately a SEPARATE type
/// rather than a comment claiming the gated case cannot occur. `CONFORMANCE_SPEC
/// §5.5` draws exactly this line: *"Only `gated_by` defers; the other three are
/// resolvable at read time"*. A gate resolves to a support set that
/// value-invention has not derived yet, so there is no honest reader spelling for
/// it — and with no variant to fill in, there is no arm in which to quietly
/// substitute the FULL axis and fetch the whole store.
#[derive(Debug, Clone, PartialEq)]
enum ReaderAxis {
    All,
    Fixed(usize),
    Range {
        start: usize,
        stop: usize,
        step: usize,
    },
}

impl ReaderAxis {
    /// The reader-resolvable form of a whole declared `select`, or `None` when
    /// ANY axis gates on a derived set — in which case the select DEFERS
    /// (`gate_spec` / `prepare`'s gated list) instead of reaching a reader.
    ///
    /// All-or-nothing on purpose: a per-axis fallback would push the resolvable
    /// axes and silently widen the gated one to the full axis, which is the
    /// difference between fetching a support set and fetching the store.
    fn from_declared(axes: &[GateAxis]) -> Option<Vec<Self>> {
        axes.iter()
            .map(|ax| match ax {
                GateAxis::All => Some(Self::All),
                GateAxis::Fixed(f) => Some(Self::Fixed(*f)),
                GateAxis::Range { start, stop, step } => Some(Self::Range {
                    start: *start,
                    stop: *stop,
                    step: *step,
                }),
                GateAxis::GatedBy(_) => None,
            })
            .collect()
    }
}

/// The reader-side spelling of a declared `select` — what a store-backed reader
/// can fetch pre-sliced. Total over [`ReaderAxis`], which is the point.
fn to_reader_selection(axes: &[ReaderAxis]) -> Selection {
    Selection::Orthogonal(
        axes.iter()
            .map(|ax| match ax {
                ReaderAxis::All => AxisSelect::All,
                ReaderAxis::Fixed(f) => AxisSelect::Indices(vec![*f]),
                ReaderAxis::Range { start, stop, step } => AxisSelect::Range {
                    start: *start,
                    stop: *stop,
                    step: *step,
                },
            })
            .collect(),
    )
}

/// Where a declared `select` is honoured. The first two arms produce the same
/// array; the reader arm just avoids fetching what it then throws away.
enum SelectApplication {
    /// No declared select.
    None,
    /// Pushed to the reader; only the `fixed` axes still need dropping. Its
    /// axes were all reader-resolvable ([`ReaderAxis`]), so this arm can never
    /// stand for a gate.
    Reader { drop_axes: Vec<usize> },
    /// Honoured engine-side rather than by the reader: applied after decode
    /// (whole-file reader, or after a record filter), or — when an axis gates
    /// on a derived set — DEFERRED, surfaced by
    /// [`PrepareProvider::gate_spec`](crate::prepare::PrepareProvider::gate_spec)
    /// and fetched pre-sliced after value-invention. This is the only arm that
    /// may carry a [`GateAxis::GatedBy`].
    Engine(Vec<GateAxis>),
}

/// Builder for [`EsioProvider`].
pub struct EsioProviderBuilder {
    loader: DataSource,
    cache: Arc<Cache>,
    window: Option<Window>,
    var_map: IndexMap<String, String>,
    select: Option<Selection>,
    declared: Option<Vec<GateAxis>>,
    table: Option<(Arc<RecordTable>, String)>,
    extent_mp: Option<String>,
    unit_conversion: Option<UnitConversion>,
    time_origin: f64,
}

impl EsioProviderBuilder {
    /// Map an on-disk `file_variable` to the model variable it feeds.
    ///
    /// When no mapping is declared the on-disk names are used verbatim, which is
    /// the common case for a loader whose variables are already named as the
    /// model refers to them.
    pub fn var(
        mut self,
        file_variable: impl Into<String>,
        model_variable: impl Into<String>,
    ) -> Self {
        self.var_map
            .insert(file_variable.into(), model_variable.into());
        self
    }

    /// Push a projection down to the reader (see the module docs).
    pub fn select(mut self, select: Selection) -> Self {
        self.select = Some(select);
        self
    }

    /// The run window bounding `refresh_times` / priming a DISCRETE materialize.
    pub fn window(mut self, window: Window) -> Self {
        self.window = Some(window);
        self
    }

    /// The UTC instant model time `0` stands for, in Unix seconds (esm-spec
    /// §2.2.7's time origin). A refresh at model time `t` reads the instant
    /// `time_origin + t`, and [`CadenceProvider::refresh_times`] reports
    /// anchors on the model clock (`unix - time_origin`).
    ///
    /// Defaults to `0.0`, the POSIX epoch, so model time IS Unix seconds for a
    /// caller that sets none. [`providers_from_document_with`] sets it from
    /// the document.
    pub fn time_origin(mut self, unix_seconds: f64) -> Self {
        self.time_origin = unix_seconds;
        self
    }

    /// The loader's DECLARED per-axis `select` (esm-spec §8.9) for this
    /// variable — `W[0:52411]` as a document field rather than a caller's
    /// slice.
    ///
    /// Where it is applied is an optimization, not a semantic: `build` pushes
    /// it down to the reader when the reader can fetch pre-sliced AND no rows
    /// are filtered first AND the loader is time-invariant, and otherwise
    /// applies it engine-side after decode. Both produce the same array.
    ///
    /// On a TIME-VARYING loader (one with a `temporal` cadence) the entries
    /// cover the delivered field's axes other than the time dimension (esm-spec
    /// §8.9.2), while a reader select is positional over every file dimension,
    /// time included; so it is never pushed there. With two records per sample
    /// an `"all"` entry is prepended for the leading record axis.
    ///
    /// The selection is defined over the axis the loader DELIVERS, so for a
    /// record-table loader it follows the record filter — `[0:200]` means the first 200 surviving records, never the
    /// first 200 raw rows of which some are dropped.
    ///
    /// A `gated_by` axis (esm-spec §8.9.2) is the one exception, and it is NOT
    /// an optimization: it names a derived index set whose members only exist
    /// after value-invention, so such a select always DEFERS — never pushed,
    /// never applied by an eager sample. `CONFORMANCE_SPEC §5.5`: *"Only
    /// `gated_by` defers; the other three are resolvable at read time."*
    pub fn declared_select(mut self, axes: Vec<GateAxis>) -> Self {
        self.declared = Some(axes);
        self
    }

    /// Serve this variable as a column of a shared record table (see
    /// [`RecordTable`]).
    fn record_column(mut self, table: Arc<RecordTable>, column: impl Into<String>) -> Self {
        self.table = Some((table, column.into()));
        self
    }

    /// Declare that this provider's extent binds a metaparameter (`extent`).
    fn extent_metaparameter(mut self, name: impl Into<String>) -> Self {
        self.extent_mp = Some(name.into());
        self
    }

    /// The variable's declared `unit_conversion` (esm-spec §8.5) — the factor
    /// or Expression that turns the raw on-disk column into the declared
    /// `units`. Applied at DELIVERY, after decode / codes / record filter /
    /// select; see [`EsioProvider::convert_units`].
    pub fn unit_conversion(mut self, conversion: UnitConversion) -> Self {
        self.unit_conversion = Some(conversion);
        self
    }

    /// Construct the provider, resolving the reader now so an unknown format
    /// fails here rather than mid-solve.
    pub fn build(self) -> Result<EsioProvider, ProviderError> {
        let table = self.table;
        if !self.time_origin.is_finite() {
            return Err(err(format!(
                "time origin {} is not a finite number of Unix seconds",
                self.time_origin
            )));
        }
        let temporal = self.loader.temporal.clone();
        let bracket = temporal
            .as_ref()
            .is_some_and(|t| t.records_per_sample == Some(2));
        if bracket && let Some((t, _)) = &table {
            return Err(err(format!(
                "loader '{}' is a record table (it declares a record_filter or codes), \
                 whose columns are 1-D records; records_per_sample = 2 (a bracket of \
                 two records) is not defined for it",
                t.loader_name
            )));
        }
        // A declared select names the source's native PER-RECORD axes (esm-spec
        // §8.9.2), never the bracket: a two-record sample carries an extra
        // LEADING record axis of length 2, taken whole. EarthSciIO keeps the
        // time dimension where the file has it, so a two-record sample is
        // delivered with it moved to axis 0 (`to_ess_field`).
        let record_dim = temporal
            .as_ref()
            .filter(|_| bracket)
            .map(|t| t.time_dim.clone());
        let declared = self.declared.map(|axes| {
            if bracket {
                std::iter::once(GateAxis::All).chain(axes).collect()
            } else {
                axes
            }
        });
        let inner = Provider::new(self.loader, self.cache, self.window)
            .map_err(|e| err(format!("EarthSciIO provider construction failed: {e}")))?;
        // A declared select goes to the reader when it can fetch pre-sliced,
        // there is no row filtering in front of it, AND every axis is one the
        // reader can resolve on its own. That last condition is what
        // `ReaderAxis::from_declared` decides: it has no `gated_by` variant to
        // produce, so a gated select cannot be spelled for a reader and falls
        // through to the engine arm — where `gate_spec()` reports it and
        // `prepare` fetches it pre-sliced to the support set once
        // value-invention has derived the members.
        //
        // A time-varying source never pushes: a reader-side select addresses
        // the FILE's on-disk axes, which include the record axis the declared
        // select does not name. Its select is applied after the record is
        // sliced instead.
        let (select, applied) = match declared {
            None => (self.select, SelectApplication::None),
            Some(axes) => {
                let pushable =
                    if inner.supports_selection() && table.is_none() && temporal.is_none() {
                        ReaderAxis::from_declared(&axes)
                    } else {
                        None
                    };
                match pushable {
                    Some(reader) => {
                        let drop_axes = reader
                            .iter()
                            .enumerate()
                            .filter_map(|(i, ax)| matches!(ax, ReaderAxis::Fixed(_)).then_some(i))
                            .collect();
                        (
                            Some(to_reader_selection(&reader)),
                            SelectApplication::Reader { drop_axes },
                        )
                    }
                    None => (self.select, SelectApplication::Engine(axes)),
                }
            }
        };
        Ok(EsioProvider {
            inner,
            var_map: self.var_map,
            select,
            applied,
            table,
            extent_mp: self.extent_mp,
            unit_conversion: self.unit_conversion,
            time_origin: self.time_origin,
            prime: prime_instant(temporal.as_ref(), self.window),
            time_varying: temporal.is_some(),
            table_anchor: None,
            record_dim,
        })
    }
}

/// An ESS [`CadenceProvider`] backed by a real EarthSciIO [`Provider`].
pub struct EsioProvider {
    inner: Provider,
    var_map: IndexMap<String, String>,
    select: Option<Selection>,
    /// Where the loader's declared `select` for THIS variable is applied.
    applied: SelectApplication,
    /// A record-table loader's shared decode + this variable's column name.
    table: Option<(Arc<RecordTable>, String)>,
    /// The metaparameter this provider's extent binds (`extent`).
    extent_mp: Option<String>,
    /// The variable's declared `unit_conversion` (esm-spec §8.5), if any.
    unit_conversion: Option<UnitConversion>,
    /// The instant model time 0 stands for, in Unix seconds.
    time_origin: f64,
    /// The instant a time-less sample reads (see [`prime_instant`]).
    prime: OffsetDateTime,
    /// The source declares a cadence (it is not const).
    time_varying: bool,
    /// The record anchor a record-table column was last served at, for the
    /// `refresh` None-skip.
    table_anchor: Option<OffsetDateTime>,
    /// The time dimension a two-record (`records_per_sample: 2`) sample is
    /// stacked along, moved to axis 0 on delivery; `None` for one record.
    record_dim: Option<String>,
}

/// The UTC instant `unix` Unix seconds name, rounded to the microsecond (see
/// [`EsioProvider::instant`]).
fn unix_instant(unix: f64) -> Result<OffsetDateTime, String> {
    if !unix.is_finite() {
        return Err(format!("{unix} is not a finite time"));
    }
    let micros = (unix * 1e6).round() as i128;
    OffsetDateTime::from_unix_timestamp_nanos(micros * 1000)
        .map_err(|e| format!("{unix} s is not a valid instant: {e}"))
}

/// The instant a time-less sample reads — EarthSciIO's own priming rule for a
/// DISCRETE `materialize`: the later of the run window's start and the
/// source's start. A const source has one record; its instant is immaterial.
fn prime_instant(
    temporal: Option<&earthsciio::SourceTemporal>,
    window: Option<Window>,
) -> OffsetDateTime {
    match (temporal, window) {
        (None, _) => OffsetDateTime::UNIX_EPOCH,
        (Some(t), Some((a, _))) if a > t.start => a,
        (Some(t), _) => t.start,
    }
}

impl EsioProvider {
    /// Start building a provider for `loader`, fetching through `cache`.
    pub fn builder(loader: DataSource, cache: Arc<Cache>) -> EsioProviderBuilder {
        EsioProviderBuilder {
            loader,
            cache,
            window: None,
            var_map: IndexMap::new(),
            select: None,
            declared: None,
            table: None,
            extent_mp: None,
            unit_conversion: None,
            time_origin: 0.0,
        }
    }

    /// True when a per-axis selection can be honoured without a whole-field
    /// sample: pushed to a reader that fetches pre-sliced, or, on a
    /// time-varying provider, gathered engine-side from the sample at `t`
    /// (whatever the reader).
    ///
    /// A record-table column never can: its rows are chosen by the loader's
    /// declared filter AFTER the decode, so an index pushed to the reader would
    /// address raw rows rather than the delivered ones. Nor can a time-varying
    /// source: a reader-side select addresses the file's on-disk axes, record
    /// axis included, so the record is fetched whole and sliced engine-side.
    pub fn supports_selection(&self) -> bool {
        self.table.is_none() && !self.time_varying && self.inner.supports_selection()
    }

    /// The instant model time 0 stands for, in Unix seconds (see
    /// [`EsioProviderBuilder::time_origin`]).
    pub fn time_origin(&self) -> f64 {
        self.time_origin
    }

    /// The UTC instant model time `t` reads: `time_origin + t`, rounded to the
    /// microsecond so an anchor reported by `refresh_times` (`unix - origin`)
    /// and handed back lands on that anchor exactly, not a binary64 rounding
    /// error below it — which would snap to the previous record.
    fn instant(&self, t: f64) -> Result<OffsetDateTime, ProviderError> {
        unix_instant(self.time_origin + t).map_err(|why| {
            err(format!(
                "model time {t} (origin {}): {why}",
                self.time_origin
            ))
        })
    }

    /// A record-table column at instant `at`, keyed by the model variable it
    /// feeds, with the record anchor it was decoded at. Before the declared
    /// select and unit conversion.
    fn table_fields(
        &self,
        at: OffsetDateTime,
    ) -> Result<(Option<OffsetDateTime>, HashMap<String, NativeField>), ProviderError> {
        let (table, column) = self
            .table
            .as_ref()
            .expect("table_fields is only called on a record-table column");
        let model_name = self
            .var_map
            .values()
            .next()
            .cloned()
            .unwrap_or_else(|| column.clone());
        let (anchor, array) = table.column_at(column, at)?;
        let field = NativeField {
            array,
            coords: IndexMap::new(),
        };
        Ok((anchor, HashMap::from([(model_name, field)])))
    }

    /// The full native shape of on-disk array `var` without reading any chunk —
    /// enough to decide whether a pushdown is worth it.
    pub fn array_shape(&self, var: &str) -> Result<Option<Vec<usize>>, ProviderError> {
        self.inner
            .array_shape(var)
            .map_err(|e| err(format!("array_shape({var}) failed: {e}")))
    }

    /// Rename on-disk keys to model-variable keys and convert each field.
    fn convert(
        &self,
        fields: HashMap<String, EsioField>,
    ) -> Result<HashMap<String, NativeField>, ProviderError> {
        self.convert_with(fields, self.inner.coords())
    }

    /// [`convert`](Self::convert) against an explicit coordinate set (a
    /// stateless sample's own, rather than the provider buffer's).
    fn convert_with(
        &self,
        fields: HashMap<String, EsioField>,
        coords: &HashMap<String, earthsciio::format::Coord>,
    ) -> Result<HashMap<String, NativeField>, ProviderError> {
        let mut out = HashMap::with_capacity(fields.len());
        for (disk_name, f) in fields {
            let model_name = self
                .var_map
                .get(&disk_name)
                .cloned()
                .unwrap_or_else(|| disk_name.clone());
            out.insert(
                model_name,
                to_ess_field(&disk_name, f, coords, self.record_dim.as_deref())?,
            );
        }
        Ok(out)
    }
}

// --------------------------------------------------------------------------- //
// `prepare` integration (Phase 4 clean consolidation): the build-time
// [`crate::prepare::PrepareProvider`] contract, so the engine's record-derived
// gated deferral can drive a REAL EarthSciIO fetch pre-sliced to the invented
// support set — the runner's hand-built `Selection::Orthogonal` moved into the
// engine.
// --------------------------------------------------------------------------- //

/// Run-time options of [`providers_from_document_with`]. None of them changes
/// what a document means; they say where its data is for this run.
#[cfg(not(target_arch = "wasm32"))]
#[derive(Debug, Clone, Default)]
pub struct DocumentProviderOptions {
    /// Restrict to these sources (each must then be constructible).
    pub loaders: Option<Vec<String>>,
    /// Source name ⇒ a replacement URL template (its mirrors are dropped).
    pub url_overrides: HashMap<String, String>,
    /// Source name ⇒ the custom `{name}` substitutions a mount's
    /// `url_substitutions` left unbound (reseact's NEI 2016 `{sector}`).
    pub substitutions: HashMap<String, std::collections::BTreeMap<String, String>>,
    /// The run window (UTC) bounding each time-varying provider.
    pub window: Option<earthsciio::Window>,
    /// Consuming parameter key ⇒ records per sample (1, or 2 for the bracket),
    /// a run-time restatement of the document's value, never a change to it.
    /// Each parameter receives the number its record shape gives it (esm-spec
    /// §8.5.1): 2 when the record shape (its declared `shape`, else its
    /// `param_to_var` targets' declared shapes) begins with an interval index
    /// set carrying `"records": true`, else 1. With 2 the provider returns the
    /// record at or before `t` and the next one, stacked along the first
    /// dimension. An entry for a consuming parameter must equal that value: a
    /// different one would change the rank of the delivered array away from
    /// the declared shape validation approved, so it is refused (give the
    /// record shape a record axis in the document instead). Each
    /// consuming parameter has its own provider, so two parameters may read
    /// one source with different values.
    pub records_per_sample: HashMap<String, u32>,
}

#[cfg(not(target_arch = "wasm32"))]
mod prepare_impl {
    use super::*;
    use crate::prepare::{AxisSel, PrepareError, PrepareProvider};
    use crate::pushdown_rewrite::ProviderGate;
    use earthsciio::format::AxisSelect;

    fn perr(msg: impl Into<String>) -> PrepareError {
        PrepareError(msg.into())
    }

    /// A `select.axes` declaration on a loader or one of its variables.
    ///
    /// A `range` bound may be an integer or the NAME of a metaparameter, which
    /// resolves to that metaparameter's document default — so a loader can say
    /// `W[0:N_SRC]` in the model's own terms instead of repeating 52411 and
    /// drifting from the index set sized by it.
    fn parse_declared_select(
        doc: &serde_json::Value,
        ctx: &str,
        node: &serde_json::Value,
    ) -> Result<Option<Vec<GateAxis>>, PrepareError> {
        let Some(sel) = node.get("select") else {
            return Ok(None);
        };
        let axes = sel
            .get("axes")
            .and_then(serde_json::Value::as_array)
            .ok_or_else(|| perr(format!("{ctx}.select needs an \"axes\" array")))?;
        let resolved: Vec<serde_json::Value> = axes
            .iter()
            .map(|ax| resolve_range_bounds(doc, ctx, ax))
            .collect::<Result<_, _>>()?;
        crate::pushdown_rewrite::parse_select_axes(&format!("{ctx}.select"), &resolved, None)
            .map(Some)
            .map_err(|e| perr(e.0))
    }

    /// Replace any metaparameter-named `range` bound with its document default.
    fn resolve_range_bounds(
        doc: &serde_json::Value,
        ctx: &str,
        ax: &serde_json::Value,
    ) -> Result<serde_json::Value, PrepareError> {
        let Some(range) = ax.get("range").and_then(serde_json::Value::as_object) else {
            return Ok(ax.clone());
        };
        let mut out = range.clone();
        for bound in ["start", "stop", "step"] {
            let Some(name) = out.get(bound).and_then(serde_json::Value::as_str) else {
                continue;
            };
            let v = doc
                .get("metaparameters")
                .and_then(|m| m.get(name))
                .and_then(|m| m.get("default"))
                .and_then(serde_json::Value::as_i64)
                .ok_or_else(|| {
                    perr(format!(
                        "{ctx}.select: range.{bound} names {name:?}, which is not a \
                         metaparameter with an integer default"
                    ))
                })?;
            out.insert(bound.to_string(), serde_json::Value::from(v));
        }
        Ok(serde_json::json!({ "range": out }))
    }

    /// A loader variable's `codes` map (string column → number).
    fn parse_codes(ctx: &str, vd: &serde_json::Value) -> Result<Option<CodeMap>, PrepareError> {
        let Some(codes) = vd.get("codes") else {
            return Ok(None);
        };
        let map = codes
            .get("map")
            .and_then(serde_json::Value::as_object)
            .ok_or_else(|| perr(format!("{ctx}.codes needs a \"map\" object")))?;
        let case_insensitive = codes
            .get("case_insensitive")
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(false);
        let unmapped = match codes.get("unmapped") {
            None => Unmapped::Error,
            Some(v) if v.as_str() == Some("drop") => Unmapped::Drop,
            Some(v) if v.as_str() == Some("error") => Unmapped::Error,
            Some(v) => Unmapped::Value(v.as_f64().ok_or_else(|| {
                perr(format!(
                    "{ctx}.codes.unmapped must be \"drop\", \"error\" or a number"
                ))
            })?),
        };
        let mut out = HashMap::with_capacity(map.len());
        for (k, v) in map {
            let n = v
                .as_f64()
                .ok_or_else(|| perr(format!("{ctx}.codes.map[{k:?}] must be a number")))?;
            out.insert(
                if case_insensitive {
                    k.to_uppercase()
                } else {
                    k.clone()
                },
                n,
            );
        }
        Ok(Some(CodeMap {
            map: out,
            case_insensitive,
            unmapped,
        }))
    }

    /// The single field of a `materialize` result (the `prepare` providers
    /// contract is one provider per fed variable).
    fn single_field(fields: HashMap<String, NativeField>) -> Result<ArrayD<f64>, PrepareError> {
        if fields.len() != 1 {
            let mut keys: Vec<_> = fields.keys().cloned().collect();
            keys.sort();
            return Err(perr(format!(
                "prepare provider expects exactly one field per provider, got {keys:?}; \
                 construct one EsioProvider per variable (providers_from_document does)"
            )));
        }
        Ok(fields.into_values().next().unwrap().array)
    }

    fn to_selection(selection: &[AxisSel]) -> Selection {
        Selection::Orthogonal(
            selection
                .iter()
                .map(|ax| match ax {
                    AxisSel::All => AxisSelect::All,
                    AxisSel::Indices(idx) => AxisSelect::Indices(idx.clone()),
                    AxisSel::Range { start, stop, step } => AxisSelect::Range {
                        start: *start,
                        stop: *stop,
                        step: *step,
                    },
                })
                .collect(),
        )
    }

    /// Take each axis's selection of an already-read array, keeping every
    /// axis (a fixed axis comes back length 1, as a reader would return it).
    fn slice_selection(
        key: &str,
        arr: ArrayD<f64>,
        selection: &[AxisSel],
    ) -> Result<ArrayD<f64>, PrepareError> {
        if selection.len() != arr.ndim() {
            return Err(perr(format!(
                "provider '{key}': the selection has {} axes but the array is rank {} ({:?})",
                selection.len(),
                arr.ndim(),
                arr.shape()
            )));
        }
        let mut out = arr;
        for (i, ax) in selection.iter().enumerate() {
            let idx: Vec<usize> = match ax {
                AxisSel::All => continue,
                AxisSel::Indices(idx) => idx.clone(),
                AxisSel::Range { start, stop, step } => {
                    (*start..*stop).step_by((*step).max(1)).collect()
                }
            };
            let dim = out.shape()[i];
            if let Some(&bad) = idx.iter().find(|&&g| g >= dim) {
                return Err(perr(format!(
                    "provider '{key}': the selection reaches index {bad} on axis {i}, \
                     whose native length is {dim}"
                )));
            }
            out = out.select(Axis(i), &idx);
        }
        Ok(out)
    }

    impl EsioProvider {
        /// [`PrepareProvider::sample_with_selection`] for a provider that
        /// cannot push a selection down: the record a time-less sample reads
        /// (`prime`), sampled statelessly and whole, then sliced here — never
        /// a reader-side select, which would address the file's record axis.
        fn sample_then_select(
            &mut self,
            selection: &[AxisSel],
        ) -> Result<ArrayD<f64>, PrepareError> {
            self.sample_then_select_at(self.prime, selection)
        }

        /// [`Self::sample_then_select`] at instant `at` rather than `prime`.
        fn sample_then_select_at(
            &mut self,
            at: OffsetDateTime,
            selection: &[AxisSel],
        ) -> Result<ArrayD<f64>, PrepareError> {
            let pe = |e: ProviderError| perr(e.to_string());
            let fields = if self.table.is_some() {
                self.table_fields(at).map_err(pe)?.1
            } else if let Some(sel) = &self.select {
                // A caller's explicit reader select stays a per-call peek.
                let fields = self
                    .inner
                    .refresh_with_select(at, Some(sel))
                    .map_err(|e| perr(format!("EarthSciIO sample failed: {e}")))?
                    .unwrap_or_default();
                self.convert(fields).map_err(pe)?
            } else {
                let ds = self
                    .inner
                    .sample_at(at)
                    .map_err(|e| perr(format!("EarthSciIO sample failed: {e}")))?;
                self.convert_with(ds.variables, &ds.coords).map_err(pe)?
            };
            let mut sliced = HashMap::with_capacity(fields.len());
            for (key, mut f) in fields {
                f.array = slice_selection(&key, f.array, selection)?;
                f.coords.clear(); // the native coordinates index the FULL axes
                sliced.insert(key, f);
            }
            // As on the pushed path, the gate IS the whole selection; only the
            // declared unit_conversion still applies.
            single_field(self.convert_units(sliced).map_err(pe)?)
        }
    }

    impl PrepareProvider for EsioProvider {
        fn sample(&mut self) -> Result<ArrayD<f64>, PrepareError> {
            let fields = CadenceProvider::materialize(self).map_err(|e| perr(e.to_string()))?;
            single_field(fields)
        }

        fn supports_selection(&self) -> bool {
            EsioProvider::supports_selection(self)
        }

        fn sample_with_selection(
            &mut self,
            selection: &[AxisSel],
        ) -> Result<ArrayD<f64>, PrepareError> {
            if self.table.is_some() || self.time_varying {
                // Never pushed (see `supports_selection`): read the record a
                // time-less sample primes at whole, and select engine-side.
                return self.sample_then_select(selection);
            }
            let sel = to_selection(selection);
            let fields = self
                .inner
                .materialize_with_select(Some(&sel))
                .map_err(|e| perr(format!("EarthSciIO gated materialize failed: {e}")))?;
            let fields = self.convert(fields).map_err(|e| perr(e.to_string()))?;
            // The gate IS the whole selection for this fetch, so the declared
            // select is not applied again — but the declared unit_conversion
            // still is: it is a property of the VALUES, not of which of them
            // were fetched.
            let fields = self
                .convert_units(fields)
                .map_err(|e| perr(e.to_string()))?;
            single_field(fields)
        }

        fn is_const(&self) -> bool {
            CadenceProvider::refresh_times(self).is_empty()
        }

        fn gate_spec(&self) -> Option<ProviderGate> {
            let SelectApplication::Engine(axes) = &self.applied else {
                return None;
            };
            // A declared select with a `gated_by` axis IS a provider-declared
            // gate: prepare defers it past value-invention and fetches it
            // pre-sliced to the materialised members.
            axes.iter()
                .any(|a| matches!(a, GateAxis::GatedBy(_)))
                .then(|| ProviderGate {
                    axes: axes.clone(),
                    applies_to: self
                        .var_map
                        .values()
                        .map(|v| v.rsplit('.').next().unwrap_or(v).to_string())
                        .collect(),
                })
        }

        fn extent_metaparameter(&self) -> Option<String> {
            self.extent_mp.clone()
        }
    }

    impl EsioProvider {
        /// The sample at model time `t` (seconds from the time origin, the
        /// scale of [`refresh_times`](CadenceProvider::refresh_times)) with a
        /// resolved per-axis `selection` over the parameter's DELIVERED axes
        /// (for two records per sample the first entry addresses the record
        /// axis).
        ///
        /// A time-varying provider reads the sample at `t` statelessly,
        /// without touching its refresh buffer, and slices the selection
        /// engine-side, since a reader select is positional over the file's
        /// dimensions, time included. A time-invariant provider has one
        /// sample, so `t` is not consulted and the selection goes through
        /// [`PrepareProvider::sample_with_selection`].
        pub fn sample_with_selection_at(
            &mut self,
            t: f64,
            selection: &[AxisSel],
        ) -> Result<ArrayD<f64>, ProviderError> {
            if !self.time_varying {
                return PrepareProvider::sample_with_selection(self, selection)
                    .map_err(|e| err(e.0));
            }
            let at = self.instant(t)?;
            self.sample_then_select_at(at, selection)
                .map_err(|e| err(e.0))
        }
    }

    /// One parameter's data binding to a source (see [`document_bindings`]).
    struct ParamBinding<'a> {
        /// The parameter's flattened (namespaced) path — the provider key.
        key: String,
        /// The parameter's bare name within its model.
        local: String,
        /// The parameter's `update.from` binding object (`file_variable`,
        /// `codes`, `unit_conversion`, …).
        from: &'a serde_json::Value,
        /// The parameter's declared `shape`, `None` when it declares none.
        shape: Option<&'a serde_json::Value>,
    }

    /// `{data_sources key -> [ParamBinding]}` — per source, the consuming
    /// parameters' flattened names, local names, and `update.from` bindings.
    ///
    /// From 1.0.0 a data source declares no variables of its own: the CONSUMING
    /// PARAMETER carries `update: {kind: "data", source, from: {file_variable,
    /// ...}}` and owns the units (esm-spec §8.5). This is the inversion of the
    /// 0.x `data_loaders[l].variables` map, and it is where the provider path
    /// now reads what to decode. The Python mirror is `_document_bindings`.
    ///
    /// The flattened name is the parameter's namespaced path (`"Ingest.lon"`,
    /// `"Parent.Child.lon"`), which is what keys the provider: it is the only
    /// spelling that names one parameter and every parameter. Neither half of
    /// the source-qualified alternative works — two parameters may read one
    /// `file_variable` differently (the ingest fixture's `W` / `src_W` /
    /// `emis_W` all read `Grid`'s `W`), and two models may declare the same
    /// parameter name against one source.
    ///
    /// Models, nested subsystems and variables are all walked in sorted order,
    /// so the constructed provider set — and therefore the diagnostics — are
    /// deterministic.
    fn document_bindings(doc: &serde_json::Value) -> HashMap<String, Vec<ParamBinding<'_>>> {
        fn sorted_keys(node: Option<&serde_json::Value>) -> Vec<&str> {
            let mut keys: Vec<&str> = node
                .and_then(serde_json::Value::as_object)
                .map(|o| o.keys().map(String::as_str).collect())
                .unwrap_or_default();
            keys.sort_unstable();
            keys
        }

        fn visit<'a>(
            model: &'a serde_json::Value,
            prefix: &str,
            out: &mut HashMap<String, Vec<ParamBinding<'a>>>,
        ) {
            let vars = model.get("variables");
            for vname in sorted_keys(vars) {
                let vdef = &vars.expect("sorted_keys is empty without an object")[vname];
                if vdef.get("type").and_then(serde_json::Value::as_str) != Some("parameter") {
                    continue;
                }
                let update = vdef.get("update");
                let rules: Vec<&serde_json::Value> = match update {
                    Some(serde_json::Value::Array(a)) => a.iter().collect(),
                    Some(v) => vec![v],
                    None => Vec::new(),
                };
                for rule in rules {
                    if rule.get("kind").and_then(serde_json::Value::as_str) != Some("data") {
                        continue;
                    }
                    let (Some(binding), Some(source)) = (
                        rule.get("from").filter(|f| f.is_object()),
                        rule.get("source").and_then(serde_json::Value::as_str),
                    ) else {
                        continue;
                    };
                    let key = if prefix.is_empty() {
                        vname.to_string()
                    } else {
                        format!("{prefix}.{vname}")
                    };
                    out.entry(source.to_string())
                        .or_default()
                        .push(ParamBinding {
                            key,
                            local: vname.to_string(),
                            from: binding,
                            shape: vdef.get("shape").filter(|v| !v.is_null()),
                        });
                    break; // the FIRST data rule of an `update` (esm-spec §5.4)
                }
            }
            let subs = model.get("subsystems");
            for sname in sorted_keys(subs) {
                let sub = &subs.expect("sorted_keys is empty without an object")[sname];
                let next = if prefix.is_empty() {
                    sname.to_string()
                } else {
                    format!("{prefix}.{sname}")
                };
                visit(sub, &next, out);
            }
        }

        let mut out: HashMap<String, Vec<ParamBinding<'_>>> = HashMap::new();
        let models = doc.get("models");
        for mname in sorted_keys(models) {
            visit(
                &models.expect("sorted_keys is empty without an object")[mname],
                mname,
                &mut out,
            );
        }
        for entries in out.values_mut() {
            entries.sort_by(|a, b| a.key.cmp(&b.key));
        }
        out
    }

    /// The time origin of the providers a document builds, in Unix seconds:
    /// the instant model time 0 stands for. First match wins:
    ///
    /// 1. `domain.temporal.reference_time`, when it is a non-empty string;
    /// 2. else `domain.temporal.start`, when it is a non-empty string;
    /// 3. else the start of the run `window`, when one was given;
    /// 4. else the POSIX epoch (model time is then Unix seconds).
    ///
    /// An empty string is skipped, as esm-spec §2.2.7 says loaders do; any
    /// other present value that is not an RFC 3339 date-time is an error,
    /// read by the §2.2.7 clock accessor [`crate::solver::time_origin`] so the
    /// message is that accessor's.
    fn document_time_origin(
        doc: &serde_json::Value,
        window: Option<Window>,
    ) -> Result<f64, PrepareError> {
        if let Some(temporal) = doc
            .pointer("/domain/temporal")
            .and_then(serde_json::Value::as_object)
        {
            for key in ["reference_time", "start"] {
                match temporal.get(key) {
                    None => {}
                    Some(serde_json::Value::String(s)) if s.is_empty() => {}
                    Some(v) => {
                        // The accessor reads `reference_time` first, so hand it
                        // the one field that applies here.
                        let domain = serde_json::json!({ "temporal": { key: v } });
                        return crate::solver::time_origin(&domain)
                            .map_err(|e| perr(format!("providers_from_document: {e}")));
                    }
                }
            }
        }
        Ok(window.map_or(0.0, |(start, _)| {
            start.unix_timestamp() as f64 + f64::from(start.nanosecond()) * 1e-9
        }))
    }

    /// Document-declared provider construction — the Rust mirror of the Python
    /// `earthsci_ast.data_sources.esio_provider.providers_from_document` (and
    /// the Julia EarthSciIO extension's namesake). The document's
    /// `data_sources` say WHAT to read (`source.url_template`) and
    /// `metadata.esio_format` says HOW (the EarthSciIO format-registry name);
    /// the PARAMETERS bound to a source say which `file_variable` each consumer
    /// wants and how to convert it (see [`document_bindings`]). The runner no
    /// longer hand-constructs providers — it asks the document.
    ///
    /// One provider PER VARIABLE (keyed `"<ModelPath>.<param>"`), matching (a)
    /// `prepare`'s providers contract, (b) the single-field sample, and (c)
    /// the per-key gate the record-derived pushdown path attaches. All of a
    /// loader's providers share one [`Cache`] (a per-loader subdir under
    /// `cache_root`) so a store's metadata objects are fetched once.
    ///
    /// `loaders` restricts to the named loaders (each MUST be constructible —
    /// a missing `metadata.esio_format` errors); an unrestricted sweep skips
    /// format-less loaders. `url_overrides` maps a loader name to a
    /// replacement URL (e.g. a local `file://` mirror).
    pub fn providers_from_document(
        doc: &serde_json::Value,
        cache_root: &std::path::Path,
        loaders: Option<&[&str]>,
        url_overrides: &HashMap<String, String>,
    ) -> Result<Vec<(String, EsioProvider)>, PrepareError> {
        providers_from_document_with(
            doc,
            cache_root,
            &DocumentProviderOptions {
                loaders: loaders.map(|l| l.iter().map(|s| s.to_string()).collect()),
                url_overrides: url_overrides.clone(),
                ..Default::default()
            },
        )
    }

    /// A written `records_per_sample` value read for consuming parameter `key`
    /// from `origin`: absent (or `null`) is `None`; otherwise it must be a JSON
    /// number whose value is exactly 1 or 2 (`2.0` is 2). Anything else is
    /// refused, naming the parameter, where the value came from and the value.
    fn written_records_per_sample(
        key: &str,
        origin: &str,
        value: Option<&serde_json::Value>,
    ) -> Result<Option<u32>, PrepareError> {
        let Some(v) = value.filter(|v| !v.is_null()) else {
            return Ok(None);
        };
        match v.as_f64() {
            Some(1.0) => Ok(Some(1)),
            Some(2.0) => Ok(Some(2)),
            _ => Err(perr(format!(
                "providers_from_document: parameter '{key}': records_per_sample in {origin} \
                 must be the number 1 or 2, got {v}"
            ))),
        }
    }

    /// The declared `shape` of the variable a scoped name `Model[.Sub…].var`
    /// names in raw document `doc`: `Some(None)` when it declares none,
    /// `None` when the document does not reach that declaration.
    fn raw_declared_shape<'a>(
        doc: &'a serde_json::Value,
        scoped: &str,
    ) -> Option<Option<&'a serde_json::Value>> {
        let mut parts: Vec<&str> = scoped.split('.').collect();
        let var = parts.pop()?;
        let (first, rest) = parts.split_first()?;
        let mut node = doc.get("models")?.get(*first)?;
        for seg in rest {
            node = node.get("subsystems")?.get(*seg)?;
        }
        let vdef = node.get("variables")?.get(var)?;
        Some(vdef.get("shape").filter(|v| !v.is_null()))
    }

    /// The number of records consuming parameter `key`, declaring raw
    /// `shape`, receives (esm-spec §8.5.1), read from raw document `doc`: its
    /// record shape is its own `shape`, else the declared `shape` of each
    /// `param_to_var` target it is the `from` of in the raw `coupling` (a
    /// target the document does not reach is skipped), and it receives 2 when
    /// that begins with an `index_sets` entry that is an `interval` carrying
    /// `"records": true`. A misplaced record axis is refused.
    fn raw_records_received(
        doc: &serde_json::Value,
        key: &str,
        shape: Option<&serde_json::Value>,
    ) -> Result<Option<u32>, PrepareError> {
        let as_dims = |v: &serde_json::Value| -> Vec<String> {
            v.as_array()
                .map(|a| {
                    a.iter()
                        .filter_map(|d| d.as_str().map(str::to_string))
                        .collect()
                })
                .unwrap_or_default()
        };
        let coupling: Vec<&serde_json::Value> = doc
            .get("coupling")
            .and_then(serde_json::Value::as_array)
            .into_iter()
            .flatten()
            .collect();
        let shapes: Vec<Vec<String>> = match shape {
            Some(own) => vec![as_dims(own)],
            None => {
                let targets: Vec<&str> = coupling
                    .iter()
                    .filter(|e| {
                        e.get("type").and_then(serde_json::Value::as_str) == Some("variable_map")
                            && e.get("transform").and_then(serde_json::Value::as_str)
                                == Some("param_to_var")
                            && e.get("from").and_then(serde_json::Value::as_str) == Some(key)
                    })
                    .filter_map(|e| e.get("to").and_then(serde_json::Value::as_str))
                    .collect();
                let shapes: Vec<Vec<String>> = targets
                    .iter()
                    .filter_map(|to| raw_declared_shape(doc, to))
                    .map(|s| s.map(as_dims).unwrap_or_default())
                    .collect();
                // The document as given cannot show the record shape: every
                // target is unreachable (behind an unmounted ref), or none is
                // mapped inline while a coupling_import (expanded only by
                // `flatten`) could still bring one. The count is unknown.
                let pending_import = coupling.iter().any(|e| {
                    e.get("type").and_then(serde_json::Value::as_str) == Some("coupling_import")
                });
                if shapes.is_empty() && (!targets.is_empty() || pending_import) {
                    return Ok(None);
                }
                shapes
            }
        };
        let is_record_axis = |d: &str| {
            doc.get("index_sets")
                .and_then(|s| s.get(d))
                .is_some_and(|set| {
                    set.get("kind").and_then(serde_json::Value::as_str) == Some("interval")
                        && set.get("records").and_then(serde_json::Value::as_bool) == Some(true)
                })
        };
        crate::structural::records_from_shapes(&shapes, is_record_axis)
            .map(|n| Some(u32::from(n)))
            .map_err(|bad| {
                perr(format!(
                    "providers_from_document: parameter '{key}': record_axis_misplaced: its \
                     record shape {bad:?} names a record axis anywhere but first, or its \
                     record shapes disagree about beginning with one (esm-spec §8.5.1)"
                ))
            })
    }

    /// Whether esm source `ld` is time-varying: its `temporal` block anchors at
    /// a non-empty `start`. EarthSciIO reads a source without one as
    /// time-invariant (EarthSciIO `spec/esm-sources.md` §3).
    fn is_time_varying(ld: &serde_json::Value) -> bool {
        ld.get("temporal")
            .and_then(|t| t.get("start"))
            .is_some_and(|s| !s.is_null() && s.as_str() != Some(""))
    }

    /// [`providers_from_document`] with every run-time option: the custom
    /// substitutions per source, the run window (UTC) bounding each
    /// time-varying provider's refresh times, and the two-record bracket per
    /// consuming parameter.
    ///
    /// **Clock.** Every provider runs on the document's model clock: its time
    /// origin is `domain.temporal.reference_time`, else `domain.temporal.start`
    /// (each when a non-empty string), else the start of `opts.window`, else
    /// the POSIX epoch. A refresh at model time `t` reads the instant
    /// `origin + t`, and `refresh_times` are model seconds (`unix - origin`).
    ///
    /// **Window.** Without `opts.window`, a document with a `solver.time_span`
    /// bounds the providers by `(origin + start, origin + end)`, its bounds in
    /// seconds on the §2.2.7 clock. With neither, the providers are unbounded:
    /// a time-varying source reports refresh times only up to its own declared
    /// `temporal.end`, and none when it declares no end.
    ///
    /// A record-table source (`record_filter` or `codes`) with
    /// `records_per_sample = 2` is refused, and an empty `url_overrides` entry
    /// is refused before EarthSciIO is called.
    pub fn providers_from_document_with(
        doc: &serde_json::Value,
        cache_root: &std::path::Path,
        opts: &DocumentProviderOptions,
    ) -> Result<Vec<(String, EsioProvider)>, PrepareError> {
        let loaders = opts.loaders.as_deref();
        // esm-spec §2.2.7 / §8.3: the instant model time 0 stands for, and the
        // run window — the caller's, else the document's `solver.time_span`
        // placed on that clock.
        let time_origin = document_time_origin(doc, opts.window)?;
        let window = match opts.window {
            Some(w) => Some(w),
            None => crate::solver::raw_time_span_seconds(doc)
                .map_err(|e| perr(format!("providers_from_document: {e}")))?
                .map(|(start, end)| -> Result<Window, PrepareError> {
                    let at = |s: f64| {
                        unix_instant(time_origin + s).map_err(|why| {
                            perr(format!(
                                "providers_from_document: solver.time_span bound {s} s \
                                 from the time origin: {why}"
                            ))
                        })
                    };
                    Ok((at(start)?, at(end)?))
                })
                .transpose()?,
        };
        let dls = doc
            .get("data_sources")
            .and_then(|v| v.as_object())
            .ok_or_else(|| {
                perr("providers_from_document: the document declares no data_sources")
            })?;
        let bindings = document_bindings(doc);
        let mut out = Vec::new();
        for (lname, ld) in dls {
            if let Some(want) = loaders
                && !want.iter().any(|w| w == lname)
            {
                continue;
            }
            // An override present is honoured whatever its value, so an empty
            // one is a caller error, not a reason to fall back to the template.
            let url_override = match opts.url_overrides.get(lname) {
                Some(u) if u.is_empty() => {
                    return Err(perr(format!(
                        "providers_from_document: url_overrides[\"{lname}\"] is empty"
                    )));
                }
                other => other.cloned(),
            };
            let has_format = ld
                .get("metadata")
                .and_then(|m| m.get("esio_format"))
                .and_then(|v| v.as_str())
                .is_some();
            if !has_format {
                if loaders.is_none() {
                    continue;
                }
                return Err(perr(format!(
                    "providers_from_document: data_sources.{lname} declares no \
                     metadata.esio_format — cannot construct a provider for it"
                )));
            }
            let consumers = match bindings.get(lname.as_str()) {
                Some(c) if !c.is_empty() => c,
                // A source no parameter reads has nothing to provide. Not an
                // error: a document may carry a source only some of its models
                // consume.
                _ => continue,
            };
            let cache = Arc::new(
                Cache::builder()
                    .data_dir(cache_root.join(lname))
                    .build()
                    .map_err(|e| perr(format!("cache for {lname}: {e}")))?,
            );

            // --- the loader's DECLARED decode semantics (esm-spec §8.9) ------
            // (`reader_options` reach the reader through `DataSource::from_esm`.)
            let loader_select = parse_declared_select(doc, &format!("data_sources.{lname}"), ld)?;
            // The source's location and cadence are read by EarthSciIO itself
            // (EarthSciIO spec/esm-sources.md §3): esm templates expanded at each
            // file anchor (`substitutions[lname]` binds the placeholders a mount
            // left) and a calendar cadence, so `P1M` is a calendar month rather
            // than a mean one. A dropped cadence would also pin the first file in
            // EarthSciIO's cache for ever, since CONST blobs are never revalidated.
            let source_subs = opts.substitutions.get(lname).cloned().unwrap_or_default();
            let make_loader = |vars: Vec<String>, rps: Option<u32>| {
                DataSource::from_esm(
                    lname,
                    ld,
                    &earthsciio::EsmSourceOptions {
                        variables: vars,
                        substitutions: source_subs.clone(),
                        url_override: url_override.clone(),
                        records_per_sample: rps,
                    },
                )
                .map_err(|e| perr(format!("providers_from_document: {e}")))
            };
            let extent_mp = ld
                .get("extent")
                .and_then(|e| e.get("metaparameter"))
                .and_then(serde_json::Value::as_str)
                .map(str::to_string);
            let require_finite: Vec<String> = ld
                .get("record_filter")
                .and_then(|f| f.get("require_finite"))
                .and_then(serde_json::Value::as_array)
                .map(|a| {
                    a.iter()
                        .filter_map(|v| v.as_str().map(str::to_string))
                        .collect()
                })
                .unwrap_or_default();

            let mut columns: Vec<ColumnSpec> = Vec::new();
            for b in consumers {
                let key = &b.key;
                let fv = b
                    .from
                    .get("file_variable")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or(&b.local);
                columns.push(ColumnSpec {
                    name: key.clone(),
                    file_variable: fv.to_string(),
                    codes: parse_codes(&format!("{key}.update.from"), b.from)?,
                    unit_conversion: parse_unit_conversion(b.from.get("unit_conversion"), key)
                        .map_err(|e| perr(e.to_string()))?,
                });
            }
            // A record filter or a code map makes the loader a TABLE: one
            // decode, one keep mask, columns that stay aligned.
            let is_table = !require_finite.is_empty() || columns.iter().any(|c| c.codes.is_some());
            // Each consumer's record count, from its record shape (esm-spec
            // §8.5.1), checked against any written (deprecated) value and the
            // run-time option before EarthSciIO reads the source, so a refusal
            // names the parameter whatever EarthSciIO would make of the source.
            let mut effective_rps = Vec::with_capacity(consumers.len());
            for b in consumers {
                let key = &b.key;
                let shaped = raw_records_received(doc, key, b.shape)?;
                // The deprecated written value (its own, else the source's) is
                // still read strictly, and must agree with the record shape.
                let own = written_records_per_sample(
                    key,
                    "update.from",
                    b.from.get("records_per_sample"),
                )?;
                let inherited = written_records_per_sample(
                    key,
                    &format!("data_sources.{lname}.temporal"),
                    ld.get("temporal").and_then(|t| t.get("records_per_sample")),
                )?;
                // Where the document cannot show the record shape, a written
                // value stands in (`flatten` checks it against the shape); with
                // none written the count is unknown, and the parameter is
                // refused rather than guessed.
                let Some(rps) = shaped.or(own.or(inherited)) else {
                    return Err(perr(format!(
                        "providers_from_document: parameter '{key}': its record shape \
                         (esm-spec §8.5.1) comes from a param_to_var target this document does \
                         not show yet (it arrives through a coupling_import, or sits in a model \
                         behind an unmounted ref), so providers_from_document cannot tell \
                         whether it receives one record or two. Pass a document whose \
                         coupling_import entries are expanded and refs mounted, or declare the \
                         parameter's shape."
                    )));
                };
                if let Some(written) = own.or(inherited)
                    && written != rps
                {
                    return Err(perr(format!(
                        "providers_from_document: parameter '{key}': records_per_sample_invalid: \
                         the deprecated records_per_sample {written} disagrees with its record \
                         shape, which gives it {rps} record(s) per sample (two exactly when the \
                         record shape begins with an interval index set carrying \
                         \"records\": true; esm-spec §8.5.1)"
                    )));
                }
                // A run-time entry may restate the value, never change it.
                if let Some(&n) = opts.records_per_sample.get(key.as_str()) {
                    if n != 1 && n != 2 {
                        return Err(perr(format!(
                            "providers_from_document: parameter '{key}': the run-time \
                             records_per_sample option must be 1 or 2, got {n}"
                        )));
                    }
                    if n != rps {
                        return Err(perr(format!(
                            "providers_from_document: parameter '{key}': the run-time \
                             records_per_sample option asks for {n}, but the document gives \
                             {rps}; a different value would change the rank of the delivered \
                             array away from the declared shape, so give the parameter's record \
                             shape a record axis (an interval index set carrying \
                             \"records\": true) first in the document instead"
                        )));
                    }
                }
                if rps == 2 && !is_time_varying(ld) {
                    return Err(perr(format!(
                        "providers_from_document: parameter '{key}' asks for two records per \
                         sample, but data source '{lname}' declares no temporal start, so it \
                         is time-invariant and has no successor record"
                    )));
                }
                if rps == 2 && is_table {
                    return Err(perr(format!(
                        "providers_from_document: parameter '{key}' asks for two records per \
                         sample from data source '{lname}', which is read as one filtered or \
                         coded record table (a record_filter or a codes map); two records per \
                         sample is not supported on such a source"
                    )));
                }
                effective_rps.push(rps);
            }
            let table = if is_table {
                // A `require_finite` column no parameter reads is still needed
                // to compute the mask, so it is fetched alongside.
                let mut file_vars: Vec<String> = columns
                    .iter()
                    .map(|c| c.file_variable.clone())
                    .chain(require_finite.iter().cloned())
                    .collect();
                file_vars.sort();
                file_vars.dedup();
                let loader = make_loader(file_vars, None)?;
                let temporal = loader.temporal.clone();
                let provider = Provider::new(loader, cache.clone(), window)
                    .map_err(|e| perr(format!("providers_from_document: loader '{lname}': {e}")))?;
                Some(Arc::new(RecordTable {
                    loader_name: lname.clone(),
                    provider,
                    temporal,
                    columns: columns.clone(),
                    require_finite: require_finite.clone(),
                    state: Mutex::new(None),
                }))
            } else {
                None
            };

            for ((spec, b), &rps) in columns.iter().zip(consumers).zip(&effective_rps) {
                let key = &b.key;
                let loader = make_loader(vec![spec.file_variable.clone()], Some(rps))?;
                let mut builder = EsioProvider::builder(loader, cache.clone())
                    .var(spec.file_variable.clone(), key.clone())
                    .time_origin(time_origin);
                if let Some(w) = window {
                    builder = builder.window(w);
                }
                let select = parse_declared_select(doc, &format!("{key}.update.from"), b.from)?
                    .or_else(|| loader_select.clone());
                if let Some(axes) = select {
                    builder = builder.declared_select(axes);
                }
                if let Some(t) = &table {
                    builder = builder.record_column(t.clone(), spec.name.clone());
                }
                if let Some(uc) = &spec.unit_conversion {
                    builder = builder.unit_conversion(uc.clone());
                }
                if let Some(mp) = &extent_mp {
                    builder = builder.extent_metaparameter(mp.clone());
                }
                let provider = builder
                    .build()
                    .map_err(|e| perr(format!("provider {key}: {e}")))?;
                out.push((key.clone(), provider));
            }
        }
        // Deterministic key order (BTreeMap-like), matching the Python dict of
        // sorted construction order closely enough for stable logs.
        out.sort_by(|a, b| a.0.cmp(&b.0));
        Ok(out)
    }
}

#[cfg(not(target_arch = "wasm32"))]
pub use prepare_impl::{providers_from_document, providers_from_document_with};

impl EsioProvider {
    /// Honour the declared `select` on an already-materialized field set (a
    /// no-op when the reader took it and no axis was fixed).
    fn apply_select(
        &self,
        mut fields: HashMap<String, NativeField>,
    ) -> Result<HashMap<String, NativeField>, ProviderError> {
        match &self.applied {
            SelectApplication::None => Ok(fields),
            SelectApplication::Reader { drop_axes } if drop_axes.is_empty() => Ok(fields),
            SelectApplication::Reader { drop_axes } => {
                for (key, f) in fields.iter_mut() {
                    let axes: Vec<GateAxis> = (0..f.array.ndim())
                        .map(|i| {
                            if drop_axes.contains(&i) {
                                GateAxis::Fixed(0) // already sliced to length 1
                            } else {
                                GateAxis::All
                            }
                        })
                        .collect();
                    let arr = std::mem::replace(&mut f.array, ArrayD::zeros(IxDyn(&[0])));
                    f.array = apply_axes(key, arr, &axes)?;
                }
                Ok(fields)
            }
            SelectApplication::Engine(axes) => {
                let selects = axes.iter().any(|ax| !matches!(ax, GateAxis::All));
                for (key, f) in fields.iter_mut() {
                    let arr = std::mem::replace(&mut f.array, ArrayD::zeros(IxDyn(&[0])));
                    f.array = apply_axes(key, arr, axes)?;
                    if selects {
                        // The native coordinates describe the FULL axes and no
                        // longer index this array. Dropping them is the honest
                        // answer; carrying a stale axis would silently mis-place
                        // a downstream regrid. (A selected loader that must keep
                        // its coordinates would need them selected too, which is
                        // a separate feature, not a default.)
                        f.coords.clear();
                    }
                }
                Ok(fields)
            }
        }
    }
}

impl EsioProvider {
    /// Produce the values in the variable's DECLARED `units` (esm-spec §8.5).
    ///
    /// Applied at DELIVERY — after the loader's decode, `codes`, `record_filter`
    /// and `select` — so the filter still reasons about the raw column (a
    /// conversion cannot turn a dropped record into a kept one) and every
    /// delivered array is converted exactly once, whether it arrived through the
    /// record table, a reader-pushed select, or the engine's gated fetch.
    ///
    /// A variable with no declared conversion returns the fields untouched:
    /// this is a no-op for every document that does not declare one.
    fn convert_units(
        &self,
        mut fields: HashMap<String, NativeField>,
    ) -> Result<HashMap<String, NativeField>, ProviderError> {
        let Some(conversion) = &self.unit_conversion else {
            return Ok(fields);
        };
        for (key, f) in fields.iter_mut() {
            // A selected array can carry a non-standard layout, which has no
            // backing slice; standardising it first keeps the conversion one
            // pass over contiguous memory rather than an error path.
            let arr = std::mem::replace(&mut f.array, ArrayD::zeros(IxDyn(&[0])));
            let mut arr = if arr.is_standard_layout() {
                arr
            } else {
                arr.as_standard_layout().into_owned()
            };
            let values = arr
                .as_slice_mut()
                .expect("a standard-layout array is contiguous");
            apply_unit_conversion(values, conversion, key)
                .map_err(|e| err(format!("provider {key}: {e}")))?;
            f.array = arr;
        }
        Ok(fields)
    }

    /// The declared `select` and then the declared `unit_conversion` — the one
    /// funnel every delivery goes through.
    fn deliver(
        &self,
        fields: HashMap<String, NativeField>,
    ) -> Result<HashMap<String, NativeField>, ProviderError> {
        let fields = self.apply_select(fields)?;
        self.convert_units(fields)
    }
}

impl CadenceProvider for EsioProvider {
    fn materialize(&mut self) -> Result<HashMap<String, NativeField>, ProviderError> {
        // A record-table loader serves its columns from ONE shared decode,
        // here the record a time-less sample primes at.
        if self.table.is_some() {
            let (anchor, fields) = self.table_fields(self.prime)?;
            self.table_anchor = anchor;
            return self.deliver(fields);
        }
        let fields = self
            .inner
            .materialize_with_select(self.select.as_ref())
            .map_err(|e| err(format!("EarthSciIO materialize failed: {e}")))?;
        let fields = self.convert(fields)?;
        self.deliver(fields)
    }

    fn refresh(&mut self, t: f64) -> Result<Option<HashMap<String, NativeField>>, ProviderError> {
        // `t` is MODEL time; the data is read at the instant `origin + t`.
        let at = self.instant(t)?;
        if let Some((table, _)) = &self.table {
            // A const table never refreshes; a time-varying one serves the
            // column decoded at `t`'s record anchor, and nothing (None-skip)
            // when that anchor has not advanced since the last call.
            if !self.time_varying || table.anchor(at) == self.table_anchor {
                return Ok(None);
            }
            let (anchor, fields) = self.table_fields(at)?;
            self.table_anchor = anchor;
            return self.deliver(fields).map(Some);
        }
        let fields = self
            .inner
            .refresh_with_select(at, self.select.as_ref())
            .map_err(|e| err(format!("EarthSciIO refresh failed: {e}")))?;
        // None means the record did not advance — the executor's None-skip leaves
        // the previously-loaded field in place, so propagate it rather than
        // re-emitting an identical buffer.
        match fields {
            None => Ok(None),
            Some(f) => self.convert(f).and_then(|f| self.deliver(f)).map(Some),
        }
    }

    /// EarthSciIO's anchors (Unix seconds) moved onto the model clock.
    fn refresh_times(&self) -> Vec<f64> {
        self.inner
            .refresh_times()
            .into_iter()
            .map(|unix| unix - self.time_origin)
            .collect()
    }
}
