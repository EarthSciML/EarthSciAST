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
//! `solve`.
//!
//! # The provider contract, and why it is a trait
//!
//! One [`DataProvider`] feeds ONE parameter: the build reads it (`sample`, or
//! `sample_with_selection` for a gated fetch), and so does the run
//! (`refresh(t)` at its `refresh_times`). The bytes are fetched by the
//! EarthSciIO Rust `Provider` (bead `esio-9nb.7`, data-providers plan §4.6).
//! EarthSciIO lives in a **separate repo/crate that ESS does not link**; ESS
//! instead depends on the trait here (dependency inversion), and
//! `crate::esio_provider` (feature `esio`) implements it over the real
//! `Provider`.
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
//! into the existing PR-1 buffer. No faq, no scalarizer arm, no
//! `VariableType` variant, no lift of the event/spatial rejections —
//! `declarative-bc-no-new-primitives` holds. Regridding stays declarative in the
//! model (an in-model coupling contraction the RHS evaluates), not a seam here.

use crate::cadence::{self, Cadence};
use crate::pushdown_rewrite::ProviderGate;
use indexmap::IndexMap;
use ndarray::ArrayD;
use serde_json::Value;
use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

/// A provider or refresh-executor failure: a provider that cannot deliver, a
/// malformed loader-fed variable, a missing provider, a cadence-classification
/// disagreement, or a sample of the wrong shape.
///
/// Alias of the shared [`crate::error::MessageError`] newtype; its `Display` is
/// the bare message.
pub type ProviderError = crate::error::MessageError;

/// Builds a document's data providers, once per build, keyed as
/// [`crate::problem::ProblemOptions::providers`] keys them.
///
/// A factory rather than a set because `ProblemOptions` takes its `providers`
/// BY VALUE: one shared map would be moved out by the first build and missing
/// from the second. `Err` carries a message naming what could not be
/// constructed. [`crate::bind_data_sources`] returns one for a document's
/// `data_sources`, and `InlineTestOptions::providers` takes one.
#[cfg(not(target_arch = "wasm32"))]
pub type BuildProviderFactory<'a> =
    dyn Fn() -> Result<Vec<(String, Box<dyn DataProvider>)>, String> + 'a;

/// The wasm32 build has no build pipeline (`crate::prepare` is native-only), so
/// there is no provider contract to satisfy: a factory passed to the inline-test
/// runner is refused, and every assertion of a test that needs one is recorded
/// as an ERROR.
#[cfg(target_arch = "wasm32")]
pub type BuildProviderFactory<'a> = dyn Fn() -> Result<(), String> + 'a;

fn err(msg: impl Into<String>) -> ProviderError {
    // Construct via the underlying newtype: a `pub type` alias to a tuple struct
    // cannot itself be used as a constructor.
    crate::error::MessageError(msg.into())
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

/// A raw native-grid field: the array plus its native coordinate axes (axis
/// name → coordinate values, in native-grid order). What the EarthSciIO bridge
/// decodes; a [`DataProvider`] delivers the array alone.
#[derive(Debug, Clone)]
pub struct NativeField {
    /// The field values on the provider's native grid.
    pub array: ArrayD<f64>,
    /// The native-grid coordinate axes (axis name → coordinate values).
    pub coords: IndexMap<String, Vec<f64>>,
}

impl NativeField {
    /// A field with no coordinate metadata.
    pub fn new(array: ArrayD<f64>) -> Self {
        Self {
            array,
            coords: IndexMap::new(),
        }
    }
}

/// One axis of the per-axis selection handed to a gated provider — the Rust
/// spelling of the Python engine's `"all" | [0-based indices]` form.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AxisSel {
    /// The full native axis.
    All,
    /// The listed 0-based native indices, in order.
    Indices(Vec<usize>),
    /// The half-open strided range `[start, stop)` by `step` (`step >= 1`) —
    /// the contiguous form, kept whole rather than expanded to indices so a
    /// store-backed reader can push a slice down instead of a 52,411-long
    /// index list.
    Range {
        /// Inclusive first index (0-based).
        start: usize,
        /// Exclusive last index.
        stop: usize,
        /// Stride (>= 1).
        step: usize,
    },
}

impl AxisSel {
    /// The 0-based indices this selector picks over an axis of length
    /// `dim_len` (the engine-side fallback for a provider that cannot push a
    /// selection down).
    pub fn indices(&self, dim_len: usize) -> Vec<usize> {
        match self {
            AxisSel::All => (0..dim_len).collect(),
            AxisSel::Indices(v) => v.clone(),
            AxisSel::Range { start, stop, step } => {
                (*start..(*stop).min(dim_len)).step_by(*step).collect()
            }
        }
    }
}

/// A source of ONE parameter's data, keyed in
/// [`crate::problem::ProblemOptions::providers`] by that parameter (esm-spec
/// §6.6.2 spellings: `Fed.s`, `s`, or a partial qualification).
///
/// A provider with no [`Self::refresh_times`] is CONST: its one
/// [`Self::sample`] is the parameter's value for the whole run. A provider
/// with refresh times is DISCRETE: [`Self::refresh`] delivers the record in
/// effect from each of them. When the build pipeline is asked for
/// ([`crate::problem::ProblemOptions::build_pipeline`]), it consumes every
/// CONST provider — whole, or pre-sliced through
/// [`Self::sample_with_selection`] when a gate ([`Self::gate_spec`], or the
/// pushdown rewrite's own) defers it past value invention — and may close a
/// metaparameter with a provider's own record count
/// ([`Self::extent_metaparameter`]). The run-time refresh executor consumes
/// the rest.
///
/// The array a provider delivers must have the parameter's declared shape,
/// its dimensions in the order the source stores them; it is refused
/// otherwise.
pub trait DataProvider {
    /// The whole field, time-less: a CONST provider's value, or the record a
    /// DISCRETE provider holds before any refresh.
    fn sample(&mut self) -> Result<ArrayD<f64>, ProviderError>;

    /// The record in effect from `t` (solver seconds): `Some` when it differs
    /// from what this provider last delivered, `None` when it does not — the
    /// executor then keeps the field it holds. A provider also answers `None`
    /// for a `t` that is not one of its refresh times, so the executor may ask
    /// every DISCRETE provider at every boundary. A CONST provider never
    /// refreshes.
    fn refresh(&mut self, _t: f64) -> Result<Option<ArrayD<f64>>, ProviderError> {
        Ok(None)
    }

    /// The refresh times (solver seconds) at which [`Self::refresh`] should
    /// fire; empty for a CONST provider. Their union across providers is the
    /// boundary list a solve segments on.
    fn refresh_times(&self) -> Vec<f64> {
        Vec::new()
    }

    /// Whether [`Self::sample_with_selection`] pushes the selection down to
    /// the reader (fetching only what intersects it). One that cannot is
    /// sampled whole and sliced by the build, with the same result.
    fn supports_selection(&self) -> bool {
        false
    }

    /// The whole field with a per-axis selection pushed down. EVERY requested
    /// axis is present in the result (a fixed axis comes back length-1 and is
    /// dropped by the build).
    fn sample_with_selection(
        &mut self,
        _selection: &[AxisSel],
    ) -> Result<ArrayD<f64>, ProviderError> {
        Err(err("provider does not support selection pushdown"))
    }

    /// A provider-declared gate (the fallback protocol mirroring Julia's
    /// `provider_gate_spec`); the pushdown rewrite's own gate takes
    /// precedence.
    fn gate_spec(&self) -> Option<ProviderGate> {
        None
    }

    /// The metaparameter this provider's own extent BINDS (esm-spec §8.9): a
    /// loader that discovers its record count at read time declares
    /// `extent: {"metaparameter": "N_REC"}`, and the build closes that
    /// metaparameter with the length of this provider's leading axis before
    /// the typed load. Every provider naming the same metaparameter must
    /// agree, which is also the alignment check across a table's columns.
    fn extent_metaparameter(&self) -> Option<String> {
        None
    }
}

/// One loader's binding: its declared cadence and the model variables it feeds.
/// A loader's `temporal` block decides a single cadence for *all* its outputs, so
/// every variable in `variables` shares `cadence`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LoaderBinding {
    /// The data-source name (the `update.source` of the parameters it feeds),
    /// or, for a binding [`RefreshExecutor`] made from a provider, the
    /// provider's key.
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
/// Walks `model.variables` for PARAMETERS carrying a `data`-kind `update`
/// (esm-spec §5.4), resolves each one's source, and classifies it with
/// [`crate::cadence::seed_leaf`] over [`crate::cadence::model_with_loaders`]: a
/// variable whose source loader declares a `temporal` block seeds `Discrete`
/// (refreshes at the cadence); without one it seeds `Const` (folds once at bind).
/// `doc` supplies the top-level `data_sources` the rule resolves against.
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
        // Only a PARAMETER carries an `update`, and only the `data` kind names a
        // source (a `schedule` / `remesh` / `condition` / `crossing` update is
        // not provider-fed). esm-spec §5.4.
        let Ok(parsed) = serde_json::from_value::<crate::types::ModelVariable>(var.clone()) else {
            continue;
        };
        let sources = parsed.update_sources();
        let Some(source) = sources.first().copied() else {
            continue;
        };
        if sources.iter().any(|s| *s != source) {
            return Err(err(format!(
                "variable {var_name:?}: update rules name several data sources                  ({sources:?}); one parameter is fed by one source"
            )));
        }

        // Declarative CONST/DISCRETE from the cadence pass (the temporal-block
        // rule lives in `loader_without_temporal`, applied by `seed_leaf`).
        let cad = cadence::seed_leaf(&Value::String(var_name.clone()), &model)
            .map_err(|e| err(format!("classifying loader-fed variable {var_name:?}: {e}")))?;
        // A source-fed parameter seeds only Const or Discrete; Continuous
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

/// One provider and the parameter it feeds.
struct Feed {
    /// The forcing-buffer name its array is written under.
    target: String,
    /// What a refused sample's message calls the provider: the caller's key,
    /// which may spell `target` differently (esm-spec §6.6.2).
    label: String,
    /// The parameter's declared shape, resolved against the index-set
    /// registry; `None` when it is not known, and then no shape is checked.
    declared: Option<Vec<usize>>,
    cadence: Cadence,
    precision: crate::precision::Precision,
    provider: Box<dyn DataProvider>,
    /// The provider's `refresh_times()`, sorted and deduplicated, read once
    /// when the feed is bound.
    anchors: Vec<f64>,
    /// The provider's last delivery when it went to a detached sample
    /// ([`RefreshExecutor::sample_detached`]) rather than to the forcing
    /// buffer. A provider answers `None` for a record that has not changed
    /// since it last delivered, so until it delivers again that record is
    /// this one, not the buffer's.
    detached: Option<ArrayD<f64>>,
    /// Whether the provider has delivered a record yet. A provider may
    /// answer "unchanged" (`None`) before its first delivery, for the record
    /// it was primed with (EarthSciIO's providers prime at the start of
    /// their window): that record is then read with [`DataProvider::sample`].
    delivered: bool,
}

impl Feed {
    fn new(
        target: String,
        label: String,
        declared: Option<Vec<usize>>,
        cadence: Cadence,
        provider: Box<dyn DataProvider>,
    ) -> Self {
        let mut anchors = provider.refresh_times();
        anchors.sort_by(f64::total_cmp);
        anchors.dedup();
        Feed {
            target,
            label,
            declared,
            cadence,
            precision: crate::precision::Precision::Float64,
            provider,
            anchors,
            detached: None,
            delivered: false,
        }
    }

    /// `a`, refused when it does not have the declared shape.
    fn checked(&self, mut a: ArrayD<f64>) -> Result<ArrayD<f64>, ProviderError> {
        check_provider_shape(&self.label, &a, self.declared.as_deref())?;
        if self.precision.is_f32() {
            a.mapv_inplace(|value| self.precision.round(value));
        }
        Ok(a)
    }

    fn sample(&mut self) -> Result<ArrayD<f64>, ProviderError> {
        let a = self.provider.sample()?;
        self.checked(a)
    }

    fn refresh(&mut self, t: f64) -> Result<Option<ArrayD<f64>>, ProviderError> {
        match self.provider.refresh(t)? {
            Some(a) => {
                self.delivered = true;
                self.checked(a).map(Some)
            }
            None => Ok(None),
        }
    }

    /// Ask the provider for the record in effect at `t`: `Ok(None)` when it
    /// has none there (no answer at `t` and no refresh time at or before it),
    /// `Ok(Some(None))` when its record did not change since it last
    /// delivered, `Ok(Some(Some(a)))` for a new delivery.
    fn ask_in_effect(&mut self, t: f64) -> Result<Option<Option<ArrayD<f64>>>, ProviderError> {
        let a = self.refresh(t)?;
        if a.is_some() || self.is_anchor(t) {
            return self.primed_if_unchanged(a).map(Some);
        }
        match self.anchor_before(t) {
            Some(b) => {
                let a = self.refresh(b)?;
                self.primed_if_unchanged(a).map(Some)
            }
            None => Ok(None),
        }
    }

    /// A refresh's answer at a time the provider has a record in effect,
    /// with "unchanged" (`None`) before the provider's first delivery read as
    /// the record it holds: a provider may be primed with the record in
    /// effect at the start of its window (EarthSciIO's are) and answer
    /// `None` for it, and nothing has read that record yet. Without this an
    /// `ic` at the start of the run, or the forcing at construction, would
    /// take the parameter's declared default instead of its data.
    fn primed_if_unchanged(
        &mut self,
        a: Option<ArrayD<f64>>,
    ) -> Result<Option<ArrayD<f64>>, ProviderError> {
        if a.is_some() || self.delivered {
            return Ok(a);
        }
        self.delivered = true;
        self.sample().map(Some)
    }

    /// Write a delivery into the forcing buffer: a new one, or on `None` (no
    /// change) the one a detached sample took, which the buffer does not
    /// hold yet. Either way the buffer then holds the provider's last
    /// delivery.
    fn write_delivery(
        &mut self,
        a: Option<ArrayD<f64>>,
        forcing: &ForcingBuffer,
        written: &mut Vec<String>,
    ) {
        let stashed = self.detached.take();
        if let Some(a) = a.or(stashed) {
            forcing.borrow_mut().insert(self.target.clone(), a);
            written.push(self.target.clone());
        }
    }

    /// Whether `t` is one of the provider's own refresh times.
    fn is_anchor(&self, t: f64) -> bool {
        self.anchors.binary_search_by(|a| a.total_cmp(&t)).is_ok()
    }

    /// The provider's latest refresh time strictly before `t`.
    fn anchor_before(&self, t: f64) -> Option<f64> {
        let n = self.anchors.partition_point(|&a| a < t);
        n.checked_sub(1).map(|i| self.anchors[i])
    }

    /// A failure of this feed, naming the provider by its key.
    fn named(&self, error: ProviderError) -> LoaderError {
        LoaderError {
            loader: self.target.clone(),
            error,
        }
    }
}

/// The message refusing an array of shape `got` for a variable declared with
/// shape `declared`, or `None` when it fits: equal axis by axis, and a 0-d
/// declaration (`[]`) takes an array of exactly one element. `who` names what
/// delivered it.
pub(crate) fn declared_shape_mismatch(
    who: &str,
    got: &[usize],
    declared: &[usize],
) -> Option<String> {
    let fits = if declared.is_empty() {
        got.iter().product::<usize>() == 1
    } else {
        got == declared
    };
    (!fits).then(|| {
        format!(
            "{who} delivered an array of shape {got:?}; the parameter's declared shape is \
             {declared:?}{}",
            if declared.is_empty() {
                ", one value"
            } else {
                ""
            }
        )
    })
}

/// Refuse a provider sample for `target` whose array does not have the
/// `declared` shape ([`declared_shape_mismatch`]); `None` checks nothing. The
/// check the run-time executor applies to every sample and every refresh, and
/// the one [`crate::forcing_from_sample`] applies, so the two accept and
/// refuse the same samples.
pub(crate) fn check_provider_shape(
    target: &str,
    a: &ArrayD<f64>,
    declared: Option<&[usize]>,
) -> Result<(), ProviderError> {
    match declared
        .and_then(|d| declared_shape_mismatch(&format!("provider for {target:?}"), a.shape(), d))
    {
        Some(msg) => Err(err(msg)),
        None => Ok(()),
    }
}

/// The refresh executor: the "**refresh callable + refresh_times**" surface a
/// discrete-cadence driver consumes (NOT a solver).
///
/// Pairs each [`DataProvider`] with the parameter it feeds and that
/// parameter's cadence, materializes CONST forcings once, and refreshes
/// DISCRETE forcings at their refresh times — each time writing the array
/// straight into the PR-1 [`ForcingBuffer`] (any native→sim regrid is an
/// in-model coupling expression the RHS evaluates, not a seam here).
///
/// Lifecycle a driver follows (R-3):
/// 1. [`RefreshExecutor::new`] — classify + pair providers.
/// 2. [`RefreshExecutor::materialize_const`] — once, at setup, before integrating.
/// 3. `tstops = ` [`RefreshExecutor::refresh_times`] `∩ (t0, t_end)` — driver
///    segment boundaries.
/// 4. At each boundary `t`: [`RefreshExecutor::refresh_at`]`(t, &buffer)`, then
///    continue the segmented solve.
pub struct RefreshExecutor {
    feeds: Vec<Feed>,
}

impl RefreshExecutor {
    /// Build the executor from the model's own declarations: classify each
    /// loader-fed variable of `model` (with `doc`'s `data_sources`) CONST or
    /// DISCRETE ([`classify_loader_bindings`]), and pair it with the provider
    /// in `providers` keyed by that variable — its name as `model` declares
    /// it, or that name under any prefix (`Box.src` for `src`). Each array is
    /// written under the provider's key. Every classified variable must have
    /// a provider; a provider no classified variable takes is ignored.
    pub fn new(
        model: &Value,
        doc: &Value,
        mut providers: HashMap<String, Box<dyn DataProvider>>,
    ) -> Result<Self, ProviderError> {
        let bindings = classify_loader_bindings(model, doc)?;
        let mut feeds = Vec::new();
        for binding in bindings {
            for var in &binding.variables {
                let suffix = format!(".{var}");
                let mut keys: Vec<&String> = providers
                    .keys()
                    .filter(|k| *k == var || k.ends_with(&suffix))
                    .collect();
                keys.sort();
                let key = match keys.as_slice() {
                    [k] => (*k).clone(),
                    [] => {
                        return Err(err(format!(
                            "no provider supplied for {var:?} (fed by the loader {:?})",
                            binding.loader
                        )));
                    }
                    several => {
                        return Err(err(format!(
                            "several providers feed {var:?}: {several:?}; pass one"
                        )));
                    }
                };
                let provider = providers.remove(&key).expect("a key of the map");
                feeds.push(Feed::new(key.clone(), key, None, binding.cadence, provider));
            }
        }
        Ok(Self { feeds })
    }

    /// Build the executor directly from a provider map keyed by the forcing
    /// variable each feeds (the `providers=` injection seam the runners use):
    /// a provider with refresh times is DISCRETE, one without is CONST, so a
    /// model whose loaders are supplied by the caller — with no `data`
    /// updates for [`classify_loader_bindings`] to read — still gets ONE
    /// provider-management path.
    pub fn from_providers(providers: HashMap<String, Box<dyn DataProvider>>) -> Self {
        Self::from_providers_with_shapes(providers, &HashMap::new(), &HashMap::new())
    }

    /// [`Self::from_providers`], refusing every sample a provider delivers
    /// (`sample()` and each `refresh(t)`) whose array does not have the shape
    /// `declared` holds under that provider's key. A key `declared` does not
    /// hold is not shape-checked. A refused sample is reported under the name
    /// `labels` holds for its key (the caller's spelling of it), else under
    /// the key itself.
    pub(crate) fn from_providers_with_shapes(
        providers: HashMap<String, Box<dyn DataProvider>>,
        declared: &HashMap<String, Vec<usize>>,
        labels: &HashMap<String, String>,
    ) -> Self {
        let mut feeds: Vec<Feed> = providers
            .into_iter()
            .map(|(var, provider)| {
                let cadence = if provider.refresh_times().is_empty() {
                    Cadence::Const
                } else {
                    Cadence::Discrete
                };
                Feed::new(
                    var.clone(),
                    labels.get(&var).cloned().unwrap_or_else(|| var.clone()),
                    declared.get(&var).cloned(),
                    cadence,
                    provider,
                )
            })
            .collect();
        feeds.sort_by(|a, b| a.target.cmp(&b.target));
        Self { feeds }
    }

    pub(crate) fn set_precision(&mut self, env: &crate::precision::Env) {
        for feed in &mut self.feeds {
            feed.precision = env.variable(&feed.target);
        }
    }

    /// What is wired: one binding per provider, naming the variable it feeds
    /// and its cadence.
    pub fn bindings(&self) -> impl Iterator<Item = LoaderBinding> + '_ {
        self.feeds.iter().map(|f| LoaderBinding {
            loader: f.label.clone(),
            cadence: f.cadence,
            variables: vec![f.target.clone()],
        })
    }

    /// CONST forcings: `sample()` each CONST provider **once** and write its
    /// array into `forcing`. Call at setup, before the segmented integration
    /// loop; DISCRETE providers are untouched here. Returns the variable names
    /// written (sorted).
    pub fn materialize_const(
        &mut self,
        forcing: &ForcingBuffer,
    ) -> Result<Vec<String>, ProviderError> {
        self.materialize_const_named(forcing).map_err(|e| e.error)
    }

    /// [`Self::materialize_const`], with a failure naming the provider that
    /// raised it.
    pub(crate) fn materialize_const_named(
        &mut self,
        forcing: &ForcingBuffer,
    ) -> Result<Vec<String>, LoaderError> {
        let mut written = Vec::new();
        for f in self
            .feeds
            .iter_mut()
            .filter(|f| f.cadence == Cadence::Const)
        {
            let a = f.sample().map_err(|e| f.named(e))?;
            f.write_delivery(Some(a), forcing, &mut written);
        }
        written.sort();
        written.dedup();
        Ok(written)
    }

    /// The sorted, de-duplicated union of every DISCRETE provider's
    /// `refresh_times` — the driver's tstop list. CONST providers contribute
    /// none. The caller intersects with the integration window `(t0, t_end)`.
    pub fn refresh_times(&self) -> Vec<f64> {
        let mut times: Vec<f64> = self
            .feeds
            .iter()
            .filter(|f| f.cadence == Cadence::Discrete)
            .flat_map(|f| f.anchors.iter().copied())
            .collect();
        times.sort_by(f64::total_cmp);
        times.dedup();
        times
    }

    /// Refresh at boundary `t`: for each DISCRETE provider, call `refresh(t)`;
    /// on `Some(a)`, write it into `forcing`; on `None` (record unchanged, or
    /// `t` not this provider's refresh time), **skip the write** — the
    /// previously-loaded field stays in the buffer. Returns the variable names
    /// (re)written at this boundary (sorted).
    ///
    /// Mutate the buffer only *between* segments (the driver calls this at a
    /// boundary, never inside a solver step), keeping the RHS pure within a
    /// segment.
    pub fn refresh_at(
        &mut self,
        t: f64,
        forcing: &ForcingBuffer,
    ) -> Result<Vec<String>, ProviderError> {
        self.refresh_named(t, forcing).map_err(|e| e.error)
    }

    /// Sample every DISCRETE provider at `t`, an arbitrary time rather than a
    /// refresh time: the record in effect there. Returns the variable names
    /// written (sorted).
    ///
    /// For each provider: when `t` is one of its own refresh times it is asked
    /// for `refresh(t)`, and `None` means its record did not change, so
    /// nothing is written. Otherwise it is asked for `refresh(t)` first (a
    /// provider may answer at any time, as Julia's `provider_sample` does),
    /// and on `None` for `refresh(b)` at `b`, its latest refresh time before
    /// `t`, whose record holds over `t`. A provider with no refresh time at or
    /// before `t` that does not answer at `t` has no record in effect and
    /// writes nothing.
    ///
    /// This is the sample a Problem takes at construction (`sample_time`,
    /// esm-libraries-spec §2.5.2) and a solve takes at its start. A boundary
    /// refresh inside a solve uses [`Self::refresh_at`].
    pub fn sample_at(
        &mut self,
        t: f64,
        forcing: &ForcingBuffer,
    ) -> Result<Vec<String>, ProviderError> {
        let mut written = Vec::new();
        self.sample_in_effect(t, forcing, &mut written)
            .map_err(|e| e.error)?;
        written.sort();
        written.dedup();
        Ok(written)
    }

    /// [`Self::refresh_at`], with a failure naming the provider that raised it.
    pub(crate) fn refresh_named(
        &mut self,
        t: f64,
        forcing: &ForcingBuffer,
    ) -> Result<Vec<String>, LoaderError> {
        let mut written = Vec::new();
        for f in self
            .feeds
            .iter_mut()
            .filter(|f| f.cadence == Cadence::Discrete)
        {
            let a = f.refresh(t).map_err(|e| f.named(e))?;
            f.write_delivery(a, forcing, &mut written);
        }
        written.sort();
        written.dedup();
        Ok(written)
    }

    /// [`Self::sample_at`], with a failure naming the provider that raised it.
    /// Appends the variables written to `written`, and returns the variables
    /// of every DISCRETE provider with no record in effect at `t` (sorted).
    pub(crate) fn sample_in_effect(
        &mut self,
        t: f64,
        forcing: &ForcingBuffer,
        written: &mut Vec<String>,
    ) -> Result<Vec<String>, LoaderError> {
        let mut vacant = Vec::new();
        for f in self
            .feeds
            .iter_mut()
            .filter(|f| f.cadence == Cadence::Discrete)
        {
            match f.ask_in_effect(t).map_err(|e| f.named(e))? {
                Some(a) => f.write_delivery(a, forcing, written),
                None => vacant.push(f.target.clone()),
            }
        }
        vacant.sort();
        vacant.dedup();
        Ok(vacant)
    }

    /// The record in effect at `t` of every DISCRETE provider feeding a name
    /// in `only`, without writing the forcing buffer: what a reader needs at
    /// a time other than the one the buffer holds (an `ic` right-hand side
    /// at the start of the run, esm-spec §11.4.2). Returns the fields, and
    /// the names in `only` with no record in effect at `t` (sorted).
    ///
    /// A provider whose record did not change since it last delivered gives
    /// that delivery: the buffer's field, or the one an earlier detached
    /// sample took. A new delivery is kept for the buffer's next write from
    /// that provider ([`Feed::write_delivery`]), so a solve after this one
    /// still starts from the record in effect at its start.
    #[allow(clippy::type_complexity)]
    pub(crate) fn sample_detached(
        &mut self,
        t: f64,
        only: &std::collections::HashSet<String>,
        forcing: &ForcingBuffer,
    ) -> Result<(HashMap<String, ArrayD<f64>>, Vec<String>), LoaderError> {
        let mut out: HashMap<String, ArrayD<f64>> = HashMap::new();
        for f in self
            .feeds
            .iter_mut()
            .filter(|f| f.cadence == Cadence::Discrete && only.contains(&f.target))
        {
            match f.ask_in_effect(t).map_err(|e| f.named(e))? {
                Some(Some(a)) => {
                    out.insert(f.target.clone(), a.clone());
                    f.detached = Some(a);
                }
                Some(None) => {
                    let held = f
                        .detached
                        .clone()
                        .or_else(|| forcing.borrow().get(&f.target).cloned());
                    if let Some(a) = held {
                        out.insert(f.target.clone(), a);
                    }
                }
                None => {}
            }
        }
        // A name no delivery holds has no record in effect at `t`.
        let mut vacant: Vec<String> = only
            .iter()
            .filter(|n| !out.contains_key(*n))
            .cloned()
            .collect();
        vacant.sort();
        Ok((out, vacant))
    }
}

/// A provider failure, with the variable its provider feeds.
#[derive(Debug)]
pub(crate) struct LoaderError {
    pub(crate) loader: String,
    pub(crate) error: ProviderError,
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

    fn field(values: &[f64]) -> ArrayD<f64> {
        ArrayD::from_shape_vec(IxDyn(&[values.len()]), values.to_vec()).unwrap()
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
        fn const_loader(_var: &str, value: f64) -> Self {
            Self {
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
        fn discrete_loader_field(_var: &str, schedule: Vec<(f64, Option<Vec<f64>>)>) -> Self {
            Self {
                materialize_value: None,
                schedule,
                materialize_calls: Rc::new(RefCell::new(0)),
                refresh_log: Rc::new(RefCell::new(Vec::new())),
            }
        }
    }

    impl DataProvider for FakeProvider {
        fn sample(&mut self) -> Result<ArrayD<f64>, ProviderError> {
            *self.materialize_calls.borrow_mut() += 1;
            let v = self
                .materialize_value
                .clone()
                .expect("sample called on a provider with no CONST baseline");
            Ok(field(&v))
        }
        fn refresh(&mut self, t: f64) -> Result<Option<ArrayD<f64>>, ProviderError> {
            self.refresh_log.borrow_mut().push(t);
            for (anchor, value) in &self.schedule {
                if *anchor == t {
                    return Ok(value.as_ref().map(|v| field(v)));
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
                "u":    {"type": "unknown", "shape": ["i"], "default": 0.0},
                "wind": {"type": "parameter", "shape": ["i"],
                         "update": {"kind": "data", "source": "met", "from": {"file_variable": "F"}}},
                "elev": {"type": "parameter", "shape": ["i"],
                         "update": {"kind": "data", "source": "topo", "from": {"file_variable": "F"}}}
            }}},
            "data_sources": {
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
                "a": {"type": "parameter", "shape": [],
                         "update": {"kind": "data", "source": "met", "from": {"file_variable": "F"}}},
                "b": {"type": "parameter", "shape": [],
                         "update": {"kind": "data", "source": "met", "from": {"file_variable": "F"}}}
            }}},
            "data_sources": {"met": {"kind": "grid", "temporal": {"frequency": "PT1H"}}}
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
    fn classify_ignores_non_data_updates_and_plain_vars() {
        // A `schedule` update is not provider-fed; an unknown is not source-fed.
        let doc = json!({
            "models": {"M": {"variables": {
                "u": {"type": "unknown"},
                "p": {"type": "parameter"},
                "sched": {"type": "parameter", "shape": [],
                          "update": {"kind": "schedule", "times": [1.0, 2.0],
                                     "handler": {"handler_id": "reload_sched"}}}
            }}},
            "data_sources": {}
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

        let providers: HashMap<String, Box<dyn DataProvider>> = HashMap::from([
            ("elev".to_string(), Box::new(topo) as Box<dyn DataProvider>),
            ("wind".to_string(), Box::new(met) as Box<dyn DataProvider>),
        ]);
        let mut exec = RefreshExecutor::new(&doc["models"]["M"], &doc, providers).unwrap();

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
                "wind": {"type": "parameter", "shape": [],
                         "update": {"kind": "data", "source": "met", "from": {"file_variable": "F"}}},
                "bc":   {"type": "parameter", "shape": [],
                         "update": {"kind": "data", "source": "bcs", "from": {"file_variable": "F"}}},
                "elev": {"type": "parameter", "shape": [],
                         "update": {"kind": "data", "source": "topo", "from": {"file_variable": "F"}}}
            }}},
            "data_sources": {
                "met":  {"kind": "grid", "temporal": {"frequency": "PT6H"}},
                "bcs":  {"kind": "grid", "temporal": {"frequency": "PT3H"}},
                "topo": {"kind": "static"}
            }
        });
        let providers: HashMap<String, Box<dyn DataProvider>> = HashMap::from([
            (
                "wind".to_string(),
                Box::new(FakeProvider::discrete_loader(
                    "wind",
                    vec![(0.0, Some(1.0)), (6.0, Some(2.0)), (12.0, Some(3.0))],
                )) as Box<dyn DataProvider>,
            ),
            (
                "bc".to_string(),
                Box::new(FakeProvider::discrete_loader(
                    "bc",
                    vec![
                        (0.0, Some(1.0)),
                        (3.0, Some(2.0)),
                        (6.0, Some(3.0)),
                        (9.0, Some(4.0)),
                        (12.0, Some(5.0)),
                    ],
                )) as Box<dyn DataProvider>,
            ),
            (
                "elev".to_string(),
                Box::new(FakeProvider::const_loader("elev", 7.0)) as Box<dyn DataProvider>,
            ),
        ]);
        let exec = RefreshExecutor::new(&doc["models"]["M"], &doc, providers).unwrap();

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
        let providers: HashMap<String, Box<dyn DataProvider>> = HashMap::from([
            ("wind".to_string(), Box::new(met) as Box<dyn DataProvider>),
            (
                "elev".to_string(),
                Box::new(FakeProvider::const_loader("elev", 7.0)) as Box<dyn DataProvider>,
            ),
        ]);
        let mut exec = RefreshExecutor::new(&doc["models"]["M"], &doc, providers).unwrap();
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
        let providers: HashMap<String, Box<dyn DataProvider>> = HashMap::from([
            ("wind".to_string(), Box::new(met) as Box<dyn DataProvider>),
            (
                "elev".to_string(),
                Box::new(FakeProvider::const_loader("elev", 4.0)) as Box<dyn DataProvider>,
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
        let providers: HashMap<String, Box<dyn DataProvider>> = HashMap::from([(
            "wind".to_string(),
            Box::new(FakeProvider::discrete_loader(
                "wind",
                vec![(0.0, Some(1.0))],
            )) as Box<dyn DataProvider>,
        )]);
        let e = RefreshExecutor::new(&doc["models"]["M"], &doc, providers)
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
        use crate::parse::load_string;
        use crate::simulate_array::ArrayCompiled;

        // (a) The ArrayCompiled model: `wind` appears only in the RHS, resolved by
        // name through the forcing buffer (PR-1). No `data_sources` needed here.
        let model_json = r#"
            {
              "esm": "2.0.0",
              "metadata": {
                "name": "r1_forcing"
              },
              "models": {
                "Forced": {
                  "variables": {
                    "u": {
                      "type": "unknown",
                      "shape": [
                        "i"
                      ],
                      "default": 0.0
                    }
                  },
                  "equations": [
                    {
                      "lhs": {
                        "op": "faq",
                        "args": [],
                        "output_idx": [
                          "i"
                        ],
                        "expr": {
                          "op": "D",
                          "args": [
                            {
                              "op": "index",
                              "args": [
                                "u",
                                "i"
                              ]
                            }
                          ],
                          "wrt": "t"
                        },
                        "ranges": {
                          "i": [
                            1,
                            3
                          ]
                        }
                      },
                      "rhs": {
                        "op": "faq",
                        "args": [],
                        "output_idx": [
                          "i"
                        ],
                        "ranges": {
                          "i": [
                            1,
                            3
                          ]
                        },
                        "expr": {
                          "op": "index",
                          "args": [
                            "wind",
                            "i"
                          ]
                        }
                      }
                    }
                  ]
                }
              }
            }
            "#;
        let file = load_string(model_json).expect("parse forced model");
        let compiled = ArrayCompiled::from_file(&file).expect("compile forced model");

        // (b) The cadence-classification view: `wind` is the DISCRETE output of the
        // `met` loader. Raw JSON for the executor (no schema validation / typed
        // parse), the same shape the classify_* tests use.
        let class_doc = json!({
            "models": {"Forced": {"variables": {
                "wind": {"type": "parameter", "shape": ["i"],
                         "update": {"kind": "data", "source": "met", "from": {"file_variable": "F"}}}
            }}},
            "data_sources": {"met": {"kind": "grid", "temporal": {"frequency": "PT6H"}}}
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
        let providers: HashMap<String, Box<dyn DataProvider>> = HashMap::from([(
            "Forced.wind".to_string(),
            Box::new(met) as Box<dyn DataProvider>,
        )]);
        let mut exec =
            RefreshExecutor::new(&class_doc["models"]["Forced"], &class_doc, providers).unwrap();

        let forcing = compiled.forcing_handle();
        let params = HashMap::new();
        let state = vec![0.0, 0.0, 0.0];

        // Driver tstops come straight from the executor.
        assert_eq!(exec.refresh_times(), vec![0.0, 6.0]);

        // Segment boundary t=0: refresh → RHS reads the t=0 forcing field.
        exec.refresh_at(0.0, &forcing).unwrap();
        let (dy0, _) = compiled.debug_eval_rhs(&state, 0.0, &params);
        assert_eq!(
            dy0,
            vec![2.0, 3.0, 4.0],
            "RHS reads the t=0 forcing the executor wrote"
        );

        // Segment boundary t=6: refresh advances the buffer → RHS reflects it.
        exec.refresh_at(6.0, &forcing).unwrap();
        let (dy6, _) = compiled.debug_eval_rhs(&state, 6.0, &params);
        assert_eq!(
            dy6,
            vec![9.0, 8.0, 7.0],
            "RHS reflects the refreshed forcing"
        );
    }
}
