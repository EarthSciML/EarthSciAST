//! Reading a Problem's build-time fields and observed trajectories back by
//! name (API_SPEC §5.8).

use super::*;

/// `key` qualified by the component path `model`, idempotently.
///
/// The two field maps an [`EsmProblem`] carries are keyed differently. The
/// build pipeline keys a field by the SELECTED MODEL's own variable name
/// (`E_PM25`, or `North.u` for a mounted subsystem), because it evaluates one
/// model's observed graph rather than the flattened document's; the state-free
/// static evaluation keys it by the FLATTENED name (`ISRM.E_PM25`), because
/// it evaluates the flattened system. Qualifying the first spelling and leaving
/// the second alone puts both into the one namespace Julia and Python key
/// their build-time fields by, so `observed_field` answers the same spellings
/// in all three bindings.
///
/// A key EQUAL to `model` is a variable named like its model, not a component
/// path, so it is qualified too: `fuel_mce` in model `fuel_mce` is
/// `fuel_mce.fuel_mce`, the spelling the flattened name has (API_SPEC §5.8)
/// and the one Julia and Python report.
pub(crate) fn qualify(model: &str, key: &str) -> String {
    let already = key
        .strip_prefix(model)
        .is_some_and(|rest| rest.starts_with('.'));
    if model.is_empty() || already {
        key.to_string()
    } else {
        format!("{model}.{key}")
    }
}

/// The component that owns a qualified name — everything before the final
/// segment, or `""` when the name is unqualified.
pub(super) fn component_of(qualified: &str) -> &str {
    qualified.rsplit_once('.').map_or("", |(head, _)| head)
}

/// The distinct components owning `prob`'s build-time fields (API_SPEC §5.8).
///
/// A bare name is only resolvable when this holds exactly one: with two
/// mounted components a bare `u` designates `North.u` and `South.u` equally,
/// and answering with either is worse than refusing.
pub(super) fn field_components(prob: &EsmProblem) -> std::collections::BTreeSet<String> {
    let model = prob.model_name.as_deref().unwrap_or("");
    let mut out = std::collections::BTreeSet::new();
    for k in prob.build.fields.keys() {
        out.insert(component_of(&qualify(model, k)).to_string());
    }
    for k in prob.inspection.borrow().setup_arrays.keys() {
        out.insert(component_of(&qualify(model, k)).to_string());
    }
    for k in prob.build.data_fields.keys() {
        out.insert(component_of(&qualify(model, k)).to_string());
    }
    out
}

/// Outcome of applying §5.8's precedence to one namespace of stored keys.
pub(super) enum NameResolution {
    /// The stored key `name` designates.
    Key(String),
    /// `name` is a bare name whose tail matches these keys (sorted), but the
    /// gate refused to bind one: a multi-component problem, or a second tail
    /// match within ONE component — where two keys cannot share a tail, so a
    /// second match means the component set was miscounted; refuse rather
    /// than pick.
    Ambiguous(Vec<String>),
    /// No rule matched.
    Miss,
}

/// The §5.8 name-resolution rule, shared by [`observed_field`] and the
/// observed-trajectory resolver, in precedence order:
///
/// 1. **Exact hit** — `name` is a stored key.
/// 2. **Component-qualified hit** — `name` is a stored key's [`qualify`]d
///    spelling (`ISRM.E_PM25` for the pipeline's `E_PM25`). Done as a strip
///    rather than a scan: `name` is the qualified spelling of key `k` exactly
///    when it is `model` + `.` + `k`. With an empty `model` the inner strip
///    fails and this is a no-op.
/// 3. **Bare name** — `name` carries no `.` and the problem has exactly ONE
///    component; it then resolves to the unique key with that tail.
///
/// A bare name whose tail matches but which rule 3's gate refuses comes back
/// as [`NameResolution::Ambiguous`] carrying every candidate, so a caller can
/// put the remedy in its diagnostic — the author has to qualify the name, and
/// cannot know which spellings exist without being told.
pub(super) fn resolve_observed_key<'a>(
    keys: impl Iterator<Item = &'a String> + Clone,
    model: &str,
    single_component: bool,
    name: &str,
) -> NameResolution {
    if keys.clone().any(|k| k == name) {
        return NameResolution::Key(name.to_string()); // rule 1
    }
    if let Some(rest) = name.strip_prefix(model).and_then(|r| r.strip_prefix('.'))
        && keys.clone().any(|k| k == rest)
    {
        return NameResolution::Key(rest.to_string()); // rule 2
    }
    if name.contains('.') {
        return NameResolution::Miss; // rule 3 is for bare names only
    }
    let mut matches: Vec<&String> = keys
        .filter(|k| k.rsplit('.').next() == Some(name))
        .collect();
    matches.sort();
    if single_component && matches.len() == 1 {
        return NameResolution::Key(matches[0].clone());
    }
    if matches.is_empty() {
        NameResolution::Miss
    } else {
        NameResolution::Ambiguous(matches.into_iter().cloned().collect())
    }
}

/// The keys of `keys` (a build's ingested data-fed parameters, model-local)
/// that the caller-spelled `names` may address under [`resolve_observed_key`]:
/// an exact or component-qualified hit, or EVERY key with a bare name's tail
/// (the component count that decides a bare name is not known yet, and keeping
/// a superset only costs memory; [`observed_field`] still resolves the name).
#[cfg_attr(target_arch = "wasm32", allow(dead_code))]
pub(super) fn retained_data_keys_of<'a>(
    keys: impl Iterator<Item = &'a String> + Clone,
    model: &str,
    names: &[String],
) -> std::collections::HashSet<String> {
    let mut out = std::collections::HashSet::new();
    for name in names {
        match resolve_observed_key(keys.clone(), model, false, name) {
            NameResolution::Key(k) => {
                out.insert(k);
            }
            NameResolution::Ambiguous(ks) => out.extend(ks),
            NameResolution::Miss => {}
        }
    }
    out
}

/// The build-time field named `name`, from `prob`'s construction.
///
/// Resolution is the cross-binding rule of API_SPEC §5.8
/// ([`resolve_observed_key`]), in precedence order:
///
/// 1. **Exact hit** — `name` is a stored key.
/// 2. **Component-qualified hit** — `name` is a stored key's [`qualify`]d
///    spelling (`ISRM.E_PM25` for the pipeline's `E_PM25`).
/// 3. **Bare name** — `name` carries no `.`, and the problem has exactly ONE
///    component; it then resolves to the unique field with that tail.
///
/// A bare name against a MULTI-component problem is refused rather than bound
/// to an arbitrary candidate. Reads the build pipeline's fields, the state-free
/// static evaluation's fields, and — when [`ProblemOptions::inspect`] was set —
/// the array runtime's materialized setup arrays. One arity, `(prob, name)`,
/// in every binding.
///
/// Also answers for a DATA-FED parameter (esm-spec §5.4) the build pipeline
/// ingested, with the values its provider supplied, when the caller named it
/// in [`ProblemOptions::retain_data_fields`]; an observed of the same spelling
/// wins.
pub fn observed_field(prob: &EsmProblem, name: &str) -> Result<ArrayD<f64>, SimulateError> {
    // Re-arm the document's working precision for the duration of this call
    // (`domain.element_type`, esm-spec §11.3); a no-op for a Float64 document.
    let _precision_guard = prob.precision.enter();
    // A name an `operator_compose` renaming match DELETED addresses a field that
    // MOVED (issue #230). The merge only ever removes a spelling, so a hit here
    // can never shadow a live field.
    let name = problem_merged_renames(prob)
        .get(name)
        .map(String::as_str)
        .unwrap_or(name);
    let model = prob.model_name.as_deref().unwrap_or("");
    let components = field_components(prob);
    let single = components.len() == 1;

    if let NameResolution::Key(k) =
        resolve_observed_key(prob.build.fields.keys(), model, single, name)
    {
        return Ok(prob.build.fields[&k].clone());
    }
    let inspection = prob.inspection.borrow();
    if let NameResolution::Key(k) =
        resolve_observed_key(inspection.setup_arrays.keys(), model, single, name)
    {
        return Ok(inspection.setup_arrays[&k].clone());
    }
    // A DATA-FED parameter is as observable as a computed variable: its value
    // is what the provider supplied (finding F43). Consulted last, so it never
    // shadows an observed of the same spelling.
    if let NameResolution::Key(k) =
        resolve_observed_key(prob.build.data_fields.keys(), model, single, name)
    {
        return Ok(prob.build.data_fields[&k].clone());
    }
    // A bare name that WOULD have resolved but for the component gate gets the
    // remedy in the diagnostic: the author has to qualify it, and cannot know
    // which spellings exist without being told. (`Ambiguous` under a SINGLE
    // component — the miscounted-set refusal — keeps the generic error below,
    // as it always has.)
    if !single
        && let NameResolution::Ambiguous(matches) = resolve_observed_key(
            prob.build
                .fields
                .keys()
                .chain(inspection.setup_arrays.keys())
                .chain(prob.build.data_fields.keys()),
            model,
            single,
            name,
        )
    {
        let mut cands: Vec<String> = matches.iter().map(|k| qualify(model, k)).collect();
        cands.sort();
        cands.dedup();
        return Err(SimulateError::Compile(
            crate::compile_error::CompileError::build_err(format!(
                "observed_field: '{name}' is a bare name and this EsmProblem has {} \
                     components ({}); qualify it as one of: {}",
                components.len(),
                components
                    .iter()
                    .filter(|c| !c.is_empty())
                    .cloned()
                    .collect::<Vec<_>>()
                    .join(", "),
                cands.join(", ")
            )),
        ));
    }
    // An ingested data-fed parameter construction dropped because nothing
    // asked to read it back: say how to ask.
    if !matches!(
        resolve_observed_key(prob.build.dropped_data_fields.iter(), model, single, name),
        NameResolution::Miss
    ) {
        return Err(SimulateError::Compile(
            crate::compile_error::CompileError::build_err(format!(
                "observed_field: '{name}' is a data-fed parameter whose ingested values \
                 this EsmProblem did not keep; name it in \
                 `ProblemOptions::retain_data_fields` to read it back"
            )),
        ));
    }
    let cause = prob
        .build
        .static_eval_error
        .as_deref()
        .map(|e| format!("; evaluating the state-free observed graph failed: {e}"))
        .unwrap_or_default();
    Err(SimulateError::Compile(
        crate::compile_error::CompileError::build_err(format!(
            "observed_field: '{name}' is not a build-time-evaluable observed of this \
             EsmProblem{cause}"
        )),
    ))
}

/// The trajectory of the observed variable `name` over `sol`'s output grid.
///
/// The solution-aware half of [`observed_field`], and the answer to a question
/// neither argument can answer alone. An observed is a pure function of
/// `(state, params, t)`: `prob` holds the function — the topo-sorted observed
/// graph and the parameter bindings — and `sol` holds the arguments. That is
/// why this takes both, and why [`observed_field`] can only ever report fields
/// the BUILD materialized. A [`Solution`] carries state rows only, so an
/// observed of a model that does integrate has no other way out.
///
/// Named `observed_trajectory` rather than being a second arity of
/// `observed_field` because the return RANK differs: a field is the shape the
/// document declares, a trajectory is that shape with a time axis added. Two
/// ranks under one name is a contract a caller cannot read off the call. (A
/// binding that can overload — Julia, Python — may still spell it as an extra
/// arity of `observed_field`; API_SPEC §5.8 records the transliteration.)
///
/// Name resolution is §5.8's rule, the same one [`observed_field`] applies:
/// exact hit, then the component-qualified spelling, then a bare name only when
/// the problem has exactly one component.
///
/// A static problem has no trajectory at all and wants [`observed_field`].
#[cfg(feature = "solve")]
pub fn observed_trajectory(
    prob: &EsmProblem,
    sol: &Solution,
    name: &str,
) -> Result<Vec<f64>, SimulateError> {
    // Re-arm the document's working precision for the duration of this call
    // (`domain.element_type`, esm-spec §11.3); a no-op for a Float64 document.
    let _precision_guard = prob.precision.enter();
    let one = [name.to_string()];
    // The bulk form omits what it cannot resolve; the singular one must not,
    // so an empty result becomes the diagnostic the resolver would have given.
    match observed_trajectories(prob, sol, &one)?.pop() {
        Some((_, values)) => Ok(values),
        None => {
            let declared: Vec<String> = match &*prob.backend {
                // The name resolved to nothing, and the diagnostic has to be
                // built against the runtime's own declared names.
                Backend::Array(c) => c.observed_variable_names(),
                Backend::Static(_) => Vec::new(),
            };
            let model = prob.model_name.as_deref().unwrap_or("");
            Err(
                resolve_observed_name(&declared, model, components_of(&declared, model) == 1, name)
                    .expect_err("resolution failed, or the bulk form would have answered"),
            )
        }
    }
}

/// [`observed_trajectory`] for several names, in ONE pass over the output grid.
///
/// The graph is walked once per output time however many names are asked for,
/// so a caller wanting five observeds should ask once rather than five times.
///
/// **Tolerant where the singular form is strict**, and returns `(name, values)`
/// pairs so a caller can tell which is which. A name that is not an observed
/// variable — most often a STATE, which the caller already has in `sol` — is
/// omitted rather than failing the whole call. That is what a host asking "give
/// me whichever of these are observed" needs: a test harness reading a model's
/// authored assertions knows the variable names but not which kind each is, and
/// one state in the list must not cost it the other four answers.
///
/// The returned names are the spellings that were ASKED FOR, not the resolved
/// ones, so a caller can key its own lookup by them.
#[cfg(feature = "solve")]
pub fn observed_trajectories(
    prob: &EsmProblem,
    sol: &Solution,
    names: &[String],
) -> Result<Vec<(String, Vec<f64>)>, SimulateError> {
    // Re-arm the document's working precision for the duration of this call
    // (`domain.element_type`, esm-spec §11.3); a no-op for a Float64 document.
    let _precision_guard = prob.precision.enter();
    match &*prob.backend {
        // The array runtime has ALREADY materialized its observeds at every
        // saved time — `append_observed_trajectories` appends each 0-D one to
        // the solution as a row beside the states, in the same cell-key
        // spelling — so the answer is a lookup in `sol`, not a second
        // evaluation.
        Backend::Array(c) => array_observed_trajectories(prob, c, sol, names),
        Backend::Static(reason) => Err(SimulateError::NotDynamic {
            details: format!("{reason}; a static document's results are read with observed_field"),
        }),
    }
}

/// [`observed_trajectories`] on the array runtime: read the rows that runtime
/// already appended to `sol`.
///
/// **Not a second evaluation, on purpose.** The array runtime materializes its
/// observeds at every output node during the solve (under `native`, from the
/// tape) and appends each 0-D one to the solution. Re-deriving them here would
/// be exactly the off-tape output-time evaluation `esm-libraries-spec.md`
/// §2.5.10 puts under the refusal — and it would also be a second answer to a
/// question that already has one.
///
/// **Rank.** An ARRAY-valued observed has no scalar trajectory, so it is not
/// answered here. It is reachable — `SolveOptions::output_observed` appends it
/// as one row per cell, named `base[i,j]` — and the diagnostic says so, because
/// a caller who asked for a name that exists deserves the remedy rather than
/// "not an observed variable".
///
/// Tolerant: a name that resolves to no observed is omitted rather than failing
/// the call.
#[cfg(feature = "solve")]
pub(super) fn array_observed_trajectories(
    prob: &EsmProblem,
    compiled: &crate::simulate_array::ArrayCompiled,
    sol: &Solution,
    names: &[String],
) -> Result<Vec<(String, Vec<f64>)>, SimulateError> {
    let declared: Vec<String> = compiled.observed_rule_names().collect();
    let model = prob.model_name.as_deref().unwrap_or("");
    let single = components_of(&declared, model) == 1;
    let mut out = Vec::new();
    for name in names {
        let Ok(resolved) = resolve_observed_name(&declared, model, single, name) else {
            continue;
        };
        match sol.state_variable_names.iter().position(|r| *r == resolved) {
            Some(i) => out.push((name.clone(), sol.state[i].clone())),
            None => {
                return Err(SimulateError::Compile(
                    crate::compile_error::CompileError::build_err(format!(
                        "observed_trajectory: '{name}' is an observed of this EsmProblem but \
                         carries no scalar trajectory — it is array-valued, and the array \
                         runtime appends one row per cell only for an observed the solve was \
                         asked for. Name it in `SolveOptions::output_observed` and read the \
                         `{}[i,j]` rows of the solution.",
                        compiled.shown(&resolved)
                    )),
                ));
            }
        }
    }
    Ok(out)
}

/// §5.8's precedence ([`resolve_observed_key`]), against a flat list of
/// declared observed names.
#[cfg(feature = "solve")]
pub(super) fn resolve_observed_name(
    declared: &[String],
    model: &str,
    single_component: bool,
    name: &str,
) -> Result<String, SimulateError> {
    match resolve_observed_key(declared.iter(), model, single_component, name) {
        NameResolution::Key(k) => Ok(k),
        // A bare name that WOULD have resolved but for the component count gets
        // the remedy in the diagnostic — the author cannot qualify it without
        // being told which spellings exist.
        NameResolution::Ambiguous(matches) => Err(SimulateError::Compile(
            crate::compile_error::CompileError::build_err(format!(
                "observed_trajectory: '{name}' is a bare name and this EsmProblem has {}                          components; qualify it as one of: {}",
                components_of(declared, model),
                matches
                    .iter()
                    .map(|k| qualify(model, k))
                    .collect::<Vec<_>>()
                    .join(", ")
            )),
        )),
        NameResolution::Miss => Err(SimulateError::Compile(
            crate::compile_error::CompileError::build_err(format!(
                "observed_trajectory: '{name}' is not an observed variable of this EsmProblem"
            )),
        )),
    }
}

#[cfg(feature = "solve")]
pub(super) fn components_of(declared: &[String], model: &str) -> usize {
    declared
        .iter()
        .map(|k| component_of(&qualify(model, k)).to_string())
        .collect::<std::collections::BTreeSet<_>>()
        .len()
}
