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
fn to_ess_field(
    name: &str,
    f: &EsioField,
    coords: &HashMap<String, earthsciio::format::Coord>,
) -> Result<NativeField, ProviderError> {
    let values: Vec<f64> = match &f.data {
        ArrayData::F64(v) => v.clone(),
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
            "loader variable '{name}': shape {:?} does not match {} values ({e})",
            f.shape,
            f.data.len()
        ))
    })?;

    // Carry only the coordinate axes this field actually spans, in dims order, so
    // an in-model regrid coupling sees the axes it indexes and nothing else.
    let mut out_coords: IndexMap<String, Vec<f64>> = IndexMap::new();
    for dim in &f.dims {
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
/// Lazily materialized on first use and then held: the providers are sampled
/// one after another by `prepare`, and the second one must not re-read.
struct RecordTable {
    loader_name: String,
    loader: DataSource,
    cache: Arc<Cache>,
    columns: Vec<ColumnSpec>,
    /// Loader variables whose non-finite cells drop the record.
    require_finite: Vec<String>,
    /// name → filtered column, once decoded.
    state: Mutex<Option<RecordColumns>>,
}

impl RecordTable {
    /// The filtered column for loader variable `name`.
    fn column(&self, name: &str) -> Result<ArrayD<f64>, ProviderError> {
        let cols = self.materialize()?;
        let v = cols.get(name).ok_or_else(|| {
            err(format!(
                "loader '{}' has no column '{name}' (declared: {:?})",
                self.loader_name,
                cols.keys().collect::<Vec<_>>()
            ))
        })?;
        Ok(ArrayD::from_shape_vec(IxDyn(&[v.len()]), v.clone())
            .expect("a 1-D shape always matches its own length"))
    }

    /// Decode + filter once; subsequent calls reuse the columns.
    fn materialize(&self) -> Result<RecordColumns, ProviderError> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| err("record table lock poisoned by an earlier decode failure"))?;
        if let Some(cols) = state.as_ref() {
            return Ok(cols.clone());
        }
        let cols = Arc::new(self.decode()?);
        *state = Some(cols.clone());
        Ok(cols)
    }

    fn decode(&self) -> Result<HashMap<String, Vec<f64>>, ProviderError> {
        let mut provider = Provider::new(self.loader.clone(), self.cache.clone(), None)
            .map_err(|e| err(format!("loader '{}': {e}", self.loader_name)))?;
        let fields = provider
            .materialize()
            .map_err(|e| err(format!("loader '{}' decode failed: {e}", self.loader_name)))?;

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
}

impl EsioProviderBuilder {
    /// Map an on-disk `file_variable` to the model variable it feeds.
    ///
    /// When no mapping is declared the on-disk names are used verbatim, which is
    /// the common case for a loader whose variables are already named as the
    /// model refers to them.
    pub fn var(mut self, file_variable: impl Into<String>, model_variable: impl Into<String>) -> Self {
        self.var_map.insert(file_variable.into(), model_variable.into());
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

    /// The loader's DECLARED per-axis `select` (esm-spec §8.9) for this
    /// variable — `W[0:52411]` as a document field rather than a caller's
    /// slice.
    ///
    /// Where it is applied is an optimization, not a semantic: `build` pushes
    /// it down to the reader when the reader can fetch pre-sliced AND no rows
    /// are filtered first, and otherwise applies it engine-side after decode.
    /// Both produce the same array. The selection is defined over the axis the
    /// loader DELIVERS, so for a record-table loader it follows the record
    /// filter — `[0:200]` means the first 200 surviving records, never the
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
        let (select, applied) = match self.declared {
            None => (self.select, SelectApplication::None),
            Some(axes) => {
                let pushable = if inner.supports_selection() && table.is_none() {
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
        }
    }

    /// True when the bound reader can honour a pushed-down `select`.
    ///
    /// A record-table column never can: its rows are chosen by the loader's
    /// declared filter AFTER the decode, so an index pushed to the reader would
    /// address raw rows rather than the delivered ones.
    pub fn supports_selection(&self) -> bool {
        self.table.is_none() && self.inner.supports_selection()
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
        let coords = self.inner.coords();
        let mut out = HashMap::with_capacity(fields.len());
        for (disk_name, f) in &fields {
            let model_name = self
                .var_map
                .get(disk_name)
                .cloned()
                .unwrap_or_else(|| disk_name.clone());
            out.insert(model_name, to_ess_field(disk_name, f, coords)?);
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

#[cfg(not(target_arch = "wasm32"))]
mod prepare_impl {
    use super::*;
    use crate::prepare::{AxisSel, PrepareError, PrepareProvider};
    use crate::pushdown_rewrite::ProviderGate;
    use earthsciio::SourceTemporal;
    use earthsciio::format::AxisSelect;
    use time::{Date, Duration, Month, PrimitiveDateTime, Time, UtcOffset};

    fn perr(msg: impl Into<String>) -> PrepareError {
        PrepareError(msg.into())
    }

    // ----------------------------------------------------------------------- //
    // The DECLARED cadence (esm-spec §8.9): `data_sources.<name>.temporal`.
    //
    // A source with no `temporal` is CONST — one file, read once, and (this is
    // the half that bites) IMMUTABLE to EarthSciIO's cache, which never
    // revalidates it. So dropping a declared cadence does not merely serve the
    // first file forever: it pins those bytes on disk permanently, with no
    // warning. The Python mirror is `_to_esio_temporal`, and the two must agree
    // down to the approximate-seconds constants below.
    // ----------------------------------------------------------------------- //

    /// Seconds in one ISO-8601 duration (`P1D`, `PT3H`, `P50Y`), with months and
    /// years measured by the mean Gregorian year — the same 365.2425 /
    /// 30.436875 day counts Python's `Duration.approximate_seconds` uses, so one
    /// document's cadence resolves identically in both bindings.
    ///
    /// The grammar is the one the Python regex accepts: `P[nY][nM][nW][nD]` then
    /// optional `T[nH][nM][n(.n)S]`, unsigned, designators in order. An all-zero
    /// duration is rejected rather than returned: a zero cadence would leave
    /// `refresh_times` empty and silently demote the source back to CONST, which
    /// is the very failure this conversion exists to prevent.
    fn parse_iso_duration_seconds(spec: &str) -> Result<f64, String> {
        let rest = spec
            .strip_prefix('P')
            .ok_or_else(|| format!("invalid ISO-8601 duration: {spec:?}"))?;
        let (date, time) = match rest.split_once('T') {
            Some((d, t)) => (d, t),
            None => (rest, ""),
        };

        // Consume `<digits><designator>` from the head of `s` when that
        // designator is the next one; otherwise leave `s` untouched and answer
        // zero, so an absent component is not an error but a stray one is (it
        // survives to the non-empty check below).
        fn take(s: &mut &str, designator: char, fractional: bool) -> Result<f64, String> {
            let n = s
                .find(|c: char| !(c.is_ascii_digit() || (fractional && c == '.')))
                .unwrap_or(s.len());
            if n == 0 || !s[n..].starts_with(designator) {
                return Ok(0.0);
            }
            let v = s[..n]
                .parse::<f64>()
                .map_err(|_| format!("invalid ISO-8601 duration component {:?}", &s[..=n]))?;
            *s = &s[n + designator.len_utf8()..];
            Ok(v)
        }

        let mut d = date;
        let years = take(&mut d, 'Y', false)?;
        let months = take(&mut d, 'M', false)?;
        let weeks = take(&mut d, 'W', false)?;
        let days = take(&mut d, 'D', false)? + 7.0 * weeks;
        let mut t = time;
        let hours = take(&mut t, 'H', false)?;
        let minutes = take(&mut t, 'M', false)?;
        let seconds = take(&mut t, 'S', true)?;
        if !d.is_empty() || !t.is_empty() {
            return Err(format!("invalid ISO-8601 duration: {spec:?}"));
        }

        let total = years * 365.2425 * 86400.0
            + months * 30.436875 * 86400.0
            + days * 86400.0
            + hours * 3600.0
            + minutes * 60.0
            + seconds;
        if total <= 0.0 {
            return Err(format!("duration {spec:?} has no nonzero components"));
        }
        Ok(total)
    }

    /// A trailing UTC offset — `+HH`, `-HH:MM`, `+HHMM`.
    fn parse_utc_offset(spec: &str) -> Result<UtcOffset, String> {
        let bad = || format!("invalid UTC offset: {spec:?}");
        let sign: i8 = match spec.as_bytes().first() {
            Some(b'+') => 1,
            Some(b'-') => -1,
            _ => return Err(bad()),
        };
        let digits: String = spec[1..].chars().filter(|c| *c != ':').collect();
        if !digits.chars().all(|c| c.is_ascii_digit()) || !matches!(digits.len(), 2 | 4) {
            return Err(bad());
        }
        let h: i8 = digits[..2].parse().map_err(|_| bad())?;
        let m: i8 = if digits.len() == 4 {
            digits[2..].parse().map_err(|_| bad())?
        } else {
            0
        };
        UtcOffset::from_hms(sign * h, sign * m, 0).map_err(|_| bad())
    }

    /// One ISO-8601 instant — `2016-01-01`, `2016-01-01T06:30:00Z`,
    /// `2016-01-01 06:30:00+02:00` — as UTC.
    ///
    /// A stamp carrying no offset is read as UTC, and one carrying an offset is
    /// converted to UTC rather than kept: the anchor is fed to the URL template,
    /// so a `+02:00` start left as-is would resolve `[year][month][day]` in the
    /// wrong zone. Python normalises to naive UTC for the same reason.
    fn parse_iso_instant(spec: &str) -> Result<OffsetDateTime, String> {
        let s = spec.trim();
        let bad = || format!("cannot parse {spec:?} as an ISO-8601 datetime");
        let (body, offset) = if let Some(b) = s.strip_suffix(['Z', 'z']) {
            (b, UtcOffset::UTC)
        } else {
            // The date's own hyphens are not offsets, so only the tail past
            // `YYYY-MM-DD` is searched for one.
            match s.get(10..).and_then(|tail| tail.rfind(['+', '-'])) {
                Some(i) => (&s[..10 + i], parse_utc_offset(&s[10 + i..])?),
                None => (s, UtcOffset::UTC),
            }
        };
        let (day, clock) = match body.split_once(['T', 't', ' ']) {
            Some((d, c)) => (d, c),
            None => (body, ""),
        };
        let mut dp = day.split('-');
        let (Some(y), Some(mo), Some(dd), None) = (dp.next(), dp.next(), dp.next(), dp.next())
        else {
            return Err(bad());
        };
        let date = Date::from_calendar_date(
            y.parse::<i32>().map_err(|_| bad())?,
            Month::try_from(mo.parse::<u8>().map_err(|_| bad())?).map_err(|_| bad())?,
            dd.parse::<u8>().map_err(|_| bad())?,
        )
        .map_err(|_| bad())?;
        let time = if clock.is_empty() {
            Time::MIDNIGHT
        } else {
            let mut cp = clock.split(':');
            let h: u8 = cp.next().unwrap_or("").parse().map_err(|_| bad())?;
            let m: u8 = cp.next().unwrap_or("0").parse().map_err(|_| bad())?;
            let secs: f64 = cp.next().unwrap_or("0").parse().map_err(|_| bad())?;
            if cp.next().is_some() || !(0.0..60.0).contains(&secs) {
                return Err(bad());
            }
            Time::from_hms_nano(h, m, secs as u8, (secs.fract() * 1e9).round() as u32)
                .map_err(|_| bad())?
        };
        Ok(PrimitiveDateTime::new(date, time)
            .assume_offset(offset)
            .to_offset(UtcOffset::UTC))
    }

    /// A source's declared `temporal` block as an [`earthsciio::SourceTemporal`]
    /// (`None` ⇒ CONST).
    ///
    /// `start` is the anchor every cadence step is aligned to, so a block
    /// without one cannot describe a schedule and stays CONST — matching
    /// Python. A block that DOES anchor but names no cadence is an error rather
    /// than a quiet CONST: it says the data varies in time and then declines to
    /// say how, and reading its first file forever would be a wrong answer, not
    /// a slow one.
    fn to_esio_temporal(
        ctx: &str,
        node: Option<&serde_json::Value>,
    ) -> Result<Option<SourceTemporal>, String> {
        let Some(t) = node.filter(|v| !v.is_null()) else {
            return Ok(None);
        };
        let obj = t
            .as_object()
            .ok_or_else(|| format!("{ctx}.temporal must be an object"))?;
        let field = |k: &str| {
            obj.get(k)
                .and_then(serde_json::Value::as_str)
                .filter(|s| !s.is_empty())
        };
        let Some(start) = field("start") else {
            return Ok(None); // no anchor ⇒ CONST
        };
        let dur = |k: &str| -> Result<Option<Duration>, String> {
            field(k)
                .map(|s| {
                    parse_iso_duration_seconds(s)
                        .map(Duration::seconds_f64)
                        .map_err(|e| format!("{ctx}.temporal.{k}: {e}"))
                })
                .transpose()
        };
        // Either one alone is enough: a file whose period is its cadence holds
        // one record, and a cadence with no stated file period is one file per
        // step. Both absent is the error.
        let declared_frequency = dur("frequency")?;
        let file_period = dur("file_period")?.or(declared_frequency);
        let frequency = declared_frequency.or(file_period);
        let (Some(frequency), Some(file_period)) = (frequency, file_period) else {
            return Err(format!(
                "{ctx}.temporal anchors at {start:?} but declares neither \
                 frequency nor file_period; EarthSciIO needs a cadence to \
                 refresh on"
            ));
        };
        let mut out = SourceTemporal::new(
            parse_iso_instant(start).map_err(|e| format!("{ctx}.temporal.start: {e}"))?,
            frequency,
            file_period,
        );
        if let Some(end) = field("end") {
            out = out.end(parse_iso_instant(end).map_err(|e| format!("{ctx}.temporal.end: {e}"))?);
        }
        if let Some(dim) = field("time_variable") {
            out = out.time_dim(dim);
        }
        Ok(Some(out))
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
    fn single_field(
        fields: HashMap<String, NativeField>,
    ) -> Result<ArrayD<f64>, PrepareError> {
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
            let fields = self.convert_units(fields).map_err(|e| perr(e.to_string()))?;
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

    /// `{data_sources key -> [(flattened parameter name, local name, `update.from`)]}`.
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
    fn document_bindings(
        doc: &serde_json::Value,
    ) -> HashMap<String, Vec<(String, String, &serde_json::Value)>> {
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
            out: &mut HashMap<String, Vec<(String, String, &'a serde_json::Value)>>,
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
                    out.entry(source.to_string()).or_default().push((
                        key,
                        vname.to_string(),
                        binding,
                    ));
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

        let mut out: HashMap<String, Vec<(String, String, &serde_json::Value)>> = HashMap::new();
        let models = doc.get("models");
        for mname in sorted_keys(models) {
            visit(
                &models.expect("sorted_keys is empty without an object")[mname],
                mname,
                &mut out,
            );
        }
        for entries in out.values_mut() {
            entries.sort_by(|a, b| a.0.cmp(&b.0));
        }
        out
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
        let dls = doc
            .get("data_sources")
            .and_then(|v| v.as_object())
            .ok_or_else(|| perr("providers_from_document: the document declares no data_sources"))?;
        let bindings = document_bindings(doc);
        let mut out = Vec::new();
        for (lname, ld) in dls {
            if let Some(want) = loaders
                && !want.contains(&lname.as_str())
            {
                continue;
            }
            let fmt = ld
                .get("metadata")
                .and_then(|m| m.get("esio_format"))
                .and_then(|v| v.as_str());
            let Some(fmt) = fmt else {
                if loaders.is_none() {
                    continue;
                }
                return Err(perr(format!(
                    "providers_from_document: data_sources.{lname} declares no \
                     metadata.esio_format — cannot construct a provider for it"
                )));
            };
            let url = url_overrides
                .get(lname)
                .map(String::as_str)
                .or_else(|| {
                    ld.get("source")
                        .and_then(|s| s.get("url_template"))
                        .and_then(|v| v.as_str())
                })
                .ok_or_else(|| {
                    perr(format!(
                        "providers_from_document: data_sources.{lname} has no \
                         source.url_template (and no url_overrides entry)"
                    ))
                })?;
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
            let reader_options = ld
                .get("reader_options")
                .and_then(serde_json::Value::as_object)
                .cloned()
                .unwrap_or_default();
            let loader_select = parse_declared_select(doc, &format!("data_sources.{lname}"), ld)?;
            // The source's DECLARED cadence, converted once and carried by
            // every loader built below. Without it EarthSciIO saw CONST no
            // matter what the document said (see `to_esio_temporal`).
            let temporal = to_esio_temporal(&format!("data_sources.{lname}"), ld.get("temporal"))
                .map_err(perr)?;
            let make_loader = |vars: Vec<String>| {
                let loader = DataSource::new(lname.clone(), fmt, url)
                    .variables(vars)
                    .reader_options(reader_options.clone());
                match &temporal {
                    Some(t) => loader.temporal(t.clone()),
                    None => loader,
                }
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
            for (key, vname, binding) in consumers {
                let fv = binding
                    .get("file_variable")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or(vname);
                columns.push(ColumnSpec {
                    name: key.clone(),
                    file_variable: fv.to_string(),
                    codes: parse_codes(&format!("{key}.update.from"), binding)?,
                    unit_conversion: parse_unit_conversion(binding.get("unit_conversion"), key)
                        .map_err(|e| perr(e.to_string()))?,
                });
            }
            // A record filter or a code map makes the loader a TABLE: one
            // decode, one keep mask, columns that stay aligned.
            let table = if !require_finite.is_empty() || columns.iter().any(|c| c.codes.is_some()) {
                // A `require_finite` column no parameter reads is still needed
                // to compute the mask, so it is fetched alongside.
                let mut file_vars: Vec<String> = columns
                    .iter()
                    .map(|c| c.file_variable.clone())
                    .chain(require_finite.iter().cloned())
                    .collect();
                file_vars.sort();
                file_vars.dedup();
                Some(Arc::new(RecordTable {
                    loader_name: lname.clone(),
                    loader: make_loader(file_vars),
                    cache: cache.clone(),
                    columns: columns.clone(),
                    require_finite: require_finite.clone(),
                    state: Mutex::new(None),
                }))
            } else {
                None
            };

            for (spec, (key, _vname, binding)) in columns.iter().zip(consumers) {
                let loader = make_loader(vec![spec.file_variable.clone()]);
                let mut builder = EsioProvider::builder(loader, cache.clone())
                    .var(spec.file_variable.clone(), key.clone());
                let select = parse_declared_select(doc, &format!("{key}.update.from"), binding)?
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

    #[cfg(test)]
    mod temporal_tests {
        use super::*;

        fn secs(spec: &str) -> f64 {
            parse_iso_duration_seconds(spec).unwrap_or_else(|e| panic!("{spec}: {e}"))
        }

        #[test]
        fn iso_durations_match_the_python_approximate_seconds() {
            assert_eq!(secs("PT1H"), 3600.0);
            assert_eq!(secs("P1D"), 86400.0);
            assert_eq!(secs("P1DT12H30M"), 86400.0 + 45000.0);
            assert_eq!(secs("PT0.5S"), 0.5);
            assert_eq!(secs("P2W"), 14.0 * 86400.0);
            // The mean-Gregorian constants, which are the whole reason this is
            // hand-written rather than a whole-days conversion.
            assert_eq!(secs("P1M"), 30.436875 * 86400.0);
            assert_eq!(secs("P50Y"), 50.0 * 365.2425 * 86400.0);
            // `M` before `T` is months, after it is minutes.
            assert_eq!(secs("P1M"), secs("P1M"));
            assert_eq!(secs("PT1M"), 60.0);
        }

        #[test]
        fn a_malformed_duration_is_named_not_guessed_at() {
            for spec in ["1 hour", "PT", "P", "P1X", "PT1H30", "hourly", "P1.5D"] {
                assert!(
                    parse_iso_duration_seconds(spec).is_err(),
                    "{spec:?} must not parse"
                );
            }
        }

        #[test]
        fn instants_parse_with_and_without_an_offset() {
            let utc = parse_iso_instant("2016-01-01T00:00:00Z").expect("Zulu");
            assert_eq!(utc.unix_timestamp(), 1_451_606_400);
            // A bare date is midnight; a bare stamp is UTC, not local.
            assert_eq!(parse_iso_instant("2016-01-01").expect("date"), utc);
            assert_eq!(
                parse_iso_instant("2016-01-01T00:00:00").expect("naive"),
                utc
            );
            // An offset is honoured AND normalised, so the anchor that reaches
            // the URL template is the same instant in the same zone.
            let plus2 = parse_iso_instant("2016-01-01T02:00:00+02:00").expect("offset");
            assert_eq!(plus2, utc);
            assert_eq!(plus2.offset(), UtcOffset::UTC);
            assert!(parse_iso_instant("2016-13-01").is_err(), "month 13");
            assert!(parse_iso_instant("yesterday").is_err());
        }

        #[test]
        fn a_source_with_no_anchor_stays_const() {
            assert!(to_esio_temporal("s", None).expect("absent").is_none());
            assert!(
                to_esio_temporal("s", Some(&serde_json::json!({"frequency": "PT1H"})))
                    .expect("no start")
                    .is_none(),
                "a cadence with nothing to align it to cannot schedule anything"
            );
        }

        #[test]
        fn either_period_alone_fills_in_for_the_other() {
            let hourly_files = to_esio_temporal(
                "s",
                Some(&serde_json::json!({"start": "2016-01-01", "file_period": "PT1H"})),
            )
            .expect("file_period alone")
            .expect("DISCRETE");
            assert_eq!(hourly_files.frequency, Duration::hours(1));
            assert_eq!(hourly_files.file_period, Duration::hours(1));

            let full = to_esio_temporal(
                "s",
                Some(&serde_json::json!({
                    "start": "2016-01-01T00:00:00Z",
                    "end": "2016-01-02T00:00:00Z",
                    "frequency": "PT1H",
                    "file_period": "P1D",
                    "time_variable": "Time",
                })),
            )
            .expect("full block")
            .expect("DISCRETE");
            assert_eq!(full.frequency, Duration::hours(1));
            assert_eq!(full.file_period, Duration::days(1));
            assert_eq!(full.end.map(|e| e.unix_timestamp()), Some(1_451_692_800));
            assert_eq!(full.time_dim, "Time");
        }

        #[test]
        fn an_anchor_with_no_cadence_is_an_error_not_a_quiet_const() {
            let e = to_esio_temporal("s", Some(&serde_json::json!({"start": "2016-01-01"})))
                .expect_err("a time-varying source must say how it varies");
            assert!(e.contains("neither frequency nor file_period"), "{e}");
        }
    }
}

#[cfg(not(target_arch = "wasm32"))]
pub use prepare_impl::providers_from_document;

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
        // A record-table loader serves its columns from ONE shared decode.
        if let Some((table, column)) = &self.table {
            let model_name = self
                .var_map
                .values()
                .next()
                .cloned()
                .unwrap_or_else(|| column.clone());
            let field = NativeField {
                array: table.column(column)?,
                coords: IndexMap::new(),
            };
            return self.deliver(HashMap::from([(model_name, field)]));
        }
        let fields = self
            .inner
            .materialize_with_select(self.select.as_ref())
            .map_err(|e| err(format!("EarthSciIO materialize failed: {e}")))?;
        let fields = self.convert(fields)?;
        self.deliver(fields)
    }

    fn refresh(&mut self, t: f64) -> Result<Option<HashMap<String, NativeField>>, ProviderError> {
        // `refresh_times` below emits UNIX timestamps, so the anchors ESS hands
        // back arrive on the same scale; convert straight back.
        if !t.is_finite() {
            return Err(err(format!("refresh anchor {t} is not a finite time")));
        }
        let anchor = OffsetDateTime::from_unix_timestamp(t as i64)
            .map_err(|e| err(format!("refresh anchor {t} is not a valid instant: {e}")))?;
        let fields = self
            .inner
            .refresh_with_select(anchor, self.select.as_ref())
            .map_err(|e| err(format!("EarthSciIO refresh failed: {e}")))?;
        // None means the record did not advance — the executor's None-skip leaves
        // the previously-loaded field in place, so propagate it rather than
        // re-emitting an identical buffer.
        match fields {
            None => Ok(None),
            Some(f) => self.convert(f).and_then(|f| self.deliver(f)).map(Some),
        }
    }

    fn refresh_times(&self) -> Vec<f64> {
        self.inner.refresh_times()
    }
}
