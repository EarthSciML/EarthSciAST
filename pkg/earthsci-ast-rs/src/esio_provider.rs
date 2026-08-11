//! Adapter: serve an ESS data loader through a real EarthSciIO [`Provider`].
//!
//! [`CadenceProvider`]'s own documentation specifies this seam — *"ESS does not
//! link the EarthSciIO crate; a thin adapter at the integration boundary
//! implements this trait by delegating to the real `Provider` (and converting an
//! f64 anchor to the [`OffsetDateTime`] the upstream `refresh` wants)"*. This
//! module is that adapter, behind the optional `esio` feature so the default
//! build still does not link EarthSciIO.
//!
//! It mirrors the Python binding's `earthsci_ast.data_loaders.esio_provider`:
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
use std::sync::Arc;

use earthsciio::format::{ArrayData, NativeField as EsioField, Selection};
use earthsciio::{Cache, DataLoader, Provider, Window};
use indexmap::IndexMap;
use ndarray::{ArrayD, IxDyn};
use time::OffsetDateTime;

use crate::provider::{CadenceProvider, NativeField, ProviderError};

fn err(msg: impl Into<String>) -> ProviderError {
    crate::error::MessageError(msg.into())
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

/// Builder for [`EsioProvider`].
pub struct EsioProviderBuilder {
    loader: DataLoader,
    cache: Arc<Cache>,
    window: Option<Window>,
    var_map: IndexMap<String, String>,
    select: Option<Selection>,
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

    /// Construct the provider, resolving the reader now so an unknown format
    /// fails here rather than mid-solve.
    pub fn build(self) -> Result<EsioProvider, ProviderError> {
        let inner = Provider::new(self.loader, self.cache, self.window)
            .map_err(|e| err(format!("EarthSciIO provider construction failed: {e}")))?;
        Ok(EsioProvider {
            inner,
            var_map: self.var_map,
            select: self.select,
        })
    }
}

/// An ESS [`CadenceProvider`] backed by a real EarthSciIO [`Provider`].
pub struct EsioProvider {
    inner: Provider,
    var_map: IndexMap<String, String>,
    select: Option<Selection>,
}

impl EsioProvider {
    /// Start building a provider for `loader`, fetching through `cache`.
    pub fn builder(loader: DataLoader, cache: Arc<Cache>) -> EsioProviderBuilder {
        EsioProviderBuilder {
            loader,
            cache,
            window: None,
            var_map: IndexMap::new(),
            select: None,
        }
    }

    /// True when the bound reader can honour a pushed-down `select`.
    pub fn supports_selection(&self) -> bool {
        self.inner.supports_selection()
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
    use earthsciio::format::AxisSelect;

    fn perr(msg: impl Into<String>) -> PrepareError {
        PrepareError(msg.into())
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
            single_field(fields)
        }

        fn is_const(&self) -> bool {
            CadenceProvider::refresh_times(self).is_empty()
        }
    }

    /// Document-declared provider construction — the Rust mirror of the Python
    /// `earthsci_ast.data_loaders.esio_provider.providers_from_document` (and
    /// the Julia EarthSciIO extension's namesake). The document's
    /// `data_loaders` say WHAT to read (`source.url_template`, `variables`)
    /// and `metadata.esio_format` says HOW (the EarthSciIO format-registry
    /// name); the runner no longer hand-constructs providers — it asks the
    /// document.
    ///
    /// One provider PER VARIABLE (keyed `"<Loader>.<var>"`), matching (a)
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
            .get("data_loaders")
            .and_then(|v| v.as_object())
            .ok_or_else(|| perr("providers_from_document: the document declares no data_loaders"))?;
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
                    "providers_from_document: data_loaders.{lname} declares no \
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
                        "providers_from_document: data_loaders.{lname} has no \
                         source.url_template (and no url_overrides entry)"
                    ))
                })?;
            let Some(variables) = ld.get("variables").and_then(|v| v.as_object()) else {
                continue;
            };
            let cache = Arc::new(
                Cache::builder()
                    .data_dir(cache_root.join(lname))
                    .build()
                    .map_err(|e| perr(format!("cache for {lname}: {e}")))?,
            );
            for (vname, vd) in variables {
                let fv = vd
                    .get("file_variable")
                    .and_then(|v| v.as_str())
                    .unwrap_or(vname);
                let key = format!("{lname}.{vname}");
                let loader = DataLoader::new(lname.clone(), fmt, url).variables([fv.to_string()]);
                let provider = EsioProvider::builder(loader, cache.clone())
                    .var(fv, key.clone())
                    .build()
                    .map_err(|e| perr(format!("provider {key}: {e}")))?;
                out.push((key, provider));
            }
        }
        // Deterministic key order (BTreeMap-like), matching the Python dict of
        // sorted construction order closely enough for stable logs.
        out.sort_by(|a, b| a.0.cmp(&b.0));
        Ok(out)
    }
}

#[cfg(not(target_arch = "wasm32"))]
pub use prepare_impl::providers_from_document;

impl CadenceProvider for EsioProvider {
    fn materialize(&mut self) -> Result<HashMap<String, NativeField>, ProviderError> {
        let fields = self
            .inner
            .materialize_with_select(self.select.as_ref())
            .map_err(|e| err(format!("EarthSciIO materialize failed: {e}")))?;
        self.convert(fields)
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
            Some(f) => self.convert(f).map(Some),
        }
    }

    fn refresh_times(&self) -> Vec<f64> {
        self.inner.refresh_times()
    }
}
