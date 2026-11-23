//! What the caller supplies for a document's inputs — `p`, const arrays and
//! providers — bound at construction, and the gates that refuse an input
//! nothing supplies.

use super::*;

/// Whether `var` is a parameter with a non-empty declared `shape`.
pub(super) fn is_shaped_parameter(var: &crate::types::ModelVariable) -> bool {
    var.var_type == crate::types::VariableType::Parameter
        && var.shape.as_ref().is_some_and(|s| !s.is_empty())
}

/// Whether every `update` rule of `var` takes its value from outside the model
/// — a data source (`from`) or a registered handler — which is what makes the
/// array runtime serve it from the forcing buffer.
pub(super) fn is_externally_fed(var: &crate::types::ModelVariable) -> bool {
    var.update.as_ref().is_some_and(|spec| {
        spec.rules().iter().all(|rule| {
            rule.value()
                .is_some_and(|v| v.from.is_some() || v.handler.is_some())
        })
    })
}

/// Whether a key of `keys` spells `name`, a compiled or flattened name: the
/// name itself or one of its dotted suffixes (esm-spec §6.6.2,
/// [`crate::simulate::key_spells`]).
pub(super) fn names_key<V>(keys: &HashMap<String, V>, name: &str) -> bool {
    keys.contains_key(name)
        || keys
            .keys()
            .any(|k| crate::simulate::key_spells(k, name, None).is_some())
}

/// The declared variable a compiled or flattened `name` refers to, for a
/// diagnostic: `Model.var` in a top-level model, or a bare name one model
/// declares.
pub(super) fn declared_variable<'f>(
    file: Option<&'f EsmFile>,
    name: &str,
) -> Option<&'f crate::types::ModelVariable> {
    let models = file?.models.as_ref()?;
    if let Some((model, var)) = name.split_once('.')
        && let Some(v) = models.get(model).and_then(|m| m.variables.get(var))
    {
        return Some(v);
    }
    models.values().find_map(|m| m.variables.get(name))
}

/// The `E_TREEWALK_MISSING_DATA` refusal for shaped parameter `name`, naming
/// what the document says feeds it and how a caller supplies it.
pub(super) fn missing_data_error(
    name: &str,
    var: Option<&crate::types::ModelVariable>,
) -> SimulateError {
    let shaped = var.is_some_and(is_shaped_parameter);
    let shape = var
        .and_then(|v| v.shape.as_ref())
        .filter(|s| !s.is_empty())
        .map(|s| format!(" (shape [{}])", s.join(", ")))
        .unwrap_or_default();
    let mut feeds: Vec<String> = Vec::new();
    for rule in var
        .and_then(|v| v.update.as_ref())
        .map(|u| u.rules())
        .unwrap_or_default()
    {
        let Some(value) = rule.value() else { continue };
        if let Some(from) = &value.from {
            feeds.push(format!(
                "the data source '{}' (file_variable '{}')",
                rule.data_source().unwrap_or("?"),
                from.file_variable
            ));
        } else if let Some(h) = &value.handler {
            feeds.push(format!(
                "the registered handler '{}' (update kind '{}'), which writes it only when it fires",
                h.handler_id,
                rule.kind()
            ));
        }
    }
    let (fed, how) = if feeds.is_empty() {
        (
            "Nothing in the document gives it a value.".to_string(),
            if shaped {
                format!(
                    "pass its array in `ProblemOptions::const_arrays` under \"{name}\", or declare \
                     a `default` on it"
                )
            } else {
                format!(
                    "pass it in `ProblemOptions::p` under \"{name}\", or declare a `default` on it"
                )
            },
        )
    } else {
        (
            format!(
                "The document feeds it from {}, and no data for it was supplied at construction.",
                feeds.join(" and ")
            ),
            format!(
                "pass a provider for it in `ProblemOptions::providers` under \"{name}\", or its \
                 array in `ProblemOptions::const_arrays` (a constant snapshot), or declare a \
                 `default` on it"
            ),
        )
    };
    SimulateError::Compile(crate::compile_error::CompileError::MissingData {
        parameter: name.to_string(),
        detail: format!(
            "no data supplied for the {kind}parameter '{name}'{shape}, which declares no \
             `default`. {fed} A parameter with neither a default nor a supplied value is an error \
             when a problem is built (esm-spec §10.10). To supply it, {how}.",
            kind = if shaped { "shaped " } else { "" }
        ),
    })
}

/// The `E_TREEWALK_MISSING_INITIAL_VALUE` refusal: a state slot no default,
/// initial condition, `ic` equation or caller `u0` gives a starting value.
#[cfg(feature = "solve")]
pub(super) fn refuse_missing_initial_values(
    c: &ArrayCompiled,
    u0: &HashMap<String, f64>,
) -> Result<(), SimulateError> {
    let unset = c.unset_initial_slots(u0);
    let Some(first) = unset.first() else {
        return Ok(());
    };
    let mut shown: Vec<String> = unset.iter().take(5).map(|n| format!("'{n}'")).collect();
    if unset.len() > 5 {
        shown.push("…".to_string());
    }
    Err(SimulateError::Compile(
        crate::compile_error::CompileError::MissingInitialValue {
            slot: first.clone(),
            detail: format!(
                "no starting value for {} unknown(s) ({}): the unknown declares no `default`, \
                 and no initial condition, `ic` equation or caller `u0` sets it. An unknown with \
                 no starting value is an error when a problem is built (esm-spec §11.4). To \
                 supply it, pass it in `ProblemOptions::u0` under \"{first}\", or declare a \
                 `default` on the unknown.",
                unset.len(),
                shown.join(", ")
            ),
        },
    ))
}

/// The nested [`crate::types::InlineValue`] an array denotes, row-major — the
/// spelling a shaped parameter's inline `default` takes (esm-spec §6.3).
#[cfg(not(target_arch = "wasm32"))]
pub(super) fn inline_value_of(a: &ArrayD<f64>) -> crate::types::InlineValue {
    use crate::types::InlineValue;
    fn nest(shape: &[usize], values: &[f64]) -> InlineValue {
        let Some((&axis, rest)) = shape.split_first() else {
            return InlineValue::Scalar(values[0]);
        };
        let stride = rest.iter().product::<usize>();
        InlineValue::Array(
            (0..axis)
                .map(|i| nest(rest, &values[i * stride..(i + 1) * stride]))
                .collect(),
        )
    }
    let values: Vec<f64> = a.iter().copied().collect();
    if a.ndim() == 0 {
        return InlineValue::Scalar(values[0]);
    }
    nest(a.shape(), &values)
}

/// The data a caller supplied for a document's shaped parameters, captured at
/// the top of [`esm_problem`] because the build pipeline consumes
/// `const_arrays` and `providers`.
#[derive(Default)]
pub(super) struct SuppliedData {
    /// Each `const_arrays` entry whose key names a shaped parameter of the
    /// document, as `Model.param` or as the bare `param`.
    #[cfg(not(target_arch = "wasm32"))]
    arrays: HashMap<String, ArrayD<f64>>,
    /// The keys of every provider.
    provider_keys: HashMap<String, ()>,
    /// The keys of the providers the build pipeline consumes.
    build_provider_keys: HashMap<String, ()>,
    /// Every `const_arrays` key, sorted, which a run-time provider may not
    /// also feed.
    #[cfg(not(target_arch = "wasm32"))]
    pub(super) const_keys: Vec<String>,
    /// The captured arrays for parameters the document feeds from outside
    /// (a data source or a handler) and no provider serves, keyed
    /// `Model.param`: [`Self::bind_arrays`] routes them to the forcing buffer,
    /// the channel such a parameter is read through, as a constant snapshot.
    #[cfg(not(target_arch = "wasm32"))]
    forcing_arrays: std::cell::RefCell<HashMap<String, ArrayD<f64>>>,
}

impl SuppliedData {
    /// Capture what `opts` supplies. The shaped-parameter arrays are MOVED out
    /// of `opts.const_arrays` when they are the only reason the build pipeline
    /// would run on a document with a right-hand side to compile: they need
    /// nothing from it there (stage 3d binds each onto its parameter).
    /// Otherwise the pipeline keeps them — it evaluates a state-free
    /// document's observed graph with them — and they are copied here.
    pub(super) fn capture(
        opts: &mut ProblemOptions,
        raw: Option<&JsonValue>,
        file: Option<&EsmFile>,
    ) -> Self {
        #[cfg_attr(target_arch = "wasm32", allow(unused_mut))]
        let mut out = SuppliedData::default();
        #[cfg(not(target_arch = "wasm32"))]
        {
            out.provider_keys
                .extend(opts.providers.keys().map(|k| (k.clone(), ())));
            out.const_keys = opts.const_arrays.keys().cloned().collect();
            out.const_keys.sort();
            if !opts.const_arrays.is_empty() {
                let shaped = shaped_parameter_keys(raw, file);
                let only_trigger = raw.is_some_and(declares_derivative)
                    && !opts.build_pipeline
                    && !opts.pushdown_rewrite
                    && opts.const_arrays.keys().all(|k| shaped.contains(k));
                if only_trigger {
                    out.arrays = std::mem::take(&mut opts.const_arrays);
                } else {
                    for (k, a) in &opts.const_arrays {
                        if shaped.contains(k) {
                            out.arrays.insert(k.clone(), a.clone());
                        }
                    }
                }
            }
            // The providers the build pipeline will consume.
            if pipeline_takes_providers(opts) {
                out.build_provider_keys.extend(
                    opts.providers
                        .iter()
                        .filter(|(_, p)| p.refresh_times().is_empty())
                        .map(|(k, _)| (k.clone(), ())),
                );
            }
        }
        #[cfg(target_arch = "wasm32")]
        let _ = (opts, raw, file);
        out
    }

    /// Bind each captured array to the shaped parameter it names — keyed
    /// `Model.param`, or by a bare name only one model's shaped parameter
    /// carries. A scalar override in `p` outranks it, and so does a provider
    /// for a parameter the document feeds from outside. Otherwise it becomes
    /// the parameter's inline `default`, or, for a parameter fed from outside,
    /// a constant snapshot in the forcing buffer (served by
    /// [`Self::refuse_missing_array`]). Answers whether it changed a
    /// declaration of `file`.
    #[cfg(not(target_arch = "wasm32"))]
    pub(super) fn bind_arrays(
        &self,
        file: &mut EsmFile,
        p: &HashMap<String, f64>,
        selected: Option<&str>,
    ) -> bool {
        let mut bound = false;
        if self.arrays.is_empty() {
            return bound;
        }
        let Some(models) = file.models.as_mut() else {
            return bound;
        };
        // With one model selected, a bare key names that model's parameter;
        // the other models are not built, so they cannot make it ambiguous.
        let in_scope = |mname: &str| selected.is_none_or(|s| s == mname);
        let mut owners: HashMap<String, usize> = HashMap::new();
        for (_, m) in models.iter().filter(|(n, _)| in_scope(n)) {
            for (v, var) in &m.variables {
                if is_shaped_parameter(var) {
                    *owners.entry(v.clone()).or_default() += 1;
                }
            }
        }
        for (mname, m) in models.iter_mut() {
            if !in_scope(mname) {
                continue;
            }
            for (v, var) in m.variables.iter_mut() {
                if !is_shaped_parameter(var) {
                    continue;
                }
                let qualified = format!("{mname}.{v}");
                let arr = self.arrays.get(&qualified).or_else(|| {
                    if owners.get(v) == Some(&1) {
                        self.arrays.get(v)
                    } else {
                        None
                    }
                });
                let Some(arr) = arr else { continue };
                if p.contains_key(&qualified) || p.contains_key(v) {
                    continue;
                }
                if is_externally_fed(var) {
                    if !names_key(&self.provider_keys, &qualified) {
                        self.forcing_arrays
                            .borrow_mut()
                            .insert(qualified, arr.clone());
                    }
                    continue;
                }
                var.default = Some(inline_value_of(arr));
                bound = true;
            }
        }
        bound
    }

    /// The missing-data gate for an array model: serve a forcing name no
    /// provider supplies from the caller's array, else from its declared
    /// `default`, and refuse one with neither, or a shaped parameter the build
    /// left with no value at all.
    pub(super) fn refuse_missing_array(
        &self,
        c: &ArrayCompiled,
        file: Option<&EsmFile>,
        p: &HashMap<String, f64>,
        routed: &HashMap<String, String>,
        ingested: &mut HashMap<String, ArrayD<f64>>,
        retained: &std::collections::HashSet<String>,
    ) -> Result<(), SimulateError> {
        let forcing = c.forcing_handle();
        for name in c.forcing_names() {
            if forcing.borrow().contains_key(name) {
                continue;
            }
            // What the BUILD pipeline's providers ingested for this data-fed
            // parameter. A build provider is consumed by the pipeline and never
            // reaches the run-time binding above, so without this an
            // integrating document read the parameter's `default` in its
            // right-hand side while its build-time observeds read the data
            // (finding F43). The pipeline keys model-locally, so a name the
            // compile spelled under its namespace is matched with THAT prefix
            // removed — never any other leading segment, which would hand a
            // mounted `Leaf.p` (or another component's `B.p`) this model's `p`.
            // MOVED, not copied, unless the caller also reads it back.
            let key = if ingested.contains_key(name) {
                Some(name.clone())
            } else {
                c.namespace()
                    .and_then(|ns| name.strip_prefix(ns))
                    .and_then(|rest| rest.strip_prefix('.'))
                    .filter(|local| ingested.contains_key(*local))
                    .map(str::to_string)
            };
            if let Some(key) = key {
                let arr = if retained.contains(&key) {
                    ingested[&key].clone()
                } else {
                    ingested.remove(&key).expect("checked above")
                };
                forcing.borrow_mut().insert(name.clone(), arr);
                continue;
            }
            // A run-time provider feeds it (`routed` is keyed by the compiled
            // name each one writes), or a build-time provider does.
            if routed.contains_key(name) || names_key(&self.build_provider_keys, name) {
                continue;
            }
            #[cfg(not(target_arch = "wasm32"))]
            if let Some(arr) = self.forcing_array(name) {
                forcing.borrow_mut().insert(name.clone(), arr);
                continue;
            }
            // No data is supplied: a declared default is the value (esm-spec
            // §6.3), and with none the parameter is missing data (§10.10).
            let value = match declared_default_forcing(c, name) {
                None => {
                    return Err(missing_data_error(name, declared_variable(file, name)));
                }
                // A default over a shape that does not resolve yet (an
                // unmaterialized derived set) has no field to fill here.
                Some(None) => continue,
                Some(Some(value)) => value,
            };
            forcing.borrow_mut().insert(name.clone(), value);
        }
        for name in c.unvalued_shaped_params() {
            if !names_key(p, name) {
                return Err(missing_data_error(name, declared_variable(file, name)));
            }
        }
        // A scalar parameter no default, caller `p` or `distribution` gives a
        // value (esm-spec §10.10).
        for name in c.unsupplied_params(p) {
            let var = declared_variable(file, &name);
            if c.unvalued_shaped_params().contains(&name)
                || var.is_some_and(|v| v.distribution.is_some())
            {
                continue;
            }
            return Err(missing_data_error(&name, var));
        }
        Ok(())
    }

    /// The captured snapshot for forcing name `name`, a compiled name: the one
    /// the caller keyed by that name, else the only one keyed by a dotted
    /// suffix of it ([`crate::simulate::key_spells`]).
    #[cfg(not(target_arch = "wasm32"))]
    fn forcing_array(&self, name: &str) -> Option<ArrayD<f64>> {
        let arrays = self.forcing_arrays.borrow();
        if let Some(a) = arrays.get(name) {
            return Some(a.clone());
        }
        let mut spelled = arrays
            .iter()
            .filter(|(k, _)| crate::simulate::key_spells(k, name, None).is_some());
        match (spelled.next(), spelled.next()) {
            (Some((_, a)), None) => Some(a.clone()),
            _ => None,
        }
    }

    /// The missing-data gate for a document with nothing to integrate, read
    /// off its flattened parameters (coupling may bind a declared parameter to
    /// another component's variable, and then it needs no value of its own).
    /// Flattens only when some parameter declares no value.
    pub(super) fn refuse_missing_static(
        &self,
        file: &EsmFile,
        flattened: Option<&FlattenedSystem>,
        p: &HashMap<String, f64>,
        selected: Option<&str>,
    ) -> Result<(), SimulateError> {
        let unvalued = |v: &crate::types::ModelVariable| {
            v.var_type == crate::types::VariableType::Parameter
                && v.default.is_none()
                && v.distribution.is_none()
        };
        let any = file
            .models
            .as_ref()
            .is_some_and(|ms| ms.values().any(|m| m.variables.values().any(unvalued)));
        if !any {
            return Ok(());
        }
        let owned;
        let flat = match flattened {
            Some(flat) => flat,
            None => match crate::flatten::flatten(file) {
                Ok(flat) => {
                    owned = flat;
                    &owned
                }
                Err(_) => return Ok(()),
            },
        };
        for (name, var) in &flat.parameters {
            if !unvalued(var) || names_key(p, name) {
                continue;
            }
            // With one model selected, only its parameters are built.
            if selected.is_some_and(|m| !name.starts_with(&format!("{m}."))) {
                continue;
            }
            if is_externally_fed(var) && names_key(&self.provider_keys, name) {
                continue;
            }
            return Err(missing_data_error(name, Some(var)));
        }
        Ok(())
    }
}

/// Set each 0-D parameter a value-invention node reads (inside a `distinct` /
/// keyed `faq`) to the caller's
/// `p` entry for it — keyed `Model.param` or bare — and return the `p` keys
/// used.
pub(super) fn bind_value_invention_params(
    file: &mut EsmFile,
    p: &HashMap<String, f64>,
) -> Vec<String> {
    use crate::types::Expr;
    use std::collections::HashSet;
    fn collect(e: &Expr, inside: bool, out: &mut HashSet<String>) {
        match e {
            Expr::Variable(v) if inside => {
                out.insert(v.clone());
            }
            Expr::Operator(n) => {
                let vi = inside || n.distinct == Some(true) || n.key.is_some();
                n.for_each_child(&mut |c| collect(c, vi, out));
            }
            _ => {}
        }
    }
    let mut used = Vec::new();
    if p.is_empty() {
        return used;
    }
    let Some(models) = file.models.as_mut() else {
        return used;
    };
    for (mname, m) in models.iter_mut() {
        let mut read: HashSet<String> = HashSet::new();
        for eq in &m.equations {
            collect(&eq.rhs, false, &mut read);
        }
        for (v, var) in m.variables.iter_mut() {
            if var.var_type != crate::types::VariableType::Parameter
                || var.shape.as_ref().is_some_and(|s| !s.is_empty())
                || !read.contains(v)
            {
                continue;
            }
            let qualified = format!("{mname}.{v}");
            let key = if p.contains_key(&qualified) {
                qualified
            } else if p.contains_key(v) {
                v.clone()
            } else {
                continue;
            };
            var.default = Some(crate::types::InlineValue::Scalar(p[&key]));
            used.push(key);
        }
    }
    used
}

/// Bake every scalar parameter a join key column or an overlap envelope
/// factor reads ([`crate::join::join_key_parameters`], which follows the
/// cone across components): a caller's `p` entry lands on its `default`,
/// which the build folds into the match set, and the parameter is recorded —
/// under both its model-qualified and its bare name, whichever a later
/// [`remake`] spells — so a substitution of it is refused. Baked whether or
/// not the caller passed a value: the declared default is a build-time value
/// just the same.
pub(super) fn bind_join_key_params(file: &mut EsmFile, p: &HashMap<String, f64>) -> Vec<String> {
    let mut baked = Vec::new();
    let Some(models) = file.models.as_mut() else {
        return baked;
    };
    for (mname, v) in crate::join::join_key_parameters(models) {
        let qualified = format!("{mname}.{v}");
        if let Some(&x) = p.get(&qualified).or_else(|| p.get(&v))
            && let Some(var) = models.get_mut(&mname).and_then(|m| m.variables.get_mut(&v))
        {
            var.default = Some(crate::types::InlineValue::Scalar(x));
        }
        baked.push(qualified);
        baked.push(v);
    }
    baked
}

/// Whether any equation of the raw document has a time derivative on its
/// left-hand side, or the document holds a reaction system: a document with a
/// right-hand side to compile, whose caller arrays the compile binds itself.
#[cfg(not(target_arch = "wasm32"))]
pub(super) fn declares_derivative(raw: &JsonValue) -> bool {
    fn has_d(v: &JsonValue) -> bool {
        match v {
            JsonValue::Object(o) => {
                o.get("op").and_then(JsonValue::as_str) == Some("D") || o.values().any(has_d)
            }
            JsonValue::Array(a) => a.iter().any(has_d),
            _ => false,
        }
    }
    if raw
        .get("reaction_systems")
        .and_then(JsonValue::as_object)
        .is_some_and(|r| !r.is_empty())
    {
        return true;
    }
    raw.get("models")
        .and_then(JsonValue::as_object)
        .is_some_and(|ms| {
            ms.values().any(|m| {
                m.get("equations")
                    .and_then(JsonValue::as_array)
                    .is_some_and(|eqs| eqs.iter().any(|e| e.get("lhs").is_some_and(has_d)))
            })
        })
}

/// Every name a caller's `const_arrays` key may use for a shaped parameter of
/// the document: `Model.param` and the bare `param`, read off the raw JSON when
/// there is one and the typed document otherwise.
#[cfg(not(target_arch = "wasm32"))]
pub(super) fn shaped_parameter_keys(
    raw: Option<&JsonValue>,
    file: Option<&EsmFile>,
) -> std::collections::HashSet<String> {
    let mut out = std::collections::HashSet::new();
    if let Some(models) = raw
        .and_then(|v| v.get("models"))
        .and_then(JsonValue::as_object)
    {
        for (m, model) in models {
            let Some(vars) = model.get("variables").and_then(JsonValue::as_object) else {
                continue;
            };
            for (v, var) in vars {
                let shaped = var
                    .get("shape")
                    .and_then(JsonValue::as_array)
                    .is_some_and(|s| !s.is_empty());
                if shaped && var.get("type").and_then(JsonValue::as_str) == Some("parameter") {
                    out.insert(format!("{m}.{v}"));
                    out.insert(v.clone());
                }
            }
        }
    } else if let Some(models) = file.and_then(|f| f.models.as_ref()) {
        for (m, model) in models {
            for (v, var) in &model.variables {
                if is_shaped_parameter(var) {
                    out.insert(format!("{m}.{v}"));
                    out.insert(v.clone());
                }
            }
        }
    }
    out
}

/// The declared shape of the forcing parameter each provider key feeds, for
/// the keys whose shape is known. The keys are the compiled names
/// `bind_providers` routed them onto (esm-spec §6.6.2), so each is looked up
/// as it is spelled. A key naming no forcing parameter, or one whose declared
/// shape names an index set the registry cannot size, is left out and its
/// samples are not shape-checked.
#[cfg(not(target_arch = "wasm32"))]
pub(super) fn provider_declared_shapes<'a>(
    compiled: &crate::simulate_array::ArrayCompiled,
    keys: impl Iterator<Item = &'a String>,
) -> std::collections::HashMap<String, Vec<usize>> {
    let decls = compiled.declared_forcing_shapes();
    keys.filter_map(|key| Some((key.clone(), decls.get(key.as_str())?.clone()?)))
        .collect()
}

/// The names a `variable_map` coupling of `file` reads (its `from`
/// endpoints): a run-time provider keyed by one of them keeps its own name
/// rather than being routed onto a parameter it is a suffix of.
#[cfg(not(target_arch = "wasm32"))]
pub(super) fn coupling_reads(file: Option<&EsmFile>) -> std::collections::HashSet<String> {
    file.and_then(|f| f.coupling.as_ref())
        .into_iter()
        .flatten()
        .filter_map(|c| match c {
            crate::types::CouplingEntry::VariableMap { from, .. } => Some(from.clone()),
            _ => None,
        })
        .collect()
}

#[cfg(not(target_arch = "wasm32"))]
#[allow(clippy::type_complexity)]
pub(super) fn bind_providers(
    backend: &Backend,
    opts: &mut ProblemOptions,
    tspan: (f64, f64),
    const_keys: &[String],
    keep: &std::collections::HashSet<String>,
) -> Result<
    (
        Option<SharedRefresh>,
        std::collections::HashSet<String>,
        Vec<f64>,
        HashMap<String, String>,
    ),
    SimulateError,
> {
    if opts.providers.is_empty() {
        return Ok((None, Default::default(), Vec::new(), HashMap::new()));
    }
    let Backend::Array(compiled) = backend else {
        // Providers feed loader fields, which only exist on the array/spatial
        // runtime; a pure-scalar or static document has nowhere to put them.
        let name = opts.providers.keys().next().cloned().unwrap_or_default();
        return Err(SimulateError::ProviderError {
            name,
            details: "providers require an array/spatial model (this document has none)"
                .to_string(),
        });
    };

    // Each provider writes its field under the compiled name of the
    // parameter its key designates (esm-spec §6.6.2), so the Problem and
    // `rhs_program` see its data rather than the declared default beside it.
    // An exact key wins over an alias for the same parameter, whose provider
    // is not read; any other key is used as given.
    let resolver = compiled.parameter_key_resolver();
    let mut keys: Vec<String> = opts.providers.keys().cloned().collect();
    keys.sort();
    let routing = resolver
        .route(keys.iter().map(String::as_str), keep)
        .map_err(provider_key_error)?;
    refuse_provider_const_overlap(
        |k: &str| resolver.resolve(k, keep),
        &routing.targets,
        const_keys,
    )?;
    let mut providers: HashMap<String, Box<dyn crate::provider::DataProvider>> = HashMap::new();
    let mut given: HashMap<String, String> = HashMap::new();
    for key in keys {
        let provider = opts.providers.remove(&key).expect("a key of the map");
        if routing.shadowed.contains(&key) {
            continue;
        }
        // A key that designates no parameter feeds the name it spells: in a
        // one-model document, that name under the model, as `flatten` names
        // an undeclared field the model reads.
        let target =
            routing
                .targets
                .get(&key)
                .cloned()
                .unwrap_or_else(|| match compiled.namespace() {
                    Some(ns) if !key.contains('.') => qualify(ns, &key),
                    _ => key.clone(),
                });
        if let Some(other) = given.insert(target.clone(), key.clone()) {
            // An unrouted key that is spelled as another key's target.
            return Err(SimulateError::ProviderError {
                details: format!("providers `{other}` and `{key}` both feed `{target}`; pass one"),
                name: key,
            });
        }
        providers.insert(target, provider);
    }

    // One RefreshExecutor, classifying each provider by its `refresh_times()`.
    // CONST forcings are materialized ONCE, HERE — at construction, which is
    // where §2.5.2 puts the gated fetch — and never again.
    let declared = provider_declared_shapes(compiled, providers.keys());
    let mut exec =
        crate::provider::RefreshExecutor::from_providers_with_shapes(providers, &declared, &given);
    exec.set_precision(&precision::Env::capture());
    let forcing = compiled.forcing_handle();
    exec.materialize_const_named(&forcing)
        .map_err(|e| loader_error(&given, e))?;

    let discrete: std::collections::HashSet<String> = exec
        .bindings()
        .filter(|b| b.cadence == crate::cadence::Cadence::Discrete)
        .flat_map(|b| b.variables)
        .collect();

    // Every refresh time inside the span is a segment boundary, including one
    // at or before an explicit `sample_time`: the construction sample is the
    // Problem's starting forcing, not where a solve starts refreshing.
    let mut boundaries: Vec<f64> = exec.refresh_times();
    boundaries.retain(|&b| b > tspan.0 && b < tspan.1);

    Ok((
        Some(Rc::new(std::cell::RefCell::new(exec))),
        discrete,
        boundaries,
        given,
    ))
}

/// The bound run-time providers of a Problem, shared by the Problems
/// [`remake`] derives from it: they read the same forcing buffer, and the
/// providers are not fetched again (§2.5.5).
#[cfg(not(target_arch = "wasm32"))]
pub(crate) type SharedRefresh = Rc<std::cell::RefCell<crate::provider::RefreshExecutor>>;

/// A provider failure as a [`SimulateError::ProviderError`] naming the
/// provider by the key the caller passed it under (`given` maps the forcing
/// name it feeds back to that key).
#[cfg(not(target_arch = "wasm32"))]
pub(super) fn loader_error(
    given: &HashMap<String, String>,
    e: crate::provider::LoaderError,
) -> SimulateError {
    SimulateError::ProviderError {
        name: given.get(&e.loader).cloned().unwrap_or(e.loader),
        details: e.error.to_string(),
    }
}

/// A provider key the §6.6.2 rules cannot route, as a
/// [`SimulateError::ProviderError`].
#[cfg(not(target_arch = "wasm32"))]
pub(crate) fn provider_key_error(e: crate::simulate::OverrideKeyError) -> SimulateError {
    use crate::simulate::OverrideKeyError;
    match e {
        OverrideKeyError::Ambiguous { key, candidates } => SimulateError::ProviderError {
            details: format!(
                "ambiguous parameter name: it is carried as a suffix by {} parameters ({}); \
                 qualify it further with its owning component (esm-spec §6.6.2)",
                candidates.len(),
                candidates.join(", ")
            ),
            name: key,
        },
        OverrideKeyError::Collision { name, keys } => SimulateError::ProviderError {
            details: format!(
                "providers {} all designate the parameter `{name}`; pass exactly one \
                 (esm-spec §6.6.2)",
                keys.iter()
                    .map(|k| format!("`{k}`"))
                    .collect::<Vec<_>>()
                    .join(", ")
            ),
            name: keys.into_iter().next().unwrap_or_default(),
        },
        OverrideKeyError::Unknown(name) => SimulateError::ProviderError {
            details: "designates no parameter".to_string(),
            name,
        },
    }
}

/// Refuse a provider routed onto a parameter a `const_arrays` entry also
/// supplies, under any spelling of it (esm-spec §6.6.2): two sources for one
/// value. A `const_arrays` key two parameters carry, one of them provider-fed,
/// is refused as ambiguous. The counterpart of Julia's
/// `_refuse_provider_registry_overlap`.
///
/// `targets` maps each provider key to the parameter it designates, and
/// `resolve` says what a `const_arrays` key designates, in the same names.
#[cfg(not(target_arch = "wasm32"))]
pub(super) fn refuse_provider_const_overlap(
    resolve: impl Fn(&str) -> crate::simulate::KeyHit,
    targets: &HashMap<String, String>,
    const_keys: &[String],
) -> Result<(), SimulateError> {
    use crate::simulate::KeyHit;
    if targets.is_empty() || const_keys.is_empty() {
        return Ok(());
    }
    let mut fed: HashMap<&str, &str> = HashMap::new();
    for (key, target) in targets {
        fed.insert(target.as_str(), key.as_str());
    }
    for rk in const_keys {
        match resolve(rk) {
            KeyHit::Exact(name) | KeyHit::Alias(name) => {
                if let Some(pk) = fed.get(name.as_str()) {
                    return Err(SimulateError::ProviderError {
                        name: (*pk).to_string(),
                        details: format!(
                            "providers[`{pk}`] and const_arrays[`{rk}`] both supply the \
                             parameter `{name}`; pass one of them (esm-spec §6.6.2)"
                        ),
                    });
                }
            }
            KeyHit::Ambiguous(cands) => {
                if let Some(pk) = cands.iter().find_map(|c| fed.get(c.as_str())) {
                    return Err(SimulateError::ProviderError {
                        name: pk.to_string(),
                        details: format!(
                            "const_arrays[`{rk}`] is ambiguous: it is carried as a suffix by \
                             {} parameters ({}), one of them fed by this provider; qualify it \
                             further with its owning component (esm-spec §6.6.2)",
                            cands.len(),
                            cands.join(", ")
                        ),
                    });
                }
            }
            KeyHit::Unknown => {}
        }
    }
    Ok(())
}

/// [`refuse_provider_const_overlap`] for the CONST providers the build
/// pipeline consumes, which never reach [`bind_providers`]. Keys resolve
/// against the parameters `raw` declares, by their flattened names
/// (`Model.param`, `Model.sub.param`).
#[cfg(not(target_arch = "wasm32"))]
pub(super) fn refuse_pipeline_provider_const_overlap(
    raw: &JsonValue,
    opts: &ProblemOptions,
    const_keys: &[String],
) -> Result<(), SimulateError> {
    use crate::simulate::KeyHit;
    if const_keys.is_empty() || !pipeline_takes_providers(opts) {
        return Ok(());
    }
    let consumed: Vec<&String> = opts
        .providers
        .iter()
        .filter(|(_, p)| p.refresh_times().is_empty())
        .map(|(k, _)| k)
        .collect();
    if consumed.is_empty() {
        return Ok(());
    }
    let names = declared_parameter_names(raw);
    let known = crate::simulate::SuffixIndex::new(names.iter().map(String::as_str));
    let namespaces = crate::simulate::namespace_scope(names.iter().map(String::as_str), []);
    let resolve = |k: &str| crate::simulate::resolve_key(&known, &namespaces, k);
    let targets: HashMap<String, String> = consumed
        .into_iter()
        .filter_map(|k| match resolve(k) {
            KeyHit::Exact(n) | KeyHit::Alias(n) => Some((k.clone(), n)),
            KeyHit::Ambiguous(_) | KeyHit::Unknown => None,
        })
        .collect();
    refuse_provider_const_overlap(resolve, &targets, const_keys)
}

/// The flattened name of every parameter `raw` declares: a model's
/// `parameter` variables and a reaction system's `parameters`, in every
/// inline subsystem.
#[cfg(not(target_arch = "wasm32"))]
pub(super) fn declared_parameter_names(raw: &JsonValue) -> Vec<String> {
    fn visit(node: &JsonValue, prefix: &str, out: &mut Vec<String>) {
        if let Some(vars) = node.get("variables").and_then(JsonValue::as_object) {
            for (v, var) in vars {
                if var.get("type").and_then(JsonValue::as_str) == Some("parameter") {
                    out.push(format!("{prefix}.{v}"));
                }
            }
        }
        if let Some(params) = node.get("parameters").and_then(JsonValue::as_object) {
            out.extend(params.keys().map(|p| format!("{prefix}.{p}")));
        }
        if let Some(subs) = node.get("subsystems").and_then(JsonValue::as_object) {
            for (s, sub) in subs {
                visit(sub, &format!("{prefix}.{s}"), out);
            }
        }
    }
    let mut out = Vec::new();
    for section in ["models", "reaction_systems"] {
        if let Some(components) = raw.get(section).and_then(JsonValue::as_object) {
            for (name, component) in components {
                visit(component, name, &mut out);
            }
        }
    }
    out
}

/// Sample the DISCRETE providers at construction, at `sample_time`
/// (esm-libraries-spec §2.5.2: providers are sampled at construction), so the
/// Problem's forcing holds their data from the start, as Julia's does, and
/// `rhs_program`'s default forcing set (a copy of that forcing) holds it too.
///
/// Runs after every construction gate, so a Problem refused for another reason
/// fetches nothing. Each provider gives the record in effect at
/// `sample_time` ([`crate::provider::RefreshExecutor::sample_at`]). A
/// parameter whose provider delivers nothing there holds its declared default
/// (esm-spec §6.3) until the provider first delivers; see
/// [`seed_vacant_discrete`].
#[cfg(not(target_arch = "wasm32"))]
pub(super) fn sample_discrete_providers(
    compiled: &ArrayCompiled,
    exec: &SharedRefresh,
    discrete: &std::collections::HashSet<String>,
    sample_time: f64,
    given: &HashMap<String, String>,
) -> Result<(), SimulateError> {
    if discrete.is_empty() {
        return Ok(());
    }
    let forcing = compiled.forcing_handle();
    let mut written = Vec::new();
    let mut vacant = exec
        .borrow_mut()
        .sample_in_effect(sample_time, &forcing, &mut written)
        .map_err(|e| loader_error(given, e))?;
    // A provider that answered "unchanged" at its own refresh time has
    // delivered nothing yet at construction either.
    let mut empty: Vec<String> = discrete
        .iter()
        .filter(|n| !forcing.borrow().contains_key(*n))
        .cloned()
        .collect();
    vacant.append(&mut empty);
    vacant.sort();
    vacant.dedup();
    seed_vacant_discrete(
        compiled,
        &vacant,
        given,
        "sample_time",
        sample_time,
        &mut forcing.borrow_mut(),
    )
}

/// The DISCRETE-fed fields an `ic` right-hand side reads, at `t0`, the start
/// of the run (esm-spec §11.4.2), in a buffer of their own: each provider's
/// record in effect at `t0`, else the declared default (as a solve's start
/// gives it). Only the providers feeding a field the `ic` right-hand sides
/// read are asked, and the Problem's forcing is not written
/// ([`crate::provider::RefreshExecutor::sample_detached`]).
#[cfg(all(feature = "solve", not(target_arch = "wasm32")))]
pub(super) fn discrete_at_start(
    compiled: &ArrayCompiled,
    exec: &SharedRefresh,
    read: &std::collections::HashSet<String>,
    t0: f64,
    given: &HashMap<String, String>,
) -> Result<HashMap<String, ndarray::ArrayD<f64>>, SimulateError> {
    let (mut out, vacant) = exec
        .borrow_mut()
        .sample_detached(t0, read, &compiled.forcing_handle())
        .map_err(|e| loader_error(given, e))?;
    seed_vacant_discrete(
        compiled,
        &vacant,
        given,
        "the start of the run",
        t0,
        &mut out,
    )?;
    Ok(out)
}

/// Give each DISCRETE-fed name in `vacant` (no record in effect at `t`) its
/// declared default (esm-spec §6.3) in `target`: the Problem's forcing
/// buffer, or a buffer of its own. Only a parameter the model reads from the
/// forcing buffer is required to have a value: one that declares no default
/// is refused (§10.10), naming the provider by the caller's key. A name the
/// model does not read as a forcing parameter is left as it is.
#[cfg(not(target_arch = "wasm32"))]
pub(super) fn seed_vacant_discrete(
    compiled: &ArrayCompiled,
    vacant: &[String],
    given: &HashMap<String, String>,
    at: &str,
    t: f64,
    target: &mut HashMap<String, ArrayD<f64>>,
) -> Result<(), SimulateError> {
    for name in vacant {
        if !compiled.serves_forcing(name) {
            continue;
        }
        match declared_default_forcing(compiled, name) {
            Some(Some(value)) => {
                target.insert(name.clone(), value);
            }
            // A default over a shape that does not resolve yet has no field
            // to fill here, as in the missing-data gate.
            Some(None) => {}
            None => {
                let key = given.get(name).map_or(name.as_str(), String::as_str);
                return Err(SimulateError::ProviderError {
                    name: key.to_string(),
                    details: format!(
                        "the provider has no record in effect at {at} {t} (it delivered \
                         nothing there, nor at a refresh time before it), and the parameter \
                         `{name}` it feeds declares no default"
                    ),
                });
            }
        }
    }
    Ok(())
}

/// The declared default of forcing slot `name` broadcast over its shape and
/// rounded to the slot's precision: `None` with no default, `Some(None)` for a
/// shape that does not resolve yet.
pub(super) fn declared_default_forcing(
    c: &ArrayCompiled,
    name: &str,
) -> Option<Option<ArrayD<f64>>> {
    let mut value = c.forcing_default(name)?;
    if let Some(value) = value.as_mut() {
        let prec = precision::of_variable(name);
        if prec.is_f32() {
            value.mapv_inplace(|x| prec.round(x));
        }
    }
    Some(value)
}
