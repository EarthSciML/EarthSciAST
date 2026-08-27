//! WASM bindings for earthsci-ast
//!
//! This module provides WebAssembly bindings for use with TypeScript/JavaScript.

#[cfg(feature = "wasm")]
use crate::{
    EsmFile, graph::component_graph as rust_component_graph, load_string as rust_load_string,
    performance::CompactExpr, stoichiometric_matrix, substitute_in_model,
    substitute_in_reaction_system, to_json as rust_to_json, validate as rust_validate,
};
#[cfg(feature = "wasm")]
use wasm_bindgen::prelude::*;

/// Serialize any `Serialize` value to a plain JS object (never an ES `Map`),
/// so JS callers get uniform dot-access across every export. All exports go
/// through this one helper — previously some returned `Map`s and some plain
/// objects depending on which serializer they used.
#[cfg(feature = "wasm")]
fn to_js<T: serde::Serialize>(value: &T) -> Result<JsValue, JsValue> {
    let serializer = serde_wasm_bindgen::Serializer::new().serialize_maps_as_objects(true);
    value
        .serialize(&serializer)
        .map_err(|e| JsValue::from_str(&format!("Serialization error: {e}")))
}

/// Render every model equation and reaction rate of a loaded file with one of
/// the real expression pretty-printers from [`crate::display`] (the same ones
/// the CLI `pretty` command uses).
#[cfg(feature = "wasm")]
fn render_expressions(esm_file: &EsmFile, render: fn(&crate::Expr) -> String) -> String {
    let mut out = String::new();
    if let Some(models) = &esm_file.models {
        let mut ids: Vec<&String> = models.keys().collect();
        ids.sort();
        for model_id in ids {
            out.push_str(&format!("Model: {model_id}\n"));
            for (i, eq) in models[model_id].equations.iter().enumerate() {
                out.push_str(&format!(
                    "  Eq {}: {} = {}\n",
                    i + 1,
                    render(&eq.lhs),
                    render(&eq.rhs)
                ));
            }
        }
    }
    if let Some(reaction_systems) = &esm_file.reaction_systems {
        let mut ids: Vec<&String> = reaction_systems.keys().collect();
        ids.sort();
        for rs_id in ids {
            out.push_str(&format!("Reaction System: {rs_id}\n"));
            for (i, reaction) in reaction_systems[rs_id].reactions.iter().enumerate() {
                out.push_str(&format!(
                    "  Reaction {}: rate = {}\n",
                    i + 1,
                    render(&reaction.rate)
                ));
            }
        }
    }
    out
}

/// Load an ESM file from JSON string (WASM version)
#[cfg(feature = "wasm")]
#[wasm_bindgen]
pub fn load_string(json_str: &str) -> Result<JsValue, JsValue> {
    let esm_file =
        rust_load_string(json_str).map_err(|e| JsValue::from_str(&format!("Load error: {e}")))?;
    to_js(&esm_file)
}

/// Serialize an ESM file to a JSON string (WASM version)
#[cfg(feature = "wasm")]
#[wasm_bindgen]
pub fn to_json(esm_file_js: &JsValue) -> Result<String, JsValue> {
    let esm_file: EsmFile = serde_wasm_bindgen::from_value(esm_file_js.clone())
        .map_err(|e| JsValue::from_str(&format!("Deserialization error: {e}")))?;

    match rust_to_json(&esm_file) {
        Ok(json) => Ok(json),
        Err(e) => Err(JsValue::from_str(&format!("Save error: {e}"))),
    }
}

/// Validate an ESM file (WASM version)
#[cfg(feature = "wasm")]
#[wasm_bindgen]
pub fn validate(json_str: &str) -> Result<JsValue, JsValue> {
    let esm_file =
        rust_load_string(json_str).map_err(|e| JsValue::from_str(&format!("Parse error: {e}")))?;

    let result = rust_validate(&esm_file);
    to_js(&result)
}

/// Pretty-print every equation and reaction rate with the Unicode expression
/// printer ([`crate::display::to_unicode`]) — the same renderer the CLI's
/// `pretty` command uses. (Earlier versions returned a metadata summary
/// instead of rendered math.)
#[cfg(feature = "wasm")]
#[wasm_bindgen]
pub fn to_unicode(json_str: &str) -> Result<String, JsValue> {
    let esm_file =
        rust_load_string(json_str).map_err(|e| JsValue::from_str(&format!("Parse error: {e}")))?;
    Ok(render_expressions(&esm_file, crate::display::to_unicode))
}

/// Pretty-print every equation and reaction rate with the LaTeX expression
/// printer ([`crate::display::to_latex`]).
#[cfg(feature = "wasm")]
#[wasm_bindgen]
pub fn to_latex(json_str: &str) -> Result<String, JsValue> {
    let esm_file =
        rust_load_string(json_str).map_err(|e| JsValue::from_str(&format!("Parse error: {e}")))?;
    Ok(render_expressions(&esm_file, crate::display::to_latex))
}

/// Pretty-print every equation and reaction rate with the ASCII expression
/// printer ([`crate::display::to_ascii`]) — pure-ASCII output, unlike the
/// Unicode renderer.
#[cfg(feature = "wasm")]
#[wasm_bindgen]
pub fn to_ascii(json_str: &str) -> Result<String, JsValue> {
    let esm_file =
        rust_load_string(json_str).map_err(|e| JsValue::from_str(&format!("Parse error: {e}")))?;
    Ok(render_expressions(&esm_file, crate::display::to_ascii))
}

/// Substitute expressions in ESM file (WASM version)
#[cfg(feature = "wasm")]
#[wasm_bindgen]
pub fn substitute(json_str: &str, bindings_str: &str) -> Result<String, JsValue> {
    use crate::Expr;

    let esm_file =
        rust_load_string(json_str).map_err(|e| JsValue::from_str(&format!("Parse error: {e}")))?;

    // Parse bindings as JSON object
    let bindings: serde_json::Value = serde_json::from_str(bindings_str)
        .map_err(|e| JsValue::from_str(&format!("Bindings parse error: {e}")))?;

    // Convert bindings to Expr objects
    let mut expr_bindings = std::collections::HashMap::new();
    if let serde_json::Value::Object(obj) = bindings {
        for (key, value) in obj {
            let expr = match value {
                serde_json::Value::Number(n) => {
                    if let Some(f) = n.as_f64() {
                        Expr::Number(f)
                    } else {
                        return Err(JsValue::from_str(&format!(
                            "Invalid number in bindings: {n}"
                        )));
                    }
                }
                serde_json::Value::String(s) => {
                    // Try to parse as number first, otherwise treat as variable
                    if let Ok(f) = s.parse::<f64>() {
                        Expr::Number(f)
                    } else {
                        Expr::Variable(s)
                    }
                }
                _ => {
                    return Err(JsValue::from_str(&format!(
                        "Unsupported binding type for key '{key}': {value:?}"
                    )));
                }
            };
            expr_bindings.insert(key, expr);
        }
    }

    let mut result_file = esm_file.clone();

    // Apply substitutions to all models
    if let Some(ref mut models) = result_file.models {
        for model in models.values_mut() {
            *model = substitute_in_model(model, &expr_bindings);
        }
    }

    // Apply substitutions to reaction systems if present
    if let Some(ref mut reactions) = result_file.reaction_systems {
        for reaction_system in reactions.values_mut() {
            *reaction_system = substitute_in_reaction_system(reaction_system, &expr_bindings);
        }
    }

    // Convert back to JSON string
    match rust_to_json(&result_file) {
        Ok(json) => Ok(json),
        Err(e) => Err(JsValue::from_str(&format!("Save error: {e}"))),
    }
}

/// Create a compact expression for fast evaluation (WASM version)
#[cfg(feature = "wasm")]
#[wasm_bindgen]
pub fn create_compact_expression(expr_str: &str) -> Result<JsValue, JsValue> {
    // Parse expression from JSON string
    let expr: crate::Expr = serde_json::from_str(expr_str)
        .map_err(|e| JsValue::from_str(&format!("Parse error: {e}")))?;

    let compact = CompactExpr::from_expr(&expr);
    to_js(&compact)
}

/// Compute stoichiometric matrix (WASM version)
#[cfg(feature = "wasm")]
#[wasm_bindgen]
pub fn compute_stoichiometric_matrix(reaction_system_str: &str) -> Result<JsValue, JsValue> {
    let reaction_system: crate::ReactionSystem = serde_json::from_str(reaction_system_str)
        .map_err(|e| JsValue::from_str(&format!("Parse error: {e}")))?;

    let matrix = stoichiometric_matrix(&reaction_system);
    to_js(&matrix)
}

/// Introspect the **flattened** simulation inputs of an `.esm` file (gt-5ws).
///
/// Runs the same `flatten` pass [`solve`] uses, then reports the exact
/// parameter and state names it will accept — already namespaced — together
/// with their defaults and units, plus the system's independent variables. Use
/// this to build a Run UI without guessing the flattened names: the keys
/// returned here are exactly the keys to pass back in `params` / `ic`.
///
/// Returns `{ parameters: Var[], states: Var[], independentVariables: string[] }`
/// where `Var = { name: string, default: number | null, units: string | null }`.
/// A system whose `independentVariables` is not `["t"]` still has an
/// undiscretized spatial operator; discretized (array-op) PDEs report `["t"]`
/// here and run in the browser like any other file (EarthSciAST-akz).
#[cfg(feature = "wasm")]
#[wasm_bindgen]
pub fn simulate_inputs(json_str: &str) -> Result<JsValue, JsValue> {
    use crate::types::ModelVariable;
    use indexmap::IndexMap;

    let esm_file =
        rust_load_string(json_str).map_err(|e| JsValue::from_str(&format!("Parse error: {e}")))?;
    let flat =
        crate::flatten(&esm_file).map_err(|e| JsValue::from_str(&format!("Flatten error: {e}")))?;

    let to_vars = |vars: &IndexMap<String, ModelVariable>| -> Vec<serde_json::Value> {
        vars.iter()
            .map(|(name, mv)| {
                serde_json::json!({ "name": name, "default": mv.default, "units": mv.units })
            })
            .collect()
    };

    // Each state's `kind`, so a host can tell a settable initial condition from
    // one the solver is going to overwrite. Without it every Run UI re-derives
    // the distinction by walking the raw `.esm` itself — the same rule written
    // twice, in a language that cannot see what flattening already resolved.
    let algebraic: std::collections::HashSet<String> =
        crate::simulate::algebraic_state_names(&flat)
            .into_iter()
            .collect();
    let mut states = to_vars(&flat.state_variables);
    for state in &mut states {
        let kind = match state.get("name").and_then(|n| n.as_str()) {
            Some(name) if algebraic.contains(name) => "algebraic",
            _ => "differential",
        };
        state["kind"] = serde_json::Value::from(kind);
    }

    let out = serde_json::json!({
        "parameters": to_vars(&flat.parameters),
        "states": states,
        "independentVariables": flat.independent_variables,
    });

    to_js(&out)
}

/// Run a simulation in the browser (WASM version, gt-5ws / spike S1).
///
/// Flattens and solves the `.esm` file through diffsol's Faer backend, entirely
/// client-side. Pure-ODE / 0-D box models and — since the `simulate_array` wasm
/// gate was lifted (EarthSciAST-akz) — array-op and discretized-PDE
/// files both run here through the same dispatch the native backend uses.
/// **Spherical/geodesic geometry** (conservative regridding) runs here too, as of
/// the move to the pure-Rust `s2rst` kernel: it links into this
/// `wasm32-unknown-unknown` build like any other dependency, so the clip runs
/// in-module with no host setup. (Previously these leaf ops hit a wasm stub and
/// returned a runtime `GeometryError`, because the C++ s2geometry kernel could
/// not be linked and had to be reached through a separate Emscripten module.)
///
/// Arguments:
/// - `json_str`: the `.esm` file as a JSON string.
/// - `t0`, `t_end`: the integration interval.
/// - `params_str`: JSON object mapping parameter name → value (`{}` for none).
/// - `ic_str`: JSON object mapping state name → initial value (`{}` to use the
///   model's `default`s).
/// - `opts_str`: JSON object, all fields optional —
///   `{ "alg": "bdf"|"sdirk"|"erk", "abstol": f64, "reltol": f64,
///      "maxiters": u32, "outputPoints": u32 }`. `outputPoints` samples the
///   solution at that many evenly spaced times in `[t0, t_end]` (nice for
///   plotting); omit it to get the solver's natural step grid. The names are
///   the canonical SciML ones (`API_SPEC.md` §4); the pre-harmonization
///   `solver` / `maxSteps` spellings are still accepted as aliases so an
///   existing host keeps working.
/// - `progress`: optional observer, called as `progress(fraction, t, step)`
///   once before the first step and then after **every** accepted step.
///   `fraction` is the covered share of `[t0, t_end]`, clamped to `[0, 1]`.
///   Return **`false`** to cancel the run. A cancel is NOT an error: the call
///   resolves with the trajectory computed so far and `metadata.retcode ===
///   "Terminated"`. Any other return value — including `undefined`, which is
///   what a callback with no `return` gives — continues. A callback that throws
///   is treated as a cancel.
///
///   It is called on every step and is **not throttled here**: the integrator
///   has no portable clock (`Instant::now()` panics on `wasm32-unknown-unknown`),
///   so a host that wants to rate-limit should do it in JS, where
///   `performance.now()` works. Keep it cheap — a 0-D model can accept
///   thousands of steps in a fraction of a second.
///
/// Returns a JS object `{ time: number[], state: number[][],
/// stateVariableNames: string[], retcode: string, metadata: {...} }` where
/// `state[i][k]` is variable `stateVariableNames[i]` at `time[k]`, and
/// `retcode` is the SciML return code — `"Success"` means the run reached
/// `t_end`, anything else means it stopped early and the trajectory ends there.
///
/// Named `solve`, not `simulate`: `simulate` is deleted in every binding
/// (`esm-libraries-spec.md` §2.5.1). This export builds the EsmProblem and solves
/// it in one call because a `wasm_bindgen` boundary cannot hand a host a
/// `EsmProblem` handle without a lifetime story JS has no way to honour.
#[cfg(all(feature = "wasm", feature = "solve"))]
#[wasm_bindgen]
pub fn solve(
    json_str: &str,
    t0: f64,
    t_end: f64,
    params_str: &str,
    ic_str: &str,
    opts_str: &str,
    progress: Option<js_sys::Function>,
) -> Result<JsValue, JsValue> {
    use crate::problem::{ProblemOptions, esm_problem, solve as rust_solve};

    let esm_file =
        rust_load_string(json_str).map_err(|e| JsValue::from_str(&format!("Parse error: {e}")))?;

    let opts = parse_solve_options(opts_str, t0, t_end, progress)?;

    // Build once, then solve — the same two steps every native caller takes,
    // collapsed here for a host that runs a document ONCE. A host that runs the
    // same document repeatedly should hold a [`Problem`] instead and pay for the
    // build once.
    let prob = esm_problem(
        &esm_file,
        (t0, t_end),
        ProblemOptions {
            p: parse_binding_map(params_str, "Params")?,
            u0: parse_binding_map(ic_str, "Initial-conditions")?,
            compile: crate::problem::Compile::Always,
            ..Default::default()
        },
    )
    .map_err(|e| JsValue::from_str(&format!("EsmProblem build error: {e}")))?;
    let sol =
        rust_solve(&prob, &opts).map_err(|e| JsValue::from_str(&format!("Solve error: {e}")))?;

    to_js(&solution_json(&sol))
}

/// A JSON `{name: number}` map, empty when the string is.
///
/// Shared by [`solve`], [`observed_fields`] and [`Problem`] so the three cannot
/// disagree about what an empty binding map means.
#[cfg(feature = "wasm")]
fn parse_binding_map(
    s: &str,
    what: &str,
) -> Result<std::collections::HashMap<String, f64>, JsValue> {
    let s = s.trim();
    if s.is_empty() {
        return Ok(std::collections::HashMap::new());
    }
    serde_json::from_str(s).map_err(|e| JsValue::from_str(&format!("{what} parse error: {e}")))
}

/// [`solve`]'s options object, including the progress observer.
///
/// Factored out so the free function and [`Problem::solve`] read the SAME
/// spelling of `alg` / `solver`, the same `outputPoints`, and the same cancel
/// convention. Two parsers for one options object is two behaviours waiting to
/// diverge.
#[cfg(all(feature = "wasm", feature = "solve"))]
fn parse_solve_options(
    opts_str: &str,
    t0: f64,
    t_end: f64,
    progress: Option<js_sys::Function>,
) -> Result<crate::simulate::SolveOptions, JsValue> {
    use crate::simulate::{Alg, Flow, Progress, ProgressFn, SolveOptions};

    let opts_json: serde_json::Value = {
        let s = opts_str.trim();
        if s.is_empty() {
            serde_json::json!({})
        } else {
            serde_json::from_str(s)
                .map_err(|e| JsValue::from_str(&format!("Options parse error: {e}")))?
        }
    };

    let mut opts = SolveOptions::default();
    // Canonical `alg` first, the pre-harmonization `solver` as an alias.
    let alg_name = opts_json
        .get("alg")
        .or_else(|| opts_json.get("solver"))
        .and_then(|v| v.as_str());
    if let Some(s) = alg_name {
        opts.alg =
            Alg::from_name(s).ok_or_else(|| JsValue::from_str(&format!("Unknown alg '{s}'")))?;
    }
    if let Some(v) = opts_json.get("abstol").and_then(|v| v.as_f64()) {
        opts.abstol = v;
    }
    if let Some(v) = opts_json.get("reltol").and_then(|v| v.as_f64()) {
        opts.reltol = v;
    }
    if let Some(v) = opts_json
        .get("maxiters")
        .or_else(|| opts_json.get("maxSteps"))
        .and_then(|v| v.as_u64())
    {
        opts.maxiters = v as usize;
    }
    if let Some(n) = opts_json.get("outputPoints").and_then(|v| v.as_u64()) {
        opts.sample_evenly(t0, t_end, n as usize);
    }

    // Positional `(fraction, t, step)` rather than an options object: this fires
    // on every accepted step, and allocating a JS object per step for values the
    // host already knows (it passed t0/t_end/maxSteps in) is pure overhead.
    //
    // Cancel is an explicit `=== false` and nothing else. Treating "falsy" as
    // cancel would make the most natural observer — `(f) => postMessage(f)`,
    // which returns `undefined` — abort on its first call.
    if let Some(cb) = progress {
        let observer: ProgressFn = std::sync::Arc::new(move |p: &Progress<'_>| {
            match cb.call3(
                &JsValue::NULL,
                &JsValue::from_f64(p.fraction()),
                &JsValue::from_f64(p.t),
                &JsValue::from_f64(p.step as f64),
            ) {
                Ok(v) => {
                    if v == JsValue::FALSE {
                        Flow::Cancel
                    } else {
                        Flow::Continue
                    }
                }
                // The observer threw. Stopping is the conservative reading: a
                // host whose progress reporting is broken should not be left
                // with a run it can no longer see or interrupt.
                Err(_) => Flow::Cancel,
            }
        });
        opts.progress = Some(observer);
    }
    Ok(opts)
}

/// A solution in the object shape [`solve`] has always returned.
#[cfg(all(feature = "wasm", feature = "solve"))]
fn solution_json(sol: &crate::simulate::Solution) -> serde_json::Value {
    serde_json::json!({
        "time": sol.time,
        "state": sol.state,
        "stateVariableNames": sol.state_variable_names,
        // The SciML return code (esm-libraries-spec §2.5.3). A host tells "ran
        // to t_end" from "stopped early, here is why" by reading THIS, not by
        // comparing step counters or parsing an error string.
        "retcode": sol.retcode.name(),
        "metadata": metadata_json(sol),
    })
}

/// [`solve`]'s `metadata` object.
#[cfg(all(feature = "wasm", feature = "solve"))]
fn metadata_json(sol: &crate::simulate::Solution) -> serde_json::Value {
    serde_json::json!({
        "alg": sol.metadata.alg,
        "nRhsCalls": sol.metadata.n_rhs_calls,
        "nJacobianCalls": sol.metadata.n_jacobian_calls,
        "nAcceptedSteps": sol.metadata.n_accepted_steps,
        "nRejectedSteps": sol.metadata.n_rejected_steps,
        // Rules the vectorized tape could not compile, so the per-cell oracle
        // evaluated them: `[{rule, reason}, …]`, empty when the tape covered
        // everything. Same numbers either way — but a fallback's cost grows with
        // the cell count, so this is the only way a browser host can tell "slow
        // model" from "slow spelling of a fast model".
        "tapeFallbacks": sol.metadata.tape_fallbacks.iter()
            .map(|(rule, reason)| serde_json::json!({"rule": rule, "reason": reason}))
            .collect::<Vec<_>>(),
    })
}

/// Read back every build-time observed field of a document, evaluated once.
///
/// The counterpart to [`solve`] for a document with **no state variables**: a
/// `system_kind: "nonlinear"` file whose whole content is its observed graph has
/// nothing to integrate, `solve` refuses it with
/// [`SimulateError::NotDynamic`](crate::SimulateError::NotDynamic), and
/// `observed_field` is how such a document's results are read (API_SPEC §5.8).
/// Without this export a wasm host had no way to reach that path at all — the
/// only entry point that runs a model was `solve`, so a browser presented with a
/// state-free document could only hand it to the ODE solver and report whatever
/// the integrator said about a zero-length state vector.
///
/// Arguments mirror [`solve`]'s leading five. `t0`/`t_end` are the problem's
/// span: nothing here integrates over it, but construction takes a span and a
/// time-dependent loader is sampled against it. `params_str` and `ic_str` are
/// the same JSON `{name: number}` maps, bound as `p` and `u0`.
///
/// Returns `{ names: string[], fields: { [name]: { shape: number[], values:
/// number[] } } }`. `names` is [`EsmProblem::observed_field_names`] —
/// component-qualified, sorted, and the spelling that resolves however many
/// components the document has. `values` is the field in row-major (C) order,
/// and `shape` is empty for a rank-0 observed, whose `values` is then a single
/// number. Both are present for every name, so a host need not call twice.
///
/// A document that DOES have state variables is not an error here: it simply
/// reports whatever fields its build materialized, which for an ordinary ODE
/// model is usually none. Deciding which of the two entry points a document
/// wants is the host's job, and `names.length` is not the way to do it —
/// [`crate::classification`] answers it from the document.
#[cfg(feature = "wasm")]
#[wasm_bindgen]
pub fn observed_fields(
    json_str: &str,
    t0: f64,
    t_end: f64,
    params_str: &str,
    ic_str: &str,
) -> Result<JsValue, JsValue> {
    use crate::problem::{ProblemOptions, esm_problem, observed_field};

    let esm_file =
        rust_load_string(json_str).map_err(|e| JsValue::from_str(&format!("Parse error: {e}")))?;

    let prob = esm_problem(
        &esm_file,
        (t0, t_end),
        ProblemOptions {
            p: parse_binding_map(params_str, "Params")?,
            u0: parse_binding_map(ic_str, "Initial-conditions")?,
            ..Default::default()
        },
    )
    .map_err(|e| JsValue::from_str(&format!("EsmProblem build error: {e}")))?;

    let names = prob.observed_field_names();
    let mut fields = serde_json::Map::with_capacity(names.len());
    for name in &names {
        // Every name came from `observed_field_names`, so a miss is a defect in
        // the resolver rather than a caller error — report it as one instead of
        // silently returning a short map.
        let a = observed_field(&prob, name)
            .map_err(|e| JsValue::from_str(&format!("observed_field({name}): {e}")))?;
        fields.insert(
            name.clone(),
            serde_json::json!({
                "shape": a.shape(),
                "values": a.iter().copied().collect::<Vec<f64>>(),
            }),
        );
    }

    to_js(&serde_json::json!({ "names": names, "fields": fields }))
}

/// Compile a document's RHS onto the vectorized tape and report which rules
/// did NOT make it — WITHOUT integrating anything.
///
/// The companion to [`solve`]'s `metadata.tapeFallbacks`, for the case that
/// motivated it: a model with a fallback in a tendency equation may take hours,
/// so the metadata that would have named the culprit never arrives. This runs
/// the build alone (milliseconds) and answers the same question up front.
///
/// Returns `{ nRules, nTaped, fallbacks: [{ rule, reason }, …] }`. A non-empty
/// `fallbacks` is not an error — the numbers are bit-identical either way — but
/// a fallback rule is re-walked once per grid cell per RHS call, so its cost
/// grows with the grid where a taped rule's does not. See `esm-spec.md` §9.6.10
/// for the authoring patterns that keep rules vectorizable.
///
/// Files whose RHS is not array-compilable at all (pure scalar ODE systems)
/// report `nRules: 0` — they never build a tape and have nothing to fall back
/// from.
#[cfg(feature = "wasm")]
#[wasm_bindgen]
pub fn tape_report(json_str: &str) -> Result<JsValue, JsValue> {
    let esm_file =
        rust_load_string(json_str).map_err(|e| JsValue::from_str(&format!("Parse error: {e}")))?;
    let compiled = match crate::simulate_array::ArrayCompiled::from_file(&esm_file) {
        Ok(c) => c,
        // Not an array model: no tape, nothing to report.
        Err(_) => {
            return to_js(&serde_json::json!({
                "nRules": 0, "nTaped": 0, "fallbacks": [],
            }));
        }
    };
    let report = compiled.debug_build_tape_report();
    let out = serde_json::json!({
        "nRules": report.n_rules,
        "nTaped": report.n_taped,
        "fallbacks": report.fallbacks.iter()
            .map(|(rule, reason)| serde_json::json!({"rule": rule, "reason": reason}))
            .collect::<Vec<_>>(),
    });
    to_js(&out)
}

/// Generate component graph for ESM file (WASM version)
#[cfg(feature = "wasm")]
#[wasm_bindgen]
pub fn component_graph(json_str: &str) -> Result<JsValue, JsValue> {
    let esm_file =
        rust_load_string(json_str).map_err(|e| JsValue::from_str(&format!("Parse error: {e}")))?;

    let graph = rust_component_graph(&esm_file);
    to_js(&graph)
}

/// Area of a lon/lat polygon `ring` under `manifold` (RFC §8.1). `ring_json` is a
/// JSON array of `[lon, lat]` pairs in **degrees**; `manifold` is one of
/// `"planar" | "spherical" | "geodesic"`. Returns the planar shoelace area for
/// `planar`, or the great-circle area in **steradians** for `spherical`/`geodesic`.
///
/// The spherical/geodesic path runs the in-module `s2rst` kernel — no host setup,
/// no JS bridge. Only a degenerate ring errors.
#[cfg(feature = "wasm")]
#[wasm_bindgen]
pub fn polygon_area(ring_json: &str, manifold: &str) -> Result<f64, JsValue> {
    let ring: Vec<(f64, f64)> = serde_json::from_str(ring_json)
        .map_err(|e| JsValue::from_str(&format!("ring parse error: {e}")))?;
    let m = crate::geometry::Manifold::from_flag(manifold)
        .ok_or_else(|| JsValue::from_str(&format!("unknown manifold '{manifold}'")))?;
    crate::geometry::polygon_area(&ring, m).map_err(|e| JsValue::from_str(&e.to_string()))
}

/// Clip lon/lat polygon rings `a` and `b` on `manifold` and return the overlap
/// ring as a JSON array of `[lon, lat]` pairs (degrees; `[]` for a disjoint or
/// edge-touching clip). `a_json`/`b_json` are JSON `[lon, lat]` arrays; `manifold`
/// is `"planar" | "spherical" | "geodesic"`. Like [`polygon_area`], every
/// manifold is served in-module — the spherical/geodesic clip needs no host setup.
#[cfg(feature = "wasm")]
#[wasm_bindgen]
pub fn intersect_polygon(a_json: &str, b_json: &str, manifold: &str) -> Result<String, JsValue> {
    let a: Vec<(f64, f64)> = serde_json::from_str(a_json)
        .map_err(|e| JsValue::from_str(&format!("a parse error: {e}")))?;
    let b: Vec<(f64, f64)> = serde_json::from_str(b_json)
        .map_err(|e| JsValue::from_str(&format!("b parse error: {e}")))?;
    let m = crate::geometry::Manifold::from_flag(manifold)
        .ok_or_else(|| JsValue::from_str(&format!("unknown manifold '{manifold}'")))?;
    let ring = crate::geometry::intersect_polygon(&a, &b, m)
        .map_err(|e| JsValue::from_str(&e.to_string()))?;
    serde_json::to_string(&ring).map_err(|e| JsValue::from_str(&format!("serialize error: {e}")))
}

/// Report the crate and supported-schema versions. (The native performance
/// feature flags were dropped from this report: they are never enabled in a
/// wasm build, so advertising them here was misleading.)
#[cfg(feature = "wasm")]
#[wasm_bindgen]
pub fn get_version_info() -> JsValue {
    let info = serde_json::json!({
        "library_version": crate::LIBRARY_VERSION,
        "schema_version": crate::SCHEMA_VERSION,
    });
    to_js(&info).unwrap_or(JsValue::NULL)
}

/// Benchmark parsing performance (WASM version)
#[cfg(feature = "wasm")]
#[wasm_bindgen]
pub fn benchmark_parsing(json_str: &str, iterations: u32) -> Result<f64, JsValue> {
    let start = js_sys::Date::now();

    for _ in 0..iterations {
        rust_load_string(json_str).map_err(|e| JsValue::from_str(&format!("Parse error: {e}")))?;
    }

    let end = js_sys::Date::now();
    let total_time = end - start;

    Ok(total_time / iterations as f64)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_new_wasm_exports_compile() {
        let json = r#"
            {
              "esm": "1.0.0",
              "metadata": {
                "name": "Test Model",
                "description": "A simple test model for WASM exports"
              },
              "models": {
                "SimpleModel": {
                  "variables": {
                    "x": {
                      "type": "unknown",
                      "units": "m",
                      "default": 1.0
                    },
                    "k": {
                      "type": "parameter",
                      "default": 0.5
                    }
                  },
                  "equations": [
                    {
                      "lhs": {
                        "op": "D",
                        "args": [
                          "x"
                        ]
                      },
                      "rhs": {
                        "op": "*",
                        "args": [
                          "k",
                          "x"
                        ]
                      }
                    }
                  ]
                }
              }
            }
            "#;

        // Test that the core functions work (without WASM feature for regular tests)
        let esm_file = rust_load_string(json).expect("Should load valid ESM file");
        let graph = rust_component_graph(&esm_file);

        assert_eq!(graph.nodes.len(), 1, "Should have 1 model node");
        assert_eq!(graph.edges.len(), 0, "Should have no edges");
        assert_eq!(graph.nodes[0].id, "SimpleModel");

        println!("✓ New WASM export functions compile and core functionality works");
    }
}

// =============================================================================
// The Problem / Solution handles
// =============================================================================
//
// [`solve`] and [`observed_fields`] each build a problem, use it once, and throw
// it away, because a `wasm_bindgen` export cannot take one as an argument. That
// is right for a host that runs a document once — the app's Run button — and
// wrong for one that runs the same document repeatedly: a parameter sweep pays
// for flatten, value invention and compile on every member, and reading an
// observed back means solving a second time.
//
// `EsmProblem` is fully owned (`Rc<JsonValue>`, `Rc<Backend>`,
// `Rc<BuildProducts>`) and carries no lifetime, so it satisfies wasm-bindgen's
// `'static` bound and can be handed over as an opaque handle. What JS owes in
// exchange is DISPOSAL: a pointer-backed wasm-bindgen class is not reachable by
// the JavaScript garbage collector, so a handle that is never `free()`d leaks
// its compiled backend and every build product with it. Both classes below are
// `try`/`finally` material.
//
//   const prob = Problem.build(json, 0, 10, '{}', '{}', '{}')
//   try {
//     const sol = prob.solve('{"alg":"bdf"}')
//     try { console.log(sol.observed('NOx')) } finally { sol.free() }
//   } finally { prob.free() }

/// A built [`crate::problem::EsmProblem`], reusable across solves.
///
/// `Rc` rather than a bare value so a [`Solution`] can hold the problem it came
/// from: an observed's trajectory is a function of both, and making the host
/// pass the problem back in would let it pass a DIFFERENT one — silently
/// producing numbers from the wrong parameter bindings.
#[cfg(all(feature = "wasm", feature = "solve"))]
#[wasm_bindgen]
pub struct Problem {
    inner: std::rc::Rc<crate::problem::EsmProblem>,
}

#[cfg(all(feature = "wasm", feature = "solve"))]
#[wasm_bindgen]
impl Problem {
    /// Build a problem from a document. The arguments are [`solve`]'s leading
    /// five, and mean the same things.
    ///
    /// Not a `constructor`: wasm-bindgen constructors cannot be fallible in a
    /// way that reads well from JS, and building a document is the step most
    /// likely to fail.
    pub fn build(
        json_str: &str,
        t0: f64,
        t_end: f64,
        params_str: &str,
        ic_str: &str,
    ) -> Result<Problem, JsValue> {
        use crate::problem::{Compile, ProblemOptions, esm_problem};

        let esm_file = rust_load_string(json_str)
            .map_err(|e| JsValue::from_str(&format!("Parse error: {e}")))?;
        let prob = esm_problem(
            &esm_file,
            (t0, t_end),
            ProblemOptions {
                p: parse_binding_map(params_str, "Params")?,
                u0: parse_binding_map(ic_str, "Initial-conditions")?,
                // `Auto`, not `Always`: a handle is also how a host inspects a
                // STATIC document, and `Always` would fail to build the very
                // documents `observed_field` exists to answer for. A host that
                // means to integrate calls `solve`, which says so with its own
                // error if there is nothing to integrate.
                compile: Compile::Auto,
                ..Default::default()
            },
        )
        .map_err(|e| JsValue::from_str(&format!("EsmProblem build error: {e}")))?;
        Ok(Problem {
            inner: std::rc::Rc::new(prob),
        })
    }

    /// Integrate, returning a [`Solution`] handle.
    ///
    /// `opts_str` and `progress` are [`solve`]'s, unchanged — including the
    /// `alg` / `solver` alias and the `=== false` cancel convention.
    pub fn solve(
        &self,
        opts_str: &str,
        progress: Option<js_sys::Function>,
    ) -> Result<Solution, JsValue> {
        let (t0, t_end) = self.inner.tspan();
        let opts = parse_solve_options(opts_str, t0, t_end, progress)?;
        let sol = crate::problem::solve(&self.inner, &opts)
            .map_err(|e| JsValue::from_str(&format!("Solve error: {e}")))?;
        Ok(Solution {
            inner: sol,
            problem: self.inner.clone(),
        })
    }

    /// A NEW problem with different bindings, sharing this one's compiled
    /// right-hand side and build products (§2.5.5) — the point of holding a
    /// handle at all.
    ///
    /// Empty JSON leaves that half unchanged; `tspan_str` is `[t0, t_end]` or
    /// empty. The original is untouched, so a sweep keeps one problem and
    /// derives a member per point.
    pub fn remake(
        &self,
        params_str: &str,
        ic_str: &str,
        tspan_str: &str,
    ) -> Result<Problem, JsValue> {
        let tspan = {
            let s = tspan_str.trim();
            if s.is_empty() {
                None
            } else {
                let v: Vec<f64> = serde_json::from_str(s)
                    .map_err(|e| JsValue::from_str(&format!("Tspan parse error: {e}")))?;
                if v.len() != 2 {
                    return Err(JsValue::from_str("Tspan must be [t0, t_end]"));
                }
                Some((v[0], v[1]))
            }
        };
        let next = crate::problem::remake(
            &self.inner,
            &crate::problem::Remake {
                p: parse_binding_map(params_str, "Params")?,
                u0: parse_binding_map(ic_str, "Initial-conditions")?,
                tspan,
                callbacks: None,
            },
        )
        .map_err(|e| JsValue::from_str(&format!("Remake error: {e}")))?;
        Ok(Problem {
            inner: std::rc::Rc::new(next),
        })
    }

    /// One BUILD-time observed field, as `{ shape, values }` (API_SPEC §5.8).
    ///
    /// The handle form of [`observed_fields`]. For an observed of a document
    /// that integrates, ask the [`Solution`]: a build-time field is a constant
    /// and a trajectory is not.
    pub fn observed_field(&self, name: &str) -> Result<JsValue, JsValue> {
        let a = crate::problem::observed_field(&self.inner, name)
            .map_err(|e| JsValue::from_str(&format!("observed_field({name}): {e}")))?;
        to_js(&serde_json::json!({
            "shape": a.shape(),
            "values": a.iter().copied().collect::<Vec<f64>>(),
        }))
    }

    /// Every name [`Problem::observed_field`] can answer for, sorted.
    #[wasm_bindgen(js_name = observedFieldNames)]
    pub fn observed_field_names(&self) -> Vec<String> {
        self.inner.observed_field_names()
    }

    /// Flattened state-variable names, in solver order.
    #[wasm_bindgen(js_name = stateVariableNames)]
    pub fn state_variable_names(&self) -> Vec<String> {
        self.inner.state_variable_names()
    }

    /// Flattened parameter names.
    #[wasm_bindgen(js_name = parameterNames)]
    pub fn parameter_names(&self) -> Vec<String> {
        self.inner.parameter_names()
    }

    /// Whether there is anything to integrate. `false` means [`Problem::solve`]
    /// will refuse, and the results are read with
    /// [`Problem::observed_field`].
    #[wasm_bindgen(js_name = isDynamic)]
    pub fn is_dynamic(&self) -> bool {
        self.inner.is_dynamic()
    }

    /// The integration interval, as `[t0, t_end]`.
    pub fn tspan(&self) -> Vec<f64> {
        let (a, b) = self.inner.tspan();
        vec![a, b]
    }
}

/// A trajectory, plus the problem that produced it.
///
/// Holding the problem is what lets [`Solution::observed`] answer at all: an
/// observed is a pure function of `(state, params, t)`, the problem holds the
/// function and this holds the arguments.
#[cfg(all(feature = "wasm", feature = "solve"))]
#[wasm_bindgen]
pub struct Solution {
    inner: crate::simulate::Solution,
    problem: std::rc::Rc<crate::problem::EsmProblem>,
}

#[cfg(all(feature = "wasm", feature = "solve"))]
#[wasm_bindgen]
impl Solution {
    /// The whole trajectory in [`solve`]'s object shape, so a host can move
    /// between the two APIs without a second decoder.
    #[wasm_bindgen(js_name = toJSON)]
    pub fn to_json(&self) -> Result<JsValue, JsValue> {
        to_js(&solution_json(&self.inner))
    }

    /// Output times.
    pub fn time(&self) -> Vec<f64> {
        self.inner.time.clone()
    }

    /// Flattened state-variable names, parallel to the rows of the state.
    #[wasm_bindgen(js_name = stateVariableNames)]
    pub fn state_variable_names(&self) -> Vec<String> {
        self.inner.state_variable_names.clone()
    }

    /// One state variable's trajectory, by name (esm-libraries-spec §2.5.7).
    ///
    /// Resolves the exact flattened name, then a unique bare tail. Returns an
    /// error rather than an empty array for a name it does not have, so a typo
    /// is not a row of zeros.
    pub fn get(&self, name: &str) -> Result<Vec<f64>, JsValue> {
        self.inner
            .get(name)
            .map(|v| v.to_vec())
            .ok_or_else(|| JsValue::from_str(&format!("no state variable named '{name}'")))
    }

    /// One OBSERVED variable's trajectory over the output grid.
    ///
    /// The reason this class holds its problem. A `Solution` carries state rows
    /// only — in every binding — so before this there was no way to read back
    /// an observed of a model that integrates. Name resolution is API_SPEC
    /// §5.8's rule.
    pub fn observed(&self, name: &str) -> Result<Vec<f64>, JsValue> {
        crate::problem::observed_trajectory(&self.problem, &self.inner, name)
            .map_err(|e| JsValue::from_str(&format!("observed({name}): {e}")))
    }

    /// Several observeds in ONE pass over the output grid.
    ///
    /// `names_str` is a JSON array; the result is an object keyed by the names
    /// that were ASKED FOR. The graph is walked once per output time however
    /// many names are given, so this is materially cheaper than a loop over
    /// [`Solution::observed`].
    ///
    /// **Tolerant, where [`Solution::observed`] is strict.** A name that is not
    /// an observed variable is simply ABSENT from the result rather than an
    /// error — most often because it is a STATE, which the caller already has.
    /// That is what a host reading a model's authored assertions needs: it
    /// knows the variable names and not which kind each is, and one state in
    /// the list must not cost it the other answers. A caller that wants "this
    /// specific name or an explanation" asks [`Solution::observed`].
    #[wasm_bindgen(js_name = observedMany)]
    pub fn observed_many(&self, names_str: &str) -> Result<JsValue, JsValue> {
        let names: Vec<String> = serde_json::from_str(names_str)
            .map_err(|e| JsValue::from_str(&format!("Names parse error: {e}")))?;
        let rows = crate::problem::observed_trajectories(&self.problem, &self.inner, &names)
            .map_err(|e| JsValue::from_str(&format!("observedMany: {e}")))?;
        let out: serde_json::Map<String, serde_json::Value> = rows
            .into_iter()
            .map(|(n, row)| (n, serde_json::json!(row)))
            .collect();
        to_js(&out)
    }

    /// Every observed variable this solution can report a trajectory for.
    #[wasm_bindgen(js_name = observedNames)]
    pub fn observed_names(&self) -> Vec<String> {
        self.problem.observed_variable_names()
    }

    /// The SciML return code. `"Success"` means the run reached `t_end`.
    pub fn retcode(&self) -> String {
        self.inner.retcode.name().to_string()
    }

    /// Solver provenance and step counters.
    pub fn metadata(&self) -> Result<JsValue, JsValue> {
        to_js(&metadata_json(&self.inner))
    }
}
