//! Data-provider consumption + cadence wiring — the refresh executor (bead
//! ess-14f.9 / RS-R1, plan `esio-consumer-rust-plan`; parent ess-14f).
//!
//! # What this module is
//!
//! A discrete-cadence Earth-system model forces its RHS with external fields a
//! data loader reads at a cadence — 6-hourly meteorology, boundary-condition
//! slices, time-varying emissions. PR-1 (ess-14f.7) gave the array RHS a *live
//! forcing buffer* ([`crate::simulate_array::ArrayCompiled::forcing_handle`]) the
//! integrator reads each step; PR-3 (ess-14f.8) let the array runtime consume a
//! coupled, flattened model. This module is the **refresh executor** between a
//! data provider and that buffer: it GETs CONST forcings once, REFRESHes DISCRETE
//! forcings at their cadence anchors, and writes each native field straight into
//! the forcing buffer. There is no native→sim regrid here — regridding is an
//! ordinary in-model coupling expression the RHS evaluates (the obsolete regrid
//! seam was removed in v0.8.0).
//!
//! It is the ESS "**refresh callable + refresh_times**" surface a driver consumes
//! — explicitly *not* a solver. The segmented integration loop that calls it
//! lives in a user-owned driver / example harness (R-3, ess-14f.11), preserving
//! `library-exposes-rhs-not-solver`: this module exposes data + pure functions
//! ([`RefreshExecutor::refresh_times`], [`RefreshExecutor::refresh_at`]), never a
//! `solve`/`simulate`.
//!
//! # The provider contract, and why it is a trait
//!
//! The bytes are fetched by the EarthSciIO Rust `Provider` (bead `esio-9nb.7`,
//! data-providers plan §4.6): `materialize` (CONST, load once), `refresh(t)`
//! (DISCRETE, re-read at a cadence anchor; `None` if the record has not advanced),
//! `refresh_times` (the cadence anchors). EarthSciIO lives in a **separate
//! repo/crate that ESS does not link**; ESS instead depends on the
//! [`CadenceProvider`] **trait** here (dependency inversion), and a thin adapter
//! at the integration boundary wraps the real `Provider` to implement it. The
//! cross-rig mayor-gate on `esio-9nb.7` froze that signature so this trait
//! matches it.
//!
//! Time is the **f64 solver clock** — the cadence anchors `refresh_times` yields,
//! the same axis the diffsol driver integrates on. The upstream `Provider` takes
//! a wall-clock `DateTime<Utc>` in `refresh`; converting an f64 anchor to that
//! `DateTime` (via the loader's temporal epoch) is the adapter's concern, which
//! keeps ESS `chrono`-free and the driver f64-native.
//!
//! # CONST vs DISCRETE is declared, not guessed
//!
//! Which loader-fed variable is CONST and which is DISCRETE is **declared** by the
//! model: this module consumes the cadence pass
//! ([`crate::cadence::model_with_loaders`] + [`crate::cadence::seed_leaf`]). A
//! `data_ingest`-refresh variable whose source loader carries a `temporal` block
//! is DISCRETE (refreshes at the cadence); without one it is CONST (materialized
//! once, folds for the run). See [`classify_loader_bindings`].
//!
//! # No new engine primitive
//!
//! This is consumer/glue code: a provider *trait* and an executor that drives it
//! into the existing PR-1 buffer. No arrayop, no scalarizer arm, no
//! `VariableType` variant, no lift of the event/spatial rejections —
//! `declarative-bc-no-new-primitives` holds. Regridding stays declarative in the
//! model (an in-model coupling contraction the RHS evaluates), not a seam here.

use crate::cadence::{self, Cadence};
use indexmap::IndexMap;
use ndarray::ArrayD;
use serde_json::Value;
use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

/// A refresh-executor / classification failure: a malformed loader-fed variable,
/// a missing provider, a cadence-classification disagreement, or a buffer write error.
/// Mirrors the lightweight string-wrapped style of [`crate::cadence::CadenceError`].
#[derive(Debug, Clone, thiserror::Error)]
#[error("{0}")]
pub struct ProviderError(pub String);

fn err(msg: impl Into<String>) -> ProviderError {
    ProviderError(msg.into())
}

/// The PR-1 forcing-buffer handle ([`ArrayCompiled::forcing_handle`]): a shared,
/// interior-mutable map from variable name to its current native field. The
/// refresh executor *writes* it between cadence segments; the captured RHS /
/// Jacobian closures *read* it live on the next step. `Rc<RefCell<…>>` for the
/// same reason the rest of the array RHS scratch is — diffsol's RHS is `Fn`, not
/// `FnMut`.
///
/// [`ArrayCompiled::forcing_handle`]: crate::simulate_array::ArrayCompiled::forcing_handle
pub type ForcingBuffer = Rc<RefCell<HashMap<String, ArrayD<f64>>>>;

/// A raw native-grid field handed back by a provider: the array plus its native
/// coordinate axes (axis name → coordinate values, in native-grid order).
///
/// Regridding/reprojection onto the model's simulation grid is the owning model's
/// job (an in-model coupling expression the RHS evaluates), **not** the
/// provider's — so `materialize`/`refresh` return a `NativeField`, and the
/// executor writes its array straight into the forcing buffer. `NativeField =
/// {array, coords}` matches the Python/Julia/Rust contract in data-providers plan §4.6.
#[derive(Debug, Clone)]
pub struct NativeField {
    /// The field values on the provider's native grid.
    pub array: ArrayD<f64>,
    /// The native-grid coordinate axes (axis name → coordinate values). Carried
    /// for a model whose in-model regrid coupling needs them; the executor writes
    /// only `array`.
    pub coords: IndexMap<String, Vec<f64>>,
}

impl NativeField {
    /// A field with no coordinate metadata — convenience for an already-on-grid
    /// loader or a test whose forcing is consumed directly.
    pub fn new(array: ArrayD<f64>) -> Self {
        Self {
            array,
            coords: IndexMap::new(),
        }
    }
}

/// The cadence-driven data-provider contract the refresh executor consumes.
///
/// This is the ESS-side **consumer interface** mirroring the EarthSciIO Rust
/// `Provider` (bead `esio-9nb.7`, data-providers plan §4.6). ESS does not link the
/// EarthSciIO crate; a thin adapter at the integration boundary implements this
/// trait by delegating to the real `Provider` (and converting an f64 anchor to the
/// `DateTime<Utc>` the upstream `refresh` wants). Tests implement it with an
/// in-memory fake — no I/O — exactly the "testable with a hand-built buffer"
/// contract the plan specifies.
///
/// One `CadenceProvider` corresponds to one data loader and may feed several
/// model variables; `materialize`/`refresh` are keyed by the fed variable name.
pub trait CadenceProvider {
    /// CONST load: read the whole field(s) once at setup. Keyed by the variable
    /// name(s) the loader feeds. Called once by [`RefreshExecutor::materialize_const`]
    /// for a CONST loader; a DISCRETE loader's CONST baseline (if any) is out of
    /// scope here — DISCRETE loaders refresh at anchors.
    fn materialize(&mut self) -> Result<HashMap<String, NativeField>, ProviderError>;

    /// DISCRETE refresh at cadence anchor `t` (solver seconds): re-read the slice.
    /// `Some(fields)` when the record advanced (a buffer write follows);
    /// `None` when it has not — the executor then **skips the buffer write**
    /// (None-skip), leaving the previously-loaded field in place. A provider also
    /// returns `None` for a `t` that is not one of its own anchors, so the executor
    /// may call every DISCRETE provider at every union anchor and let each decide.
    fn refresh(&mut self, t: f64) -> Result<Option<HashMap<String, NativeField>>, ProviderError>;

    /// The cadence anchors (solver seconds) at which `refresh` should fire. Empty
    /// for a CONST loader (no `temporal` block) — it contributes no driver tstop.
    /// The union of these across DISCRETE providers is the driver's tstop list.
    fn refresh_times(&self) -> Vec<f64>;
}

// There is NO native→sim-grid regrid seam: the freshly sampled native forcing is
// written straight into the buffer, and any native→sim regrid is an ordinary
// in-model coupling expression the RHS evaluates downstream (the obsolete
// `Regrid`/`IdentityRegrid` seam was removed in v0.8.0 — regridding is declarative
// in the model, not re-implemented imperatively in Rust).

/// One loader's binding: its declared cadence and the model variables it feeds.
/// A loader's `temporal` block decides a single cadence for *all* its outputs, so
/// every variable in `variables` shares `cadence`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LoaderBinding {
    /// The data-loader name (the `refresh.source` of the variables it feeds).
    pub loader: String,
    /// `Const` (no `temporal` — materialize once) or `Discrete` (refresh at the
    /// cadence). A loader never feeds a `Continuous` forcing.
    pub cadence: Cadence,
    /// The model variables this loader feeds, in declaration order.
    pub variables: Vec<String>,
}

/// Classify every loader-fed variable in `model` as CONST or DISCRETE, grouped by
/// source loader, using the cadence pass's **declarative** rule.
///
/// Walks `model.variables` for `discrete` variables carrying a `data_ingest`
/// refresh, resolves each one's source loader, and classifies it with
/// [`crate::cadence::seed_leaf`] over [`crate::cadence::model_with_loaders`]: a
/// variable whose source loader declares a `temporal` block seeds `Discrete`
/// (refreshes at the cadence); without one it seeds `Const` (folds once at bind).
/// `doc` supplies the top-level `data_loaders` the rule resolves against.
///
/// Returns the bindings in loader-first-seen order. A loader whose variables
/// disagree on cadence is an error (its `temporal` block must decide one cadence
/// for all its outputs).
pub fn classify_loader_bindings(
    model: &Value,
    doc: &Value,
) -> Result<Vec<LoaderBinding>, ProviderError> {
    let model = cadence::model_with_loaders(model, doc);
    let Some(variables) = model.get("variables").and_then(|v| v.as_object()) else {
        return Ok(Vec::new());
    };

    let mut by_loader: IndexMap<String, LoaderBinding> = IndexMap::new();
    for (var_name, var) in variables {
        // Only `discrete` variables carry a `refresh`; only `data_ingest` names a
        // data loader (a `schedule`/`remesh` refresh is not provider-fed).
        if var.get("type").and_then(|v| v.as_str()) != Some("discrete") {
            continue;
        }
        let Some(refresh) = var.get("refresh") else {
            continue;
        };
        if refresh.get("kind").and_then(|v| v.as_str()) != Some("data_ingest") {
            continue;
        }
        let source = refresh
            .get("source")
            .and_then(|v| v.as_str())
            .ok_or_else(|| {
                err(format!(
                    "variable {var_name:?}: data_ingest refresh is missing a string `source`"
                ))
            })?;

        // Declarative CONST/DISCRETE from the cadence pass (the temporal-block
        // rule lives in `loader_without_temporal`, applied by `seed_leaf`).
        let cad = cadence::seed_leaf(&Value::String(var_name.clone()), &model)
            .map_err(|e| err(format!("classifying loader-fed variable {var_name:?}: {e}")))?;
        // A loader-fed `discrete` variable seeds only Const or Discrete; Continuous
        // would mean the cadence rule changed under us — fail loudly rather than
        // silently treat a hot-path forcing as a cadence forcing.
        if cad == Cadence::Continuous {
            return Err(err(format!(
                "loader-fed variable {var_name:?} classified CONTINUOUS — a \
                 data_ingest forcing must be const or discrete"
            )));
        }

        match by_loader.get_mut(source) {
            Some(binding) => {
                if binding.cadence != cad {
                    return Err(err(format!(
                        "loader {source:?} feeds variables of disagreeing cadence \
                         ({} vs {}) — its `temporal` block must decide one cadence \
                         for all its outputs",
                        binding.cadence.as_str(),
                        cad.as_str()
                    )));
                }
                binding.variables.push(var_name.clone());
            }
            None => {
                by_loader.insert(
                    source.to_string(),
                    LoaderBinding {
                        loader: source.to_string(),
                        cadence: cad,
                        variables: vec![var_name.clone()],
                    },
                );
            }
        }
    }

    Ok(by_loader.into_values().collect())
}

/// One classified loader paired with its provider.
struct LoaderProvider {
    binding: LoaderBinding,
    provider: Box<dyn CadenceProvider>,
}

/// The refresh executor: the ESS "**refresh callable + refresh_times**" surface a
/// discrete-cadence driver consumes (NOT a solver).
///
/// Pairs each loader's [`CadenceProvider`] with its declared cadence (from
/// [`classify_loader_bindings`]), materializes CONST forcings once, and refreshes
/// DISCRETE forcings at their cadence anchors — each time writing the native field
/// straight into the PR-1 [`ForcingBuffer`] (any native→sim regrid is an in-model
/// coupling expression the RHS evaluates, not a seam here).
///
/// Lifecycle a driver follows (R-3):
/// 1. [`RefreshExecutor::new`] — classify + pair providers.
/// 2. [`RefreshExecutor::materialize_const`] — once, at setup, before integrating.
/// 3. `tstops = ` [`RefreshExecutor::refresh_times`] `∩ (t0, t_end)` — driver
///    segment boundaries.
/// 4. At each boundary `t`: [`RefreshExecutor::refresh_at`]`(t, &buffer)`, then
///    continue the segmented solve.
pub struct RefreshExecutor {
    loaders: Vec<LoaderProvider>,
}

impl RefreshExecutor {
    /// Build the executor: classify each loader-fed variable in `model` (with
    /// `doc`'s `data_loaders`) CONST/DISCRETE, and pair each classified loader with
    /// its provider from `providers` (keyed by loader name). Every classified
    /// loader must have a provider; an unclassified extra provider is ignored.
    pub fn new(
        model: &Value,
        doc: &Value,
        mut providers: HashMap<String, Box<dyn CadenceProvider>>,
    ) -> Result<Self, ProviderError> {
        let bindings = classify_loader_bindings(model, doc)?;
        let mut loaders = Vec::with_capacity(bindings.len());
        for binding in bindings {
            let provider = providers.remove(&binding.loader).ok_or_else(|| {
                err(format!(
                    "no provider supplied for loader {:?} (feeds {:?})",
                    binding.loader, binding.variables
                ))
            })?;
            loaders.push(LoaderProvider { binding, provider });
        }
        Ok(Self { loaders })
    }

    /// The classified loader bindings, for a driver that wants to inspect what is
    /// wired (which variables are CONST vs DISCRETE, which loaders are present).
    pub fn bindings(&self) -> impl Iterator<Item = &LoaderBinding> {
        self.loaders.iter().map(|lp| &lp.binding)
    }

    /// CONST forcings: `materialize()` each CONST loader **once** and write the
    /// native field into `forcing`. Call at setup, before the segmented integration
    /// loop; DISCRETE loaders are untouched here. Returns the variable names written
    /// (sorted), for assertion/logging. Idempotent in effect — calling twice just
    /// re-reads and overwrites with identical values — but a CONST field is meant
    /// to be loaded once.
    pub fn materialize_const(
        &mut self,
        forcing: &ForcingBuffer,
    ) -> Result<Vec<String>, ProviderError> {
        let RefreshExecutor { loaders } = self;
        let mut written = Vec::new();
        for lp in loaders.iter_mut() {
            if lp.binding.cadence != Cadence::Const {
                continue;
            }
            let fields = lp.provider.materialize()?;
            write_fields(&fields, forcing, &mut written)?;
        }
        written.sort();
        written.dedup();
        Ok(written)
    }

    /// The sorted, de-duplicated union of every DISCRETE provider's
    /// `refresh_times` — the driver's tstop list. CONST loaders contribute none.
    /// The caller intersects with the integration window `(t0, t_end)`.
    pub fn refresh_times(&self) -> Vec<f64> {
        let mut times: Vec<f64> = self
            .loaders
            .iter()
            .filter(|lp| lp.binding.cadence == Cadence::Discrete)
            .flat_map(|lp| lp.provider.refresh_times())
            .collect();
        times.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        times.dedup();
        times
    }

    /// Refresh at cadence anchor `t`: for each DISCRETE provider, call
    /// `refresh(t)`; on `Some(fields)`, write each native field into `forcing`;
    /// on `None` (record unchanged, or `t` not this provider's anchor),
    /// **skip the write** — the previously-loaded field stays in the buffer
    /// (None-skip). CONST loaders never refresh. Returns the variable names
    /// (re)written at this anchor (sorted).
    ///
    /// Mutate the buffer only *between* segments (the driver calls this at a
    /// boundary, never inside a solver step), keeping the RHS pure within a
    /// segment.
    pub fn refresh_at(
        &mut self,
        t: f64,
        forcing: &ForcingBuffer,
    ) -> Result<Vec<String>, ProviderError> {
        let RefreshExecutor { loaders } = self;
        let mut written = Vec::new();
        for lp in loaders.iter_mut() {
            if lp.binding.cadence != Cadence::Discrete {
                continue;
            }
            // `None` (record unchanged, or `t` not this provider's anchor) → skip
            // the buffer write (None-skip); the previously-loaded field stays put.
            if let Some(fields) = lp.provider.refresh(t)? {
                write_fields(&fields, forcing, &mut written)?;
            }
        }
        written.sort();
        written.dedup();
        Ok(written)
    }
}

/// Write each freshly sampled native field straight into the forcing buffer,
/// recording the variable names written. There is no regrid here — any native→sim
/// regrid is an in-model coupling expression the RHS evaluates. The buffer's
/// `borrow_mut` is taken per-insert (not held across the loop), so it cannot
/// deadlock the `RefCell`.
fn write_fields(
    fields: &HashMap<String, NativeField>,
    forcing: &ForcingBuffer,
    written: &mut Vec<String>,
) -> Result<(), ProviderError> {
    for (var, native) in fields {
        forcing.borrow_mut().insert(var.clone(), native.array.clone());
        written.push(var.clone());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    //! R-1 acceptance evidence (bead ess-14f.9): provider arrays land in the
    //! forcing buffer at each tstop; CONST once / DISCRETE at anchors; None-skip
    //! honored. Providers are in-memory fakes (no I/O), the "testable with a
    //! hand-built buffer" contract the plan specifies.
    use super::*;
    use ndarray::IxDyn;
    use serde_json::json;

    fn buffer() -> ForcingBuffer {
        Rc::new(RefCell::new(HashMap::new()))
    }

    fn field(values: &[f64]) -> NativeField {
        NativeField::new(ArrayD::from_shape_vec(IxDyn(&[values.len()]), values.to_vec()).unwrap())
    }

    fn buf_get(forcing: &ForcingBuffer, var: &str) -> Option<Vec<f64>> {
        forcing
            .borrow()
            .get(var)
            .map(|a| a.iter().copied().collect())
    }

    /// A configurable in-memory provider for one loader feeding one variable. The
    /// fed field is a value-vector (a 1-D array); scalar constructors wrap a single
    /// value, the `_field` constructor takes the whole vector for a shaped forcing.
    struct FakeProvider {
        var: String,
        /// CONST baseline returned by `materialize` (and what makes `materialize`
        /// counted). `None` for a pure-DISCRETE loader that is never materialized.
        materialize_value: Option<Vec<f64>>,
        /// DISCRETE anchors → the field to return; a `None` value models a record
        /// that did not advance (the provider returns `None` → None-skip).
        schedule: Vec<(f64, Option<Vec<f64>>)>,
        materialize_calls: Rc<RefCell<usize>>,
        refresh_log: Rc<RefCell<Vec<f64>>>,
    }

    impl FakeProvider {
        fn const_loader(var: &str, value: f64) -> Self {
            Self {
                var: var.to_string(),
                materialize_value: Some(vec![value]),
                schedule: Vec::new(),
                materialize_calls: Rc::new(RefCell::new(0)),
                refresh_log: Rc::new(RefCell::new(Vec::new())),
            }
        }
        fn discrete_loader(var: &str, schedule: Vec<(f64, Option<f64>)>) -> Self {
            let schedule = schedule
                .into_iter()
                .map(|(t, v)| (t, v.map(|x| vec![x])))
                .collect();
            Self::discrete_loader_field(var, schedule)
        }
        fn discrete_loader_field(var: &str, schedule: Vec<(f64, Option<Vec<f64>>)>) -> Self {
            Self {
                var: var.to_string(),
                materialize_value: None,
                schedule,
                materialize_calls: Rc::new(RefCell::new(0)),
                refresh_log: Rc::new(RefCell::new(Vec::new())),
            }
        }
    }

    impl CadenceProvider for FakeProvider {
        fn materialize(&mut self) -> Result<HashMap<String, NativeField>, ProviderError> {
            *self.materialize_calls.borrow_mut() += 1;
            let v = self
                .materialize_value
                .clone()
                .expect("materialize called on a provider with no CONST baseline");
            Ok(HashMap::from([(self.var.clone(), field(&v))]))
        }
        fn refresh(
            &mut self,
            t: f64,
        ) -> Result<Option<HashMap<String, NativeField>>, ProviderError> {
            self.refresh_log.borrow_mut().push(t);
            for (anchor, value) in &self.schedule {
                if *anchor == t {
                    return Ok(value
                        .as_ref()
                        .map(|v| HashMap::from([(self.var.clone(), field(v))])));
                }
            }
            Ok(None) // `t` is not one of this provider's anchors.
        }
        fn refresh_times(&self) -> Vec<f64> {
            self.schedule.iter().map(|(a, _)| *a).collect()
        }
    }

    /// A doc with one DISCRETE loader (`met`, has `temporal`) feeding `wind`, one
    /// CONST loader (`topo`, no `temporal`) feeding `elev`, and an ordinary state.
    fn mixed_doc() -> Value {
        json!({
            "models": {"M": {"variables": {
                "u":    {"type": "state", "shape": ["i"], "default": 0.0},
                "wind": {"type": "discrete", "shape": ["i"],
                         "refresh": {"kind": "data_ingest", "source": "met"}},
                "elev": {"type": "discrete", "shape": ["i"],
                         "refresh": {"kind": "data_ingest", "source": "topo"}}
            }}},
            "data_loaders": {
                "met":  {"kind": "grid", "temporal": {"frequency": "PT6H"}},
                "topo": {"kind": "static"}
            }
        })
    }

    #[test]
    fn classify_splits_const_and_discrete_by_temporal() {
        let doc = mixed_doc();
        let bindings = classify_loader_bindings(&doc["models"]["M"], &doc).unwrap();
        // Two loaders, in declaration order of the variables they feed (wind→met,
        // then elev→topo).
        let met = bindings.iter().find(|b| b.loader == "met").unwrap();
        let topo = bindings.iter().find(|b| b.loader == "topo").unwrap();
        assert_eq!(met.cadence, Cadence::Discrete, "temporal loader → DISCRETE");
        assert_eq!(met.variables, vec!["wind".to_string()]);
        assert_eq!(topo.cadence, Cadence::Const, "no-temporal loader → CONST");
        assert_eq!(topo.variables, vec!["elev".to_string()]);
    }

    #[test]
    fn classify_groups_multiple_vars_under_one_loader() {
        // One loader feeding two variables → one binding listing both.
        let doc = json!({
            "models": {"M": {"variables": {
                "a": {"type": "discrete", "refresh": {"kind": "data_ingest", "source": "met"}},
                "b": {"type": "discrete", "refresh": {"kind": "data_ingest", "source": "met"}}
            }}},
            "data_loaders": {"met": {"kind": "grid", "temporal": {"frequency": "PT1H"}}}
        });
        let bindings = classify_loader_bindings(&doc["models"]["M"], &doc).unwrap();
        assert_eq!(bindings.len(), 1);
        assert_eq!(bindings[0].cadence, Cadence::Discrete);
        assert_eq!(
            bindings[0].variables,
            vec!["a".to_string(), "b".to_string()]
        );
    }

    #[test]
    fn classify_ignores_non_data_ingest_and_plain_vars() {
        // A `schedule` refresh is not provider-fed; a plain state is not loader-fed.
        let doc = json!({
            "models": {"M": {"variables": {
                "u": {"type": "state"},
                "p": {"type": "parameter"},
                "sched": {"type": "discrete",
                          "refresh": {"kind": "schedule", "times": [1.0, 2.0]}}
            }}},
            "data_loaders": {}
        });
        let bindings = classify_loader_bindings(&doc["models"]["M"], &doc).unwrap();
        assert!(bindings.is_empty(), "no data_ingest loader-fed variable");
    }

    #[test]
    fn const_loader_materialized_once_discrete_untouched() {
        let doc = mixed_doc();
        let topo = FakeProvider::const_loader("elev", 7.0);
        let met = FakeProvider::discrete_loader("wind", vec![(0.0, Some(1.0))]);
        let topo_calls = Rc::clone(&topo.materialize_calls);
        let met_calls = Rc::clone(&met.materialize_calls);

        let providers: HashMap<String, Box<dyn CadenceProvider>> = HashMap::from([
            (
                "topo".to_string(),
                Box::new(topo) as Box<dyn CadenceProvider>,
            ),
            ("met".to_string(), Box::new(met) as Box<dyn CadenceProvider>),
        ]);
        let mut exec = RefreshExecutor::new(
            &doc["models"]["M"],
            &doc,
            providers,
        )
        .unwrap();

        let forcing = buffer();
        let written = exec.materialize_const(&forcing).unwrap();

        // CONST `elev` is loaded once; DISCRETE `met` is NOT materialized.
        assert_eq!(written, vec!["elev".to_string()]);
        assert_eq!(buf_get(&forcing, "elev"), Some(vec![7.0]));
        assert_eq!(
            buf_get(&forcing, "wind"),
            None,
            "DISCRETE not loaded at setup"
        );
        assert_eq!(*topo_calls.borrow(), 1, "CONST materialized exactly once");
        assert_eq!(*met_calls.borrow(), 0, "DISCRETE never materialized");
    }

    #[test]
    fn refresh_times_is_sorted_union_over_discrete_only() {
        let doc = json!({
            "models": {"M": {"variables": {
                "wind": {"type": "discrete", "refresh": {"kind": "data_ingest", "source": "met"}},
                "bc":   {"type": "discrete", "refresh": {"kind": "data_ingest", "source": "bcs"}},
                "elev": {"type": "discrete", "refresh": {"kind": "data_ingest", "source": "topo"}}
            }}},
            "data_loaders": {
                "met":  {"kind": "grid", "temporal": {"frequency": "PT6H"}},
                "bcs":  {"kind": "grid", "temporal": {"frequency": "PT3H"}},
                "topo": {"kind": "static"}
            }
        });
        let providers: HashMap<String, Box<dyn CadenceProvider>> = HashMap::from([
            (
                "met".to_string(),
                Box::new(FakeProvider::discrete_loader(
                    "wind",
                    vec![(0.0, Some(1.0)), (6.0, Some(2.0)), (12.0, Some(3.0))],
                )) as Box<dyn CadenceProvider>,
            ),
            (
                "bcs".to_string(),
                Box::new(FakeProvider::discrete_loader(
                    "bc",
                    vec![
                        (0.0, Some(1.0)),
                        (3.0, Some(2.0)),
                        (6.0, Some(3.0)),
                        (9.0, Some(4.0)),
                        (12.0, Some(5.0)),
                    ],
                )) as Box<dyn CadenceProvider>,
            ),
            (
                "topo".to_string(),
                Box::new(FakeProvider::const_loader("elev", 7.0)) as Box<dyn CadenceProvider>,
            ),
        ]);
        let exec = RefreshExecutor::new(
            &doc["models"]["M"],
            &doc,
            providers,
        )
        .unwrap();

        // Union of {0,6,12} and {0,3,6,9,12}, sorted+deduped; CONST `topo` adds none.
        assert_eq!(exec.refresh_times(), vec![0.0, 3.0, 6.0, 9.0, 12.0]);
    }

    #[test]
    fn discrete_refresh_writes_at_anchors_and_honors_none_skip() {
        let doc = mixed_doc();
        // `met` advances at t=0 (→10) and t=12 (→30), but NOT at t=6 (None → skip).
        let met = FakeProvider::discrete_loader(
            "wind",
            vec![(0.0, Some(10.0)), (6.0, None), (12.0, Some(30.0))],
        );
        let refresh_log = Rc::clone(&met.refresh_log);
        let providers: HashMap<String, Box<dyn CadenceProvider>> = HashMap::from([
            ("met".to_string(), Box::new(met) as Box<dyn CadenceProvider>),
            (
                "topo".to_string(),
                Box::new(FakeProvider::const_loader("elev", 7.0)) as Box<dyn CadenceProvider>,
            ),
        ]);
        let mut exec = RefreshExecutor::new(
            &doc["models"]["M"],
            &doc,
            providers,
        )
        .unwrap();
        let forcing = buffer();

        // Anchor t=0: record advances → buffer gets [10].
        assert_eq!(
            exec.refresh_at(0.0, &forcing).unwrap(),
            vec!["wind".to_string()]
        );
        assert_eq!(buf_get(&forcing, "wind"), Some(vec![10.0]));

        // Anchor t=6: provider returns None → buffer write SKIPPED, [10] retained.
        assert_eq!(
            exec.refresh_at(6.0, &forcing).unwrap(),
            Vec::<String>::new(),
            "None-skip: nothing written at an unchanged anchor"
        );
        assert_eq!(
            buf_get(&forcing, "wind"),
            Some(vec![10.0]),
            "the prior field is retained across a None refresh"
        );

        // Anchor t=12: record advances again → buffer updated to [30].
        assert_eq!(
            exec.refresh_at(12.0, &forcing).unwrap(),
            vec!["wind".to_string()]
        );
        assert_eq!(buf_get(&forcing, "wind"), Some(vec![30.0]));

        assert_eq!(
            *refresh_log.borrow(),
            vec![0.0, 6.0, 12.0],
            "refresh fired at every anchor"
        );
    }

    #[test]
    fn refresh_writes_native_field_into_buffer() {
        let doc = mixed_doc();
        let met = FakeProvider::discrete_loader("wind", vec![(0.0, Some(5.0))]);
        let providers: HashMap<String, Box<dyn CadenceProvider>> = HashMap::from([
            ("met".to_string(), Box::new(met) as Box<dyn CadenceProvider>),
            (
                "topo".to_string(),
                Box::new(FakeProvider::const_loader("elev", 4.0)) as Box<dyn CadenceProvider>,
            ),
        ]);
        // No regrid seam: the native field lands in the buffer unchanged (any
        // native→sim regrid is an in-model coupling the RHS evaluates).
        let mut exec = RefreshExecutor::new(&doc["models"]["M"], &doc, providers).unwrap();
        let forcing = buffer();

        exec.materialize_const(&forcing).unwrap();
        assert_eq!(
            buf_get(&forcing, "elev"),
            Some(vec![4.0]),
            "CONST native field written unchanged"
        );

        exec.refresh_at(0.0, &forcing).unwrap();
        assert_eq!(
            buf_get(&forcing, "wind"),
            Some(vec![5.0]),
            "DISCRETE native field written unchanged"
        );
    }

    #[test]
    fn new_errors_when_a_classified_loader_has_no_provider() {
        let doc = mixed_doc();
        // Supply `met` but not `topo` → the CONST loader is unprovided.
        let providers: HashMap<String, Box<dyn CadenceProvider>> = HashMap::from([(
            "met".to_string(),
            Box::new(FakeProvider::discrete_loader(
                "wind",
                vec![(0.0, Some(1.0))],
            )) as Box<dyn CadenceProvider>,
        )]);
        let e = RefreshExecutor::new(
            &doc["models"]["M"],
            &doc,
            providers,
        )
        .map(|_| ())
        .unwrap_err();
        assert!(
            e.0.contains("topo"),
            "error names the unprovided loader: {}",
            e.0
        );
    }

    #[test]
    fn end_to_end_executor_drives_the_pr1_forcing_buffer_into_the_rhs() {
        // R-1 ⊕ PR-1: the executor writes the forcing buffer that an
        // `ArrayCompiled` RHS reads live. `D(u[i]) = wind[i]` over i∈[1,3]; after a
        // refresh the RHS must equal the forcing the executor wrote.
        //
        // The two views of the loader-fed `wind` reflect the plan's sidestep of a
        // `Discrete` `VariableType` (§2.B): to the *typed* `ArrayCompiled`, `wind`
        // is an **undeclared name** resolved through the forcing buffer (exactly
        // PR-1's pattern — no `discrete` variable in `variables`); to the *cadence
        // pass* (raw JSON), the model declares it `discrete` + `data_ingest` so the
        // executor classifies it DISCRETE. `classify_loader_bindings` reads raw
        // JSON and never typed-parses, so the two coexist on one variable name.
        use crate::parse::load;
        use crate::simulate_array::ArrayCompiled;

        // (a) The ArrayCompiled model: `wind` appears only in the RHS, resolved by
        // name through the forcing buffer (PR-1). No `data_loaders` needed here.
        let model_json = r#"{
         "esm": "0.1.0",
         "metadata": {"name": "r1_forcing"},
         "models": {"Forced": {
           "variables": {"u": {"type": "state", "shape": ["i"], "default": 0.0}},
           "equations": [{
             "lhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
                     "expr": {"op": "D", "args": [{"op": "index", "args": ["u", "i"]}], "wrt": "t"},
                     "ranges": {"i": [1, 3]}},
             "rhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
                     "ranges": {"i": [1, 3]},
                     "expr": {"op": "index", "args": ["wind", "i"]}}
           }]
         }}
        }"#;
        let file = load(model_json).expect("parse forced model");
        let compiled = ArrayCompiled::from_file(&file).expect("compile forced model");

        // (b) The cadence-classification view: `wind` is the DISCRETE output of the
        // `met` loader. Raw JSON for the executor (no schema validation / typed
        // parse), the same shape the classify_* tests use.
        let class_doc = json!({
            "models": {"Forced": {"variables": {
                "wind": {"type": "discrete", "shape": ["i"],
                         "refresh": {"kind": "data_ingest", "source": "met"}}
            }}},
            "data_loaders": {"met": {"kind": "grid", "temporal": {"frequency": "PT6H"}}}
        });

        // The forcing is a shaped [3] field matching i∈[1,3] — distinct per cell so
        // the test pins indexing, not just a broadcast scalar.
        let met = FakeProvider::discrete_loader_field(
            "wind",
            vec![
                (0.0, Some(vec![2.0, 3.0, 4.0])),
                (6.0, Some(vec![9.0, 8.0, 7.0])),
            ],
        );
        let providers: HashMap<String, Box<dyn CadenceProvider>> =
            HashMap::from([("met".to_string(), Box::new(met) as Box<dyn CadenceProvider>)]);
        let mut exec = RefreshExecutor::new(
            &class_doc["models"]["Forced"],
            &class_doc,
            providers,
        )
        .unwrap();

        let forcing = compiled.forcing_handle();
        let params = HashMap::new();
        let state = vec![0.0, 0.0, 0.0];

        // Driver tstops come straight from the executor.
        assert_eq!(exec.refresh_times(), vec![0.0, 6.0]);

        // Segment boundary t=0: refresh → RHS reads the t=0 forcing field.
        exec.refresh_at(0.0, &forcing).unwrap();
        let (dy0, _) = compiled.debug_eval_rhs(&state, 0.0, &params, false);
        assert_eq!(
            dy0,
            vec![2.0, 3.0, 4.0],
            "RHS reads the t=0 forcing the executor wrote"
        );

        // Segment boundary t=6: refresh advances the buffer → RHS reflects it.
        exec.refresh_at(6.0, &forcing).unwrap();
        let (dy6, _) = compiled.debug_eval_rhs(&state, 6.0, &params, false);
        assert_eq!(
            dy6,
            vec![9.0, 8.0, 7.0],
            "RHS reflects the refreshed forcing"
        );
    }
}
